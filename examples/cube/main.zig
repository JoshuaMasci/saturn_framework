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

    const ppm_texture = try readRgbaPpm(gpa, @embedFile("texture.ppm"));
    defer gpa.free(ppm_texture.data);
    std.log.info("Texture Loaded: {}x{}", .{ ppm_texture.width, ppm_texture.height });

    const sampled_texture = try device.createTexture(.{
        .name = "sampled_texture",
        .width = ppm_texture.width,
        .height = ppm_texture.height,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .transfer = true, .host_transfer = true },
        .memory = .gpu_only,
    });
    defer device.destroyTexture(sampled_texture);

    std.debug.assert(device.canUploadTexture(sampled_texture));
    try device.uploadTexture(sampled_texture, ppm_texture.data);

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

    const uniform_buffer = try device.createBuffer(.{
        .name = "uniform_buffer",
        .size = 16,
        .usage = .{ .uniform = true, .transfer_dst = true },
        .memory = .cpu_to_gpu,
    });
    defer device.destroyBuffer(uniform_buffer);

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

        var builder = saturn.RenderGraphBuilder.init(tpa);
        defer builder.deinit();

        const uniform_buffer_handle = try builder.importBuffer(uniform_buffer);
        var update_callback_ctx: UpdateCallbackData = .{
            .uniform_buffer_handle = uniform_buffer_handle,
        };

        var update_pass = try builder.beginPass(.initCStr("Update Buffer Pass"));
        update_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
        update_pass.transfer_callback = .{ .ctx = @ptrCast(&update_callback_ctx), .callback = updateCallback };
        try update_pass.end();

        var render_callback_ctx: RenderCallbackData = .{
            .uniform_buffer_handle = uniform_buffer_handle,
        };

        const swapchain_texture = try builder.importWindow(window);
        var render_pass = try builder.beginPass(.initCStr("Cube Pass"));
        render_pass.render_target = .{};
        render_pass.render_target.?.color_attachemnts.add(.{ .texture = swapchain_texture, .clear = @splat(0.25) });
        render_pass.buffer_usages.add(.{ .buffer = uniform_buffer_handle, .usage = .none });
        render_pass.render_callback = .{ .ctx = @ptrCast(&render_callback_ctx), .callback = renderCallback };
        try render_pass.end();

        const render_graph = builder.build();

        //Submit a render job on the selected device
        try device.submit(tpa, &render_graph);
    }
}

const UpdateCallbackData = struct {
    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
};

fn updateCallback(ctx: ?*anyopaque, encoder: saturn.TransferCommandEncoder) void {
    _ = encoder; // autofix
    const callback_data: *UpdateCallbackData = @ptrCast(@alignCast(ctx.?));
    _ = callback_data; // autofix
}

const RenderCallbackData = struct {
    uniform_buffer_handle: saturn.RenderGraphBufferIndex,
};

fn renderCallback(ctx: ?*anyopaque, encoder: saturn.GraphicsCommandEncoder) void {
    _ = encoder; // autofix
    const callback_data: *RenderCallbackData = @ptrCast(@alignCast(ctx.?));
    _ = callback_data; // autofix
}

//Super basic ppm loader, doesnt support comments
fn readRgbaPpm(gpa: std.mem.Allocator, data: []const u8) !struct {
    width: u32,
    height: u32,
    data: []const u8,
} {
    //Expected header "P6.{WIDTH} {HEIGHT}.255"

    const MAGIC: []const u8 = "P6\n";
    const TAIL: []const u8 = "\n255";

    const magic: []const u8 = data[0..MAGIC.len];
    if (!std.mem.eql(u8, magic, MAGIC)) {
        return error.InvalidMagic;
    }

    const end_pos = std.mem.indexOf(u8, data[0..20], TAIL) orelse return error.InvaildHeader;
    const dim_str = data[MAGIC.len..end_pos];
    var dim_split = std.mem.splitAny(u8, dim_str, " ");
    const width_str = dim_split.next() orelse return error.InvaildHeader;
    const height_str = dim_split.next() orelse return error.InvaildHeader;

    const width = try std.fmt.parseInt(u32, width_str, 10);
    const height = try std.fmt.parseInt(u32, height_str, 10);
    const pixel_count = width * height;

    const rgba_data = try gpa.alloc(u8, pixel_count * 4);
    errdefer gpa.free(rgba_data);

    const rgb_data: []const u8 = data[end_pos..];

    for (0..pixel_count) |idx| {
        const rgb_idx = idx * 3;
        const rgba_idx = idx * 4;

        @memcpy(rgba_data[rgba_idx..(rgba_idx + 3)], rgb_data[rgb_idx..(rgb_idx + 3)]);
        rgba_data[rgba_idx + 3] = 0;
    }

    return .{
        .width = width,
        .height = height,
        .data = rgba_data,
    };
}
