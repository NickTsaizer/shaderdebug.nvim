local function current_source_path()
    local source = debug.getinfo(1, "S").source
    return source:sub(1, 1) == "@" and source:sub(2) or source
end

local root = vim.fn.fnamemodify(current_source_path(), ":h:h")
package.path = table.concat({
    root .. "/lua/?.lua",
    root .. "/lua/?/init.lua",
    package.path,
}, ";")

return root
