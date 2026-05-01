local context = require("shaderdebug.src.context")
local util = require("shaderdebug.src.util")

local M = {}
local DEBUG_OUTPUT_NAME = "shaderdebug_output"

local function parse_function_signature(line)
    local return_type, function_name = line:match("^%s*([%w_%<%>%[%]%.:,]+)%s+([%a_][%w_]*)%s*%(")
    if not return_type or not function_name then
        return nil
    end

    return {
        return_type = util.trim(return_type),
        name = function_name,
    }
end

local function is_return_statement(line)
    return line:match("^%s*return%s+") ~= nil
end

local function is_assignment_statement(line)
    if line:find("==", 1, true) or line:find("!=", 1, true) or line:find("<=", 1, true) or line:find(">=", 1, true) then
        return false
    end

    local _, operator = line:match("^%s*(.-)%s*([%+%-%*/%%]?=)%s*(.+);%s*$")
    return operator == "="
end

local function line_in_range(line_number, range)
    return range and line_number >= range.start_line and line_number <= range.end_line
end

local function is_control_flow_call(line)
    return line:match("^%s*if%s*%(")
        or line:match("^%s*for%s*%(")
        or line:match("^%s*while%s*%(")
        or line:match("^%s*switch%s*%(")
end

local function current_line_function_call(line)
    if is_control_flow_call(line) then
        return nil
    end

    local call_expr = line:match("^%s*([%a_][%w_%.:]-%b())%s*;%s*$")
    if call_expr then
        return util.trim(call_expr)
    end

    return nil
end

local function current_line_expression(line)
    local return_expr = line:match("^%s*return%s+(.+);%s*$")
    if return_expr then
        return util.trim(return_expr)
    end

    if line:find("==", 1, true) or line:find("!=", 1, true) or line:find("<=", 1, true) or line:find(">=", 1, true) then
        return nil
    end

    local _, operator, rhs = line:match("^%s*(.-)%s*([%+%-%*/%%]?=)%s*(.+);%s*$")
    if rhs and operator == "=" then
        return util.trim(rhs)
    end

    return current_line_function_call(line)
end

local function find_fragment_entry(lines)
    local saw_fragment_attr = false

    for _, line in ipairs(lines) do
        if line:match('%[shader%(%s*"fragment"%s*%)%]') or line:match("%[shader%(%s*'fragment'%s*%)%]") then
            saw_fragment_attr = true
        elseif saw_fragment_attr then
            local function_name = line:match("([%a_][%w_]*)%s*%(")
            if function_name then
                return function_name
            end
        end
    end

    return nil
end

local function brace_delta(line)
    local opens = select(2, line:gsub("{", ""))
    local closes = select(2, line:gsub("}", ""))
    return opens - closes
end

local function find_function_end(lines, start_line)
    local depth = 0
    for i = 1, start_line do
        depth = depth + brace_delta(lines[i])
    end

    local running_depth = depth
    for i = start_line + 1, #lines do
        running_depth = running_depth + brace_delta(lines[i])
        if running_depth <= 0 then
            return i
        end
    end

    return #lines
end

local function find_function_range(lines, function_name)
    for i, line in ipairs(lines) do
        local signature = parse_function_signature(line)
        if signature and signature.name == function_name then
            return {
                name = signature.name,
                return_type = signature.return_type,
                start_line = i,
                end_line = find_function_end(lines, i),
            }
        end
    end

    return nil
end

local function find_enclosing_function(lines, cursor_line)
    for i = cursor_line, 1, -1 do
        local signature = parse_function_signature(lines[i])
        if signature then
            local range = {
                name = signature.name,
                return_type = signature.return_type,
                start_line = i,
                end_line = find_function_end(lines, i),
            }
            if line_in_range(cursor_line, range) then
                return range
            end
        end
    end

    return nil
end

local function first_function_line(lines)
    for i, line in ipairs(lines) do
        if parse_function_signature(line) then
            return i
        end
    end

    return #lines + 1
end

local function build_instrumented_line(line, expression, in_entry_function)
    local indent = line:match("^(%s*)") or ""

    if is_return_statement(line) then
        if in_entry_function then
            return indent .. DEBUG_OUTPUT_NAME .. " = shaderdebug_toColor(" .. expression .. ");",
                indent .. "return " .. DEBUG_OUTPUT_NAME .. ";"
        end

        return indent .. DEBUG_OUTPUT_NAME .. " = shaderdebug_toColor(" .. expression .. ");",
            indent .. "return " .. expression .. ";"
    end

    if is_assignment_statement(line) then
        return line, indent .. DEBUG_OUTPUT_NAME .. " = shaderdebug_toColor(" .. expression .. ");"
    end

    return indent .. DEBUG_OUTPUT_NAME .. " = shaderdebug_toColor(" .. expression .. ");"
end

local function rewrite_entry_returns(lines, entry_range, target_line)
    for i = entry_range.start_line, entry_range.end_line do
        if i ~= target_line and is_return_statement(lines[i]) then
            local indent = lines[i]:match("^(%s*)") or ""
            lines[i] = indent .. "return " .. DEBUG_OUTPUT_NAME .. ";"
        end
    end
end

function M.build_instrumented_source(bufnr, cursor_line)
    local lines = util.read_lines(bufnr)
    local line = lines[cursor_line]
    if not line then
        return nil, "No line under cursor"
    end

    local expression = current_line_expression(line)
    if not expression then
        return nil, "Cursor line must be a simple assignment, function call, or return statement"
    end

    local entry = find_fragment_entry(lines)
    if not entry then
        return nil, "No [shader(\"fragment\")] entry point found"
    end

    local entry_range = find_function_range(lines, entry)
    if not entry_range then
        return nil, "Failed to resolve fragment entry function"
    end

    local enclosing_function = find_enclosing_function(lines, cursor_line)
    if not enclosing_function then
        return nil, "Cursor line must be inside a function body"
    end

    local new_lines = vim.deepcopy(lines)
    local replacement_a, replacement_b = build_instrumented_line(line, expression, enclosing_function.name == entry)
    new_lines[cursor_line] = replacement_a
    if replacement_b then
        table.insert(new_lines, cursor_line + 1, replacement_b)
        if line_in_range(cursor_line, entry_range) then
            entry_range.end_line = entry_range.end_line + 1
        end
    end

    local insertion_line = first_function_line(new_lines)
    table.insert(new_lines, insertion_line, "static float4 " .. DEBUG_OUTPUT_NAME .. " = float4(0.0, 0.0, 0.0, 1.0);")

    if insertion_line <= entry_range.start_line then
        entry_range.start_line = entry_range.start_line + 1
        entry_range.end_line = entry_range.end_line + 1
    end

    rewrite_entry_returns(new_lines, entry_range, cursor_line)
    table.insert(new_lines, context.get_debug_helpers())

    return {
        source = table.concat(new_lines, "\n") .. "\n",
        entry = entry,
        expression = expression,
        cursor_line = cursor_line,
    }
end

function M.write_temp_source(bufnr, payload)
    util.ensure_cache_dir()

    local source_name = vim.api.nvim_buf_get_name(bufnr)
    local stem = vim.fn.fnamemodify(source_name ~= "" and source_name or "shader", ":t:r")
    local prefix = string.format(
        "%s/%s-line-%d.debug",
        context.get_config().cache_dir,
        util.sanitize_name(stem),
        payload.cursor_line
    )

    local temp_source = prefix .. ".slang"
    local output_png = prefix .. ".png"
    local ok, err = util.write_text(temp_source, payload.source)
    if not ok then
        return nil, err
    end

    return temp_source, output_png, prefix
end

return M
