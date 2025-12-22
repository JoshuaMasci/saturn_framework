const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");

pub const MemoryProperties = struct {
    device_local_bytes: u64 = 0,
    device_local_host_visible_bytes: u64 = 0,
    host_local: u64 = 0,
    unified_memory: bool = false,
};

pub const QueuesFamilies = struct {
    graphics: ?u32 = null,
    async_compute: ?u32 = null,
    async_transfer: ?u32 = null,
};

pub const Extensions = struct {
    mesh_shading: bool = false,
    ray_tracing: bool = false,
    host_image_copy: bool = false,
    amdx_shader_enqueue: bool = false,
};

const Self = @This();

name: []const u8,
device_id: u32, // PCI device ID
vendor_id: saturn.Device.VendorID, // PCI vendor ID / Metal device registry ID
driver_version: u32,
type: saturn.Device.Type,

memory: MemoryProperties = .{},
queues: QueuesFamilies = .{},
extensions: Extensions = .{},

pub fn init(allocator: std.mem.Allocator, name_allocator: std.mem.Allocator, instance: vk.InstanceProxy, physical_device: vk.PhysicalDevice) !Self {
    var driver_properties: vk.PhysicalDeviceDriverProperties = .{
        .driver_id = undefined,
        .driver_name = undefined,
        .driver_info = undefined,
        .conformance_version = undefined,
    };
    var properties2: vk.PhysicalDeviceProperties2 = .{
        .p_next = &driver_properties,
        .properties = undefined,
    };
    instance.getPhysicalDeviceProperties2(physical_device, &properties2);

    const extensions_properties: []vk.ExtensionProperties = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, allocator);
    defer allocator.free(extensions_properties);

    //Memory Properties
    const memory: MemoryProperties = MEM_BLK: {
        var device_local_bytes: u64 = 0;
        var device_local_host_visible_bytes: u64 = 0;
        var host_visible_bytes: u64 = 0;

        const props = instance.getPhysicalDeviceMemoryProperties(physical_device);
        for (props.memory_heaps[0..props.memory_heap_count], 0..) |heap, i| {
            const device_local = heap.flags.device_local_bit;
            var host_visible = false;
            for (props.memory_types[0..props.memory_type_count]) |mtype| {
                if (mtype.heap_index == i and (mtype.property_flags.host_visible_bit and mtype.property_flags.host_coherent_bit)) {
                    host_visible = true;
                    break;
                }
            }

            if (device_local and host_visible) {
                device_local_host_visible_bytes += heap.size;
            }
            if (device_local) {
                device_local_bytes += heap.size;
            }
            if (host_visible) {
                host_visible_bytes += heap.size;
            }
        }

        // This is an attempt to determine if the device memory is all host accessable (Likey because the GPU is either itegrated or has reBAR enabled),
        // which should allow may transfers to be done as mem copies instead
        // Older GPUs may only have a small amount of BAR memory, if this is the case buffer allocations will avoid using it and rely on transfer queues as normal
        break :MEM_BLK .{
            .device_local_bytes = device_local_bytes,
            .device_local_host_visible_bytes = device_local_host_visible_bytes,
            .host_local = host_visible_bytes,
            .unified_memory = (device_local_bytes == device_local_host_visible_bytes),
        };
    };

    const queues: QueuesFamilies = QUE_BLK: {
        const queue_properties = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(queue_properties);

        break :QUE_BLK .{
            // Graphics queue must be support compute and transfer
            // This should hold for all desktop devices, I vaguely recall mobile devices that this didn't hold for, if so some rendering code will need to be changed to support this
            .graphics = findQueueFamliyIndex(queue_properties, .{ .graphics_bit = true, .compute_bit = true, .transfer_bit = true }, .{}),
            .async_compute = findQueueFamliyIndex(queue_properties, .{ .compute_bit = true, .transfer_bit = true }, .{ .graphics_bit = true }),
            .async_transfer = findQueueFamliyIndex(queue_properties, .{ .transfer_bit = true }, .{ .graphics_bit = true, .compute_bit = true }),
        };
    };

    const extensions: Extensions = .{
        .mesh_shading = supportsExtension(extensions_properties, "VK_EXT_mesh_shader"),

        // Will not support VK_KHR_ray_tracing_pipeline, cause I hate the SBT
        .ray_tracing = supportsExtension(extensions_properties, "VK_KHR_acceleration_structure") and supportsExtension(extensions_properties, "VK_KHR_ray_query"),

        .host_image_copy = supportsExtension(extensions_properties, "VK_EXT_host_image_copy"),

        .amdx_shader_enqueue = supportsExtension(extensions_properties, "VK_AMDX_shader_enqueue"),
    };

    const len = std.mem.indexOf(u8, &properties2.properties.device_name, &.{0}).?;
    const name = try name_allocator.dupe(u8, properties2.properties.device_name[0..len]);
    errdefer name_allocator.free(name);

    return .{
        .name = name,
        .device_id = properties2.properties.device_id,
        .vendor_id = @enumFromInt(properties2.properties.vendor_id),
        .driver_version = properties2.properties.driver_version,
        .type = switch (properties2.properties.device_type) {
            .integrated_gpu => .integrated,
            .discrete_gpu => .discrete,
            .virtual_gpu => .virtual,
            .cpu => .cpu,
            else => .unknown,
        },
        .memory = memory,
        .queues = queues,
        .extensions = extensions,
    };
}

fn supportsExtension(properties: []const vk.ExtensionProperties, name: []const u8) bool {
    for (properties) |extension| {
        if (std.mem.eql(u8, extension.extension_name[0..name.len], name)) {
            return true;
        }
    }
    return false;
}

fn findQueueFamliyIndex(properties: []const vk.QueueFamilyProperties, contains: vk.QueueFlags, excludes: vk.QueueFlags) ?u32 {
    // Search for a queue family index that contains the desired flags and doesn't contain any excluded flags
    for (properties, 0..) |queue_family, i| {
        if (queue_family.queue_flags.contains(contains) and queue_family.queue_flags.complement().contains(excludes)) {
            return @intCast(i);
        }
    }
    return null;
}

fn versionToArray(version: vk.Version) [4]u16 {
    return .{ @intCast(version.variant), @intCast(version.major), @intCast(version.minor), @intCast(version.patch) };
}
