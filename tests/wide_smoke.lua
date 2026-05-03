dofile(vim.fn.fnamemodify((debug.getinfo(1, "S").source:sub(2)), ":h") .. "/bootstrap.lua")

local shaderdebug = require("shaderdebug")

local function assert_truthy(value, message)
  if not value then
    error(message or "assertion failed")
  end
  return value
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. string.format(" (expected=%s actual=%s)", tostring(expected), tostring(actual)))
  end
end

local function log(message)
  io.stdout:write(message .. "\n")
end

local function current_commands()
  return vim.api.nvim_get_commands({ builtin = false })
end

local function expect_commands()
  local commands = current_commands()
  for _, name in ipairs({
    "ShaderDebugPreview",
    "ShaderDebugToggleAuto",
    "ShaderDebugInputs",
    "ShaderDebugSetImage",
    "ShaderDebugSetImages",
    "ShaderDebugSetData",
    "ShaderDebugClearInput",
    "ShaderDebugOpenTestShader",
    "ShaderDebugClear",
  }) do
    assert_truthy(commands[name], "missing command: " .. name)
  end
end

local function set_test_cursor(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

local function has_resource(result, name)
  for _, spec in ipairs(result.resource_specs or {}) do
    if spec.name == name then
      return true
    end
  end
  return false
end

local function assert_render_output(result)
  if result.output_mode == "memory" then
    local data = result.output_png_data
    assert_truthy(type(data) == "string" and #data > 24, "missing rendered png bytes")
    assert_truthy(data:sub(1, 8) == "\137PNG\r\n\26\n", "rendered bytes are not a png")
    return
  end

  assert_truthy(vim.fn.filereadable(result.output_png) == 1, "missing rendered png")
end

local function run_line_case(api, line, expected_resources)
  set_test_cursor(line)
  local inputs_result = assert_truthy(shaderdebug.show_inputs(), string.format("show_inputs failed for %s line %d", api, line))
  assert_eq(inputs_result.api, api, "show_inputs api mismatch")
  assert_truthy(#inputs_result.resource_specs >= 1, "expected reflected resource specs")
  for _, name in ipairs(expected_resources or {}) do
    assert_truthy(has_resource(inputs_result, name), string.format("missing reflected resource '%s' on line %d", name, line))
  end

  local render_result = assert_truthy(shaderdebug.preview_current_line({ sync = true }), string.format("preview_current_line failed for %s line %d", api, line))
  assert_eq(render_result.api, api, "render api mismatch")
  assert_eq(render_result.cursor_line, line, "cursor line mismatch")
  assert_render_output(render_result)
  assert_truthy(render_result.manifest_path and vim.fn.filereadable(render_result.manifest_path) == 1, "missing manifest")
  assert_truthy(render_result.vertex_spv and render_result.fragment_spv, "missing compiled shader outputs")
  for _, name in ipairs(expected_resources or {}) do
    assert_truthy(has_resource(render_result, name), string.format("missing rendered resource '%s' on line %d", name, line))
  end
  assert_truthy(shaderdebug.get_last_result() ~= nil, "last result not recorded")
  assert_truthy(vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()), "source buffer became invalid")
  assert_truthy(require("shaderdebug.src.context").get_state().preview_context ~= nil, "preview context missing")
end

local function run_api_case(api)
  log("== API: " .. api .. " ==")
  shaderdebug.setup({ api = api, auto_preview = false, debounce_ms = 25, cache_dir = "/tmp/shaderdebug-tests-" .. api })
  expect_commands()
  assert_eq(shaderdebug.get_api(), api, "configured api mismatch")

  shaderdebug.open_test_shader()
  assert_eq(vim.bo.filetype, "slang", "test shader filetype mismatch")

  shaderdebug.set_data_input("globals", '{"tint":[1,0.5,0.25,1],"time":1.25,"resolution":[512,512]}')
  shaderdebug.set_data_input("debug_points", '[[1,0,0,1],[0,1,0,1],[0,0,1,1]]')
  shaderdebug.set_image_input("scene_color", "__default__")

  run_line_case(api, 20, {})
  run_line_case(api, 27, { "globals" })
  run_line_case(api, 28, {})
  run_line_case(api, 30, { "scene_color", "scene_sampler" })
  run_line_case(api, 32, { "globals", "scene_color", "scene_sampler" })

  shaderdebug.clear_input("globals")
  shaderdebug.clear_input("debug_points")
  shaderdebug.clear_input("scene_color")
  shaderdebug.clear_preview()

  local state = require("shaderdebug.src.context").get_state()
  assert_truthy(state.preview_win == nil or not vim.api.nvim_win_is_valid(state.preview_win), "preview window still valid after clear")
  assert_truthy(state.preview_buf == nil or not vim.api.nvim_buf_is_valid(state.preview_buf), "preview buffer still valid after clear")
  log("PASS: " .. api)
end

local ok, err = xpcall(function()
  run_api_case("vulkan")
  run_api_case("opengl")
end, debug.traceback)

if ok then
  log("ALL TESTS PASSED")
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
