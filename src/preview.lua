local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")
local util = require("shaderdebug.src.util")

local M = {}

local on_preview_closed = function() end
local native_image_supported = nil
local missing_image_backend_warned = false

local function warn_missing_image_backend()
    if missing_image_backend_warned then
        return
    end

    missing_image_backend_warned = true
    util.notify(
        "No image backend available for shaderdebug preview. Install/enable image.nvim or use a Neovim build with vim.ui.img support.",
        vim.log.levels.WARN
    )
end

local function warn_unavailable_backend(backend)
    if missing_image_backend_warned then
        return
    end

    missing_image_backend_warned = true
    util.notify(string.format("Shaderdebug preview backend '%s' is unavailable.", backend), vim.log.levels.WARN)
end

function M.setup(opts)
    on_preview_closed = opts and opts.on_preview_closed or on_preview_closed
end

function M.result_context(result)
    return {
        bufnr = result.bufnr,
        cursor_line = result.cursor_line,
        shader_key = result.shader_key,
    }
end

local function supports_native_image_api()
    if native_image_supported ~= nil then
        return native_image_supported
    end

    local image = vim.ui and vim.ui.img
    if type(image) ~= "table" or type(image.set) ~= "function" or type(image.del) ~= "function" then
        native_image_supported = false
        return false
    end

    local ok, supported = pcall(image._supported, { timeout = 100 })
    native_image_supported = ok and supported or false
    return native_image_supported
end

local function load_image_api()
    local preview_config = context.get_config().preview or {}
    local backend = preview_config.backend or "auto"

    if backend == "native" then
        if supports_native_image_api() then
            return { kind = "native", api = vim.ui.img }
        end
        warn_unavailable_backend("native")
        return nil
    end

    local ok, image = pcall(require, "image")
    local function load_plugin_backend()
        local ok_plugin, plugin_image = pcall(require, "image")
        if ok_plugin then
            return { kind = "plugin", api = plugin_image }
        end

        local ok_lazy, lazy = pcall(require, "lazy")
        if ok_lazy then
            pcall(lazy.load, { plugins = { "image.nvim" } })
        end

        ok_plugin, plugin_image = pcall(require, "image")
        if ok_plugin then
            return { kind = "plugin", api = plugin_image }
        end

        return nil
    end

    if backend == "image.nvim" then
        local plugin_backend = load_plugin_backend()
        if plugin_backend then
            return plugin_backend
        end
        warn_unavailable_backend("image.nvim")
        return nil
    end

    if supports_native_image_api() then
        return { kind = "native", api = vim.ui.img }
    end

    local plugin_backend = load_plugin_backend()
    if plugin_backend then
        return plugin_backend
    end

    warn_missing_image_backend()
    return nil
end

function M.clear_image()
    local state = context.get_state()
    if state.image then
        if state.image.kind == "native" then
            pcall(vim.ui.img.del, state.image.id)
        elseif state.image.kind == "plugin" and state.image.handle then
            pcall(state.image.handle.clear, state.image.handle)
        end
        state.image = nil
    end
end

local function update_preview_image(image, result, preview_win, preview_buf, width, height)
    local state = context.get_state()
    local config = context.get_config()
    local absolute_path = vim.fn.fnamemodify(result.output_png, ":p")
    local image_y = math.max((state.preview_text_line_count or 1) + (config.preview.image_gap_lines or 0) - 1, 0)

    image.window = preview_win
    image.buffer = preview_buf
    image.namespace = "shaderdebug"
    image.inline = true
    image.with_virtual_padding = true
    image.geometry = image.geometry or {}
    image.geometry.x = 0
    image.geometry.y = image_y
    image.geometry.width = width
    image.geometry.height = height
    image.rendered_geometry = { x = nil, y = nil, width = nil, height = nil }
    image.last_modified = -1
    image.resize_hash = nil
    image.cropped_hash = nil

    if image.original_path ~= absolute_path then
        image:clear(true)
        image.original_path = absolute_path
        image.path = absolute_path
        image.cropped_path = absolute_path
        image.resized_path = absolute_path
    end
end

local function read_file_bytes(path)
    local fd, open_err = vim.uv.fs_open(path, "r", 438)
    if not fd then
        return nil, open_err
    end

    local stat, stat_err = vim.uv.fs_fstat(fd)
    if not stat then
        vim.uv.fs_close(fd)
        return nil, stat_err
    end

    local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)
    if not data then
        return nil, read_err
    end

    return data, nil
end

local function byte_to_int(b1, b2, b3, b4)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function read_png_size(data)
    if type(data) ~= "string" or #data < 24 then
        return nil
    end

    if data:sub(1, 8) ~= "\137PNG\r\n\26\n" or data:sub(13, 16) ~= "IHDR" then
        return nil
    end

    local b = { data:byte(17, 24) }
    if #b < 8 then
        return nil
    end

    local width = byte_to_int(b[1], b[2], b[3], b[4])
    local height = byte_to_int(b[5], b[6], b[7], b[8])
    if width <= 0 or height <= 0 then
        return nil
    end

    return width, height
end

local function default_cell_aspect_ratio()
    local term = (vim.env.TERM or ""):lower()
    return (term:find("kitty", 1, true) or vim.env.KITTY_WINDOW_ID) and 2 or 1
end

local function decode_json_output(command)
    local result = util.system_wait(command)
    if result.code ~= 0 or not result.stdout or result.stdout == "" then
        return nil
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok then
        return nil
    end

    return decoded
end

local function kitty_window_grid_size()
    if vim.fn.executable("kitty") ~= 1 or not vim.env.KITTY_WINDOW_ID then
        return nil
    end

    local decoded = decode_json_output({ "kitty", "@", "ls" })
    if type(decoded) ~= "table" then
        return nil
    end

    local target_id = tonumber(vim.env.KITTY_WINDOW_ID)
    for _, os_window in ipairs(decoded) do
        for _, tab in ipairs(os_window.tabs or {}) do
            for _, window in ipairs(tab.windows or {}) do
                if tonumber(window.id) == target_id then
                    return window.columns, window.lines
                end
            end
        end
    end

    return nil
end

local function hyprland_active_window_size()
    if vim.fn.executable("hyprctl") ~= 1 or not vim.env.HYPRLAND_INSTANCE_SIGNATURE then
        return nil
    end

    local decoded = decode_json_output({ "hyprctl", "activewindow", "-j" })
    if type(decoded) ~= "table" or type(decoded.size) ~= "table" then
        return nil
    end

    local size = decoded.size
    local width = tonumber(size[1])
    local height = tonumber(size[2])
    if not width or not height or width <= 0 or height <= 0 then
        return nil
    end

    return width, height
end

local function detect_cell_aspect_ratio()
    local cols, rows = kitty_window_grid_size()
    local pixel_width, pixel_height = hyprland_active_window_size()
    if not cols or not rows or not pixel_width or not pixel_height then
        return nil
    end

    local cell_width = pixel_width / cols
    local cell_height = pixel_height / rows
    if cell_width <= 0 or cell_height <= 0 then
        return nil
    end

    return cell_height / cell_width
end

local function get_cell_aspect_ratio()
    local preview_config = context.get_config().preview or {}
    if type(preview_config.cell_aspect_ratio) == "number" and preview_config.cell_aspect_ratio > 0 then
        return preview_config.cell_aspect_ratio
    end

    local state = context.get_state()
    if state.attempted_cell_aspect_ratio_detection then
        return state.detected_cell_aspect_ratio or default_cell_aspect_ratio()
    end

    state.attempted_cell_aspect_ratio_detection = true
    state.detected_cell_aspect_ratio = detect_cell_aspect_ratio()
    return state.detected_cell_aspect_ratio or default_cell_aspect_ratio()
end

local function fit_image_size(max_width, max_height, image_width, image_height)
    local _ = image_width
    local __ = image_height

    local cell_aspect_ratio = get_cell_aspect_ratio()

    local height = math.max(math.min(max_height, math.floor(max_width / cell_aspect_ratio)), 1)
    local width = math.max(math.floor(height * cell_aspect_ratio), 1)

    if width > max_width then
        width = math.max(max_width, 1)
        height = math.max(math.floor(width / cell_aspect_ratio), 1)
    end

    return width, height
end

local function native_image_opts(preview_win, width, height)
    local state = context.get_state()
    local config = context.get_config()
    local win_pos = vim.api.nvim_win_get_position(preview_win)
    local image_y = math.max((state.preview_text_line_count or 1) + (config.preview.image_gap_lines or 0) - 1, 0)

    return {
        row = win_pos[1] + image_y + 1,
        col = win_pos[2] + 1,
        width = width,
        height = height,
    }
end

local function render_native_image(image_api, result, preview_win, width, height, data)
    data = data or read_file_bytes(result.output_png)
    local err = nil
    if type(data) ~= "string" then
        data, err = read_file_bytes(result.output_png)
    end
    if not data then
        util.notify(string.format("Failed to read preview image '%s': %s", result.output_png, err or "unknown error"), vim.log.levels.WARN)
        return
    end

    local image_width, image_height = read_png_size(data)
    width, height = fit_image_size(width, height, image_width, image_height)

    local id = image_api.set(data, native_image_opts(preview_win, width, height))
    context.get_state().image = { kind = "native", id = id }
end

function M.ensure_preview_window()
    local state = context.get_state()
    local config = context.get_config()

    if state.preview_win
        and vim.api.nvim_win_is_valid(state.preview_win)
        and state.preview_buf
        and vim.api.nvim_buf_is_valid(state.preview_buf)
    then
        return state.preview_win, state.preview_buf
    end

    local previous_win = vim.api.nvim_get_current_win()
    vim.cmd(config.preview.split_command)
    state.preview_win = vim.api.nvim_get_current_win()
    state.preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)

    local target_width = math.max(math.floor(vim.o.columns * config.preview.width_fraction), 30)
    pcall(vim.api.nvim_win_set_width, state.preview_win, target_width)

    vim.bo[state.preview_buf].buftype = "nofile"
    vim.bo[state.preview_buf].bufhidden = "hide"
    vim.bo[state.preview_buf].swapfile = false
    vim.bo[state.preview_buf].modifiable = false
    vim.bo[state.preview_buf].filetype = "shaderdebug"
    vim.api.nvim_buf_set_name(state.preview_buf, config.preview.buffer_name)
    vim.wo[state.preview_win].number = false
    vim.wo[state.preview_win].relativenumber = false
    vim.wo[state.preview_win].cursorline = false
    vim.wo[state.preview_win].signcolumn = "no"
    vim.wo[state.preview_win].foldcolumn = "0"
    vim.wo[state.preview_win].winfixwidth = true

    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout", "BufDelete" }, {
        buffer = state.preview_buf,
        once = true,
        callback = function()
            on_preview_closed("Auto preview disabled because preview buffer was closed")
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.preview_win),
        once = true,
        callback = function()
            on_preview_closed("Auto preview disabled because preview window was closed")
        end,
    })

    vim.keymap.set("n", "<CR>", function()
        require("shaderdebug").activate_preview_line()
    end, { buffer = state.preview_buf, silent = true, desc = "Edit shaderdebug input under cursor" })
    vim.keymap.set("n", "x", function()
        require("shaderdebug").clear_preview_line_input()
    end, { buffer = state.preview_buf, silent = true, desc = "Clear shaderdebug input under cursor" })
    vim.keymap.set("n", "r", function()
        require("shaderdebug").refresh_preview_context()
    end, { buffer = state.preview_buf, silent = true, desc = "Refresh shaderdebug preview" })
    vim.keymap.set("n", "<LeftMouse>", function()
        local mouse = vim.fn.getmousepos()
        if mouse.winid == state.preview_win and mouse.line > 0 then
            vim.api.nvim_set_current_win(state.preview_win)
            vim.api.nvim_win_set_cursor(state.preview_win, { mouse.line, math.max((mouse.column or 1) - 1, 0) })
            require("shaderdebug").activate_preview_line()
        end
    end, { buffer = state.preview_buf, silent = true, desc = "Click to edit shaderdebug input" })

    if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
    end

    return state.preview_win, state.preview_buf
end

local function set_preview_lines(lines, line_kinds, line_meta)
    local _, preview_buf = M.ensure_preview_window()
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(preview_buf, context.get_preview_ns(), 0, -1)

    for index, kind in ipairs(line_kinds or {}) do
        local hl = nil
        if kind == "header" then
            hl = "ShaderDebugHeader"
        elseif kind == "input_default" then
            hl = "ShaderDebugInputDefault"
        elseif kind == "input_override" then
            hl = "ShaderDebugInputOverride"
        elseif kind == "detail" then
            hl = "ShaderDebugInputDetail"
        elseif kind == "empty" then
            hl = "ShaderDebugInputEmpty"
        end

        if hl then
            vim.api.nvim_buf_add_highlight(preview_buf, context.get_preview_ns(), hl, index - 1, 0, -1)
        end

        local meta = line_meta and line_meta[index] or nil
        if meta and meta.name_start and meta.name_end then
            vim.api.nvim_buf_add_highlight(preview_buf, context.get_preview_ns(), "ShaderDebugInputName", index - 1, meta.name_start, meta.name_end)
        end
    end
end

function M.show_preview(result)
    local preview_win, preview_buf = M.ensure_preview_window()
    local state = context.get_state()
    local config = context.get_config()

    state.preview_context = M.result_context(result)
    state.preview_actions = {}

    local lines = {
        string.format("%s > %s", result.entry, result.expression),
        result.api,
    }
    local line_kinds = { "header", "detail" }
    local line_meta = {}

    if #result.resource_specs == 0 then
        lines[#lines + 1] = "- none"
        line_kinds[#line_kinds + 1] = "empty"
    else
        for _, spec in ipairs(result.resource_specs) do
            local line = input_store.input_summary_line(spec)
            lines[#lines + 1] = line
            line_kinds[#line_kinds + 1] = spec.source_label == "override" and "input_override" or "input_default"

            local line_index = #lines
            local name_start = line:find(spec.name, 1, true)
            if name_start then
                line_meta[line_index] = {
                    name_start = name_start - 1,
                    name_end = name_start - 1 + #spec.name,
                }
            end

            state.preview_actions[#lines] = { type = "input", spec = spec }
            for _, detail_line in ipairs(input_store.input_detail_lines(spec)) do
                lines[#lines + 1] = detail_line
                line_kinds[#line_kinds + 1] = "detail"
                state.preview_actions[#lines] = { type = "input", spec = spec }
            end
        end
    end

    state.preview_text_line_count = #lines

    local display_lines = vim.deepcopy(lines)
    for _ = 1, (config.preview.image_gap_lines or 0) do
        display_lines[#display_lines + 1] = ""
    end

    for _ = #line_kinds + 1, #display_lines do
        line_kinds[#line_kinds + 1] = "empty"
    end

    set_preview_lines(display_lines, line_kinds, line_meta)

    M.clear_image()
    if #vim.api.nvim_list_uis() == 0 then
        return
    end

    local image_api = load_image_api()
    if not image_api then
        return
    end

    local width = math.max(vim.api.nvim_win_get_width(preview_win) - 2, 12)
    local bottom_padding = config.preview.bottom_padding_lines or 0
    local height = math.max(
        vim.api.nvim_win_get_height(preview_win)
            - state.preview_text_line_count
            - (config.preview.image_gap_lines or 0)
            - bottom_padding,
        12
    )

    local image_data = nil
    local image_width = nil
    local image_height = nil
    if vim.fn.filereadable(result.output_png) == 1 then
        image_data = read_file_bytes(result.output_png)
        if type(image_data) == "string" then
            image_width, image_height = read_png_size(image_data)
        end
    end
    width, height = fit_image_size(width, height, image_width, image_height)

    if image_api.kind == "native" then
        render_native_image(image_api.api, result, preview_win, width, height, image_data)
        return
    end

    local image = state.image and state.image.handle or nil
    if not image then
        image = image_api.api.from_file(result.output_png, {
            id = "shaderdebug-preview",
            namespace = "shaderdebug",
            window = preview_win,
            buffer = preview_buf,
            inline = true,
            with_virtual_padding = true,
            x = 0,
            y = math.max(state.preview_text_line_count + (config.preview.image_gap_lines or 0) - 1, 0),
            width = width,
            height = height,
        })
        state.image = { kind = "plugin", handle = image }
    end

    if image then
        update_preview_image(image, result, preview_win, preview_buf, width, height)
        image:render()
    end
end

function M.close()
    local state = context.get_state()
    M.clear_image()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        pcall(vim.api.nvim_win_close, state.preview_win, true)
    end
    if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
        pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
    end
    state.preview_win = nil
    state.preview_buf = nil
    state.preview_context = nil
    state.preview_actions = {}
    state.preview_text_line_count = 0
end

return M
