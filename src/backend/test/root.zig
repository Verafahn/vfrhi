//! A headless backend that validates RHI usage without a GPU.
//!
//! The test backend tracks resource generations, dependency edges,
//! map/unmap state, command buffer state, and queue usage. It is
//! meant for unit tests of RHI call sequences and for validating
//! that externally loaded data is reachable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rhi = @import("rhi");
const types = rhi.types;
const commands = @import("../../Command.zig");
const Device = rhi.Device;
const Queue = rhi.Queue;
const Resource = rhi.Resource;
const log = std.log.scoped(.test_rhi);
const Test = @This();

allocator: Allocator,
slots: std.ArrayListUnmanaged(?Slot) = .empty,
generations: std.ArrayListUnmanaged(u32) = .empty,
free_slots: std.ArrayListUnmanaged(u32) = .empty,
live_count: usize = 0,
error_count: usize = 0,
queues: []QueueInfo = &.{},

/// One queue exposed by the test backend.
pub const QueueInfo = struct {
    family_index: u32 = 0,
    queue_index: u32 = 0,
    capabilities: types.QueueCapabilities = .{
        .graphics = true,
        .transfer = true,
        .present = true,
    },
};

/// Options for `initWithOptions`.
pub const Options = struct {
    /// Queues to expose. An empty slice creates one graphics,
    /// transfer, and present capable queue.
    queues: []const QueueInfo = &.{},
};

/// Errors reported by `validate`.
pub const ValidationError = error{
    /// Resources created through this backend are still alive.
    LeakedResources,
    /// Invalid calls or lifetime violations were observed.
    ValidationFailed,
};

/// Creates a test backend with one default queue.
///
/// # Args
/// - `allocator`: allocator used for every backend allocation.
///
/// # Return
/// A backend owned by the caller.
///
/// # Error
/// - `Allocator.Error`: allocating the backend fails.
///
/// # Note
/// Call `deinit` after destroying every RHI resource.
pub fn init(allocator: Allocator) Allocator.Error!*Test {
    return try initWithOptions(allocator, .{});
}

/// Creates a test backend with explicit options.
///
/// # Args
/// - `allocator`: allocator used for every backend allocation.
/// - `options`: queue layout of the backend.
///
/// # Return
/// A backend owned by the caller.
///
/// # Error
/// - `Allocator.Error`: allocating the backend or the queue
///   table fails.
pub fn initWithOptions(
    allocator: Allocator,
    options: Options,
) Allocator.Error!*Test {
    const self = try allocator.create(Test);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
    };

    if (options.queues.len == 0) {
        self.queues = try allocator.alloc(QueueInfo, 1);
        self.queues[0] = .{};
    } else {
        self.queues = try allocator.dupe(
            QueueInfo,
            options.queues,
        );
    }

    log.debug("Test backend created", .{});
    return self;
}

/// Destroys the backend.
///
/// # Note
/// Leaked resources and validation errors are logged as errors.
/// Use `validate` before `deinit` to fail a test explicitly.
pub fn deinit(self: *Test) void {
    if (self.live_count != 0) {
        log.err(
            "Test backend destroyed with {d} live resource(s)",
            .{self.live_count},
        );
    }
    if (self.error_count != 0) {
        log.err(
            "Test backend destroyed after {d} validation error(s)",
            .{self.error_count},
        );
    }

    for (self.slots.items, 0..) |slot, index| {
        if (slot) |value| {
            self.releaseData(@intCast(index), &value);
        }
    }
    self.slots.deinit(self.allocator);
    self.generations.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.allocator.free(self.queues);
    log.debug("Test backend destroyed", .{});
    self.allocator.destroy(self);
}

/// Returns the number of live resources.
///
/// # Return
/// The number of resources that have not been destroyed.
pub fn leakedCount(self: *Test) usize {
    return self.live_count;
}

/// Returns the number of validation errors observed so far.
///
/// # Return
/// A monotonically increasing error counter.
pub fn errorCount(self: *Test) usize {
    return self.error_count;
}

/// Clears the validation error counter.
pub fn clearErrors(self: *Test) void {
    self.error_count = 0;
}

/// Fails when resources leaked or validation errors were logged.
///
/// # Error
/// - `ValidationError.LeakedResources`: `live_count` is nonzero.
/// - `ValidationError.ValidationFailed`: errors were logged.
pub fn validate(self: *Test) ValidationError!void {
    if (self.live_count != 0) return error.LeakedResources;
    if (self.error_count != 0) return error.ValidationFailed;
}

/// Returns the shadow bytes of a buffer.
///
/// # Args
/// - `self`: the backend holding the resource.
/// - `resource`: a buffer handle.
///
/// # Return
/// The stored bytes, or `null` when `resource` is stale or is not
/// a buffer.
///
/// # Note
/// This is a validation helper. It exposes uploaded data so tests
/// can verify that external files reached the backend intact.
pub fn bufferData(
    self: *Test,
    resource: Resource,
) ?[]const u8 {
    const slot = self.lookup(resource) orelse return null;
    if (slot.tag != .buffer) return null;
    return slot.data.buffer.bytes;
}

/// Returns the shadow bytes of a texture.
///
/// # Args
/// - `self`: the backend holding the resource.
/// - `resource`: a texture handle.
///
/// # Return
/// The stored bytes, or `null` when `resource` is stale or is not
/// a texture.
///
/// # Note
/// Only the tightly packed base level is stored.
pub fn textureData(
    self: *Test,
    resource: Resource,
) ?[]const u8 {
    const slot = self.lookup(resource) orelse return null;
    if (slot.tag != .texture) return null;
    return slot.data.texture.bytes;
}

/// Returns the device interface of this backend.
///
/// # Return
/// A device whose lifetime is tied to `self`.
pub fn asDevice(self: *Test) Device {
    return .{
        .vptr = self,
        .vtable = &device_vtable,
    };
}

const Slot = struct {
    generation: u32,
    tag: Resource.Tag,
    dependencies: []const Resource,
    data: Data,

    const Data = union(Resource.Tag) {
        surface: SurfaceData,
        swapchain: SwapchainData,
        buffer: BufferData,
        texture: TextureData,
        texture_view: TextureViewData,
        sampler: SamplerData,
        shader: ShaderData,
        descriptor_set_layout: DescriptorSetLayoutData,
        pipeline_layout: PipelineLayoutData,
        descriptor_set: DescriptorSetData,
        pipeline: PipelineData,
        command_buffer: CommandBufferData,
        fence: FenceData,
        semaphore: SemaphoreData,
    };
};

const SurfaceData = struct {
    native: types.SurfaceDescription.Native,
    properties: types.SurfaceProperties,
};

const SwapchainData = struct {
    surface: Resource,
    images: []Resource,
    views: []Resource,
    properties: types.SwapchainProperties,
    next_image: u32 = 0,
};

const BufferData = struct {
    size: u64,
    usage: types.BufferUsage,
    memory: types.Memory,
    bytes: []u8,
    mapped_offset: ?u64 = null,
    mapped_size: ?u64 = null,
};

const TextureData = struct {
    properties: types.TextureProperties,
    bytes: []u8,
    layout: types.TextureLayout = .undefined,
};

const TextureViewData = struct {
    texture: Resource,
    format: types.Format,
    type: types.TextureType,
    aspect: types.TextureAspect,
    base_mip: u32,
    mip_count: u32,
    base_layer: u32,
    layer_count: u32,
};

const SamplerData = struct {};
const SemaphoreData = struct { signaled: bool = false };

const ShaderData = struct {
    stage: types.ShaderStage,
    entry_point: []u8,
};

const DescriptorSetLayoutData = struct {
    bindings: []types.DescriptorSetLayoutDescription
        .DescriptorBinding,
};

const PipelineLayoutData = struct {
    push_constants: []types.PipelineLayoutDescription.PushConstant,
    set_count: u32,
};

const DescriptorSetData = struct {
    layout: Resource,
};

const PipelineData = union(enum) {
    graphics: struct {
        layout: Resource,
        vertex_binding_count: u32,
    },
    compute: struct {
        layout: Resource,
    },
};

const CommandBufferData = struct {
    level: types.CommandBufferDescription.Level,
    state: State = .initial,
    in_rendering: bool = false,
    bind_point: ?types.BindPoint = null,
    vertex_binding_count: u32 = 0,
    pipeline_vertex_bindings: u32 = 0,
    index_buffer: ?Resource = null,
    viewport_set: bool = false,

    const State = enum {
        initial,
        recording,
        ended,
        submitted,
    };
};

const FenceData = struct {
    signaled: bool,
};

fn lookup(self: *Test, resource: Resource) ?*Slot {
    const index = resource.identifier.index;
    if (index >= self.slots.items.len) return null;
    const slot = if (self.slots.items[index]) |*value| value else return null;
    if (slot.generation != resource.identifier.generation) return null;
    if (slot.tag != resource.tag) return null;
    return slot;
}

fn fail(
    self: *Test,
    ret_addr: usize,
    comptime fmt: []const u8,
    args: anytype,
) Device.Error {
    self.error_count += 1;
    log.warn(fmt, args);
    log.warn("  called from 0x{x}", .{ret_addr});
    return error.InvalidDescription;
}

fn failResource(
    self: *Test,
    ret_addr: usize,
    resource: Resource,
) Device.Error {
    self.error_count += 1;
    log.warn(
        "invalid or stale resource: tag={s} index={d} gen={d}",
        .{
            @tagName(resource.tag),
            resource.identifier.index,
            resource.identifier.generation,
        },
    );
    log.warn("  called from 0x{x}", .{ret_addr});
    return error.InvalidResource;
}

fn require(
    self: *Test,
    resource: Resource,
    tag: Resource.Tag,
    ret_addr: usize,
) Device.Error!*Slot {
    const slot = self.lookup(resource) orelse
        return self.failResource(ret_addr, resource);
    if (slot.tag != tag) {
        self.error_count += 1;
        log.warn(
            "expected {s}, got {s}",
            .{ @tagName(tag), @tagName(slot.tag) },
        );
        log.warn("  called from 0x{x}", .{ret_addr});
        return error.InvalidResource;
    }
    return slot;
}

fn newSlot(
    self: *Test,
    tag: Resource.Tag,
    data: Slot.Data,
    dependencies: []const Resource,
    ret_addr: usize,
) Device.Error!Resource {
    var index: u32 = undefined;
    if (self.free_slots.pop()) |free_index| {
        index = free_index;
    } else {
        index = @intCast(self.slots.items.len);
        self.slots.append(
            self.allocator,
            null,
        ) catch return error.OutOfHostMemory;
        self.generations.append(self.allocator, 0) catch {
            _ = self.slots.pop();
            return error.OutOfHostMemory;
        };
    }

    const owned_dependencies = if (dependencies.len == 0)
        &.{}
    else
        self.allocator.dupe(
            Resource,
            dependencies,
        ) catch return error.OutOfHostMemory;

    const next_generation = self.generations.items[index] +% 1;
    const generation = if (next_generation == 0) 1 else next_generation;
    self.generations.items[index] = generation;

    self.slots.items[index] = .{
        .generation = generation,
        .tag = tag,
        .dependencies = owned_dependencies,
        .data = data,
    };
    self.live_count += 1;

    const resource: Resource = .{
        .identifier = .{
            .generation = generation,
            .index = index,
        },
        .tag = tag,
    };
    log.debug(
        "create {s} index={d} gen={d} (ret 0x{x})",
        .{ @tagName(tag), index, generation, ret_addr },
    );
    return resource;
}

fn releaseData(self: *Test, index: u32, slot: *const Slot) void {
    switch (slot.data) {
        .surface => {},
        .swapchain => |value| {
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .buffer => |value| self.allocator.free(value.bytes),
        .texture => |value| self.allocator.free(value.bytes),
        .texture_view => {},
        .sampler => {},
        .shader => |value| self.allocator.free(value.entry_point),
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            self.allocator.free(value.push_constants);
        },
        .descriptor_set => {},
        .pipeline => {},
        .command_buffer => {},
        .fence => {},
        .semaphore => {},
    }
    self.allocator.free(slot.dependencies);
    self.slots.items[index] = null;
    self.live_count -= 1;
    self.free_slots.append(
        self.allocator,
        index,
    ) catch |err| log.warn(
        "Cannot recycle slot {d}: {}",
        .{ index, err },
    );
}

fn hasDependent(self: *Test, resource: Resource) ?Resource {
    for (self.slots.items, 0..) |slot, index| {
        const value = slot orelse continue;
        for (value.dependencies) |dependency| {
            if (dependency.eql(resource)) {
                return .{
                    .identifier = .{
                        .generation = value.generation,
                        .index = @intCast(index),
                    },
                    .tag = value.tag,
                };
            }
        }
    }
    return null;
}

fn destroy(self: *Test, resource: Resource, ret_addr: usize) void {
    const slot = self.lookup(resource) orelse {
        self.error_count += 1;
        log.warn("destroy of stale handle (ret 0x{x})", .{ret_addr});
        return;
    };

    if (slot.data == .swapchain) {
        const value = slot.data.swapchain;
        for (value.views) |view| {
            if (self.lookup(view) != null) {
                self.forceRelease(view);
            }
        }
        for (value.images) |image| {
            if (self.lookup(image) != null) {
                self.forceRelease(image);
            }
        }
    }

    if (self.hasDependent(resource)) |dependent| {
        self.error_count += 1;
        log.warn(
            "cannot destroy {s}: {s} still depends on it",
            .{ @tagName(resource.tag), @tagName(dependent.tag) },
        );
        log.warn("  called from 0x{x}", .{ret_addr});
        return;
    }

    log.debug(
        "destroy {s} index={d} (ret 0x{x})",
        .{
            @tagName(resource.tag),
            resource.identifier.index,
            ret_addr,
        },
    );

    self.forceRelease(resource);
}

fn forceRelease(self: *Test, resource: Resource) void {
    const slot = self.lookup(resource) orelse return;
    self.releaseData(resource.identifier.index, slot);
}

fn create(
    self: *Test,
    description: Resource.Description,
    ret_addr: usize,
) Device.Error!Resource {
    return switch (description) {
        .surface => |value| self.createSurface(value, ret_addr),
        .swapchain => |value| self.createSwapchain(value, ret_addr),
        .buffer => |value| self.createBuffer(value, ret_addr),
        .texture => |value| self.createTexture(value, ret_addr),
        .texture_view => |value| self.createTextureView(value, ret_addr),
        .sampler => |value| self.createSampler(value, ret_addr),
        .shader => |value| self.createShader(value, ret_addr),
        .descriptor_set_layout => |value| {
            return self.createDescriptorSetLayout(value, ret_addr);
        },
        .pipeline_layout => |value| {
            return self.createPipelineLayout(value, ret_addr);
        },
        .descriptor_set => |value| {
            return self.createDescriptorSet(value, ret_addr);
        },
        .pipeline => |value| self.createPipeline(value, ret_addr),
        .command_buffer => |value| {
            return self.createCommandBuffer(value, ret_addr);
        },
        .fence => |value| self.createFence(value, ret_addr),
        .semaphore => |value| self.createSemaphore(value, ret_addr),
    };
}

fn createSurface(
    self: *Test,
    description: types.SurfaceDescription,
    ret_addr: usize,
) Device.Error!Resource {
    const properties: types.SurfaceProperties = switch (description.native) {
        .win32 => |value| blk: {
            if (value.hwnd == 0) {
                return self.fail(
                    ret_addr,
                    "win32 surface without hwnd",
                    .{},
                );
            }
            break :blk .{
                .min_width = 1,
                .min_height = 1,
                .max_width = 16384,
                .max_height = 16384,
                .current_width = 1280,
                .current_height = 720,
                .format_count = 1,
            };
        },
        .xlib => |value| blk: {
            if (value.display == 0 or value.window == 0) {
                return self.fail(
                    ret_addr,
                    "xlib surface without display or window",
                    .{},
                );
            }
            break :blk .{
                .min_width = 1,
                .min_height = 1,
                .max_width = 16384,
                .max_height = 16384,
                .current_width = 1280,
                .current_height = 720,
                .format_count = 1,
            };
        },
        .wayland => |value| blk: {
            if (value.display == 0 or value.surface == 0) {
                return self.fail(
                    ret_addr,
                    "wayland surface without display or surface",
                    .{},
                );
            }
            break :blk .{
                .min_width = 1,
                .min_height = 1,
                .max_width = 16384,
                .max_height = 16384,
                .current_width = 1280,
                .current_height = 720,
                .format_count = 1,
            };
        },
        .headless => |value| blk: {
            if (value.width == 0 or value.height == 0) {
                return self.fail(
                    ret_addr,
                    "headless surface without extent",
                    .{},
                );
            }
            break :blk .{
                .min_width = 1,
                .min_height = 1,
                .max_width = 16384,
                .max_height = 16384,
                .current_width = value.width,
                .current_height = value.height,
                .format_count = 1,
            };
        },
    };

    return try self.newSlot(
        .surface,
        .{ .surface = .{
            .native = description.native,
            .properties = properties,
        } },
        &.{},
        ret_addr,
    );
}

fn createSwapchain(
    self: *Test,
    description: types.SwapchainDescription,
    ret_addr: usize,
) Device.Error!Resource {
    const surface = try self.require(
        description.surface,
        .surface,
        ret_addr,
    );
    if (description.width == 0 or description.height == 0) {
        return self.fail(ret_addr, "empty swapchain extent", .{});
    }
    if (description.image_count == 0 or
        description.image_count > 8)
    {
        return self.fail(
            ret_addr,
            "swapchain image count must be 1..8",
            .{},
        );
    }

    const properties: types.SwapchainProperties = .{
        .width = description.width,
        .height = description.height,
        .format = description.format,
        .image_count = description.image_count,
    };

    const swapchain = try self.newSlot(
        .swapchain,
        .{ .swapchain = .{
            .surface = description.surface,
            .images = &.{},
            .views = &.{},
            .properties = properties,
        } },
        &.{description.surface},
        ret_addr,
    );
    errdefer self.forceRelease(swapchain);

    const images = self.allocator.alloc(
        Resource,
        description.image_count,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(images);
    const views = self.allocator.alloc(
        Resource,
        description.image_count,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(views);

    var image_created: u32 = 0;
    var view_created: u32 = 0;
    errdefer {
        var i = view_created;
        while (i > 0) {
            i -= 1;
            if (self.lookup(views[i]) != null) self.forceRelease(views[i]);
        }
        i = image_created;
        while (i > 0) {
            i -= 1;
            if (self.lookup(images[i]) != null) self.forceRelease(images[i]);
        }
    }

    for (0..description.image_count) |i| {
        const image = try self.newSlot(
            .texture,
            .{ .texture = .{
                .properties = .{
                    .type = .@"2d",
                    .format = description.format,
                    .width = description.width,
                    .height = description.height,
                    .depth = 1,
                    .mip_levels = 1,
                    .array_layers = 1,
                    .samples = 1,
                    .usage = .{
                        .color_attachment = true,
                        .transfer_src = true,
                    },
                },
                .bytes = blk: {
                    break :blk self.allocator.alloc(
                        u8,
                        0,
                    ) catch return error.OutOfHostMemory;
                },
            } },
            &.{swapchain},
            ret_addr,
        );
        images[i] = image;
        image_created += 1;
        const view = try self.newSlot(
            .texture_view,
            .{ .texture_view = .{
                .texture = image,
                .format = description.format,
                .type = .@"2d",
                .aspect = .color,
                .base_mip = 0,
                .mip_count = 1,
                .base_layer = 0,
                .layer_count = 1,
            } },
            &.{image},
            ret_addr,
        );
        views[i] = view;
        view_created += 1;
    }

    _ = surface;
    const slot = self.lookup(swapchain).?;
    slot.data.swapchain.images = images;
    slot.data.swapchain.views = views;
    return swapchain;
}

fn createBuffer(
    self: *Test,
    description: types.BufferDescription,
    ret_addr: usize,
) Device.Error!Resource {
    if (description.initial_data) |data| {
        if (data.len > description.size) {
            return self.fail(
                ret_addr,
                "initial buffer data exceeds buffer size",
                .{},
            );
        }
        if (!description.memory.host_visible and
            !description.usage.transfer_dst)
        {
            return self.fail(
                ret_addr,
                "initial data needs transfer destination usage",
                .{},
            );
        }
    }

    const bytes = self.allocator.alloc(
        u8,
        @intCast(description.size),
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(bytes);
    @memset(bytes, 0);
    if (description.initial_data) |data| {
        @memcpy(bytes[0..data.len], data);
    }

    return try self.newSlot(
        .buffer,
        .{ .buffer = .{
            .size = description.size,
            .usage = description.usage,
            .memory = description.memory,
            .bytes = bytes,
        } },
        &.{},
        ret_addr,
    );
}

fn textureBytes(
    self: *Test,
    description: types.TextureDescription,
) Device.Error![]u8 {
    const bpp = description.format.bytesPerPixel() orelse 0;
    const row = @as(u64, description.width) * bpp;
    const slice = row * @as(u64, description.height);
    const total = slice * @as(u64, description.depth);
    return self.allocator.alloc(
        u8,
        @intCast(total),
    ) catch return error.OutOfHostMemory;
}

fn createTexture(
    self: *Test,
    description: types.TextureDescription,
    ret_addr: usize,
) Device.Error!Resource {
    if (description.width == 0 or description.height == 0 or
        description.depth == 0)
    {
        return self.fail(ret_addr, "empty texture extent", .{});
    }
    if (description.format == .undefined) {
        return self.fail(ret_addr, "undefined texture format", .{});
    }
    if (description.mip_levels == 0 or
        description.array_layers == 0 or
        description.samples == 0)
    {
        return self.fail(
            ret_addr,
            "invalid texture mip, layer, or sample count",
            .{},
        );
    }

    if (description.initial_data != null and
        !description.usage.transfer_dst)
    {
        return self.fail(
            ret_addr,
            "initial texture data needs transfer destination usage",
            .{},
        );
    }
    const bytes = try self.textureBytes(description);
    errdefer self.allocator.free(bytes);
    @memset(bytes, 0);
    var layout: types.TextureLayout = .undefined;
    if (description.initial_data) |data| {
        if (data.bytes.len > bytes.len) {
            return self.fail(
                ret_addr,
                "initial texture data exceeds texture storage",
                .{},
            );
        }
        @memcpy(bytes[0..data.bytes.len], data.bytes);
        layout = switch (description.format.aspect()) {
            .color => .shader_read_only,
            .depth => .depth_read_only,
            .stencil => .stencil_read_only,
            .depth_stencil => .depth_stencil_read_only,
        };
    }

    return try self.newSlot(
        .texture,
        .{ .texture = .{
            .properties = .{
                .type = description.type,
                .format = description.format,
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
                .mip_levels = description.mip_levels,
                .array_layers = description.array_layers,
                .samples = description.samples,
                .usage = description.usage,
            },
            .bytes = bytes,
            .layout = layout,
        } },
        &.{},
        ret_addr,
    );
}

fn createTextureView(
    self: *Test,
    description: types.TextureViewDescription,
    ret_addr: usize,
) Device.Error!Resource {
    const texture = try self.require(
        description.texture,
        .texture,
        ret_addr,
    );
    const properties = texture.data.texture.properties;

    const mip_count = if (description.mip_count == 0)
        properties.mip_levels - description.base_mip
    else
        description.mip_count;
    const layer_count = if (description.layer_count == 0)
        properties.array_layers - description.base_layer
    else
        description.layer_count;

    if (description.base_mip >= properties.mip_levels or
        mip_count == 0 or
        description.base_mip + mip_count > properties.mip_levels)
    {
        return self.fail(
            ret_addr,
            "texture view mip range is out of bounds",
            .{},
        );
    }
    if (description.base_layer >= properties.array_layers or
        layer_count == 0 or
        description.base_layer + layer_count >
            properties.array_layers)
    {
        return self.fail(
            ret_addr,
            "texture view layer range is out of bounds",
            .{},
        );
    }

    return try self.newSlot(
        .texture_view,
        .{ .texture_view = .{
            .texture = description.texture,
            .format = description.format orelse properties.format,
            .type = description.type orelse properties.type,
            .aspect = description.aspect orelse
                properties.format.aspect(),
            .base_mip = description.base_mip,
            .mip_count = mip_count,
            .base_layer = description.base_layer,
            .layer_count = layer_count,
        } },
        &.{description.texture},
        ret_addr,
    );
}

fn createSampler(
    self: *Test,
    description: types.SamplerDescription,
    ret_addr: usize,
) Device.Error!Resource {
    if (description.lod_min > description.lod_max) {
        return self.fail(ret_addr, "invalid sampler lod range", .{});
    }
    if (description.anisotropy > 16) {
        return self.fail(
            ret_addr,
            "anisotropy exceeds the test device limit",
            .{},
        );
    }
    return try self.newSlot(
        .sampler,
        .{ .sampler = .{} },
        &.{},
        ret_addr,
    );
}

fn createShader(
    self: *Test,
    description: types.ShaderDescription,
    ret_addr: usize,
) Device.Error!Resource {
    if (description.code.len == 0) {
        return self.fail(ret_addr, "empty shader code", .{});
    }
    const entry_point = self.allocator.dupe(
        u8,
        description.entry_point,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(entry_point);

    return try self.newSlot(
        .shader,
        .{ .shader = .{
            .stage = description.stage,
            .entry_point = entry_point,
        } },
        &.{},
        ret_addr,
    );
}

fn createDescriptorSetLayout(
    self: *Test,
    description: types.DescriptorSetLayoutDescription,
    ret_addr: usize,
) Device.Error!Resource {
    if (description.bindings.len == 0) {
        return self.fail(ret_addr, "empty descriptor set layout", .{});
    }
    var seen: [64]u32 = undefined;
    if (description.bindings.len > seen.len) {
        return self.fail(
            ret_addr,
            "too many descriptor bindings for the test backend",
            .{},
        );
    }
    for (description.bindings, 0..) |binding, i| {
        if (binding.count == 0) {
            return self.fail(
                ret_addr,
                "descriptor binding with zero count",
                .{},
            );
        }
        for (seen[0..i]) |other| {
            if (other == binding.binding) {
                return self.fail(
                    ret_addr,
                    "duplicate descriptor binding {d}",
                    .{binding.binding},
                );
            }
        }
        seen[i] = binding.binding;
    }

    const bindings = self.allocator.dupe(
        types.DescriptorSetLayoutDescription.DescriptorBinding,
        description.bindings,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(bindings);

    return try self.newSlot(
        .descriptor_set_layout,
        .{ .descriptor_set_layout = .{ .bindings = bindings } },
        &.{},
        ret_addr,
    );
}

fn createPipelineLayout(
    self: *Test,
    description: types.PipelineLayoutDescription,
    ret_addr: usize,
) Device.Error!Resource {
    for (description.descriptor_sets) |set| {
        _ = try self.require(set, .descriptor_set_layout, ret_addr);
    }
    for (description.push_constants, 0..) |range, i| {
        if (range.size == 0 or range.offset + range.size > 256) {
            return self.fail(
                ret_addr,
                "invalid push constant range",
                .{},
            );
        }
        for (description.push_constants[0..i]) |other| {
            const end = other.offset + other.size;
            if (range.offset < end and
                other.offset < range.offset + range.size)
            {
                return self.fail(
                    ret_addr,
                    "overlapping push constant ranges",
                    .{},
                );
            }
        }
    }

    const push_constants = self.allocator.dupe(
        types.PipelineLayoutDescription.PushConstant,
        description.push_constants,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(push_constants);

    return try self.newSlot(
        .pipeline_layout,
        .{ .pipeline_layout = .{
            .push_constants = push_constants,
            .set_count = @intCast(description.descriptor_sets.len),
        } },
        description.descriptor_sets,
        ret_addr,
    );
}

fn createDescriptorSet(
    self: *Test,
    description: types.DescriptorSetDescription,
    ret_addr: usize,
) Device.Error!Resource {
    _ = try self.require(
        description.layout,
        .descriptor_set_layout,
        ret_addr,
    );
    return try self.newSlot(
        .descriptor_set,
        .{ .descriptor_set = .{ .layout = description.layout } },
        &.{description.layout},
        ret_addr,
    );
}

fn createPipeline(
    self: *Test,
    description: types.PipelineDescription,
    ret_addr: usize,
) Device.Error!Resource {
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
    self: *Test,
    description: types.GraphicsPipelineDescription,
    ret_addr: usize,
) Device.Error!Resource {
    _ = try self.require(description.layout, .pipeline_layout, ret_addr);

    const vertex = try self.require(description.vertex, .shader, ret_addr);
    if (vertex.data.shader.stage != .vertex) {
        return self.fail(
            ret_addr,
            "graphics pipeline vertex shader is not a vertex shader",
            .{},
        );
    }
    if (description.fragment) |fragment_resource| {
        const fragment = try self.require(
            fragment_resource,
            .shader,
            ret_addr,
        );
        if (fragment.data.shader.stage != .fragment) {
            return self.fail(
                ret_addr,
                "graphics pipeline fragment shader is not a fragment shader",
                .{},
            );
        }
    }
    if (description.color_formats.len == 0 and
        description.depth_format == null)
    {
        return self.fail(
            ret_addr,
            "graphics pipeline without color or depth target",
            .{},
        );
    }
    if (description.samples == 0 or description.samples > 64 or
        !std.math.isPowerOfTwo(description.samples))
    {
        return self.fail(
            ret_addr,
            "invalid graphics pipeline sample count",
            .{},
        );
    }

    var max_binding: u32 = 0;
    for (description.vertex_layout.bindings) |binding| {
        max_binding = @max(max_binding, binding.binding + 1);
    }

    const dependencies = self.allocator.alloc(
        Resource,
        if (description.fragment == null) 2 else 3,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(dependencies);
    dependencies[0] = description.layout;
    dependencies[1] = description.vertex;
    var count: usize = 2;
    if (description.fragment) |fragment| {
        dependencies[count] = fragment;
        count += 1;
    }

    const resource = try self.newSlot(
        .pipeline,
        .{ .pipeline = .{ .graphics = .{
            .layout = description.layout,
            .vertex_binding_count = max_binding,
        } } },
        dependencies[0..count],
        ret_addr,
    );
    self.allocator.free(dependencies);
    return resource;
}

fn createComputePipeline(
    self: *Test,
    description: types.ComputePipelineDescription,
    ret_addr: usize,
) Device.Error!Resource {
    _ = try self.require(description.layout, .pipeline_layout, ret_addr);
    const shader = try self.require(description.shader, .shader, ret_addr);
    if (shader.data.shader.stage != .compute) {
        return self.fail(
            ret_addr,
            "compute pipeline shader is not a compute shader",
            .{},
        );
    }

    return try self.newSlot(
        .pipeline,
        .{ .pipeline = .{ .compute = .{
            .layout = description.layout,
        } } },
        &.{ description.layout, description.shader },
        ret_addr,
    );
}

fn createCommandBuffer(
    self: *Test,
    description: types.CommandBufferDescription,
    ret_addr: usize,
) Device.Error!Resource {
    return try self.newSlot(
        .command_buffer,
        .{ .command_buffer = .{ .level = description.level } },
        &.{},
        ret_addr,
    );
}

fn createFence(
    self: *Test,
    description: types.FenceDescription,
    ret_addr: usize,
) Device.Error!Resource {
    return try self.newSlot(
        .fence,
        .{ .fence = .{ .signaled = description.signaled } },
        &.{},
        ret_addr,
    );
}

fn createSemaphore(
    self: *Test,
    description: types.SemaphoreDescription,
    ret_addr: usize,
) Device.Error!Resource {
    _ = description;
    return try self.newSlot(
        .semaphore,
        .{ .semaphore = .{} },
        &.{},
        ret_addr,
    );
}

fn createBatch(
    self: *Test,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Device.Error!void {
    if (descriptions.len != resources.len) {
        return self.fail(
            ret_addr,
            "createBatch length mismatch",
            .{},
        );
    }
    var created: usize = 0;
    errdefer {
        var i = created;
        while (i > 0) {
            i -= 1;
            self.forceRelease(resources[i]);
        }
    }
    for (descriptions, 0..) |description, i| {
        resources[i] = try self.create(description, ret_addr);
        created += 1;
    }
}

fn destroyBatch(
    self: *Test,
    resources: []const Resource,
    ret_addr: usize,
) void {
    for (resources) |resource| {
        self.destroy(resource, ret_addr);
    }
}

fn map(
    self: *Test,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Device.Error![]u8 {
    const slot = try self.require(resource, .buffer, ret_addr);
    const buffer = &slot.data.buffer;
    if (!buffer.memory.host_visible) {
        self.error_count += 1;
        log.warn("buffer is not host visible (ret 0x{x})", .{ret_addr});
        return error.Unsupported;
    }
    if (buffer.mapped_offset != null) {
        self.error_count += 1;
        log.warn("buffer is already mapped (ret 0x{x})", .{ret_addr});
        return error.InvalidResource;
    }
    if (offset > buffer.size or size > buffer.size - offset) {
        return self.fail(ret_addr, "map range is out of bounds", .{});
    }
    buffer.mapped_offset = offset;
    buffer.mapped_size = size;
    return buffer.bytes[@intCast(offset)..][0..@intCast(size)];
}

fn unmap(
    self: *Test,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    const slot = self.lookup(resource) orelse {
        self.error_count += 1;
        log.warn("unmap of stale buffer (ret 0x{x})", .{ret_addr});
        return;
    };
    if (slot.tag != .buffer) {
        self.error_count += 1;
        log.warn("unmap of non buffer resource (ret 0x{x})", .{ret_addr});
        return;
    }
    const buffer = &slot.data.buffer;
    if (buffer.mapped_offset == null) {
        self.error_count += 1;
        log.warn("unmap of unmapped buffer (ret 0x{x})", .{ret_addr});
        return;
    }
    const mapped_offset = buffer.mapped_offset.?;
    const mapped_size = buffer.mapped_size.?;
    for (dirty) |range| {
        if (range.offset < mapped_offset or
            range.size > mapped_size or
            range.offset - mapped_offset > mapped_size - range.size)
        {
            self.error_count += 1;
            log.warn(
                "dirty range outside the mapped range (ret 0x{x})",
                .{ret_addr},
            );
        }
    }
    buffer.mapped_offset = null;
    buffer.mapped_size = null;
    log.debug(
        "unmap buffer index={d} dirty={d} (ret 0x{x})",
        .{
            resource.identifier.index,
            dirty.len,
            ret_addr,
        },
    );
}

fn getQueue(
    self: *Test,
    index: u32,
    ret_addr: usize,
) Device.Error!Queue {
    if (index >= self.queues.len) {
        self.error_count += 1;
        log.warn("queue index {d} does not exist", .{index});
        log.warn("  called from 0x{x}", .{ret_addr});
        return error.Unsupported;
    }
    const info = self.queues[index];
    return .{
        .vptr = self,
        .vtable = &queue_vtable,
        .family_index = info.family_index,
        .queue_index = info.queue_index,
    };
}

fn record(
    self: *Test,
    resource: Resource,
    command: rhi.Command,
    ret_addr: usize,
) Device.Error!void {
    const slot = try self.require(
        resource,
        .command_buffer,
        ret_addr,
    );
    const command_buffer = &slot.data.command_buffer;

    switch (command) {
        .begin => {
            command_buffer.state = .recording;
            command_buffer.in_rendering = false;
            command_buffer.bind_point = null;
            command_buffer.vertex_binding_count = 0;
            command_buffer.pipeline_vertex_bindings = 0;
            command_buffer.index_buffer = null;
            command_buffer.viewport_set = false;
        },
        .end => {
            if (command_buffer.state != .recording) {
                return self.fail(
                    ret_addr,
                    "end without begin",
                    .{},
                );
            }
            if (command_buffer.in_rendering) {
                return self.fail(
                    ret_addr,
                    "end while rendering",
                    .{},
                );
            }
            command_buffer.state = .ended;
        },
        .begin_rendering => |value| {
            if (command_buffer.state != .recording) {
                return self.fail(
                    ret_addr,
                    "beginRendering outside recording",
                    .{},
                );
            }
            if (command_buffer.in_rendering) {
                return self.fail(
                    ret_addr,
                    "nested render pass",
                    .{},
                );
            }
            if (value.area.width == 0 or value.area.height == 0) {
                return self.fail(ret_addr, "empty render area", .{});
            }
            for (value.color_attachments) |attachment| {
                _ = try self.require(
                    attachment.view,
                    .texture_view,
                    ret_addr,
                );
            }
            if (value.depth_attachment) |attachment| {
                _ = try self.require(
                    attachment.view,
                    .texture_view,
                    ret_addr,
                );
            }
            command_buffer.in_rendering = true;
        },
        .end_rendering => {
            if (!command_buffer.in_rendering) {
                return self.fail(
                    ret_addr,
                    "endRendering without beginRendering",
                    .{},
                );
            }
            command_buffer.in_rendering = false;
        },
        .bind_pipeline => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            const pipeline = try self.require(
                value.pipeline,
                .pipeline,
                ret_addr,
            );
            command_buffer.bind_point = switch (pipeline.data.pipeline) {
                .graphics => .graphics,
                .compute => .compute,
            };
            if (pipeline.data.pipeline == .graphics) {
                command_buffer.vertex_binding_count = 0;
                command_buffer.pipeline_vertex_bindings =
                    pipeline.data.pipeline.graphics.vertex_binding_count;
                command_buffer.index_buffer = null;
            }
        },
        .bind_vertex_buffers => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            if (value.offsets.len != 0 and
                value.offsets.len != value.buffers.len)
            {
                return self.fail(
                    ret_addr,
                    "vertex buffer offset count mismatch",
                    .{},
                );
            }
            for (value.buffers) |buffer| {
                const buffer_slot = try self.require(
                    buffer,
                    .buffer,
                    ret_addr,
                );
                if (!buffer_slot.data.buffer.usage.vertex) {
                    return self.fail(
                        ret_addr,
                        "buffer is not a vertex buffer",
                        .{},
                    );
                }
            }
            command_buffer.vertex_binding_count = @intCast(
                value.first_binding + value.buffers.len,
            );
        },
        .bind_index_buffer => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            const buffer = try self.require(
                value.buffer,
                .buffer,
                ret_addr,
            );
            if (!buffer.data.buffer.usage.index) {
                return self.fail(
                    ret_addr,
                    "buffer is not an index buffer",
                    .{},
                );
            }
            command_buffer.index_buffer = value.buffer;
        },
        .bind_descriptor_sets => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            _ = try self.require(
                value.layout,
                .pipeline_layout,
                ret_addr,
            );
            for (value.sets) |set| {
                _ = try self.require(
                    set,
                    .descriptor_set,
                    ret_addr,
                );
            }
        },
        .set_viewport => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            if (value.width <= 0 or value.height <= 0) {
                return self.fail(ret_addr, "empty viewport", .{});
            }
            command_buffer.viewport_set = true;
        },
        .set_scissor => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            if (value.width == 0 or value.height == 0) {
                return self.fail(ret_addr, "empty scissor", .{});
            }
        },
        .draw => |value| {
            try self.requireDraw(
                command_buffer,
                ret_addr,
            );
            if (value.vertex_count == 0) {
                return self.fail(ret_addr, "empty draw", .{});
            }
            if (!command_buffer.viewport_set) {
                return self.fail(
                    ret_addr,
                    "draw without viewport",
                    .{},
                );
            }
        },
        .draw_indexed => |value| {
            try self.requireDraw(
                command_buffer,
                ret_addr,
            );
            if (value.index_count == 0) {
                return self.fail(
                    ret_addr,
                    "empty indexed draw",
                    .{},
                );
            }
            if (command_buffer.index_buffer == null) {
                return self.fail(
                    ret_addr,
                    "indexed draw without index buffer",
                    .{},
                );
            }
        },
        .dispatch => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            if (command_buffer.bind_point != .compute) {
                return self.fail(
                    ret_addr,
                    "dispatch without compute pipeline",
                    .{},
                );
            }
            if (value.x == 0 or value.y == 0 or value.z == 0) {
                return self.fail(ret_addr, "empty dispatch", .{});
            }
        },
        .copy_buffer => |value| {
            try self.validateBufferCopy(value, ret_addr);
        },
        .copy_buffer_to_texture => |value| {
            try self.validateBufferTextureCopy(
                value.buffer,
                value.texture,
                value.region,
                ret_addr,
            );
        },
        .copy_texture_to_buffer => |value| {
            try self.validateBufferTextureCopy(
                value.buffer,
                value.texture,
                value.region,
                ret_addr,
            );
        },
        .copy_texture => |value| {
            _ = try self.require(value.src, .texture, ret_addr);
            _ = try self.require(value.dst, .texture, ret_addr);
            for (value.regions) |region| {
                if (region.extent.width == 0 or
                    region.extent.height == 0 or
                    region.extent.depth == 0)
                {
                    return self.fail(
                        ret_addr,
                        "empty texture copy region",
                        .{},
                    );
                }
            }
        },
        .barrier => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            const barrier_slot = self.lookup(value.resource) orelse
                return self.failResource(ret_addr, value.resource);
            switch (barrier_slot.data) {
                .texture => |*texture| {
                    if (texture.layout != value.layout_before) {
                        return self.fail(
                            ret_addr,
                            "texture layout mismatch: expected {s}, got {s}",
                            .{
                                @tagName(texture.layout),
                                @tagName(value.layout_before),
                            },
                        );
                    }
                    texture.layout = value.layout_after;
                },
                .buffer => {},
                else => {
                    self.error_count += 1;
                    log.warn(
                        "barrier on unsupported resource {s}",
                        .{@tagName(barrier_slot.tag)},
                    );
                    return error.InvalidResource;
                },
            }
        },
        .push_constants => |value| {
            _ = try self.requireRecording(
                command_buffer,
                ret_addr,
            );
            _ = try self.require(
                value.layout,
                .pipeline_layout,
                ret_addr,
            );
            if (value.data.len == 0 or value.data.len > 256) {
                return self.fail(
                    ret_addr,
                    "invalid push constant size",
                    .{},
                );
            }
        },
    }
}

fn requireRecording(
    self: *Test,
    command_buffer: *CommandBufferData,
    ret_addr: usize,
) Device.Error!void {
    if (command_buffer.state != .recording) {
        return self.fail(
            ret_addr,
            "command requires a recording command buffer",
            .{},
        );
    }
}

fn requireDraw(
    self: *Test,
    command_buffer: *CommandBufferData,
    ret_addr: usize,
) Device.Error!void {
    try self.requireRecording(command_buffer, ret_addr);
    if (!command_buffer.in_rendering) {
        return self.fail(ret_addr, "draw outside render pass", .{});
    }
    if (command_buffer.bind_point != .graphics) {
        return self.fail(
            ret_addr,
            "draw without graphics pipeline",
            .{},
        );
    }
    if (command_buffer.vertex_binding_count <
        command_buffer.pipeline_vertex_bindings)
    {
        return self.fail(
            ret_addr,
            "draw without required vertex buffers",
            .{},
        );
    }
}

fn validateBufferCopy(
    self: *Test,
    description: commands.CopyBuffer,
    ret_addr: usize,
) Device.Error!void {
    const src = try self.require(description.src, .buffer, ret_addr);
    const dst = try self.require(description.dst, .buffer, ret_addr);
    if (!src.data.buffer.usage.transfer_src and
        !src.data.buffer.usage.transfer_dst)
    {
        return self.fail(
            ret_addr,
            "source buffer lacks transfer usage",
            .{},
        );
    }
    if (!dst.data.buffer.usage.transfer_dst) {
        return self.fail(
            ret_addr,
            "destination buffer lacks transfer destination usage",
            .{},
        );
    }
    for (description.regions) |region| {
        if (region.size == 0) {
            return self.fail(ret_addr, "empty buffer copy region", .{});
        }
        if (region.src_offset > src.data.buffer.size or
            region.size > src.data.buffer.size - region.src_offset)
        {
            return self.fail(
                ret_addr,
                "buffer copy source range out of bounds",
                .{},
            );
        }
        if (region.dst_offset > dst.data.buffer.size or
            region.size > dst.data.buffer.size - region.dst_offset)
        {
            return self.fail(
                ret_addr,
                "buffer copy destination range out of bounds",
                .{},
            );
        }
    }
}

fn validateBufferTextureCopy(
    self: *Test,
    buffer: Resource,
    texture: Resource,
    region: commands.TextureCopyRegion,
    ret_addr: usize,
) Device.Error!void {
    const buffer_slot = try self.require(buffer, .buffer, ret_addr);
    const texture_slot = try self.require(texture, .texture, ret_addr);
    if (region.extent.width == 0 or
        region.extent.height == 0 or
        region.extent.depth == 0)
    {
        return self.fail(ret_addr, "empty texture copy region", .{});
    }
    const properties = texture_slot.data.texture.properties;
    if (region.mip_level >= properties.mip_levels) {
        return self.fail(ret_addr, "copy mip level out of bounds", .{});
    }
    if (region.array_layer >= properties.array_layers) {
        return self.fail(ret_addr, "copy array layer out of bounds", .{});
    }
    if (buffer_slot.data.buffer.size == 0) {
        return self.fail(ret_addr, "copy with empty buffer", .{});
    }
}

fn deviceOpi(
    self: *Test,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!?[]const u8 {
    _ = output_mode;
    return switch (operator) {
        .wait_idle => blk: {
            log.debug("device wait idle (ret 0x{x})", .{ret_addr});
            break :blk null;
        },
        .wait_fence => |value| blk: {
            const slot = try self.require(
                value.fence,
                .fence,
                ret_addr,
            );
            if (!slot.data.fence.signaled) {
                self.error_count += 1;
                log.warn("fence wait timed out (ret 0x{x})", .{ret_addr});
                return error.Timeout;
            }
            break :blk null;
        },
        .reset_fence => |value| blk: {
            const slot = try self.require(
                value.fence,
                .fence,
                ret_addr,
            );
            slot.data.fence.signaled = false;
            break :blk null;
        },
        .write_descriptor_set => |value| blk: {
            try self.writeDescriptorSet(value, ret_addr);
            break :blk null;
        },
    };
}

fn writeDescriptorSet(
    self: *Test,
    description: anytype,
    ret_addr: usize,
) Device.Error!void {
    const set = try self.require(
        description.set,
        .descriptor_set,
        ret_addr,
    );
    const layout_resource = set.data.descriptor_set.layout;
    const layout = try self.require(
        layout_resource,
        .descriptor_set_layout,
        ret_addr,
    );

    for (description.writes) |write| {
        var found = false;
        for (layout.data.descriptor_set_layout.bindings) |binding| {
            if (binding.binding != write.binding) continue;
            found = true;
            if (write.array_index >= binding.count) {
                return self.fail(
                    ret_addr,
                    "descriptor array index out of bounds",
                    .{},
                );
            }
            switch (write.kind) {
                .buffer => |value| {
                    if (binding.kind != .uniform_buffer and
                        binding.kind != .storage_buffer)
                    {
                        return self.fail(
                            ret_addr,
                            "buffer write to non buffer binding",
                            .{},
                        );
                    }
                    const buffer = try self.require(
                        value.buffer,
                        .buffer,
                        ret_addr,
                    );
                    const size = if (value.size == 0)
                        buffer.data.buffer.size
                    else
                        value.size;
                    if (value.offset > buffer.data.buffer.size or
                        size > buffer.data.buffer.size - value.offset)
                    {
                        return self.fail(
                            ret_addr,
                            "descriptor buffer range out of bounds",
                            .{},
                        );
                    }
                },
                .texture => |value| {
                    if (binding.kind != .sampled_texture and
                        binding.kind != .storage_texture and
                        binding.kind != .combined_image_sampler)
                    {
                        return self.fail(
                            ret_addr,
                            "texture write to non texture binding",
                            .{},
                        );
                    }
                    _ = try self.require(
                        value.view,
                        .texture_view,
                        ret_addr,
                    );
                    if (binding.kind == .combined_image_sampler and
                        value.sampler == null)
                    {
                        return self.fail(
                            ret_addr,
                            "combined image sampler needs a sampler",
                            .{},
                        );
                    }
                    if (value.sampler) |sampler| {
                        _ = try self.require(
                            sampler,
                            .sampler,
                            ret_addr,
                        );
                    }
                },
                .sampler => |value| {
                    if (binding.kind != .sampler) {
                        return self.fail(
                            ret_addr,
                            "sampler write to non sampler binding",
                            .{},
                        );
                    }
                    _ = try self.require(value, .sampler, ret_addr);
                },
            }
        }
        if (!found) {
            return self.fail(
                ret_addr,
                "descriptor binding {d} does not exist",
                .{write.binding},
            );
        }
    }
}

fn query(
    self: *Test,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    return switch (feature) {
        .api_version => self.queryFixed(
            rhi.Version.api_1_3,
            output_mode,
        ),
        .device_name => self.queryString(
            "vfrhi test backend",
            output_mode,
        ),
        .driver_name => self.queryString(
            "vfrhi test driver",
            output_mode,
        ),
        .device_type => self.queryFixed(
            Device.DeviceType.cpu,
            output_mode,
        ),
        .limit => |limit| self.queryFixed(
            limitValue(limit),
            output_mode,
        ),
        .format => |value| self.queryFormat(value, output_mode),
        .surface => self.querySurface(handle, output_mode, ret_addr),
        .swapchain => self.querySwapchain(
            handle,
            output_mode,
            ret_addr,
        ),
        .swapchain_images => self.querySwapchainImages(
            handle,
            output_mode,
            ret_addr,
        ),
        .swapchain_views => self.querySwapchainViews(
            handle,
            output_mode,
            ret_addr,
        ),
        .buffer => self.queryBuffer(handle, output_mode, ret_addr),
        .texture => self.queryTexture(handle, output_mode, ret_addr),
        .memory => self.queryMemory(feature_index, output_mode),
        .queue => self.queryQueue(feature_index, output_mode),
    };
}

fn queryFixed(
    self: *Test,
    value: anytype,
    output_mode: ?Device.OutputMode,
) Device.Error!Device.QueryResult {
    _ = self;
    const bytes = std.mem.asBytes(&value);
    const result = try writeOutput(output_mode, bytes);
    return .{ .support = .support, .result = result };
}

fn queryString(
    self: *Test,
    value: []const u8,
    output_mode: ?Device.OutputMode,
) Device.Error!Device.QueryResult {
    _ = self;
    const result = try writeOutput(output_mode, value);
    return .{ .support = .support, .result = result };
}

fn queryFormat(
    self: *Test,
    value: anytype,
    output_mode: ?Device.OutputMode,
) Device.Error!Device.QueryResult {
    _ = self;
    _ = output_mode;
    if (value.format == .undefined) {
        return .{ .support = .unsupport };
    }
    const props = formatProperties(value.format);
    const usage = value.usage;
    const supported =
        (!usage.sampled or props.sampled) and
        (!usage.storage or props.storage) and
        (!usage.color_attachment or props.color_attachment) and
        (!usage.depth_attachment or props.depth_attachment) and
        (!usage.buffer or props.buffer);
    return .{
        .support = if (supported) .support else .unsupport,
    };
}

fn querySurface(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "surface query without handle", .{});
    const slot = try self.require(resource, .surface, ret_addr);
    const bytes = std.mem.asBytes(&slot.data.surface.properties);
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn querySwapchain(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "swapchain query without handle", .{});
    const slot = try self.require(resource, .swapchain, ret_addr);
    const bytes = std.mem.asBytes(&slot.data.swapchain.properties);
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn querySwapchainImages(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "image list without handle", .{});
    const slot = try self.require(resource, .swapchain, ret_addr);
    const mode = output_mode orelse
        return self.fail(ret_addr, "image list without output", .{});
    return writeResourceList(
        mode,
        slot.data.swapchain.images,
    );
}

fn querySwapchainViews(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "view list without handle", .{});
    const slot = try self.require(resource, .swapchain, ret_addr);
    const mode = output_mode orelse
        return self.fail(ret_addr, "view list without output", .{});
    return writeResourceList(
        mode,
        slot.data.swapchain.views,
    );
}

fn queryBuffer(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "buffer query without handle", .{});
    const slot = try self.require(resource, .buffer, ret_addr);
    const properties: types.BufferProperties = .{
        .size = slot.data.buffer.size,
        .memory = slot.data.buffer.memory,
    };
    const bytes = std.mem.asBytes(&properties);
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn queryTexture(
    self: *Test,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    const resource = handle orelse
        return self.fail(ret_addr, "texture query without handle", .{});
    const slot = try self.require(resource, .texture, ret_addr);
    const bytes = std.mem.asBytes(
        &slot.data.texture.properties,
    );
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn queryMemory(
    self: *Test,
    index: u32,
    output_mode: ?Device.OutputMode,
) Device.Error!Device.QueryResult {
    _ = self;
    const heap: types.MemoryHeap = switch (index) {
        0 => .{
            .size = 8 * 1024 * 1024 * 1024,
            .device_local = true,
        },
        1 => .{
            .size = 2 * 1024 * 1024 * 1024,
            .device_local = false,
        },
        else => return .{ .support = .unsupport },
    };
    const bytes = std.mem.asBytes(&heap);
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn queryQueue(
    self: *Test,
    index: u32,
    output_mode: ?Device.OutputMode,
) Device.Error!Device.QueryResult {
    if (index >= self.queues.len) {
        return .{ .support = .unsupport };
    }
    const properties: types.QueueProperties = .{
        .capabilities = self.queues[index].capabilities,
        .count = 1,
        .timestamp_bits = 64,
    };
    const bytes = std.mem.asBytes(&properties);
    return .{
        .support = .support,
        .result = try writeOutput(output_mode, bytes),
    };
}

fn limitValue(limit: Device.Limit) u64 {
    return switch (limit) {
        .max_texture_dimension_1d => 16384,
        .max_texture_dimension_2d => 16384,
        .max_texture_dimension_3d => 2048,
        .max_texture_array_layers => 2048,
        .max_buffer_size => 8 * 1024 * 1024 * 1024,
        .max_uniform_buffer_range => 65536,
        .max_storage_buffer_range => 1024 * 1024 * 1024,
        .max_push_constant_size => 256,
        .max_vertex_bindings => 16,
        .max_vertex_attributes => 32,
        .max_descriptor_sets => 4096,
        .max_color_attachments => 8,
    };
}

fn formatProperties(format: types.Format) types.FormatProperties {
    return switch (format) {
        .undefined => .{},
        .d32_float, .d24_unorm_s8_uint => .{
            .sampled = true,
            .depth_attachment = true,
        },
        else => .{
            .sampled = true,
            .storage = true,
            .color_attachment = true,
            .buffer = true,
        },
    };
}

fn writeOutput(
    output_mode: ?Device.OutputMode,
    bytes: []const u8,
) Device.Error!?[]const u8 {
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

fn writeResourceList(
    output_mode: Device.OutputMode,
    resources: []const Resource,
) Device.Error!Device.QueryResult {
    return switch (output_mode) {
        .slice => |slice| blk: {
            const bytes = std.mem.sliceAsBytes(resources);
            if (slice.len < bytes.len) return error.BufferTooSmall;
            @memcpy(slice[0..bytes.len], bytes);
            break :blk .{
                .support = .support,
                .result = slice[0..bytes.len],
            };
        },
        .allocator => error.Unsupported,
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

fn backend(vptr: *anyopaque) *Test {
    return @ptrCast(@alignCast(vptr));
}

fn deviceCreate(
    vptr: *anyopaque,
    description: Resource.Description,
    ret_addr: usize,
) Device.Error!Resource {
    return backend(vptr).create(description, ret_addr);
}

fn deviceDestroy(
    vptr: *anyopaque,
    resource: Resource,
    ret_addr: usize,
) void {
    backend(vptr).destroy(resource, ret_addr);
}

fn deviceCreateBatch(
    vptr: *anyopaque,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Device.Error!void {
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
    backend(vptr).destroyBatch(resources, ret_addr);
}

fn deviceMap(
    vptr: *anyopaque,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Device.Error![]u8 {
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
) Device.Error!Queue {
    return backend(vptr).getQueue(index, ret_addr);
}

fn deviceRecord(
    vptr: *anyopaque,
    resource: Resource,
    command: rhi.Command,
    ret_addr: usize,
) Device.Error!void {
    return backend(vptr).record(resource, command, ret_addr);
}

fn deviceOp(
    vptr: *anyopaque,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!?[]const u8 {
    return backend(vptr).deviceOpi(operator, output_mode, ret_addr);
}

fn deviceQuery(
    vptr: *anyopaque,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Device.Error!Device.QueryResult {
    return backend(vptr).query(
        feature,
        feature_index,
        handle,
        output_mode,
        ret_addr,
    );
}

fn queueIndex(vptr: *anyopaque, family: u32, index: u32) ?*Test {
    const self = backend(vptr);
    for (self.queues) |queue| {
        if (queue.family_index == family and queue.queue_index == index) {
            return self;
        }
    }
    return null;
}

fn queueAcquire(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Acquire,
    ret_addr: usize,
) Device.Error!Queue.Acquired {
    const self = queueIndex(vptr, family_index, queue_index) orelse {
        return error.InvalidResource;
    };
    const slot = try self.require(
        description.swapchain,
        .swapchain,
        ret_addr,
    );
    const swapchain = &slot.data.swapchain;
    if (description.semaphore) |semaphore| {
        const semaphore_slot = try self.require(
            semaphore,
            .semaphore,
            ret_addr,
        );
        semaphore_slot.data.semaphore.signaled = true;
    }
    if (description.fence) |fence| {
        const fence_slot = try self.require(fence, .fence, ret_addr);
        fence_slot.data.fence.signaled = true;
    }
    const image_index = swapchain.next_image % swapchain.properties.image_count;
    swapchain.next_image +%= 1;
    return .{ .image_index = image_index };
}

fn queueSubmit(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    submission: Queue.Submission,
    ret_addr: usize,
) Device.Error!void {
    const self = queueIndex(vptr, family_index, queue_index) orelse {
        return error.InvalidResource;
    };
    for (submission.command_buffers) |command_buffer| {
        const slot = try self.require(
            command_buffer,
            .command_buffer,
            ret_addr,
        );
        if (slot.data.command_buffer.state != .ended) {
            self.error_count += 1;
            log.warn(
                "submit of a command buffer that is not ended",
                .{},
            );
            log.warn("  called from 0x{x}", .{ret_addr});
            return error.InvalidResource;
        }
    }
    for (submission.wait_semaphores) |semaphore| {
        _ = try self.require(semaphore, .semaphore, ret_addr);
    }
    for (submission.signal_semaphores) |semaphore| {
        const slot = try self.require(semaphore, .semaphore, ret_addr);
        slot.data.semaphore.signaled = true;
    }
    if (submission.fence) |fence| {
        const slot = try self.require(fence, .fence, ret_addr);
        slot.data.fence.signaled = true;
    }
    for (submission.command_buffers) |command_buffer| {
        const slot = self.lookup(command_buffer).?;
        slot.data.command_buffer.state = .submitted;
    }
    log.debug(
        "submit {d} command buffer(s) (ret 0x{x})",
        .{ submission.command_buffers.len, ret_addr },
    );
}

fn queuePresent(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Present,
    ret_addr: usize,
) Device.Error!void {
    const self = queueIndex(vptr, family_index, queue_index) orelse {
        return error.InvalidResource;
    };
    const slot = try self.require(
        description.swapchain,
        .swapchain,
        ret_addr,
    );
    if (description.image_index >= slot.data.swapchain.properties.image_count) {
        self.error_count += 1;
        log.warn(
            "present of image index {d} outside the swapchain",
            .{description.image_index},
        );
        log.warn("  called from 0x{x}", .{ret_addr});
        return error.InvalidDescription;
    }
    for (description.wait_semaphores) |semaphore| {
        _ = try self.require(semaphore, .semaphore, ret_addr);
    }
    log.debug(
        "present image {d} (ret 0x{x})",
        .{ description.image_index, ret_addr },
    );
}

fn queueWaitIdle(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    ret_addr: usize,
) Device.Error!void {
    _ = queueIndex(vptr, family_index, queue_index) orelse {
        return error.InvalidResource;
    };
    log.debug("queue wait idle (ret 0x{x})", .{ret_addr});
}
