local uv = vim.uv

local context = require("shaderdebug.src.context")

local M = {}

function M.notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "shaderdebug" })
end

function M.ensure_cache_dir()
    vim.fn.mkdir(context.get_config().cache_dir, "p")
end

function M.read_text(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

function M.write_text(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end

    file:write(content)
    file:close()
    return true
end

function M.write_binary(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end

    file:write(content)
    file:close()
    return true
end

function M.system_wait(cmd, opts)
    return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

function M.system_start(cmd, opts, on_exit)
    return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(result)
        vim.schedule(function()
            on_exit(result)
        end)
    end)
end

function M.command_error(result)
    local stderr = result and result.stderr or ""
    local stdout = result and result.stdout or ""
    return stderr ~= "" and stderr or (stdout ~= "" and stdout or "unknown error")
end

function M.file_mtime(path)
    local stat = uv.fs_stat(path)
    return stat and stat.mtime and stat.mtime.sec or 0
end

function M.trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.sanitize_name(name)
    return (name:gsub("[^%w_%-]", "_"))
end

function M.read_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.pkg_config_flags(packages)
    local command = { "pkg-config", "--cflags", "--libs" }
    vim.list_extend(command, packages)

    local result = M.system_wait(command)
    if result.code ~= 0 then
        return nil, M.command_error(result)
    end

    local output = vim.trim(result.stdout or "")
    if output == "" then
        return {}
    end

    return vim.split(output, "%s+", { trimempty = true })
end

function M.ensure_runner(api)
    local config = context.get_config()
    M.ensure_cache_dir()

    local runner_api = context.normalize_api(api) or "vulkan"
    local source = runner_api == "opengl" and config.runner_source_opengl or config.runner_source
    local binary = runner_api == "opengl" and config.runner_binary_opengl or config.runner_binary

    if uv.fs_stat(source) == nil then
        M.notify(string.format("Renderer source not found for %s: %s", runner_api, source), vim.log.levels.ERROR)
        return false
    end

    local needs_build = uv.fs_stat(binary) == nil or M.file_mtime(source) > M.file_mtime(binary)
    if not needs_build then
        return true
    end

    local packages = runner_api == "opengl" and { "egl", "epoxy", "libpng" } or { "vulkan", "libpng" }
    local pkg_flags, pkg_err = M.pkg_config_flags(packages)
    if not pkg_flags then
        M.notify(
            string.format("Failed to resolve %s renderer build flags:\n%s", runner_api, pkg_err),
            vim.log.levels.ERROR
        )
        return false
    end

    local command = { "c++", "-x", "c++", source, "-O2", "-std=c++20", "-o", binary }
    vim.list_extend(command, pkg_flags)

    local result = M.system_wait(command)
    if result.code ~= 0 then
        M.notify(
            string.format("Failed to build shaderdebug %s renderer:\n%s", runner_api, M.command_error(result)),
            vim.log.levels.ERROR
        )
        return false
    end

    return true
end

return M
