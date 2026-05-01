package.path = "/home/nick/.config/nvim/lua/?.lua;/home/nick/.config/nvim/lua/?/init.lua;" .. package.path

local shaderdebug = require("shaderdebug")

local IMAGES = {
  { label = "png", path = "/home/nick/Pictures/One Dark/30. One Dark.png", expect_passthrough = true },
  { label = "jpg", path = "/home/nick/Pictures/Material Sakura/12. Material Sakura.jpg", expect_passthrough = false },
  { label = "gif", path = "/home/nick/Pictures/Animated/10. Animated.gif", expect_passthrough = false },
}

local function fail(message)
  error(message, 2)
end

local function assert_truthy(value, message)
  if not value then
    fail(message or "assertion failed")
  end
  return value
end

local function log(message)
  io.stdout:write(message .. "\n")
end

local function find_spec(result, name)
  for _, spec in ipairs(result.resource_specs or {}) do
    if spec.name == name then
      return spec
    end
  end
end

local function assert_render_output(result, label)
  if result.output_mode == "memory" then
    local data = result.output_png_data
    assert_truthy(type(data) == "string" and #data > 24, "rendered output bytes missing for " .. label)
    assert_truthy(data:sub(1, 8) == "\137PNG\r\n\26\n", "rendered bytes are not png for " .. label)
    return
  end

  assert_truthy(vim.fn.filereadable(result.output_png) == 1, "rendered output missing for " .. label)
end

local function render_with_image(image)
  shaderdebug.set_image_input("scene_color", image.path)
  vim.api.nvim_win_set_cursor(0, { 30, 0 })
  local result = assert_truthy(shaderdebug.preview_current_line({ sync = true }), "render failed for " .. image.label)
  local spec = assert_truthy(find_spec(result, "scene_color"), "scene_color missing for " .. image.label)
  local bound = assert_truthy(spec.bound_values and spec.bound_values[1], "scene_color bound value missing for " .. image.label)
  assert_truthy(vim.fn.filereadable(bound) == 1, "bound file unreadable for " .. image.label .. ": " .. bound)
  assert_render_output(result, image.label)

  if image.expect_passthrough then
    local expected = vim.fn.fnamemodify(image.path, ":p")
    assert_truthy(bound == expected, string.format("expected png passthrough for %s, got %s", image.label, bound))
  else
    assert_truthy(bound:match("%.png$") ~= nil, "expected converted png for " .. image.label .. ": " .. bound)
    assert_truthy(bound ~= vim.fn.fnamemodify(image.path, ":p"), "expected converted path for " .. image.label)
  end

  log(string.format("PASS image switch: %s -> %s", image.label, bound))
  return result, bound
end

local function run_api_case(api)
  log("== image switching API: " .. api .. " ==")
  shaderdebug.setup({ api = api, auto_preview = false, debounce_ms = 25, cache_dir = "/tmp/shaderdebug-switch-" .. api })
  shaderdebug.open_test_shader()
  shaderdebug.set_data_input("globals", '{"tint":[1,1,1,1],"time":0.75,"resolution":[512,512]}')

  local seen = {}
  for _, image in ipairs(IMAGES) do
    local _, bound = render_with_image(image)
    assert_truthy(not seen[bound], "bound path repeated unexpectedly for " .. image.label)
    seen[bound] = true
  end

  shaderdebug.clear_input("scene_color")
  shaderdebug.clear_input("globals")
  shaderdebug.clear_preview()
  log("PASS api switch cycle: " .. api)
end

local ok, err = xpcall(function()
  for _, image in ipairs(IMAGES) do
    assert_truthy(vim.fn.filereadable(image.path) == 1, "missing test image: " .. image.path)
  end
  run_api_case("vulkan")
  run_api_case("opengl")
end, debug.traceback)

if ok then
  log("ALL IMAGE SWITCH TESTS PASSED")
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
