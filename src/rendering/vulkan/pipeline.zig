const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");
const FixedArrayList = @import("../../fixed_array_list.zig").FixedArrayList;

const Device = @import("platform.zig").Device;
const Texture = @import("texture.zig");

pub const PipelineError = error{
    ShaderModuleCreationFailed,
    PipelineCreationFailed,
    OutOfMemory,
};

pub const PipelineConfig = struct {
    color_format: vk.Format,
    depth_format: ?vk.Format = null,
    sample_count: vk.SampleCountFlags = .{ .@"1_bit" = true },
    cull_mode: vk.CullModeFlags = .{},
    front_face: vk.FrontFace = .counter_clockwise,
    polygon_mode: vk.PolygonMode = .fill,
    enable_depth_test: bool = true,
    enable_depth_write: bool = true,
    depth_compare_op: vk.CompareOp = .less,
    enable_blending: bool = false,
};

pub const VertexInput = struct {
    bindings: []const vk.VertexInputBindingDescription = &.{},
    attributes: []const vk.VertexInputAttributeDescription = &.{},
};

pub fn createGraphicsPipeline(
    device: *const Device,
    desc: *const saturn.GraphicsPipelineDesc,
) PipelineError!vk.Pipeline {

    // Shader stage create infos
    var shader_stages: FixedArrayList(vk.PipelineShaderStageCreateInfo, 2) = .empty;
    shader_stages.add(.{
        .flags = .{},
        .stage = .{ .vertex_bit = true },
        .module = device.shader_modules.get(desc.vertex).?,
        .p_name = "main",
        .p_specialization_info = null,
    });

    if (desc.fragment) |fragment_shader| {
        shader_stages.add(.{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = device.shader_modules.get(fragment_shader).?,
            .p_name = "main",
            .p_specialization_info = null,
        });
    }
    const shader_stage_slice = shader_stages.slice();

    // Vertex Input State
    var vertex_binding_descriptions: FixedArrayList(vk.VertexInputBindingDescription, 16) = .empty;
    var vertex_attribute_descriptions: FixedArrayList(vk.VertexInputAttributeDescription, 16) = .empty;

    for (desc.vertex_input_state.bindings) |b| {
        vertex_binding_descriptions.add(.{
            .binding = b.binding,
            .stride = b.stride,
            .input_rate = toVkVertexRate(b.input_rate),
        });
    }

    for (desc.vertex_input_state.attributes) |a| {
        vertex_attribute_descriptions.add(.{
            .location = a.location,
            .binding = a.binding,
            .format = toVkFormat(a.format),
            .offset = a.offset,
        });
    }

    const vertex_binding_description_slice = vertex_binding_descriptions.slice();
    const vertex_attribute_description_slice = vertex_attribute_descriptions.slice();

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(vertex_binding_description_slice.len),
        .p_vertex_binding_descriptions = vertex_binding_description_slice.ptr,
        .vertex_attribute_description_count = @intCast(vertex_attribute_description_slice.len),
        .p_vertex_attribute_descriptions = vertex_attribute_description_slice.ptr,
    };

    // Input assembly state
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = toVkTopology(desc.primitive_topology),
        .primitive_restart_enable = .false,
    };

    // Viewport state (using dynamic state)
    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = null, // Dynamic
        .scissor_count = 1,
        .p_scissors = null, // Dynamic
    };

    // Rasterization state
    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = toVkPolygonMode(desc.raster_state.fill_mode),
        .cull_mode = toVkCullMode(desc.raster_state.cull_mode),
        .front_face = toVkFrontFace(desc.raster_state.front_face),
        .depth_bias_enable = if (desc.raster_state.depth_bias_enable) .true else .false,
        .depth_bias_constant_factor = desc.raster_state.depth_bias_constant_factor,
        .depth_bias_clamp = desc.raster_state.depth_bias_clamp,
        .depth_bias_slope_factor = desc.raster_state.depth_bias_slope_factor,
        .line_width = 1.0,
    };

    // Multisampling state
    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .sample_shading_enable = .false,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    // Depth stencil state
    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = if (desc.depth_stencial_state.depth_test_enable) .true else .false,
        .depth_write_enable = if (desc.depth_stencial_state.depth_write_enable) .true else .false,
        .depth_compare_op = toVkCompareOp(desc.depth_stencial_state.depth_compare_op),
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
        .front = std.mem.zeroes(vk.StencilOpState),
        .back = std.mem.zeroes(vk.StencilOpState),
    };

    var color_blend_attachments: FixedArrayList(vk.PipelineColorBlendAttachmentState, 8) = .empty;

    //TODO: enable blending
    // Color blend attachment state
    for (desc.target_info.color_targets) |_| {
        color_blend_attachments.add(.{
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            .blend_enable = .false,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        });
    }
    const color_blend_attachment_slice = color_blend_attachments.slice();

    // Color blend state
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(color_blend_attachment_slice.len),
        .p_attachments = color_blend_attachment_slice.ptr,
        .blend_constants = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
    };

    // Dynamic states
    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };

    const dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    var color_attachment_formats: FixedArrayList(vk.Format, 8) = .empty;
    for (desc.target_info.color_targets) |color_format| {
        color_attachment_formats.add(Texture.getVkFormat(color_format));
    }
    const color_attachment_format_slice = color_attachment_formats.slice();

    // Rendering info for dynamic rendering (Vulkan 1.3 / VK_KHR_dynamic_rendering)
    const pipeline_rendering_create_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = @intCast(color_attachment_format_slice.len),
        .p_color_attachment_formats = color_attachment_format_slice.ptr,
        .depth_attachment_format = if (desc.target_info.depth_target) |format| Texture.getVkFormat(format) else .undefined,
        .stencil_attachment_format = .undefined,
    };

    // Graphics pipeline create info
    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = @intCast(shader_stage_slice.len),
        .p_stages = shader_stage_slice.ptr,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_depth_stencil_state = &depth_stencil,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state,
        .layout = device.pipeline_layout,
        .render_pass = .null_handle, // Using dynamic rendering
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
        .p_next = &pipeline_rendering_create_info,
    };

    var pipeline: vk.Pipeline = undefined;
    const result = device.device.proxy.createGraphicsPipelines(
        .null_handle, // pipeline cache
        1,
        @ptrCast(&pipeline_info),
        null, // allocator
        @ptrCast(&pipeline),
    ) catch |err| {
        std.log.err("Failed to create graphics pipeline: {}", .{err});
        return PipelineError.PipelineCreationFailed;
    };

    if (result != .success) {
        return PipelineError.PipelineCreationFailed;
    }

    return pipeline;
}

fn toVkTopology(t: saturn.PrimitiveTopology) vk.PrimitiveTopology {
    return switch (t) {
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
        .line_list => .line_list,
    };
}

fn toVkVertexRate(r: saturn.VertexInputRate) vk.VertexInputRate {
    return switch (r) {
        .vertex => .vertex,
        .instance => .instance,
    };
}

fn toVkFormat(f: saturn.VertexFormat) vk.Format {
    return switch (f) {
        .float => .r32_sfloat,
        .float2 => .r32g32_sfloat,
        .float3 => .r32g32b32_sfloat,
        .float4 => .r32g32b32a32_sfloat,
        .int => .r32_sint,
        .int2 => .r32g32_sint,
        .int3 => .r32g32b32_sint,
        .int4 => .r32g32b32a32_sint,
        .uint => .r32_uint,
        .uint2 => .r32g32_uint,
        .uint3 => .r32g32b32_uint,
        .uint4 => .r32g32b32a32_uint,
        .u8x4_norm => .r8g8b8a8_unorm,
        .i8x4_norm => .r8g8b8a8_snorm,
        .u16x2_norm => .r16g16_unorm,
        .u16x4_norm => .r16g16b16a16_unorm,
    };
}

fn toVkPolygonMode(f: saturn.FillMode) vk.PolygonMode {
    return switch (f) {
        .solid => .fill,
        .wireframe => .line,
    };
}

fn toVkCullMode(c: saturn.CullMode) vk.CullModeFlags {
    return switch (c) {
        .none => .{},
        .front => .{ .front_bit = true },
        .back => .{ .back_bit = true },
    };
}

fn toVkFrontFace(f: saturn.FrontFace) vk.FrontFace {
    return switch (f) {
        .clockwise => .clockwise,
        .counter_clockwise => .counter_clockwise,
    };
}

fn toVkCompareOp(c: saturn.CompareOp) vk.CompareOp {
    return switch (c) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_or_equal,
        .always => .always,
    };
}
