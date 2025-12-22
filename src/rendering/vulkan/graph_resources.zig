const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");
const CompiledGraph = @import("graph_compiler.zig").CompiledGraph;

const Device = @import("platform.zig").Device;
const Swapchain = @import("swapchain.zig");

const Buffer = @import("buffer.zig");
const Texture = @import("texture.zig");

const Error = error{
    OutOfMemory,
    InvalidWindowHandle,
    InvalidBufferHandle,
    InvalidTextureHandle,
    SwapchainError,
};

const SwapchainInfo = struct {
    swapchain: *Swapchain,
    index: u32,
    wait_semaphore: vk.Semaphore,
    present_semaphore: vk.Semaphore,
    texture: Texture,
};

const BufferData = struct {
    buffer: Buffer,
    inital_state: ?saturn.RenderGraph.BufferUsage = null,
};
const TextureData = struct {
    texture: Texture,
    inital_state: ?saturn.RenderGraph.TextureUsage = null,
};

const Self = @This();

device: *Device,
swapchains: []SwapchainInfo,

buffers: []BufferData,
textures: []TextureData,

pub fn init(allocator: std.mem.Allocator, graph: *const saturn.RenderGraph.Desc, device: *Device) Error!Self {
    const swapchains: []SwapchainInfo = try allocator.alloc(SwapchainInfo, graph.windows.len);
    errdefer allocator.free(swapchains);

    for (graph.windows, swapchains) |window, *swapchain_info| {
        const swapchain = device.swapchains.get(window.handle) orelse return error.InvalidWindowHandle;

        if (swapchain.out_of_date) {
            const size = device.backend.get_window_size_fn(window.handle, device.backend.get_window_size_user_data);
            swapchain.rebuild(.{ .width = size[0], .height = size[1] }) catch return error.SwapchainError;
        }

        const wait_semaphore = device.per_frame_data[device.frame_index].semaphore_pool.get() catch return error.OutOfMemory;
        const swapchain_index = swapchain.acquireNextImage(null, wait_semaphore, .null_handle) catch |err| {
            if (err == error.OutOfDateKHR) {
                swapchain.out_of_date = true;
            }
            return error.SwapchainError;
        };

        swapchain_info.* = .{
            .swapchain = swapchain,
            .index = swapchain_index,
            .wait_semaphore = wait_semaphore,
            .present_semaphore = swapchain.present_semaphores[swapchain_index],
            .texture = swapchain.textures[swapchain_index],
        };
    }

    const buffers = try allocator.alloc(BufferData, graph.buffers.len);
    errdefer allocator.free(buffers);

    const textures = try allocator.alloc(TextureData, graph.textures.len);
    errdefer allocator.free(textures);

    for (graph.buffers, buffers) |graph_entry, *entry| {
        switch (graph_entry.source) {
            .persistent => |handle| {
                const buffer = device.buffers.get(@enumFromInt(@intFromEnum(handle))) orelse return error.InvalidBufferHandle;
                entry.* = .{
                    .buffer = buffer,
                };
            },
        }
    }

    for (graph.textures, textures) |graph_entry, *entry| {
        switch (graph_entry.source) {
            .persistent => |handle| {
                const texture = device.textures.get(@enumFromInt(@intFromEnum(handle))) orelse return error.InvalidBufferHandle;
                entry.* = .{
                    .texture = texture,
                };
            },
            .window => |index| {
                const swapchain = swapchains[index];
                entry.* = .{
                    .texture = swapchain.texture,
                };
            },
        }
    }

    return .{
        .device = device,
        .swapchains = swapchains,
        .buffers = buffers,
        .textures = textures,
    };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.swapchains);
    allocator.free(self.buffers);
    allocator.free(self.textures);
}

pub fn writeFinalStates(self: Self, device: *Device) void {
    _ = self; // autofix
    _ = device; // autofix
}
