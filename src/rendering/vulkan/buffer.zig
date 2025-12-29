const std = @import("std");
const vk = @import("vulkan");

const Device = @import("device.zig");
const GpuAllocator = @import("gpu_allocator.zig");
const Binding = @import("bindless_descriptor.zig").Binding;

const Self = @This();

handle: vk.Buffer,
allocation: GpuAllocator.Allocation,
size: vk.DeviceSize,

uniform_binding: ?Binding = null,
storage_binding: ?Binding = null,

pub fn init(
    device: *Device,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    location: GpuAllocator.MemoryLocation,
) !Self {
    const handle = try device.proxy.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    }, null);
    errdefer device.proxy.destroyBuffer(handle, null);

    const mem_requirements = device.proxy.getBufferMemoryRequirements(handle);

    const allocation = try device.gpu_allocator.alloc(mem_requirements, location);
    errdefer device.gpu_allocator.free(allocation);

    try device.proxy.bindBufferMemory(handle, allocation.memory, allocation.offset);

    return .{
        .handle = handle,
        .allocation = allocation,
        .size = size,
    };
}

pub fn deinit(self: Self, device: *Device) void {
    device.proxy.destroyBuffer(self.handle, null);
    device.gpu_allocator.free(self.allocation);
}

pub fn getMappedSlice(self: *const Self, comptime T: type) ?[]T {
    if (self.allocation.getMappedByteSlice()) |bytes| {
        const ptr: [*]T = @ptrCast(@alignCast(bytes.ptr));
        const len = bytes.len / @sizeOf(T);
        return ptr[0..len];
    }
    return null;
}
