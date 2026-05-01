package.path = "/home/nick/.config/nvim/lua/?.lua;/home/nick/.config/nvim/lua/?/init.lua;" .. package.path

local shaderdebug = require("shaderdebug")

local IMAGES = {
  { label = "png", path = "/home/nick/Pictures/One Dark/30. One Dark.png" },
  { label = "jpg", path = "/home/nick/Pictures/Material Sakura/12. Material Sakura.jpg" },
  { label = "gif", path = "/home/nick/Pictures/Animated/10. Animated.gif" },
  { label = "webp", path = "/tmp/shaderdebug-test.webp" },
}

local CYCLES = 3
local WEBP_FIXTURE_PATH = "/tmp/shaderdebug-test.webp"

local function assert_truthy(value, message)
  if not value then
    error(message or "assertion failed", 2)
  end
  return value
end

local function log(message)
  io.stdout:write(message .. "\n")
end

local function ensure_webp_fixture()
  if vim.fn.filereadable(WEBP_FIXTURE_PATH) == 1 then
    return true
  end

  local result = vim.system({
    "ffmpeg",
    "-y",
    "-loglevel",
    "error",
    "-i",
    IMAGES[1].path,
    WEBP_FIXTURE_PATH,
  }, { text = true }):wait()

  return result.code == 0 and vim.fn.filereadable(WEBP_FIXTURE_PATH) == 1
end

local function find_spec(result, name)
  for _, spec in ipairs(result.resource_specs or {}) do
    if spec.name == name then
      return spec
    end
  end
end

local function assert_render_output(result, switch_index)
  if result.output_mode == "memory" then
    local data = result.output_png_data
    assert_truthy(type(data) == "string" and #data > 24, "missing output png bytes on switch " .. switch_index)
    assert_truthy(data:sub(1, 8) == "\137PNG\r\n\26\n", "invalid png bytes on switch " .. switch_index)
    return
  end

  assert_truthy(vim.fn.filereadable(result.output_png) == 1, "missing output png on switch " .. switch_index)
end

local function render_switch(image, switch_index)
  shaderdebug.set_image_input("scene_color", image.path)
  vim.api.nvim_win_set_cursor(0, { 30, 0 })
  local result = assert_truthy(shaderdebug.preview_current_line({ sync = true }), "render failed on switch " .. switch_index)
  local scene = assert_truthy(find_spec(result, "scene_color"), "missing scene_color on switch " .. switch_index)
  local sampler = assert_truthy(find_spec(result, "scene_sampler"), "missing scene_sampler on switch " .. switch_index)
  local bound = assert_truthy(scene.bound_values and scene.bound_values[1], "missing bound image on switch " .. switch_index)

  assert_render_output(result, switch_index)
  assert_truthy(vim.fn.filereadable(bound) == 1, "missing bound source on switch " .. switch_index .. ": " .. bound)
  assert_truthy(sampler.bound_values and sampler.bound_values[1] == "linear", "sampler state changed unexpectedly")

  log(string.format("switch %02d ok: %s -> %s", switch_index, image.label, bound))
end

local function run_api_case(api)
  log("== stress API: " .. api .. " ==")
  shaderdebug.setup({ api = api, auto_preview = false, debounce_ms = 15, cache_dir = "/tmp/shaderdebug-stress-" .. api })
  shaderdebug.open_test_shader()
  shaderdebug.set_data_input("globals", '{"tint":[1,1,1,1],"time":2.0,"resolution":[512,512]}')

  local switch_index = 0
  for cycle = 1, CYCLES do
    log("cycle " .. cycle)
    for _, image in ipairs(IMAGES) do
      switch_index = switch_index + 1
      render_switch(image, switch_index)
    end
  end

  shaderdebug.clear_input("scene_color")
  shaderdebug.clear_input("globals")
  shaderdebug.clear_preview()
  log("PASS stress API: " .. api)
end

local ok, err = xpcall(function()
  assert_truthy(ensure_webp_fixture(), "failed to prepare webp test image: " .. WEBP_FIXTURE_PATH)
  for _, image in ipairs(IMAGES) do
    assert_truthy(vim.fn.filereadable(image.path) == 1, "missing test image: " .. image.path)
  end
  run_api_case("vulkan")
  run_api_case("opengl")
end, debug.traceback)

if ok then
  log("ALL STRESS SWITCH TESTS PASSED")
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
