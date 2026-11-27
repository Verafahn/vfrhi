//! A Vulkan backend for vfrhi.
//!
//! The backend owns a Vulkan instance, a logical device, and every
//! resource created through the RHI. It does not create or destroy
//! the application's window, and it does not require any window
//! manager: surfaces are described by native handles supplied by the
//! caller.

const std = @import("std");
const vk = @import("vulkan");
const rhi = @import("rhi");
const types = rhi.types;
const commands = @import("../../Command.zig");
const Resource = rhi.Resource;
const Device = rhi.Device;
const Queue = rhi.Queue;
const Error = rhi.Error;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vulkan);

/// The API version type used by this backend.
pub const Version = rhi.Version;

/// Creation parameters of a Vulkan backend.
pub const VulkanDesc = struct {
    /// Optional application name reported to the driver.
    application_name: ?[:0]const u8 = null,
    /// Application version reported to the driver.
    application_version: Version = .api_1_0,
    /// Optional engine name reported to the driver.
    engine_name: ?[:0]const u8 = null,
    /// Engine version reported to the driver.
    engine_version: Version = .api_1_0,
    /// API version requested by the application.
    api_version: Version = .api_1_3,
    /// Null terminated instance extension names.
    ///
    /// The caller is responsible for enabling the platform surface
    /// extensions it needs, such as `VK_KHR_win32_surface`.
    enabled_extension: ?[*]const [*:0]const u8 = null,
    /// Number of entries in `enabled_extension`.
    extension_count: u32 = 0,
    /// Optional Vulkan allocation callbacks.
    allocator: ?*const vk.AllocationCallbacks = null,
};

const BufferState = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: u64,
    hints: types.Memory,
    host_visible: bool,
    non_coherent: bool,
    mapped: ?[*]u8 = null,
};

const TextureState = struct {
    handle: vk.Image,
    memory: vk.DeviceMemory,
    owns_memory: bool,
    properties: types.TextureProperties,
    layout: types.TextureLayout,
};

const TextureViewState = struct {
    handle: vk.ImageView,
    aspect: types.TextureAspect,
};

const SwapchainState = struct {
    handle: vk.SwapchainKHR,
    surface: Resource,
    properties: types.SwapchainProperties,
    images: []Resource,
    views: []Resource,
};

const ShaderState = struct {
    module: vk.ShaderModule,
    stage: types.ShaderStage,
    entry_point: [:0]u8,
};

const DescriptorSetLayoutState = struct {
    handle: vk.DescriptorSetLayout,
    bindings: []types.DescriptorSetLayoutDescription.DescriptorBinding,
};

const DescriptorSetState = struct {
    handle: vk.DescriptorSet,
    layout: Resource,
};

const PipelineState = struct {
    handle: vk.Pipeline,
    bind_point: types.BindPoint,
};

const CommandBufferState = struct {
    handle: vk.CommandBuffer,
    level: types.CommandBufferDescription.Level,
    state: State = .initial,

    const State = enum {
        initial,
        recording,
        ended,
        submitted,
    };
};

const Handle = union(Resource.Tag) {
    surface: vk.SurfaceKHR,
    swapchain: SwapchainState,
    buffer: BufferState,
    texture: TextureState,
    texture_view: TextureViewState,
    sampler: vk.Sampler,
    shader: ShaderState,
    descriptor_set_layout: DescriptorSetLayoutState,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set: DescriptorSetState,
    pipeline: PipelineState,
    command_buffer: CommandBufferState,
    fence: vk.Fence,
    semaphore: vk.Semaphore,
};

const Slot = struct {
    generation: u32,
    tag: Resource.Tag,
    handle: Handle,
};

/// A Vulkan backend instance.
///
/// The backend owns the Vulkan instance, physical device, logical
/// device, and every RHI resource. Create it with `init` and destroy
/// it with `deinit` after all RHI resources are gone.
pub const Vulkan = struct {
    pub const Desc = VulkanDesc;
    pub const Version = rhi.Version;

    allocator: Allocator,
    vk_allocator: ?*const vk.AllocationCallbacks,

    instance: vk.Instance = undefined,
    vki_wrapper: vk.InstanceWrapper = undefined,
    vki: vk.InstanceProxy = undefined,

    physical_device: vk.PhysicalDevice = undefined,
    properties: vk.PhysicalDeviceProperties = undefined,
    memory_properties: vk.PhysicalDeviceMemoryProperties = undefined,

    device: vk.Device = undefined,
    vkd_wrapper: vk.DeviceWrapper = undefined,
    vkd: vk.DeviceProxy = undefined,

    queue_family_index: u32 = 0,
    queue: vk.Queue = undefined,
    supports_swapchain: bool = false,

    command_pool: vk.CommandPool = .null,
    descriptor_pool: vk.DescriptorPool = .null,

    slots: std.ArrayListUnmanaged(?Slot) = .empty,
    generations: std.ArrayListUnmanaged(u32) = .empty,
    free_slots: std.ArrayListUnmanaged(u32) = .empty,
    live_count: usize = 0,

    /// Creates a Vulkan instance and a logical device.
    ///
    /// # Args
    /// - `allocator`: allocator for backend bookkeeping.
    /// - `loader_fn`: a `vkGetInstanceProcAddr` compatible function.
    /// - `description`: instance and device parameters.
    ///
    /// # Return
    /// An initialized backend owned by the caller.
    ///
    /// # Error
    /// - `error.OutOfHostMemory`: an allocation fails.
    /// - `error.InitializationFailed`: the instance cannot be
    ///   created.
    /// - `error.Unsupported`: no Vulkan 1.3 device with dynamic
    ///   rendering and a graphics queue is available.
    ///
    /// # Note
    /// The backend requires Vulkan 1.3 with dynamic rendering. The
    /// caller must enable the platform surface extensions it uses in
    /// `description.enabled_extension`.
    ///
    /// Call `deinit` only after every RHI resource has been
    /// destroyed.
    pub fn init(
        allocator: Allocator,
        loader_fn: anytype,
        description: VulkanDesc,
    ) !*Vulkan {
        log.debug("Creating Vulkan backend", .{});
        errdefer log.warn("Vulkan backend creation failed", .{});

        if (description.extension_count != 0 and
            description.enabled_extension == null)
        {
            return error.InvalidDescription;
        }
        if (description.api_version.major < 1 or
            (description.api_version.major == 1 and
                description.api_version.minor < 3))
        {
            log.warn(
                "Vulkan backend requires API 1.3 or newer",
                .{},
            );
            return error.Unsupported;
        }

        const self = try allocator.create(Vulkan);
        self.* = .{
            .allocator = allocator,
            .vk_allocator = description.allocator,
        };
        errdefer allocator.destroy(self);

        const vkb = vk.BaseWrapper.load(loader_fn);
        const app_name: ?[*:0]const u8 = if (description.application_name) |name|
            name.ptr
        else
            null;
        const engine_name: ?[*:0]const u8 = if (description.engine_name) |name|
            name.ptr
        else
            null;
        self.instance = try vkb.createInstance(&.{
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = app_name,
                .application_version = @bitCast(
                    description.application_version,
                ),
                .p_engine_name = engine_name,
                .engine_version = @bitCast(description.engine_version),
                .api_version = @bitCast(description.api_version),
            },
            .enabled_extension_count = description.extension_count,
            .pp_enabled_extension_names = description.enabled_extension,
        }, self.vk_allocator);
        errdefer self.vki.destroyInstance(self.vk_allocator);

        self.vki_wrapper = vk.InstanceWrapper.load(
            self.instance,
            loader_fn,
        );
        self.vki = vk.InstanceProxy.init(
            self.instance,
            &self.vki_wrapper,
        );

        log.info("  application_version: {f}", .{
            description.application_version,
        });
        log.info("       engine_version: {f}", .{
            description.engine_version,
        });
        log.info("          api_version: {f}", .{
            description.api_version,
        });

        try self.selectPhysicalDevice(description.api_version);
        try self.createDevice();

        self.command_pool = try self.vkd.createCommandPool(&.{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = self.queue_family_index,
        }, self.vk_allocator);
        errdefer self.vkd.destroyCommandPool(
            self.command_pool,
            self.vk_allocator,
        );

        self.descriptor_pool = try self.vkd.createDescriptorPool(&.{
            .flags = .{ .free_descriptor_set = true },
            .max_sets = 1024,
            .pool_size_count = descriptor_pool_sizes.len,
            .p_pool_sizes = &descriptor_pool_sizes,
        }, self.vk_allocator);
        errdefer self.vkd.destroyDescriptorPool(
            self.descriptor_pool,
            self.vk_allocator,
        );

        log.info("    device_name: {s}", .{
            std.mem.sliceTo(&self.properties.device_name, 0),
        });
        log.info("   device_type: {s}", .{
            @tagName(self.properties.device_type),
        });
        log.debug("Vulkan backend has been created", .{});
        return self;
    }

    /// Destroys the backend.
    ///
    /// # Note
    /// Every RHI resource must be destroyed before this call. Live
    /// resources are reported as warnings because the backend cannot
    /// destroy them safely after the owning tables are freed.
    pub fn deinit(self: *Vulkan) void {
        log.debug("Destroying Vulkan backend", .{});
        if (self.live_count != 0) {
            log.err(
                "Vulkan backend destroyed with {d} live resource(s)",
                .{self.live_count},
            );
            for (self.slots.items) |slot| {
                if (slot) |value| self.releaseHostData(&value);
            }
        }

        self.vkd.deviceWaitIdle() catch |err| {
            log.warn("deviceWaitIdle failed: {}", .{err});
        };

        if (self.descriptor_pool != .null) {
            self.vkd.destroyDescriptorPool(
                self.descriptor_pool,
                self.vk_allocator,
            );
        }
        if (self.command_pool != .null) {
            self.vkd.destroyCommandPool(
                self.command_pool,
                self.vk_allocator,
            );
        }

        self.vkd.destroyDevice(self.vk_allocator);
        self.vki.destroyInstance(self.vk_allocator);

        self.slots.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
        self.allocator.destroy(self);
        log.debug("Vulkan backend has been destroyed", .{});
    }

    /// Returns the RHI device interface of this backend.
    ///
    /// # Return
    /// A device whose lifetime is tied to `self`.
    pub fn asDevice(self: *Vulkan) Device {
        return .{
            .vptr = self,
            .vtable = &device_vtable,
        };
    }

    fn selectPhysicalDevice(
        self: *Vulkan,
        api_version: rhi.Version,
    ) !void {
        const devices = try self.vki.enumeratePhysicalDevicesAlloc(
            self.allocator,
        );
        defer self.allocator.free(devices);
        if (devices.len == 0) return error.Unsupported;

        const required_version: u32 = @bitCast(rhi.Version.make(
            api_version.variant,
            1,
            3,
            0,
        ));

        for (devices) |physical_device| {
            const properties = self.vki.getPhysicalDeviceProperties(
                physical_device,
            );
            if (properties.api_version < required_version) continue;

            var features13 = vk.PhysicalDeviceVulkan13Features{};
            var features2 = vk.PhysicalDeviceFeatures2{
                .features = .{},
                .p_next = @ptrCast(&features13),
            };
            self.vki.getPhysicalDeviceFeatures2(
                physical_device,
                &features2,
            );
            if (features13.dynamic_rendering == .false) continue;

            const families = try self.vki
                .getPhysicalDeviceQueueFamilyPropertiesAlloc(
                physical_device,
                self.allocator,
            );
            defer self.allocator.free(families);

            for (families, 0..) |family, index| {
                if (!family.queue_flags.graphics) continue;
                if (family.queue_count == 0) continue;

                self.physical_device = physical_device;
                self.properties = properties;
                self.queue_family_index = @intCast(index);
                self.memory_properties = self.vki
                    .getPhysicalDeviceMemoryProperties(physical_device);
                try self.detectDeviceExtensions();
                return;
            }
        }

        return error.Unsupported;
    }

    fn detectDeviceExtensions(self: *Vulkan) !void {
        const extensions = try self.vki
            .enumerateDeviceExtensionPropertiesAlloc(
            self.physical_device,
            null,
            self.allocator,
        );
        defer self.allocator.free(extensions);

        self.supports_swapchain = false;
        for (extensions) |extension| {
            const name = std.mem.sliceTo(
                &extension.extension_name,
                0,
            );
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) {
                self.supports_swapchain = true;
            }
        }
        if (!self.supports_swapchain) {
            log.warn(
                "VK_KHR_swapchain is unavailable; swapchain creation will fail",
                .{},
            );
        }
    }

    fn createDevice(self: *Vulkan) !void {
        const priorities = [_]f32{1.0};
        const queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = self.queue_family_index,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&priorities),
        };

        var features13 = vk.PhysicalDeviceVulkan13Features{
            .dynamic_rendering = .true,
        };
        const device_extensions = [_][*:0]const u8{
            "VK_KHR_swapchain",
        };

        const create_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features13),
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = if (self.supports_swapchain)
                device_extensions.len
            else
                0,
            .pp_enabled_extension_names = if (self.supports_swapchain)
                &device_extensions
            else
                null,
        };

        self.device = try self.vki.createDevice(
            self.physical_device,
            &create_info,
            self.vk_allocator,
        );
        errdefer self.vkd.destroyDevice(self.vk_allocator);

        self.vkd_wrapper = vk.DeviceWrapper.load(
            self.device,
            self.vki_wrapper.dispatch.vkGetDeviceProcAddr.?,
        );
        self.vkd = vk.DeviceProxy.init(
            self.device,
            &self.vkd_wrapper,
        );
        self.queue = self.vkd.getDeviceQueue(
            self.queue_family_index,
            0,
        );
    }

    fn lookup(
        self: *Vulkan,
        resource: Resource,
        tag: Resource.Tag,
    ) Error!*Slot {
        const index = resource.identifier.index;
        if (index >= self.slots.items.len) {
            log.warn("unknown resource index {d}", .{index});
            return error.InvalidResource;
        }
        const slot = if (self.slots.items[index]) |*value|
            value
        else {
            log.warn("destroyed resource index {d}", .{index});
            return error.InvalidResource;
        };
        if (slot.generation != resource.identifier.generation) {
            log.warn("stale resource index {d}", .{index});
            return error.InvalidResource;
        }
        if (slot.tag != tag) {
            log.warn(
                "expected {s}, got {s}",
                .{ @tagName(tag), @tagName(slot.tag) },
            );
            return error.InvalidResource;
        }
        return slot;
    }

    fn newSlot(
        self: *Vulkan,
        tag: Resource.Tag,
        handle: Handle,
    ) Error!Resource {
        var index: u32 = undefined;
        if (self.free_slots.pop()) |free_index| {
            index = free_index;
        } else {
            index = @intCast(self.slots.items.len);
            self.slots.append(
                self.allocator,
                null,
            ) catch return error.OutOfHostMemory;
            self.generations.append(
                self.allocator,
                0,
            ) catch {
                _ = self.slots.pop();
                return error.OutOfHostMemory;
            };
        }

        const next_generation = self.generations.items[index] +% 1;
        const generation = if (next_generation == 0) 1 else next_generation;
        self.generations.items[index] = generation;
        self.slots.items[index] = .{
            .generation = generation,
            .tag = tag,
            .handle = handle,
        };
        self.live_count += 1;

        return .{
            .identifier = .{
                .generation = generation,
                .index = index,
            },
            .tag = tag,
        };
    }

    fn releaseSlot(self: *Vulkan, resource: Resource) void {
        const index = resource.identifier.index;
        if (index >= self.slots.items.len) return;
        if (self.slots.items[index] == null) return;
        self.slots.items[index] = null;
        self.live_count -= 1;
        self.free_slots.append(
            self.allocator,
            index,
        ) catch |err| log.warn(
            "cannot recycle resource slot {d}: {}",
            .{ index, err },
        );
    }

    fn releaseHostData(self: *Vulkan, slot: *const Slot) void {
        switch (slot.handle) {
            .swapchain => |value| {
                self.allocator.free(value.images);
                self.allocator.free(value.views);
            },
            .shader => |value| self.allocator.free(value.entry_point),
            .descriptor_set_layout => |value| {
                self.allocator.free(value.bindings);
            },
            else => {},
        }
    }

    fn createResource(
        self: *Vulkan,
        description: Resource.Description,
        ret_addr: usize,
    ) Error!Resource {
        log.debug(
            "create {s} (ret 0x{x})",
            .{ @tagName(description), ret_addr },
        );
        return switch (description) {
            .surface => |value| self.createSurface(value, ret_addr),
            .swapchain => |value| self.createSwapchain(value, ret_addr),
            .buffer => |value| self.createBuffer(value, ret_addr),
            .texture => |value| self.createTexture(value, ret_addr),
            .texture_view => |value| self.createTextureView(
                value,
                ret_addr,
            ),
            .sampler => |value| self.createSampler(value, ret_addr),
            .shader => |value| self.createShader(value, ret_addr),
            .descriptor_set_layout => |value| self.createDescriptorSetLayout(
                value,
                ret_addr,
            ),
            .pipeline_layout => |value| self.createPipelineLayout(
                value,
                ret_addr,
            ),
            .descriptor_set => |value| self.createDescriptorSet(
                value,
                ret_addr,
            ),
            .pipeline => |value| self.createPipeline(value, ret_addr),
            .command_buffer => |value| self.createCommandBuffer(
                value,
                ret_addr,
            ),
            .fence => |value| self.createFence(value, ret_addr),
            .semaphore => |value| self.createSemaphore(value, ret_addr),
        };
    }

    fn createSurface(
        self: *Vulkan,
        description: types.SurfaceDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const surface = switch (description.native) {
            .win32 => |value| blk: {
                if (self.vki_wrapper.dispatch.vkCreateWin32SurfaceKHR ==
                    null)
                {
                    log.warn(
                        "VK_KHR_win32_surface is not enabled",
                        .{},
                    );
                    return error.Unsupported;
                }
                break :blk self.vki.createWin32SurfaceKHR(&.{
                    .hinstance = @ptrFromInt(value.hinstance),
                    .hwnd = @ptrFromInt(value.hwnd),
                }, self.vk_allocator) catch |err| {
                    return mapError(err);
                };
            },
            .xlib => |value| blk: {
                if (self.vki_wrapper.dispatch.vkCreateXlibSurfaceKHR ==
                    null)
                {
                    log.warn(
                        "VK_KHR_xlib_surface is not enabled",
                        .{},
                    );
                    return error.Unsupported;
                }
                break :blk self.vki.createXlibSurfaceKHR(&.{
                    .dpy = @ptrFromInt(value.display),
                    .window = @intCast(value.window),
                }, self.vk_allocator) catch |err| {
                    return mapError(err);
                };
            },
            .wayland => |value| blk: {
                if (self.vki_wrapper.dispatch
                    .vkCreateWaylandSurfaceKHR == null)
                {
                    log.warn(
                        "VK_KHR_wayland_surface is not enabled",
                        .{},
                    );
                    return error.Unsupported;
                }
                break :blk self.vki.createWaylandSurfaceKHR(&.{
                    .display = @ptrFromInt(value.display),
                    .surface = @ptrFromInt(value.surface),
                }, self.vk_allocator) catch |err| {
                    return mapError(err);
                };
            },
            .headless => {
                log.warn(
                    "Vulkan does not support headless RHI surfaces",
                    .{},
                );
                return error.Unsupported;
            },
        };
        errdefer self.vki.destroySurfaceKHR(
            surface,
            self.vk_allocator,
        );

        return self.newSlot(.surface, .{ .surface = surface });
    }

    fn createSwapchain(
        self: *Vulkan,
        description: types.SwapchainDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        if (!self.supports_swapchain) return error.Unsupported;
        const surface_slot = try self.lookup(
            description.surface,
            .surface,
        );
        const surface = surface_slot.handle.surface;

        const support = self.vki.getPhysicalDeviceSurfaceSupportKHR(
            self.physical_device,
            self.queue_family_index,
            surface,
        ) catch |err| return mapError(err);
        if (support == .false) {
            log.warn(
                "selected queue family does not support presentation",
                .{},
            );
            return error.Unsupported;
        }

        const caps = self.vki
            .getPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device,
            surface,
        ) catch |err| return mapError(err);

        const formats = self.vki
            .getPhysicalDeviceSurfaceFormatsAllocKHR(
            self.physical_device,
            surface,
            self.allocator,
        ) catch |err| return mapError(err);
        defer self.allocator.free(formats);

        const wanted_format = toVkFormat(description.format) orelse
            return error.Unsupported;
        var chosen_format: ?vk.SurfaceFormatKHR = null;
        for (formats) |format| {
            if (format.format != wanted_format) continue;
            if (chosen_format == null or
                format.color_space == .srgb_nonlinear_khr)
            {
                chosen_format = format;
                if (format.color_space == .srgb_nonlinear_khr) break;
            }
        }
        const surface_format = chosen_format orelse {
            log.warn(
                "surface does not support format {s}",
                .{@tagName(description.format)},
            );
            return error.Unsupported;
        };

        var present_mode = toVkPresentMode(description.present_mode);
        const modes = self.vki
            .getPhysicalDeviceSurfacePresentModesAllocKHR(
            self.physical_device,
            surface,
            self.allocator,
        ) catch |err| return mapError(err);
        defer self.allocator.free(modes);
        var present_supported = false;
        for (modes) |mode| {
            if (mode == present_mode) present_supported = true;
        }
        if (!present_supported) {
            present_mode = .fifo_khr;
        }

        var extent: vk.Extent2D = .{
            .width = description.width,
            .height = description.height,
        };
        if (caps.current_extent.width != 0) {
            extent = caps.current_extent;
        } else {
            if (extent.width == 0) extent.width = caps.min_image_extent.width;
            if (extent.height == 0) {
                extent.height = caps.min_image_extent.height;
            }
        }
        extent.width = std.math.clamp(
            extent.width,
            caps.min_image_extent.width,
            caps.max_image_extent.width,
        );
        extent.height = std.math.clamp(
            extent.height,
            caps.min_image_extent.height,
            caps.max_image_extent.height,
        );

        var image_count = @max(
            caps.min_image_count,
            description.image_count,
        );
        if (caps.max_image_count != 0) {
            image_count = @min(image_count, caps.max_image_count);
        }
        image_count = @max(image_count, 1);

        var composite: vk.CompositeAlphaFlagsKHR = .{};
        if (caps.supported_composite_alpha.opaque_khr) {
            composite.opaque_khr = true;
        } else if (caps.supported_composite_alpha.pre_multiplied_khr) {
            composite.pre_multiplied_khr = true;
        } else if (caps.supported_composite_alpha.post_multiplied_khr) {
            composite.post_multiplied_khr = true;
        } else {
            composite.inherit_khr = true;
        }

        const handle = self.vkd.createSwapchainKHR(&.{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = composite,
            .present_mode = present_mode,
            .clipped = .true,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroySwapchainKHR(
            handle,
            self.vk_allocator,
        );

        const native_images = self.vkd
            .getSwapchainImagesAllocKHR(
            handle,
            self.allocator,
        ) catch |err| return mapError(err);
        defer self.allocator.free(native_images);
        if (native_images.len == 0) return error.Unknown;

        const images = self.allocator.alloc(
            Resource,
            native_images.len,
        ) catch return error.OutOfHostMemory;
        errdefer self.allocator.free(images);
        const views = self.allocator.alloc(
            Resource,
            native_images.len,
        ) catch return error.OutOfHostMemory;
        errdefer self.allocator.free(views);

        var created_images: usize = 0;
        var created_views: usize = 0;
        errdefer {
            var i = created_views;
            while (i > 0) {
                i -= 1;
                self.destroyResource(views[i]);
            }
            i = created_images;
            while (i > 0) {
                i -= 1;
                self.destroyResource(images[i]);
            }
        }

        const rhi_format = fromVkFormat(surface_format.format);
        for (native_images, 0..) |image, index| {
            const properties: types.TextureProperties = .{
                .type = .@"2d",
                .format = rhi_format,
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
                .mip_levels = 1,
                .array_layers = 1,
                .samples = 1,
                .usage = .{
                    .color_attachment = true,
                    .transfer_src = true,
                },
            };
            images[index] = try self.newSlot(.texture, .{
                .texture = .{
                    .handle = image,
                    .memory = .null,
                    .owns_memory = false,
                    .properties = properties,
                    .layout = .undefined,
                },
            });
            created_images += 1;

            const view = self.vkd.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = surface_format.format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, self.vk_allocator) catch |err| return mapError(err);
            views[index] = try self.newSlot(.texture_view, .{
                .texture_view = .{
                    .handle = view,
                    .aspect = .color,
                },
            });
            created_views += 1;
        }

        const properties: types.SwapchainProperties = .{
            .width = extent.width,
            .height = extent.height,
            .format = rhi_format,
            .image_count = @intCast(native_images.len),
        };
        const resource = try self.newSlot(.swapchain, .{
            .swapchain = .{
                .handle = handle,
                .surface = description.surface,
                .properties = properties,
                .images = images,
                .views = views,
            },
        });
        return resource;
    }

    fn createBuffer(
        self: *Vulkan,
        description: types.BufferDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        if (description.initial_data) |data| {
            if (data.len > description.size) {
                return error.InvalidDescription;
            }
            if (!description.memory.host_visible and
                !description.usage.transfer_dst)
            {
                return error.InvalidDescription;
            }
        }
        if (description.size == 0) return error.InvalidDescription;

        const usage = toVkBufferUsage(description.usage);
        const handle = self.vkd.createBuffer(&.{
            .size = description.size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyBuffer(handle, self.vk_allocator);

        const requirements = self.vkd.getBufferMemoryRequirements(
            handle,
        );
        const memory_type = try self.findMemoryType(
            requirements.memory_type_bits,
            description.memory,
        );
        const actual = self.memory_properties.memory_types[memory_type]
            .property_flags;
        const memory = self.vkd.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.freeMemory(memory, self.vk_allocator);
        self.vkd.bindBufferMemory(
            handle,
            memory,
            0,
        ) catch |err| return mapError(err);

        const host_visible = actual.host_visible;
        const non_coherent = host_visible and !actual.host_coherent;

        if (description.initial_data) |data| {
            if (host_visible) {
                const mapped = self.vkd.mapMemory(
                    memory,
                    0,
                    vk.WHOLE_SIZE,
                    .{},
                ) catch |err| return mapError(err);
                const bytes: [*]u8 = @ptrCast(mapped orelse
                    return error.OutOfHostMemory);
                @memcpy(bytes[0..data.len], data);
                if (non_coherent) {
                    self.vkd.flushMappedMemoryRanges(&.{
                        .{
                            .memory = memory,
                            .offset = 0,
                            .size = vk.WHOLE_SIZE,
                        },
                    }) catch |err| {
                        self.vkd.unmapMemory(memory);
                        return mapError(err);
                    };
                }
                self.vkd.unmapMemory(memory);
            } else {
                try self.uploadToBuffer(handle, description.size, data);
            }
        }

        return self.newSlot(.buffer, .{
            .buffer = .{
                .handle = handle,
                .memory = memory,
                .size = description.size,
                .hints = description.memory,
                .host_visible = host_visible,
                .non_coherent = non_coherent,
            },
        });
    }

    fn createTexture(
        self: *Vulkan,
        description: types.TextureDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const format = toVkFormat(description.format) orelse
            return error.Unsupported;
        if (description.width == 0 or description.height == 0 or
            description.depth == 0)
        {
            return error.InvalidDescription;
        }
        if (description.mip_levels == 0 or
            description.array_layers == 0)
        {
            return error.InvalidDescription;
        }
        if (description.initial_data != null and
            !description.usage.transfer_dst)
        {
            return error.InvalidDescription;
        }
        const samples = toVkSampleCount(description.samples) orelse
            return error.Unsupported;

        const handle = self.vkd.createImage(&.{
            .image_type = switch (description.type) {
                .@"1d" => .@"1d",
                .@"2d" => .@"2d",
                .@"3d" => .@"3d",
            },
            .format = format,
            .extent = .{
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
            },
            .mip_levels = description.mip_levels,
            .array_layers = description.array_layers,
            .samples = samples,
            .tiling = .optimal,
            .usage = toVkImageUsage(description.usage),
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyImage(handle, self.vk_allocator);

        const requirements = self.vkd.getImageMemoryRequirements(handle);
        const memory_type = try self.findMemoryType(
            requirements.memory_type_bits,
            .{},
        );
        const memory = self.vkd.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.freeMemory(memory, self.vk_allocator);
        self.vkd.bindImageMemory(
            handle,
            memory,
            0,
        ) catch |err| return mapError(err);

        var layout: types.TextureLayout = .undefined;
        if (description.initial_data) |data| {
            layout = try self.uploadToTexture(
                handle,
                description,
                data,
            );
        }

        const properties: types.TextureProperties = .{
            .type = description.type,
            .format = description.format,
            .width = description.width,
            .height = description.height,
            .depth = description.depth,
            .mip_levels = description.mip_levels,
            .array_layers = description.array_layers,
            .samples = description.samples,
            .usage = description.usage,
        };

        return self.newSlot(.texture, .{
            .texture = .{
                .handle = handle,
                .memory = memory,
                .owns_memory = true,
                .properties = properties,
                .layout = layout,
            },
        });
    }

    fn createTextureView(
        self: *Vulkan,
        description: types.TextureViewDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const texture_slot = try self.lookup(
            description.texture,
            .texture,
        );
        const texture = texture_slot.handle.texture;
        if (description.base_mip >= texture.properties.mip_levels or
            description.base_layer >= texture.properties.array_layers)
        {
            return error.InvalidDescription;
        }
        const mip_count = if (description.mip_count == 0)
            texture.properties.mip_levels - description.base_mip
        else
            description.mip_count;
        const layer_count = if (description.layer_count == 0)
            texture.properties.array_layers - description.base_layer
        else
            description.layer_count;
        if (description.base_mip >= texture.properties.mip_levels or
            mip_count == 0 or
            description.base_mip + mip_count >
                texture.properties.mip_levels)
        {
            return error.InvalidDescription;
        }
        if (description.base_layer >= texture.properties.array_layers or
            layer_count == 0 or
            description.base_layer + layer_count >
                texture.properties.array_layers)
        {
            return error.InvalidDescription;
        }

        const format = toVkFormat(
            description.format orelse texture.properties.format,
        ) orelse return error.Unsupported;
        const view_type = toVkImageViewType(
            description.type orelse texture.properties.type,
        );
        const handle = self.vkd.createImageView(&.{
            .image = texture.handle,
            .view_type = view_type,
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = toVkAspect(
                    description.aspect orelse
                        texture.properties.format.aspect(),
                ),
                .base_mip_level = description.base_mip,
                .level_count = mip_count,
                .base_array_layer = description.base_layer,
                .layer_count = layer_count,
            },
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyImageView(handle, self.vk_allocator);

        return self.newSlot(.texture_view, .{
            .texture_view = .{
                .handle = handle,
                .aspect = description.aspect orelse
                    texture.properties.format.aspect(),
            },
        });
    }

    fn createSampler(
        self: *Vulkan,
        description: types.SamplerDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const anisotropy = description.anisotropy != 0;
        const handle = self.vkd.createSampler(&.{
            .mag_filter = toVkFilter(description.mag_filter),
            .min_filter = toVkFilter(description.min_filter),
            .mipmap_mode = switch (description.mipmap) {
                .nearest => .nearest,
                .linear => .linear,
            },
            .address_mode_u = toVkAddressMode(description.address_u),
            .address_mode_v = toVkAddressMode(description.address_v),
            .address_mode_w = toVkAddressMode(description.address_w),
            .mip_lod_bias = 0,
            .anisotropy_enable = if (anisotropy) .true else .false,
            .max_anisotropy = if (anisotropy)
                @floatFromInt(description.anisotropy)
            else
                1,
            .compare_enable = if (description.compare == null)
                .false
            else
                .true,
            .compare_op = if (description.compare) |compare|
                toVkCompareOp(compare)
            else
                .always,
            .min_lod = description.lod_min,
            .max_lod = description.lod_max,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = .false,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroySampler(handle, self.vk_allocator);

        return self.newSlot(.sampler, .{ .sampler = handle });
    }

    fn createShader(
        self: *Vulkan,
        description: types.ShaderDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        if (description.code.len == 0) {
            return error.InvalidDescription;
        }
        const handle = self.vkd.createShaderModule(&.{
            .code_size = description.code.len * @sizeOf(u32),
            .p_code = description.code.ptr,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyShaderModule(
            handle,
            self.vk_allocator,
        );

        const entry_point = self.allocator.dupeSentinel(
            u8,
            description.entry_point,
            0,
        ) catch return error.OutOfHostMemory;
        errdefer self.allocator.free(entry_point);

        return self.newSlot(.shader, .{
            .shader = .{
                .module = handle,
                .stage = description.stage,
                .entry_point = entry_point,
            },
        });
    }

    fn createDescriptorSetLayout(
        self: *Vulkan,
        description: types.DescriptorSetLayoutDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        if (description.bindings.len == 0) {
            return error.InvalidDescription;
        }
        const bindings = self.allocator.alloc(
            vk.DescriptorSetLayoutBinding,
            description.bindings.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(bindings);
        for (description.bindings, 0..) |binding, index| {
            bindings[index] = .{
                .binding = binding.binding,
                .descriptor_type = toVkDescriptorType(binding.kind),
                .descriptor_count = binding.count,
                .stage_flags = toVkShaderStages(binding.stages),
            };
        }

        const handle = self.vkd.createDescriptorSetLayout(&.{
            .binding_count = @intCast(bindings.len),
            .p_bindings = bindings.ptr,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyDescriptorSetLayout(
            handle,
            self.vk_allocator,
        );

        const stored = self.allocator.dupe(
            types.DescriptorSetLayoutDescription.DescriptorBinding,
            description.bindings,
        ) catch return error.OutOfHostMemory;
        errdefer self.allocator.free(stored);

        return self.newSlot(.descriptor_set_layout, .{
            .descriptor_set_layout = .{
                .handle = handle,
                .bindings = stored,
            },
        });
    }

    fn createPipelineLayout(
        self: *Vulkan,
        description: types.PipelineLayoutDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const set_layouts = self.allocator.alloc(
            vk.DescriptorSetLayout,
            description.descriptor_sets.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(set_layouts);
        for (description.descriptor_sets, 0..) |set, index| {
            const slot = try self.lookup(set, .descriptor_set_layout);
            set_layouts[index] = slot.handle.descriptor_set_layout.handle;
        }

        const ranges = self.allocator.alloc(
            vk.PushConstantRange,
            description.push_constants.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(ranges);
        for (description.push_constants, 0..) |range, index| {
            ranges[index] = .{
                .stage_flags = toVkShaderStages(range.stages),
                .offset = range.offset,
                .size = range.size,
            };
        }

        const handle = self.vkd.createPipelineLayout(&.{
            .set_layout_count = @intCast(set_layouts.len),
            .p_set_layouts = if (set_layouts.len == 0)
                null
            else
                set_layouts.ptr,
            .push_constant_range_count = @intCast(ranges.len),
            .p_push_constant_ranges = if (ranges.len == 0)
                null
            else
                ranges.ptr,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyPipelineLayout(
            handle,
            self.vk_allocator,
        );

        return self.newSlot(.pipeline_layout, .{
            .pipeline_layout = handle,
        });
    }

    fn createDescriptorSet(
        self: *Vulkan,
        description: types.DescriptorSetDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const layout = try self.lookup(
            description.layout,
            .descriptor_set_layout,
        );
        var set: vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&layout.handle.descriptor_set_layout.handle),
        }, @ptrCast(&set)) catch |err| return mapError(err);
        errdefer self.vkd.freeDescriptorSets(
            self.descriptor_pool,
            &.{set},
        ) catch {};

        return self.newSlot(.descriptor_set, .{
            .descriptor_set = .{
                .handle = set,
                .layout = description.layout,
            },
        });
    }

    fn createPipeline(
        self: *Vulkan,
        description: types.PipelineDescription,
        ret_addr: usize,
    ) Error!Resource {
        return switch (description) {
            .graphics => |value| self.createGraphicsPipeline(
                value,
                ret_addr,
            ),
            .compute => |value| self.createComputePipeline(
                value,
                ret_addr,
            ),
        };
    }

    fn createGraphicsPipeline(
        self: *Vulkan,
        description: types.GraphicsPipelineDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const layout = try self.lookup(
            description.layout,
            .pipeline_layout,
        );
        const vertex = try self.lookup(description.vertex, .shader);
        if (vertex.handle.shader.stage != .vertex) {
            return error.InvalidDescription;
        }

        var stage_infos: [2]vk.PipelineShaderStageCreateInfo = undefined;
        stage_infos[0] = .{
            .stage = .{ .vertex = true },
            .module = vertex.handle.shader.module,
            .p_name = vertex.handle.shader.entry_point.ptr,
        };
        var stage_count: u32 = 1;
        if (description.fragment) |fragment_resource| {
            const fragment = try self.lookup(
                fragment_resource,
                .shader,
            );
            if (fragment.handle.shader.stage != .fragment) {
                return error.InvalidDescription;
            }
            stage_infos[1] = .{
                .stage = .{ .fragment = true },
                .module = fragment.handle.shader.module,
                .p_name = fragment.handle.shader.entry_point.ptr,
            };
            stage_count = 2;
        }

        const vertex_bindings = self.allocator.alloc(
            vk.VertexInputBindingDescription,
            description.vertex_layout.bindings.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(vertex_bindings);
        for (description.vertex_layout.bindings, 0..) |binding, index| {
            vertex_bindings[index] = .{
                .binding = binding.binding,
                .stride = binding.stride,
                .input_rate = switch (binding.rate) {
                    .vertex => .vertex,
                    .instance => .instance,
                },
            };
        }

        const vertex_attributes = self.allocator.alloc(
            vk.VertexInputAttributeDescription,
            description.vertex_layout.attributes.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(vertex_attributes);
        for (description.vertex_layout.attributes, 0..) |attribute, index| {
            vertex_attributes[index] = .{
                .location = attribute.location,
                .binding = attribute.binding,
                .format = toVkFormat(attribute.format) orelse
                    return error.Unsupported,
                .offset = attribute.offset,
            };
        }

        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = @intCast(
                vertex_bindings.len,
            ),
            .p_vertex_binding_descriptions = if (vertex_bindings.len == 0)
                null
            else
                vertex_bindings.ptr,
            .vertex_attribute_description_count = @intCast(
                vertex_attributes.len,
            ),
            .p_vertex_attribute_descriptions = if (vertex_attributes.len == 0)
                null
            else
                vertex_attributes.ptr,
        };
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = toVkTopology(description.topology),
            .primitive_restart_enable = .false,
        };
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };

        var cull: vk.CullModeFlags = .{};
        switch (description.cull) {
            .none => {},
            .front => cull.front = true,
            .back => cull.back = true,
            .front_and_back => {
                cull.front = true;
                cull.back = true;
            },
        }
        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = cull,
            .front_face = switch (description.front_face) {
                .clockwise => .clockwise,
                .counter_clockwise => .counter_clockwise,
            },
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = toVkSampleCount(
                description.samples,
            ) orelse return error.Unsupported,
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        const depth = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = if (description.depth.enable and
                description.depth_format != null)
                .true
            else
                .false,
            .depth_write_enable = if (description.depth.write and
                description.depth_format != null)
                .true
            else
                .false,
            .depth_compare_op = toVkCompareOp(
                description.depth.compare,
            ),
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = defaultStencilState(),
            .back = defaultStencilState(),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };

        const blend_attachments = self.allocator.alloc(
            vk.PipelineColorBlendAttachmentState,
            description.color_formats.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(blend_attachments);
        for (blend_attachments) |*attachment| {
            attachment.* = .{
                .blend_enable = if (description.blend.enabled)
                    .true
                else
                    .false,
                .src_color_blend_factor = toVkBlendFactor(
                    description.blend.src_color,
                ),
                .dst_color_blend_factor = toVkBlendFactor(
                    description.blend.dst_color,
                ),
                .color_blend_op = toVkBlendOp(
                    description.blend.op_color,
                ),
                .src_alpha_blend_factor = toVkBlendFactor(
                    description.blend.src_alpha,
                ),
                .dst_alpha_blend_factor = toVkBlendFactor(
                    description.blend.dst_alpha,
                ),
                .alpha_blend_op = toVkBlendOp(
                    description.blend.op_alpha,
                ),
                .color_write_mask = .{
                    .r = true,
                    .g = true,
                    .b = true,
                    .a = true,
                },
            };
        }

        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = @intCast(blend_attachments.len),
            .p_attachments = if (blend_attachments.len == 0)
                null
            else
                @ptrCast(blend_attachments.ptr),
            .blend_constants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
        };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = @ptrCast(&dynamic_states),
        };

        const color_formats = self.allocator.alloc(
            vk.Format,
            description.color_formats.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(color_formats);
        for (description.color_formats, 0..) |format, index| {
            color_formats[index] = toVkFormat(format) orelse
                return error.Unsupported;
        }

        const depth_format: vk.Format = if (description.depth_format) |format|
            toVkFormat(format) orelse return error.Unsupported
        else
            .undefined;
        const rendering_info = vk.PipelineRenderingCreateInfo{
            .view_mask = 0,
            .color_attachment_count = @intCast(color_formats.len),
            .p_color_attachment_formats = if (color_formats.len == 0)
                null
            else
                color_formats.ptr,
            .depth_attachment_format = depth_format,
            .stencil_attachment_format = if (depth_format ==
                .d24_unorm_s8_uint)
                depth_format
            else
                .undefined,
        };

        const create_info = vk.GraphicsPipelineCreateInfo{
            .p_next = @ptrCast(&rendering_info),
            .stage_count = stage_count,
            .p_stages = @ptrCast(&stage_infos),
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = &depth,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
            .layout = layout.handle.pipeline_layout,
            .subpass = 0,
            .base_pipeline_index = -1,
        };
        var pipeline: vk.Pipeline = undefined;
        const result = self.vkd.createGraphicsPipelines(
            .null,
            &.{create_info},
            self.vk_allocator,
            @ptrCast(&pipeline),
        ) catch |err| return mapError(err);
        if (result != .success) return error.Unknown;
        errdefer self.vkd.destroyPipeline(pipeline, self.vk_allocator);

        return self.newSlot(.pipeline, .{
            .pipeline = .{
                .handle = pipeline,
                .bind_point = .graphics,
            },
        });
    }

    fn createComputePipeline(
        self: *Vulkan,
        description: types.ComputePipelineDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const layout = try self.lookup(
            description.layout,
            .pipeline_layout,
        );
        const shader = try self.lookup(description.shader, .shader);
        if (shader.handle.shader.stage != .compute) {
            return error.InvalidDescription;
        }
        const stage = vk.PipelineShaderStageCreateInfo{
            .stage = .{ .compute = true },
            .module = shader.handle.shader.module,
            .p_name = shader.handle.shader.entry_point.ptr,
        };
        const create_info = vk.ComputePipelineCreateInfo{
            .stage = stage,
            .layout = layout.handle.pipeline_layout,
            .base_pipeline_index = -1,
        };
        var pipeline: vk.Pipeline = undefined;
        const result = self.vkd.createComputePipelines(
            .null,
            &.{create_info},
            self.vk_allocator,
            @ptrCast(&pipeline),
        ) catch |err| return mapError(err);
        if (result != .success) return error.Unknown;
        errdefer self.vkd.destroyPipeline(pipeline, self.vk_allocator);

        return self.newSlot(.pipeline, .{
            .pipeline = .{
                .handle = pipeline,
                .bind_point = .compute,
            },
        });
    }

    fn createCommandBuffer(
        self: *Vulkan,
        description: types.CommandBufferDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        var handle: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = switch (description.level) {
                .primary => .primary,
                .secondary => .secondary,
            },
            .command_buffer_count = 1,
        }, @ptrCast(&handle)) catch |err| return mapError(err);
        errdefer self.vkd.freeCommandBuffers(
            self.command_pool,
            &.{handle},
        );

        return self.newSlot(.command_buffer, .{
            .command_buffer = .{
                .handle = handle,
                .level = description.level,
            },
        });
    }

    fn createFence(
        self: *Vulkan,
        description: types.FenceDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = ret_addr;
        const handle = self.vkd.createFence(&.{
            .flags = if (description.signaled)
                .{ .signaled = true }
            else
                .{},
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyFence(handle, self.vk_allocator);
        return self.newSlot(.fence, .{ .fence = handle });
    }

    fn createSemaphore(
        self: *Vulkan,
        description: types.SemaphoreDescription,
        ret_addr: usize,
    ) Error!Resource {
        _ = description;
        _ = ret_addr;
        const handle = self.vkd.createSemaphore(
            &.{},
            self.vk_allocator,
        ) catch |err| return mapError(err);
        errdefer self.vkd.destroySemaphore(handle, self.vk_allocator);
        return self.newSlot(.semaphore, .{ .semaphore = handle });
    }

    fn createBatch(
        self: *Vulkan,
        descriptions: []const Resource.Description,
        resources: []Resource,
        ret_addr: usize,
    ) Error!void {
        if (descriptions.len != resources.len) {
            return error.InvalidDescription;
        }
        var created: usize = 0;
        errdefer {
            while (created > 0) {
                created -= 1;
                self.destroyResource(resources[created]);
            }
        }
        for (descriptions, 0..) |description, index| {
            resources[index] = try self.createResource(
                description,
                ret_addr,
            );
            created += 1;
        }
    }

    fn destroyResource(self: *Vulkan, resource: Resource) void {
        const slot = self.lookup(resource, resource.tag) catch return;
        switch (slot.handle) {
            .surface => |handle| {
                self.vki.destroySurfaceKHR(handle, self.vk_allocator);
            },
            .swapchain => |value| {
                for (value.views) |view| {
                    self.destroyIfAlive(view);
                }
                for (value.images) |image| {
                    self.destroyIfAlive(image);
                }
                self.vkd.destroySwapchainKHR(
                    value.handle,
                    self.vk_allocator,
                );
                self.allocator.free(value.images);
                self.allocator.free(value.views);
            },
            .buffer => |value| {
                if (value.mapped != null) {
                    self.vkd.unmapMemory(value.memory);
                }
                self.vkd.destroyBuffer(value.handle, self.vk_allocator);
                self.vkd.freeMemory(value.memory, self.vk_allocator);
            },
            .texture => |value| {
                if (value.owns_memory) {
                    self.vkd.destroyImage(
                        value.handle,
                        self.vk_allocator,
                    );
                    self.vkd.freeMemory(
                        value.memory,
                        self.vk_allocator,
                    );
                }
            },
            .texture_view => |value| {
                self.vkd.destroyImageView(
                    value.handle,
                    self.vk_allocator,
                );
            },
            .sampler => |handle| {
                self.vkd.destroySampler(handle, self.vk_allocator);
            },
            .shader => |value| {
                self.vkd.destroyShaderModule(
                    value.module,
                    self.vk_allocator,
                );
                self.allocator.free(value.entry_point);
            },
            .descriptor_set_layout => |value| {
                self.vkd.destroyDescriptorSetLayout(
                    value.handle,
                    self.vk_allocator,
                );
                self.allocator.free(value.bindings);
            },
            .pipeline_layout => |handle| {
                self.vkd.destroyPipelineLayout(
                    handle,
                    self.vk_allocator,
                );
            },
            .descriptor_set => |handle| {
                self.vkd.freeDescriptorSets(
                    self.descriptor_pool,
                    &.{handle.handle},
                ) catch |err| {
                    log.warn("freeDescriptorSets failed: {}", .{err});
                };
            },
            .pipeline => |value| {
                self.vkd.destroyPipeline(
                    value.handle,
                    self.vk_allocator,
                );
            },
            .command_buffer => |value| {
                self.vkd.freeCommandBuffers(
                    self.command_pool,
                    &.{value.handle},
                );
            },
            .fence => |handle| {
                self.vkd.destroyFence(handle, self.vk_allocator);
            },
            .semaphore => |handle| {
                self.vkd.destroySemaphore(handle, self.vk_allocator);
            },
        }
        self.releaseSlot(resource);
    }

    fn destroyIfAlive(self: *Vulkan, resource: Resource) void {
        _ = self.lookup(resource, resource.tag) catch return;
        self.destroyResource(resource);
    }

    fn map(
        self: *Vulkan,
        resource: Resource,
        offset: u64,
        size: u64,
        ret_addr: usize,
    ) Error![]u8 {
        _ = ret_addr;
        const slot = try self.lookup(resource, .buffer);
        const buffer = &slot.handle.buffer;
        if (!buffer.host_visible) return error.Unsupported;
        if (buffer.mapped != null) return error.InvalidResource;
        if (offset > buffer.size or size > buffer.size - offset) {
            return error.InvalidDescription;
        }
        const mapped = self.vkd.mapMemory(
            buffer.memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ) catch |err| return mapError(err);
        const bytes: [*]u8 = @ptrCast(mapped orelse
            return error.OutOfHostMemory);
        if (buffer.non_coherent) {
            self.vkd.invalidateMappedMemoryRanges(&.{
                .{
                    .memory = buffer.memory,
                    .offset = 0,
                    .size = vk.WHOLE_SIZE,
                },
            }) catch |err| {
                self.vkd.unmapMemory(buffer.memory);
                return mapError(err);
            };
        }
        buffer.mapped = bytes;
        return bytes[@intCast(offset)..][0..@intCast(size)];
    }

    fn unmap(
        self: *Vulkan,
        resource: Resource,
        dirty: []const Device.Dirty,
        ret_addr: usize,
    ) void {
        _ = ret_addr;
        _ = dirty;
        const slot = self.lookup(resource, .buffer) catch return;
        const buffer = &slot.handle.buffer;
        if (buffer.mapped == null) {
            log.warn("unmap of an unmapped buffer", .{});
            return;
        }
        if (buffer.non_coherent) {
            self.vkd.flushMappedMemoryRanges(&.{
                .{
                    .memory = buffer.memory,
                    .offset = 0,
                    .size = vk.WHOLE_SIZE,
                },
            }) catch |err| log.warn(
                "flushMappedMemoryRanges failed: {}",
                .{err},
            );
        }
        self.vkd.unmapMemory(buffer.memory);
        buffer.mapped = null;
    }

    fn getQueue(self: *Vulkan, index: u32, ret_addr: usize) Error!Queue {
        _ = ret_addr;
        if (index != 0) return error.Unsupported;
        return .{
            .vptr = self,
            .vtable = &queue_vtable,
            .family_index = self.queue_family_index,
            .queue_index = 0,
        };
    }

    fn record(
        self: *Vulkan,
        resource: Resource,
        command: commands.Command,
        ret_addr: usize,
    ) Error!void {
        _ = ret_addr;
        const slot = try self.lookup(resource, .command_buffer);
        const command_buffer = &slot.handle.command_buffer;
        const handle = command_buffer.handle;

        switch (command) {
            .begin => {
                if (command_buffer.state == .recording) {
                    return error.InvalidResource;
                }
                self.vkd.resetCommandBuffer(
                    handle,
                    .{},
                ) catch |err| return mapError(err);
                self.vkd.beginCommandBuffer(handle, &.{}) catch |err|
                    return mapError(err);
                command_buffer.state = .recording;
            },
            .end => {
                if (command_buffer.state != .recording) {
                    return error.InvalidResource;
                }
                self.vkd.endCommandBuffer(handle) catch |err|
                    return mapError(err);
                command_buffer.state = .ended;
            },
            .begin_rendering => |value| {
                try self.requireRecording(command_buffer);
                const color_infos = self.allocator.alloc(
                    vk.RenderingAttachmentInfo,
                    value.color_attachments.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(color_infos);
                for (value.color_attachments, 0..) |attachment, index| {
                    const view = try self.lookup(
                        attachment.view,
                        .texture_view,
                    );
                    color_infos[index] = .{
                        .image_view = view.handle.texture_view.handle,
                        .image_layout = .color_attachment_optimal,
                        .resolve_mode = .{},
                        .resolve_image_layout = .undefined,
                        .load_op = toVkLoadOp(attachment.load),
                        .store_op = toVkStoreOp(attachment.store),
                        .clear_value = .{ .color = .{
                            .float_32 = .{
                                attachment.clear.r,
                                attachment.clear.g,
                                attachment.clear.b,
                                attachment.clear.a,
                            },
                        } },
                    };
                }
                var depth_info: vk.RenderingAttachmentInfo = undefined;
                var depth_pointer: ?*const vk.RenderingAttachmentInfo = null;
                if (value.depth_attachment) |attachment| {
                    const view = try self.lookup(
                        attachment.view,
                        .texture_view,
                    );
                    depth_info = .{
                        .image_view = view.handle.texture_view.handle,
                        .image_layout = .depth_stencil_attachment_optimal,
                        .resolve_mode = .{},
                        .resolve_image_layout = .undefined,
                        .load_op = toVkLoadOp(attachment.load),
                        .store_op = toVkStoreOp(attachment.store),
                        .clear_value = .{ .depth_stencil = .{
                            .depth = attachment.clear_depth,
                            .stencil = attachment.clear_stencil,
                        } },
                    };
                    depth_pointer = &depth_info;
                }

                self.vkd.cmdBeginRendering(handle, &.{
                    .render_area = .{
                        .offset = .{
                            .x = value.area.x,
                            .y = value.area.y,
                        },
                        .extent = .{
                            .width = value.area.width,
                            .height = value.area.height,
                        },
                    },
                    .layer_count = 1,
                    .view_mask = 0,
                    .color_attachment_count = @intCast(color_infos.len),
                    .p_color_attachments = if (color_infos.len == 0)
                        null
                    else
                        color_infos.ptr,
                    .p_depth_attachment = depth_pointer,
                });
            },
            .end_rendering => {
                try self.requireRecording(command_buffer);
                self.vkd.cmdEndRendering(handle);
            },
            .bind_pipeline => |value| {
                try self.requireRecording(command_buffer);
                const pipeline = try self.lookup(
                    value.pipeline,
                    .pipeline,
                );
                self.vkd.cmdBindPipeline(
                    handle,
                    switch (pipeline.handle.pipeline.bind_point) {
                        .graphics => .graphics,
                        .compute => .compute,
                    },
                    pipeline.handle.pipeline.handle,
                );
            },
            .bind_vertex_buffers => |value| {
                try self.requireRecording(command_buffer);
                const buffers = self.allocator.alloc(
                    vk.Buffer,
                    value.buffers.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(buffers);
                const offsets = self.allocator.alloc(
                    vk.DeviceSize,
                    value.buffers.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(offsets);
                for (value.buffers, 0..) |buffer, index| {
                    const buffer_slot = try self.lookup(
                        buffer,
                        .buffer,
                    );
                    buffers[index] = buffer_slot.handle.buffer.handle;
                    offsets[index] = if (value.offsets.len == 0)
                        0
                    else if (index < value.offsets.len)
                        value.offsets[index]
                    else
                        return error.InvalidDescription;
                }
                self.vkd.cmdBindVertexBuffers(
                    handle,
                    value.first_binding,
                    buffers,
                    offsets,
                );
            },
            .bind_index_buffer => |value| {
                try self.requireRecording(command_buffer);
                const buffer = try self.lookup(value.buffer, .buffer);
                self.vkd.cmdBindIndexBuffer(
                    handle,
                    buffer.handle.buffer.handle,
                    value.offset,
                    switch (value.type) {
                        .uint16 => .uint16,
                        .uint32 => .uint32,
                    },
                );
            },
            .bind_descriptor_sets => |value| {
                try self.requireRecording(command_buffer);
                const layout = try self.lookup(
                    value.layout,
                    .pipeline_layout,
                );
                const sets = self.allocator.alloc(
                    vk.DescriptorSet,
                    value.sets.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(sets);
                for (value.sets, 0..) |set, index| {
                    const set_slot = try self.lookup(
                        set,
                        .descriptor_set,
                    );
                    sets[index] = set_slot.handle.descriptor_set.handle;
                }
                self.vkd.cmdBindDescriptorSets(
                    handle,
                    switch (value.bind_point) {
                        .graphics => .graphics,
                        .compute => .compute,
                    },
                    layout.handle.pipeline_layout,
                    value.first_set,
                    sets,
                    if (value.dynamic_offsets.len == 0)
                        null
                    else
                        value.dynamic_offsets,
                );
            },
            .set_viewport => |value| {
                try self.requireRecording(command_buffer);
                const viewport = vk.Viewport{
                    .x = value.x,
                    .y = value.y,
                    .width = value.width,
                    .height = value.height,
                    .min_depth = value.min_depth,
                    .max_depth = value.max_depth,
                };
                self.vkd.cmdSetViewport(handle, 0, &.{viewport});
            },
            .set_scissor => |value| {
                try self.requireRecording(command_buffer);
                const scissor = vk.Rect2D{
                    .offset = .{ .x = value.x, .y = value.y },
                    .extent = .{
                        .width = value.width,
                        .height = value.height,
                    },
                };
                self.vkd.cmdSetScissor(handle, 0, &.{scissor});
            },
            .draw => |value| {
                try self.requireRecording(command_buffer);
                self.vkd.cmdDraw(
                    handle,
                    value.vertex_count,
                    value.instance_count,
                    value.first_vertex,
                    value.first_instance,
                );
            },
            .draw_indexed => |value| {
                try self.requireRecording(command_buffer);
                self.vkd.cmdDrawIndexed(
                    handle,
                    value.index_count,
                    value.instance_count,
                    value.first_index,
                    value.vertex_offset,
                    value.first_instance,
                );
            },
            .dispatch => |value| {
                try self.requireRecording(command_buffer);
                self.vkd.cmdDispatch(handle, value.x, value.y, value.z);
            },
            .copy_buffer => |value| {
                try self.requireRecording(command_buffer);
                const src = try self.lookup(value.src, .buffer);
                const dst = try self.lookup(value.dst, .buffer);
                const regions = self.allocator.alloc(
                    vk.BufferCopy,
                    value.regions.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(regions);
                for (value.regions, 0..) |region, index| {
                    regions[index] = .{
                        .src_offset = region.src_offset,
                        .dst_offset = region.dst_offset,
                        .size = region.size,
                    };
                }
                self.vkd.cmdCopyBuffer(
                    handle,
                    src.handle.buffer.handle,
                    dst.handle.buffer.handle,
                    regions,
                );
            },
            .copy_buffer_to_texture => |value| {
                try self.requireRecording(command_buffer);
                const buffer = try self.lookup(value.buffer, .buffer);
                const texture = try self.lookup(value.texture, .texture);
                const copy = makeBufferImageCopy(
                    value.buffer_offset,
                    value.row_pitch,
                    value.image_height,
                    value.region,
                    texture.handle.texture.properties,
                ) catch return error.InvalidDescription;
                self.vkd.cmdCopyBufferToImage(
                    handle,
                    buffer.handle.buffer.handle,
                    texture.handle.texture.handle,
                    .transfer_dst_optimal,
                    &.{copy},
                );
            },
            .copy_texture_to_buffer => |value| {
                try self.requireRecording(command_buffer);
                const buffer = try self.lookup(value.buffer, .buffer);
                const texture = try self.lookup(value.texture, .texture);
                const copy = makeBufferImageCopy(
                    value.buffer_offset,
                    value.row_pitch,
                    value.image_height,
                    value.region,
                    texture.handle.texture.properties,
                ) catch return error.InvalidDescription;
                self.vkd.cmdCopyImageToBuffer(
                    handle,
                    texture.handle.texture.handle,
                    .transfer_src_optimal,
                    buffer.handle.buffer.handle,
                    &.{copy},
                );
            },
            .copy_texture => |value| {
                try self.requireRecording(command_buffer);
                const src = try self.lookup(value.src, .texture);
                const dst = try self.lookup(value.dst, .texture);
                const regions = self.allocator.alloc(
                    vk.ImageCopy,
                    value.regions.len,
                ) catch return error.OutOfHostMemory;
                defer self.allocator.free(regions);
                for (value.regions, 0..) |region, index| {
                    regions[index] = .{
                        .src_subresource = .{
                            .aspect_mask = toVkAspect(
                                src.handle.texture.properties.format
                                    .aspect(),
                            ),
                            .mip_level = region.mip_level,
                            .base_array_layer = region.array_layer,
                            .layer_count = 1,
                        },
                        .src_offset = .{
                            .x = @intCast(region.offset.x),
                            .y = @intCast(region.offset.y),
                            .z = @intCast(region.offset.z),
                        },
                        .dst_subresource = .{
                            .aspect_mask = toVkAspect(
                                dst.handle.texture.properties.format
                                    .aspect(),
                            ),
                            .mip_level = region.mip_level,
                            .base_array_layer = region.array_layer,
                            .layer_count = 1,
                        },
                        .dst_offset = .{
                            .x = @intCast(region.offset.x),
                            .y = @intCast(region.offset.y),
                            .z = @intCast(region.offset.z),
                        },
                        .extent = .{
                            .width = region.extent.width,
                            .height = region.extent.height,
                            .depth = region.extent.depth,
                        },
                    };
                }
                self.vkd.cmdCopyImage(
                    handle,
                    src.handle.texture.handle,
                    .transfer_src_optimal,
                    dst.handle.texture.handle,
                    .transfer_dst_optimal,
                    regions,
                );
            },
            .barrier => |value| {
                try self.requireRecording(command_buffer);
                try self.recordBarrier(handle, value);
            },
            .push_constants => |value| {
                try self.requireRecording(command_buffer);
                const layout = try self.lookup(
                    value.layout,
                    .pipeline_layout,
                );
                self.vkd.cmdPushConstants(
                    handle,
                    layout.handle.pipeline_layout,
                    toVkShaderStages(value.stages),
                    value.offset,
                    @intCast(value.data.len),
                    value.data.ptr,
                );
            },
        }
    }

    fn requireRecording(
        self: *Vulkan,
        command_buffer: *CommandBufferState,
    ) Error!void {
        _ = self;
        if (command_buffer.state != .recording) {
            return error.InvalidResource;
        }
    }

    fn recordBarrier(
        self: *Vulkan,
        command_buffer: vk.CommandBuffer,
        value: commands.Barrier,
    ) Error!void {
        const slot = self.lookup(value.resource, value.resource.tag) catch {
            return error.InvalidResource;
        };
        switch (slot.handle) {
            .texture => |*texture| {
                const aspect = texture.properties.format.aspect();
                const barrier = vk.ImageMemoryBarrier{
                    .src_access_mask = toVkAccess(value.src_access),
                    .dst_access_mask = toVkAccess(value.dst_access),
                    .old_layout = toVkLayout(value.layout_before),
                    .new_layout = toVkLayout(value.layout_after),
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture.handle,
                    .subresource_range = .{
                        .aspect_mask = toVkAspect(aspect),
                        .base_mip_level = 0,
                        .level_count = vk.REMAINING_MIP_LEVELS,
                        .base_array_layer = 0,
                        .layer_count = vk.REMAINING_ARRAY_LAYERS,
                    },
                };
                self.vkd.cmdPipelineBarrier(
                    command_buffer,
                    toVkStage(value.src_stage),
                    toVkStage(value.dst_stage),
                    .{},
                    null,
                    null,
                    &.{barrier},
                );
                texture.layout = value.layout_after;
            },
            .buffer => |texture_buffer| {
                const barrier = vk.BufferMemoryBarrier{
                    .src_access_mask = toVkAccess(value.src_access),
                    .dst_access_mask = toVkAccess(value.dst_access),
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .buffer = texture_buffer.handle,
                    .offset = 0,
                    .size = vk.WHOLE_SIZE,
                };
                self.vkd.cmdPipelineBarrier(
                    command_buffer,
                    toVkStage(value.src_stage),
                    toVkStage(value.dst_stage),
                    .{},
                    null,
                    &.{barrier},
                    null,
                );
            },
            else => return error.InvalidResource,
        }
    }

    fn deviceOp(
        self: *Vulkan,
        operator: Device.DeviceOp,
        output_mode: ?Device.OutputMode,
        ret_addr: usize,
    ) Error!?[]const u8 {
        _ = output_mode;
        _ = ret_addr;
        switch (operator) {
            .wait_idle => {
                self.vkd.deviceWaitIdle() catch |err|
                    return mapError(err);
                return null;
            },
            .wait_fence => |value| {
                const slot = try self.lookup(value.fence, .fence);
                const result = self.vkd.waitForFences(
                    &.{slot.handle.fence},
                    .true,
                    value.timeout_ns,
                ) catch |err| return mapError(err);
                if (result == .timeout) return error.Timeout;
                return null;
            },
            .reset_fence => |value| {
                const slot = try self.lookup(value.fence, .fence);
                self.vkd.resetFences(
                    &.{slot.handle.fence},
                ) catch |err| return mapError(err);
                return null;
            },
            .write_descriptor_set => |value| {
                try self.writeDescriptorSet(value);
                return null;
            },
        }
    }

    fn writeDescriptorSet(
        self: *Vulkan,
        description: anytype,
    ) Error!void {
        const set_slot = try self.lookup(
            description.set,
            .descriptor_set,
        );
        const layout_slot = try self.lookup(
            set_slot.handle.descriptor_set.layout,
            .descriptor_set_layout,
        );
        const writes = self.allocator.alloc(
            vk.WriteDescriptorSet,
            description.writes.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(writes);
        const image_infos = self.allocator.alloc(
            vk.DescriptorImageInfo,
            description.writes.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(image_infos);
        const buffer_infos = self.allocator.alloc(
            vk.DescriptorBufferInfo,
            description.writes.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(buffer_infos);

        for (description.writes, 0..) |write, index| {
            const binding = findBinding(
                layout_slot.handle.descriptor_set_layout.bindings,
                write.binding,
            ) orelse return error.InvalidDescription;
            if (write.array_index >= binding.count) {
                return error.InvalidDescription;
            }
            const descriptor_type = toVkDescriptorType(binding.kind);

            switch (write.kind) {
                .buffer => |value| {
                    if (binding.kind != .uniform_buffer and
                        binding.kind != .storage_buffer)
                    {
                        return error.InvalidDescription;
                    }
                    const buffer = try self.lookup(value.buffer, .buffer);
                    buffer_infos[index] = .{
                        .buffer = buffer.handle.buffer.handle,
                        .offset = value.offset,
                        .range = if (value.size == 0)
                            vk.WHOLE_SIZE
                        else
                            value.size,
                    };
                    writes[index] = .{
                        .dst_set = set_slot.handle.descriptor_set.handle,
                        .dst_binding = write.binding,
                        .dst_array_element = write.array_index,
                        .descriptor_count = 1,
                        .descriptor_type = descriptor_type,
                        .p_buffer_info = @ptrCast(&buffer_infos[index]),
                    };
                },
                .texture => |value| {
                    if (binding.kind != .sampled_texture and
                        binding.kind != .storage_texture and
                        binding.kind != .combined_image_sampler)
                    {
                        return error.InvalidDescription;
                    }
                    const image_view = try self.lookup(
                        value.view,
                        .texture_view,
                    );
                    if (binding.kind == .combined_image_sampler and
                        value.sampler == null)
                    {
                        return error.InvalidDescription;
                    }
                    var sampler: vk.Sampler = .null;
                    if (value.sampler) |sampler_resource| {
                        const sampler_slot = try self.lookup(
                            sampler_resource,
                            .sampler,
                        );
                        sampler = sampler_slot.handle.sampler;
                    }
                    image_infos[index] = .{
                        .sampler = sampler,
                        .image_view = image_view.handle.texture_view.handle,
                        .image_layout = if (binding.kind == .storage_texture)
                            .general
                        else
                            aspectLayout(
                                image_view.handle.texture_view.aspect,
                            ),
                    };
                    writes[index] = .{
                        .dst_set = set_slot.handle.descriptor_set.handle,
                        .dst_binding = write.binding,
                        .dst_array_element = write.array_index,
                        .descriptor_count = 1,
                        .descriptor_type = descriptor_type,
                        .p_image_info = @ptrCast(&image_infos[index]),
                    };
                },
                .sampler => |value| {
                    if (binding.kind != .sampler) {
                        return error.InvalidDescription;
                    }
                    const sampler = try self.lookup(value, .sampler);
                    image_infos[index] = .{
                        .sampler = sampler.handle.sampler,
                        .image_view = .null,
                        .image_layout = .undefined,
                    };
                    writes[index] = .{
                        .dst_set = set_slot.handle.descriptor_set.handle,
                        .dst_binding = write.binding,
                        .dst_array_element = write.array_index,
                        .descriptor_count = 1,
                        .descriptor_type = descriptor_type,
                        .p_image_info = @ptrCast(&image_infos[index]),
                    };
                },
            }
        }

        self.vkd.updateDescriptorSets(writes, null);
    }

    fn query(
        self: *Vulkan,
        feature: Device.Feature,
        feature_index: u32,
        handle: ?Resource,
        output_mode: ?Device.OutputMode,
        ret_addr: usize,
    ) Error!Device.QueryResult {
        _ = ret_addr;
        return switch (feature) {
            .api_version => blk: {
                const version: rhi.Version = @bitCast(
                    self.properties.api_version,
                );
                break :blk writeFixed(output_mode, version);
            },
            .device_name => blk: {
                const name = std.mem.sliceTo(
                    &self.properties.device_name,
                    0,
                );
                break :blk .{
                    .support = .support,
                    .result = try writeBytes(output_mode, name),
                };
            },
            .driver_name => blk: {
                var buffer: [96]u8 = undefined;
                const name = std.fmt.bufPrint(
                    &buffer,
                    "vendor {d} driver {d}",
                    .{
                        self.properties.vendor_id,
                        self.properties.driver_version,
                    },
                ) catch return error.Unknown;
                break :blk .{
                    .support = .support,
                    .result = try writeBytes(output_mode, name),
                };
            },
            .device_type => blk: {
                const device_type: Device.DeviceType = switch (self.properties.device_type) {
                    .integrated_gpu => .integrated_gpu,
                    .discrete_gpu => .discrete_gpu,
                    .virtual_gpu => .virtual_gpu,
                    .cpu => .cpu,
                    else => .other,
                };
                break :blk writeFixed(output_mode, device_type);
            },
            .limit => |limit| blk: {
                const value: u64 = switch (limit) {
                    .max_texture_dimension_1d => self.properties
                        .limits.max_image_dimension_1d,
                    .max_texture_dimension_2d => self.properties
                        .limits.max_image_dimension_2d,
                    .max_texture_dimension_3d => self.properties
                        .limits.max_image_dimension_3d,
                    .max_texture_array_layers => self.properties
                        .limits.max_image_array_layers,
                    .max_buffer_size => self.properties.limits
                        .max_storage_buffer_range,
                    .max_uniform_buffer_range => self.properties
                        .limits.max_uniform_buffer_range,
                    .max_storage_buffer_range => self.properties
                        .limits.max_storage_buffer_range,
                    .max_push_constant_size => self.properties
                        .limits.max_push_constants_size,
                    .max_vertex_bindings => self.properties.limits
                        .max_vertex_input_bindings,
                    .max_vertex_attributes => self.properties.limits
                        .max_vertex_input_attributes,
                    .max_descriptor_sets => self.properties.limits
                        .max_bound_descriptor_sets,
                    .max_color_attachments => self.properties.limits
                        .max_color_attachments,
                };
                break :blk writeFixed(output_mode, value);
            },
            .format => |value| blk: {
                const format = toVkFormat(value.format) orelse
                    break :blk .{ .support = .unsupport };
                const properties = self.vki
                    .getPhysicalDeviceFormatProperties(
                    self.physical_device,
                    format,
                );
                const actual: types.FormatProperties = .{
                    .sampled = properties
                        .optimal_tiling_features.sampled_image,
                    .storage = properties
                        .optimal_tiling_features.storage_image,
                    .color_attachment = properties
                        .optimal_tiling_features.color_attachment,
                    .depth_attachment = properties
                        .optimal_tiling_features.depth_stencil_attachment,
                    .buffer = properties.buffer_features.vertex_buffer,
                };
                const wanted = value.usage;
                const supported =
                    (!wanted.sampled or actual.sampled) and
                    (!wanted.storage or actual.storage) and
                    (!wanted.color_attachment or
                        actual.color_attachment) and
                    (!wanted.depth_attachment or
                        actual.depth_attachment) and
                    (!wanted.buffer or actual.buffer);
                break :blk .{
                    .support = if (supported) .support else .unsupport,
                };
            },
            .surface => blk: {
                const resource = handle orelse
                    return error.InvalidDescription;
                const slot = try self.lookup(resource, .surface);
                if (!self.supports_swapchain) {
                    break :blk .{ .support = .unsupport };
                }
                const caps = self.vki
                    .getPhysicalDeviceSurfaceCapabilitiesKHR(
                    self.physical_device,
                    slot.handle.surface,
                ) catch |err| return mapError(err);
                const formats = self.vki
                    .getPhysicalDeviceSurfaceFormatsAllocKHR(
                    self.physical_device,
                    slot.handle.surface,
                    self.allocator,
                ) catch |err| return mapError(err);
                defer self.allocator.free(formats);
                const properties: types.SurfaceProperties = .{
                    .min_width = caps.min_image_extent.width,
                    .min_height = caps.min_image_extent.height,
                    .max_width = caps.max_image_extent.width,
                    .max_height = caps.max_image_extent.height,
                    .current_width = caps.current_extent.width,
                    .current_height = caps.current_extent.height,
                    .format_count = @intCast(formats.len),
                };
                break :blk writeFixed(output_mode, properties);
            },
            .swapchain => blk: {
                const resource = handle orelse
                    return error.InvalidDescription;
                const slot = try self.lookup(resource, .swapchain);
                break :blk writeFixed(
                    output_mode,
                    slot.handle.swapchain.properties,
                );
            },
            .swapchain_images => self.writeResourceList(
                handle,
                output_mode,
                true,
            ),
            .swapchain_views => self.writeResourceList(
                handle,
                output_mode,
                false,
            ),
            .buffer => blk: {
                const resource = handle orelse
                    return error.InvalidDescription;
                const slot = try self.lookup(resource, .buffer);
                const properties: types.BufferProperties = .{
                    .size = slot.handle.buffer.size,
                    .memory = slot.handle.buffer.hints,
                };
                break :blk writeFixed(output_mode, properties);
            },
            .texture => blk: {
                const resource = handle orelse
                    return error.InvalidDescription;
                const slot = try self.lookup(resource, .texture);
                break :blk writeFixed(
                    output_mode,
                    slot.handle.texture.properties,
                );
            },
            .memory => blk: {
                if (feature_index >= self.memory_properties.memory_heap_count) {
                    break :blk .{ .support = .unsupport };
                }
                const heap = self.memory_properties.memory_heaps[
                    feature_index
                ];
                const properties: types.MemoryHeap = .{
                    .size = heap.size,
                    .device_local = heap.flags.device_local,
                };
                break :blk writeFixed(output_mode, properties);
            },
            .queue => blk: {
                const families = self.vki
                    .getPhysicalDeviceQueueFamilyPropertiesAlloc(
                    self.physical_device,
                    self.allocator,
                ) catch |err| return mapError(err);
                defer self.allocator.free(families);
                if (feature_index >= families.len) {
                    break :blk .{ .support = .unsupport };
                }
                const family = families[feature_index];
                const properties: types.QueueProperties = .{
                    .capabilities = .{
                        .graphics = family.queue_flags.graphics,
                        .compute = family.queue_flags.compute,
                        .transfer = family.queue_flags.transfer,
                        .present = family.queue_flags.graphics,
                    },
                    .count = family.queue_count,
                    .timestamp_bits = family.timestamp_valid_bits,
                };
                break :blk writeFixed(output_mode, properties);
            },
        };
    }

    fn writeResourceList(
        self: *Vulkan,
        handle: ?Resource,
        output_mode: ?Device.OutputMode,
        images: bool,
    ) Error!Device.QueryResult {
        const resource = handle orelse return error.InvalidDescription;
        const slot = try self.lookup(resource, .swapchain);
        const list = if (images)
            slot.handle.swapchain.images
        else
            slot.handle.swapchain.views;
        const mode = output_mode orelse
            return .{ .support = .unsupport };
        return switch (mode) {
            .slice => |slice| blk: {
                const bytes = std.mem.sliceAsBytes(list);
                if (slice.len < bytes.len) {
                    return error.BufferTooSmall;
                }
                @memcpy(slice[0..bytes.len], bytes);
                break :blk .{
                    .support = .support,
                    .result = slice[0..bytes.len],
                };
            },
            .allocator => error.Unsupported,
        };
    }

    fn findMemoryType(
        self: *Vulkan,
        bits: u32,
        hints: types.Memory,
    ) Error!u32 {
        for (0..self.memory_properties.memory_type_count) |index| {
            const mask = @as(u32, 1) << @intCast(index);
            if (bits & mask == 0) continue;
            const flags = self.memory_properties.memory_types[index]
                .property_flags;
            if (!hints.host_visible and hints.device_local and
                !flags.device_local)
            {
                continue;
            }
            if (hints.host_visible and !flags.host_visible) continue;
            if (hints.host_coherent and !flags.host_coherent) continue;
            if (hints.host_cached and !flags.host_cached) continue;
            return @intCast(index);
        }
        return error.OutOfDeviceMemory;
    }

    fn createStagingBuffer(
        self: *Vulkan,
        data: []const u8,
    ) Error!struct {
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,
    } {
        const handle = self.vkd.createBuffer(&.{
            .size = data.len,
            .usage = .{ .transfer_src = true },
            .sharing_mode = .exclusive,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.destroyBuffer(handle, self.vk_allocator);

        const requirements = self.vkd.getBufferMemoryRequirements(
            handle,
        );
        const memory_type = try self.findMemoryType(
            requirements.memory_type_bits,
            .{ .device_local = false, .host_visible = true },
        );
        const memory = self.vkd.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        }, self.vk_allocator) catch |err| return mapError(err);
        errdefer self.vkd.freeMemory(memory, self.vk_allocator);
        self.vkd.bindBufferMemory(
            handle,
            memory,
            0,
        ) catch |err| return mapError(err);

        const mapped = self.vkd.mapMemory(
            memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ) catch |err| return mapError(err);
        const bytes: [*]u8 = @ptrCast(mapped orelse
            return error.OutOfHostMemory);
        @memcpy(bytes[0..data.len], data);
        self.vkd.flushMappedMemoryRanges(&.{
            .{
                .memory = memory,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            },
        }) catch |err| {
            self.vkd.unmapMemory(memory);
            return mapError(err);
        };
        self.vkd.unmapMemory(memory);

        return .{ .buffer = handle, .memory = memory };
    }

    fn beginOneShot(self: *Vulkan) Error!vk.CommandBuffer {
        var handle: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&handle)) catch |err| return mapError(err);
        errdefer self.vkd.freeCommandBuffers(
            self.command_pool,
            &.{handle},
        );
        self.vkd.beginCommandBuffer(handle, &.{
            .flags = .{ .one_time_submit = true },
        }) catch |err| return mapError(err);
        return handle;
    }

    fn endOneShot(self: *Vulkan, handle: vk.CommandBuffer) Error!void {
        defer self.vkd.freeCommandBuffers(
            self.command_pool,
            &.{handle},
        );
        self.vkd.endCommandBuffer(handle) catch |err|
            return mapError(err);
        self.vkd.queueSubmit(
            self.queue,
            &.{.{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&handle) }},
            .null,
        ) catch |err| return mapError(err);
        self.vkd.queueWaitIdle(self.queue) catch |err|
            return mapError(err);
    }

    fn uploadToBuffer(
        self: *Vulkan,
        destination: vk.Buffer,
        destination_size: u64,
        data: []const u8,
    ) Error!void {
        if (data.len == 0) return;
        if (data.len > destination_size) {
            return error.InvalidDescription;
        }
        const staging = try self.createStagingBuffer(data);
        defer {
            self.vkd.destroyBuffer(staging.buffer, self.vk_allocator);
            self.vkd.freeMemory(staging.memory, self.vk_allocator);
        }
        const handle = try self.beginOneShot();
        errdefer self.vkd.freeCommandBuffers(
            self.command_pool,
            &.{handle},
        );
        self.vkd.cmdCopyBuffer(handle, staging.buffer, destination, &.{
            .{
                .src_offset = 0,
                .dst_offset = 0,
                .size = data.len,
            },
        });
        try self.endOneShot(handle);
    }

    fn uploadToTexture(
        self: *Vulkan,
        image: vk.Image,
        description: types.TextureDescription,
        data: types.TextureData,
    ) Error!types.TextureLayout {
        const bpp = description.format.bytesPerPixel() orelse
            return error.InvalidDescription;
        const tight_row = @as(u64, description.width) * bpp;
        const row_bytes = if (data.row_pitch == 0)
            tight_row
        else
            data.row_pitch;
        const required = row_bytes *
            @as(u64, description.height) *
            @as(u64, description.depth);
        if (data.bytes.len < required) {
            return error.InvalidDescription;
        }

        const staging = try self.createStagingBuffer(data.bytes);
        defer {
            self.vkd.destroyBuffer(staging.buffer, self.vk_allocator);
            self.vkd.freeMemory(staging.memory, self.vk_allocator);
        }

        const handle = try self.beginOneShot();
        errdefer self.vkd.freeCommandBuffers(
            self.command_pool,
            &.{handle},
        );
        const aspect: types.TextureAspect = description
            .format
            .aspect();
        const final_layout: vk.ImageLayout = switch (aspect) {
            .color => .shader_read_only_optimal,
            .depth => .depth_read_only_optimal,
            .stencil => .stencil_read_only_optimal,
            .depth_stencil => .depth_stencil_read_only_optimal,
        };

        const to_transfer = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = toVkAspect(aspect),
                .base_mip_level = 0,
                .level_count = description.mip_levels,
                .base_array_layer = 0,
                .layer_count = description.array_layers,
            },
        };
        self.vkd.cmdPipelineBarrier(
            handle,
            .{ .top_of_pipe = true },
            .{ .transfer = true },
            .{},
            null,
            null,
            &.{to_transfer},
        );

        const copy = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = if (data.row_pitch == 0)
                0
            else
                @intCast(data.row_pitch / bpp),
            .buffer_image_height = data.image_height,
            .image_subresource = .{
                .aspect_mask = toVkAspect(aspect),
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = description.array_layers,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
            },
        };
        self.vkd.cmdCopyBufferToImage(
            handle,
            staging.buffer,
            image,
            .transfer_dst_optimal,
            &.{copy},
        );

        const to_final = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write = true },
            .dst_access_mask = .{ .shader_read = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = final_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = toVkAspect(aspect),
                .base_mip_level = 0,
                .level_count = description.mip_levels,
                .base_array_layer = 0,
                .layer_count = description.array_layers,
            },
        };
        self.vkd.cmdPipelineBarrier(
            handle,
            .{ .transfer = true },
            .{ .fragment_shader = true, .compute_shader = true },
            .{},
            null,
            null,
            &.{to_final},
        );
        try self.endOneShot(handle);

        return switch (aspect) {
            .color => .shader_read_only,
            .depth => .depth_read_only,
            .stencil => .stencil_read_only,
            .depth_stencil => .depth_stencil_read_only,
        };
    }
};

const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
    .{ .type = .uniform_buffer, .descriptor_count = 1024 },
    .{ .type = .storage_buffer, .descriptor_count = 1024 },
    .{ .type = .sampled_image, .descriptor_count = 4096 },
    .{ .type = .storage_image, .descriptor_count = 256 },
    .{ .type = .sampler, .descriptor_count = 1024 },
    .{ .type = .combined_image_sampler, .descriptor_count = 1024 },
};

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfHostMemory => error.OutOfHostMemory,
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.DeviceLost => error.DeviceLost,
        error.InitializationFailed => error.InitializationFailed,
        error.OutOfDateKHR => error.SurfaceOutOfDate,
        error.SurfaceLostKHR => error.SurfaceLost,
        error.Timeout => error.Timeout,
        error.MemoryMapFailed => error.OutOfHostMemory,
        error.Unknown => error.Unknown,
        else => error.Unknown,
    };
}

fn writeFixed(
    output_mode: ?Device.OutputMode,
    value: anytype,
) Error!Device.QueryResult {
    const bytes = std.mem.asBytes(&value);
    const result = try writeBytes(output_mode, bytes);
    return .{ .support = .support, .result = result };
}

fn writeBytes(
    output_mode: ?Device.OutputMode,
    bytes: []const u8,
) Error!?[]const u8 {
    const mode = output_mode orelse return null;
    return switch (mode) {
        .slice => |slice| blk: {
            if (slice.len < bytes.len) return error.BufferTooSmall;
            @memcpy(slice[0..bytes.len], bytes);
            break :blk slice[0..bytes.len];
        },
        .allocator => |allocator| blk: {
            const result = allocator.dupe(
                u8,
                bytes,
            ) catch return error.OutOfHostMemory;
            break :blk @as(?[]const u8, result);
        },
    };
}

fn defaultStencilState() vk.StencilOpState {
    return .{
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
        .compare_op = .always,
        .compare_mask = 0xff,
        .write_mask = 0xff,
        .reference = 0,
    };
}

fn findBinding(
    bindings: []const types.DescriptorSetLayoutDescription
        .DescriptorBinding,
    binding: u32,
) ?types.DescriptorSetLayoutDescription.DescriptorBinding {
    for (bindings) |candidate| {
        if (candidate.binding == binding) return candidate;
    }
    return null;
}

fn makeBufferImageCopy(
    buffer_offset: u64,
    row_pitch: u32,
    image_height: u32,
    region: commands.TextureCopyRegion,
    properties: types.TextureProperties,
) !vk.BufferImageCopy {
    if (region.mip_level >= properties.mip_levels) {
        return error.InvalidDescription;
    }
    if (region.array_layer >= properties.array_layers) {
        return error.InvalidDescription;
    }
    const bpp = properties.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    return .{
        .buffer_offset = buffer_offset,
        .buffer_row_length = if (row_pitch == 0)
            0
        else
            row_pitch / bpp,
        .buffer_image_height = image_height,
        .image_subresource = .{
            .aspect_mask = toVkAspect(properties.format.aspect()),
            .mip_level = region.mip_level,
            .base_array_layer = region.array_layer,
            .layer_count = 1,
        },
        .image_offset = .{
            .x = @intCast(region.offset.x),
            .y = @intCast(region.offset.y),
            .z = @intCast(region.offset.z),
        },
        .image_extent = .{
            .width = region.extent.width,
            .height = region.extent.height,
            .depth = region.extent.depth,
        },
    };
}

fn toVkFormat(format: types.Format) ?vk.Format {
    return switch (format) {
        .undefined => null,
        .r8_unorm => .r8_unorm,
        .r8g8_unorm => .r8g8_unorm,
        .r8g8b8a8_unorm => .r8g8b8a8_unorm,
        .r8g8b8a8_srgb => .r8g8b8a8_srgb,
        .b8g8r8a8_unorm => .b8g8r8a8_unorm,
        .b8g8r8a8_srgb => .b8g8r8a8_srgb,
        .r16_float => .r16_sfloat,
        .r16g16_float => .r16g16_sfloat,
        .r16g16b16a16_float => .r16g16b16a16_sfloat,
        .r32_float => .r32_sfloat,
        .r32g32_float => .r32g32_sfloat,
        .r32g32b32_float => .r32g32b32_sfloat,
        .r32g32b32a32_float => .r32g32b32a32_sfloat,
        .r32_uint => .r32_uint,
        .r32g32_uint => .r32g32_uint,
        .r32g32b32_uint => .r32g32b32_uint,
        .r32g32b32a32_uint => .r32g32b32a32_uint,
        .d32_float => .d32_sfloat,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
    };
}

fn fromVkFormat(format: vk.Format) types.Format {
    return switch (format) {
        .r8_unorm => .r8_unorm,
        .r8g8_unorm => .r8g8_unorm,
        .r8g8b8a8_unorm => .r8g8b8a8_unorm,
        .r8g8b8a8_srgb => .r8g8b8a8_srgb,
        .b8g8r8a8_unorm => .b8g8r8a8_unorm,
        .b8g8r8a8_srgb => .b8g8r8a8_srgb,
        .r16_sfloat => .r16_float,
        .r16g16_sfloat => .r16g16_float,
        .r16g16b16a16_sfloat => .r16g16b16a16_float,
        .r32_sfloat => .r32_float,
        .r32g32_sfloat => .r32g32_float,
        .r32g32b32_sfloat => .r32g32b32_float,
        .r32g32b32a32_sfloat => .r32g32b32a32_float,
        .r32_uint => .r32_uint,
        .r32g32_uint => .r32g32_uint,
        .r32g32b32_uint => .r32g32b32_uint,
        .r32g32b32a32_uint => .r32g32b32a32_uint,
        .d32_sfloat => .d32_float,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        else => .undefined,
    };
}

fn toVkBufferUsage(usage: types.BufferUsage) vk.BufferUsageFlags {
    return .{
        .vertex_buffer = usage.vertex,
        .index_buffer = usage.index,
        .uniform_buffer = usage.uniform,
        .storage_buffer = usage.storage,
        .indirect_buffer = usage.indirect,
        .transfer_src = usage.transfer_src,
        .transfer_dst = usage.transfer_dst,
    };
}

fn toVkImageUsage(usage: types.TextureUsage) vk.ImageUsageFlags {
    return .{
        .sampled = usage.sampled,
        .storage = usage.storage,
        .color_attachment = usage.color_attachment,
        .depth_stencil_attachment = usage.depth_attachment,
        .transfer_src = usage.transfer_src,
        .transfer_dst = usage.transfer_dst,
    };
}

fn toVkImageViewType(value: types.TextureType) vk.ImageViewType {
    return switch (value) {
        .@"1d" => .@"1d",
        .@"2d" => .@"2d",
        .@"3d" => .@"3d",
    };
}

fn toVkSampleCount(samples: u32) ?vk.SampleCountFlags {
    return switch (samples) {
        1 => .{ .@"1" = true },
        2 => .{ .@"2" = true },
        4 => .{ .@"4" = true },
        8 => .{ .@"8" = true },
        16 => .{ .@"16" = true },
        32 => .{ .@"32" = true },
        64 => .{ .@"64" = true },
        else => null,
    };
}

fn toVkAspect(aspect: types.TextureAspect) vk.ImageAspectFlags {
    return switch (aspect) {
        .color => .{ .color = true },
        .depth => .{ .depth = true },
        .stencil => .{ .stencil = true },
        .depth_stencil => .{ .depth = true, .stencil = true },
    };
}

fn toVkFilter(filter: types.Filter) vk.Filter {
    return switch (filter) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn toVkAddressMode(mode: types.AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => .clamp_to_border,
    };
}

fn toVkCompareOp(op: types.CompareOp) vk.CompareOp {
    return switch (op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_or_equal,
        .always => .always,
    };
}

fn toVkTopology(topology: types.Topology) vk.PrimitiveTopology {
    return switch (topology) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
        .triangle_fan => .triangle_fan,
    };
}

fn toVkBlendFactor(factor: types.BlendFactor) vk.BlendFactor {
    return switch (factor) {
        .zero => .zero,
        .one => .one,
        .src_color => .src_color,
        .one_minus_src_color => .one_minus_src_color,
        .dst_color => .dst_color,
        .one_minus_dst_color => .one_minus_dst_color,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .constant_color => .constant_color,
        .one_minus_constant_color => .one_minus_constant_color,
        .constant_alpha => .constant_alpha,
        .one_minus_constant_alpha => .one_minus_constant_alpha,
    };
}

fn toVkBlendOp(op: types.BlendOp) vk.BlendOp {
    return switch (op) {
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
    };
}

fn toVkLoadOp(op: types.LoadOp) vk.AttachmentLoadOp {
    return switch (op) {
        .load => .load,
        .clear => .clear,
        .dont_care => .dont_care,
    };
}

fn toVkStoreOp(op: types.StoreOp) vk.AttachmentStoreOp {
    return switch (op) {
        .store => .store,
        .dont_care => .dont_care,
    };
}

fn toVkDescriptorType(
    kind: types.DescriptorKind,
) vk.DescriptorType {
    return switch (kind) {
        .uniform_buffer => .uniform_buffer,
        .storage_buffer => .storage_buffer,
        .sampled_texture => .sampled_image,
        .storage_texture => .storage_image,
        .sampler => .sampler,
        .combined_image_sampler => .combined_image_sampler,
    };
}

fn toVkShaderStages(stages: types.ShaderStageFlags) vk.ShaderStageFlags {
    return .{
        .vertex = stages.vertex,
        .fragment = stages.fragment,
        .compute = stages.compute,
        .geometry = stages.geometry,
        .tessellation_control = stages.tessellation_control,
        .tessellation_evaluation = stages.tessellation_evaluation,
    };
}

fn toVkStage(stage: types.PipelineStage) vk.PipelineStageFlags {
    return switch (stage) {
        .top_of_pipe => .{ .top_of_pipe = true },
        .vertex_input => .{ .vertex_input = true },
        .vertex_shader => .{ .vertex_shader = true },
        .fragment_shader => .{ .fragment_shader = true },
        .color_attachment => .{ .color_attachment_output = true },
        .compute_shader => .{ .compute_shader = true },
        .transfer => .{ .transfer = true },
        .bottom_of_pipe => .{ .bottom_of_pipe = true },
        .all_commands => .{ .all_commands = true },
        .host => .{ .host = true },
    };
}

fn toVkAccess(access: types.Access) vk.AccessFlags {
    return .{
        .indirect_command_read = access.indirect_command_read,
        .index_read = access.index_read,
        .vertex_attribute_read = access.vertex_attribute_read,
        .uniform_read = access.uniform_read,
        .input_attachment_read = access.input_attachment_read,
        .shader_read = access.shader_read,
        .shader_write = access.shader_write,
        .color_attachment_read = access.color_attachment_read,
        .color_attachment_write = access.color_attachment_write,
        .depth_stencil_attachment_read = access
            .depth_stencil_attachment_read,
        .depth_stencil_attachment_write = access
            .depth_stencil_attachment_write,
        .transfer_read = access.transfer_read,
        .transfer_write = access.transfer_write,
        .host_read = access.host_read,
        .host_write = access.host_write,
        .memory_read = access.memory_read,
        .memory_write = access.memory_write,
    };
}

fn aspectLayout(aspect: types.TextureAspect) vk.ImageLayout {
    return switch (aspect) {
        .color => .shader_read_only_optimal,
        .depth => .depth_read_only_optimal,
        .stencil => .stencil_read_only_optimal,
        .depth_stencil => .depth_stencil_read_only_optimal,
    };
}

fn toVkLayout(layout: types.TextureLayout) vk.ImageLayout {
    return switch (layout) {
        .undefined => .undefined,
        .general => .general,
        .color_attachment => .color_attachment_optimal,
        .depth_attachment => .depth_stencil_attachment_optimal,
        .depth_read_only => .depth_read_only_optimal,
        .stencil_read_only => .stencil_read_only_optimal,
        .depth_stencil_read_only => .depth_stencil_read_only_optimal,
        .shader_read_only => .shader_read_only_optimal,
        .transfer_src => .transfer_src_optimal,
        .transfer_dst => .transfer_dst_optimal,
        .present => .present_src_khr,
    };
}

fn toVkPresentMode(mode: types.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
        .fifo => .fifo_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
    };
}

const device_vtable: Device.VTable = .{
    .create = deviceCreate,
    .destroy = deviceDestroy,
    .create_batch = deviceCreateBatch,
    .destroy_batch = deviceDestroyBatch,
    .map = deviceMap,
    .unmap = deviceUnmap,
    .get_queue = deviceGetQueue,
    .record = deviceRecord,
    .device_op = deviceOp,
    .query = deviceQuery,
};

const queue_vtable: Queue.VTable = .{
    .acquire = queueAcquire,
    .submit = queueSubmit,
    .present = queuePresent,
    .wait_idle = queueWaitIdle,
};

fn backend(vptr: *anyopaque) *Vulkan {
    return @ptrCast(@alignCast(vptr));
}

fn deviceCreate(
    vptr: *anyopaque,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    return backend(vptr).createResource(description, ret_addr);
}

fn deviceDestroy(
    vptr: *anyopaque,
    resource: Resource,
    ret_addr: usize,
) void {
    log.debug(
        "destroy {s} index={d} (ret 0x{x})",
        .{
            @tagName(resource.tag),
            resource.identifier.index,
            ret_addr,
        },
    );
    backend(vptr).destroyResource(resource);
}

fn deviceCreateBatch(
    vptr: *anyopaque,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Error!void {
    return backend(vptr).createBatch(
        descriptions,
        resources,
        ret_addr,
    );
}

fn deviceDestroyBatch(
    vptr: *anyopaque,
    resources: []const Resource,
    ret_addr: usize,
) void {
    log.debug(
        "destroy {d} resource(s) (ret 0x{x})",
        .{ resources.len, ret_addr },
    );
    const self = backend(vptr);
    for (resources) |resource| {
        self.destroyResource(resource);
    }
}

fn deviceMap(
    vptr: *anyopaque,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    return backend(vptr).map(resource, offset, size, ret_addr);
}

fn deviceUnmap(
    vptr: *anyopaque,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    backend(vptr).unmap(resource, dirty, ret_addr);
}

fn deviceGetQueue(
    vptr: *anyopaque,
    index: u32,
    ret_addr: usize,
) Error!Queue {
    return backend(vptr).getQueue(index, ret_addr);
}

fn deviceRecord(
    vptr: *anyopaque,
    resource: Resource,
    command: commands.Command,
    ret_addr: usize,
) Error!void {
    return backend(vptr).record(resource, command, ret_addr);
}

fn deviceOp(
    vptr: *anyopaque,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    return backend(vptr).deviceOp(operator, output_mode, ret_addr);
}

fn deviceQuery(
    vptr: *anyopaque,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!Device.QueryResult {
    return backend(vptr).query(
        feature,
        feature_index,
        handle,
        output_mode,
        ret_addr,
    );
}

fn queueIndex(
    self: *Vulkan,
    family_index: u32,
    queue_index: u32,
) Error!void {
    if (family_index != self.queue_family_index or queue_index != 0) {
        return error.InvalidResource;
    }
}

fn queueAcquire(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Acquire,
    ret_addr: usize,
) Error!Queue.Acquired {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(self, family_index, queue_index);
    const swapchain = try self.lookup(
        description.swapchain,
        .swapchain,
    );
    const semaphore: vk.Semaphore = if (description.semaphore) |resource|
        (try self.lookup(resource, .semaphore)).handle.semaphore
    else
        .null;
    const fence: vk.Fence = if (description.fence) |resource|
        (try self.lookup(resource, .fence)).handle.fence
    else
        .null;
    if (semaphore == .null and fence == .null) {
        return error.InvalidDescription;
    }
    const acquired = self.vkd.acquireNextImageKHR(
        swapchain.handle.swapchain.handle,
        description.timeout_ns,
        semaphore,
        fence,
    ) catch |err| return mapError(err);
    const result = switch (acquired.result) {
        .success => false,
        .suboptimal_khr => true,
        .not_ready => return error.NotReady,
        .timeout => return error.Timeout,
        else => return error.Unknown,
    };
    if (acquired.image_index < swapchain.handle.swapchain.images.len) {
        const image_resource = swapchain.handle.swapchain.images[
            acquired.image_index
        ];
        if (self.lookup(image_resource, .texture)) |image_slot| {
            image_slot.handle.texture.layout = .undefined;
        } else |_| {}
    }
    return .{
        .image_index = acquired.image_index,
        .suboptimal = result,
    };
}

fn queueSubmit(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    submission: Queue.Submission,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(self, family_index, queue_index);

    const command_buffers = self.allocator.alloc(
        vk.CommandBuffer,
        submission.command_buffers.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(command_buffers);
    for (submission.command_buffers, 0..) |resource, index| {
        const slot = try self.lookup(resource, .command_buffer);
        if (slot.handle.command_buffer.state != .ended) {
            return error.InvalidResource;
        }
        command_buffers[index] = slot.handle.command_buffer.handle;
    }

    const wait_semaphores = self.allocator.alloc(
        vk.Semaphore,
        submission.wait_semaphores.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(wait_semaphores);
    const wait_stages = self.allocator.alloc(
        vk.PipelineStageFlags,
        submission.wait_semaphores.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(wait_stages);
    for (submission.wait_semaphores, 0..) |resource, index| {
        const slot = try self.lookup(resource, .semaphore);
        wait_semaphores[index] = slot.handle.semaphore;
        wait_stages[index] = .{ .all_commands = true };
    }

    const signal_semaphores = self.allocator.alloc(
        vk.Semaphore,
        submission.signal_semaphores.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(signal_semaphores);
    for (submission.signal_semaphores, 0..) |resource, index| {
        const slot = try self.lookup(resource, .semaphore);
        signal_semaphores[index] = slot.handle.semaphore;
    }

    const fence: vk.Fence = if (submission.fence) |resource|
        (try self.lookup(resource, .fence)).handle.fence
    else
        .null;

    self.vkd.queueSubmit(
        self.queue,
        &.{.{
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = if (wait_semaphores.len == 0)
                null
            else
                wait_semaphores.ptr,
            .p_wait_dst_stage_mask = if (wait_stages.len == 0)
                null
            else
                wait_stages.ptr,
            .command_buffer_count = @intCast(command_buffers.len),
            .p_command_buffers = if (command_buffers.len == 0)
                null
            else
                command_buffers.ptr,
            .signal_semaphore_count = @intCast(signal_semaphores.len),
            .p_signal_semaphores = if (signal_semaphores.len == 0)
                null
            else
                signal_semaphores.ptr,
        }},
        fence,
    ) catch |err| return mapError(err);

    for (submission.command_buffers) |resource| {
        if (self.lookup(resource, .command_buffer)) |slot| {
            slot.handle.command_buffer.state = .submitted;
        } else |_| {}
    }
}

fn queuePresent(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Present,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(self, family_index, queue_index);
    const swapchain = try self.lookup(
        description.swapchain,
        .swapchain,
    );

    const wait_semaphores = self.allocator.alloc(
        vk.Semaphore,
        description.wait_semaphores.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(wait_semaphores);
    for (description.wait_semaphores, 0..) |resource, index| {
        const slot = try self.lookup(resource, .semaphore);
        wait_semaphores[index] = slot.handle.semaphore;
    }

    const swapchains = [_]vk.SwapchainKHR{
        swapchain.handle.swapchain.handle,
    };
    const indices = [_]u32{description.image_index};
    const result = self.vkd.queuePresentKHR(
        self.queue,
        &.{
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = if (wait_semaphores.len == 0)
                null
            else
                wait_semaphores.ptr,
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchains),
            .p_image_indices = @ptrCast(&indices),
        },
    ) catch |err| return mapError(err);
    if (result == .suboptimal_khr) {
        return error.SurfaceOutOfDate;
    }
}

fn queueWaitIdle(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(self, family_index, queue_index);
    self.vkd.queueWaitIdle(self.queue) catch |err|
        return mapError(err);
}
