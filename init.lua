local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")
local input_ui = require("shaderdebug.src.input_ui")
local preview = require("shaderdebug.src.preview")
local render = require("shaderdebug.src.render")
local util = require("shaderdebug.src.util")

local M = {}

local function disable_auto_preview(reason)
    local state = context.get_state()
    if state.timer then
        state.pending_request = nil
        state.timer:stop()
    end

    state.render_request_id = state.render_request_id + 1
    render.stop_active_process()

    if state.auto_enabled then
        state.auto_enabled = false
        if reason then
            util.notify(reason)
        end
    end
end

preview.setup({ on_preview_closed = disable_auto_preview })
render.setup({ show_preview = preview.show_preview })
input_ui.setup({ rerender_context = render.rerender_context })

function M.preview_current_line(opts)
    return render.preview_current_line(opts)
end

function M.show_inputs()
    local result, err = render.render_current_line({ skip_render = true, sync = true })
    if not result then
        util.notify(err, vim.log.levels.WARN)
        return nil, err
    end

    local lines = {
        string.format("API: %s", result.api),
        string.format("Expression: %s", result.expression),
        "Inputs:",
    }
    if #result.resource_specs == 0 then
        lines[#lines + 1] = "- none"
    else
        for _, spec in ipairs(result.resource_specs) do
            lines[#lines + 1] = input_store.input_summary_line(spec)
        end
    end

    util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return result
end

function M.set_image_input(name, path)
    local shader_key = input_store.shader_key_for_buffer(vim.api.nvim_get_current_buf())
    input_store.set_image_input_for(shader_key, name, path)
end

function M.set_images_input(name, paths)
    local shader_key = input_store.shader_key_for_buffer(vim.api.nvim_get_current_buf())
    input_store.set_images_input_for(shader_key, name, paths)
end

function M.set_data_input(name, argument)
    local value, err = input_store.parse_data_argument(argument)
    if not value then
        util.notify(err, vim.log.levels.ERROR)
        return nil, err
    end

    local shader_key = input_store.shader_key_for_buffer(vim.api.nvim_get_current_buf())
    return input_store.set_data_input_value_for(shader_key, name, value)
end

function M.clear_input(name)
    local shader_key = input_store.shader_key_for_buffer(vim.api.nvim_get_current_buf())
    input_store.clear_input_for(shader_key, name)
end

function M.refresh_preview_context()
    local preview_context = context.get_state().preview_context
    if not preview_context then
        util.notify("No preview context available", vim.log.levels.WARN)
        return nil
    end

    local started, err = render.rerender_context(preview_context)
    if not started then
        util.notify(err, vim.log.levels.WARN)
        return nil, err
    end

    return true
end

function M.activate_preview_line()
    local state = context.get_state()
    if not state.preview_buf or vim.api.nvim_get_current_buf() ~= state.preview_buf then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local action = state.preview_actions[line]
    if not action or action.type ~= "input" then
        return
    end

    local preview_context = state.preview_context or (state.last_result and preview.result_context(state.last_result))
    if not preview_context then
        util.notify("No preview context available", vim.log.levels.WARN)
        return
    end

    input_ui.edit_input_spec(action.spec, preview_context)
end

function M.clear_preview_line_input()
    local state = context.get_state()
    if not state.preview_buf or vim.api.nvim_get_current_buf() ~= state.preview_buf then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local action = state.preview_actions[line]
    if not action or action.type ~= "input" then
        return
    end

    local preview_context = state.preview_context or (state.last_result and preview.result_context(state.last_result))
    if not preview_context then
        util.notify("No preview context available", vim.log.levels.WARN)
        return
    end

    input_store.clear_input_for(preview_context.shader_key, action.spec.name)
    render.rerender_context(preview_context)
end

function M.toggle_auto_preview()
    local state = context.get_state()
    state.auto_enabled = not state.auto_enabled
    util.notify("Auto preview " .. (state.auto_enabled and "enabled" or "disabled"))
    if state.auto_enabled and vim.bo.filetype == "slang" then
        render.schedule_preview(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
    else
        disable_auto_preview()
    end
end

function M.clear_preview()
    disable_auto_preview()
    preview.close()
end

function M.get_api()
    return context.detect_api()
end

function M.open_test_shader()
    local path = "/tmp/shaderdebug_test.slang"
    local lines = {
        "Texture2D<float4> scene_color;",
        "SamplerState scene_sampler;",
        "StructuredBuffer<float4> debug_points;",
        "struct Globals {",
        "    float4 tint;",
        "    float time;",
        "    float _padding0;",
        "    float2 resolution;",
        "};",
        "ConstantBuffer<Globals> globals;",
        "",
        "struct FragmentInput {",
        "    float4 position : SV_Position;",
        "    float2 uv : TEXCOORD0;",
        "    float3 world_pos : TEXCOORD1;",
        "};",
        "",
        "float3 shadeHelper(float2 uv, float wave)",
        "{",
        "    return float3(uv.x, uv.y, wave);",
        "}",
        "",
        "[shader(\"fragment\")]",
        "float4 fsMain(FragmentInput input) : SV_Target",
        "{",
        "    float2 uv = input.uv;",
        "    float wave = 0.5 + 0.5 * sin(globals.time + input.world_pos.x * 6.0);",
        "    shadeHelper(uv, wave);",
        "    float3 baseColor = float3(uv.x, uv.y, wave);",
        "    float4 sampled = scene_color.Sample(scene_sampler, uv);",
        "    float3 finalColor = lerp(baseColor * globals.tint.xyz, sampled.xyz, globals.tint.w);",
        "    return float4(finalColor, 1.0);",
        "}",
    }

    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "slang"
    util.notify("Wrote test shader to " .. path)
end

function M.get_last_result()
    return context.get_state().last_result
end

function M.setup(user_config)
    context.setup(user_config)
    context.setup_preview_highlights()

    local state = context.get_state()
    state.augroup = vim.api.nvim_create_augroup("ShaderDebugPreview", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "TextChanged", "TextChangedI", "BufEnter" }, {
        group = state.augroup,
        callback = function(args)
            if vim.bo[args.buf].filetype == "slang" then
                render.schedule_preview(args.buf, vim.api.nvim_win_get_cursor(0)[1])
            end
        end,
    })

    vim.api.nvim_create_user_command("ShaderDebugPreview", function()
        M.preview_current_line()
    end, { desc = "Render shader output for the current Slang line" })

    vim.api.nvim_create_user_command("ShaderDebugToggleAuto", function()
        M.toggle_auto_preview()
    end, { desc = "Toggle automatic shader debug preview" })

    vim.api.nvim_create_user_command("ShaderDebugInputs", function()
        M.show_inputs()
    end, { desc = "Show reflected inputs for the current debug expression" })

    vim.api.nvim_create_user_command("ShaderDebugSetImage", function(opts)
        if #opts.fargs < 2 then
            util.notify("Usage: ShaderDebugSetImage <name> <path>", vim.log.levels.ERROR)
            return
        end
        M.set_image_input(opts.fargs[1], opts.fargs[2])
    end, { nargs = "+", desc = "Bind a single image input by reflected name" })

    vim.api.nvim_create_user_command("ShaderDebugSetImages", function(opts)
        if #opts.fargs < 2 then
            util.notify("Usage: ShaderDebugSetImages <name> <path1,path2,...>", vim.log.levels.ERROR)
            return
        end
        M.set_images_input(opts.fargs[1], table.concat(vim.list_slice(opts.fargs, 2), " "))
    end, { nargs = "+", desc = "Bind an image array input by reflected name" })

    vim.api.nvim_create_user_command("ShaderDebugSetData", function(opts)
        if #opts.fargs < 2 then
            util.notify("Usage: ShaderDebugSetData <name> <json|@file>", vim.log.levels.ERROR)
            return
        end
        M.set_data_input(opts.fargs[1], table.concat(vim.list_slice(opts.fargs, 2), " "))
    end, { nargs = "+", desc = "Bind JSON data for a uniform/storage buffer input" })

    vim.api.nvim_create_user_command("ShaderDebugClearInput", function(opts)
        if #opts.fargs ~= 1 then
            util.notify("Usage: ShaderDebugClearInput <name>", vim.log.levels.ERROR)
            return
        end
        M.clear_input(opts.fargs[1])
    end, { nargs = 1, desc = "Clear a reflected input override" })

    vim.api.nvim_create_user_command("ShaderDebugOpenTestShader", function()
        M.open_test_shader()
    end, { desc = "Create and open a test shader in /tmp" })

    vim.api.nvim_create_user_command("ShaderDebugClear", function()
        M.clear_preview()
    end, { desc = "Clear shader debug preview" })
end

return M
