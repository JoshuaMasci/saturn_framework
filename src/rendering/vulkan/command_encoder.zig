const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");

const Device = @import("platform.zig").Device;
const Resources = @import("graph_resources.zig");

pub const GraphicsCommandEncoder = struct {
    const Self = @This();

    device: *const Device,
    resources: *const Resources,
    command_buffer: vk.CommandBufferProxy,

    pub fn interface(self: *Self) saturn.GraphicsCommandEncoder {
        return .{
            .ctx = self,
            .vtable = &.{
                .setPipeline = setPipeline,
                .setViewport = setViewport,
                .setScissor = setScissor,
                .setVertexBuffer = setVertexBuffer,
                .setIndexBuffer = setIndexBuffer,
                .pushResources = pushResources,
                .draw = draw,
                .drawIndexed = drawIndexed,
            },
        };
    }

    fn setPipeline(ctx: *anyopaque, pipeline: saturn.GraphicsPipelineHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_pipeline: vk.Pipeline = @enumFromInt(@intFromEnum(pipeline));
        self.command_buffer.bindPipeline(.graphics, vk_pipeline);
    }

    fn setViewport(
        ctx: *anyopaque,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        min_depth: f32,
        max_depth: f32,
    ) void {
        const viewport: vk.Viewport = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .min_depth = min_depth,
            .max_depth = max_depth,
        };

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.command_buffer.setViewport(0, 1, &.{viewport});
    }

    fn setScissor(ctx: *anyopaque, x: i32, y: i32, width: u32, height: u32) void {
        const rect: vk.Rect2D = .{
            .offset = .{ .x = x, .y = y },
            .extent = .{ .width = width, .height = height },
        };

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.command_buffer.setScissor(0, 1, &.{rect});
    }

    fn setVertexBuffer(ctx: *anyopaque, slot: u32, buf: saturn.BufferHandle, offset: usize) void {
        _ = slot; // autofix
        _ = buf; // autofix
        _ = offset; // autofix

        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self; // autofix
    }

    fn setIndexBuffer(ctx: *anyopaque, buf: saturn.BufferHandle, offset: usize, index_type: saturn.IndexType) void {
        _ = buf; // autofix
        _ = offset; // autofix
        _ = index_type; // autofix

        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self; // autofix
    }

    pub fn pushResources(ctx: *anyopaque, resources: []const saturn.GraphResource) void {
        const MAX_RESOURCES: usize = 32;
        std.debug.assert(resources.len <= MAX_RESOURCES);

        const self: *Self = @ptrCast(@alignCast(ctx));

        var index_buffer: [MAX_RESOURCES]u32 = @splat(0);
        const index_slice = index_buffer[0..resources.len];

        for (index_slice, resources) |*index, resource| {
            index.* = switch (resource) {
                .uniform_buffer => |buffer| self.resources.buffers[buffer.idx].buffer.uniform_binding.?.asU32(),
                .storage_buffer => |buffer| self.resources.buffers[buffer.idx].buffer.storage_binding.?.asU32(),
                else => 0,
            };
        }

        const index_bytes = std.mem.sliceAsBytes(index_slice);

        self.command_buffer.pushConstants(
            self.device.pipeline_layout,
            self.device.device.all_stage_flags,
            0,
            @intCast(index_bytes.len),
            index_bytes.ptr,
        );
    }

    fn draw(ctx: *anyopaque, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.command_buffer.draw(
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        );
    }

    fn drawIndexed(
        ctx: *anyopaque,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.command_buffer.drawIndexed(
            index_count,
            instance_count,
            first_index,
            vertex_offset,
            first_instance,
        );
    }
};

pub const TransferCommandEncoder = struct {
    const Self = @This();

    device: *const Device,
    resources: *const Resources,
    command_buffer: vk.CommandBufferProxy,

    pub fn interface(self: *Self) saturn.TransferCommandEncoder {
        return .{
            .ctx = self,
            .vtable = &.{
                .updateBuffer = updateBuffer,
            },
        };
    }

    pub fn updateBuffer(ctx: *anyopaque, buf: saturn.RenderGraphBufferIndex, offset: usize, data: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const buffer = self.resources.buffers[buf.idx];
        self.command_buffer.updateBuffer(buffer.buffer.handle, offset, data.len, data.ptr);
    }
};
