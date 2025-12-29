const std = @import("std");

const vk = @import("vulkan");

const Buffer = @import("buffer.zig");
const Texture = @import("texture.zig");
const Device = @import("device.zig");

pub const DescriptorCounts = struct {
    uniform_buffers: u16,
    storage_buffers: u16,
    sampled_images: u16,
    storage_images: u16,
    accleration_structures: u16 = 0,
};

const Self = @This();

device: *Device,
layout: vk.DescriptorSetLayout,

pool: vk.DescriptorPool,
set: vk.DescriptorSet,

uniform_buffer_array: BufferDescriptor,
storage_buffer_array: BufferDescriptor,
sampled_image_array: ImageDescriptor,
storage_image_array: ImageDescriptor,

pub fn init(allocator: std.mem.Allocator, device: *Device, descriptor_counts: DescriptorCounts) !Self {
    const All_STAGE_FLAGS = device.all_stage_flags;

    const BINDING_COUNT = 5;
    const bindings = [BINDING_COUNT]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = descriptor_counts.uniform_buffers,
            .stage_flags = All_STAGE_FLAGS,
        },
        .{
            .binding = 1,
            .descriptor_type = .storage_buffer,
            .descriptor_count = descriptor_counts.storage_buffers,
            .stage_flags = All_STAGE_FLAGS,
        },
        .{
            .binding = 2,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = descriptor_counts.sampled_images,
            .stage_flags = All_STAGE_FLAGS,
        },
        .{
            .binding = 3,
            .descriptor_type = .storage_image,
            .descriptor_count = descriptor_counts.storage_images,
            .stage_flags = All_STAGE_FLAGS,
        },
        .{
            .binding = 4,
            .descriptor_type = .acceleration_structure_khr,
            .descriptor_count = descriptor_counts.accleration_structures,
            .stage_flags = All_STAGE_FLAGS,
        },
    };

    const binding_flags: [BINDING_COUNT]vk.DescriptorBindingFlags = @splat(.{
        .update_after_bind_bit = true,
        .update_unused_while_pending_bit = true,
        .partially_bound_bit = true,
    });

    //TODO: enable 5th binding with raytracing
    const binding_count: u32 = 4;

    const binding_create_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{
        .binding_count = binding_count,
        .p_binding_flags = &binding_flags,
    };

    const layout = try device.proxy.createDescriptorSetLayout(&.{
        .p_next = @ptrCast(&binding_create_info),
        .binding_count = binding_count,
        .p_bindings = &bindings,
        .flags = .{ .update_after_bind_pool_bit = true },
    }, null);

    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .uniform_buffer, .descriptor_count = descriptor_counts.uniform_buffers },
        .{ .type = .storage_buffer, .descriptor_count = descriptor_counts.storage_buffers },
        .{ .type = .combined_image_sampler, .descriptor_count = descriptor_counts.sampled_images },
        .{ .type = .storage_image, .descriptor_count = descriptor_counts.storage_images },
        .{ .type = .acceleration_structure_khr, .descriptor_count = descriptor_counts.accleration_structures },
    };

    const pool = try device.proxy.createDescriptorPool(&.{ .max_sets = 1, .pool_size_count = binding_count, .p_pool_sizes = &pool_sizes, .flags = .{ .update_after_bind_bit = true } }, null);

    var set: vk.DescriptorSet = .null_handle;
    try device.proxy.allocateDescriptorSets(&.{ .descriptor_pool = pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&layout) }, @ptrCast(&set));

    return Self{
        .device = device,
        .layout = layout,
        .pool = pool,
        .set = set,
        .uniform_buffer_array = .init(allocator, device, set, 0, .uniform_buffer, descriptor_counts.uniform_buffers),
        .storage_buffer_array = .init(allocator, device, set, 1, .storage_buffer, descriptor_counts.storage_buffers),
        .sampled_image_array = .init(allocator, device, set, 2, .combined_image_sampler, .shader_read_only_optimal, descriptor_counts.sampled_images),
        .storage_image_array = .init(allocator, device, set, 3, .storage_image, .general, descriptor_counts.storage_images),
    };
}

pub fn deinit(self: *Self) void {
    self.device.proxy.destroyDescriptorPool(self.pool, null);
    self.device.proxy.destroyDescriptorSetLayout(self.layout, null);

    self.uniform_buffer_array.deinit();
    self.storage_buffer_array.deinit();
    self.sampled_image_array.deinit();
    self.storage_image_array.deinit();
}

pub fn writeUpdates(self: *Self, temp_allocator: std.mem.Allocator) !void {
    try self.uniform_buffer_array.writeUpdates(temp_allocator);
    try self.storage_buffer_array.writeUpdates(temp_allocator);
    try self.sampled_image_array.writeUpdates(temp_allocator);
    try self.storage_image_array.writeUpdates(temp_allocator);
}

pub fn bind(self: Self, command_buffer: vk.CommandBufferProxy, layout: vk.PipelineLayout) void {
    const bind_points = [_]vk.PipelineBindPoint{ .graphics, .compute };
    for (bind_points) |bind_point| {
        command_buffer.bindDescriptorSets(
            bind_point,
            layout,
            0,
            1,
            @ptrCast(&self.set),
            0,
            null,
        );
    }
}

pub const Binding = struct {
    binding: u16,
    index: u16,

    pub fn asU32(self: Binding) u32 {
        const low: u32 = @intCast(self.binding);
        const high: u32 = @intCast(self.index);
        return high << 16 | low;
    }
};

const BufferDescriptor = struct {
    device: *Device,
    set: vk.DescriptorSet,

    descriptor_index: u16,
    descriptor_type: vk.DescriptorType,

    allocator: std.mem.Allocator,
    index_list: IndexList,
    update_list: std.AutoArrayHashMap(u32, vk.DescriptorBufferInfo),

    fn init(
        allocator: std.mem.Allocator,
        device: *Device,
        set: vk.DescriptorSet,
        descriptor_index: u16,
        descriptor_type: vk.DescriptorType,
        array_count: u16,
    ) BufferDescriptor {
        return .{
            .allocator = allocator,
            .device = device,
            .set = set,
            .descriptor_index = descriptor_index,
            .descriptor_type = descriptor_type,
            .index_list = .init(1, array_count),
            .update_list = .init(allocator),
        };
    }

    fn deinit(self: *BufferDescriptor) void {
        self.index_list.deinit(self.allocator);
        self.update_list.deinit();
    }

    pub fn bind(self: *BufferDescriptor, buffer: Buffer) Binding {
        const index = self.index_list.get().?;
        self.update_list.put(index, .{
            .buffer = buffer.handle,
            .offset = 0,
            .range = vk.WHOLE_SIZE,
        }) catch |err| std.log.info("Failed to update descriptor binding {}:{} {}", .{ self.descriptor_index, index, err });
        return .{ .binding = self.descriptor_index, .index = index };
    }

    pub fn clear(self: *BufferDescriptor, binding: Binding) void {
        self.index_list.free(self.allocator, binding.index);
        self.update_list.put(binding.index, .{
            .buffer = .null_handle,
            .offset = 0,
            .range = vk.WHOLE_SIZE,
        }) catch |err| std.log.info("Failed to free descriptor binding {}:{} {}", .{ self.descriptor_index, binding.index, err });
    }

    pub fn writeUpdates(self: *BufferDescriptor, temp_allocator: std.mem.Allocator) !void {
        const buffer_infos = self.update_list.values();
        const indexes = self.update_list.keys();
        const descriptor_writes = try temp_allocator.alloc(vk.WriteDescriptorSet, self.update_list.count());

        for (indexes, buffer_infos, descriptor_writes) |index, *info, *descriptor_write| {
            descriptor_write.* = .{
                .descriptor_count = 1,
                .descriptor_type = self.descriptor_type,
                .dst_set = self.set,
                .dst_binding = self.descriptor_index,
                .dst_array_element = index,
                .p_buffer_info = @ptrCast(info),
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            };
        }

        self.device.proxy.updateDescriptorSets(@intCast(descriptor_writes.len), @ptrCast(descriptor_writes.ptr), 0, null);
        self.update_list.clearRetainingCapacity();
    }
};

const ImageDescriptor = struct {
    device: *Device,
    set: vk.DescriptorSet,

    descriptor_index: u16,
    descriptor_type: vk.DescriptorType,
    image_layout: vk.ImageLayout,

    allocator: std.mem.Allocator,
    index_list: IndexList,
    update_list: std.AutoArrayHashMap(u32, vk.DescriptorImageInfo),

    pub fn init(
        allocator: std.mem.Allocator,
        device: *Device,
        set: vk.DescriptorSet,
        descriptor_index: u16,
        descriptor_type: vk.DescriptorType,
        image_layout: vk.ImageLayout,
        array_count: u16,
    ) ImageDescriptor {
        return .{
            .allocator = allocator,
            .device = device,
            .set = set,
            .descriptor_index = descriptor_index,
            .descriptor_type = descriptor_type,
            .image_layout = image_layout,
            .index_list = .init(1, array_count),
            .update_list = .init(allocator),
        };
    }

    pub fn deinit(self: *ImageDescriptor) void {
        self.index_list.deinit(self.allocator);
        self.update_list.deinit();
    }

    pub fn bind(self: *ImageDescriptor, image: Texture, sampler: vk.Sampler) Binding {
        const index = self.index_list.get().?;
        self.update_list.put(index, .{
            .sampler = sampler,
            .image_view = image.view_handle,
            .image_layout = self.image_layout,
        }) catch |err| std.log.info("Failed to update descriptor binding {}:{} {}", .{ self.descriptor_index, index, err });
        return .{ .binding = self.descriptor_index, .index = index };
    }

    pub fn clear(self: *ImageDescriptor, binding: Binding) void {
        self.index_list.free(self.allocator, binding.index);
        self.update_list.put(binding.index, .{
            .sampler = .null_handle,
            .image_view = .null_handle,
            .image_layout = .undefined,
        }) catch |err| std.log.info("Failed to free descriptor binding {}:{} {}", .{ self.descriptor_index, binding.index, err });
    }

    pub fn writeUpdates(self: *ImageDescriptor, temp_allocator: std.mem.Allocator) !void {
        const buffer_infos = self.update_list.values();
        const indexes = self.update_list.keys();
        const descriptor_writes = try temp_allocator.alloc(vk.WriteDescriptorSet, self.update_list.count());

        for (indexes, buffer_infos, descriptor_writes) |index, *info, *descriptor_write| {
            descriptor_write.* = .{
                .descriptor_count = 1,
                .descriptor_type = self.descriptor_type,
                .dst_set = self.set,
                .dst_binding = self.descriptor_index,
                .dst_array_element = index,
                .p_buffer_info = &.{},
                .p_image_info = @ptrCast(info),
                .p_texel_buffer_view = &.{},
            };
        }

        self.device.proxy.updateDescriptorSets(@intCast(descriptor_writes.len), @ptrCast(descriptor_writes.ptr), 0, null);
        self.update_list.clearRetainingCapacity();
    }
};

const IndexList = struct {
    freed: std.ArrayList(u16) = .empty,
    next: u16,
    min: u16,
    max: u16,

    pub fn init(min: u16, max: u16) IndexList {
        return IndexList{
            .next = min,
            .min = min,
            .max = max,
        };
    }

    pub fn deinit(self: *IndexList, allocator: std.mem.Allocator) void {
        self.freed.deinit(allocator);
    }

    pub fn get(self: *IndexList) ?u16 {
        if (self.freed.items.len > 0) {
            return self.freed.pop();
        } else if (self.next <= self.max) {
            const idx = self.next;
            self.next += 1;
            return idx;
        } else {
            return null; // exhausted
        }
    }

    pub fn free(self: *IndexList, allocator: std.mem.Allocator, index: u16) void {
        if (index < self.min or index > self.max) return;
        self.freed.append(allocator, index) catch {}; // ignore OOM
    }
};
