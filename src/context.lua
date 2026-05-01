local M = {}

local preview_ns = vim.api.nvim_create_namespace("shaderdebug-preview")

local default_config = {
    api = "auto",
    auto_preview = false,
    debounce_ms = 180,
    image_size = 512,
    preview = {
        buffer_name = "ShaderDebug Preview",
        split_command = "rightbelow vsplit",
        width_fraction = 0.35,
        top_padding_lines = 8,
        image_gap_lines = 1,
        bottom_padding_lines = 1,
        cell_aspect_ratio = nil,
        backend = "native",
    },
    cache_dir = vim.fn.stdpath("cache") .. "/shaderdebug",
    runner_source = vim.fn.stdpath("config") .. "/lua/shaderdebug/renderer_vk.cpp",
    runner_binary = vim.fn.stdpath("cache") .. "/shaderdebug/shaderdebug_renderer",
    runner_source_opengl = vim.fn.stdpath("config") .. "/lua/shaderdebug/renderer_gl.cpp",
    runner_binary_opengl = vim.fn.stdpath("cache") .. "/shaderdebug/shaderdebug_renderer_gl",
    slangc = vim.fn.exepath("slangc") ~= "" and vim.fn.exepath("slangc") or "slangc",
    glslang_validator = vim.fn.exepath("glslangValidator") ~= "" and vim.fn.exepath("glslangValidator")
        or "glslangValidator",
    ffmpeg = vim.fn.exepath("ffmpeg") ~= "" and vim.fn.exepath("ffmpeg") or "ffmpeg",
    slang_profile = "sm_6_5",
    opengl_profile = "glsl_450",
}

local config = vim.deepcopy(default_config)

local state = {
    auto_enabled = false,
    timer = nil,
    pending_request = nil,
    active_process = nil,
    render_request_id = 0,
    preview_buf = nil,
    preview_win = nil,
    preview_actions = {},
    preview_context = nil,
    preview_text_line_count = 0,
    image = nil,
    preview_image_suspended = false,
    native_preview_suspended = false,
    detected_cell_aspect_ratio = nil,
    attempted_cell_aspect_ratio_detection = false,
    augroup = nil,
    last_result = nil,
    input_overrides = {},
    input_editors = {},
}

local debug_helpers = table.concat({
    "",
    "float4 shaderdebug_toColor(float value) { return float4(value, value, value, 1.0); }",
    "float4 shaderdebug_toColor(float2 value) { return float4(value.x, value.y, 0.0, 1.0); }",
    "float4 shaderdebug_toColor(float3 value) { return float4(value, 1.0); }",
    "float4 shaderdebug_toColor(float4 value) { return value; }",
    "float4 shaderdebug_toColor(int value) { float f = clamp(float(value) / 255.0, 0.0, 1.0); return float4(f, f, f, 1.0); }",
    "float4 shaderdebug_toColor(int2 value) { return float4(clamp(float2(value) / 255.0, 0.0, 1.0), 0.0, 1.0); }",
    "float4 shaderdebug_toColor(int3 value) { return float4(clamp(float3(value) / 255.0, 0.0, 1.0), 1.0); }",
    "float4 shaderdebug_toColor(int4 value) { return clamp(float4(value) / 255.0, 0.0, 1.0); }",
    "float4 shaderdebug_toColor(uint value) { float f = clamp(float(value) / 255.0, 0.0, 1.0); return float4(f, f, f, 1.0); }",
    "float4 shaderdebug_toColor(uint2 value) { return float4(clamp(float2(value) / 255.0, 0.0, 1.0), 0.0, 1.0); }",
    "float4 shaderdebug_toColor(uint3 value) { return float4(clamp(float3(value) / 255.0, 0.0, 1.0), 1.0); }",
    "float4 shaderdebug_toColor(uint4 value) { return clamp(float4(value) / 255.0, 0.0, 1.0); }",
    "float4 shaderdebug_toColor(bool value) { return value ? float4(1.0, 1.0, 1.0, 1.0) : float4(0.0, 0.0, 0.0, 1.0); }",
    "float4 shaderdebug_toColor(bool2 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, 0.0, 1.0); }",
    "float4 shaderdebug_toColor(bool3 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, value.z ? 1.0 : 0.0, 1.0); }",
    "float4 shaderdebug_toColor(bool4 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, value.z ? 1.0 : 0.0, value.w ? 1.0 : 0.0); }",
    "",
}, "\n")

local function normalize_api(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = value:lower()
    if normalized == "gl" or normalized == "ogl" then
        return "opengl"
    end
    if normalized == "vk" then
        return "vulkan"
    end
    if normalized == "auto" or normalized == "opengl" or normalized == "vulkan" then
        return normalized
    end

    return nil
end

local function normalize_preview_backend(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = value:lower()
    if normalized == "auto" or normalized == "native" or normalized == "image.nvim" then
        return normalized
    end

    if normalized == "image" or normalized == "image_nvim" or normalized == "image-nvim" then
        return "image.nvim"
    end

    return nil
end

function M.get_config()
    return config
end

function M.get_state()
    return state
end

function M.get_preview_ns()
    return preview_ns
end

function M.get_debug_helpers()
    return debug_helpers
end

function M.get_default_config()
    return default_config
end

function M.normalize_api(value)
    return normalize_api(value)
end

function M.detect_api()
    local configured = normalize_api(config.api) or "auto"
    if configured ~= "auto" then
        return configured
    end

    return "vulkan"
end

function M.setup_preview_highlights()
    vim.api.nvim_set_hl(0, "ShaderDebugHeader", { link = "Title", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputDefault", { link = "Identifier", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputOverride", { link = "Function", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputName", { link = "Identifier", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputDetail", { link = "Comment" })
    vim.api.nvim_set_hl(0, "ShaderDebugInputEmpty", { link = "NonText" })
end

function M.setup(user_config)
    config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config or {})
    config.api = normalize_api(config.api) or default_config.api
    config.preview = config.preview or {}
    config.preview.backend = normalize_preview_backend(config.preview.backend) or default_config.preview.backend
    state.auto_enabled = config.auto_preview
    return config
end

return M
