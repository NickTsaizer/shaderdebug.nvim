#include <vulkan/vulkan.h>
#include <png.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#define VK_CHECK(expr)                                                                                                  \
    do {                                                                                                                \
        VkResult shaderdebug_vk_result__ = (expr);                                                                      \
        if (shaderdebug_vk_result__ != VK_SUCCESS) {                                                                    \
            throw std::runtime_error(std::string("Vulkan call failed: ") + #expr + " -> " +                         \
                                     std::to_string(static_cast<int>(shaderdebug_vk_result__)));                       \
        }                                                                                                               \
    } while (0)

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

struct BufferResource {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize size = 0;
};

struct ImageResource {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct PreparedResource {
    ResourceSpec spec;
    std::vector<ImageResource> images;
    std::vector<BufferResource> buffers;
    std::vector<VkDescriptorImageInfo> image_infos;
    std::vector<VkDescriptorBufferInfo> buffer_infos;
    VkSampler sampler = VK_NULL_HANDLE;
};

struct VulkanContext {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue graphics_queue = VK_NULL_HANDLE;
    uint32_t graphics_queue_family = 0;
    VkCommandPool command_pool = VK_NULL_HANDLE;
};

static std::vector<char> read_binary_file(const std::string &path)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        throw std::runtime_error("failed to open file: " + path);
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<char> buffer(static_cast<size_t>(size));
    if (size > 0 && !file.read(buffer.data(), size)) {
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
    out.width = width;
    out.height = height;
    out.rgba.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);

    std::vector<png_bytep> rows(height);
    for (png_uint_32 y = 0; y < height; ++y) {
        rows[y] = out.rgba.data() + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u;
    }
    png_read_image(png, rows.data());
    png_destroy_read_struct(&png, &info, nullptr);
    fclose(file);
    return out;
}

static ImagePixels make_default_image()
{
    ImagePixels out;
    out.width = 64;
    out.height = 64;
    out.rgba.resize(static_cast<size_t>(out.width) * static_cast<size_t>(out.height) * 4u);
    for (uint32_t y = 0; y < out.height; ++y) {
        for (uint32_t x = 0; x < out.width; ++x) {
            const bool checker = ((x / 8) + (y / 8)) % 2 == 0;
            const size_t index = (static_cast<size_t>(y) * out.width + x) * 4u;
            out.rgba[index + 0] = checker ? 255 : 40;
            out.rgba[index + 1] = static_cast<uint8_t>((x * 255) / std::max(1u, out.width - 1));
            out.rgba[index + 2] = static_cast<uint8_t>((y * 255) / std::max(1u, out.height - 1));
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
        std::vector<std::string> fields = split_tabs(line);
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

static uint32_t find_memory_type(VkPhysicalDevice physical_device, uint32_t type_filter, VkMemoryPropertyFlags properties)
{
    VkPhysicalDeviceMemoryProperties memory_properties{};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
    for (uint32_t index = 0; index < memory_properties.memoryTypeCount; ++index) {
        if ((type_filter & (1u << index)) && (memory_properties.memoryTypes[index].propertyFlags & properties) == properties) {
            return index;
        }
    }
    throw std::runtime_error("failed to find suitable memory type");
}

static VkCommandBuffer begin_single_use_commands(const VulkanContext &context)
{
    VkCommandBufferAllocateInfo alloc_info{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    alloc_info.commandPool = context.command_pool;
    alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;

    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    VK_CHECK(vkAllocateCommandBuffers(context.device, &alloc_info, &command_buffer));

    VkCommandBufferBeginInfo begin_info{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VK_CHECK(vkBeginCommandBuffer(command_buffer, &begin_info));
    return command_buffer;
}

static void end_single_use_commands(const VulkanContext &context, VkCommandBuffer command_buffer)
{
    VK_CHECK(vkEndCommandBuffer(command_buffer));
    VkSubmitInfo submit_info{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffer;
    VK_CHECK(vkQueueSubmit(context.graphics_queue, 1, &submit_info, VK_NULL_HANDLE));
    VK_CHECK(vkQueueWaitIdle(context.graphics_queue));
    vkFreeCommandBuffers(context.device, context.command_pool, 1, &command_buffer);
}

static BufferResource create_buffer(
    const VulkanContext &context,
    VkDeviceSize size,
    VkBufferUsageFlags usage,
    VkMemoryPropertyFlags memory_properties)
{
    BufferResource out;
    out.size = size;

    VkBufferCreateInfo create_info{ VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    create_info.size = size;
    create_info.usage = usage;
    create_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VK_CHECK(vkCreateBuffer(context.device, &create_info, nullptr, &out.buffer));

    VkMemoryRequirements requirements{};
    vkGetBufferMemoryRequirements(context.device, out.buffer, &requirements);

    VkMemoryAllocateInfo alloc_info{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    alloc_info.allocationSize = requirements.size;
    alloc_info.memoryTypeIndex = find_memory_type(context.physical_device, requirements.memoryTypeBits, memory_properties);
    VK_CHECK(vkAllocateMemory(context.device, &alloc_info, nullptr, &out.memory));
    VK_CHECK(vkBindBufferMemory(context.device, out.buffer, out.memory, 0));

    return out;
}

static void destroy_buffer(const VulkanContext &context, BufferResource &buffer)
{
    if (buffer.buffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(context.device, buffer.buffer, nullptr);
        buffer.buffer = VK_NULL_HANDLE;
    }
    if (buffer.memory != VK_NULL_HANDLE) {
        vkFreeMemory(context.device, buffer.memory, nullptr);
        buffer.memory = VK_NULL_HANDLE;
    }
}

static ImageResource create_image(
    const VulkanContext &context,
    uint32_t width,
    uint32_t height,
    VkFormat format,
    VkImageUsageFlags usage)
{
    ImageResource out;
    out.width = width;
    out.height = height;

    VkImageCreateInfo create_info{ VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    create_info.imageType = VK_IMAGE_TYPE_2D;
    create_info.extent.width = width;
    create_info.extent.height = height;
    create_info.extent.depth = 1;
    create_info.mipLevels = 1;
    create_info.arrayLayers = 1;
    create_info.format = format;
    create_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    create_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    create_info.usage = usage;
    create_info.samples = VK_SAMPLE_COUNT_1_BIT;
    create_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VK_CHECK(vkCreateImage(context.device, &create_info, nullptr, &out.image));

    VkMemoryRequirements requirements{};
    vkGetImageMemoryRequirements(context.device, out.image, &requirements);

    VkMemoryAllocateInfo alloc_info{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    alloc_info.allocationSize = requirements.size;
    alloc_info.memoryTypeIndex = find_memory_type(
        context.physical_device, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VK_CHECK(vkAllocateMemory(context.device, &alloc_info, nullptr, &out.memory));
    VK_CHECK(vkBindImageMemory(context.device, out.image, out.memory, 0));

    VkImageViewCreateInfo view_info{ VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    view_info.image = out.image;
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = format;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;
    VK_CHECK(vkCreateImageView(context.device, &view_info, nullptr, &out.view));

    return out;
}

static void destroy_image(const VulkanContext &context, ImageResource &image)
{
    if (image.view != VK_NULL_HANDLE) {
        vkDestroyImageView(context.device, image.view, nullptr);
        image.view = VK_NULL_HANDLE;
    }
    if (image.image != VK_NULL_HANDLE) {
        vkDestroyImage(context.device, image.image, nullptr);
        image.image = VK_NULL_HANDLE;
    }
    if (image.memory != VK_NULL_HANDLE) {
        vkFreeMemory(context.device, image.memory, nullptr);
        image.memory = VK_NULL_HANDLE;
    }
}

static void copy_buffer(const VulkanContext &context, VkBuffer source, VkBuffer destination, VkDeviceSize size)
{
    VkCommandBuffer command_buffer = begin_single_use_commands(context);
    VkBufferCopy copy_region{};
    copy_region.size = size;
    vkCmdCopyBuffer(command_buffer, source, destination, 1, &copy_region);
    end_single_use_commands(context, command_buffer);
}

static void transition_image_layout(
    const VulkanContext &context,
    VkImage image,
    VkImageLayout old_layout,
    VkImageLayout new_layout,
    VkPipelineStageFlags source_stage,
    VkPipelineStageFlags destination_stage,
    VkAccessFlags source_access,
    VkAccessFlags destination_access)
{
    VkCommandBuffer command_buffer = begin_single_use_commands(context);
    VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = source_access;
    barrier.dstAccessMask = destination_access;

    vkCmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        0,
        0,
        nullptr,
        0,
        nullptr,
        1,
        &barrier);

    end_single_use_commands(context, command_buffer);
}

static void copy_buffer_to_image(
    const VulkanContext &context,
    VkBuffer buffer,
    VkImage image,
    uint32_t width,
    uint32_t height)
{
    VkCommandBuffer command_buffer = begin_single_use_commands(context);
    VkBufferImageCopy region{};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = { width, height, 1 };
    vkCmdCopyBufferToImage(command_buffer, buffer, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    end_single_use_commands(context, command_buffer);
}

static VkSampler create_sampler(const VulkanContext &context, const std::string &mode)
{
    const bool nearest = mode == "nearest";
    VkSamplerCreateInfo sampler_info{ VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    sampler_info.magFilter = nearest ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
    sampler_info.minFilter = nearest ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
    sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.maxAnisotropy = 1.0f;
    sampler_info.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = VK_FALSE;
    sampler_info.compareEnable = VK_FALSE;

    VkSampler sampler = VK_NULL_HANDLE;
    VK_CHECK(vkCreateSampler(context.device, &sampler_info, nullptr, &sampler));
    return sampler;
}

static ImageResource upload_image_pixels(const VulkanContext &context, const ImagePixels &pixels)
{
    BufferResource staging = create_buffer(
        context,
        static_cast<VkDeviceSize>(pixels.rgba.size()),
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    void *mapped = nullptr;
    VK_CHECK(vkMapMemory(context.device, staging.memory, 0, staging.size, 0, &mapped));
    std::memcpy(mapped, pixels.rgba.data(), pixels.rgba.size());
    vkUnmapMemory(context.device, staging.memory);

    ImageResource image = create_image(
        context,
        pixels.width,
        pixels.height,
        VK_FORMAT_R8G8B8A8_UNORM,
        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT);

    transition_image_layout(
        context,
        image.image,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        VK_ACCESS_TRANSFER_WRITE_BIT);
    copy_buffer_to_image(context, staging.buffer, image.image, pixels.width, pixels.height);
    transition_image_layout(
        context,
        image.image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT);

    destroy_buffer(context, staging);
    return image;
}

static VkDescriptorType descriptor_type_for_kind(ResourceKind kind)
{
    switch (kind) {
    case ResourceKind::CombinedImageSampler:
        return VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    case ResourceKind::SampledImage:
        return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    case ResourceKind::Sampler:
        return VK_DESCRIPTOR_TYPE_SAMPLER;
    case ResourceKind::UniformBuffer:
        return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    case ResourceKind::StorageBuffer:
        return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    }
    throw std::runtime_error("invalid descriptor kind");
}

static VkShaderModule create_shader_module(const VulkanContext &context, const std::vector<char> &code)
{
    if (code.empty() || (code.size() % 4) != 0) {
        throw std::runtime_error("invalid SPIR-V blob");
    }

    VkShaderModuleCreateInfo create_info{ VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    create_info.codeSize = code.size();
    create_info.pCode = reinterpret_cast<const uint32_t *>(code.data());

    VkShaderModule module = VK_NULL_HANDLE;
    VK_CHECK(vkCreateShaderModule(context.device, &create_info, nullptr, &module));
    return module;
}

static void init_vulkan(VulkanContext &context, bool needs_descriptor_array)
{
    VkApplicationInfo app_info{ VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app_info.pApplicationName = "shaderdebug";
    app_info.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "shaderdebug";
    app_info.engineVersion = VK_MAKE_VERSION(0, 1, 0);
    app_info.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo instance_info{ VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    instance_info.pApplicationInfo = &app_info;
    VK_CHECK(vkCreateInstance(&instance_info, nullptr, &context.instance));

    uint32_t physical_device_count = 0;
    VK_CHECK(vkEnumeratePhysicalDevices(context.instance, &physical_device_count, nullptr));
    if (physical_device_count == 0) {
        throw std::runtime_error("no Vulkan physical devices available");
    }

    std::vector<VkPhysicalDevice> physical_devices(physical_device_count);
    VK_CHECK(vkEnumeratePhysicalDevices(context.instance, &physical_device_count, physical_devices.data()));

    for (VkPhysicalDevice candidate : physical_devices) {
        uint32_t queue_family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, nullptr);
        std::vector<VkQueueFamilyProperties> queue_families(queue_family_count);
        vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, queue_families.data());
        for (uint32_t family = 0; family < queue_family_count; ++family) {
            if (queue_families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                context.physical_device = candidate;
                context.graphics_queue_family = family;
                break;
            }
        }
        if (context.physical_device != VK_NULL_HANDLE) {
            break;
        }
    }

    if (context.physical_device == VK_NULL_HANDLE) {
        throw std::runtime_error("no Vulkan graphics queue family found");
    }

    VkPhysicalDeviceVulkan12Features available_vulkan12{ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceFeatures2 features2{ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    features2.pNext = &available_vulkan12;
    vkGetPhysicalDeviceFeatures2(context.physical_device, &features2);

    VkPhysicalDeviceVulkan12Features enabled_vulkan12{ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    if (needs_descriptor_array) {
        if (!available_vulkan12.runtimeDescriptorArray) {
            throw std::runtime_error("runtimeDescriptorArray is required for reflected texture arrays");
        }
        enabled_vulkan12.runtimeDescriptorArray = VK_TRUE;
        if (available_vulkan12.descriptorBindingPartiallyBound) {
            enabled_vulkan12.descriptorBindingPartiallyBound = VK_TRUE;
        }
        if (available_vulkan12.shaderSampledImageArrayNonUniformIndexing) {
            enabled_vulkan12.shaderSampledImageArrayNonUniformIndexing = VK_TRUE;
        }
        if (available_vulkan12.descriptorBindingVariableDescriptorCount) {
            enabled_vulkan12.descriptorBindingVariableDescriptorCount = VK_TRUE;
        }
    }

    const float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info{ VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    queue_info.queueFamilyIndex = context.graphics_queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &queue_priority;

    VkDeviceCreateInfo device_info{ VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.pNext = &enabled_vulkan12;
    VK_CHECK(vkCreateDevice(context.physical_device, &device_info, nullptr, &context.device));
    vkGetDeviceQueue(context.device, context.graphics_queue_family, 0, &context.graphics_queue);

    VkCommandPoolCreateInfo pool_info{ VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = context.graphics_queue_family;
    VK_CHECK(vkCreateCommandPool(context.device, &pool_info, nullptr, &context.command_pool));
}

static void destroy_vulkan(VulkanContext &context)
{
    if (context.command_pool != VK_NULL_HANDLE) {
        vkDestroyCommandPool(context.device, context.command_pool, nullptr);
        context.command_pool = VK_NULL_HANDLE;
    }
    if (context.device != VK_NULL_HANDLE) {
        vkDestroyDevice(context.device, nullptr);
        context.device = VK_NULL_HANDLE;
    }
    if (context.instance != VK_NULL_HANDLE) {
        vkDestroyInstance(context.instance, nullptr);
        context.instance = VK_NULL_HANDLE;
    }
}

static std::vector<VkDescriptorSetLayout> create_set_layouts(
    const VulkanContext &context,
    const std::vector<ResourceSpec> &resources,
    uint32_t max_set)
{
    std::map<uint32_t, std::vector<VkDescriptorSetLayoutBinding>> bindings_by_set;
    for (const ResourceSpec &resource : resources) {
        VkDescriptorSetLayoutBinding binding{};
        binding.binding = resource.binding;
        binding.descriptorType = descriptor_type_for_kind(resource.kind);
        binding.descriptorCount = std::max(resource.count, 1u);
        binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        bindings_by_set[resource.set].push_back(binding);
    }

    std::vector<VkDescriptorSetLayout> set_layouts(max_set + 1, VK_NULL_HANDLE);
    for (uint32_t set = 0; set <= max_set; ++set) {
        std::vector<VkDescriptorSetLayoutBinding> bindings = bindings_by_set[set];
        std::sort(bindings.begin(), bindings.end(), [](const auto &lhs, const auto &rhs) {
            return lhs.binding < rhs.binding;
        });
        VkDescriptorSetLayoutCreateInfo create_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
        create_info.bindingCount = static_cast<uint32_t>(bindings.size());
        create_info.pBindings = bindings.empty() ? nullptr : bindings.data();
        VK_CHECK(vkCreateDescriptorSetLayout(context.device, &create_info, nullptr, &set_layouts[set]));
    }
    return set_layouts;
}

static std::vector<VkDescriptorSet> allocate_descriptor_sets(
    const VulkanContext &context,
    const std::vector<VkDescriptorSetLayout> &set_layouts,
    VkDescriptorPool &descriptor_pool,
    const std::vector<ResourceSpec> &resources)
{
    std::map<VkDescriptorType, uint32_t> pool_counts;
    for (const ResourceSpec &resource : resources) {
        pool_counts[descriptor_type_for_kind(resource.kind)] += std::max(resource.count, 1u);
    }

    std::vector<VkDescriptorPoolSize> pool_sizes;
    for (const auto &[type, count] : pool_counts) {
        VkDescriptorPoolSize size{};
        size.type = type;
        size.descriptorCount = count;
        pool_sizes.push_back(size);
    }

    VkDescriptorPoolCreateInfo pool_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    pool_info.maxSets = static_cast<uint32_t>(set_layouts.size());
    pool_info.poolSizeCount = static_cast<uint32_t>(pool_sizes.size());
    pool_info.pPoolSizes = pool_sizes.empty() ? nullptr : pool_sizes.data();
    VK_CHECK(vkCreateDescriptorPool(context.device, &pool_info, nullptr, &descriptor_pool));

    VkDescriptorSetAllocateInfo alloc_info{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    alloc_info.descriptorPool = descriptor_pool;
    alloc_info.descriptorSetCount = static_cast<uint32_t>(set_layouts.size());
    alloc_info.pSetLayouts = set_layouts.data();

    std::vector<VkDescriptorSet> descriptor_sets(set_layouts.size(), VK_NULL_HANDLE);
    VK_CHECK(vkAllocateDescriptorSets(context.device, &alloc_info, descriptor_sets.data()));
    return descriptor_sets;
}

static PreparedResource prepare_resource(const VulkanContext &context, const ResourceSpec &spec)
{
    PreparedResource prepared;
    prepared.spec = spec;

    if (spec.kind == ResourceKind::CombinedImageSampler || spec.kind == ResourceKind::SampledImage) {
        const std::string sampler_mode = "linear";
        if (spec.kind == ResourceKind::CombinedImageSampler) {
            prepared.sampler = create_sampler(context, sampler_mode);
        }

        for (const std::string &path : spec.values) {
            const ImagePixels pixels = path == "__default__" ? make_default_image() : read_png(path);
            prepared.images.push_back(upload_image_pixels(context, pixels));
        }

        prepared.image_infos.resize(prepared.images.size());
        for (size_t index = 0; index < prepared.images.size(); ++index) {
            prepared.image_infos[index].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            prepared.image_infos[index].imageView = prepared.images[index].view;
            prepared.image_infos[index].sampler = spec.kind == ResourceKind::CombinedImageSampler ? prepared.sampler : VK_NULL_HANDLE;
        }
    } else if (spec.kind == ResourceKind::Sampler) {
        const std::string sampler_mode = spec.values.empty() ? "linear" : spec.values.front();
        prepared.sampler = create_sampler(context, sampler_mode);
        prepared.image_infos.resize(1);
        prepared.image_infos[0].sampler = prepared.sampler;
    } else if (spec.kind == ResourceKind::UniformBuffer || spec.kind == ResourceKind::StorageBuffer) {
        for (const std::string &path : spec.values) {
            const std::vector<char> blob = read_binary_file(path);
            BufferResource buffer = create_buffer(
                context,
                static_cast<VkDeviceSize>(blob.size()),
                (spec.kind == ResourceKind::UniformBuffer ? VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT : VK_BUFFER_USAGE_STORAGE_BUFFER_BIT),
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            void *mapped = nullptr;
            VK_CHECK(vkMapMemory(context.device, buffer.memory, 0, buffer.size, 0, &mapped));
            std::memcpy(mapped, blob.data(), blob.size());
            vkUnmapMemory(context.device, buffer.memory);
            prepared.buffers.push_back(buffer);
        }

        prepared.buffer_infos.resize(prepared.buffers.size());
        for (size_t index = 0; index < prepared.buffers.size(); ++index) {
            prepared.buffer_infos[index].buffer = prepared.buffers[index].buffer;
            prepared.buffer_infos[index].offset = 0;
            prepared.buffer_infos[index].range = prepared.buffers[index].size;
        }
    }

    return prepared;
}

static void destroy_prepared_resource(const VulkanContext &context, PreparedResource &resource)
{
    for (ImageResource &image : resource.images) {
        destroy_image(context, image);
    }
    for (BufferResource &buffer : resource.buffers) {
        destroy_buffer(context, buffer);
    }
    if (resource.sampler != VK_NULL_HANDLE) {
        vkDestroySampler(context.device, resource.sampler, nullptr);
        resource.sampler = VK_NULL_HANDLE;
    }
}

static void update_descriptor_sets(
    const VulkanContext &context,
    const std::vector<VkDescriptorSet> &descriptor_sets,
    std::vector<PreparedResource> &resources)
{
    std::vector<VkWriteDescriptorSet> writes;
    writes.reserve(resources.size());
    for (PreparedResource &resource : resources) {
        VkWriteDescriptorSet write{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        write.dstSet = descriptor_sets[resource.spec.set];
        write.dstBinding = resource.spec.binding;
        write.descriptorCount = std::max(resource.spec.count, 1u);
        write.descriptorType = descriptor_type_for_kind(resource.spec.kind);
        if (resource.spec.kind == ResourceKind::CombinedImageSampler || resource.spec.kind == ResourceKind::SampledImage ||
            resource.spec.kind == ResourceKind::Sampler) {
            write.pImageInfo = resource.image_infos.data();
            write.descriptorCount = static_cast<uint32_t>(resource.image_infos.size());
        } else {
            write.pBufferInfo = resource.buffer_infos.data();
            write.descriptorCount = static_cast<uint32_t>(resource.buffer_infos.size());
        }
        writes.push_back(write);
    }
    vkUpdateDescriptorSets(context.device, static_cast<uint32_t>(writes.size()), writes.data(), 0, nullptr);
}

static void record_and_submit_render(
    const VulkanContext &context,
    const Options &options,
    const std::vector<VkDescriptorSet> &descriptor_sets,
    VkPipelineLayout pipeline_layout,
    VkRenderPass render_pass,
    VkFramebuffer framebuffer,
    VkPipeline pipeline,
    VkImage render_target,
    VkBuffer readback_buffer)
{
    VkCommandBufferAllocateInfo alloc_info{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    alloc_info.commandPool = context.command_pool;
    alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;

    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    VK_CHECK(vkAllocateCommandBuffers(context.device, &alloc_info, &command_buffer));

    VkCommandBufferBeginInfo begin_info{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VK_CHECK(vkBeginCommandBuffer(command_buffer, &begin_info));

    VkClearValue clear_value{};
    clear_value.color = { { 0.0f, 0.0f, 0.0f, 1.0f } };

    VkRenderPassBeginInfo render_pass_info{ VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    render_pass_info.renderPass = render_pass;
    render_pass_info.framebuffer = framebuffer;
    render_pass_info.renderArea.extent = { options.size, options.size };
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_value;

    vkCmdBeginRenderPass(command_buffer, &render_pass_info, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    if (!descriptor_sets.empty()) {
        vkCmdBindDescriptorSets(
            command_buffer,
            VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline_layout,
            0,
            static_cast<uint32_t>(descriptor_sets.size()),
            descriptor_sets.data(),
            0,
            nullptr);
    }
    vkCmdDraw(command_buffer, 3, 1, 0, 0);
    vkCmdEndRenderPass(command_buffer);

    VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = render_target;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    vkCmdPipelineBarrier(
        command_buffer,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        nullptr,
        0,
        nullptr,
        1,
        &barrier);

    VkBufferImageCopy copy_region{};
    copy_region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy_region.imageSubresource.layerCount = 1;
    copy_region.imageExtent = { options.size, options.size, 1 };
    vkCmdCopyImageToBuffer(
        command_buffer,
        render_target,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        readback_buffer,
        1,
        &copy_region);

    VK_CHECK(vkEndCommandBuffer(command_buffer));

    VkFenceCreateInfo fence_info{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    VK_CHECK(vkCreateFence(context.device, &fence_info, nullptr, &fence));

    VkSubmitInfo submit_info{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffer;
    VK_CHECK(vkQueueSubmit(context.graphics_queue, 1, &submit_info, fence));
    VK_CHECK(vkWaitForFences(context.device, 1, &fence, VK_TRUE, UINT64_MAX));

    vkDestroyFence(context.device, fence, nullptr);
    vkFreeCommandBuffers(context.device, context.command_pool, 1, &command_buffer);
}

static int run(const Options &options)
{
    const std::vector<ResourceSpec> resource_specs = parse_manifest(options.manifest_path);
    bool needs_descriptor_array = false;
    uint32_t max_set = 0;
    for (const ResourceSpec &resource : resource_specs) {
        max_set = std::max(max_set, resource.set);
        if (resource.count > 1) {
            needs_descriptor_array = true;
        }
    }

    VulkanContext context;
    init_vulkan(context, needs_descriptor_array);

    std::vector<PreparedResource> prepared_resources;
    std::vector<VkDescriptorSetLayout> set_layouts;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkRenderPass render_pass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkShaderModule vertex_module = VK_NULL_HANDLE;
    VkShaderModule fragment_module = VK_NULL_HANDLE;
    ImageResource render_target;
    BufferResource readback_buffer;

    try {
        for (const ResourceSpec &resource : resource_specs) {
            prepared_resources.push_back(prepare_resource(context, resource));
        }

        set_layouts = create_set_layouts(context, resource_specs, max_set);
        const std::vector<VkDescriptorSet> descriptor_sets = allocate_descriptor_sets(context, set_layouts, descriptor_pool, resource_specs);
        update_descriptor_sets(context, descriptor_sets, prepared_resources);

        const std::vector<char> vertex_code = read_binary_file(options.vertex_path);
        const std::vector<char> fragment_code = read_binary_file(options.fragment_path);
        vertex_module = create_shader_module(context, vertex_code);
        fragment_module = create_shader_module(context, fragment_code);

        render_target = create_image(
            context,
            options.size,
            options.size,
            VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);

        VkAttachmentDescription color_attachment{};
        color_attachment.format = VK_FORMAT_R8G8B8A8_UNORM;
        color_attachment.samples = VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkAttachmentReference color_reference{};
        color_reference.attachment = 0;
        color_reference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkSubpassDescription subpass{};
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_reference;

        VkSubpassDependency dependency{};
        dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkRenderPassCreateInfo render_pass_info{ VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
        render_pass_info.attachmentCount = 1;
        render_pass_info.pAttachments = &color_attachment;
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;
        VK_CHECK(vkCreateRenderPass(context.device, &render_pass_info, nullptr, &render_pass));

        VkFramebufferCreateInfo framebuffer_info{ VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        framebuffer_info.renderPass = render_pass;
        framebuffer_info.attachmentCount = 1;
        framebuffer_info.pAttachments = &render_target.view;
        framebuffer_info.width = options.size;
        framebuffer_info.height = options.size;
        framebuffer_info.layers = 1;
        VK_CHECK(vkCreateFramebuffer(context.device, &framebuffer_info, nullptr, &framebuffer));

        VkPipelineLayoutCreateInfo layout_info{ VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        layout_info.setLayoutCount = static_cast<uint32_t>(set_layouts.size());
        layout_info.pSetLayouts = set_layouts.data();
        VK_CHECK(vkCreatePipelineLayout(context.device, &layout_info, nullptr, &pipeline_layout));

        VkPipelineShaderStageCreateInfo vertex_stage{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO };
        vertex_stage.stage = VK_SHADER_STAGE_VERTEX_BIT;
        vertex_stage.module = vertex_module;
        vertex_stage.pName = "main";

        VkPipelineShaderStageCreateInfo fragment_stage{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO };
        fragment_stage.stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        fragment_stage.module = fragment_module;
        fragment_stage.pName = options.entry_name.c_str();

        std::array<VkPipelineShaderStageCreateInfo, 2> stages = { vertex_stage, fragment_stage };

        VkPipelineVertexInputStateCreateInfo vertex_input{ VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        VkPipelineInputAssemblyStateCreateInfo input_assembly{ VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
        input_assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkViewport viewport{};
        viewport.x = 0.0f;
        viewport.y = 0.0f;
        viewport.width = static_cast<float>(options.size);
        viewport.height = static_cast<float>(options.size);
        viewport.minDepth = 0.0f;
        viewport.maxDepth = 1.0f;

        VkRect2D scissor{};
        scissor.extent = { options.size, options.size };

        VkPipelineViewportStateCreateInfo viewport_state{ VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
        viewport_state.viewportCount = 1;
        viewport_state.pViewports = &viewport;
        viewport_state.scissorCount = 1;
        viewport_state.pScissors = &scissor;

        VkPipelineRasterizationStateCreateInfo rasterizer{ VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
        rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
        rasterizer.cullMode = VK_CULL_MODE_NONE;
        rasterizer.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rasterizer.lineWidth = 1.0f;

        VkPipelineMultisampleStateCreateInfo multisample{ VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState color_blend_attachment{};
        color_blend_attachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                               VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

        VkPipelineColorBlendStateCreateInfo color_blend{ VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
        color_blend.attachmentCount = 1;
        color_blend.pAttachments = &color_blend_attachment;

        VkGraphicsPipelineCreateInfo pipeline_info{ VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
        pipeline_info.stageCount = static_cast<uint32_t>(stages.size());
        pipeline_info.pStages = stages.data();
        pipeline_info.pVertexInputState = &vertex_input;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisample;
        pipeline_info.pColorBlendState = &color_blend;
        pipeline_info.layout = pipeline_layout;
        pipeline_info.renderPass = render_pass;
        pipeline_info.subpass = 0;
        VK_CHECK(vkCreateGraphicsPipelines(context.device, VK_NULL_HANDLE, 1, &pipeline_info, nullptr, &pipeline));

        readback_buffer = create_buffer(
            context,
            static_cast<VkDeviceSize>(options.size) * static_cast<VkDeviceSize>(options.size) * 4u,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        record_and_submit_render(
            context,
            options,
            descriptor_sets,
            pipeline_layout,
            render_pass,
            framebuffer,
            pipeline,
            render_target.image,
            readback_buffer.buffer);

        void *mapped = nullptr;
        VK_CHECK(vkMapMemory(context.device, readback_buffer.memory, 0, readback_buffer.size, 0, &mapped));
        const bool wrote_output = options.stdout_png
            ? write_stdout_png(options.size, options.size, static_cast<const uint8_t *>(mapped))
            : write_png(options.output_path, options.size, options.size, static_cast<const uint8_t *>(mapped));
        if (!wrote_output) {
            vkUnmapMemory(context.device, readback_buffer.memory);
            throw std::runtime_error("failed to write PNG output");
        }
        vkUnmapMemory(context.device, readback_buffer.memory);
    } catch (...) {
        destroy_buffer(context, readback_buffer);
        destroy_image(context, render_target);
        if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(context.device, pipeline, nullptr);
        }
        if (pipeline_layout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(context.device, pipeline_layout, nullptr);
        }
        if (framebuffer != VK_NULL_HANDLE) {
            vkDestroyFramebuffer(context.device, framebuffer, nullptr);
        }
        if (render_pass != VK_NULL_HANDLE) {
            vkDestroyRenderPass(context.device, render_pass, nullptr);
        }
        if (vertex_module != VK_NULL_HANDLE) {
            vkDestroyShaderModule(context.device, vertex_module, nullptr);
        }
        if (fragment_module != VK_NULL_HANDLE) {
            vkDestroyShaderModule(context.device, fragment_module, nullptr);
        }
        if (descriptor_pool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(context.device, descriptor_pool, nullptr);
        }
        for (VkDescriptorSetLayout layout : set_layouts) {
            if (layout != VK_NULL_HANDLE) {
                vkDestroyDescriptorSetLayout(context.device, layout, nullptr);
            }
        }
        for (PreparedResource &resource : prepared_resources) {
            destroy_prepared_resource(context, resource);
        }
        destroy_vulkan(context);
        throw;
    }

    destroy_buffer(context, readback_buffer);
    destroy_image(context, render_target);
    if (pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(context.device, pipeline, nullptr);
    }
    if (pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(context.device, pipeline_layout, nullptr);
    }
    if (framebuffer != VK_NULL_HANDLE) {
        vkDestroyFramebuffer(context.device, framebuffer, nullptr);
    }
    if (render_pass != VK_NULL_HANDLE) {
        vkDestroyRenderPass(context.device, render_pass, nullptr);
    }
    if (vertex_module != VK_NULL_HANDLE) {
        vkDestroyShaderModule(context.device, vertex_module, nullptr);
    }
    if (fragment_module != VK_NULL_HANDLE) {
        vkDestroyShaderModule(context.device, fragment_module, nullptr);
    }
    if (descriptor_pool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(context.device, descriptor_pool, nullptr);
    }
    for (VkDescriptorSetLayout layout : set_layouts) {
        if (layout != VK_NULL_HANDLE) {
            vkDestroyDescriptorSetLayout(context.device, layout, nullptr);
        }
    }
    for (PreparedResource &resource : prepared_resources) {
        destroy_prepared_resource(context, resource);
    }
    destroy_vulkan(context);
    return 0;
}

int main(int argc, char **argv)
{
    Options options;
    if (!parse_args(argc, argv, options)) {
        std::cerr << "usage: shaderdebug_renderer --vertex file.spv --fragment file.spv --manifest file.tsv --entry name (--output out.png | --stdout-png) [--size 512]\n";
        return 1;
    }

    try {
        return run(options);
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
