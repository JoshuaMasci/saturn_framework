const std = @import("std");

const vk = @import("vulkan");

pub const MemoryLocation = enum {
    gpu_mappable,
    gpu_only,
    cpu_only,
};

pub const Allocation = struct {
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
    location: MemoryLocation,
    mapped_ptr: ?*anyopaque,

    pub fn getMappedByteSlice(self: *const @This()) ?[]u8 {
        if (self.mapped_ptr) |buffer_ptr| {
            const buffer_slice_ptr: [*]u8 = @ptrCast(@alignCast(buffer_ptr));
            const buffer_slice: []u8 = buffer_slice_ptr[0..self.size];
            return buffer_slice;
        } else {
            return null;
        }
    }
};

const Self = @This();

physical_device: vk.PhysicalDevice,
instance: vk.InstanceProxy,
device: vk.DeviceProxy,
memory_properties: vk.PhysicalDeviceMemoryProperties,

total_requested_bytes: usize = 0,

pub fn init(
    physical_device: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    device: vk.DeviceProxy,
) Self {
    const memory_properties = instance.getPhysicalDeviceMemoryProperties(physical_device);
    return .{
        .physical_device = physical_device,
        .instance = instance,
        .device = device,
        .memory_properties = memory_properties,
    };
}

pub fn deinit(self: Self) void {
    _ = self; // autofix
}

pub fn alloc(
    self: *Self,
    requirements: vk.MemoryRequirements,
    location: MemoryLocation,
) !Allocation {
    const memory_type_index = try self.findMemoryType(
        requirements.memory_type_bits,
        switch (location) {
            .gpu_mappable => .{ .device_local_bit = true, .host_visible_bit = true, .host_coherent_bit = true },
            .gpu_only => .{ .device_local_bit = true },
            .cpu_only => .{ .host_visible_bit = true, .host_coherent_bit = true },
        },
    );

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type_index,
    };

    const offset: vk.DeviceSize = 0;
    const memory = try self.device.allocateMemory(&alloc_info, null);

    var mapped_ptr: ?*anyopaque = null;
    if (self.memory_properties.memory_types[memory_type_index].property_flags.contains(
        .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
    )) {
        mapped_ptr = try self.device.mapMemory(memory, offset, alloc_info.allocation_size, .{});
    }

    self.total_requested_bytes += alloc_info.allocation_size;

    return .{
        .memory = memory,
        .offset = 0,
        .size = alloc_info.allocation_size,
        .location = location,
        .mapped_ptr = mapped_ptr,
    };
}

pub fn free(self: *Self, allocation: Allocation) void {
    if (allocation.mapped_ptr) |_| {
        self.device.unmapMemory(allocation.memory);
    }

    self.device.freeMemory(allocation.memory, null);

    self.total_requested_bytes -= allocation.size;
}

fn findMemoryType(self: *const Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.memory_properties.memory_types[0..self.memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }
    return error.NoSuitableMemoryType;
}
