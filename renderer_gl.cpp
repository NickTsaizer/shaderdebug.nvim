#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <png.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

struct Options {
    std::string vertex_path;
    std::string fragment_path;
    std::string manifest_path;
    std::string entry_name = "main";
    std::string output_path;
    bool stdout_png = false;
    uint32_t size = 512;
};

enum class ResourceKind {
    CombinedImageSampler,
    SampledImage,
    Sampler,
    UniformBuffer,
    StorageBuffer,
};

struct ResourceSpec {
    std::string name;
    ResourceKind kind;
    uint32_t set = 0;
    uint32_t binding = 0;
    uint32_t count = 1;
    std::vector<std::string> values;
};

struct ImagePixels {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgba;
};

struct PreparedResource {
    ResourceSpec spec;
    std::vector<GLuint> textures;
    std::vector<GLuint> samplers;
    std::vector<GLuint> buffers;
};

struct EglContext {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
};

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

static std::string egl_error_string(EGLint error)
{
    switch (error) {
    case EGL_SUCCESS:
        return "EGL_SUCCESS";
    case EGL_NOT_INITIALIZED:
        return "EGL_NOT_INITIALIZED";
    case EGL_BAD_ACCESS:
        return "EGL_BAD_ACCESS";
    case EGL_BAD_ALLOC:
        return "EGL_BAD_ALLOC";
    case EGL_BAD_ATTRIBUTE:
        return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_CONTEXT:
        return "EGL_BAD_CONTEXT";
    case EGL_BAD_CONFIG:
        return "EGL_BAD_CONFIG";
    case EGL_BAD_CURRENT_SURFACE:
        return "EGL_BAD_CURRENT_SURFACE";
    case EGL_BAD_DISPLAY:
        return "EGL_BAD_DISPLAY";
    case EGL_BAD_SURFACE:
        return "EGL_BAD_SURFACE";
    case EGL_BAD_MATCH:
        return "EGL_BAD_MATCH";
    case EGL_BAD_PARAMETER:
        return "EGL_BAD_PARAMETER";
    case EGL_BAD_NATIVE_PIXMAP:
        return "EGL_BAD_NATIVE_PIXMAP";
    case EGL_BAD_NATIVE_WINDOW:
        return "EGL_BAD_NATIVE_WINDOW";
    case EGL_CONTEXT_LOST:
        return "EGL_CONTEXT_LOST";
    default:
        return "EGL_UNKNOWN_ERROR";
    }
}

static void egl_check(EGLBoolean ok, const std::string &message)
{
    if (ok == EGL_TRUE) {
        return;
    }

    const EGLint error = eglGetError();
    throw std::runtime_error(message + ": " + egl_error_string(error));
}

static EglContext init_egl(uint32_t size)
{
    EglContext out;

    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
        eglGetProcAddress("eglGetPlatformDisplayEXT"));

    if (get_platform_display) {
        out.display = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
    }
    if (out.display == EGL_NO_DISPLAY) {
        out.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    }
    if (out.display == EGL_NO_DISPLAY) {
        throw std::runtime_error("failed to get EGL display");
    }

    EGLint major = 0;
    EGLint minor = 0;
    egl_check(eglInitialize(out.display, &major, &minor), "eglInitialize failed");

    egl_check(eglBindAPI(EGL_OPENGL_API), "eglBindAPI(OpenGL) failed");

    const EGLint config_attribs[] = {
        EGL_SURFACE_TYPE,
        EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE,
        EGL_OPENGL_BIT,
        EGL_RED_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_BLUE_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_NONE,
    };

    EGLint config_count = 0;
    egl_check(eglChooseConfig(out.display, config_attribs, &out.config, 1, &config_count), "eglChooseConfig failed");
    if (config_count < 1 || out.config == nullptr) {
        throw std::runtime_error("no suitable EGL config found");
    }

    const EGLint surface_attribs[] = {
        EGL_WIDTH,
        static_cast<EGLint>(size),
        EGL_HEIGHT,
        static_cast<EGLint>(size),
        EGL_NONE,
    };
    out.surface = eglCreatePbufferSurface(out.display, out.config, surface_attribs);
    if (out.surface == EGL_NO_SURFACE) {
        throw std::runtime_error("eglCreatePbufferSurface failed: " + egl_error_string(eglGetError()));
    }

    const EGLint context_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION,
        4,
        EGL_CONTEXT_MINOR_VERSION,
        5,
        EGL_CONTEXT_OPENGL_PROFILE_MASK,
        EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };
    out.context = eglCreateContext(out.display, out.config, EGL_NO_CONTEXT, context_attribs);
    if (out.context == EGL_NO_CONTEXT) {
        const EGLint fallback_context_attribs[] = {
            EGL_CONTEXT_MAJOR_VERSION,
            4,
            EGL_CONTEXT_MINOR_VERSION,
            3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK,
            EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        };
        out.context = eglCreateContext(out.display, out.config, EGL_NO_CONTEXT, fallback_context_attribs);
    }
    if (out.context == EGL_NO_CONTEXT) {
        throw std::runtime_error("eglCreateContext failed: " + egl_error_string(eglGetError()));
    }

    egl_check(eglMakeCurrent(out.display, out.surface, out.surface, out.context), "eglMakeCurrent failed");

    return out;
}

static void destroy_egl(EglContext &context)
{
    if (context.display != EGL_NO_DISPLAY) {
        eglMakeCurrent(context.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context.context != EGL_NO_CONTEXT) {
            eglDestroyContext(context.display, context.context);
            context.context = EGL_NO_CONTEXT;
        }
        if (context.surface != EGL_NO_SURFACE) {
            eglDestroySurface(context.display, context.surface);
            context.surface = EGL_NO_SURFACE;
        }
        eglTerminate(context.display);
        context.display = EGL_NO_DISPLAY;
    }
}

static std::string read_text_file(const std::string &path)
{
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        throw std::runtime_error("failed to open file: " + path);
    }

    std::stringstream stream;
    stream << file.rdbuf();
    return stream.str();
}

static std::vector<uint8_t> read_binary_file(const std::string &path)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        throw std::runtime_error("failed to open file: " + path);
    }

    const std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<uint8_t> buffer(static_cast<size_t>(std::max<std::streamsize>(size, 0)));
    if (size > 0 && !file.read(reinterpret_cast<char *>(buffer.data()), size)) {
        throw std::runtime_error("failed to read file: " + path);
    }
    return buffer;
}

static bool write_png(const std::string &path, uint32_t width, uint32_t height, const uint8_t *rgba)
{
    FILE *file = fopen(path.c_str(), "wb");
    if (!file) {
        return false;
    }

    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    if (!png) {
        fclose(file);
        return false;
    }

    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, nullptr);
        fclose(file);
        return false;
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        fclose(file);
        return false;
    }

    png_init_io(png, file);
    png_set_IHDR(
        png,
        info,
        width,
        height,
        8,
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    std::vector<png_bytep> rows(height);
    for (uint32_t y = 0; y < height; ++y) {
        rows[y] = const_cast<png_bytep>(rgba + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u);
    }
    png_write_image(png, rows.data());
    png_write_end(png, nullptr);

    png_destroy_write_struct(&png, &info);
    fclose(file);
    return true;
}

static void append_png_bytes(png_structp png, png_bytep data, png_size_t size)
{
    auto *buffer = static_cast<std::vector<uint8_t> *>(png_get_io_ptr(png));
    buffer->insert(buffer->end(), data, data + size);
}

static void flush_png_bytes(png_structp)
{
}

static std::vector<uint8_t> encode_png(uint32_t width, uint32_t height, const uint8_t *rgba)
{
    std::vector<uint8_t> bytes;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    if (!png) {
        throw std::runtime_error("failed to initialize png encoder");
    }

    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, nullptr);
        throw std::runtime_error("failed to initialize png metadata");
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        throw std::runtime_error("failed to encode png output");
    }

    png_set_write_fn(png, &bytes, append_png_bytes, flush_png_bytes);
    png_set_IHDR(
        png,
        info,
        width,
        height,
        8,
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    std::vector<png_bytep> rows(height);
    for (uint32_t y = 0; y < height; ++y) {
        rows[y] = const_cast<png_bytep>(rgba + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u);
    }
    png_write_image(png, rows.data());
    png_write_end(png, nullptr);
    png_destroy_write_struct(&png, &info);
    return bytes;
}

static bool write_stdout_png(uint32_t width, uint32_t height, const uint8_t *rgba)
{
    const std::vector<uint8_t> bytes = encode_png(width, height, rgba);
    std::cout.write(reinterpret_cast<const char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    std::cout.flush();
    return std::cout.good();
}

static ImagePixels read_png(const std::string &path)
{
    FILE *file = fopen(path.c_str(), "rb");
    if (!file) {
        throw std::runtime_error("failed to open png: " + path);
    }

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    if (!png) {
        fclose(file);
        throw std::runtime_error("png_create_read_struct failed");
    }

    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, nullptr, nullptr);
        fclose(file);
        throw std::runtime_error("png_create_info_struct failed");
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, nullptr);
        fclose(file);
        throw std::runtime_error("libpng read failed");
    }

    png_init_io(png, file);
    png_read_info(png, info);

    png_uint_32 width = 0;
    png_uint_32 height = 0;
    int bit_depth = 0;
    int color_type = 0;
    png_get_IHDR(png, info, &width, &height, &bit_depth, &color_type, nullptr, nullptr, nullptr);

    if (bit_depth == 16) {
        png_set_strip_16(png);
    }
    if (color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_palette_to_rgb(png);
    }
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) {
        png_set_expand_gray_1_2_4_to_8(png);
    }
    if (png_get_valid(png, info, PNG_INFO_tRNS)) {
        png_set_tRNS_to_alpha(png);
    }
    if (color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    }
    if (color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA) {
        png_set_gray_to_rgb(png);
    }

    png_read_update_info(png, info);

    ImagePixels out;
    out.width = static_cast<uint32_t>(width);
    out.height = static_cast<uint32_t>(height);
    out.rgba.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);

    std::vector<png_bytep> rows(height);
    for (uint32_t y = 0; y < height; ++y) {
        rows[y] = out.rgba.data() + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u;
    }
    png_read_image(png, rows.data());

    png_destroy_read_struct(&png, &info, nullptr);
    fclose(file);
    return out;
}

static ImagePixels make_checkerboard(uint32_t size)
{
    ImagePixels out;
    out.width = size;
    out.height = size;
    out.rgba.resize(static_cast<size_t>(size) * static_cast<size_t>(size) * 4u);

    for (uint32_t y = 0; y < size; ++y) {
        for (uint32_t x = 0; x < size; ++x) {
            const bool checker = ((x / 32u) + (y / 32u)) % 2u == 0u;
            const size_t index = (static_cast<size_t>(y) * static_cast<size_t>(size) + static_cast<size_t>(x)) * 4u;
            out.rgba[index + 0] = checker ? 255 : 40;
            out.rgba[index + 1] = static_cast<uint8_t>((x * 255) / std::max(1u, size - 1));
            out.rgba[index + 2] = static_cast<uint8_t>((y * 255) / std::max(1u, size - 1));
            out.rgba[index + 3] = 255;
        }
    }

    return out;
}

static std::vector<std::string> split_tabs(const std::string &line)
{
    std::vector<std::string> parts;
    std::stringstream stream(line);
    std::string item;
    while (std::getline(stream, item, '\t')) {
        parts.push_back(item);
    }
    return parts;
}

static ResourceKind parse_resource_kind(const std::string &value)
{
    if (value == "combined_image_sampler") {
        return ResourceKind::CombinedImageSampler;
    }
    if (value == "sampled_image") {
        return ResourceKind::SampledImage;
    }
    if (value == "sampler") {
        return ResourceKind::Sampler;
    }
    if (value == "uniform_buffer") {
        return ResourceKind::UniformBuffer;
    }
    if (value == "storage_buffer") {
        return ResourceKind::StorageBuffer;
    }
    throw std::runtime_error("unknown resource kind: " + value);
}

static std::vector<ResourceSpec> parse_manifest(const std::string &path)
{
    std::ifstream file(path);
    if (!file) {
        throw std::runtime_error("failed to open manifest: " + path);
    }

    std::vector<ResourceSpec> resources;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }

        const std::vector<std::string> fields = split_tabs(line);
        if (fields.size() < 7 || fields[0] != "resource") {
            throw std::runtime_error("invalid manifest line: " + line);
        }

        ResourceSpec spec;
        spec.name = fields[1];
        spec.kind = parse_resource_kind(fields[2]);
        spec.set = static_cast<uint32_t>(std::stoul(fields[3]));
        spec.binding = static_cast<uint32_t>(std::stoul(fields[4]));
        spec.count = static_cast<uint32_t>(std::stoul(fields[5]));
        for (size_t index = 6; index < fields.size(); ++index) {
            spec.values.push_back(fields[index]);
        }
        resources.push_back(spec);
    }

    return resources;
}

static bool parse_args(int argc, char **argv, Options &options)
{
    for (int index = 1; index < argc; ++index) {
        const std::string arg = argv[index];
        if (arg == "--vertex" && index + 1 < argc) {
            options.vertex_path = argv[++index];
        } else if (arg == "--fragment" && index + 1 < argc) {
            options.fragment_path = argv[++index];
        } else if (arg == "--manifest" && index + 1 < argc) {
            options.manifest_path = argv[++index];
        } else if (arg == "--entry" && index + 1 < argc) {
            options.entry_name = argv[++index];
        } else if (arg == "--output" && index + 1 < argc) {
            options.output_path = argv[++index];
        } else if (arg == "--stdout-png") {
            options.stdout_png = true;
        } else if (arg == "--size" && index + 1 < argc) {
            options.size = static_cast<uint32_t>(std::stoul(argv[++index]));
        } else {
            std::cerr << "unknown argument: " << arg << "\n";
            return false;
        }
    }

    const bool has_output_target = !options.output_path.empty() || options.stdout_png;
    const bool single_output_target = options.output_path.empty() || !options.stdout_png;
    return !options.vertex_path.empty() && !options.fragment_path.empty() && !options.manifest_path.empty() &&
           has_output_target && single_output_target && options.size > 0;
}

static GLuint compile_shader(GLenum type, const std::string &path)
{
    const std::string source = read_text_file(path);
    const char *source_ptr = source.c_str();

    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source_ptr, nullptr);
    glCompileShader(shader);

    GLint success = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (success == GL_TRUE) {
        return shader;
    }

    GLint log_length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &log_length);
    std::string log(static_cast<size_t>(std::max(log_length, 1)), '\0');
    glGetShaderInfoLog(shader, log_length, nullptr, log.data());
    glDeleteShader(shader);
    throw std::runtime_error("shader compile failed for " + path + "\n" + log);
}

static GLuint link_program(GLuint vertex_shader, GLuint fragment_shader)
{
    const GLuint program = glCreateProgram();
    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);

    GLint success = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &success);
    if (success == GL_TRUE) {
        return program;
    }

    GLint log_length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &log_length);
    std::string log(static_cast<size_t>(std::max(log_length, 1)), '\0');
    glGetProgramInfoLog(program, log_length, nullptr, log.data());
    glDeleteProgram(program);
    throw std::runtime_error("program link failed\n" + log);
}

static GLuint create_sampler(const std::string &mode)
{
    const bool nearest = mode == "nearest";
    GLuint sampler = 0;
    glGenSamplers(1, &sampler);
    glSamplerParameteri(sampler, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glSamplerParameteri(sampler, GL_TEXTURE_MAG_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glSamplerParameteri(sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glSamplerParameteri(sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glSamplerParameteri(sampler, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    return sampler;
}

static GLuint create_texture(const ImagePixels &pixels, const std::string &mode)
{
    const bool nearest = mode == "nearest";
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA8,
        static_cast<GLsizei>(pixels.width),
        static_cast<GLsizei>(pixels.height),
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        pixels.rgba.data());
    glBindTexture(GL_TEXTURE_2D, 0);
    return texture;
}

static PreparedResource prepare_resource(const ResourceSpec &spec)
{
    PreparedResource prepared;
    prepared.spec = spec;

    if (spec.kind == ResourceKind::CombinedImageSampler || spec.kind == ResourceKind::SampledImage) {
        const std::string default_mode = "linear";
        for (size_t index = 0; index < spec.values.size(); ++index) {
            ImagePixels pixels = spec.values[index] == "__default__" ? make_checkerboard(256) : read_png(spec.values[index]);
            prepared.textures.push_back(create_texture(pixels, default_mode));
            if (spec.kind == ResourceKind::CombinedImageSampler) {
                prepared.samplers.push_back(create_sampler(default_mode));
            }
        }
    } else if (spec.kind == ResourceKind::Sampler) {
        const std::string mode = spec.values.empty() ? "linear" : spec.values.front();
        prepared.samplers.push_back(create_sampler(mode));
    } else if (spec.kind == ResourceKind::UniformBuffer || spec.kind == ResourceKind::StorageBuffer) {
        if (spec.values.empty()) {
            throw std::runtime_error("buffer resource missing payload: " + spec.name);
        }
        const std::vector<uint8_t> data = read_binary_file(spec.values.front());
        GLuint buffer = 0;
        glGenBuffers(1, &buffer);
        const GLenum target = spec.kind == ResourceKind::UniformBuffer ? GL_UNIFORM_BUFFER : GL_SHADER_STORAGE_BUFFER;
        glBindBuffer(target, buffer);
        glBufferData(target, static_cast<GLsizeiptr>(data.size()), data.data(), GL_STATIC_DRAW);
        glBindBuffer(target, 0);
        prepared.buffers.push_back(buffer);
    }

    return prepared;
}

static void bind_resource_uniform(GLuint program, const ResourceSpec &spec)
{
    if (!(spec.kind == ResourceKind::CombinedImageSampler || spec.kind == ResourceKind::SampledImage)) {
        return;
    }

    const GLint location = glGetUniformLocation(program, spec.name.c_str());
    if (location < 0) {
        return;
    }

    if (spec.count <= 1) {
        glUniform1i(location, static_cast<GLint>(spec.binding));
        return;
    }

    std::vector<GLint> units(spec.count);
    for (uint32_t index = 0; index < spec.count; ++index) {
        units[index] = static_cast<GLint>(spec.binding + index);
    }
    glUniform1iv(location, static_cast<GLsizei>(units.size()), units.data());
}

static void bind_resources(GLuint program, const std::vector<PreparedResource> &resources)
{
    glUseProgram(program);

    for (const PreparedResource &prepared : resources) {
        const ResourceSpec &spec = prepared.spec;
        if (spec.kind == ResourceKind::CombinedImageSampler || spec.kind == ResourceKind::SampledImage) {
            for (size_t index = 0; index < prepared.textures.size(); ++index) {
                const GLuint unit = spec.binding + static_cast<GLuint>(index);
                glActiveTexture(GL_TEXTURE0 + unit);
                glBindTexture(GL_TEXTURE_2D, prepared.textures[index]);
                if (spec.kind == ResourceKind::CombinedImageSampler && index < prepared.samplers.size()) {
                    glBindSampler(unit, prepared.samplers[index]);
                }
            }
            bind_resource_uniform(program, spec);
        } else if (spec.kind == ResourceKind::Sampler) {
            if (!prepared.samplers.empty()) {
                glBindSampler(spec.binding, prepared.samplers.front());
            }
        } else if (spec.kind == ResourceKind::UniformBuffer) {
            if (!prepared.buffers.empty()) {
                glBindBufferBase(GL_UNIFORM_BUFFER, spec.binding, prepared.buffers.front());
            }
        } else if (spec.kind == ResourceKind::StorageBuffer) {
            if (!prepared.buffers.empty()) {
                glBindBufferBase(GL_SHADER_STORAGE_BUFFER, spec.binding, prepared.buffers.front());
            }
        }
    }
}

static void destroy_resources(std::vector<PreparedResource> &resources)
{
    for (PreparedResource &prepared : resources) {
        if (!prepared.textures.empty()) {
            glDeleteTextures(static_cast<GLsizei>(prepared.textures.size()), prepared.textures.data());
            prepared.textures.clear();
        }
        if (!prepared.samplers.empty()) {
            glDeleteSamplers(static_cast<GLsizei>(prepared.samplers.size()), prepared.samplers.data());
            prepared.samplers.clear();
        }
        if (!prepared.buffers.empty()) {
            glDeleteBuffers(static_cast<GLsizei>(prepared.buffers.size()), prepared.buffers.data());
            prepared.buffers.clear();
        }
    }
}

int main(int argc, char **argv)
{
    Options options;
    if (!parse_args(argc, argv, options)) {
        std::cerr << "usage: shaderdebug_renderer_gl --vertex file.vert.glsl --fragment file.frag.glsl --manifest file.tsv --entry name (--output out.png | --stdout-png) [--size 512]\n";
        return 1;
    }

    EglContext egl;
    GLuint vertex_shader = 0;
    GLuint fragment_shader = 0;
    GLuint program = 0;
    GLuint vao = 0;
    GLuint framebuffer = 0;
    GLuint color_texture = 0;
    std::vector<PreparedResource> resources;

    try {
        egl = init_egl(options.size);

        vertex_shader = compile_shader(GL_VERTEX_SHADER, options.vertex_path);
        fragment_shader = compile_shader(GL_FRAGMENT_SHADER, options.fragment_path);
        program = link_program(vertex_shader, fragment_shader);

        const std::vector<ResourceSpec> resource_specs = parse_manifest(options.manifest_path);
        resources.reserve(resource_specs.size());
        for (const ResourceSpec &spec : resource_specs) {
            resources.push_back(prepare_resource(spec));
        }

        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);

        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);

        glGenTextures(1, &color_texture);
        glBindTexture(GL_TEXTURE_2D, color_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, static_cast<GLsizei>(options.size), static_cast<GLsizei>(options.size), 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color_texture, 0);

        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            throw std::runtime_error("OpenGL framebuffer is incomplete");
        }

        bind_resources(program, resources);

        glViewport(0, 0, static_cast<GLsizei>(options.size), static_cast<GLsizei>(options.size));
        glDisable(GL_BLEND);
        glDisable(GL_DEPTH_TEST);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glUseProgram(program);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();

        std::vector<uint8_t> rgba(static_cast<size_t>(options.size) * static_cast<size_t>(options.size) * 4u);
        glReadPixels(0, 0, static_cast<GLsizei>(options.size), static_cast<GLsizei>(options.size), GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());

        std::vector<uint8_t> flipped(rgba.size());
        const size_t row_bytes = static_cast<size_t>(options.size) * 4u;
        for (uint32_t y = 0; y < options.size; ++y) {
            const size_t src = static_cast<size_t>(options.size - 1 - y) * row_bytes;
            const size_t dst = static_cast<size_t>(y) * row_bytes;
            std::copy(rgba.begin() + static_cast<std::ptrdiff_t>(src), rgba.begin() + static_cast<std::ptrdiff_t>(src + row_bytes), flipped.begin() + static_cast<std::ptrdiff_t>(dst));
        }

        const bool wrote_output = options.stdout_png
            ? write_stdout_png(options.size, options.size, flipped.data())
            : write_png(options.output_path, options.size, options.size, flipped.data());
        if (!wrote_output) {
            throw std::runtime_error("failed to write png output");
        }
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";

        destroy_resources(resources);

        if (program != 0) {
            glDeleteProgram(program);
        }
        if (vertex_shader != 0) {
            glDeleteShader(vertex_shader);
        }
        if (fragment_shader != 0) {
            glDeleteShader(fragment_shader);
        }
        if (color_texture != 0) {
            glDeleteTextures(1, &color_texture);
        }
        if (framebuffer != 0) {
            glDeleteFramebuffers(1, &framebuffer);
        }
        if (vao != 0) {
            glDeleteVertexArrays(1, &vao);
        }
        destroy_egl(egl);
        return 1;
    }

    destroy_resources(resources);

    if (program != 0) {
        glDeleteProgram(program);
    }
    if (vertex_shader != 0) {
        glDeleteShader(vertex_shader);
    }
    if (fragment_shader != 0) {
        glDeleteShader(fragment_shader);
    }
    if (color_texture != 0) {
        glDeleteTextures(1, &color_texture);
    }
    if (framebuffer != 0) {
        glDeleteFramebuffers(1, &framebuffer);
    }
    if (vao != 0) {
        glDeleteVertexArrays(1, &vao);
    }
    destroy_egl(egl);
    return 0;
}
