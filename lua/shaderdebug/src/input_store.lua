local uv = vim.uv
local ffi = require("ffi")

local context = require("shaderdebug.src.context")
local util = require("shaderdebug.src.util")

ffi.cdef([[ 
typedef unsigned char uint8_t;
typedef int int32_t;
typedef unsigned int uint32_t;
]])

local M = {}

function M.shader_key_for_buffer(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    return vim.fn.fnamemodify(path ~= "" and path or ("buffer-" .. bufnr), ":p")
end

function M.get_input_store(shader_key)
    local state = context.get_state()
    state.input_overrides[shader_key] = state.input_overrides[shader_key] or {}
    return state.input_overrides[shader_key]
end

function M.input_store_for_spec(spec, shader_key)
    return M.get_input_store(shader_key)[spec.name]
end

function M.table_is_array(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end

    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end

    return true
end

local function flatten_numeric_array(value)
    if type(value) ~= "table" then
        return { value }
    end

    local out = {}
    for _, item in ipairs(value) do
        if type(item) == "table" then
            vim.list_extend(out, flatten_numeric_array(item))
        else
            out[#out + 1] = item
        end
    end
    return out
end

local function struct_size_from_fields(fields)
    local size = 0
    for _, field in ipairs(fields or {}) do
        local binding = field.binding or {}
        if binding.offset and binding.size then
            size = math.max(size, binding.offset + binding.size)
        elseif field.type then
            size = math.max(size, struct_size_from_fields(field.type.fields or {}))
        end
    end
    return size
end

local function element_size_for_type(typeinfo)
    local kind = typeinfo.kind
    if kind == "scalar" then
        return 4
    elseif kind == "vector" then
        return (typeinfo.elementCount or 1) * 4
    elseif kind == "matrix" then
        return (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1) * 4
    elseif kind == "struct" then
        return struct_size_from_fields(typeinfo.fields)
    elseif kind == "array" then
        local stride = (typeinfo.binding and typeinfo.binding.elementStride) or element_size_for_type(typeinfo.elementType)
        local count = math.max(typeinfo.elementCount or 0, 1)
        return stride * count
    end

    return 0
end

local function identity_matrix(rows, cols)
    local out = {}
    for row = 1, rows do
        for col = 1, cols do
            out[#out + 1] = row == col and 1 or 0
        end
    end
    return out
end

local function default_value_for_type(typeinfo, field_name, render_context)
    local kind = typeinfo.kind
    if kind == "scalar" then
        if typeinfo.scalarType == "bool" then
            return false
        end
        return 0
    elseif kind == "vector" then
        if field_name == "resolution"
            and (typeinfo.elementCount or 0) == 2
            and typeinfo.elementType
            and typeinfo.elementType.scalarType == "float32"
        then
            return { render_context.image_size, render_context.image_size }
        end

        if field_name == "tint"
            and (typeinfo.elementCount or 0) == 4
            and typeinfo.elementType
            and typeinfo.elementType.scalarType == "float32"
        then
            return { 1, 1, 1, 0.5 }
        end

        if field_name == "camera_pos" and (typeinfo.elementCount or 0) == 4 then
            return { 0, 0, 0, 1 }
        end

        local out = {}
        for i = 1, (typeinfo.elementCount or 1) do
            out[i] = 0
        end
        return out
    elseif kind == "matrix" then
        if field_name == "view" or field_name == "proj" or field_name == "model" then
            return identity_matrix(typeinfo.rowCount or 1, typeinfo.columnCount or 1)
        end

        local out = {}
        for i = 1, (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1) do
            out[i] = 0
        end
        return out
    elseif kind == "struct" then
        local out = {}
        for _, field in ipairs(typeinfo.fields or {}) do
            out[field.name] = default_value_for_type(field.type, field.name, render_context)
        end
        return out
    elseif kind == "array" then
        local count = typeinfo.elementCount and typeinfo.elementCount > 0 and typeinfo.elementCount or 1
        local out = {}
        for i = 1, count do
            out[i] = default_value_for_type(typeinfo.elementType, field_name, render_context)
        end
        return out
    end

    return nil
end

local function merge_values(default_value, override_value)
    if override_value == nil then
        return default_value
    end
    if type(default_value) ~= "table" or type(override_value) ~= "table" then
        return override_value
    end

    if M.table_is_array(default_value) or M.table_is_array(override_value) then
        return override_value
    end

    local merged = vim.deepcopy(default_value)
    for key, value in pairs(override_value) do
        merged[key] = merge_values(merged[key], value)
    end
    return merged
end

local function write_scalar(ptr, offset, scalar_type, value)
    if scalar_type == "float32" then
        ffi.cast("float*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "int32" then
        ffi.cast("int32_t*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "uint32" then
        ffi.cast("uint32_t*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "bool" then
        ffi.cast("uint32_t*", ptr + offset)[0] = value and 1 or 0
    end
end

local function pack_value(ptr, base_offset, typeinfo, value, binding)
    local kind = typeinfo.kind
    if kind == "scalar" then
        write_scalar(ptr, base_offset, typeinfo.scalarType, value)
        return
    end

    if kind == "vector" then
        local values = flatten_numeric_array(value or {})
        local scalar_type = typeinfo.elementType and typeinfo.elementType.scalarType or "float32"
        for index = 1, (typeinfo.elementCount or 1) do
            write_scalar(ptr, base_offset + (index - 1) * 4, scalar_type, values[index] or 0)
        end
        return
    end

    if kind == "matrix" then
        local values = flatten_numeric_array(value or {})
        local scalar_type = typeinfo.elementType and typeinfo.elementType.scalarType or "float32"
        local count = (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1)
        for index = 1, count do
            write_scalar(ptr, base_offset + (index - 1) * 4, scalar_type, values[index] or 0)
        end
        return
    end

    if kind == "struct" then
        local object = type(value) == "table" and value or {}
        for _, field in ipairs(typeinfo.fields or {}) do
            local field_binding = field.binding or {}
            local field_offset = base_offset + (field_binding.offset or 0)
            pack_value(ptr, field_offset, field.type, object[field.name], field_binding)
        end
        return
    end

    if kind == "array" then
        local array_value = M.table_is_array(value) and value or {}
        local stride = (binding and binding.elementStride and binding.elementStride > 0) and binding.elementStride
            or element_size_for_type(typeinfo.elementType)
        local count = typeinfo.elementCount and typeinfo.elementCount > 0 and typeinfo.elementCount or #array_value
        if count == 0 then
            count = 1
        end
        for index = 1, count do
            pack_value(ptr, base_offset + (index - 1) * stride, typeinfo.elementType, array_value[index], typeinfo.elementType.binding)
        end
    end
end

function M.parse_data_argument(argument)
    local payload = argument
    if payload:sub(1, 1) == "@" then
        payload = util.read_text(payload:sub(2))
    elseif uv.fs_stat(payload) then
        payload = util.read_text(payload)
    end

    if not payload then
        return nil, "Failed to read data payload"
    end

    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok then
        return nil, decoded
    end

    return decoded
end

local function convert_image_if_needed(source_path)
    if source_path == "__default__" then
        return source_path
    end

    local absolute = vim.fn.fnamemodify(source_path, ":p")
    if vim.fn.filereadable(absolute) ~= 1 then
        return nil, "Image not found: " .. absolute
    end

    if absolute:lower():match("%.png$") then
        return absolute
    end

    local cache_dir = context.get_config().cache_dir .. "/image-cache"
    vim.fn.mkdir(cache_dir, "p")
    local output_path = string.format("%s/%s-%d.png", cache_dir, util.sanitize_name(absolute), util.file_mtime(absolute))
    if vim.fn.filereadable(output_path) == 1 then
        return output_path
    end

    local result = util.system_wait({
        context.get_config().ffmpeg,
        "-y",
        "-i",
        absolute,
        "-frames:v",
        "1",
        output_path,
    })

    if result.code ~= 0 then
        return nil, util.command_error(result)
    end

    return output_path
end

local function build_buffer_blob(spec, override_value, render_context)
    if spec.kind == "uniform_buffer" then
        local typeinfo = spec.type_info
        local merged_value = merge_values(default_value_for_type(typeinfo, spec.name, render_context), override_value)
        local size = (spec.layout_binding and spec.layout_binding.size) or struct_size_from_fields(typeinfo.fields)
        local storage = ffi.new("uint8_t[?]", size)
        ffi.fill(storage, size, 0)
        pack_value(ffi.cast("uint8_t*", storage), 0, typeinfo, merged_value, spec.layout_binding)
        return ffi.string(storage, size)
    end

    if spec.kind == "storage_buffer" then
        local typeinfo = spec.type_info
        local default_element = default_value_for_type(typeinfo, spec.name, render_context)
        local values = override_value

        if type(values) ~= "table" or not M.table_is_array(values) then
            values = { merge_values(default_element, values or {}) }
        else
            local merged = {}
            for index, value in ipairs(values) do
                merged[index] = merge_values(default_element, value)
            end
            values = merged
        end

        local element_size = struct_size_from_fields(typeinfo.fields)
        local size = math.max(#values, 1) * math.max(element_size, 4)
        local storage = ffi.new("uint8_t[?]", size)
        ffi.fill(storage, size, 0)
        local ptr = ffi.cast("uint8_t*", storage)
        for index, value in ipairs(values) do
            pack_value(ptr, (index - 1) * element_size, typeinfo, value)
        end
        return ffi.string(storage, size)
    end

    return nil, "Unsupported buffer kind: " .. spec.kind
end

function M.prepare_manifest(specs, shader_key, prefix, render_context)
    local manifest_path = prefix .. ".manifest.tsv"
    local store = M.get_input_store(shader_key)
    local lines = {}
    local prepared_specs = {}

    for _, spec in ipairs(specs) do
        local override = store[spec.name]
        local manifest_fields = {
            "resource",
            spec.name,
            spec.kind,
            tostring(spec.set),
            tostring(spec.binding),
        }
        local source_label = "default"

        if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
            local paths = { "__default__" }
            if override and override.kind == "images" then
                paths = override.values
                source_label = "override"
            end

            if not spec.is_array then
                paths = { paths[1] or "__default__" }
            end

            local converted = {}
            for _, path in ipairs(paths) do
                local actual, err = convert_image_if_needed(path)
                if not actual then
                    return nil, err
                end
                converted[#converted + 1] = actual
            end

            manifest_fields[#manifest_fields + 1] = tostring(#converted)
            vim.list_extend(manifest_fields, converted)
            spec.descriptor_count = #converted
            spec.source_label = source_label
            spec.bound_values = converted
        elseif spec.kind == "sampler" then
            local sampler_mode = override and override.mode or "linear"
            manifest_fields[#manifest_fields + 1] = "1"
            manifest_fields[#manifest_fields + 1] = sampler_mode
            spec.descriptor_count = 1
            spec.source_label = override and "override" or "default"
            spec.bound_values = { sampler_mode }
        elseif spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
            local blob, err = build_buffer_blob(spec, override and override.value or nil, render_context)
            if not blob then
                return nil, err
            end

            local buffer_path = string.format("%s.%s.bin", prefix, util.sanitize_name(spec.name))
            local ok, write_err = util.write_binary(buffer_path, blob)
            if not ok then
                return nil, write_err
            end

            manifest_fields[#manifest_fields + 1] = "1"
            manifest_fields[#manifest_fields + 1] = buffer_path
            spec.descriptor_count = 1
            spec.source_label = override and "override" or "default"
            spec.bound_values = { buffer_path }
        else
            return nil, "Unsupported reflected resource kind: " .. spec.kind
        end

        lines[#lines + 1] = table.concat(manifest_fields, "\t")
        prepared_specs[#prepared_specs + 1] = spec
    end

    local ok, err = util.write_text(manifest_path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
    if not ok then
        return nil, err
    end

    return manifest_path, prepared_specs
end

function M.default_json_for_spec(spec)
    local render_context = { image_size = context.get_config().image_size }
    if spec.kind == "uniform_buffer" then
        return default_value_for_type(spec.type_info, spec.name, render_context)
    end

    if spec.kind == "storage_buffer" then
        return { default_value_for_type(spec.type_info, spec.name, render_context) }
    end

    return nil
end

function M.input_summary_line(spec)
    local detail = "default"
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        if spec.bound_values and #spec.bound_values > 0 then
            if spec.bound_values[1] == "__default__" then
                detail = "default image"
            else
                local names = {}
                for _, path in ipairs(spec.bound_values) do
                    names[#names + 1] = vim.fn.fnamemodify(path, ":t")
                end
                detail = table.concat(names, ", ")
            end
        end
    elseif spec.kind == "sampler" then
        detail = spec.bound_values and spec.bound_values[1] or "linear"
    elseif spec.source_label == "override" then
        detail = "custom data"
    else
        detail = "default data"
    end

    return string.format("• %s [%s] set=%d binding=%d → %s", spec.name, spec.kind, spec.set, spec.binding, detail)
end

function M.input_detail_lines(spec)
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        if spec.bound_values and #spec.bound_values > 0 then
            if spec.bound_values[1] == "__default__" then
                return { "  image: default checkerboard" }
            end

            local lines = {}
            for index, path in ipairs(spec.bound_values) do
                lines[#lines + 1] = string.format("  image[%d]: %s", index, path)
            end
            return lines
        end
        return { "  image: press <Enter> to choose path" }
    end

    if spec.kind == "sampler" then
        local mode = spec.bound_values and spec.bound_values[1] or "linear"
        return { string.format("  sampler: %s", mode) }
    end

    if spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
        if spec.bound_values and #spec.bound_values > 0 then
            return { string.format("  data: %s", spec.bound_values[1]) }
        end
        return { "  data: press <Enter> to edit JSON" }
    end

    return {}
end

function M.set_image_input_for(shader_key, name, path)
    M.get_input_store(shader_key)[name] = { kind = "images", values = { path } }
    util.notify(string.format("Bound image '%s' -> %s", name, path))
end

function M.set_images_input_for(shader_key, name, paths)
    local values = paths
    if type(values) == "string" then
        values = vim.split(values, ",", { trimempty = true })
        for index, value in ipairs(values) do
            values[index] = util.trim(value)
        end
    end

    M.get_input_store(shader_key)[name] = { kind = "images", values = values }
    util.notify(string.format("Bound image list '%s' (%d item%s)", name, #values, #values == 1 and "" or "s"))
end

function M.set_data_input_value_for(shader_key, name, value)
    M.get_input_store(shader_key)[name] = { kind = "data", value = value }
    util.notify(string.format("Bound data '%s'", name))
    return true
end

function M.clear_input_for(shader_key, name)
    M.get_input_store(shader_key)[name] = nil
    util.notify(string.format("Cleared input '%s'", name))
end

return M
