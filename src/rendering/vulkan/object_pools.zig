const std = @import("std");
const vk = @import("vulkan");
const Device = @import("device.zig");
const Queue = @import("queue.zig");

// Command Buffer Pool
pub const CommandBufferPool = struct {
    const Self = @This();

    objects: std.ArrayList(vk.CommandBuffer),
    next_free: usize,
    device: *Device,
    command_pool: vk.CommandPool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: *Device, queue: Queue) !Self {
        return Self{
            .objects = .empty,
            .next_free = 0,
            .device = device,
            .command_pool = try device.proxy.createCommandPool(
                &.{ .flags = .{}, .queue_family_index = queue.family_index },
                null,
            ),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shrink(0) catch {};
        self.objects.deinit(self.allocator);
        self.device.proxy.destroyCommandPool(self.command_pool, null);
    }

    pub fn get(self: *Self) !vk.CommandBuffer {
        if (self.next_free < self.objects.items.len) {
            // This is a stupid "clever" way to increment the index after getting the current freed index
            // I write this comment cause I'm generally against the clever way of doing things as it is less readable
            defer self.next_free += 1;
            return self.objects.items[self.next_free];
        }

        // Need to allocate a new command buffers
        var command_buffers: [4]vk.CommandBuffer = undefined;

        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(command_buffers.len),
        };

        try self.device.proxy.allocateCommandBuffers(&alloc_info, command_buffers[0..4].ptr);

        try self.objects.appendSlice(self.allocator, &command_buffers);
        const cmd_buf = self.objects.items[self.next_free];
        self.next_free += 1;
        return cmd_buf;
    }

    pub fn reset(self: *Self) error{PoolResetFailed}!void {
        self.device.proxy.resetCommandPool(self.command_pool, .{}) catch return error.PoolResetFailed;
        self.next_free = 0;
    }

    pub fn shrink(self: *Self, target_capacity: usize) !void {
        if (target_capacity >= self.objects.items.len) return;

        const buffers_to_free = self.objects.items[target_capacity..];
        if (buffers_to_free.len > 0) {
            self.device.proxy.freeCommandBuffers(
                self.command_pool,
                @intCast(buffers_to_free.len),
                buffers_to_free.ptr,
            );
        }

        self.objects.shrinkAndFree(self.allocator, target_capacity);
        if (self.next_free > target_capacity) {
            self.next_free = target_capacity;
        }
    }

    pub fn capacity(self: *const Self) usize {
        return self.objects.items.len;
    }
};

// Fence Pool
pub const FencePool = struct {
    const Self = @This();

    objects: std.ArrayList(vk.Fence),
    next_free: usize,
    device: *Device,
    create_flags: vk.FenceCreateFlags,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: *Device, create_flags: vk.FenceCreateFlags) Self {
        return Self{
            .objects = .empty,
            .next_free = 0,
            .device = device,
            .create_flags = create_flags,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shrink(0) catch {};
        self.objects.deinit(self.allocator);
    }

    pub fn get(self: *Self) !vk.Fence {
        if (self.next_free < self.objects.items.len) {
            const fence = self.objects.items[self.next_free];
            self.next_free += 1;
            // Reset fence when reusing
            try self.device.proxy.resetFences(1, @ptrCast(&fence));
            return fence;
        }

        // Create new fence
        const create_info = vk.FenceCreateInfo{
            .flags = self.create_flags,
        };

        const fence = try self.device.proxy.createFence(&create_info, null);
        try self.objects.append(self.allocator, fence);
        self.next_free += 1;
        return fence;
    }

    pub fn reset(self: *Self) error{PoolResetFailed}!void {
        if (self.objects.items.len != 0) {
            self.device.proxy.resetFences(@intCast(self.objects.items.len), self.objects.items.ptr) catch return error.PoolResetFailed;
        }
        self.next_free = 0;
    }

    pub fn shrink(self: *Self, target_capacity: usize) !void {
        if (target_capacity >= self.objects.items.len) return;

        const fences_to_destroy = self.objects.items[target_capacity..];
        for (fences_to_destroy) |fence| {
            self.device.proxy.destroyFence(fence, null);
        }

        self.objects.shrinkAndFree(self.allocator, target_capacity);
        if (self.next_free > target_capacity) {
            self.next_free = target_capacity;
        }
    }

    pub fn capacity(self: *const Self) usize {
        return self.objects.items.len;
    }
};

// Semaphore Pool
pub const SemaphorePool = struct {
    const Self = @This();

    objects: std.ArrayList(vk.Semaphore),
    next_free: usize,
    device: *Device,
    semaphore_type: vk.SemaphoreType,
    initial_value: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: *Device, semaphore_type: vk.SemaphoreType, initial_value: u64) Self {
        return Self{
            .objects = .empty,
            .next_free = 0,
            .device = device,
            .semaphore_type = semaphore_type,
            .initial_value = initial_value,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shrink(0) catch {};
        self.objects.deinit(self.allocator);
    }

    pub fn get(self: *Self) !vk.Semaphore {
        if (self.next_free < self.objects.items.len) {
            const semaphore = self.objects.items[self.next_free];
            self.next_free += 1;
            return semaphore;
        }

        // Create new semaphore
        var create_info = vk.SemaphoreCreateInfo{};

        var type_create_info: vk.SemaphoreTypeCreateInfo = undefined;
        if (self.semaphore_type == .timeline) {
            type_create_info = vk.SemaphoreTypeCreateInfo{
                .semaphore_type = self.semaphore_type,
                .initial_value = self.initial_value,
            };
            create_info.p_next = &type_create_info;
        }

        const semaphore = try self.device.proxy.createSemaphore(&create_info, null);
        try self.objects.append(self.allocator, semaphore);
        self.next_free += 1;
        return semaphore;
    }

    pub fn reset(self: *Self) void {
        self.next_free = 0;
    }

    pub fn shrink(self: *Self, target_capacity: usize) !void {
        if (target_capacity >= self.objects.items.len) return;

        const semaphores_to_destroy = self.objects.items[target_capacity..];
        for (semaphores_to_destroy) |semaphore| {
            self.device.proxy.destroySemaphore(semaphore, null);
        }

        self.objects.shrinkAndFree(self.allocator, target_capacity);
        if (self.next_free > target_capacity) {
            self.next_free = target_capacity;
        }
    }

    pub fn capacity(self: *const Self) usize {
        return self.objects.items.len;
    }
};
