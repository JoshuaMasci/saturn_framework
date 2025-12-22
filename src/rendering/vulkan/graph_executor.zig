const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");

const FixedString = saturn.FixedString;
const CompiledGraph = @import("graph_compiler.zig").CompiledGraph;
const GraphResources = @import("graph_resources.zig");

const Device = @import("platform.zig").Device;
const Swapchain = @import("swapchain.zig");

pub fn executeGraph(tpa: std.mem.Allocator, device: *Device, graph: *const saturn.RenderGraph.Desc, resources: *const GraphResources, compiled: *const CompiledGraph) !void {
    const frame_data = &device.per_frame_data[device.frame_index];

    const command_buffer_handle = try frame_data.graphics_command_pool.get();
    const command_buffer = vk.CommandBufferProxy.init(command_buffer_handle, device.device.proxy.wrapper);

    try command_buffer.beginCommandBuffer(&.{});

    device.descriptor.bind(command_buffer, device.pipeline_layout);

    for (compiled.pass_sets.items, 1..) |pass_set, i| {
        if (device.device.debug) {
            const name: FixedString = .initFmt("Render Pass Set: {}", .{i});

            command_buffer.beginDebugUtilsLabelEXT(&.{
                .p_label_name = name.getCStr(),
                .color = .{ 1, 0, 0, 1 },
            });
        }

        pass_set.pre_barrier.cmd(command_buffer);

        //Run command
        for (pass_set.pass_indexes.items) |pass_index| {
            const pass = &graph.passes[pass_index];
            if (device.device.debug) {
                command_buffer.beginDebugUtilsLabelEXT(&.{
                    .p_label_name = pass.name.getCStr(),
                    .color = .{ 0, 1, 0, 1 },
                });
            }

            if (pass.render_target) |*render_target| {
                beginRendering(command_buffer, resources, render_target);
            }

            //Draw call here
            if (pass.render_callback) |render_callback| {
                var command_encoder: @import("command_encoder.zig").GraphicsCommandEncoder = .{
                    .device = device,
                    .resources = resources,
                    .command_buffer = command_buffer,
                };

                render_callback.callback(render_callback.ctx, command_encoder.interface());
            }

            if (pass.transfer_callback) |transfer_callback| {
                var command_encoder: @import("command_encoder.zig").TransferCommandEncoder = .{
                    .device = device,
                    .resources = resources,
                    .command_buffer = command_buffer,
                };
                transfer_callback.callback(transfer_callback.ctx, command_encoder.interface());
            }

            if (pass.render_target != null) {
                command_buffer.endRendering();
            }
            if (device.device.debug) {
                command_buffer.endDebugUtilsLabelEXT();
            }
        }

        pass_set.post_barrier.cmd(command_buffer);

        if (device.device.debug) {
            command_buffer.endDebugUtilsLabelEXT();
        }
    }

    try command_buffer.endCommandBuffer();

    // CommandBuffer & Swapchain Present submit
    {
        const wait_dst_stage_mask: vk.PipelineStageFlags = .{ .all_commands_bit = true };

        const wait_semaphores = try tpa.alloc(vk.Semaphore, resources.swapchains.len);
        defer tpa.free(wait_semaphores);

        const wait_dst_stage_masks = try tpa.alloc(vk.PipelineStageFlags, resources.swapchains.len);
        defer tpa.free(wait_dst_stage_masks);

        const signal_semaphores = try tpa.alloc(vk.Semaphore, resources.swapchains.len);
        defer tpa.free(signal_semaphores);

        for (resources.swapchains, 0..) |swapchain_info, i| {
            wait_semaphores[i] = swapchain_info.wait_semaphore;
            wait_dst_stage_masks[i] = wait_dst_stage_mask;
            signal_semaphores[i] = swapchain_info.present_semaphore;
        }

        const submit_infos: [1]vk.SubmitInfo = .{vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = (&command_buffer_handle)[0..1],
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = wait_semaphores.ptr,
            .p_wait_dst_stage_mask = wait_dst_stage_masks.ptr,
            .signal_semaphore_count = @intCast(signal_semaphores.len),
            .p_signal_semaphores = signal_semaphores.ptr,
        }};

        const fence = try frame_data.fence_pool.get();
        try frame_data.frame_wait_fences.append(device.gpa, fence);
        errdefer {
            frame_data.frame_wait_fences.clearRetainingCapacity();
        }

        try device.device.proxy.queueSubmit(device.device.graphics_queue.handle, @intCast(submit_infos.len), &submit_infos, fence);

        for (resources.swapchains) |swapchain_info| {
            swapchain_info.swapchain.queuePresent(
                device.device.graphics_queue.handle,
                swapchain_info.index,
                swapchain_info.present_semaphore,
            ) catch |err| {
                switch (err) {
                    error.OutOfDateKHR => swapchain_info.swapchain.out_of_date = true,
                    else => return err,
                }
            };
        }
    }
}

const SwapchainImageInfo = struct {
    swapchain: *Swapchain,
    index: u32,
    wait_semaphore: vk.Semaphore,
    present_semaphore: vk.Semaphore,
};

fn beginRendering(command_buffer: vk.CommandBufferProxy, resources: *const GraphResources, render_target: *const saturn.RenderGraph.RenderTarget) void {
    var color_attachments_buffer: [8]vk.RenderingAttachmentInfo = undefined;
    const color_attachments = color_attachments_buffer[0..render_target.color_attachemnts.count];
    var render_extent: ?vk.Extent2D = null;

    for (color_attachments, render_target.color_attachemnts.slice()) |*vk_attachment, attachment| {
        const interface = &resources.textures[attachment.texture.idx].texture;

        if (render_extent) |extent| {
            if (extent.width != interface.extent.width or extent.height != interface.extent.height) {
                std.debug.panic("Render Target Attachment sizes dont match {} != {}", .{ extent, interface.extent });
                //return error.AttachmentsExtentDoNoMatch;
            }
        } else {
            render_extent = interface.extent;
        }

        vk_attachment.* = .{
            .image_view = interface.view_handle,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = if (attachment.clear != null) .clear else .load,
            .store_op = .store, //if (attachment.store) .store else .dont_care,
            .clear_value = .{ .color = .{ .float_32 = attachment.clear orelse undefined } },
        };
    }

    var depth_attachment: ?vk.RenderingAttachmentInfo = null;
    if (render_target.depth_attachment) |attachment| {
        const interface = &resources.textures[attachment.texture.idx].texture;

        if (render_extent) |extent| {
            if (extent.width != interface.extent.width or extent.height != interface.extent.height) {
                std.debug.panic("Render Target Attachment sizes dont match {} != {}", .{ extent, interface.extent });
                //return error.AttachmentsExtentDoNoMatch;
            }
        } else {
            render_extent = interface.extent;
        }

        depth_attachment = .{
            .image_view = interface.view_handle,
            .image_layout = .depth_attachment_stencil_read_only_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = if (attachment.clear != null) .clear else .load,
            .store_op = .store, //if (attachment.store) .store else .dont_care,
            .clear_value = .{ .depth_stencil = .{ .depth = attachment.clear orelse undefined, .stencil = 0 } },
        };
    }

    const render_area: vk.Rect2D = .{ .extent = render_extent.?, .offset = .{ .x = 0, .y = 0 } };
    const rendering_info: vk.RenderingInfo = .{
        .render_area = render_area,
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_attachments.len),
        .p_color_attachments = color_attachments.ptr,
        .p_depth_attachment = if (depth_attachment) |attachment| @ptrCast(&attachment) else null,
    };
    command_buffer.beginRendering(&rendering_info);

    const viewport: vk.Viewport = .{
        .width = @floatFromInt(render_area.extent.width),
        .height = @floatFromInt(render_area.extent.height),
        .x = 0.0,
        .y = 0.0,
        .min_depth = 0.0,
        .max_depth = 1.0,
    };
    command_buffer.setViewport(0, 1, @ptrCast(&viewport));
    command_buffer.setScissor(0, 1, @ptrCast(&render_area));
}
