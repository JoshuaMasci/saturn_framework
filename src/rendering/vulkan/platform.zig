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
        validation: bool,
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
            validation,
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

        pub fn reset(self: *@This(), device: *Device) void {
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
                device.device.proxy.destroyPipeline(pipeline, null);
            }
            self.freed.pipelines.clearRetainingCapacity();

            for (self.freed.buffers.items) |buffer| {
                if (buffer.uniform_binding) |binding| {
                    device.descriptor.uniform_buffer_array.clear(binding);
                }

                if (buffer.storage_binding) |binding| {
                    device.descriptor.storage_buffer_array.clear(binding);
                }

                buffer.deinit(device.device);
            }
            self.freed.buffers.clearRetainingCapacity();

            for (self.freed.texture.items) |texture| {
                if (texture.sampled_binding) |binding| {
                    device.descriptor.sampled_image_array.clear(binding);
                }

                if (texture.storage_binding) |binding| {
                    device.descriptor.storage_image_array.clear(binding);
                }

                texture.deinit(device.device);
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
    linear_sampler: vk.Sampler,

    swapchains: std.AutoHashMap(saturn.WindowHandle, *Swapchain),
    shader_modules: std.AutoHashMap(saturn.ShaderHandle, vk.ShaderModule),
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

        const physical_device = backend.instance.physical_devices[physical_device_index];

        if (desc.features.ray_tracing and !physical_device.info.extensions.ray_tracing) {
            return error.FeatureNotSupported;
        }

        if (desc.features.mesh_shading and !physical_device.info.extensions.mesh_shading) {
            return error.FeatureNotSupported;
        }

        if (desc.features.host_image_copy and !physical_device.info.extensions.host_image_copy) {
            return error.FeatureNotSupported;
        }

        device.* = VkDevice.init(
            gpa,
            backend.instance.proxy,
            physical_device,
            desc.features,
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

        const linear_sampler = device.proxy.createSampler(&.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = .false,
            .max_anisotropy = 0.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = vk.LOD_CLAMP_NONE,
            .border_color = .float_opaque_black,
            .unnormalized_coordinates = .false,
        }, null) catch return error.InitializationFailed;
        errdefer device.proxy.destroySampler(linear_sampler, null);

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
            .linear_sampler = linear_sampler,

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
            frame_data.reset(self);
            frame_data.deinit(self.gpa);
        }
        self.gpa.free(self.per_frame_data);

        var shader_iter = self.shader_modules.valueIterator();
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

        self.device.proxy.destroySampler(self.linear_sampler, null);
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
                .getBufferMappedSlice = getBufferMappedSlice,
                .createTexture = createTexture,
                .destroyTexture = destroyTexture,
                .canUploadTexture = canUploadTexture,
                .uploadTexture = uploadTexture,
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

        if (desc.usage.uniform) {
            buffer.uniform_binding = self.descriptor.uniform_buffer_array.bind(buffer);
        }

        if (desc.usage.storage) {
            buffer.storage_binding = self.descriptor.storage_buffer_array.bind(buffer);
        }

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
                if (entry.value.uniform_binding) |binding| {
                    self.descriptor.uniform_buffer_array.clear(binding);
                }

                if (entry.value.storage_binding) |binding| {
                    self.descriptor.storage_buffer_array.clear(binding);
                }

                entry.value.deinit(self.device);
            };
        }
    }

    fn getBufferMappedSlice(ctx: *anyopaque, handle: saturn.BufferHandle) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_buffer: vk.Buffer = @enumFromInt(@intFromEnum(handle));

        if (self.buffers.get(vk_buffer)) |entry| {
            return entry.allocation.getMappedByteSlice();
        }

        return null;
    }

    fn createTexture(ctx: *anyopaque, desc: saturn.TextureDesc) saturn.Error!saturn.TextureHandle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const format = Texture.getVkFormat(desc.format);
        const usage = Texture.getVkImageUsage(desc.usage, desc.format.isColor());

        var texture = Texture.init2D(self.device, .{ .width = desc.width, .height = desc.height }, format, usage, .gpu_only) catch |err| {
            return switch (err) {
                error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
                error.NoSuitableMemoryType => error.InvalidUsage,
                else => error.Unknown,
            };
        };
        errdefer texture.deinit(self.device);

        if (desc.usage.sampled) {
            texture.sampled_binding = self.descriptor.sampled_image_array.bind(texture, self.linear_sampler);
        }

        if (desc.usage.storage) {
            texture.storage_binding = self.descriptor.storage_image_array.bind(texture, .null_handle);
        }

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
                if (entry.value.sampled_binding) |binding| {
                    self.descriptor.sampled_image_array.clear(binding);
                }

                if (entry.value.storage_binding) |binding| {
                    self.descriptor.storage_image_array.clear(binding);
                }

                entry.value.deinit(self.device);
            };
        }
    }

    fn canUploadTexture(ctx: *anyopaque, handle: saturn.TextureHandle) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_image: vk.Image = @enumFromInt(@intFromEnum(handle));

        if (self.device.extensions.host_image_copy) {
            if (self.textures.get(vk_image)) |texture| {
                if (texture.usage.host_transfer_bit) {
                    if (texture.allocation) |allocation| {
                        return allocation.mapped_ptr != null;
                    }
                }
            }
        }

        return false;
    }

    fn uploadTexture(ctx: *anyopaque, handle: saturn.TextureHandle, data: []const u8) saturn.Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const vk_image: vk.Image = @enumFromInt(@intFromEnum(handle));
        std.debug.assert(self.device.extensions.host_image_copy);

        if (self.textures.get(vk_image)) |texture| {
            texture.hostImageCopy(self.device, .shader_read_only_optimal, data) catch return error.Unknown;
        }
    }

    fn createShaderModule(ctx: *anyopaque, desc: saturn.ShaderDesc) saturn.Error!saturn.ShaderHandle {
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

        const handle: saturn.ShaderHandle = @enumFromInt(@intFromEnum(module));

        self.shader_modules.put(handle, module) catch {
            self.device.proxy.destroyShaderModule(module, null);
            return error.OutOfMemory;
        };

        return handle;
    }

    fn destroyShaderModule(ctx: *anyopaque, handle: saturn.ShaderHandle) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.shader_modules.fetchRemove(handle)) |module| {
            self.device.proxy.destroyShaderModule(module.value, null);
        }
    }

    fn createGraphicsPipeline(ctx: *anyopaque, desc: *const saturn.GraphicsPipelineDesc) saturn.Error!saturn.GraphicsPipelineHandle {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const pipeline = Pipeline.createGraphicsPipeline(self, desc) catch return error.InvalidUsage;
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
        const vk_format = Texture.getVkFormat(desc.texture_format);
        const vk_usage = Texture.getVkImageUsage(desc.texture_usage, true); //Swapchain is always color
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
        frame_data.reset(self);

        self.descriptor.writeUpdates(tpa) catch return error.DeviceLost;

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

fn getVkPresentMode(mode: saturn.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .fifo => .fifo_khr,
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
    };
}
