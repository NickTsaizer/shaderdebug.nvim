local context = require("shaderdebug.src.context")
local util = require("shaderdebug.src.util")

local M = {}

function M.parse_reflection(path)
    local content = util.read_text(path)
    if not content then
        return nil, "Failed to read reflection JSON"
    end

    local ok, decoded = pcall(vim.json.decode, content)
    if not ok then
        return nil, decoded
    end

    return decoded
end

function M.find_entry_reflection(reflection, entry_name)
    for _, entry in ipairs(reflection.entryPoints or {}) do
        if entry.name == entry_name then
            return entry
        end
    end

    for _, entry in ipairs(reflection.entryPoints or {}) do
        if entry.stage == "fragment" then
            return entry
        end
    end

    return nil
end

local function binding_map(entry)
    local map = {}
    for _, binding in ipairs(entry.bindings or {}) do
        if binding.name and binding.binding and (binding.binding.used == nil or binding.binding.used ~= 0) then
            map[binding.name] = binding.binding
        end
    end
    return map
end

local function reflection_resource_spec(parameter, used_binding)
    local typeinfo = parameter.type or {}
    local spec = {
        name = parameter.name,
        set = (used_binding and used_binding.space) or (parameter.binding and parameter.binding.space) or 0,
        binding = (used_binding and used_binding.index) or (parameter.binding and parameter.binding.index) or 0,
        used = true,
        raw_type = typeinfo,
    }

    if typeinfo.kind == "constantBuffer" then
        spec.kind = "uniform_buffer"
        spec.type_info = typeinfo.elementType
        spec.layout_binding = typeinfo.elementVarLayout and typeinfo.elementVarLayout.binding or nil
        return spec
    end

    if typeinfo.kind == "resource" and typeinfo.baseShape == "structuredBuffer" then
        spec.kind = "storage_buffer"
        spec.type_info = typeinfo.resultType
        spec.is_array = true
        return spec
    end

    if typeinfo.kind == "resource" and typeinfo.baseShape == "texture2D" then
        spec.kind = typeinfo.combined and "combined_image_sampler" or "sampled_image"
        spec.type_info = typeinfo
        spec.descriptor_count = 1
        return spec
    end

    if typeinfo.kind == "samplerState" then
        spec.kind = "sampler"
        spec.type_info = typeinfo
        spec.descriptor_count = 1
        return spec
    end

    if typeinfo.kind == "array"
        and typeinfo.elementType
        and typeinfo.elementType.kind == "resource"
        and typeinfo.elementType.baseShape == "texture2D"
    then
        spec.kind = typeinfo.elementType.combined and "combined_image_sampler" or "sampled_image"
        spec.type_info = typeinfo.elementType
        spec.is_array = true
        spec.descriptor_count = math.max(typeinfo.elementCount or 0, 1)
        return spec
    end

    return nil
end

function M.collect_resource_specs(reflection, entry)
    local specs = {}
    local used_map = binding_map(entry)

    for _, parameter in ipairs(reflection.parameters or {}) do
        local used_binding = used_map[parameter.name]
        if used_binding then
            local spec = reflection_resource_spec(parameter, used_binding)
            if spec then
                table.insert(specs, spec)
            end
        end
    end

    table.sort(specs, function(a, b)
        if a.set == b.set then
            return a.binding < b.binding
        end
        return a.set < b.set
    end)

    return specs
end

local function glsl_type_for_type(typeinfo)
    local kind = typeinfo.kind
    if kind == "scalar" then
        local scalar = typeinfo.scalarType
        if scalar == "float32" then
            return "float"
        elseif scalar == "int32" then
            return "int"
        elseif scalar == "uint32" then
            return "uint"
        elseif scalar == "bool" then
            return "bool"
        end
    elseif kind == "vector" then
        local scalar = typeinfo.elementType and typeinfo.elementType.scalarType
        local count = typeinfo.elementCount or 1
        if scalar == "float32" then
            return ({ [2] = "vec2", [3] = "vec3", [4] = "vec4" })[count]
        elseif scalar == "int32" then
            return ({ [2] = "ivec2", [3] = "ivec3", [4] = "ivec4" })[count]
        elseif scalar == "uint32" then
            return ({ [2] = "uvec2", [3] = "uvec3", [4] = "uvec4" })[count]
        elseif scalar == "bool" then
            return ({ [2] = "bvec2", [3] = "bvec3", [4] = "bvec4" })[count]
        end
    end

    return nil
end

local function default_glsl_expr(typeinfo, location, name)
    local kind = typeinfo.kind
    local scalar = typeinfo.scalarType or (typeinfo.elementType and typeinfo.elementType.scalarType)
    local uv = "shaderdebug_uv"
    local centered = "shaderdebug_centered"

    if kind == "scalar" then
        if scalar == "float32" then
            if name == "plane_coord" then
                return "0.0"
            end
            return uv .. ".x"
        elseif scalar == "int32" then
            return "int(floor(" .. uv .. ".x * 4.0))"
        elseif scalar == "uint32" then
            return "uint(floor(" .. uv .. ".x * 4.0))"
        elseif scalar == "bool" then
            return uv .. ".x > 0.5"
        end
    elseif kind == "vector" then
        local count = typeinfo.elementCount or 1
        if scalar == "float32" then
            if count == 2 then
                return uv
            elseif count == 3 then
                if name == "world_pos" then
                    return "vec3(" .. centered .. ", 0.0)"
                end
                return "vec3(" .. uv .. ", 1.0)"
            elseif count == 4 then
                return "vec4(" .. uv .. ", 0.0, 1.0)"
            end
        elseif scalar == "int32" then
            if count == 2 then
                return "ivec2(floor(" .. uv .. " * 8.0))"
            elseif count == 3 then
                return "ivec3(int(floor(" .. uv .. ".x * 8.0)), int(floor(" .. uv .. ".y * 8.0)), " .. tostring(location) .. ")"
            elseif count == 4 then
                return "ivec4(int(floor(" .. uv .. ".x * 8.0)), int(floor(" .. uv .. ".y * 8.0)), " .. tostring(location) .. ", 1)"
            end
        elseif scalar == "uint32" then
            if count == 2 then
                return "uvec2(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)))"
            elseif count == 3 then
                return "uvec3(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)), uint(" .. tostring(location) .. "))"
            elseif count == 4 then
                return "uvec4(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)), uint(" .. tostring(location) .. "), 1u)"
            end
        elseif scalar == "bool" then
            if count == 2 then
                return "bvec2(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5)"
            elseif count == 3 then
                return "bvec3(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5, true)"
            elseif count == 4 then
                return "bvec4(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5, true, true)"
            end
        end
    end

    return nil
end

local function collect_fragment_varyings(entry)
    local varyings = {}

    local function push(name, typeinfo, binding)
        if binding and binding.kind == "varyingInput" and binding.index ~= nil then
            varyings[#varyings + 1] = {
                name = name,
                type = typeinfo,
                location = binding.index,
            }
        end
    end

    for _, parameter in ipairs(entry.parameters or {}) do
        local typeinfo = parameter.type or {}
        if typeinfo.kind == "struct" then
            for _, field in ipairs(typeinfo.fields or {}) do
                push(field.name, field.type, field.binding)
            end
        else
            push(parameter.name, typeinfo, parameter.binding)
        end
    end

    table.sort(varyings, function(a, b)
        return a.location < b.location
    end)

    local deduped = {}
    local by_location = {}
    for _, varying in ipairs(varyings) do
        if not by_location[varying.location] then
            by_location[varying.location] = true
            table.insert(deduped, varying)
        end
    end

    return deduped
end

function M.build_vertex_glsl(entry, api)
    local varyings = collect_fragment_varyings(entry)
    local vertex_index = api == "opengl" and "gl_VertexID" or "gl_VertexIndex"
    local lines = { "#version 450" }

    for _, varying in ipairs(varyings) do
        local glsl_type = glsl_type_for_type(varying.type)
        if not glsl_type then
            return nil, string.format("Unsupported fragment varying type for '%s'", varying.name)
        end
        table.insert(lines, string.format("layout(location = %d) out %s v_%d;", varying.location, glsl_type, varying.location))
    end

    vim.list_extend(lines, {
        "vec2 shaderdebug_positions[3] = vec2[](",
        "    vec2(-1.0, -1.0),",
        "    vec2( 3.0, -1.0),",
        "    vec2(-1.0,  3.0)",
        ");",
        "void main()",
        "{",
        string.format("    vec2 pos = shaderdebug_positions[%s];", vertex_index),
        "    gl_Position = vec4(pos, 0.0, 1.0);",
        "    vec2 shaderdebug_uv = pos * 0.5 + 0.5;",
        "    vec2 shaderdebug_centered = shaderdebug_uv * 2.0 - 1.0;",
    })

    for _, varying in ipairs(varyings) do
        local expr = default_glsl_expr(varying.type, varying.location, varying.name)
        if not expr then
            return nil, string.format("Unsupported varying default expression for '%s'", varying.name)
        end
        table.insert(lines, string.format("    v_%d = %s;", varying.location, expr))
    end

    table.insert(lines, "}")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

function M.build_vertex_artifact(vertex_glsl, prefix, api)
    local source_path = prefix .. ".vert.glsl"
    local ok, err = util.write_text(source_path, vertex_glsl)
    if not ok then
        return nil, err
    end

    if api == "opengl" then
        return source_path
    end

    local output_path = prefix .. ".vert.spv"
    local result = util.system_wait({
        context.get_config().glslang_validator,
        "-V",
        "--target-env",
        "vulkan1.2",
        "-S",
        "vert",
        "-o",
        output_path,
        source_path,
    })

    if result.code ~= 0 then
        return nil, util.command_error(result)
    end

    return output_path
end

function M.fragment_compile_spec(temp_source, prefix, entry, api)
    local config = context.get_config()
    if api == "opengl" then
        return {
            fragment_output = prefix .. ".frag.glsl",
            reflection_json = prefix .. ".reflect.json",
            command = {
                config.slangc,
                "-target",
                "glsl",
                "-profile",
                config.opengl_profile,
                "-entry",
                entry,
                "-stage",
                "fragment",
                "-reflection-json",
                prefix .. ".reflect.json",
                temp_source,
                "-o",
                prefix .. ".frag.glsl",
            },
        }
    end

    return {
        fragment_output = prefix .. ".frag.spv",
        reflection_json = prefix .. ".reflect.json",
        command = {
            config.slangc,
            "-target",
            "spirv",
            "-profile",
            config.slang_profile,
            "-fvk-use-entrypoint-name",
            "-fvk-use-scalar-layout",
            "-entry",
            entry,
            "-stage",
            "fragment",
            "-reflection-json",
            prefix .. ".reflect.json",
            temp_source,
            "-o",
            prefix .. ".frag.spv",
        },
    }
end

function M.vertex_compile_spec(prefix, api)
    if api == "opengl" then
        return {
            source_path = prefix .. ".vert.glsl",
            output_path = prefix .. ".vert.glsl",
            command = nil,
        }
    end

    return {
        source_path = prefix .. ".vert.glsl",
        output_path = prefix .. ".vert.spv",
        command = {
            context.get_config().glslang_validator,
            "-V",
            "--target-env",
            "vulkan1.2",
            "-S",
            "vert",
            "-o",
            prefix .. ".vert.spv",
            prefix .. ".vert.glsl",
        },
    }
end

local function render_output_args(render_target)
    if render_target and render_target.mode == "memory" then
        return { "--stdout-png" }
    end

    return { "--output", render_target.output_png }
end

function M.render_command_spec(api, vertex_output, fragment_output, manifest_path, render_target, entry)
    local config = context.get_config()
    local command = {
        api == "opengl" and config.runner_binary_opengl or config.runner_binary,
        "--vertex",
        vertex_output,
        "--fragment",
        fragment_output,
        "--manifest",
        manifest_path,
        "--entry",
        entry,
        "--size",
        tostring(config.image_size),
    }
    vim.list_extend(command, render_output_args(render_target))
    return command
end

function M.render_command_opts(render_target)
    if render_target and render_target.mode == "memory" then
        return { text = false }
    end

    return nil
end

function M.adapt_opengl_fragment_glsl(path)
    local source = util.read_text(path)
    if not source then
        return nil, "Failed to read generated GLSL: " .. path
    end

    local texture_sampler_pairs = {}
    for texture_name, sampler_name in source:gmatch("sampler2D%(([%w_]+),([%w_]+)%)") do
        texture_sampler_pairs[#texture_sampler_pairs + 1] = {
            texture = texture_name,
            sampler = sampler_name,
        }
    end

    if #texture_sampler_pairs == 0 then
        return true
    end

    local transformed = source
    for _, pair in ipairs(texture_sampler_pairs) do
        local texture_decl_pattern = "layout%(binding = (%d+)%)%s*\nuniform texture2D " .. pair.texture .. ";"
        transformed = transformed:gsub(texture_decl_pattern, function(binding)
            return string.format("layout(binding = %s)\nuniform sampler2D %s;", binding, pair.texture)
        end, 1)

        transformed = transformed:gsub("\nsampler2D%(" .. pair.texture .. ",%s*" .. pair.sampler .. "%)", "\n" .. pair.texture)
        transformed = transformed:gsub("sampler2D%(" .. pair.texture .. ",%s*" .. pair.sampler .. "%)", pair.texture)

        local sampler_decl_pattern = "\n#line [^\n]*\nlayout%(binding = %d+%)%s*\nuniform sampler " .. pair.sampler .. ";\n*"
        local replaced = false
        transformed = transformed:gsub(sampler_decl_pattern, function()
            replaced = true
            return "\n"
        end, 1)

        if not replaced then
            transformed = transformed:gsub("layout%(binding = %d+%)%s*\nuniform sampler " .. pair.sampler .. ";\n*", "", 1)
        end
    end

    local ok, err = util.write_text(path, transformed)
    if not ok then
        return nil, err
    end

    return true
end

function M.compile_fragment_artifact(temp_source, prefix, entry, api)
    local spec = M.fragment_compile_spec(temp_source, prefix, entry, api)
    local result = util.system_wait(spec.command)
    if result.code ~= 0 then
        return nil, util.command_error(result)
    end

    if api == "opengl" then
        local ok, err = M.adapt_opengl_fragment_glsl(spec.fragment_output)
        if not ok then
            return nil, err
        end
    end

    return spec.fragment_output, spec.reflection_json
end

function M.render_preview(api, vertex_output, fragment_output, manifest_path, render_target, entry)
    local result = util.system_wait(
        M.render_command_spec(api, vertex_output, fragment_output, manifest_path, render_target, entry),
        M.render_command_opts(render_target)
    )
    if result.code ~= 0 then
        return nil, util.command_error(result)
    end

    return {
        stdout = result.stdout,
    }
end

return M
