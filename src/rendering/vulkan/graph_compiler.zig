const std = @import("std");
const vk = @import("vulkan");

const saturn = @import("../../root.zig");

const Graph = @import("../../graph.zig").Graph;
const GraphResources = @import("graph_resources.zig");

const Device = @import("platform.zig").Device;
const Buffer = @import("buffer.zig");
const Texture = @import("texture.zig");

pub const PipelineBarrier = struct {
    memory_barriers: std.ArrayList(vk.MemoryBarrier2) = .empty,
    buffer: std.ArrayList(vk.BufferMemoryBarrier2) = .empty,
    texture: std.ArrayList(vk.ImageMemoryBarrier2) = .empty,

    pub fn deinit(self: *PipelineBarrier, allocator: std.mem.Allocator) void {
        self.memory_barriers.deinit(allocator);
        self.buffer.deinit(allocator);
        self.texture.deinit(allocator);
    }

    pub fn cmd(self: PipelineBarrier, command_buffer: vk.CommandBufferProxy) void {
        if (self.memory_barriers.items.len + self.buffer.items.len + self.texture.items.len != 0) {
            for (self.buffer.items) |buf| {
                if (buf.src_access_mask.host_read_bit) {
                    std.debug.panic("Dst access: {any}", .{buf.dst_access_mask});
                }
            }

            command_buffer.pipelineBarrier2(&.{
                .memory_barrier_count = @intCast(self.memory_barriers.items.len),
                .p_memory_barriers = self.memory_barriers.items.ptr,
                .buffer_memory_barrier_count = @intCast(self.buffer.items.len),
                .p_buffer_memory_barriers = self.buffer.items.ptr,
                .image_memory_barrier_count = @intCast(self.texture.items.len),
                .p_image_memory_barriers = self.texture.items.ptr,
            });
        }
    }
};

pub const RenderPassSet = struct {
    pre_barrier: PipelineBarrier = .{},
    pass_indexes: std.ArrayList(u16) = .empty,
    post_barrier: PipelineBarrier = .{},

    pub fn deinit(self: *RenderPassSet, allocator: std.mem.Allocator) void {
        self.pre_barrier.deinit(allocator);
        self.pass_indexes.deinit(allocator);
        self.post_barrier.deinit(allocator);
    }
};

pub const CompiledGraph = struct {
    gpa: std.mem.Allocator,
    pass_sets: std.ArrayList(RenderPassSet),

    pub fn deinit(self: *CompiledGraph) void {
        for (self.pass_sets.items) |*set| {
            set.deinit(self.gpa);
        }
        self.pass_sets.deinit(self.gpa);
    }
};

pub const Setting = struct {
    unified_image_layout: bool = false,
};

const NodeData = struct {
    pass_index: ?u16 = null,
};

const EdgeData = union(enum) {
    buffer: struct {
        index: usize,
        last: saturn.RenderGraphBufferUsage,
        next: saturn.RenderGraphBufferUsage,
    },
    texture: struct {
        index: usize,
        last: saturn.RenderGraphTextureUsage,
        next: saturn.RenderGraphTextureUsage,
    },
};

const BufferState = struct {
    const PassUsage = struct {
        last_pass: ?u16 = null,
        usage: saturn.RenderGraphBufferUsage,
    };

    // write: BufferPassUsage,
    // reads: std.ArrayList(BufferPassUsage),
    last: ?PassUsage = null,

    pub fn update(self: *BufferState, usage: PassUsage) ?PassUsage {
        const old = self.last;
        self.last = usage;
        return old;
    }
};

const TextureState = struct {
    const PassUsage = struct {
        last_pass: ?u16 = null,
        usage: saturn.RenderGraphTextureUsage,
    };

    last: ?PassUsage = null,

    pub fn update(self: *TextureState, usage: PassUsage) ?PassUsage {
        const old = self.last;
        self.last = usage;
        return old;
    }
};

pub fn compileGraphBasic(
    allocator: std.mem.Allocator,
    render_graph: *const saturn.RenderGraphDesc,
    resources: *const GraphResources,
    settings: Setting,
) !CompiledGraph {
    const buffer_states: []BufferState = try allocator.alloc(BufferState, resources.buffers.len);
    errdefer allocator.free(buffer_states);

    for (buffer_states, resources.buffers) |*state, resource| {
        state.* = .{};
        if (resource.inital_state) |usage| {
            _ = state.update(.{ .usage = usage });
        }
    }

    const texture_states: []TextureState = try allocator.alloc(TextureState, resources.textures.len);
    errdefer allocator.free(texture_states);

    for (texture_states, resources.textures) |*state, resource| {
        state.* = .{};
        if (resource.inital_state) |usage| {
            _ = state.update(.{ .usage = usage });
        }
    }

    var result: CompiledGraph = .{
        .gpa = allocator,
        .pass_sets = try .initCapacity(allocator, render_graph.passes.len), //Alloc the max possible number of passes
    };
    errdefer result.deinit();

    for (render_graph.passes, 0..) |pass, i| {
        const pass_i: u16 = @intCast(i);

        var pass_set: RenderPassSet = .{};
        errdefer pass_set.deinit(result.gpa);
        try pass_set.pass_indexes.append(result.gpa, pass_i);

        if (pass.render_target) |render_target| {
            for (render_target.color_attachemnts.slice()) |attachment| {
                const texture = resources.textures[attachment.texture.idx].texture;
                const last_usage: TextureState.PassUsage = texture_states[attachment.texture.idx].update(.{ .last_pass = pass_i, .usage = .attachment_write }) orelse .{ .usage = .none };
                try pass_set.pre_barrier.texture.append(result.gpa, createTextureBarrier(texture, last_usage.usage, .attachment_write, settings.unified_image_layout));
            }

            if (render_target.depth_attachment) |attachment| {
                const texture = resources.textures[attachment.texture.idx].texture;
                const last_usage: TextureState.PassUsage = texture_states[attachment.texture.idx].update(.{ .last_pass = pass_i, .usage = .attachment_write }) orelse .{ .usage = .none };
                try pass_set.pre_barrier.texture.append(result.gpa, createTextureBarrier(texture, last_usage.usage, .attachment_write, settings.unified_image_layout));
            }
        }

        for (pass.buffer_usages.slice()) |usage| {
            const buffer = resources.buffers[usage.buffer.idx].buffer;
            if (buffer_states[usage.buffer.idx].update(.{ .last_pass = pass_i, .usage = usage.usage })) |last_usage| {
                try pass_set.pre_barrier.buffer.append(result.gpa, createBufferBarrier(buffer, last_usage.usage, usage.usage));
            }
        }

        for (pass.texture_usages.slice()) |usage| {
            const texture = resources.textures[usage.texture.idx].texture;
            const last_usage: TextureState.PassUsage = texture_states[usage.texture.idx].update(.{ .last_pass = pass_i, .usage = usage.usage }) orelse .{ .usage = .none };
            try pass_set.pre_barrier.texture.append(result.gpa, createTextureBarrier(texture, last_usage.usage, usage.usage, settings.unified_image_layout));
        }

        result.pass_sets.appendAssumeCapacity(pass_set);
    }

    for (render_graph.windows) |window| {
        const last_usage: TextureState.PassUsage = texture_states[window.texture.idx].update(.{ .last_pass = null, .usage = .present }) orelse .{ .usage = .none };
        const last_pass_i: u16 = last_usage.last_pass orelse @intCast(result.pass_sets.items.len); //Pick the last pass if never used
        const last_pass = &result.pass_sets.items[last_pass_i];
        const texture = resources.textures[window.texture.idx].texture;
        try last_pass.post_barrier.texture.append(result.gpa, createTextureBarrier(texture, last_usage.usage, .present, settings.unified_image_layout));
    }

    return result;
}

// TODO: fix
// I think the graph sorted is reversed
pub fn compileGraph(
    allocator: std.mem.Allocator,
    render_graph: *const saturn.RenderGraphDesc,
    resources: *const GraphResources,
    settings: Setting,
) !CompiledGraph {
    const buffer_states: []BufferState = try allocator.alloc(BufferState, resources.buffers.len);
    errdefer allocator.free(buffer_states);

    for (buffer_states, resources.buffers) |*state, resource| {
        state.* = .{};
        if (resource.inital_state) |usage| {
            _ = state.update(.{ .usage = usage });
        }
    }

    const texture_states: []TextureState = try allocator.alloc(TextureState, resources.textures.len);
    errdefer allocator.free(texture_states);

    for (texture_states, resources.textures) |*state, resource| {
        state.* = .{};
        if (resource.inital_state) |usage| {
            _ = state.update(.{ .usage = usage });
        }
    }

    const DependencyGraph = Graph(NodeData, EdgeData);
    var graph: DependencyGraph = try .initCapacity(
        allocator,
        render_graph.passes.len + 2,
        (render_graph.buffers.len + render_graph.textures.len) * render_graph.passes.len,
    );
    defer graph.deinit();

    // Passes on used for prior frame barriers and swapchain present barriers
    const init_node = try graph.addNode(.{});
    const last_node = try graph.addNode(.{});

    // Needed mostly for final swapchain transitions
    const pass_node_indexes: []u16 = try allocator.alloc(u16, render_graph.passes.len);
    defer allocator.free(pass_node_indexes);

    {
        for (render_graph.passes, 0..) |pass, i| {
            const pass_i = try graph.addNode(.{ .pass_index = @intCast(i) });
            pass_node_indexes[i] = pass_i;

            if (pass.render_target) |render_target| {
                for (render_target.color_attachemnts.slice()) |attachment| {
                    const last_usage: TextureState.PassUsage = texture_states[attachment.texture.idx].update(.{ .last_pass = pass_i, .usage = .attachment_write }) orelse .{ .usage = .none };
                    try graph.addEdge(last_usage.last_pass orelse init_node, pass_i, .{
                        .texture = .{
                            .index = attachment.texture.idx,
                            .last = last_usage.usage,
                            .next = .attachment_write,
                        },
                    });
                }

                if (render_target.depth_attachment) |attachment| {
                    const last_usage: TextureState.PassUsage = texture_states[attachment.texture.idx].update(.{ .last_pass = pass_i, .usage = .attachment_write }) orelse .{ .usage = .none };
                    try graph.addEdge(last_usage.last_pass orelse init_node, pass_i, .{
                        .texture = .{
                            .index = attachment.texture.idx,
                            .last = last_usage.usage,
                            .next = .attachment_write,
                        },
                    });
                }
            }

            for (pass.buffer_usages.slice()) |usage| {
                if (buffer_states[usage.buffer.idx].update(.{ .last_pass = pass_i, .usage = usage.usage })) |last_usage| {
                    try graph.addEdge(last_usage.last_pass orelse init_node, pass_i, .{
                        .buffer = .{
                            .index = usage.buffer.idx,
                            .last = last_usage.usage,
                            .next = usage.usage,
                        },
                    });
                }
            }

            for (pass.texture_usages.slice()) |usage| {
                const last_usage: TextureState.PassUsage = texture_states[usage.texture.idx].update(.{ .last_pass = pass_i, .usage = usage.usage }) orelse .{ .usage = .none };

                try graph.addEdge(last_usage.last_pass orelse init_node, pass_i, .{
                    .texture = .{
                        .index = usage.texture.idx,
                        .last = last_usage.usage,
                        .next = usage.usage,
                    },
                });
            }
        }

        //Add transtions to present
        for (render_graph.windows) |window| {
            const texture = render_graph.textures[window.texture.idx];
            if (texture.usages) |texture_usage| {
                try graph.addEdge(pass_node_indexes[texture_usage.last_pass_used], last_node, .{ .texture = .{
                    .index = window.texture.idx,
                    .last = texture_usage.last_access,
                    .next = .present,
                } });
            } else {
                //Unused swapchain transition
                try graph.addEdge(pass_node_indexes[0], last_node, .{ .texture = .{
                    .index = window.texture.idx,
                    .last = .none,
                    .next = .present,
                } });
            }
        }
    }

    var result: CompiledGraph = .{
        .gpa = allocator,
        .pass_sets = try .initCapacity(allocator, render_graph.passes.len), //Alloc the max possible number of passes
    };

    //Compile Graph
    {
        var sorted_passes = std.ArrayList(DependencyGraph.SortResult).fromOwnedSlice(try graph.topologicalSort(allocator));
        defer sorted_passes.deinit(allocator);

        //Remove dummy nodes
        {
            var init_node_pos: ?usize = null;
            var last_node_pos: ?usize = null;
            for (sorted_passes.items, 0..) |pass, pos| {
                if (pass.index == init_node) {
                    init_node_pos = pos;
                }

                if (pass.index == last_node) {
                    last_node_pos = pos;
                }
            }
            sorted_passes.orderedRemoveMany(&.{ init_node_pos.?, last_node_pos.? });
        }

        var pass_level: u16 = sorted_passes.items[0].level; //get lowest pass level
        var pass_index: usize = 0;

        while (pass_index < sorted_passes.items.len) {
            //Count passes at this level
            var pass_count: usize = 0;
            for (sorted_passes.items[pass_index..]) |pass| {
                if (pass.level != pass_level) {
                    break;
                }
                pass_count += 1;
            }

            std.debug.assert(pass_count != 0);
            const passes = sorted_passes.items[pass_index..(pass_index + pass_count)];

            var pass_set: RenderPassSet = .{};
            errdefer pass_set.deinit(result.gpa);

            pass_set.pass_indexes = try .initCapacity(result.gpa, pass_count);

            for (passes) |sort_pass| {
                const node = graph.nodes.items[sort_pass.index];

                pass_set.pass_indexes.appendAssumeCapacity(node.data.pass_index.?);

                for (node.in_edges.items) |edge_index| {
                    const edge = graph.edges.items[edge_index];

                    switch (edge.data) {
                        .buffer => |data| {
                            const buffer = resources.buffers[data.index].buffer;
                            try pass_set.pre_barrier.buffer.append(result.gpa, createBufferBarrier(buffer, data.last, data.next));
                        },
                        .texture => |data| {
                            const texture = resources.textures[data.index].texture;
                            try pass_set.pre_barrier.texture.append(result.gpa, createTextureBarrier(texture, data.last, data.next, settings.unified_image_layout));
                        },
                    }
                }

                //TODO: how to make post barriers not duplicate
                for (node.out_edges.items) |edge_index| {
                    const edge = graph.edges.items[edge_index];

                    switch (edge.data) {
                        .buffer => |data| {
                            const buffer = resources.buffers[data.index].buffer;
                            try pass_set.post_barrier.buffer.append(result.gpa, createBufferBarrier(buffer, data.last, data.next));
                        },
                        .texture => |data| {
                            const texture = resources.textures[data.index].texture;
                            try pass_set.post_barrier.texture.append(result.gpa, createTextureBarrier(texture, data.last, data.next, settings.unified_image_layout));
                        },
                    }
                }
            }

            result.pass_sets.appendAssumeCapacity(pass_set);

            pass_level += 1;
            pass_index += pass_count;
        }
    }

    return result;
}

const BufferFlags = struct {
    stage_mask: vk.PipelineStageFlags2,
    access_mask: vk.AccessFlags2,

    fn from(usage: saturn.RenderGraphBufferUsage) BufferFlags {
        _ = usage; // autofix
        return .{
            .stage_mask = .{ .all_commands_bit = true },
            .access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        };
    }
};

fn createBufferBarrier(buffer: Buffer, src: saturn.RenderGraphBufferUsage, dst: saturn.RenderGraphBufferUsage) vk.BufferMemoryBarrier2 {
    const src_mask: BufferFlags = .from(src);
    const dst_mask: BufferFlags = .from(dst);

    return .{
        .buffer = buffer.handle,
        .offset = 0,
        .size = buffer.size,

        .src_stage_mask = src_mask.stage_mask,
        .src_access_mask = src_mask.access_mask,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,

        .dst_stage_mask = dst_mask.stage_mask,
        .dst_access_mask = dst_mask.access_mask,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };
}

const TextureFlags = struct {
    stage_mask: vk.PipelineStageFlags2,
    access_mask: vk.AccessFlags2,
    layout: vk.ImageLayout,

    fn from(usage: saturn.RenderGraphTextureUsage, unified_image_layouts: bool) TextureFlags {
        _ = unified_image_layouts; // autofix
        return .{
            .stage_mask = .{ .all_commands_bit = true },
            .access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            .layout = switch (usage) {
                .none => .undefined,
                .attachment_write => .attachment_optimal,
                .attachment_read => .attachment_optimal,
                .present => .present_src_khr,
            },
        };
    }
};

fn createTextureBarrier(
    texture: Texture,
    src: saturn.RenderGraphTextureUsage,
    dst: saturn.RenderGraphTextureUsage,
    unified_image_layouts: bool,
) vk.ImageMemoryBarrier2 {
    const src_mask: TextureFlags = .from(src, unified_image_layouts);
    const dst_mask: TextureFlags = .from(dst, unified_image_layouts);

    return .{
        .image = texture.handle,
        .subresource_range = .{
            .aspect_mask = Texture.getFormatAspectMask(texture.format),
            .base_array_layer = 0,
            .layer_count = 1,
            .base_mip_level = 0,
            .level_count = 1,
        },

        .old_layout = src_mask.layout,
        .src_stage_mask = src_mask.stage_mask,
        .src_access_mask = src_mask.access_mask,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,

        .new_layout = dst_mask.layout,
        .dst_stage_mask = dst_mask.stage_mask,
        .dst_access_mask = dst_mask.access_mask,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };
}
