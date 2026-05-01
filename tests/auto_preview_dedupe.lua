package.path = "/home/nick/.config/nvim/lua/?.lua;/home/nick/.config/nvim/lua/?/init.lua;" .. package.path

local shaderdebug = require("shaderdebug")
local context = require("shaderdebug.src.context")
local render = require("shaderdebug.src.render")

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

local function make_timer()
  return {
    starts = 0,
    stops = 0,
    callback = nil,
    stop = function(self)
      self.stops = self.stops + 1
    end,
    start = function(self, _, _, callback)
      self.starts = self.starts + 1
      self.callback = callback
    end,
  }
end

local function flush_timer(timer, calls, expected_count)
  assert_truthy(timer.callback, "missing scheduled callback")
  timer.callback()
  local completed = vim.wait(100, function()
    return #calls >= expected_count
  end)
  assert_truthy(completed, "scheduled callback did not complete")
end

local function set_line(line, value)
  vim.api.nvim_buf_set_lines(0, line - 1, line, false, { value })
end

local ok, err = xpcall(function()
  shaderdebug.setup({
    api = "vulkan",
    auto_preview = true,
    debounce_ms = 5,
    cache_dir = "/tmp/shaderdebug-auto-preview-dedupe",
  })
  shaderdebug.open_test_shader()

  local state = context.get_state()
  local timer = make_timer()
  state.timer = timer

  local original_start_preview_job = render.start_preview_job
  local calls = {}

  render.start_preview_job = function(opts, on_complete)
    calls[#calls + 1] = opts
    state.last_preview_request = {
      bufnr = opts.bufnr,
      cursor_line = opts.cursor_line,
      changedtick = opts.changedtick,
    }
    if on_complete then
      on_complete({ ok = true }, nil)
    end
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local target_line = 30
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })

  render.schedule_preview(bufnr, target_line)
  assert_eq(timer.starts, 1, "initial schedule should start timer once")

  render.schedule_preview(bufnr, target_line)
  assert_eq(timer.starts, 1, "duplicate schedule should not restart timer")

  flush_timer(timer, calls, 1)
  assert_eq(#calls, 1, "timer callback should trigger one preview job")
  assert_truthy(state.last_preview_request ~= nil, "last preview request should be recorded")

  render.schedule_preview(bufnr, target_line)
  assert_eq(timer.starts, 1, "rendered request should not reschedule without changes")

  local original_line = vim.api.nvim_buf_get_lines(bufnr, 24, 25, false)[1]
  set_line(25, original_line .. " ")

  render.schedule_preview(bufnr, target_line)
  assert_eq(timer.starts, 2, "buffer change should reschedule preview")
  flush_timer(timer, calls, 2)
  assert_eq(#calls, 2, "changed buffer should trigger a second preview job")

  render.start_preview_job = original_start_preview_job
  shaderdebug.clear_preview()
end, debug.traceback)

if ok then
  io.stdout:write("AUTO PREVIEW DEDUPE TEST PASSED\n")
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
