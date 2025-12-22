const vk = @import("vulkan");

const Self = @This();

family_index: u32,
handle: vk.Queue,
command_pool: vk.CommandPool,

pub fn init(device: vk.DeviceProxy, family_index: u32) !Self {
    return .{
        .family_index = family_index,
        .handle = device.getDeviceQueue(family_index, 0),
        .command_pool = try device.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = family_index }, null),
    };
}

pub fn deinit(
    self: Self,
    device: vk.DeviceProxy,
) void {
    device.destroyCommandPool(self.command_pool, null);
}
