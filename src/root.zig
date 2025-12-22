const std = @import("std");

const SdlPlatform = @import("platform/sdl3.zig");

const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;
pub const FixedString = @import("fixed_string.zig");

// ----------------------------
// Root Functions
// ----------------------------

var global_state: ?struct {
    gpa: std.mem.Allocator,
    platform: *SdlPlatform,
} = null;

pub fn init(gpa: std.mem.Allocator, desc: Platform.Desc) Error!Platform.Interface {
    std.debug.assert(global_state == null);

    const platform = try gpa.create(SdlPlatform);
    errdefer gpa.destroy(platform);

    platform.* = try .init(gpa, desc);
    errdefer platform.deinit();

    global_state = .{
        .gpa = gpa,
        .platform = platform,
    };

    return platform.interface();
}

pub fn deinit() void {
    if (global_state) |state| {
        state.platform.deinit();
        state.gpa.destroy(state.platform);
        global_state = null;
    }
}

// ----------------------------
// Platform Types
// ----------------------------

pub const Error = error{
    Unknown,

    OutOfMemory,
    OutOfDeviceMemory,

    InitializationFailed,
    FailedToInitPlatform,
    FailedToInitRenderingBackend,
    FailedToCreateWindow,
    FailedToCreateSurface,
    ExtensionNotSupported,
    FeatureNotSupported,

    DeviceLost,
    WindowLost,

    InvalidUsage,
};

pub const Version = packed struct(u32) {
    patch: u12 = 0,
    minor: u10 = 0,
    major: u7 = 0,
    variant: u3 = 0,

    pub fn toU32(self: @This()) u32 {
        return @bitCast(self);
    }
};

pub const AppInfo = struct {
    name: [:0]const u8,
    version: Version,
};

pub const RenderingBackend = enum {
    vulkan,
    dx12,
    metal,
};

pub const Platform = struct {
    pub const Desc = struct {
        app_info: AppInfo,
        debug: bool = false,
        force_rendering_backend: ?RenderingBackend = null,
    };

    pub const Callbacks = struct {
        ctx: ?*anyopaque = null,

        // App Callbacks
        quit: ?*const fn (ctx: ?*anyopaque) void = null,

        // Window Callbacks
        window_resize: ?*const fn (ctx: ?*anyopaque, window_handle: Window.Handle, size: [2]u32) void = null,
        window_close_requested: ?*const fn (ctx: ?*anyopaque, window_handle: Window.Handle) void = null,

        // Mouse Callbacks
        mouse_button: ?*const fn (ctx: ?*anyopaque, button: Mouse.Button, state: ButtonState) void = null,
        mouse_motion: ?*const fn (ctx: ?*anyopaque, position: [2]f32) void = null,
        mouse_wheel: ?*const fn (ctx: ?*anyopaque, delta: [2]i32) void = null,

        // Keyboard Callbacks
        text_input: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,

        // Gamepad Callbacks
        gamepad_connected: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32) void = null,
        gamepad_disconnected: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32) void = null,
        gamepad_button: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32, button: Gamepad.Button, state: ButtonState) void = null,
        gamepad_axis: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32, axis: Gamepad.Axis, value: f32) void = null,
    };

    pub const Interface = struct {
        const Self = @This();

        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // App
            process_events: *const fn (ctx: *anyopaque, callbacks: Callbacks) void,

            // Window
            createWindow: *const fn (ctx: *anyopaque, settings: Window.Desc) Error!Window.Handle,
            destroyWindow: *const fn (ctx: *anyopaque, window_handle: Window.Handle) void,

            // Gpu Devices
            getDevices: *const fn (ctx: *anyopaque) []const Device.Info,
            doesDeviceSupportPresent: *const fn (ctx: *anyopaque, physical_device_index: u32, window_handle: Window.Handle) bool,
            getWindowSupport: *const fn (ctx: *anyopaque, physical_device_index: u32, window_handle: Window.Handle) ?Window.Support,
            createDevice: *const fn (ctx: *anyopaque, physical_device_index: u32, desc: Device.Desc) Error!Device.Interface,
            destroyDevice: *const fn (ctx: *anyopaque, device_interface: Device.Interface) void,
        };

        // Convenience wrappers

        pub fn processEvents(self: *const Self, callbacks: Callbacks) void {
            self.vtable.process_events(self.ctx, callbacks);
        }

        pub fn createWindow(self: *const Self, settings: Window.Desc) Error!Window.Handle {
            return self.vtable.createWindow(self.ctx, settings);
        }

        pub fn destroyWindow(self: *const Self, window_handle: Window.Handle) void {
            self.vtable.destroyWindow(self.ctx, window_handle);
        }

        pub fn createDeviceBasic(self: *const Self, window_opt: ?Window.Handle, power_level: Device.PowerPreferance) Error!?Device.Interface {
            const SelectedDevice = struct {
                score: usize,
                info: Device.Info,
            };

            const prefered_type: Device.Type = switch (power_level) {
                .prefer_low_power => .integrated,
                .prefer_high_power => .discrete,
            };

            const devices = self.vtable.getDevices(self.ctx);
            var selected_device_opt: ?SelectedDevice = null;

            for (devices) |device_info| {
                if (window_opt) |window_handle| {
                    if (!self.vtable.doesDeviceSupportPresent(self.ctx, device_info.physical_device_index, window_handle)) {
                        continue;
                    }
                }

                const new_device: SelectedDevice = .{
                    .info = device_info,
                    .score = if (device_info.type == prefered_type) 100 else 1,
                };

                if (selected_device_opt) |*selected_device| {
                    if (new_device.score > selected_device.score) {
                        selected_device.* = new_device;
                    }
                } else {
                    selected_device_opt = new_device;
                }
            }

            const selected_device = selected_device_opt orelse return null;
            const device_interface: Device.Interface = self.vtable.createDevice(self.ctx, selected_device.info.physical_device_index, .{}) catch |err| return err;
            return device_interface;
        }

        pub fn destroyDevice(self: *const Self, device_interface: Device.Interface) void {
            self.vtable.destroyDevice(self.ctx, device_interface);
        }
    };
};

pub const Window = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const Size = union(enum) {
        windowed: [2]i32,
        fullscreen,
        maximized,
    };

    pub const Desc = struct {
        name: [*c]const u8,
        size: Size,
        resizeable: bool,
    };

    pub const PresentMode = enum {
        fifo,
        immediate,
        mailbox,
    };

    pub const Support = struct {
        min_image_count: u32,
        max_image_count: u32,
        usage: Texture.Usage,
        formats: []const Texture.Format,
        present_modes: []const PresentMode,
    };

    pub const Settings = struct {
        texture_count: u32,
        texture_usage: Texture.Usage,
        texture_format: Texture.Format,
        present_mode: PresentMode,
    };
};

pub const ButtonState = enum(u1) {
    pressed,
    released,
};

pub const Mouse = struct {
    pub const Button = enum(u8) {
        left = 1,
        middle = 2,
        right = 3,
        x1 = 4,
        x2 = 5,
    };
};

pub const Keyboard = struct {};

pub const Gamepad = struct {
    pub const Handle = enum(u32) { null_handle = 0, _ };

    pub const Button = enum(u8) {
        south = 0, // A on Xbox, Cross on PlayStation
        east = 1, // B on Xbox, Circle on PlayStation
        west = 2, // X on Xbox, Square on PlayStation
        north = 3, // Y on Xbox, Triangle on PlayStation
        back = 4,
        guide = 5,
        start = 6,
        left_stick = 7,
        right_stick = 8,
        left_shoulder = 9,
        right_shoulder = 10,
        dpad_up = 11,
        dpad_down = 12,
        dpad_left = 13,
        dpad_right = 14,
        trackpad = 20,
    };

    pub const Axis = enum(u8) {
        left_x = 0,
        left_y = 1,
        right_x = 2,
        right_y = 3,
        left_trigger = 4,
        right_trigger = 5,
    };
};

pub const MemoryType = enum {
    gpu_only,
    cpu_to_gpu,
    gpu_to_cpu,
};

// ----------------------------
// Buffer Types
// ----------------------------

pub const Buffer = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const Desc = struct {
        name: [:0]const u8,
        size: usize,
        usage: Usage,
        memory: MemoryType,
    };

    pub const Usage = struct {
        vertex: bool = false,
        index: bool = false,
        uniform: bool = false,
        storage: bool = false,
        transfer_src: bool = false,
        transfer_dst: bool = false,
    };
};

// ----------------------------
// Buffer Types
// ----------------------------

pub const Texture = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const Desc = struct {
        name: [:0]const u8,
        width: u32,
        height: u32,
        depth: u32 = 1,
        format: Format,
        mip_levels: u32 = 1,
        usage: Usage,
        memory: MemoryType,
    };

    pub const Format = enum {
        rgba8_unorm,
        bgra8_unorm,
        rgba16_float,
        depth32_float,

        bc1_rgba_unorm,
        bc1_rgba_srgb,

        bc2_rgba_unorm,
        bc2_rgba_srgb,

        bc3_rgba_unorm,
        bc3_rgba_srgb,

        bc4_r_unorm,
        bc4_r_snorm,

        bc5_rg_unorm,
        bc5_rg_snorm,

        bc6h_rgb_ufloat,
        bc6h_rgb_sfloat,

        bc7_rgba_unorm,
        bc7_rgba_srgb,
    };

    pub const Usage = struct {
        sampled: bool = false,
        storage: bool = false,
        attachment: bool = false,
        transfer: bool = false,
    };
};

// ----------------------------
// Pipline Types
// ----------------------------

pub const IndexType = enum {
    u16,
    u32,
};

pub const Shader = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const Stage = enum {
        vertex,
        fragment,
        compute,
    };

    pub const Desc = struct {
        code: []const u32,
    };
};

pub const GraphicsPipeline = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const PrimitiveTopology = enum {
        triangle_list,
        triangle_strip,
        line_list,
    };

    pub const Desc = struct {
        vertex: Shader.Handle,
        fragment: ?Shader.Handle = null,
        color_formats: []const Texture.Format = &.{},
        depth_format: ?Texture.Format = null,
        primitive_topology: PrimitiveTopology = .triangle_list,
    };
};

pub const ComputePipeline = struct {
    pub const Handle = enum(u64) { null_handle = 0, _ };

    pub const Desc = struct {};
};

// ----------------------------
// Device Types
// ----------------------------

pub const Device = struct {
    pub const PowerPreferance = enum {
        prefer_low_power,
        prefer_high_power,
    };

    pub const Desc = struct {
        frames_in_flight: u32 = 2,
    };

    pub const Type = enum {
        unknown,
        integrated,
        discrete,
        virtual,
        cpu,
    };

    // List from here: https://www.reddit.com/r/vulkan/comments/4ta9nj/is_there_a_comprehensive_list_of_the_names_and/
    //TODO: find a more complete list?
    pub const VendorID = enum(u32) {
        AMD = 0x1002,
        ImgTec = 0x1010,
        Nvidia = 0x10DE,
        ARM = 0x13B5,
        Qualcomm = 0x5143,
        Intel = 0x8086,
        _,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) !void {
            if (std.enums.tagName(@This(), self)) |tag_name| {
                return writer.print("{s}", .{tag_name});
            } else {
                return writer.print("0x{x}", .{@intFromEnum(self)});
            }
        }
    };

    pub const Queues = struct {
        graphics: bool,
        async_compute: bool,
        async_transfer: bool,
    };

    pub const Features = struct {
        mesh_shading: bool,
        ray_tracing: bool,
    };

    pub const Memory = struct {
        // Bytes of GPU local (VRAM) memory
        device_local: u64,

        // CPU visible GPU memory
        device_local_host_visible: u64,

        // GPU visible CPU memory
        host_local: u64,

        // Unified memory flag for IGPUs, or DGPUs with all device-local memory mappabled
        unified_memory: bool,
    };

    pub const Info = struct {
        physical_device_index: u32,
        name: []const u8,
        device_id: u32, // PCI device ID
        vendor_id: VendorID, // PCI vendor ID
        driver_version: u32,
        type: Type,
        backend: RenderingBackend,

        queues: Queues,
        memory: Memory,
        features: Features,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) !void {
            try writer.print(".{{\n", .{});
            try writer.print("  .physical_device_index = {},\n", .{self.physical_device_index});
            try writer.print("  .name = \"{s}\",\n", .{self.name});
            try writer.print("  .device_id = 0x{X},\n", .{self.device_id});
            try writer.print("  .vendor_id = .{f},\n", .{self.vendor_id});
            try writer.print("  .driver_version = 0x{X},\n", .{self.driver_version});
            try writer.print("  .type = .{s},\n", .{@tagName(self.type)});
            try writer.print("  .backend = .{s},\n", .{@tagName(self.backend)});
            try writer.print("  .queues = {},\n", .{self.queues});
            try writer.print("  .memory = {},\n", .{self.memory});
            try writer.print("  .features = {},\n", .{self.features});
            try writer.print("}}", .{});
        }
    };

    pub const Interface = struct {
        const Self = @This();

        // Opaque pointer to backend implementation
        ctx: *anyopaque,

        // V-table: function pointers to backend
        vtable: *const VTable,

        pub const VTable = struct {
            getInfo: *const fn (ctx: *anyopaque) Info,

            createBuffer: *const fn (ctx: *anyopaque, desc: Buffer.Desc) Error!Buffer.Handle,
            destroyBuffer: *const fn (ctx: *anyopaque, handle: Buffer.Handle) void,

            createTexture: *const fn (ctx: *anyopaque, desc: Texture.Desc) Error!Texture.Handle,
            destroyTexture: *const fn (ctx: *anyopaque, handle: Texture.Handle) void,

            createShaderModule: *const fn (ctx: *anyopaque, desc: Shader.Desc) Error!Shader.Handle,
            destroyShaderModule: *const fn (ctx: *anyopaque, handle: Shader.Handle) void,

            createGraphicsPipeline: *const fn (ctx: *anyopaque, desc: GraphicsPipeline.Desc) Error!GraphicsPipeline.Handle,
            destroyGraphicsPipeline: *const fn (ctx: *anyopaque, handle: GraphicsPipeline.Handle) void,

            createComputePipeline: *const fn (ctx: *anyopaque, desc: ComputePipeline.Desc) Error!ComputePipeline.Handle,
            destroyComputePipeline: *const fn (ctx: *anyopaque, handle: ComputePipeline.Handle) void,

            claimWindow: *const fn (ctx: *anyopaque, window_handle: Window.Handle, settings: Window.Settings) Error!void,
            releaseWindow: *const fn (ctx: *anyopaque, window_handle: Window.Handle) void,

            submit: *const fn (ctx: *anyopaque, tpa: std.mem.Allocator, graph: *const RenderGraph.Desc) Error!void,
            waitIdle: *const fn (ctx: *anyopaque) void,
        };

        pub fn getInfo(self: *const Self) Info {
            return self.vtable.getInfo(self.ctx);
        }

        pub fn createBuffer(self: *const Self, desc: Buffer.Desc) Error!Buffer.Handle {
            return self.vtable.createBuffer(self.ctx, desc);
        }

        pub fn destroyBuffer(self: *const Self, handle: Buffer.Handle) void {
            self.vtable.destroyBuffer(self.ctx, handle);
        }

        pub fn createTexture(self: *const Self, desc: Texture.Desc) Error!Texture.Handle {
            return self.vtable.createTexture(self.ctx, desc);
        }

        pub fn destroyTexture(self: *const Self, handle: Texture.Handle) void {
            self.vtable.destroyTexture(self.ctx, handle);
        }

        pub fn createShaderModule(self: *const Self, desc: Shader.Desc) Error!Shader.Handle {
            return self.vtable.createShaderModule(self.ctx, desc);
        }

        pub fn destroyShaderModule(self: *const Self, handle: Shader.Handle) void {
            self.vtable.destroyShaderModule(self.ctx, handle);
        }

        pub fn createGraphicsPipeline(self: *const Self, desc: GraphicsPipeline.Desc) Error!GraphicsPipeline.Handle {
            return self.vtable.createGraphicsPipeline(self.ctx, desc);
        }

        pub fn destroyGraphicsPipeline(self: *const Self, handle: GraphicsPipeline.Handle) void {
            self.vtable.destroyGraphicsPipeline(self.ctx, handle);
        }

        pub fn createComputePipeline(self: *const Self, desc: ComputePipeline.Desc) Error!ComputePipeline.Handle {
            return self.vtable.createComputePipeline(self.ctx, desc);
        }

        pub fn destroyComputePipeline(self: *const Self, handle: ComputePipeline.Handle) void {
            self.vtable.destroyComputePipeline(self.ctx, handle);
        }

        pub fn claimWindow(self: *const Self, window_handle: Window.Handle, settings: Window.Settings) Error!void {
            return self.vtable.claimWindow(self.ctx, window_handle, settings);
        }

        pub fn releaseWindow(self: *const Self, window_handle: Window.Handle) void {
            self.vtable.releaseWindow(self.ctx, window_handle);
        }

        pub fn submit(self: *const Self, tpa: std.mem.Allocator, graph: *const RenderGraph.Desc) Error!void {
            return self.vtable.submit(self.ctx, tpa, graph);
        }

        pub fn waitIdle(self: *const Self) void {
            self.vtable.waitIdle(self.ctx);
        }
    };
};

// ----------------------------
// Command Encoder Types
// ----------------------------

pub const GraphicsCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setPipeline: *const fn (ctx: *anyopaque, pipeline: GraphicsPipeline.Handle) void,
        setViewport: *const fn (ctx: *anyopaque, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void,
        setScissor: *const fn (ctx: *anyopaque, x: i32, y: i32, width: u32, height: u32) void,
        setVertexBuffer: *const fn (ctx: *anyopaque, slot: u32, buf: Buffer.Handle, offset: usize) void,
        setIndexBuffer: *const fn (ctx: *anyopaque, buf: Buffer.Handle, offset: usize, index_type: IndexType) void,

        setPushData: *const fn (ctx: *anyopaque, offset: u32, data: []const u8) void,

        draw: *const fn (ctx: *anyopaque, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void,
        drawIndexed: *const fn (ctx: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void,
    };

    pub fn setPipeline(self: Self, pipeline: GraphicsPipeline.Handle) void {
        self.vtable.setPipeline(self.ctx, pipeline);
    }

    // Not sure if push constants will be removed from this api yet
    pub fn setPushData(self: Self, offset: u32, data: anytype) void {
        self.vtable.setPushData(self.ctx, offset, std.mem.asBytes(data));
    }

    pub fn draw(self: Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.vtable.draw(self.ctx, vertex_count, instance_count, first_vertex, first_instance);
    }
};

pub const ComputeCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setPipeline: *const fn (ctx: *anyopaque, pipeline: ComputePipeline.Handle) void,
        dispatch: *const fn (ctx: *anyopaque, x: u32, y: u32, z: u32) void,
    };
};

pub const TransferCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        updateBuffer: *const fn (ctx: *anyopaque, buffer: RenderGraph.BufferIndex, offset: usize, data: []const u8) void,
    };

    pub fn updateBuffer(self: Self, buffer: Buffer.Handle, offset: usize, data: []const u8) void {
        self.vtable.updateBuffer(self.ctx, buffer, offset, data);
    }
};

// ----------------------------
// RenderGraph Types
// ----------------------------

pub const RenderGraph = struct {
    pub const BufferIndex = struct { idx: u32 };
    pub const TextureIndex = struct { idx: u32 };

    pub const Desc = struct {
        const Self = @This();

        windows: []const WindowEntry = &.{},
        buffers: []const BufferEntry = &.{},
        textures: []const TextureEntry = &.{},
        passes: []const Pass = &.{},
    };

    pub const WindowEntry = struct {
        handle: Window.Handle,
        texture: TextureIndex,
    };

    pub const BufferEntry = struct {
        source: union(enum) {
            persistent: Buffer.Handle,
        },
        usages: ?struct {
            first_pass_used: u16,
            last_pass_used: u16,
            last_access: BufferUsage,
        } = null,
    };

    pub const BufferUsage = enum(u32) {
        none,
    };

    pub const BufferAccess = struct {
        buffer: BufferIndex,
        usage: BufferUsage,
    };

    pub const TextureEntry = struct {
        source: union(enum) {
            persistent: Texture.Handle,
            window: u32, //Lookup into RenderGraph.windows
        },
        usages: ?struct {
            first_pass_used: u16,
            last_pass_used: u16,
            last_access: TextureUsage,
        } = null,
    };

    pub const TextureUsage = enum(u32) {
        none,
        attachment_write,
        attachment_read,
        present,
    };

    pub const TextureAccess = struct {
        texture: TextureIndex,
        usage: TextureUsage,
    };

    pub const ColorAttachment = struct {
        texture: TextureIndex,
        clear: ?[4]f32,
    };

    pub const DepthAttachment = struct {
        texture: TextureIndex,
        clear: ?f32,
    };

    pub const RenderTarget = struct {
        color_attachemnts: FixedArrayList(ColorAttachment, 8) = .empty,
        depth_attachment: ?DepthAttachment = null,
    };

    pub const RenderCallback = struct {
        ctx: ?*anyopaque,
        callback: GraphicsCommandEncoder.Callback,
    };

    pub const TransferCallback = struct {
        ctx: ?*anyopaque,
        callback: TransferCommandEncoder.Callback,
    };

    pub const Pass = struct {
        name: FixedString,
        render_target: ?RenderTarget = null,
        render_callback: ?RenderCallback = null,
        transfer_callback: ?TransferCallback = null,

        buffer_usages: FixedArrayList(BufferAccess, 32),
        texture_usages: FixedArrayList(TextureAccess, 32),
    };

    pub const Builder = struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        windows: std.ArrayList(WindowEntry) = .empty,
        buffers: std.ArrayList(BufferEntry) = .empty,
        textures: std.ArrayList(TextureEntry) = .empty,
        passes: std.ArrayList(Pass) = .empty,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self; // autofix
        }

        pub fn importBuffer(self: *Self, handle: Buffer.Handle) !BufferIndex {
            const idx: u32 = @intCast(self.buffers.items.len);
            try self.buffers.append(self.gpa, .{
                .source = .{ .persistent = handle },
            });
            return .{ .idx = idx };
        }

        pub fn importTexture(self: *Self, handle: Texture.Handle) !TextureIndex {
            const idx: u32 = @intCast(self.textures.items.len);
            try self.textures.append(self.gpa, .{
                .source = .{ .persistent = handle },
            });
            return .{ .idx = idx };
        }

        pub fn importWindow(self: *Self, handle: Window.Handle) !TextureIndex {
            const window_idx: u32 = @intCast(self.windows.items.len);
            const texture_idx: u32 = @intCast(self.textures.items.len);
            try self.windows.append(self.gpa, .{
                .handle = handle,
                .texture = .{ .idx = texture_idx },
            });
            try self.textures.append(self.gpa, .{
                .source = .{ .window = window_idx },
            });
            return .{ .idx = texture_idx };
        }

        pub fn beginPass(self: *Self, name: FixedString) !PassBuilder {
            return PassBuilder{
                .parent = self,
                .name = name,
            };
        }

        pub const PassBuilder = struct {
            parent: *Self,
            name: FixedString,
            render_target: ?RenderTarget = null,
            render_callback: ?RenderCallback = null,
            transfer_callback: ?TransferCallback = null,
            buffer_usages: FixedArrayList(BufferAccess, 32) = .empty,
            texture_usages: FixedArrayList(TextureAccess, 32) = .empty,

            pub fn end(self: *PassBuilder) !void {
                try self.parent.passes.append(self.parent.gpa, .{
                    .name = self.name,
                    .render_target = self.render_target,
                    .render_callback = self.render_callback,
                    .transfer_callback = self.transfer_callback,
                    .buffer_usages = self.buffer_usages,
                    .texture_usages = self.texture_usages,
                });
            }
        };

        pub fn build(self: *Self) Desc {
            return .{
                .windows = self.windows.items,
                .buffers = self.buffers.items,
                .textures = self.textures.items,
                .passes = self.passes.items,
            };
        }
    };
};
