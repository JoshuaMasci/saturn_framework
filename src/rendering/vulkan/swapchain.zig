const std = @import("std");

const vk = @import("vulkan");

const Texture = @import("texture.zig");
const Device = @import("device.zig");

const MAX_IMAGE_COUNT: u32 = 8;

pub const SwapchainImage = struct {
    swapchain: vk.SwapchainKHR,
    index: u32,
    present_semaphore: vk.Semaphore,
    texture: Texture,
};

const Self = @This();

out_of_date: bool = false,
device: *Device,
surface: vk.SurfaceKHR,
handle: vk.SwapchainKHR,

image_count: usize,
textures: [MAX_IMAGE_COUNT]Texture,
present_semaphores: [MAX_IMAGE_COUNT]vk.Semaphore,

//Info
extent: vk.Extent2D,
usage: vk.ImageUsageFlags,
format: vk.Format,
color_space: vk.ColorSpaceKHR,
transform: vk.SurfaceTransformFlagsKHR,
composite_alpha: vk.CompositeAlphaFlagsKHR,
present_mode: vk.PresentModeKHR,

pub fn init(
    device: *Device,
    surface: vk.SurfaceKHR,
    window_extent: vk.Extent2D,
    image_count: u32,
    usage: vk.ImageUsageFlags,
    format: vk.Format,
    present_mode: vk.PresentModeKHR,
    old_swapchain: ?vk.SwapchainKHR,
) !Self {
    const surface_capabilities = try device.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(device.physical_device.handle, surface);

    const final_image_count = std.math.clamp(image_count, surface_capabilities.min_image_count, @max(surface_capabilities.max_image_count, MAX_IMAGE_COUNT));
    const extent: vk.Extent2D = .{
        .width = std.math.clamp(window_extent.width, surface_capabilities.min_image_extent.width, surface_capabilities.max_image_extent.width),
        .height = std.math.clamp(window_extent.height, surface_capabilities.min_image_extent.height, surface_capabilities.max_image_extent.height),
    };

    const color_space = .srgb_nonlinear_khr;
    const transform = surface_capabilities.current_transform;
    const composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };

    const handle = try device.proxy.createSwapchainKHR(&.{
        .flags = .{},
        .surface = surface,
        .min_image_count = final_image_count,
        .image_format = format,
        .image_color_space = color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = usage,
        .image_sharing_mode = .exclusive,
        .pre_transform = transform,
        .composite_alpha = composite_alpha,
        .present_mode = present_mode,
        .clipped = .false,
        .old_swapchain = old_swapchain orelse .null_handle,
    }, null);

    var actual_image_count: u32 = 0;
    _ = try device.proxy.getSwapchainImagesKHR(handle, &actual_image_count, null);

    if (actual_image_count > MAX_IMAGE_COUNT) {
        return error.TooManyImages;
    }

    var image_handles: [MAX_IMAGE_COUNT]vk.Image = undefined;
    _ = try device.proxy.getSwapchainImagesKHR(handle, &actual_image_count, &image_handles);

    var textures: [MAX_IMAGE_COUNT]Texture = undefined;
    var present_semaphores: [MAX_IMAGE_COUNT]vk.Semaphore = undefined;

    for (image_handles[0..actual_image_count], textures[0..actual_image_count], present_semaphores[0..actual_image_count]) |image_handle, *swapchain_image, *semaphore| {
        const view_handle = try device.proxy.createImageView(&.{
            .view_type = .@"2d",
            .image = image_handle,
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        swapchain_image.* = .{
            .handle = image_handle,
            .view_handle = view_handle,

            .extent = extent,
            .mip_levels = 1,
            .format = format,
            .usage = usage,
        };
        semaphore.* = try device.proxy.createSemaphore(&.{}, null);
    }

    return .{
        .device = device,
        .surface = surface,
        .handle = handle,
        .image_count = actual_image_count,
        .textures = textures,
        .present_semaphores = present_semaphores,
        .extent = extent,
        .usage = usage,
        .format = format,
        .color_space = color_space,
        .transform = transform,
        .composite_alpha = composite_alpha,
        .present_mode = present_mode,
    };
}

pub fn deinit(self: Self) void {
    for (self.textures[0..self.image_count], self.present_semaphores[0..self.image_count]) |image, semaphore| {
        self.device.proxy.destroyImageView(image.view_handle, null);
        self.device.proxy.destroySemaphore(semaphore, null);
    }

    self.device.proxy.destroySwapchainKHR(self.handle, null);
}

pub fn rebuild(self: *Self, size: vk.Extent2D) !void {
    const new: Self = try .init(
        self.device,
        self.surface,
        size,
        @intCast(self.image_count),
        self.usage,
        self.format,
        self.present_mode,
        self.handle,
    );
    self.deinit();
    self.* = new;
}

pub fn acquireNextImage(
    self: *Self,
    timeout: ?u64,
    wait_semaphore: vk.Semaphore,
    wait_fence: vk.Fence,
) vk.DeviceProxy.AcquireNextImageKHRError!u32 {
    const result = try self.device.proxy.acquireNextImageKHR(
        self.handle,
        timeout orelse std.math.maxInt(u64),
        wait_semaphore,
        wait_fence,
    );

    if (result.result == .suboptimal_khr) {
        std.log.warn("acquireNextImageKHR Swapchain Suboptimal", .{});
        self.out_of_date = true;
    }

    return result.image_index;
}

pub fn queuePresent(
    self: *Self,
    queue: vk.Queue,
    index: u32,
    present_semaphore: vk.Semaphore,
) vk.DeviceProxy.QueuePresentKHRError!void {
    const present_result = try self.device.proxy.queuePresentKHR(queue, &.{
        .swapchain_count = 1,
        .p_image_indices = @ptrCast(&index),
        .p_swapchains = @ptrCast(&self.handle),
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&present_semaphore),
    });

    if (present_result == .suboptimal_khr) {
        std.log.warn("queuePresentKHR Swapchain Suboptimal", .{});
        self.out_of_date = true;
    }
}
