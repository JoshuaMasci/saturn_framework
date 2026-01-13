const std = @import("std");

const saturn = @import("saturn");

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

fn gamepadConnectedCallback(ctx: ?*anyopaque, gamepad_id: u32) void {
    _ = ctx; // autofix
    std.log.info("Gamepad Connected: {}", .{gamepad_id});
}

fn gamepadButtonCallback(ctx: ?*anyopaque, gamepad_id: u32, button: saturn.GamepadButton, state: saturn.ButtonState) void {
    _ = ctx; // autofix
    std.log.info("Gamepad({}) Button: {} -> {}", .{ gamepad_id, button, state });
}

fn gamepadAxisCallback(ctx: ?*anyopaque, gamepad_id: u32, axis: saturn.GamepadAxis, value: f32) void {
    _ = ctx; // autofix
    _ = gamepad_id; // autofix

    switch (axis) {
        .right_x => axis_values[0] = value,
        .right_y => axis_values[1] = value,
        else => {},
    }
}

var axis_values: [2]f32 = @splat(0.0);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer if (debug_allocator.deinit() == .leak) {
        std.log.err("DebugAllocator has a memory leak!", .{});
    };
    const gpa = debug_allocator.allocator();

    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const tpa = arena_allocator.allocator();

    const name = "Triangle Demo";
    var platform = try saturn.init(gpa, .{
        .app_info = .{ .name = name, .version = .{ .minor = 1 } },
        .validation = @import("builtin").mode == .Debug,
    });
    defer saturn.deinit();

    const window_size: saturn.WindowSize =
        if (std.process.hasEnvVar(gpa, "FULLSCREEN") catch false)
            .fullscreen
        else
            .{ .windowed = .{ 1600, 900 } };

    const window = try platform.createWindow(.{
        .name = name,
        .size = window_size,
        .resizeable = true,
    });
    defer platform.destroyWindow(window);

    const power_preferance: saturn.DevicePowerPreferance =
        if (std.process.hasEnvVar(gpa, "PREFER_HIGH_POWER") catch false)
            .prefer_high_power
        else
            .prefer_low_power;

    const device = try platform.createDeviceBasic(window, power_preferance) orelse return error.NoSuitableDevice;
    defer platform.destroyDevice(device);

    std.log.info("Selected Device: {f}", .{device.getInfo()});

    const RenderTargetFormat: saturn.TextureFormat = .bgra8_unorm;

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

    const vertex_shader_code_bytes = @embedFile("triangle.vert.spv");
    const vertex_shader_code = try gpa.alignedAlloc(u8, .of(u32), vertex_shader_code_bytes.len);
    defer gpa.free(vertex_shader_code);
    @memcpy(vertex_shader_code, vertex_shader_code_bytes);

    const fragment_shader_code_bytes = @embedFile("triangle.frag.spv");
    const fragment_shader_code = try gpa.alignedAlloc(u8, .of(u32), fragment_shader_code_bytes.len);
    defer gpa.free(fragment_shader_code);
    @memcpy(fragment_shader_code, fragment_shader_code_bytes);

    const triangle_vertex_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, vertex_shader_code),
    });
    defer device.destroyShaderModule(triangle_vertex_shader);

    const triangle_fragment_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, fragment_shader_code),
    });
    defer device.destroyShaderModule(triangle_fragment_shader);

    const triangle_pipeline: saturn.GraphicsPipelineHandle = try device.createGraphicsPipeline(&.{
        .vertex = triangle_vertex_shader,
        .fragment = triangle_fragment_shader,
        .target_info = .{
            .color_targets = &.{RenderTargetFormat},
        },
    });
    defer device.destroyGraphicsPipeline(triangle_pipeline);

    const uniform_buffer = try device.createBuffer(.{
        .name = "uniform_buffer",
        .size = 16,
        .usage = .{ .uniform = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(uniform_buffer);

    var rotation: f32 = 0;

    while (is_running) {
        _ = arena_allocator.reset(.retain_capacity);

        // Call a the begining of a frame to update windowing and input
        platform.processEvents(.{
            .quit = quitCallback,
            .window_close_requested = windowCloseCallback,
            .gamepad_connected = gamepadConnectedCallback,
            .gamepad_button = gamepadButtonCallback,
            .gamepad_axis = gamepadAxisCallback,
        });

        //Update triangle rotation
        {
            const axis_len = std.math.sqrt((axis_values[0] * axis_values[0]) + (axis_values[1] * axis_values[1]));
            if (axis_len > 0.25) {
                const new_rotation = std.math.atan2(axis_values[1], -axis_values[0]) + (std.math.pi / 2.0);
                const distance = new_rotation - rotation;

                if (@abs(distance) > std.math.pi) {
                    rotation = new_rotation;
                } else {
                    rotation = std.math.lerp(rotation, new_rotation, 0.5);
                }

                rotation = std.math.lerp(rotation, new_rotation, 0.5);
            }
        }

        var builder = saturn.RenderGraphBuilder.init(tpa);
        defer builder.deinit();

        const uniform_buffer_handle = try builder.importBuffer(uniform_buffer);
        var update_callback_ctx: UpdateCallbackData = .{
            .uniform_buffer_handle = uniform_buffer_handle,
            .rotation = rotation,
        };

        var update_pass = try builder.beginPass(.initCStr("Update Buffer Pass"));
        update_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
        update_pass.transfer_callback = .{ .ctx = @ptrCast(&update_callback_ctx), .callback = updateCallback };
        try update_pass.end();

        var render_callback_ctx: RenderCallbackData = .{
            .pipeline = triangle_pipeline,
            .uniform_buffer_handle = uniform_buffer_handle,
        };

        const swapchain_texture = try builder.importWindow(window);
        var render_pass = try builder.beginPass(.initCStr("Triangle Pass"));
        render_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
        render_pass.render_target = .{};
        render_pass.render_target.?.color_attachemnts.add(.{ .texture = swapchain_texture, .clear = @splat(0.25) });
        render_pass.render_callback = .{ .ctx = @ptrCast(&render_callback_ctx), .callback = renderCallback };
        try render_pass.end();

        const render_graph = builder.build();

        //Submit a render job on the selected device
        try device.submit(tpa, &render_graph);
    }
}

const UpdateCallbackData = struct {
    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
    rotation: f32,
};

fn updateCallback(ctx: ?*anyopaque, encoder: saturn.TransferCommandEncoder) void {
    const callback_data: *UpdateCallbackData = @ptrCast(@alignCast(ctx.?));
    encoder.updateBuffer(callback_data.uniform_buffer_handle, 0, &std.mem.toBytes(callback_data.rotation));
}

const RenderCallbackData = struct {
    pipeline: saturn.GraphicsPipelineHandle,
    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
};

fn renderCallback(ctx: ?*anyopaque, encoder: saturn.GraphicsCommandEncoder) void {
    const callback_data: *RenderCallbackData = @ptrCast(@alignCast(ctx.?));
    encoder.setPipeline(callback_data.pipeline);
    encoder.pushResources(&.{.{ .uniform_buffer = callback_data.uniform_buffer_handle }});
    encoder.draw(3, 1, 0, 0);
}
