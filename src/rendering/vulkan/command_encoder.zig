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
                .setPushData = setPushData,
                .draw = draw,
                .drawIndexed = drawIndexed,
            },
        };
    }

    fn setPipeline(ctx: *anyopaque, pipeline: saturn.GraphicsPipeline.Handle) void {
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

    fn setVertexBuffer(ctx: *anyopaque, slot: u32, buf: saturn.Buffer.Handle, offset: usize) void {
        _ = slot; // autofix
        _ = buf; // autofix
        _ = offset; // autofix

        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self; // autofix
    }

    fn setIndexBuffer(ctx: *anyopaque, buf: saturn.Buffer.Handle, offset: usize, index_type: saturn.IndexType) void {
        _ = buf; // autofix
        _ = offset; // autofix
        _ = index_type; // autofix

        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self; // autofix
    }

    fn setPushData(ctx: *anyopaque, offset: u32, data: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.command_buffer.pushConstants(
            self.device.pipeline_layout,
            self.device.device.all_stage_flags,
            offset,
            @intCast(data.len),
            data.ptr,
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

    pub fn updateBuffer(ctx: *anyopaque, buf: saturn.RenderGraph.BufferIndex, offset: usize, data: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const buffer = self.resources.buffers[buf.idx];
        self.command_buffer.updateBuffer(buffer.buffer.handle, offset, data.len, data.ptr);
    }
};
