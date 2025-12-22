const std = @import("std");

const vk = @import("vulkan");

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
    device: vk.DeviceProxy,
    pipeline_layout: vk.PipelineLayout,
    config: PipelineConfig,
    vertex_input: VertexInput,
    vertex_module: vk.ShaderModule,
    fragment_module: ?vk.ShaderModule,
) PipelineError!vk.Pipeline {
    // Shader stage create infos
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vertex_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = fragment_module orelse .null_handle,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(vertex_input.bindings.len),
        .p_vertex_binding_descriptions = vertex_input.bindings.ptr,
        .vertex_attribute_description_count = @intCast(vertex_input.attributes.len),
        .p_vertex_attribute_descriptions = vertex_input.attributes.ptr,
    };

    // Input assembly state
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
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
        .flags = .{},
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = config.polygon_mode,
        .line_width = 1.0,
        .cull_mode = config.cull_mode,
        .front_face = config.front_face,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
    };

    // Multisampling state
    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .sample_shading_enable = .false,
        .rasterization_samples = config.sample_count,
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    // Depth stencil state
    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = if (config.enable_depth_test and config.depth_format != null) .true else .false,
        .depth_write_enable = if (config.enable_depth_write and config.depth_format != null) .true else .false,
        .depth_compare_op = config.depth_compare_op,
        .depth_bounds_test_enable = .false,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
        .stencil_test_enable = .false,
        .front = std.mem.zeroes(vk.StencilOpState),
        .back = std.mem.zeroes(vk.StencilOpState),
    };

    // Color blend attachment state
    const color_blend_attachment: [1]vk.PipelineColorBlendAttachmentState = .{.{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = if (config.enable_blending) .true else .false,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    }};

    // Color blend state
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(color_blend_attachment.len),
        .p_attachments = @ptrCast(&color_blend_attachment),
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

    // Rendering info for dynamic rendering (Vulkan 1.3 / VK_KHR_dynamic_rendering)
    const color_attachment_format = [_]vk.Format{config.color_format};
    const pipeline_rendering_create_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &color_attachment_format,
        .depth_attachment_format = config.depth_format orelse .undefined,
        .stencil_attachment_format = .undefined,
    };

    // Graphics pipeline create info
    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = if (fragment_module != null) 2 else 1,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_depth_stencil_state = &depth_stencil,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state,
        .layout = pipeline_layout,
        .render_pass = .null_handle, // Using dynamic rendering
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
        .p_next = &pipeline_rendering_create_info,
    };

    var pipeline: vk.Pipeline = undefined;
    const result = device.createGraphicsPipelines(
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
