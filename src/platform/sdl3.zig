const std = @import("std");

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cInclude("SDL3/SDL_vulkan.h");

    @cDefine("SDL_MAIN_HANDLED", {});
});

const saturn = @import("../root.zig");
const Platform = saturn.Platform;
const Window = saturn.Window;
const Device = saturn.Device;

//TODO: use tagged union
const RenderingBackend = @import("../rendering/vulkan/platform.zig").Backend;

const Self = @This();

gpa: std.mem.Allocator,
backend: *RenderingBackend,

pub fn init(gpa: std.mem.Allocator, desc: Platform.Desc) saturn.Error!Self {
    const compile_version = c.SDL_VERSION;
    std.log.info("Compiled against sdl {}.{}.{}", .{ c.SDL_VERSIONNUM_MAJOR(compile_version), c.SDL_VERSIONNUM_MINOR(compile_version), c.SDL_VERSIONNUM_MICRO(compile_version) });

    const version = c.SDL_GetVersion();
    std.log.info("Running with sdl {}.{}.{}", .{ c.SDL_VERSIONNUM_MAJOR(version), c.SDL_VERSIONNUM_MINOR(version), c.SDL_VERSIONNUM_MICRO(version) });

    if (!c.SDL_Init(c.SDL_INIT_EVENTS | c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD | c.SDL_INIT_HAPTIC)) {
        return error.FailedToInitPlatform;
    }
    errdefer c.SDL_Quit();

    if (c.SDL_GetCurrentVideoDriver()) |driver| {
        std.log.info("SDL3 using {s} backend", .{driver});
    }

    const backend = try gpa.create(RenderingBackend);
    errdefer gpa.destroy(backend);

    if (c.SDL_Vulkan_LoadLibrary(null) == false) {
        return error.FailedToInitRenderingBackend;
    }

    const loader: vk.PfnGetInstanceProcAddr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());

    var ext_len: u32 = 0;
    const exts = c.SDL_Vulkan_GetInstanceExtensions(&ext_len);

    backend.* = try .init(
        gpa,
        loader,
        exts[0..ext_len],
        createSurface,
        getWindowSize,
        null,
        desc.app_info,
        desc.app_info,
        desc.debug,
    );
    errdefer backend.deinit();

    return .{
        .gpa = gpa,
        .backend = backend,
    };
}

pub fn deinit(self: *Self) void {
    self.backend.deinit();
    self.gpa.destroy(self.backend);

    std.log.info("Quiting sdl", .{});
    c.SDL_Quit();
}

pub fn interface(self: *Self) Platform.Interface {
    return .{
        .ctx = self,
        .vtable = &.{
            .process_events = process_events,

            .createWindow = createWindow,
            .destroyWindow = destroyWindow,

            .getDevices = getDevices,

            .doesDeviceSupportPresent = doesDeviceSupportPresent,
            .getWindowSupport = getWindowSupport,

            .createDevice = createDevice,
            .destroyDevice = destroyDevice,
        },
    };
}

pub fn process_events(ctx: *anyopaque, callbacks: Platform.Callbacks) void {
    _ = ctx; // autofix

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                if (callbacks.quit) |quit_fn| {
                    quit_fn(callbacks.ctx);
                }
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                if (callbacks.window_resize) |resize_fn| {
                    if (c.SDL_GetWindowFromID(event.window.windowID)) |sdl_window| {
                        const size: [2]u32 = .{ @intCast(event.window.data1), @intCast(event.window.data2) };
                        const window: Window.Handle = @enumFromInt(@intFromPtr(sdl_window));
                        resize_fn(callbacks.ctx, window, size);
                    } else {
                        std.log.warn("SDL_GetWindowFromID Failed for ID({})", .{event.window.windowID});
                    }
                }
            },
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                if (callbacks.window_close_requested) |close_fn| {
                    if (c.SDL_GetWindowFromID(event.window.windowID)) |sdl_window| {
                        const window: Window.Handle = @enumFromInt(@intFromPtr(sdl_window));
                        close_fn(callbacks.ctx, window);
                    } else {
                        std.log.warn("SDL_GetWindowFromID Failed for ID({})", .{event.window.windowID});
                    }
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (callbacks.mouse_button) |mouse_button_fn| {
                    const button = std.meta.intToEnum(saturn.Mouse.Button, event.button.button) catch continue;
                    const state: saturn.ButtonState = if (event.button.down) .pressed else .released;
                    mouse_button_fn(callbacks.ctx, button, state);
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (callbacks.mouse_motion) |mouse_motion_fn| {
                    mouse_motion_fn(callbacks.ctx, .{ event.motion.x, event.motion.y });
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (callbacks.mouse_wheel) |mouse_wheel_fn| {
                    mouse_wheel_fn(callbacks.ctx, .{ event.wheel.integer_x, event.wheel.integer_y });
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (callbacks.text_input) |text_input_fn| {
                    const text = std.mem.span(event.text.text);
                    text_input_fn(callbacks.ctx, text);
                }
            },
            c.SDL_EVENT_GAMEPAD_ADDED => {
                const gamepad_index = event.gdevice.which;
                const gamepad = c.SDL_OpenGamepad(gamepad_index).?;
                _ = gamepad; // autofix
                //const gamepad_name: []const u8 = std.mem.span(c.SDL_GetGamepadName(gamepad));

                if (callbacks.gamepad_connected) |gamepad_connected_fn| {
                    gamepad_connected_fn(callbacks.ctx, gamepad_index);
                }
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                const gamepad_index = event.gdevice.which;
                const gamepad = c.SDL_GetGamepadFromID(gamepad_index);

                if (callbacks.gamepad_disconnected) |gamepad_disconnected_fn| {
                    gamepad_disconnected_fn(callbacks.ctx, gamepad_index);
                }

                c.SDL_CloseGamepad(gamepad);
            },
            c.SDL_EVENT_GAMEPAD_BUTTON_UP, c.SDL_EVENT_GAMEPAD_BUTTON_DOWN => {
                if (callbacks.gamepad_button) |gamepad_button_fn| {
                    const button = std.meta.intToEnum(saturn.Gamepad.Button, event.gbutton.button) catch continue;
                    const state: saturn.ButtonState = if (event.gbutton.down) .pressed else .released;
                    gamepad_button_fn(callbacks.ctx, event.gbutton.which, button, state);
                }
            },
            c.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
                if (callbacks.gamepad_axis) |gamepad_axis_motion_fn| {
                    const axis = std.meta.intToEnum(saturn.Gamepad.Axis, event.gaxis.axis) catch continue;
                    const f_value: f32 = @as(f32, @floatFromInt(event.gaxis.value)) / std.math.maxInt(i16);
                    gamepad_axis_motion_fn(callbacks.ctx, event.gaxis.which, axis, f_value);
                }
            },
            else => {},
        }
    }
}

pub fn createWindow(ctx: *anyopaque, desc: Window.Desc) saturn.Error!Window.Handle {
    const self: *Self = @ptrCast(@alignCast(ctx));

    var window_width: i32 = 1600;
    var window_height: i32 = 900;
    var window_flags: c.SDL_WindowFlags = c.SDL_WINDOW_VULKAN; //TODO: Set this based on graphics backend

    if (desc.resizeable) {
        window_flags |= c.SDL_WINDOW_RESIZABLE;
    }

    switch (desc.size) {
        .windowed => |window_size| {
            window_width = window_size[0];
            window_height = window_size[1];
        },
        .maximized => window_flags |= c.SDL_WINDOW_MAXIMIZED,
        .fullscreen => window_flags |= c.SDL_WINDOW_FULLSCREEN,
    }

    const sdl_window: *c.SDL_Window = c.SDL_CreateWindow(desc.name, window_width, window_height, window_flags) orelse return error.FailedToCreateWindow;
    errdefer c.SDL_DestroyWindow(sdl_window);

    const window: Window.Handle = @enumFromInt(@intFromPtr(sdl_window));
    try self.backend.createSurface(window);
    return window;
}
pub fn destroyWindow(ctx: *anyopaque, window: Window.Handle) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.backend.destroySurface(window);
    const sdl_window: ?*c.SDL_Window = @ptrFromInt(@intFromEnum(window));
    c.SDL_DestroyWindow(sdl_window);
}

pub fn getDevices(ctx: *anyopaque) []const Device.Info {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.backend.instance.physical_devices_info;
}

pub fn doesDeviceSupportPresent(ctx: *anyopaque, device_index: u32, window: Window.Handle) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.backend.doesDeviceSupportPresent(device_index, window);
}

pub fn getWindowSupport(ctx: *anyopaque, device_index: u32, window: Window.Handle) ?Window.Support {
    _ = ctx; // autofix
    _ = window; // autofix
    _ = device_index; // autofix
    return null;
}

pub fn createDevice(ctx: *anyopaque, device_index: u32, desc: Device.Desc) saturn.Error!Device.Interface {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.backend.createDevice(device_index, desc);
}
pub fn destroyDevice(ctx: *anyopaque, device: Device.Interface) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.backend.destroyDevice(device);
}

/// Callback function for getting window size from SDL3
/// This is passed to the rendering backend to query window dimensions
/// Returns [width, height] as a backend-agnostic type
fn getWindowSize(window: Window.Handle, user_data: ?*anyopaque) [2]u32 {
    const sdl_window: ?*c.SDL_Window = @ptrFromInt(@intFromEnum(window));

    _ = user_data;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(sdl_window, &w, &h);
    return .{
        @intCast(w),
        @intCast(h),
    };
}

const vk = @import("vulkan");
pub fn createSurface(instance: vk.Instance, window: saturn.Window.Handle, allocator: ?*const vk.AllocationCallbacks) ?vk.SurfaceKHR {
    var c_surface: c.VkSurfaceKHR = undefined;
    const c_instance: c.VkInstance = @ptrFromInt(@intFromEnum(instance));
    const c_allocator: ?*c.VkAllocationCallbacks = @ptrCast(@constCast(allocator));
    const sdl_window: ?*c.SDL_Window = @ptrFromInt(@intFromEnum(window));

    if (c.SDL_Vulkan_CreateSurface(sdl_window, c_instance, c_allocator, &c_surface)) {
        const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(c_surface));
        return surface;
    }
    return null;
}
