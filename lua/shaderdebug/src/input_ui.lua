local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")
local preview = require("shaderdebug.src.preview")
local util = require("shaderdebug.src.util")

local M = {}
local modal_hl_ns = vim.api.nvim_create_namespace("shaderdebug-modal")
local preview_hidden = false
local preview_restore_pending = false

local rerender_context = function()
    return nil, "No rerender callback configured"
end

local function highlight_bg(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok or type(hl) ~= "table" then
        return nil
    end

    return hl.bg
end

local function highlight_def(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok or type(hl) ~= "table" then
        return {}
    end

    return hl
end

local function ensure_modal_highlights()
    local bg = highlight_bg("NormalFloat") or highlight_bg("Normal") or 0
    local normal = highlight_def("NormalFloat")
    local border = highlight_def("FloatBorder")
    local pmenu = highlight_def("Pmenu")
    local pmenu_sel = highlight_def("PmenuSel")

    vim.api.nvim_set_hl(modal_hl_ns, "Normal", {
        fg = normal.fg,
        bg = bg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "NormalFloat", {
        fg = normal.fg,
        bg = bg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "FloatBorder", {
        bg = bg,
        fg = border.fg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "FloatTitle", {
        bg = bg,
        fg = border.fg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "FloatFooter", {
        bg = bg,
        fg = border.fg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "Pmenu", {
        fg = pmenu.fg or normal.fg,
        bg = bg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "PmenuSel", {
        fg = pmenu_sel.fg or pmenu.fg or normal.fg,
        bg = pmenu_sel.bg or bg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "PmenuSbar", {
        bg = bg,
    })
    vim.api.nvim_set_hl(modal_hl_ns, "PmenuThumb", {
        bg = border.fg or normal.fg,
    })
end

local function apply_opaque_modal_style(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end

    local config = vim.api.nvim_win_get_config(win)
    if not config or config.relative == "" then
        return
    end

    ensure_modal_highlights()
    vim.wo[win].winblend = 0
    pcall(vim.api.nvim_win_set_hl_ns, win, modal_hl_ns)
end

local function style_new_float_windows(open_fn)
    local before = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        before[win] = true
    end

    open_fn()

    vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if not before[win] then
                apply_opaque_modal_style(win)
            end
        end
    end)
end

local function has_floating_windows()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(win)
        if config and config.relative and config.relative ~= "" then
            return true
        end
    end

    return false
end

local function schedule_preview_restore(preview_context)
    if not preview_context or not preview_hidden or preview_restore_pending then
        return
    end

    preview_restore_pending = true

    local function try_restore()
        if has_floating_windows() then
            vim.defer_fn(try_restore, 25)
            return
        end

        preview_restore_pending = false
        preview_hidden = false
        preview.set_image_suspended(false)
        preview.set_native_image_suspended(false)
        rerender_context(preview_context)
    end

    vim.defer_fn(try_restore, 25)
end

local function suspend_preview_image(preview_context)
    local state = context.get_state()
    if not preview_context then
        return false
    end

    if preview_hidden then
        return true
    end

    if not state.image then
        return false
    end

    preview.set_image_suspended(true)
    preview.set_native_image_suspended(true)
    preview_hidden = true
    return true
end

function M.setup(opts)
    rerender_context = opts and opts.rerender_context or rerender_context
end

local function encode_json_pretty(value, indent)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local next_pad = string.rep("  ", indent + 1)
    local value_type = type(value)

    if value_type == "nil" then
        return "null"
    elseif value_type == "boolean" or value_type == "number" then
        return tostring(value)
    elseif value_type == "string" then
        return vim.json.encode(value)
    elseif value_type ~= "table" then
        return vim.json.encode(tostring(value))
    end

    if input_store.table_is_array(value) then
        if #value == 0 then
            return "[]"
        end

        local parts = {}
        for _, item in ipairs(value) do
            parts[#parts + 1] = next_pad .. encode_json_pretty(item, indent + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end

    local keys = vim.tbl_keys(value)
    table.sort(keys)
    if #keys == 0 then
        return "{}"
    end

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = next_pad .. vim.json.encode(key) .. ": " .. encode_json_pretty(value[key], indent + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

local function open_json_input_editor(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)
    local value = (current and current.kind == "data" and current.value) or input_store.default_json_for_spec(spec)
    local text = encode_json_pretty(value)
    local state = context.get_state()

    vim.cmd("belowright split")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "json"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(buf, string.format("shaderdebug://input/%s", spec.name))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))

    state.input_editors[buf] = {
        spec = spec,
        preview_context = preview_context,
    }

    vim.keymap.set("n", "q", function()
        if vim.bo[buf].modified then
            util.notify("Input buffer has unsaved changes", vim.log.levels.WARN)
            return
        end
        pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, silent = true, desc = "Close shaderdebug input editor" })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function(args)
            local session = context.get_state().input_editors[args.buf]
            if not session then
                return
            end

            local content = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false), "\n")
            local ok, decoded = pcall(vim.json.decode, content)
            if not ok then
                util.notify("Invalid JSON: " .. decoded, vim.log.levels.ERROR)
                return
            end

            input_store.set_data_input_value_for(session.preview_context.shader_key, session.spec.name, decoded)
            vim.bo[args.buf].modified = false
            rerender_context(session.preview_context)
        end,
    })

    util.notify("Edit JSON and :write to apply")
end

local function prompt_image_input(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)
    local default_value = current and current.values and table.concat(current.values, ",") or ""
    local prompt = spec.is_array and ("Image paths for " .. spec.name .. " (comma-separated): ")
        or ("Image path for " .. spec.name .. ": ")
    local hidden_preview = suspend_preview_image(preview_context)

    style_new_float_windows(function()
        vim.ui.input({ prompt = prompt, default = default_value }, function(input)
            if not input or util.trim(input) == "" then
                if hidden_preview then
                    schedule_preview_restore(preview_context)
                end
                return
            end
            if spec.is_array then
                input_store.set_images_input_for(shader_key, spec.name, input)
            else
                input_store.set_image_input_for(shader_key, spec.name, util.trim(input))
            end
            if hidden_preview then
                schedule_preview_restore(preview_context)
            else
                rerender_context(preview_context)
            end
        end)
    end)
end

local function prompt_sampler_input(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)
    local hidden_preview = suspend_preview_image(preview_context)

    style_new_float_windows(function()
        vim.ui.select({ "linear", "nearest", "clear override" }, {
            prompt = string.format("Sampler mode for %s", spec.name),
            format_item = function(item)
                if item == "clear override" then
                    return item
                end
                local marker = current and current.mode == item and " (current)" or ""
                return item .. marker
            end,
        }, function(choice)
            if not choice then
                if hidden_preview then
                    schedule_preview_restore(preview_context)
                end
                return
            end
            if choice == "clear override" then
                input_store.clear_input_for(shader_key, spec.name)
            else
                input_store.get_input_store(shader_key)[spec.name] = { kind = "sampler", mode = choice }
                util.notify(string.format("Bound sampler '%s' -> %s", spec.name, choice))
            end
            if hidden_preview then
                schedule_preview_restore(preview_context)
            else
                rerender_context(preview_context)
            end
        end)
    end)
end

function M.edit_input_spec(spec, preview_context)
    local actions = {}
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        actions = {
            { key = "set", label = spec.is_array and "Set image paths" or "Set image path" },
            { key = "clear", label = "Use default" },
        }
    elseif spec.kind == "sampler" then
        actions = {
            { key = "set", label = "Choose sampler mode" },
            { key = "clear", label = "Use default" },
        }
    elseif spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
        actions = {
            { key = "edit", label = "Edit JSON in split" },
            { key = "load", label = "Load JSON from file" },
            { key = "clear", label = "Use default" },
        }
    else
        util.notify("No editor available for " .. spec.kind, vim.log.levels.WARN)
        return
    end

    local hidden_preview = suspend_preview_image(preview_context)

    style_new_float_windows(function()
        vim.ui.select(actions, {
            prompt = string.format("Input actions for %s", spec.name),
            format_item = function(item)
                return item.label
            end,
        }, function(choice)
            if not choice then
                if hidden_preview then
                    schedule_preview_restore(preview_context)
                end
                return
            end

            if choice.key == "clear" then
                input_store.clear_input_for(preview_context.shader_key, spec.name)
                if hidden_preview then
                    schedule_preview_restore(preview_context)
                else
                    rerender_context(preview_context)
                end
                return
            end

            if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
                prompt_image_input(spec, preview_context)
                return
            end

            if spec.kind == "sampler" then
                prompt_sampler_input(spec, preview_context)
                return
            end

            if choice.key == "edit" then
                open_json_input_editor(spec, preview_context)
                if hidden_preview then
                    schedule_preview_restore(preview_context)
                end
                return
            end

            if choice.key == "load" then
                style_new_float_windows(function()
                    vim.ui.input({ prompt = "JSON file path for " .. spec.name .. ": " }, function(input)
                        if not input or util.trim(input) == "" then
                            if hidden_preview then
                                schedule_preview_restore(preview_context)
                            end
                            return
                        end
                        local value, err = input_store.parse_data_argument(input)
                        if not value then
                            util.notify(err, vim.log.levels.ERROR)
                            if hidden_preview then
                                schedule_preview_restore(preview_context)
                            end
                            return
                        end
                        input_store.set_data_input_value_for(preview_context.shader_key, spec.name, value)
                        if hidden_preview then
                            schedule_preview_restore(preview_context)
                        else
                            rerender_context(preview_context)
                        end
                    end)
                end)
            end
        end)
    end)
end

return M
