const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");

const PhysicalDeviceInfo = @import("physical_device.zig");

pub const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    info: PhysicalDeviceInfo,
};

const Self = @This();

allocator: std.mem.Allocator,
base: vk.BaseWrapper,
proxy: vk.InstanceProxy,

name_pool: std.heap.ArenaAllocator,
physical_devices: []const PhysicalDevice,
physical_devices_info: []const saturn.DeviceInfo,

debug_messager: ?DebugMessenger,

pub fn init(
    allocator: std.mem.Allocator,
    loader: vk.PfnGetInstanceProcAddr,
    extensions: []const [*c]const u8,
    app_info: vk.ApplicationInfo,
    debug: bool,
) !Self {
    const base = vk.BaseWrapper.load(loader);

    var instance_layers: std.ArrayList([*c]const u8) = .empty;
    defer instance_layers.deinit(allocator);

    var instance_extentions: std.ArrayList([*c]const u8) = .empty;
    defer instance_extentions.deinit(allocator);
    try instance_extentions.appendSlice(allocator, extensions);

    if (debug) {
        try instance_layers.append(allocator, "VK_LAYER_KHRONOS_validation");
        try instance_extentions.append(allocator, "VK_EXT_debug_utils");
    }

    const instance_handle = base.createInstance(&.{
        .p_application_info = &app_info,
        .pp_enabled_layer_names = @ptrCast(instance_layers.items.ptr),
        .enabled_layer_count = @intCast(instance_layers.items.len),
        .pp_enabled_extension_names = @ptrCast(instance_extentions.items.ptr),
        .enabled_extension_count = @intCast(instance_extentions.items.len),
    }, null) catch return error.FailedToInitBackend;

    const instance_wrapper = try allocator.create(vk.InstanceWrapper);
    errdefer allocator.destroy(instance_wrapper);
    instance_wrapper.* = vk.InstanceWrapper.load(instance_handle, base.dispatch.vkGetInstanceProcAddr.?);
    const instance = vk.InstanceProxy.init(instance_handle, instance_wrapper);

    const physical_device_handles = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_device_handles);

    const physical_devices = try allocator.alloc(PhysicalDevice, physical_device_handles.len);
    errdefer allocator.free(physical_devices);

    const physical_devices_info = try allocator.alloc(saturn.DeviceInfo, physical_device_handles.len);
    errdefer allocator.free(physical_devices_info);

    var name_pool: std.heap.ArenaAllocator = .init(allocator);
    errdefer name_pool.deinit();

    for (physical_devices, physical_devices_info, physical_device_handles, 0..) |*physical_device, *info, handle, index| {
        physical_device.* = .{
            .handle = handle,
            .info = try .init(
                allocator,
                name_pool.allocator(),
                instance,
                handle,
            ),
        };
        info.* = .{
            .physical_device_index = @intCast(index),
            .name = physical_device.info.name,
            .device_id = physical_device.info.device_id,
            .vendor_id = physical_device.info.vendor_id,
            .driver_version = physical_device.info.driver_version,
            .type = physical_device.info.type,
            .backend = .vulkan,

            .memory = .{
                .device_local = physical_device.info.memory.device_local_bytes,
                .device_local_host_visible = physical_device.info.memory.device_local_host_visible_bytes,
                .host_local = physical_device.info.memory.host_local,
                .unified_memory = physical_device.info.memory.unified_memory,
            },
            .queues = .{
                .graphics = physical_device.info.queues.graphics != null,
                .async_compute = physical_device.info.queues.async_compute != null,
                .async_transfer = physical_device.info.queues.async_transfer != null,
            },

            .features = .{
                .mesh_shading = physical_device.info.extensions.mesh_shading,
                .ray_tracing = physical_device.info.extensions.ray_tracing,
                .host_image_copy = physical_device.info.extensions.host_image_copy,
            },
        };
    }

    const debug_messager: ?DebugMessenger =
        if (debug)
            DebugMessenger.init(
                instance,
                .{ .verbose_bit_ext = false, .info_bit_ext = false, .warning_bit_ext = true, .error_bit_ext = true },
                .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            )
        else
            null;

    return .{
        .allocator = allocator,
        .base = base,
        .proxy = instance,

        .name_pool = name_pool,
        .physical_devices = physical_devices,
        .physical_devices_info = physical_devices_info,

        .debug_messager = debug_messager,
    };
}

pub fn deinit(self: *Self) void {
    if (self.debug_messager) |debug_messager| {
        debug_messager.deinit(self.proxy);
    }

    self.allocator.free(self.physical_devices);
    self.allocator.free(self.physical_devices_info);
    self.name_pool.deinit();

    self.proxy.destroyInstance(null);
    self.allocator.destroy(self.proxy.wrapper);
}

const DebugMessenger = struct {
    handle: vk.DebugUtilsMessengerEXT,

    fn init(instance: vk.InstanceProxy, message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, message_types: vk.DebugUtilsMessageTypeFlagsEXT) DebugMessenger {
        return .{
            .handle = instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = message_severity,
                .message_type = message_types,
                .pfn_user_callback = DebugMessenger.callback,
            }, null) catch |err| blk: {
                std.log.err("Failed to create vk.DebugUtilsMessengerEXT: {}", .{err});
                break :blk .null_handle;
            },
        };
    }

    fn deinit(self: @This(), instance: vk.InstanceProxy) void {
        instance.destroyDebugUtilsMessengerEXT(self.handle, null);
    }

    fn callback(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        _ = message_types; // autofix
        _ = p_user_data; // autofix

        if (p_callback_data) |callback_data| {
            if (callback_data.p_message) |message| {
                if (message_severity.info_bit_ext or message_severity.verbose_bit_ext) {
                    std.log.info("vulkan: {s}", .{message});
                } else if (message_severity.warning_bit_ext) {
                    std.log.warn("vulkan: {s}", .{message});
                } else if (message_severity.error_bit_ext) {
                    std.log.err("vulkan: {s}", .{message});
                }
            }
        }

        return .false;
    }
};
