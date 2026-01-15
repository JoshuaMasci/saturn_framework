const std = @import("std");

const saturn = @import("saturn");
const zm = @import("zmath");
const zstbi = @import("zstbi");

//Globals
var is_running: bool = true;
fn quitCallback(ctx: ?*anyopaque) void {
    _ = ctx; // autofix
    std.log.info("App quit requested", .{});
    is_running = false;
}

fn windowCloseCallback(ctx: ?*anyopaque, window: saturn.WindowHandle) void {
    _ = ctx; // autofix
    _ = window; // autofix
    std.log.info("Window close requested", .{});
    is_running = false;
}

fn windowResizeCallback(ctx: ?*anyopaque, window: saturn.WindowHandle, size: [2]u32) void {
    _ = size; // autofix
    _ = ctx; // autofix
    _ = window; // autofix
}

fn gamepadConnectedCallback(ctx: ?*anyopaque, gamepad_id: u32) void {
    _ = ctx; // autofix
    std.log.info("Gamepad Connected: {}", .{gamepad_id});
}

fn gamepadButtonCallback(ctx: ?*anyopaque, gamepad_id: u32, button: saturn.GamepadButton, state: saturn.ButtonState) void {
    _ = gamepad_id; // autofix
    _ = button; // autofix
    _ = state; // autofix
    _ = ctx; // autofix
}

fn gamepadAxisCallback(ctx: ?*anyopaque, gamepad_id: u32, axis: saturn.GamepadAxis, value: f32) void {
    _ = ctx; // autofix
    _ = gamepad_id; // autofix

    switch (axis) {
        .right_x => right_stick_values[0] = value,
        .right_y => right_stick_values[1] = value,
        else => {},
    }
}

const cube = struct {
    const Vertex = struct {
        position: [3]f32,
        uv: [2]f32,
    };

    const Index = u16;

    const vertices = [_]Vertex{
        // Front (+Z)
        .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0.0, 0.0 } },

        // Back (-Z)
        .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 0.0, 0.0 } },

        // Left (-X)
        .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0.0, 0.0 } },

        // Right (+X)
        .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 0.0, 0.0 } },

        // Top (+Y)
        .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0.0, 0.0 } },

        // Bottom (-Y)
        .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } },
        .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1.0, 1.0 } },
        .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1.0, 0.0 } },
        .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0.0, 0.0 } },
    };

    pub const indices = [_]Index{
        0, 1, 2, 2, 3, 0, // front
        4, 5, 6, 6, 7, 4, // back
        8, 9, 10, 10, 11, 8, // left
        12, 13, 14, 14, 15, 12, // right
        16, 17, 18, 18, 19, 16, // top
        20, 21, 22, 22, 23, 20, // bottom
    };
};

var right_stick_values: [2]f32 = @splat(0.0);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer if (debug_allocator.deinit() == .leak) {
        std.log.err("DebugAllocator has a memory leak!", .{});
    };
    const gpa = debug_allocator.allocator();

    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const tpa = arena_allocator.allocator();

    const name = "Cube Demo";
    var platform = try saturn.init(gpa, .{
        .app_info = .{ .name = name, .version = .{ .minor = 1 } },
        .validation = @import("builtin").mode == .Debug,
    });
    defer saturn.deinit();

    //TODO: switch from envs to args
    const window_size: saturn.WindowSize =
        if (std.process.hasEnvVar(gpa, "FULLSCREEN") catch false)
            .fullscreen
        else
            .{ .windowed = .{ 1600, 900 } };
    const power_preferance: saturn.DevicePowerPreferance =
        if (std.process.hasEnvVar(gpa, "PREFER_HIGH_POWER") catch false)
            .prefer_high_power
        else
            .prefer_low_power;

    const window = try platform.createWindow(.{
        .name = name,
        .size = window_size,
        .resizeable = true,
    });
    defer platform.destroyWindow(window);

    const device = try platform.createDeviceBasic(window, power_preferance) orelse return error.NoSuitableDevice;
    defer platform.destroyDevice(device);

    const device_info = device.getInfo();
    std.log.info("Selected Device: {f}", .{device_info});

    if (!device_info.features.host_image_copy or !device_info.memory.unified_memory) {
        std.log.err("Device must Support HostImageCopy and have UnifiedMemory/Rebar", .{});
        std.log.err("I dont feel like writing a transfer pass right now, TODO: not be lazy", .{});
        return;
    }

    const RenderTargetFormat: saturn.TextureFormat = .bgra8_unorm; //TODO: hdr support
    const DepthTargetFormat: saturn.TextureFormat = .depth32_float;

    try device.claimWindow(
        window,
        .{
            .texture_count = 3,
            .texture_usage = .{ .attachment = true, .transfer = true },
            .texture_format = RenderTargetFormat,
            .present_mode = .fifo,
        },
    );
    defer device.releaseWindow(window);

    var depth_texture_size = platform.getWindowSize(window);
    var depth_texture = try device.createTexture(.{
        .name = "depth_target_texture",
        .width = depth_texture_size[0],
        .height = depth_texture_size[1],
        .format = DepthTargetFormat,
        .usage = .{ .attachment = true },
        .memory = .gpu_only,
    });
    defer device.destroyTexture(depth_texture);

    // Texture load
    zstbi.init(gpa);
    defer zstbi.deinit();
    var stb_image = try zstbi.Image.loadFromMemory(@embedFile("saturn.png"), 4);
    defer stb_image.deinit();

    std.log.info("Texture Loaded: {}x{}", .{ stb_image.width, stb_image.height });

    const sampled_texture = try device.createTexture(.{
        .name = "sampled_texture",
        .width = stb_image.width,
        .height = stb_image.height,
        .format = .rgba8_unorm,
        .usage = .{
            .sampled = true,
            .transfer = true,
            .host_transfer = device_info.features.host_image_copy,
        },
        .memory = .gpu_only,
    });
    defer device.destroyTexture(sampled_texture);

    std.debug.assert(device.canUploadTexture(sampled_texture));
    try device.uploadTexture(sampled_texture, 0, stb_image.data);

    // Mesh load
    const vertex_buffer = try device.createBuffer(.{
        .name = "vertex_buffer",
        .size = @sizeOf(cube.Vertex) * cube.vertices.len,
        .usage = .{ .vertex = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(vertex_buffer);
    writeBuffer(device, vertex_buffer, &cube.vertices);

    const index_buffer = try device.createBuffer(.{
        .name = "index_buffer",
        .size = @sizeOf(cube.Index) * cube.indices.len,
        .usage = .{ .index = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(index_buffer);
    writeBuffer(device, index_buffer, &cube.indices);

    const vertex_shader_code_bytes = @embedFile("cube.vert.spv");
    const vertex_shader_code = try gpa.alignedAlloc(u8, .of(u32), vertex_shader_code_bytes.len);
    defer gpa.free(vertex_shader_code);
    @memcpy(vertex_shader_code, vertex_shader_code_bytes);

    const fragment_shader_code_bytes = @embedFile("cube.frag.spv");
    const fragment_shader_code = try gpa.alignedAlloc(u8, .of(u32), fragment_shader_code_bytes.len);
    defer gpa.free(fragment_shader_code);
    @memcpy(fragment_shader_code, fragment_shader_code_bytes);

    const cube_vertex_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, vertex_shader_code),
    });
    defer device.destroyShaderModule(cube_vertex_shader);

    const cube_fragment_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, fragment_shader_code),
    });
    defer device.destroyShaderModule(cube_fragment_shader);

    const cube_pipeline: saturn.GraphicsPipelineHandle = try device.createGraphicsPipeline(&.{
        .vertex = cube_vertex_shader,
        .fragment = cube_fragment_shader,
        .vertex_input_state = .{
            .bindings = &.{
                .{
                    .binding = 0,
                    .stride = @sizeOf(cube.Vertex),
                    .input_rate = .vertex,
                },
            },
            .attributes = &.{
                .{
                    .binding = 0,
                    .location = 0,
                    .format = .float3,
                    .offset = @offsetOf(cube.Vertex, "position"),
                },
                .{
                    .binding = 0,
                    .location = 1,
                    .format = .float2,
                    .offset = @offsetOf(cube.Vertex, "uv"),
                },
            },
        },
        .raster_state = .{
            .cull_mode = .back,
            .front_face = .counter_clockwise,
        },
        .depth_stencial_state = .{
            .depth_test_enable = true,
            .depth_write_enable = true,
            .depth_compare_op = .less,
        },
        .target_info = .{
            .color_targets = &.{RenderTargetFormat},
            .depth_target = DepthTargetFormat,
        },
    });
    defer device.destroyGraphicsPipeline(cube_pipeline);

    const uniform_buffer = try device.createBuffer(.{
        .name = "uniform_buffer",
        .size = @sizeOf(zm.Mat),
        .usage = .{ .uniform = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(uniform_buffer);

    var cube_rotation: zm.Quat = zm.qidentity();

    while (is_running) {
        _ = arena_allocator.reset(.retain_capacity);

        // Call a the begining of a frame to update windowing and input
        platform.processEvents(.{
            .quit = quitCallback,
            .window_close_requested = windowCloseCallback,
            .window_resize = windowResizeCallback,
            .gamepad_connected = gamepadConnectedCallback,
            .gamepad_button = gamepadButtonCallback,
            .gamepad_axis = gamepadAxisCallback,
        });

        const yaw = if (@abs(right_stick_values[0]) > 0.25) right_stick_values[0] else 0.0;
        const pitch = if (@abs(right_stick_values[1]) > 0.25) right_stick_values[1] else 0.0;
        const ROT_SPEED: f32 = std.math.pi * 2.0;
        const FAKE_DT: f32 = 1.0 / 360.0;
        cube_rotation = zm.qmul(cube_rotation, zm.quatFromRollPitchYaw(-pitch * ROT_SPEED * FAKE_DT, yaw * ROT_SPEED * FAKE_DT, 0.0));

        var builder = saturn.RenderGraphBuilder.init(tpa);
        defer builder.deinit();

        const window_size_int = platform.getWindowSize(window);

        if (!std.mem.eql(u32, &window_size_int, &depth_texture_size)) {
            depth_texture_size = window_size_int;
            device.destroyTexture(depth_texture);
            depth_texture = try device.createTexture(.{
                .name = "depth_target_texture",
                .width = depth_texture_size[0],
                .height = depth_texture_size[1],
                .format = DepthTargetFormat,
                .usage = .{ .attachment = true },
                .memory = .gpu_only,
            });
        }

        const width_float: f32 = @floatFromInt(window_size_int[0]);
        const height_float: f32 = @floatFromInt(window_size_int[1]);
        const aspect_ratio: f32 = width_float / height_float;

        const uniform_buffer_handle = try builder.importBuffer(uniform_buffer);
        var update_callback_ctx: UpdateCallbackData = .{
            .uniform_buffer_handle = uniform_buffer_handle,
            .aspect_ratio = aspect_ratio,
            .fov_x = 75.0,
            .cube_rotation = cube_rotation,
        };

        {
            var update_pass = try builder.beginPass(.initCStr("Update Buffer Pass"));
            update_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
            update_pass.transfer_callback = .{ .ctx = @ptrCast(&update_callback_ctx), .callback = updateCallback };
            try update_pass.end();
        }

        var render_callback_ctx: RenderCallbackData = .{
            .pipeline = cube_pipeline,
            .index_count = @intCast(cube.indices.len),
            .vertex_buffer_handle = try builder.importBuffer(vertex_buffer),
            .index_buffer_handle = try builder.importBuffer(index_buffer),

            .uniform_buffer_handle = uniform_buffer_handle,
            .sampled_texture_handle = try builder.importTexture(sampled_texture),
        };

        {
            const depth_texture_handle = try builder.importTexture(depth_texture);

            const swapchain_texture = try builder.importWindow(window);
            var render_pass = try builder.beginPass(.initCStr("Cube Pass"));
            render_pass.render_target = .{};
            render_pass.render_target.?.color_attachemnts.add(.{ .texture = swapchain_texture, .clear = @splat(0.25) });
            render_pass.render_target.?.depth_attachment = .{ .texture = depth_texture_handle, .clear = 1 };
            render_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
            render_pass.render_callback = .{ .ctx = @ptrCast(&render_callback_ctx), .callback = renderCallback };
            try render_pass.end();
        }

        const render_graph = builder.build();

        //Submit a render job on the selected device
        try device.submit(tpa, &render_graph);
    }
}

pub fn writeBuffer(device: saturn.DeviceInterface, buffer: saturn.BufferHandle, slice: anytype) void {
    const buffer_slice = device.getBufferMappedSlice(buffer).?;
    const bytes_slice = std.mem.sliceAsBytes(slice);
    @memcpy(buffer_slice[0..bytes_slice.len], bytes_slice);
}

const UpdateCallbackData = struct {
    aspect_ratio: f32,
    fov_x: f32,
    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
    cube_rotation: zm.Quat,
};

fn updateCallback(ctx: ?*anyopaque, encoder: saturn.TransferCommandEncoder) void {
    const data: *UpdateCallbackData = @ptrCast(@alignCast(ctx.?));

    const CUBE_POS: zm.Vec = .{ 0, 0, 2.5, 0 };
    const EYE_POS: zm.Vec = .{ 0, 0, 0, 0 };
    const EYE_UP: zm.Vec = .{ 0, 1, 0, 0 };
    const NEAR: f32 = 0.1;
    const FAR: f32 = 100.0;

    const fov_y: f32 = std.math.atan(std.math.tan(std.math.degreesToRadians(data.fov_x) / 2.0) / data.aspect_ratio) * 2.0;

    const model_matrix = zm.mul(zm.matFromQuat(data.cube_rotation), zm.translationV(CUBE_POS));
    const view_matrix = zm.lookAtRh(EYE_POS, CUBE_POS, EYE_UP);
    var projection_matrix = zm.perspectiveFovRh(fov_y, data.aspect_ratio, NEAR, FAR);
    projection_matrix[1][1] *= -1;
    const mvp_matrix = zm.mul(zm.mul(model_matrix, view_matrix), projection_matrix);
    const mvp_matrix_bytes: []const u8 = std.mem.asBytes(&mvp_matrix);
    encoder.updateBuffer(data.uniform_buffer_handle, 0, mvp_matrix_bytes);
}

const RenderCallbackData = struct {
    pipeline: saturn.GraphicsPipelineHandle,
    index_count: u32,
    vertex_buffer_handle: saturn.RenderGraphBufferIndex,
    index_buffer_handle: saturn.RenderGraphBufferIndex,

    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
    sampled_texture_handle: saturn.RenderGraphTextureIndex,
};

fn renderCallback(ctx: ?*anyopaque, encoder: saturn.GraphicsCommandEncoder) void {
    const callback_data: *RenderCallbackData = @ptrCast(@alignCast(ctx.?));

    encoder.setPipeline(callback_data.pipeline);
    encoder.pushResources(&.{
        .{ .uniform_buffer = callback_data.uniform_buffer_handle },
        .{ .sampled_texture = callback_data.sampled_texture_handle },
    });
    encoder.setVertexBuffer(0, callback_data.vertex_buffer_handle, 0);
    encoder.setIndexBuffer(callback_data.index_buffer_handle, 0, .u16);

    encoder.drawIndexed(callback_data.index_count, 1, 0, 0, 0);
}
