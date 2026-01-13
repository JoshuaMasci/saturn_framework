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

pub fn init(gpa: std.mem.Allocator, desc: PlatformDesc) Error!PlatformInterface {
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

pub const PlatformDesc = struct {
    app_info: AppInfo,
    force_rendering_backend: ?RenderingBackend = null,
    validation: bool,
};

pub const PlatformCallbacks = struct {
    ctx: ?*anyopaque = null,

    // App Callbacks
    quit: ?*const fn (ctx: ?*anyopaque) void = null,

    // Window Callbacks
    window_resize: ?*const fn (ctx: ?*anyopaque, window_handle: WindowHandle, size: [2]u32) void = null,
    window_close_requested: ?*const fn (ctx: ?*anyopaque, window_handle: WindowHandle) void = null,

    // Mouse Callbacks
    mouse_button: ?*const fn (ctx: ?*anyopaque, button: MouseButton, state: ButtonState) void = null,
    mouse_motion: ?*const fn (ctx: ?*anyopaque, position: [2]f32) void = null,
    mouse_wheel: ?*const fn (ctx: ?*anyopaque, delta: [2]i32) void = null,

    // Keyboard Callbacks
    text_input: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,

    // Gamepad Callbacks
    gamepad_connected: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32) void = null,
    gamepad_disconnected: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32) void = null,
    gamepad_button: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32, button: GamepadButton, state: ButtonState) void = null,
    gamepad_axis: ?*const fn (ctx: ?*anyopaque, gamepad_id: u32, axis: GamepadAxis, value: f32) void = null,
};

pub const PlatformInterface = struct {
    const Self = @This();

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // App
        process_events: *const fn (ctx: *anyopaque, callbacks: PlatformCallbacks) void,

        // Window
        createWindow: *const fn (ctx: *anyopaque, settings: WindowDesc) Error!WindowHandle,
        destroyWindow: *const fn (ctx: *anyopaque, window_handle: WindowHandle) void,
        getWindowSize: *const fn (ctx: *anyopaque, window_handle: WindowHandle) [2]u32,

        // Gpu Devices
        getDevices: *const fn (ctx: *anyopaque) []const DeviceInfo,
        doesDeviceSupportPresent: *const fn (ctx: *anyopaque, physical_device_index: u32, window_handle: WindowHandle) bool,
        getWindowSupport: *const fn (ctx: *anyopaque, physical_device_index: u32, window_handle: WindowHandle) ?WindowSupport,
        createDevice: *const fn (ctx: *anyopaque, physical_device_index: u32, desc: DeviceDesc) Error!DeviceInterface,
        destroyDevice: *const fn (ctx: *anyopaque, device_interface: DeviceInterface) void,
    };

    // Convenience wrappers

    pub fn processEvents(self: *const Self, callbacks: PlatformCallbacks) void {
        self.vtable.process_events(self.ctx, callbacks);
    }

    pub fn createWindow(self: *const Self, settings: WindowDesc) Error!WindowHandle {
        return self.vtable.createWindow(self.ctx, settings);
    }

    pub fn destroyWindow(self: *const Self, window_handle: WindowHandle) void {
        self.vtable.destroyWindow(self.ctx, window_handle);
    }

    pub fn getWindowSize(self: *const Self, window_handle: WindowHandle) [2]u32 {
        return self.vtable.getWindowSize(self.ctx, window_handle);
    }

    pub fn createDeviceBasic(self: *const Self, window_opt: ?WindowHandle, power_level: DevicePowerPreferance) Error!?DeviceInterface {
        const SelectedDevice = struct {
            score: usize,
            info: DeviceInfo,
        };

        const prefered_type: DeviceType = switch (power_level) {
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
        const device_interface: DeviceInterface = self.vtable.createDevice(
            self.ctx,
            selected_device.info.physical_device_index,
            .{
                .frames_in_flight = if (selected_device.info.type == .discrete) 3 else 2,
                .queues = selected_device.info.queues,
                .features = selected_device.info.features,
            },
        ) catch |err| return err;
        return device_interface;
    }

    pub fn destroyDevice(self: *const Self, device_interface: DeviceInterface) void {
        self.vtable.destroyDevice(self.ctx, device_interface);
    }
};

pub const WindowHandle = enum(u64) { null_handle = 0, _ };

pub const WindowSize = union(enum) {
    windowed: [2]i32,
    fullscreen,
    maximized,
};

pub const WindowDesc = struct {
    name: [*c]const u8,
    size: WindowSize,
    resizeable: bool,
};

pub const PresentMode = enum {
    fifo,
    immediate,
    mailbox,
};

pub const WindowSupport = struct {
    min_image_count: u32,
    max_image_count: u32,
    usage: TextureUsage,
    formats: []const TextureFormat,
    present_modes: []const PresentMode,
};

pub const WindowSettings = struct {
    texture_count: u32,
    texture_usage: TextureUsage,
    texture_format: TextureFormat,
    present_mode: PresentMode,
};

pub const ButtonState = enum(u1) {
    pressed,
    released,
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    x1 = 4,
    x2 = 5,
};

pub const Keyboard = struct {};

pub const GamepadHandle = enum(u32) { null_handle = 0, _ };

pub const GamepadButton = enum(u8) {
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

pub const GamepadAxis = enum(u8) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

pub const MemoryType = enum {
    gpu_only,
    cpu_to_gpu,
    gpu_to_cpu,
};

// ----------------------------
// Buffer Types
// ----------------------------

pub const BufferHandle = enum(u64) { null_handle = 0, _ };

pub const BufferDesc = struct {
    name: [:0]const u8,
    size: usize,
    usage: BufferUsage,
    memory: MemoryType,
};

pub const BufferUsage = struct {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
};

pub const TextureHandle = enum(u64) { null_handle = 0, _ };

pub const TextureDesc = struct {
    name: [:0]const u8,
    width: u32,
    height: u32,
    depth: u32 = 1,
    format: TextureFormat,
    mip_levels: u32 = 1,
    usage: TextureUsage,
    memory: MemoryType,
};

pub const TextureFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
    rgba16_float,

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

    depth32_float,

    pub fn isColor(self: TextureFormat) bool {
        return switch (self) {
            .depth32_float => false,
            else => true,
        };
    }
};

pub const TextureUsage = struct {
    sampled: bool = false,
    storage: bool = false,
    attachment: bool = false,
    transfer: bool = false,
    host_transfer: bool = false,
};

pub const SamplerDesc = struct {};

// ----------------------------
// Pipline Types
// ----------------------------

pub const IndexType = enum {
    u16,
    u32,
};

pub const ShaderHandle = enum(u64) { null_handle = 0, _ };

pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
};

pub const ShaderDesc = struct {
    code: []const u32,
};

pub const GraphicsPipelineHandle = enum(u64) { null_handle = 0, _ };

pub const PrimitiveTopology = enum {
    triangle_list,
    triangle_strip,
    line_list,
};

pub const VertexInputRate = enum {
    vertex,
    instance,
};

pub const VertexBinding = struct {
    binding: u32,
    stride: u32,
    input_rate: VertexInputRate,
};

pub const VertexFormat = enum {
    float,
    float2,
    float3,
    float4,

    int,
    int2,
    int3,
    int4,

    uint,
    uint2,
    uint3,
    uint4,

    u8x4_norm,
    i8x4_norm,
    u16x2_norm,
    u16x4_norm,
};

pub const VertexAttribute = struct {
    binding: u32,
    location: u32,
    format: VertexFormat,
    offset: u32,
};

pub const VertexInputState = struct {
    bindings: []const VertexBinding = &.{},
    attributes: []const VertexAttribute = &.{},
};

pub const FillMode = enum {
    solid,
    wireframe,
};

pub const CullMode = enum {
    none,
    front,
    back,
};

pub const FrontFace = enum {
    clockwise,
    counter_clockwise,
};

pub const RasterizerState = struct {
    fill_mode: FillMode = .solid,
    cull_mode: CullMode = .none,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_enable: bool = false,
    depth_bias_constant_factor: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
    depth_bias_slope_factor: f32 = 0.0,
};

pub const CompareOp = enum(u8) {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

pub const DepthStencilState = struct {
    depth_test_enable: bool = false,
    depth_write_enable: bool = false,
    depth_compare_op: CompareOp = .never,
    // stencil_test_enable: bool,
    // front: StencilFaceState,
    // back: StencilFaceState,
};

pub const RenderTargetInfo = struct {
    color_targets: []const TextureFormat = &.{},
    depth_target: ?TextureFormat = null,
    // stencil_target: ?TextureFormat = null,
};

pub const GraphicsPipelineDesc = struct {
    vertex: ShaderHandle,
    fragment: ?ShaderHandle = null,
    vertex_input_state: VertexInputState = .{},
    primitive_topology: PrimitiveTopology = .triangle_list,
    raster_state: RasterizerState = .{},
    depth_stencial_state: DepthStencilState = .{},
    target_info: RenderTargetInfo = .{},
};

pub const ComputePipelineHandle = enum(u64) { null_handle = 0, _ };
pub const ComputePipelineDesc = struct {};

// ----------------------------
// Device Types
// ----------------------------

pub const DevicePowerPreferance = enum {
    prefer_low_power,
    prefer_high_power,
};

pub const DeviceDesc = struct {
    frames_in_flight: u32,
    queues: DeviceQueues,
    features: DeviceFeatures,
};

pub const DeviceType = enum {
    unknown,
    integrated,
    discrete,
    virtual,
    cpu,
};

// List from here: https://www.reddit.com/r/vulkan/comments/4ta9nj/is_there_a_comprehensive_list_of_the_names_and/
//TODO: find a more complete list?
pub const DeviceVendorID = enum(u32) {
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

pub const DeviceQueues = struct {
    graphics: bool,
    async_compute: bool,
    async_transfer: bool,
};

pub const DeviceFeatures = struct {
    mesh_shading: bool,
    ray_tracing: bool,
    host_image_copy: bool,
};

pub const DeviceMemory = struct {
    // Bytes of GPU local (VRAM) memory
    device_local: u64,

    // CPU visible GPU memory
    device_local_host_visible: u64,

    // GPU visible CPU memory
    host_local: u64,

    // Unified memory flag for IGPUs, or DGPUs with all device-local memory mappabled
    unified_memory: bool,
};

pub const DeviceInfo = struct {
    physical_device_index: u32,
    name: []const u8,
    device_id: u32, // PCI device ID
    vendor_id: DeviceVendorID, // PCI vendor ID
    driver_version: u32,
    type: DeviceType,
    backend: RenderingBackend,

    queues: DeviceQueues,
    memory: DeviceMemory,
    features: DeviceFeatures,

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

pub const DeviceInterface = struct {
    const Self = @This();

    // Opaque pointer to backend implementation
    ctx: *anyopaque,

    // V-table: function pointers to backend
    vtable: *const VTable,

    pub const VTable = struct {
        getInfo: *const fn (ctx: *anyopaque) DeviceInfo,

        createBuffer: *const fn (ctx: *anyopaque, desc: BufferDesc) Error!BufferHandle,
        destroyBuffer: *const fn (ctx: *anyopaque, handle: BufferHandle) void,
        getBufferMappedSlice: *const fn (ctx: *anyopaque, handle: BufferHandle) ?[]u8,

        createTexture: *const fn (ctx: *anyopaque, desc: TextureDesc) Error!TextureHandle,
        destroyTexture: *const fn (ctx: *anyopaque, handle: TextureHandle) void,
        canUploadTexture: *const fn (ctx: *anyopaque, handle: TextureHandle) bool,
        uploadTexture: *const fn (ctx: *anyopaque, handle: TextureHandle, data: []const u8) Error!void,

        createShaderModule: *const fn (ctx: *anyopaque, desc: ShaderDesc) Error!ShaderHandle,
        destroyShaderModule: *const fn (ctx: *anyopaque, handle: ShaderHandle) void,

        createGraphicsPipeline: *const fn (ctx: *anyopaque, desc: *const GraphicsPipelineDesc) Error!GraphicsPipelineHandle,
        destroyGraphicsPipeline: *const fn (ctx: *anyopaque, handle: GraphicsPipelineHandle) void,

        createComputePipeline: *const fn (ctx: *anyopaque, desc: ComputePipelineDesc) Error!ComputePipelineHandle,
        destroyComputePipeline: *const fn (ctx: *anyopaque, handle: ComputePipelineHandle) void,

        claimWindow: *const fn (ctx: *anyopaque, window_handle: WindowHandle, settings: WindowSettings) Error!void,
        releaseWindow: *const fn (ctx: *anyopaque, window_handle: WindowHandle) void,

        submit: *const fn (ctx: *anyopaque, tpa: std.mem.Allocator, graph: *const RenderGraphDesc) Error!void,
        waitIdle: *const fn (ctx: *anyopaque) void,
    };

    pub fn getInfo(self: *const Self) DeviceInfo {
        return self.vtable.getInfo(self.ctx);
    }

    pub fn createBuffer(self: *const Self, desc: BufferDesc) Error!BufferHandle {
        return self.vtable.createBuffer(self.ctx, desc);
    }

    pub fn destroyBuffer(self: *const Self, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ctx, handle);
    }

    pub fn getBufferMappedSlice(self: *const Self, handle: BufferHandle) ?[]u8 {
        return self.vtable.getBufferMappedSlice(self.ctx, handle);
    }

    pub fn createTexture(self: *const Self, desc: TextureDesc) Error!TextureHandle {
        return self.vtable.createTexture(self.ctx, desc);
    }

    pub fn destroyTexture(self: *const Self, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ctx, handle);
    }

    pub fn canUploadTexture(self: *const Self, handle: TextureHandle) bool {
        return self.vtable.canUploadTexture(self.ctx, handle);
    }

    pub fn uploadTexture(self: *const Self, handle: TextureHandle, data: []const u8) Error!void {
        return self.vtable.uploadTexture(self.ctx, handle, data);
    }

    pub fn createShaderModule(self: *const Self, desc: ShaderDesc) Error!ShaderHandle {
        return self.vtable.createShaderModule(self.ctx, desc);
    }

    pub fn destroyShaderModule(self: *const Self, handle: ShaderHandle) void {
        self.vtable.destroyShaderModule(self.ctx, handle);
    }

    pub fn createGraphicsPipeline(self: *const Self, desc: *const GraphicsPipelineDesc) Error!GraphicsPipelineHandle {
        return self.vtable.createGraphicsPipeline(self.ctx, desc);
    }

    pub fn destroyGraphicsPipeline(self: *const Self, handle: GraphicsPipelineHandle) void {
        self.vtable.destroyGraphicsPipeline(self.ctx, handle);
    }

    pub fn createComputePipeline(self: *const Self, desc: ComputePipelineDesc) Error!ComputePipelineHandle {
        return self.vtable.createComputePipeline(self.ctx, desc);
    }

    pub fn destroyComputePipeline(self: *const Self, handle: ComputePipelineHandle) void {
        self.vtable.destroyComputePipeline(self.ctx, handle);
    }

    pub fn claimWindow(self: *const Self, window_handle: WindowHandle, settings: WindowSettings) Error!void {
        return self.vtable.claimWindow(self.ctx, window_handle, settings);
    }

    pub fn releaseWindow(self: *const Self, window_handle: WindowHandle) void {
        self.vtable.releaseWindow(self.ctx, window_handle);
    }

    pub fn submit(self: *const Self, tpa: std.mem.Allocator, graph: *const RenderGraphDesc) Error!void {
        return self.vtable.submit(self.ctx, tpa, graph);
    }

    pub fn waitIdle(self: *const Self) void {
        self.vtable.waitIdle(self.ctx);
    }
};

// ----------------------------
// Command Encoder Types
// ----------------------------
pub const GraphResource = union(enum) {
    uniform_buffer: RenderGraphBufferIndex,
    storage_buffer: RenderGraphBufferIndex,
    sampled_texture: RenderGraphTextureIndex,
    storage_texture: RenderGraphTextureIndex,
};

pub const GraphicsCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setPipeline: *const fn (ctx: *anyopaque, pipeline: GraphicsPipelineHandle) void,
        setViewport: *const fn (ctx: *anyopaque, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void,
        setScissor: *const fn (ctx: *anyopaque, x: i32, y: i32, width: u32, height: u32) void,
        setVertexBuffer: *const fn (ctx: *anyopaque, slot: u32, buffer: RenderGraphBufferIndex, offset: usize) void,
        setIndexBuffer: *const fn (ctx: *anyopaque, buffer: RenderGraphBufferIndex, offset: usize, index_type: IndexType) void,

        pushResources: *const fn (ctx: *anyopaque, resources: []const GraphResource) void,

        draw: *const fn (ctx: *anyopaque, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void,
        drawIndexed: *const fn (ctx: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void,
    };

    pub fn setPipeline(self: Self, pipeline: GraphicsPipelineHandle) void {
        self.vtable.setPipeline(self.ctx, pipeline);
    }

    pub fn pushResources(self: Self, resources: []const GraphResource) void {
        self.vtable.pushResources(self.ctx, resources);
    }

    pub fn setVertexBuffer(self: Self, slot: u32, buffer: RenderGraphBufferIndex, offset: usize) void {
        self.vtable.setVertexBuffer(self.ctx, slot, buffer, offset);
    }

    pub fn setIndexBuffer(self: Self, buffer: RenderGraphBufferIndex, offset: usize, index_type: IndexType) void {
        self.vtable.setIndexBuffer(self.ctx, buffer, offset, index_type);
    }

    pub fn draw(self: Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.vtable.draw(self.ctx, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(self: Self, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        self.vtable.drawIndexed(self.ctx, index_count, instance_count, first_index, vertex_offset, first_instance);
    }
};

pub const ComputeCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setPipeline: *const fn (ctx: *anyopaque, pipeline: ComputePipelineHandle) void,
        dispatch: *const fn (ctx: *anyopaque, x: u32, y: u32, z: u32) void,
    };
};

pub const TransferCommandEncoder = struct {
    const Self = @This();

    pub const Callback = *const fn (data: ?*anyopaque, encoder: Self) void;

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        updateBuffer: *const fn (ctx: *anyopaque, buffer: RenderGraphBufferIndex, offset: usize, data: []const u8) void,
    };

    pub fn updateBuffer(self: Self, buffer: RenderGraphBufferIndex, offset: usize, data: []const u8) void {
        self.vtable.updateBuffer(self.ctx, buffer, offset, data);
    }
};

// ----------------------------
// RenderGraph Types
// ----------------------------
pub const RenderGraphBufferIndex = struct { idx: u32 };
pub const RenderGraphTextureIndex = struct { idx: u32 };

pub const RenderGraphDesc = struct {
    const Self = @This();

    windows: []const WindowEntry = &.{},
    buffers: []const BufferEntry = &.{},
    textures: []const TextureEntry = &.{},
    passes: []const RenderPass = &.{},
};

pub const WindowEntry = struct {
    handle: WindowHandle,
    texture: RenderGraphTextureIndex,
};

pub const BufferEntry = struct {
    source: union(enum) {
        persistent: BufferHandle,
    },
    usages: ?struct {
        first_pass_used: u16,
        last_pass_used: u16,
        last_access: RenderGraphBufferUsage,
    } = null,
};

pub const RenderGraphBufferUsage = enum(u32) {
    none,
};

pub const RenderGraphBufferAccess = struct {
    buffer: RenderGraphBufferIndex,
    usage: RenderGraphBufferUsage,
};

pub const TextureEntry = struct {
    source: union(enum) {
        persistent: TextureHandle,
        window: u32, //Lookup into RenderGraphwindows
    },
    usages: ?struct {
        first_pass_used: u16,
        last_pass_used: u16,
        last_access: RenderGraphTextureUsage,
    } = null,
};

pub const RenderGraphTextureUsage = enum(u32) {
    none,
    attachment_write,
    attachment_read,
    present,
};

pub const RenderGraphTextureAccess = struct {
    texture: RenderGraphTextureIndex,
    usage: RenderGraphTextureUsage,
};

pub const RenderGraphColorAttachment = struct {
    texture: RenderGraphTextureIndex,
    clear: ?[4]f32,
};

pub const RenderGraphDepthAttachment = struct {
    texture: RenderGraphTextureIndex,
    clear: ?f32,
};

pub const RenderGraphRenderTarget = struct {
    color_attachemnts: FixedArrayList(RenderGraphColorAttachment, 8) = .empty,
    depth_attachment: ?RenderGraphDepthAttachment = null,
};

pub const RenderCallback = struct {
    ctx: ?*anyopaque,
    callback: GraphicsCommandEncoder.Callback,
};

pub const TransferCallback = struct {
    ctx: ?*anyopaque,
    callback: TransferCommandEncoder.Callback,
};

pub const RenderPass = struct {
    name: FixedString,
    render_target: ?RenderGraphRenderTarget = null,
    render_callback: ?RenderCallback = null,
    transfer_callback: ?TransferCallback = null,

    buffer_usages: FixedArrayList(RenderGraphBufferAccess, 32),
    texture_usages: FixedArrayList(RenderGraphTextureAccess, 32),
};

pub const RenderGraphBuilder = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    windows: std.ArrayList(WindowEntry) = .empty,
    buffers: std.ArrayList(BufferEntry) = .empty,
    textures: std.ArrayList(TextureEntry) = .empty,
    passes: std.ArrayList(RenderPass) = .empty,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // autofix
    }

    pub fn importBuffer(self: *Self, handle: BufferHandle) !RenderGraphBufferIndex {
        const idx: u32 = @intCast(self.buffers.items.len);
        try self.buffers.append(self.gpa, .{
            .source = .{ .persistent = handle },
        });
        return .{ .idx = idx };
    }

    pub fn importTexture(self: *Self, handle: TextureHandle) !RenderGraphTextureIndex {
        const idx: u32 = @intCast(self.textures.items.len);
        try self.textures.append(self.gpa, .{
            .source = .{ .persistent = handle },
        });
        return .{ .idx = idx };
    }

    pub fn importWindow(self: *Self, handle: WindowHandle) !RenderGraphTextureIndex {
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
        render_target: ?RenderGraphRenderTarget = null,
        render_callback: ?RenderCallback = null,
        transfer_callback: ?TransferCallback = null,
        buffer_usages: FixedArrayList(RenderGraphBufferAccess, 32) = .empty,
        texture_usages: FixedArrayList(RenderGraphTextureAccess, 32) = .empty,

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

    pub fn build(self: *Self) RenderGraphDesc {
        return .{
            .windows = self.windows.items,
            .buffers = self.buffers.items,
            .textures = self.textures.items,
            .passes = self.passes.items,
        };
    }
};
