const std = @import("std");

const vk = @import("vulkan");
const saturn = @import("../../root.zig");

const Device = @import("device.zig");
const GpuAllocator = @import("gpu_allocator.zig");
const Binding = @import("bindless_descriptor.zig").Binding;

const Self = @This();

handle: vk.Image,
view_handle: vk.ImageView,
allocation: ?GpuAllocator.Allocation = null,

extent: vk.Extent2D,
format: vk.Format,
usage: vk.ImageUsageFlags,

sampled_binding: ?Binding = null,
storage_binding: ?Binding = null,

pub fn init2D(device: *Device, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, memory_location: GpuAllocator.MemoryLocation) !Self {
    const handle = try device.proxy.createImage(&.{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer device.proxy.destroyImage(handle, null);

    const allocation = try device.gpu_allocator.alloc(device.proxy.getImageMemoryRequirements(handle), memory_location);
    errdefer device.gpu_allocator.free(allocation);
    try device.proxy.bindImageMemory(handle, allocation.memory, allocation.offset);

    const view_handle = try device.proxy.createImageView(&.{
        .view_type = .@"2d",
        .image = handle,
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = getFormatAspectMask(format),
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer device.proxy.destroyImageView(view_handle, null);

    return .{
        .extent = extent,
        .format = format,
        .usage = usage,
        .handle = handle,
        .view_handle = view_handle,
        .allocation = allocation,
    };
}

pub fn deinit(self: Self, device: *Device) void {
    device.proxy.destroyImageView(self.view_handle, null);
    device.proxy.destroyImage(self.handle, null);

    if (self.allocation) |allocation|
        device.gpu_allocator.free(allocation);
}

pub fn hostImageCopy(
    self: *const Self,
    device: *Device,
    final_layout: vk.ImageLayout,
    data: []const u8,
) !void {
    {
        const transition_info = vk.HostImageLayoutTransitionInfo{
            .image = self.handle,
            .old_layout = .undefined,
            .new_layout = final_layout,
            .subresource_range = .{
                .aspect_mask = getFormatAspectMask(self.format),
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        try device.proxy.transitionImageLayoutEXT(1, @ptrCast(&transition_info));
    }

    {
        const region: vk.MemoryToImageCopyEXT = .{
            .p_host_pointer = data.ptr,
            .memory_row_length = 0,
            .memory_image_height = 0,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = getFormatAspectMask(self.format),
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
        };

        const copy_info: vk.CopyMemoryToImageInfo = .{
            .dst_image = self.handle,
            .dst_image_layout = final_layout,
            .region_count = 1,
            .p_regions = @ptrCast(&region),
        };
        try device.proxy.copyMemoryToImageEXT(&copy_info);
    }
}

pub fn getVkFormat(format: saturn.TextureFormat) vk.Format {
    return switch (format) {
        .rgba8_unorm => .r8g8b8a8_unorm,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .rgba16_float => .r16g16b16a16_sfloat,
        .depth32_float => .d32_sfloat,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc1_rgba_srgb => .bc1_rgba_srgb_block,
        .bc2_rgba_unorm => .bc2_unorm_block,
        .bc2_rgba_srgb => .bc2_srgb_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc3_rgba_srgb => .bc3_srgb_block,
        .bc4_r_unorm => .bc4_unorm_block,
        .bc4_r_snorm => .bc4_snorm_block,
        .bc5_rg_unorm => .bc5_unorm_block,
        .bc5_rg_snorm => .bc5_snorm_block,
        .bc6h_rgb_ufloat => .bc6h_ufloat_block,
        .bc6h_rgb_sfloat => .bc6h_sfloat_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
        .bc7_rgba_srgb => .bc7_srgb_block,
    };
}

pub fn getVkImageUsage(usage: saturn.TextureUsage, is_color: bool) vk.ImageUsageFlags {
    return .{
        .transfer_src_bit = usage.transfer,
        .transfer_dst_bit = usage.transfer,
        .sampled_bit = usage.sampled,
        .storage_bit = usage.storage,
        .color_attachment_bit = usage.attachment and is_color,
        .depth_stencil_attachment_bit = usage.attachment and !is_color,
        .host_transfer_bit = usage.host_transfer,
    };
}

pub fn getFormatAspectMask(format: vk.Format) vk.ImageAspectFlags {
    return switch (format) {
        // Depth-only formats
        .d16_unorm, .d32_sfloat, .x8_d24_unorm_pack32 => .{ .depth_bit = true },

        // Stencil-only formats
        .s8_uint => .{ .stencil_bit = true },

        // Depth-stencil formats
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true },

        // All other formats (color formats)
        else => .{ .color_bit = true },
    };
}
