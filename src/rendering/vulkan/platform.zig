const std = @import("std");

const vk = @import("vulkan");

const saturn = @import("../../root.zig");

const Instance = @import("instance.zig");

const VkDevice = @import("device.zig");
const Swapchain = @import("swapchain.zig");
const object_pools = @import("object_pools.zig");
const Buffer = @import("buffer.zig");
const Texture = @import("texture.zig");
const Pipeline = @import("pipeline.zig");
const BindlessDescriptor = @import("bindless_descriptor.zig");

const GraphResources = @import("graph_resources.zig");
const graph_compiler = @import("graph_compiler.zig");
const graph_executor = @import("graph_executor.zig");

pub const SurfaceCreateFn = *const fn (instance: vk.Instance, window: saturn.WindowHandle, allocator: ?*const vk.AllocationCallbacks) ?vk.SurfaceKHR;
pub const GetWindowSizeFn = *const fn (window: saturn.WindowHandle, user_data: ?*anyopaque) [2]u32;

pub const Backend = struct {
    const Self = @This();

    gpa: std.mem.Allocator,

    instance: *Instance,

    create_surface_fn: SurfaceCreateFn,
    surfaces: std.AutoArrayHashMap(saturn.WindowHandle, vk.SurfaceKHR),

    devices: std.AutoHashMap(*Device, void),

    // Window size callback
    get_window_size_fn: GetWindowSizeFn,
    get_window_size_user_data: ?*anyopaque,

    pub fn init(
        gpa: std.mem.Allocator,
        loader: vk.PfnGetInstanceProcAddr,
        extensions: []const [*c]const u8,
        create_surface_fn: SurfaceCreateFn,
        get_window_size_fn: GetWindowSizeFn,
        get_window_size_user_data: ?*anyopaque,
        engine: saturn.AppInfo,
        app: saturn.AppInfo,
        debug: bool,
    ) saturn.Error!Self {
        const instance = try gpa.create(Instance);
        errdefer gpa.destroy(instance);

        instance.* = Instance.init(
            gpa,
            loader,
            extensions,
            .{
                .p_engine_name = engine.name,
                .engine_version = engine.version.toU32(),
                .p_application_name = app.name,
                .application_version = app.version.toU32(),
                .api_version = @bitCast(vk.API_VERSION_1_3),
            },
            debug,
        ) catch return error.FailedToInitRenderingBackend;
        errdefer instance.deinit();

        return .{
            .gpa = gpa,
            .instance = instance,
            .create_surface_fn = create_surface_fn,
            .surfaces = .init(gpa),
            .devices = .init(gpa),
            .get_window_size_fn = get_window_size_fn,
            .get_window_size_user_data = get_window_size_user_data,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.devices.keyIterator();
        while (iter.next()) |device_ptr| {
            device_ptr.*.deinit();
            self.gpa.destroy(device_ptr.*);
        }
        self.devices.deinit();

        self.surfaces.deinit();
        self.instance.deinit();
        self.gpa.destroy(self.instance);
    }

    pub fn createSurface(self: *Self, window: saturn.WindowHandle) saturn.Error!void {
        const surface = self.create_surface_fn(self.instance.proxy.handle, window, null) orelse return error.FailedToCreateSurface;
        try self.surfaces.put(window, surface);
    }

    pub fn destroySurface(self: *Self, window: saturn.WindowHandle) void {
        if (self.surfaces.get(window)) |surface| {
            self.instance.proxy.destroySurfaceKHR(surface, null);
            _ = self.surfaces.swapRemove(window);
        }
    }

    pub fn doesDeviceSupportPresent(self: *Self, device_index: u32, window: saturn.WindowHandle) bool {
        if (self.surfaces.get(window)) |surface| {
            const result = self.instance.proxy.getPhysicalDeviceSurfaceSupportKHR(
                self.instance.physical_devices[device_index].handle,
                self.instance.physical_devices[device_index].info.queues.graphics.?,
                surface,
            ) catch return false;
            return result == .true;
        }

        return false;
    }

    pub fn createDevice(
        self: *Self,
        physical_device_index: u32,
        desc: saturn.DeviceDesc,
    ) saturn.Error!saturn.DeviceInterface {
        const device_ptr = try self.gpa.create(Device);
        errdefer self.gpa.destroy(device_ptr);

        device_ptr.* = try .init(
            self.gpa,
            self,
            physical_device_index,
            desc,
        );
        errdefer device_ptr.deinit();

        try self.devices.put(device_ptr, {});
        return device_ptr.interface();
    }

    pub fn destroyDevice(self: *Self, device: saturn.DeviceInterface) void {
        const device_ptr: *Device = @ptrCast(@alignCast(device.ctx));

        if (self.devices.remove(device_ptr)) {
            device.waitIdle();
            device_ptr.deinit();
            self.gpa.destroy(device_ptr);
        }
    }
};

pub const Device = struct {
    const PerFrameData = struct {
        frame_wait_fences: std.ArrayList(vk.Fence) = .empty,
        graphics_command_pool: object_pools.CommandBufferPool,
        semaphore_pool: object_pools.SemaphorePool,
        fence_pool: object_pools.FencePool,

        //Freed items
        freed: struct {
            pipelines: std.ArrayList(vk.Pipeline) = .empty,
            buffers: std.ArrayList(Buffer) = .empty,
            texture: std.ArrayList(Texture) = .empty,
        } = .{},

        pub fn init(gpa: std.mem.Allocator, device: *VkDevice) !PerFrameData {
            return .{
                .graphics_command_pool = try .init(gpa, device, device.graphics_queue),
                .semaphore_pool = .init(gpa, device, .binary, 0),
                .fence_pool = .init(gpa, device, .{}),
            };
        }

        pub fn deinit(self: *PerFrameData, gpa: std.mem.Allocator) void {
            self.frame_wait_fences.deinit(gpa);
            self.graphics_command_pool.deinit();
            self.semaphore_pool.deinit();
            self.fence_pool.deinit();

            self.freed.pipelines.deinit(gpa);
            self.freed.buffers.deinit(gpa);
            self.freed.texture.deinit(gpa);
        }

        pub fn reset(self: *@This(), device: *VkDevice) void {
            self.frame_wait_fences.clearRetainingCapacity();
            self.graphics_command_pool.reset() catch |err| {
                //If this fails, well just allocate more buffers I guess ¯\_(ツ)_/¯
                std.log.err("Failed to reset command pool: {}", .{err});
            };
            self.semaphore_pool.reset();
            self.fence_pool.reset() catch |err| {
                //If this fails, IDK what to do ¯\_(ツ)_/¯
                std.log.err("Failed to reset fence pool: {}", .{err});
            };

            for (self.freed.pipelines.items) |pipeline| {
                device.proxy.destroyPipeline(pipeline, null);
            }
            self.freed.pipelines.clearRetainingCapacity();

            for (self.freed.buffers.items) |buffer| {
                buffer.deinit(device);
            }
            self.freed.buffers.clearRetainingCapacity();

            for (self.freed.texture.items) |texture| {
                texture.deinit(device);
            }
            self.freed.texture.clearRetainingCapacity();
        }
    };

    const Self = @This();

    gpa: std.mem.Allocator,
    backend: *Backend,
    physical_device_index: u32,
    device: *VkDevice,
    descriptor: BindlessDescriptor,

    pipeline_layout: vk.PipelineLayout,

    swapchains: std.AutoHashMap(saturn.WindowHandle, *Swapchain),
    shader_modules: std.AutoHashMap(vk.ShaderModule, void),
    graphics_pipelines: std.AutoHashMap(vk.Pipeline, void),
    compute_pipelines: std.AutoHashMap(vk.Pipeline, void),
    buffers: std.AutoHashMap(vk.Buffer, Buffer),
    textures: std.AutoHashMap(vk.Image, Texture),

    // Dynamic frames in flight
    frame_index: usize = 0,
    per_frame_data: []PerFrameData,

    submit_timeout_ns: u64 = std.time.ns_per_s * 5,

    pub fn init(
        gpa: std.mem.Allocator,
        backend: *Backend,
        physical_device_index: u32,
        desc: saturn.DeviceDesc,
    ) saturn.Error!Self {
        var device = try gpa.create(VkDevice);
        errdefer gpa.destroy(device);

        device.* = VkDevice.init(
            gpa,
            backend.instance.proxy,
            backend.instance.physical_devices[physical_device_index],
            .{},
            backend.instance.debug_messager != null,
        ) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                error.ExtensionNotPresent => error.ExtensionNotSupported,
                error.FeatureNotPresent => error.FeatureNotSupported,
                else => error.InitializationFailed,
            };
        };
        errdefer device.deinit();

        var descriptor = BindlessDescriptor.init(gpa, device, .{
            .uniform_buffers = 1024,
            .storage_buffers = 1024,
            .sampled_images = 1024,
            .storage_images = 1024,
        }) catch return error.InitializationFailed;
        errdefer descriptor.deinit();

        const descriptor_set_layouts: []const vk.DescriptorSetLayout = &.{descriptor.layout};
        const push_ranges: []const vk.PushConstantRange = &.{.{ .offset = 0, .size = 256, .stage_flags = device.all_stage_flags }};

        const pipeline_layout = device.proxy.createPipelineLayout(&.{
            .set_layout_count = @intCast(descriptor_set_layouts.len),
            .p_set_layouts = descriptor_set_layouts.ptr,
            .push_constant_range_count = @intCast(push_ranges.len),
            .p_push_constant_ranges = push_ranges.ptr,
        }, null) catch return error.InitializationFailed;
        errdefer device.proxy.destroyPipelineLayout(pipeline_layout, null);

        const per_frame_data = try gpa.alloc(PerFrameData, desc.frames_in_flight);
        errdefer gpa.free(per_frame_data);

        for (per_frame_data) |*frame_data| {
            frame_data.* = PerFrameData.init(gpa, device) catch return error.OutOfMemory;
        }
        errdefer {
            for (per_frame_data) |*frame_data| {
                frame_data.deinit(gpa);
            }
        }

        return .{
            .gpa = gpa,
            .backend = backend,
            .physical_device_index = physical_device_index,
            .device = device,

            .descriptor = descriptor,
            .pipeline_layout = pipeline_layout,

            .swapchains = .init(gpa),
            .shader_modules = .init(gpa),
            .graphics_pipelines = .init(gpa),
            .compute_pipelines = .init(gpa),

            .buffers = .init(gpa),
            .textures = .init(gpa),

            .per_frame_data = per_frame_data,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self.device.proxy.deviceWaitIdle() catch {};

        for (self.per_frame_data) |*frame_data| {
            frame_data.reset(self.device);
            frame_data.deinit(self.gpa);
        }
        self.gpa.free(self.per_frame_data);

        var shader_iter = self.shader_modules.keyIterator();
        while (shader_iter.next()) |module| {
            self.device.proxy.destroyShaderModule(module.*, null);
        }
        self.shader_modules.deinit();

        var graphics_iter = self.graphics_pipelines.keyIterator();
        while (graphics_iter.next()) |pipeline| {
            self.device.proxy.destroyPipeline(pipeline.*, null);
        }
        self.graphics_pipelines.deinit();

        var compute_iter = self.compute_pipelines.keyIterator();
        while (compute_iter.next()) |pipeline| {
            self.device.proxy.destroyPipeline(pipeline.*, null);
        }

        self.device.proxy.destroyPipelineLayout(self.pipeline_layout, null);
        self.descriptor.deinit();

        var swapchain_iter = self.swapchains.valueIterator();
        while (swapchain_iter.next()) |swapchain| {
            swapchain.*.deinit();
            self.gpa.destroy(swapchain.*);
        }
        self.swapchains.deinit();

        var buffer_iter = self.buffers.valueIterator();
        while (buffer_iter.next()) |buf| {
            buf.deinit(self.device);
        }
        self.buffers.deinit();

        var texture_iter = self.textures.valueIterator();
        while (texture_iter.next()) |tex| {
            tex.deinit(self.device);
        }
        self.textures.deinit();

        self.device.deinit();
        self.gpa.destroy(self.device);
    }

    pub fn interface(self: *Self) saturn.DeviceInterface {
        return .{
            .ctx = self,
            .vtable = &.{
                .getInfo = getInfo,
                .createBuffer = createBuffer,
                .destroyBuffer = destroyBuffer,
                .createTexture = createTexture,
                .destroyTexture = destroyTexture,
                .createShaderModule = createShaderModule,
                .destroyShaderModule = destroyShaderModule,
                .createGraphicsPipeline = createGraphicsPipeline,
                .destroyGraphicsPipeline = destroyGraphicsPipeline,
                .createComputePipeline = createComputePipeline,
                .destroyComputePipeline = destroyComputePipeline,
                .claimWindow = claimWindow,
                .releaseWindow = releaseWindow,
                .submit = submit,
                .waitIdle = waitIdle,
            },
        };
    }

    fn getInfo(ctx: *anyopaque) saturn.DeviceInfo {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backend.instance.physical_devices_info[self.physical_device_index];
    }

    fn createBuffer(ctx: *anyopaque, desc: saturn.BufferDesc) saturn.Error!saturn.BufferHandle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const usage = getVkBufferUsage(desc.usage);

        const memory_location: @import("gpu_allocator.zig").MemoryLocation = switch (desc.memory) {
            .gpu_only => .gpu_only,
            .cpu_to_gpu => .gpu_mappable,
            .gpu_to_cpu => .cpu_only,
        };

        var buffer = Buffer.init(
            self.device,
            desc.size,
            usage,
            memory_location,
        ) catch |err| {
            return switch (err) {
                error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
                error.NoSuitableMemoryType => error.InvalidUsage,
                else => error.Unknown,
            };
        };
        errdefer buffer.deinit(self.device);

        self.buffers.put(buffer.handle, buffer) catch return error.OutOfMemory;

        if (self.device.debug) {
            self.device.proxy.setDebugUtilsObjectNameEXT(&.{
                .object_type = .buffer,
                .object_handle = @intFromEnum(buffer.handle),
                .p_object_name = desc.name,
            }) catch {};
        }

        return @enumFromInt(@intFromEnum(buffer.handle));
    }

    fn destroyBuffer(ctx: *anyopaque, buffer: saturn.BufferHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_buffer: vk.Buffer = @enumFromInt(@intFromEnum(buffer));

        if (self.buffers.fetchRemove(vk_buffer)) |entry| {
            self.per_frame_data[self.frame_index].freed.buffers.append(self.gpa, entry.value) catch {
                entry.value.deinit(self.device);
            };
        }
    }

    fn createTexture(ctx: *anyopaque, desc: saturn.TextureDesc) saturn.Error!saturn.TextureHandle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const format = getVkFormat(desc.format);
        const usage = getVkImageUsage(desc.usage);

        var texture = Texture.init2D(self.device, .{ .width = desc.width, .height = desc.height }, format, usage, .gpu_only) catch |err| {
            return switch (err) {
                error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
                error.NoSuitableMemoryType => error.InvalidUsage,
                else => error.Unknown,
            };
        };
        errdefer texture.deinit(self.device);

        self.textures.put(texture.handle, texture) catch return error.OutOfMemory;

        if (self.device.debug) {
            self.device.proxy.setDebugUtilsObjectNameEXT(&.{
                .object_type = .image,
                .object_handle = @intFromEnum(texture.handle),
                .p_object_name = desc.name,
            }) catch {};
        }

        return @enumFromInt(@intFromEnum(texture.handle));
    }

    fn destroyTexture(ctx: *anyopaque, texture: saturn.TextureHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_image: vk.Image = @enumFromInt(@intFromEnum(texture));

        if (self.textures.fetchRemove(vk_image)) |entry| {
            self.per_frame_data[self.frame_index].freed.texture.append(self.gpa, entry.value) catch {
                entry.value.deinit(self.device);
            };
        }
    }

    fn createShaderModule(ctx: *anyopaque, desc: saturn.Shader.Desc) saturn.Error!saturn.Shader.Handle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const module = self.device.proxy.createShaderModule(&.{
            .code_size = desc.code.len * @sizeOf(u32),
            .p_code = desc.code.ptr,
        }, null) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                error.OutOfDeviceMemory => error.OutOfDeviceMemory,
                else => error.InvalidUsage,
            };
        };

        self.shader_modules.put(module, {}) catch {
            self.device.proxy.destroyShaderModule(module, null);
            return error.OutOfMemory;
        };

        return @enumFromInt(@intFromEnum(module));
    }

    fn destroyShaderModule(ctx: *anyopaque, module: saturn.Shader.Handle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_module: vk.ShaderModule = @enumFromInt(@intFromEnum(module));

        if (self.shader_modules.remove(vk_module)) {
            self.device.proxy.destroyShaderModule(vk_module, null);
        }
    }

    fn createGraphicsPipeline(ctx: *anyopaque, desc: saturn.GraphicsPipelineDesc) saturn.Error!saturn.GraphicsPipelineHandle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const vertex_module: vk.ShaderModule = @enumFromInt(@intFromEnum(desc.vertex));
        const fragment_module: ?vk.ShaderModule = if (desc.fragment) |frag| @enumFromInt(@intFromEnum(frag)) else null;

        if (!self.shader_modules.contains(vertex_module)) return error.InvalidUsage;
        if (fragment_module) |module| {
            if (!self.shader_modules.contains(module)) return error.InvalidUsage;
        }

        const pipeline = Pipeline.createGraphicsPipeline(
            self.device.proxy,
            self.pipeline_layout,
            .{
                .color_format = getVkFormat(desc.color_formats[0]),
            },
            .{},
            vertex_module,
            fragment_module,
        ) catch return error.InvalidUsage;
        errdefer self.device.proxy.destroyPipeline(pipeline, null);

        try self.graphics_pipelines.put(pipeline, {});

        return @enumFromInt(@intFromEnum(pipeline));
    }

    fn destroyGraphicsPipeline(ctx: *anyopaque, pipeline: saturn.GraphicsPipelineHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_pipeline: vk.Pipeline = @enumFromInt(@intFromEnum(pipeline));

        if (self.graphics_pipelines.fetchRemove(vk_pipeline)) |entry| {
            self.per_frame_data[self.frame_index].freed.pipelines.append(self.gpa, entry.key) catch {
                self.device.proxy.destroyPipeline(entry.key, null);
            };
        }
    }

    fn createComputePipeline(ctx: *anyopaque, desc: saturn.ComputePipelineDesc) saturn.Error!saturn.ComputePipelineHandle {
        _ = desc; // autofix
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self; // autofix

        return error.OutOfMemory;
    }

    fn destroyComputePipeline(ctx: *anyopaque, pipeline: saturn.ComputePipelineHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_pipeline: vk.Pipeline = @enumFromInt(@intFromEnum(pipeline));

        if (self.compute_pipelines.fetchRemove(vk_pipeline)) |entry| {
            self.per_frame_data[self.frame_index].freed.pipelines.append(self.gpa, entry.key) catch {
                self.device.proxy.destroyPipeline(entry.key, null);
            };
        }
    }

    fn claimWindow(ctx: *anyopaque, window: saturn.WindowHandle, desc: saturn.WindowSettings) saturn.Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Use existing conversion functions
        const vk_format = getVkFormat(desc.texture_format);
        const vk_usage = getVkImageUsage(desc.texture_usage);
        const vk_present_mode = getVkPresentMode(desc.present_mode);

        // Get the surface for this window
        const surface = self.backend.surfaces.get(window) orelse return error.WindowLost;

        // Query the window size from the platform via callback
        const size = self.backend.get_window_size_fn(window, self.backend.get_window_size_user_data);
        const extent = vk.Extent2D{ .width = size[0], .height = size[1] };

        if (self.swapchains.get(window)) |swapchain| {
            const old_swapchain: Swapchain = swapchain.*;
            errdefer old_swapchain.deinit();

            swapchain.* = Swapchain.init(
                self.device,
                surface,
                extent,
                desc.texture_count,
                vk_usage,
                vk_format,
                vk_present_mode,
                null,
            ) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
                    error.DeviceLost => error.DeviceLost,
                    error.SurfaceLostKHR => error.WindowLost,
                    else => error.Unknown,
                };
            };
        } else {
            const swapchain = try self.gpa.create(Swapchain);
            errdefer self.gpa.destroy(swapchain);

            swapchain.* = Swapchain.init(
                self.device,
                surface,
                extent,
                desc.texture_count,
                vk_usage,
                vk_format,
                vk_present_mode,
                null,
            ) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
                    error.DeviceLost => error.DeviceLost,
                    error.SurfaceLostKHR => error.WindowLost,
                    else => error.Unknown,
                };
            };

            try self.swapchains.put(window, swapchain);
        }
    }

    fn releaseWindow(ctx: *anyopaque, window: saturn.WindowHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.swapchains.fetchRemove(window)) |entry| {
            self.device.proxy.deviceWaitIdle() catch {};
            entry.value.deinit();
            self.gpa.destroy(entry.value);
        }
    }

    fn submit(ctx: *anyopaque, tpa: std.mem.Allocator, graph: *const saturn.RenderGraphDesc) saturn.Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const frame_data = &self.per_frame_data[self.frame_index];

        //Wait for previous frame to finish
        if (frame_data.frame_wait_fences.items.len > 0) {
            _ = self.device.proxy.waitForFences(
                @intCast(frame_data.frame_wait_fences.items.len),
                frame_data.frame_wait_fences.items.ptr,
                .true,
                self.submit_timeout_ns,
            ) catch return error.DeviceLost;
            frame_data.frame_wait_fences.clearRetainingCapacity();
        }
        frame_data.reset(self.device);

        const graph_resources = GraphResources.init(tpa, graph, self) catch return error.DeviceLost;
        defer graph_resources.deinit(tpa);

        const compiled_graph = graph_compiler.compileGraphBasic(tpa, graph, &graph_resources, .{}) catch return error.DeviceLost;

        graph_executor.executeGraph(tpa, self, graph, &graph_resources, &compiled_graph) catch |err| std.log.err("Failed to render graph: {}", .{err});

        self.frame_index = (self.frame_index + 1) % self.per_frame_data.len;
    }

    fn waitIdle(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.device.proxy.deviceWaitIdle() catch {};
    }
};

fn getVkBufferUsage(usage: saturn.BufferUsage) vk.BufferUsageFlags {
    return .{
        .vertex_buffer_bit = usage.vertex,
        .index_buffer_bit = usage.index,
        .uniform_buffer_bit = usage.uniform,
        .storage_buffer_bit = usage.storage,
        .transfer_src_bit = usage.transfer_src,
        .transfer_dst_bit = usage.transfer_dst,
    };
}

fn getVkFormat(format: saturn.TextureFormat) vk.Format {
    return switch (format) {
        .rgba8_unorm => .r8g8b8a8_unorm,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .rgba16_float => .r16g16b16a16_sfloat,
        .depth32_float => .d32_sfloat,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc1_rgba_srgb => .bc1_rgba_srgb_block,
        .bc2_rgba_unorm => .bc2_unorm_block,
        .bc2_rgba_srgb => .bc2_srgb_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc3_rgba_srgb => .bc3_srgb_block,
        .bc4_r_unorm => .bc4_unorm_block,
        .bc4_r_snorm => .bc4_snorm_block,
        .bc5_rg_unorm => .bc5_unorm_block,
        .bc5_rg_snorm => .bc5_snorm_block,
        .bc6h_rgb_ufloat => .bc6h_ufloat_block,
        .bc6h_rgb_sfloat => .bc6h_sfloat_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
        .bc7_rgba_srgb => .bc7_srgb_block,
    };
}

fn getVkImageUsage(usage: saturn.TextureUsage) vk.ImageUsageFlags {
    return .{
        .transfer_src_bit = usage.transfer,
        .transfer_dst_bit = usage.transfer,
        .sampled_bit = usage.sampled,
        .storage_bit = usage.storage,
        .color_attachment_bit = usage.attachment,
    };
}

fn getVkPresentMode(mode: saturn.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .fifo => .fifo_khr,
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
    };
}
