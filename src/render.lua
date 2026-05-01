local uv = vim.uv

local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")
local reflection = require("shaderdebug.src.reflection")
local source = require("shaderdebug.src.source")
local util = require("shaderdebug.src.util")

local M = {}

local show_preview = function() end
local get_preview_render_target = function()
    return { mode = "file" }
end

function M.setup(opts)
    show_preview = opts and opts.show_preview or show_preview
    get_preview_render_target = opts and opts.get_preview_render_target or get_preview_render_target
end

local function normalize_render_target(target, output_png)
    local mode = type(target) == "table" and target.mode or "file"
    return {
        mode = mode == "memory" and "memory" or "file",
        output_png = output_png,
    }
end

local function build_render_result(request, fragment_output, vertex_output, manifest_path, resource_specs)
    return {
        api = request.api,
        entry = request.payload.entry,
        expression = request.payload.expression,
        cursor_line = request.cursor_line,
        bufnr = request.bufnr,
        shader_key = request.shader_key,
        output_mode = request.render_target.mode,
        output_png = request.output_png,
        output_png_data = nil,
        temp_source = request.temp_source,
        fragment_spv = fragment_output,
        vertex_spv = vertex_output,
        manifest_path = manifest_path,
        resource_specs = resource_specs,
    }
end

local function apply_render_output(result, render_target, process_result)
    if render_target.mode ~= "memory" then
        return true
    end

    local data = process_result and process_result.stdout or nil
    if type(data) ~= "string" or data == "" then
        return nil, "Renderer returned no PNG bytes"
    end

    result.output_png_data = data
    return true
end

function M.current_cursor_line_for_buffer(bufnr)
    local current_buf = vim.api.nvim_get_current_buf()
    if current_buf == bufnr then
        return vim.api.nvim_win_get_cursor(0)[1]
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        return vim.api.nvim_win_get_cursor(winid)[1]
    end

    return 1
end

function M.stop_active_process()
    local state = context.get_state()
    if state.active_process then
        pcall(state.active_process.kill, state.active_process, 15)
        state.active_process = nil
    end
end

function M.rerender_context(preview_context)
    if not preview_context or not preview_context.bufnr or not vim.api.nvim_buf_is_valid(preview_context.bufnr) then
        return nil, "Source shader buffer is no longer valid"
    end

    return M.start_preview_job({
        bufnr = preview_context.bufnr,
        cursor_line = preview_context.cursor_line,
    })
end

local function prepare_render_request(opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "slang" then
        return nil, "Current buffer is not a Slang file"
    end

    local cursor_line = opts.cursor_line or M.current_cursor_line_for_buffer(bufnr)
    local payload, err = source.build_instrumented_source(bufnr, cursor_line)
    if not payload then
        return nil, err
    end

    local temp_source, output_png, prefix = source.write_temp_source(bufnr, payload)
    if not temp_source then
        return nil, output_png
    end

    local shader_key = input_store.shader_key_for_buffer(bufnr)
    local api = context.detect_api()
    if util.ensure_runner(api) ~= true then
        return nil, "Renderer build failed"
    end

    local render_target = normalize_render_target(get_preview_render_target(), output_png)

    return {
        api = api,
        opts = opts,
        bufnr = bufnr,
        cursor_line = cursor_line,
        payload = payload,
        temp_source = temp_source,
        output_png = output_png,
        prefix = prefix,
        shader_key = shader_key,
        render_target = render_target,
    }
end

function M.render_current_line(opts)
    local request, request_err = prepare_render_request(opts)
    if not request then
        return nil, request_err
    end

    local fragment_output, reflection_path_or_err = reflection.compile_fragment_artifact(
        request.temp_source,
        request.prefix,
        request.payload.entry,
        request.api
    )
    if not fragment_output then
        local label = request.api == "opengl" and "GLSL" or "SPIR-V"
        return nil, string.format("Slang %s compile failed:\n%s", label, reflection_path_or_err)
    end

    local reflect_data, reflect_err = reflection.parse_reflection(reflection_path_or_err)
    if not reflect_data then
        return nil, "Failed to parse reflection:\n" .. reflect_err
    end

    local entry = reflection.find_entry_reflection(reflect_data, request.payload.entry)
    if not entry then
        return nil, "No fragment entry reflection found for " .. request.payload.entry
    end

    local vertex_glsl, vertex_err = reflection.build_vertex_glsl(entry, request.api)
    if not vertex_glsl then
        return nil, vertex_err
    end

    local vertex_output, vertex_output_err = reflection.build_vertex_artifact(vertex_glsl, request.prefix, request.api)
    if not vertex_output then
        local label = request.api == "opengl" and "GLSL" or "SPIR-V"
        return nil, string.format("Vertex %s build failed:\n%s", label, vertex_output_err)
    end

    local specs = reflection.collect_resource_specs(reflect_data, entry)
    local render_context = {
        image_size = context.get_config().image_size,
        shader_key = request.shader_key,
    }
    local manifest_path, prepared_specs_or_err = input_store.prepare_manifest(specs, request.shader_key, request.prefix, render_context)
    if not manifest_path then
        return nil, "Failed to prepare inputs:\n" .. prepared_specs_or_err
    end

    local result = build_render_result(request, fragment_output, vertex_output, manifest_path, prepared_specs_or_err)

    if not request.opts.skip_render then
        local render_output, render_err = reflection.render_preview(
            request.api,
            vertex_output,
            fragment_output,
            manifest_path,
            request.render_target,
            request.payload.entry
        )
        if not render_output then
            local label = request.api == "opengl" and "OpenGL" or "Vulkan"
            return nil, string.format("%s preview render failed:\n%s", label, render_err)
        end

        local ok, output_err = apply_render_output(result, request.render_target, render_output)
        if not ok then
            local label = request.api == "opengl" and "OpenGL" or "Vulkan"
            return nil, string.format("%s preview render failed:\n%s", label, output_err)
        end
    end

    context.get_state().last_result = result
    return result
end

function M.start_preview_job(opts, on_complete)
    local request, request_err = prepare_render_request(opts)
    if not request then
        if on_complete then
            on_complete(nil, request_err)
        end
        return nil, request_err
    end

    local state = context.get_state()
    state.render_request_id = state.render_request_id + 1
    local request_id = state.render_request_id
    M.stop_active_process()
    local opts_for_job = request.opts or {}

    local function is_current()
        return request_id == state.render_request_id
    end

    local function finish(result, err)
        if not is_current() then
            return
        end

        state.active_process = nil
        if result then
            state.last_result = result
            if not opts_for_job.skip_preview and not opts_for_job.skip_render then
                show_preview(result)
            end
        elseif err and not opts_for_job.silent and not err:match("Cursor line must") then
            util.notify(err, vim.log.levels.WARN)
        end

        if on_complete then
            on_complete(result, err)
        end
    end

    local function spawn(cmd, system_opts, err_prefix, next_step)
        if not is_current() then
            return
        end

        state.active_process = util.system_start(cmd, system_opts, function(result)
            if not is_current() then
                return
            end

            state.active_process = nil
            if result.code ~= 0 then
                finish(nil, err_prefix .. util.command_error(result))
                return
            end

            next_step(result)
        end)
    end

    local api = request.api
    local fragment_spec = reflection.fragment_compile_spec(request.temp_source, request.prefix, request.payload.entry, api)
    spawn(
        fragment_spec.command,
        nil,
        string.format("Slang %s compile failed:\n", api == "opengl" and "GLSL" or "SPIR-V"),
        function()
            if api == "opengl" then
                local ok, glsl_err = reflection.adapt_opengl_fragment_glsl(fragment_spec.fragment_output)
                if not ok then
                    finish(nil, "Failed to adapt OpenGL GLSL:\n" .. glsl_err)
                    return
                end
            end

            local reflect_data, reflect_err = reflection.parse_reflection(fragment_spec.reflection_json)
            if not reflect_data then
                finish(nil, "Failed to parse reflection:\n" .. reflect_err)
                return
            end

            local entry = reflection.find_entry_reflection(reflect_data, request.payload.entry)
            if not entry then
                finish(nil, "No fragment entry reflection found for " .. request.payload.entry)
                return
            end

            local vertex_glsl, vertex_err = reflection.build_vertex_glsl(entry, api)
            if not vertex_glsl then
                finish(nil, vertex_err)
                return
            end

            local vertex_spec = reflection.vertex_compile_spec(request.prefix, api)
            local ok, write_err = util.write_text(vertex_spec.source_path, vertex_glsl)
            if not ok then
                finish(nil, write_err)
                return
            end

            local specs = reflection.collect_resource_specs(reflect_data, entry)
            local render_context = {
                image_size = context.get_config().image_size,
                shader_key = request.shader_key,
            }
            local manifest_path, prepared_specs_or_err = input_store.prepare_manifest(specs, request.shader_key, request.prefix, render_context)
            if not manifest_path then
                finish(nil, "Failed to prepare inputs:\n" .. prepared_specs_or_err)
                return
            end

            local result = build_render_result(
                request,
                fragment_spec.fragment_output,
                vertex_spec.output_path,
                manifest_path,
                prepared_specs_or_err
            )

            if opts_for_job.skip_render then
                finish(result, nil)
                return
            end

            local function spawn_render()
                spawn(
                    reflection.render_command_spec(
                        api,
                        vertex_spec.output_path,
                        fragment_spec.fragment_output,
                        manifest_path,
                        request.render_target,
                        request.payload.entry
                    ),
                    reflection.render_command_opts(request.render_target),
                    string.format("%s preview render failed:\n", api == "opengl" and "OpenGL" or "Vulkan"),
                    function(render_output)
                        local ok, output_err = apply_render_output(result, request.render_target, render_output)
                        if not ok then
                            finish(nil, string.format("%s preview render failed:\n%s", api == "opengl" and "OpenGL" or "Vulkan", output_err))
                            return
                        end

                        finish(result, nil)
                    end
                )
            end

            if vertex_spec.command then
                spawn(
                    vertex_spec.command,
                    nil,
                    string.format("Vertex %s build failed:\n", api == "opengl" and "GLSL" or "SPIR-V"),
                    spawn_render
                )
            else
                spawn_render()
            end
        end
    )

    return true
end

function M.schedule_preview(bufnr, cursor_line)
    local state = context.get_state()
    if not state.auto_enabled then
        return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "slang" then
        return
    end

    local request = {
        bufnr = bufnr,
        cursor_line = cursor_line or M.current_cursor_line_for_buffer(bufnr),
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    }
    state.pending_request = request

    if not state.timer then
        state.timer = uv.new_timer()
    end

    state.timer:stop()
    state.timer:start(context.get_config().debounce_ms, 0, vim.schedule_wrap(function()
        if state.pending_request ~= request then
            return
        end
        if not vim.api.nvim_buf_is_valid(request.bufnr) or vim.bo[request.bufnr].filetype ~= "slang" then
            return
        end

        M.start_preview_job({ bufnr = request.bufnr, cursor_line = request.cursor_line, silent = true }, function(_, err)
            if err and not err:match("Cursor line must") then
                util.notify(err, vim.log.levels.WARN)
            end
        end)
    end))
end

function M.preview_current_line(opts)
    opts = opts or {}
    if opts.sync or opts.skip_render then
        local result, err = M.render_current_line(opts)
        if not result then
            if not opts.silent then
                util.notify(err, vim.log.levels.WARN)
            end
            return nil, err
        end

        if not opts.skip_preview and not opts.skip_render then
            show_preview(result)
        end

        return result
    end

    local started, err = M.start_preview_job(opts)
    if not started then
        if not opts.silent then
            util.notify(err, vim.log.levels.WARN)
        end
        return nil, err
    end

    return true
end

return M
