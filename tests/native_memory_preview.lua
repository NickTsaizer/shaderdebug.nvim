package.path = "/home/nick/.config/nvim/lua/?.lua;/home/nick/.config/nvim/lua/?/init.lua;" .. package.path

local shaderdebug = require("shaderdebug")
local context = require("shaderdebug.src.context")
local preview = require("shaderdebug.src.preview")

local function fail(message)
  error(message, 2)
end

local function assert_truthy(value, message)
  if not value then
    fail(message or "assertion failed")
  end
  return value
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. string.format(" (expected=%s actual=%s)", tostring(expected), tostring(actual)))
  end
end

local function pack_u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function fake_png_bytes(width, height)
  return "\137PNG\r\n\26\n" .. "\0\0\0\rIHDR" .. pack_u32(width) .. pack_u32(height) .. string.rep("\0", 24)
end

local captured = {}
local original_img = vim.ui and vim.ui.img or nil
local original_nvim_list_uis = vim.api.nvim_list_uis

local function reset_capture()
  captured = { set_calls = 0, del_calls = 0, data = nil, opts = nil }
end

local function install_native_stub()
  vim.ui = vim.ui or {}
  vim.ui.img = {
    _supported = function()
      return true
    end,
    set = function(data, opts)
      captured.set_calls = captured.set_calls + 1
      captured.data = data
      captured.opts = opts
      return 99
    end,
    del = function(id)
      captured.del_calls = captured.del_calls + 1
      captured.deleted_id = id
    end,
  }
end

local function restore_native_stub()
  vim.ui = vim.ui or {}
  vim.ui.img = original_img
end

local function install_ui_stub()
  vim.api.nvim_list_uis = function()
    return { { width = 120, height = 40 } }
  end
end

local function restore_ui_stub()
  vim.api.nvim_list_uis = original_nvim_list_uis
end

local ok, err = xpcall(function()
  reset_capture()
  install_native_stub()
  install_ui_stub()

  shaderdebug.setup({
    api = "vulkan",
    auto_preview = false,
    cache_dir = "/tmp/shaderdebug-native-memory-preview",
    preview = { backend = "native" },
  })

  local render_target = preview.get_render_target()
  assert_eq(render_target.mode, "memory", "native preview should request memory output")

  local png_data = fake_png_bytes(8, 4)
  preview.show_preview({
    api = "vulkan",
    bufnr = vim.api.nvim_get_current_buf(),
    cursor_line = 1,
    entry = "fsMain",
    expression = "float4(1.0)",
    shader_key = "test-shader",
    resource_specs = {},
    output_mode = "memory",
    output_png = "/tmp/this-file-should-not-be-read.png",
    output_png_data = png_data,
  })

  assert_eq(captured.set_calls, 1, "native image api should be called exactly once")
  assert_eq(captured.data, png_data, "native preview should use in-memory png bytes")
  assert_truthy(type(captured.opts) == "table", "native image opts missing")
  assert_truthy(captured.opts.width >= 1 and captured.opts.height >= 1, "native image size missing")
  assert_truthy(context.get_state().image and context.get_state().image.kind == "native", "native preview state missing")

  shaderdebug.clear_preview()
  assert_eq(captured.del_calls, 1, "native image should be cleared once")
end, debug.traceback)

restore_native_stub()
restore_ui_stub()

if ok then
  io.stdout:write("NATIVE MEMORY PREVIEW TEST PASSED\n")
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
