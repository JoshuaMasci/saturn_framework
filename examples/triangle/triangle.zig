const std = @import("std");

const Saturn = @import("saturn");

//Globals
var is_running: bool = true;
fn quitCallback(ctx: ?*anyopaque) void {
    _ = ctx; // autofix
    std.log.info("App quit requested", .{});
    is_running = false;
}
fn windowCloseCallback(ctx: ?*anyopaque, window: Saturn.Window.Handle) void {
    _ = ctx; // autofix
    _ = window; // autofix
    std.log.info("Window close requested", .{});
    is_running = false;
}

fn gamepadConnectedCallback(ctx: ?*anyopaque, gamepad_id: u32) void {
    _ = ctx; // autofix
    std.log.info("Gamepad Connected: {}", .{gamepad_id});
}

fn gamepadButtonCallback(ctx: ?*anyopaque, gamepad_id: u32, button: Saturn.Gamepad.Button, state: Saturn.ButtonState) void {
    _ = ctx; // autofix
    std.log.info("Gamepad({}) Button: {} -> {}", .{ gamepad_id, button, state });
}

fn gamepadAxisCallback(ctx: ?*anyopaque, gamepad_id: u32, axis: Saturn.Gamepad.Axis, value: f32) void {
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
    var platform = try Saturn.init(gpa, .{
        .app_info = .{ .name = name, .version = .{ .minor = 1 } },
        .debug = @import("builtin").mode == .Debug,
    });
    defer Saturn.deinit();

    const window = try platform.createWindow(.{
        .name = name,
        .size = .{ .windowed = .{ 1600, 900 } },
        .resizeable = false,
    });
    defer platform.destroyWindow(window);

    const power_preferance: Saturn.Device.PowerPreferance =
        if (std.process.hasEnvVar(gpa, "PREFER_HIGH_POWER") catch false)
            .prefer_high_power
        else
            .prefer_low_power;

    const device = try platform.createDeviceBasic(window, power_preferance) orelse return error.NoSuitableDevice;
    defer platform.destroyDevice(device);

    std.log.info("Selected Device: {f}", .{device.getInfo()});

    const RenderTargetFormat: Saturn.Texture.Format = .bgra8_unorm;

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

    const vertex_shader_code = try std.fs.cwd().readFileAllocOptions(gpa, "examples/triangle/triangle.vert.spv", std.math.maxInt(u32), null, .of(u32), null);
    defer gpa.free(vertex_shader_code);

    const fragment_shader_code = try std.fs.cwd().readFileAllocOptions(gpa, "examples/triangle/triangle.frag.spv", std.math.maxInt(u32), null, .of(u32), null);
    defer gpa.free(fragment_shader_code);

    const triangle_vertex_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, vertex_shader_code),
    });
    defer device.destroyShaderModule(triangle_vertex_shader);

    const triangle_fragment_shader = try device.createShaderModule(.{
        .code = std.mem.bytesAsSlice(u32, fragment_shader_code),
    });
    defer device.destroyShaderModule(triangle_fragment_shader);

    const triangle_pipeline: Saturn.GraphicsPipeline.Handle = try device.createGraphicsPipeline(.{
        .color_formats = &.{RenderTargetFormat},
        .vertex = triangle_vertex_shader,
        .fragment = triangle_fragment_shader,
    });
    defer device.destroyGraphicsPipeline(triangle_pipeline);

    const uniform_buffer = try device.createBuffer(.{
        .name = "uniform_buffer",
        .size = 16,
        .usage = .{ .uniform = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(uniform_buffer);

    if (device.createTexture(.{
        .width = 1920,
        .height = 1080,
        .format = .bc7_rgba_srgb,
        .usage = .{ .sampled = true, .transfer = true },
        .name = "test_texture",
        .memory = .gpu_only,
    })) |texture| {
        device.destroyTexture(texture);
    } else |err| {
        std.log.err("Failed to create texture: {}", .{err});
    }

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

        var builder = Saturn.RenderGraph.Builder.init(tpa);
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
            .rotation = rotation,
        };

        const swapchain_texture = try builder.importWindow(window);
        var swapchain_pass = try builder.beginPass(.initCStr("Swapchain Pass"));
        swapchain_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
        swapchain_pass.render_target = .{};
        swapchain_pass.render_target.?.color_attachemnts.add(.{ .texture = swapchain_texture, .clear = @splat(0.25) });
        swapchain_pass.render_callback = .{ .ctx = @ptrCast(&render_callback_ctx), .callback = renderCallback };
        try swapchain_pass.end();

        const render_graph = builder.build();

        //Submit a render job on the selected device
        try device.submit(tpa, &render_graph);
    }
}

const UpdateCallbackData = struct {
    uniform_buffer_handle: Saturn.RenderGraph.BufferIndex,
    rotation: f32,
};

fn updateCallback(ctx: ?*anyopaque, encoder: Saturn.TransferCommandEncoder) void {
    _ = encoder; // autofix
    const callback_data: *UpdateCallbackData = @ptrCast(@alignCast(ctx.?));
    _ = callback_data; // autofix
    //encoder.updateBuffer(callback_data.uniform_buffer_handle, 0, &std.mem.toBytes(callback_data.rotation));
}

const RenderCallbackData = struct {
    pipeline: Saturn.GraphicsPipeline.Handle,
    rotation: f32,
};

fn renderCallback(ctx: ?*anyopaque, encoder: Saturn.GraphicsCommandEncoder) void {
    const callback_data: *RenderCallbackData = @ptrCast(@alignCast(ctx.?));
    encoder.setPipeline(callback_data.pipeline);
    encoder.setPushData(0, &callback_data.rotation);
    encoder.draw(3, 1, 0, 0);
}
