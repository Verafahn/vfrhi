//! An OpenGL backend for vfrhi.
//!
//! The backend never creates or destroys the OpenGL context. The caller
//! owns the window and context, makes it current, and then initializes
//! the backend with a GLAD compatible loader. All RHI resources are
//! translated to OpenGL objects owned by the backend.
//!
//! OpenGL has no portable SPIR-V entry point, so every shader is
//! decompiled to GLSL 4.50 by `spirv.zig` before it is compiled.
//!
//! OpenGL has no device side swapchain, no semaphores, and no memory
//! heaps. The backend emulates swapchain images with textures and
//! presents by blitting the presented texture to the default
//! framebuffer. Presentation does not call `SwapBuffers`: the caller
//! must present the window after `Swapchain.present`.
const std = @import("std");
const rhi = @import("rhi");
const types = rhi.types;
const commands = @import("../../Command.zig");
const Resource = rhi.Resource;
const Device = rhi.Device;
const Queue = rhi.Queue;
const Error = rhi.Error;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.opengl);
const OpenGL = @This();

const glad = @import("glad");
const spirv = @import("spirv.zig");

const GLenum = u32;
const GLuint = u32;
const GLint = c_int;
const GLsizei = c_int;
const GLbitfield = u32;
const GLboolean = u8;
const GLintptr = isize;
const GLsizeiptr = isize;
const GLsync = ?*anyopaque;
const GLchar = u8;
const GLfloat = f32;

/// The API version type used by this backend.
pub const Version = rhi.Version;

/// Creation parameters of an OpenGL backend.
pub const Desc = struct {
    /// Smallest OpenGL version the backend accepts.
    ///
    /// The backend requires OpenGL 4.5 core profile features. The
    /// default matches that minimum.
    api_version: Version = .make(0, 4, 5, 0),
};

const Limits = struct {
    max_texture_size: u32 = 0,
    max_3d_texture_size: u32 = 0,
    max_array_texture_layers: u32 = 0,
    max_uniform_block_size: u32 = 0,
    max_shader_storage_block_size: u64 = 0,
    max_vertex_attribs: u32 = 0,
    max_vertex_attrib_bindings: u32 = 0,
    max_color_attachments: u32 = 0,
    max_uniform_buffer_bindings: u32 = 0,
    max_shader_storage_buffer_bindings: u32 = 0,
    max_texture_units: u32 = 0,
    max_image_units: u32 = 0,
    max_samples: u32 = 0,
    uniform_buffer_offset_alignment: u32 = 0,
};

const BufferState = struct {
    handle: GLuint,
    size: u64,
    usage: types.BufferUsage,
    memory: types.Memory,
    mapped: ?[*]u8 = null,
};

const TextureState = struct {
    handle: GLuint,
    properties: types.TextureProperties,
    layout: types.TextureLayout,
    owns_handle: bool = true,
};

const TextureViewState = struct {
    handle: GLuint,
    texture: Resource,
    format: types.Format,
    type: types.TextureType,
    aspect: types.TextureAspect,
    arrayed: bool,
    base_mip: u32,
    mip_count: u32,
    base_layer: u32,
    layer_count: u32,
};

const SurfaceState = struct {
    native: types.SurfaceDescription.Native,
    properties: types.SurfaceProperties,
};

const SwapchainState = struct {
    surface: Resource,
    fbo: GLuint,
    properties: types.SwapchainProperties,
    images: []Resource,
    views: []Resource,
    next_image: u32 = 0,
};

const ShaderState = struct {
    handle: GLuint,
    stage: types.ShaderStage,
};

const DescriptorSetLayoutState = struct {
    bindings: []types.DescriptorSetLayoutDescription.DescriptorBinding,
};

const PipelineLayoutState = struct {
    descriptor_sets: []Resource,
    push_constants: []types.PipelineLayoutDescription.PushConstant,
    push_buffer: GLuint = 0,
    push_bytes: []u8 = &.{},
    push_size: u32 = 0,
};

const StoredWrite = Device.DescriptorWrite;

const DescriptorSetState = struct {
    layout: Resource,
    writes: std.ArrayListUnmanaged(StoredWrite) = .empty,
};

const ProgramBinding = struct {
    set: u32,
    binding: u32,
    kind: types.DescriptorKind,
    point: u32,
    count: u32 = 1,
};

const PipelineState = struct {
    program: GLuint,
    vao: GLuint = 0,
    bind_point: types.BindPoint,
    layout: Resource,
    bindings: []ProgramBinding = &.{},
    push_binding: ?u32 = null,
    push_size: u32 = 0,
    vertex_bindings: []types.VertexLayout.Binding = &.{},
    topology: types.Topology = .triangle_list,
    cull: types.CullMode = .none,
    front_face: types.FrontFace = .counter_clockwise,
    depth: types.DepthState = .{},
    depth_format: ?types.Format = null,
    blend: types.BlendState = .{},
    samples: u32 = 1,
    color_formats: []types.Format = &.{},
};

const BoundSet = struct {
    set: u32,
    resource: Resource,
};

const VertexBinding = struct {
    binding: u32,
    buffer: Resource,
    offset: u64,
};

const IndexBinding = struct {
    buffer: Resource,
    offset: u64,
    index_type: types.IndexType,
};

const CommandBufferState = struct {
    level: types.CommandBufferDescription.Level,
    state: State = .initial,
    in_rendering: bool = false,
    fbo: GLuint = 0,
    pipeline: ?Resource = null,
    bound_sets: std.ArrayListUnmanaged(BoundSet) = .empty,
    vertex_buffers: std.ArrayListUnmanaged(VertexBinding) = .empty,
    index_buffer: ?IndexBinding = null,
    viewport_set: bool = false,
    color_attachment_count: u32 = 0,
    depth_attachment: bool = false,
    color_dont_care: [8]bool = @splat(false),
    depth_dont_care: bool = false,

    const State = enum {
        initial,
        recording,
        ended,
        submitted,
    };
};

const FenceState = struct {
    signaled: bool,
    sync: GLsync = null,
};

const SemaphoreState = struct {
    signaled: bool = false,
};

const Handle = union(Resource.Tag) {
    surface: SurfaceState,
    swapchain: SwapchainState,
    buffer: BufferState,
    texture: TextureState,
    texture_view: TextureViewState,
    sampler: GLuint,
    shader: ShaderState,
    descriptor_set_layout: DescriptorSetLayoutState,
    pipeline_layout: PipelineLayoutState,
    descriptor_set: DescriptorSetState,
    pipeline: PipelineState,
    command_buffer: CommandBufferState,
    fence: FenceState,
    semaphore: SemaphoreState,
};

const Slot = struct {
    generation: u32,
    tag: Resource.Tag,
    handle: Handle,
};

allocator: Allocator,

version: Version = .api_1_0,
renderer: []u8 = &.{},
vendor: []u8 = &.{},
version_string: []u8 = &.{},
device_type: Device.DeviceType = .other,
limits: Limits = .{},
supports_anisotropy: bool = false,
max_anisotropy: f32 = 1,

slots: std.ArrayListUnmanaged(?Slot) = .empty,
generations: std.ArrayListUnmanaged(u32) = .empty,
free_slots: std.ArrayListUnmanaged(u32) = .empty,
live_count: usize = 0,

/// Creates an OpenGL backend for the current context.
///
/// # Args
/// - `allocator`: allocator for backend bookkeeping.
/// - `loader_fn`: a GLAD compatible `glGetProcAddress` function, for
///   example `glfwGetProcAddress`.
/// - `description`: accepted API version.
///
/// # Return
/// An initialized backend owned by the caller.
///
/// # Error
/// - `error.InitializationFailed`: GLAD cannot load the context or
///   no current context exists.
/// - `error.Unsupported`: the context is older than OpenGL 4.5.
/// - `error.OutOfHostMemory`: an allocation fails.
///
/// # Note
/// The caller must make the OpenGL context current before calling
/// this function and keep it alive until `deinit` returns.
pub fn init(
    allocator: Allocator,
    loader_fn: anytype,
    description: Desc,
) !*OpenGL {
    log.debug("Creating OpenGL backend", .{});
    if (description.api_version.major != 4 or
        description.api_version.minor < 5)
    {
        log.warn(
            "OpenGL backend requires API 4.5 or newer",
            .{},
        );
        return error.Unsupported;
    }

    const Loader = *const fn (
        [*c]const u8,
    ) callconv(.c) ?*anyopaque;
    const loader: ?Loader = switch (@typeInfo(@TypeOf(loader_fn))) {
        .@"fn" => @ptrCast(&loader_fn),
        .pointer, .optional => @ptrCast(loader_fn),
        else => @compileError(
            "loader_fn must be a function or a function pointer",
        ),
    };
    if (glad.loadGLLoader(loader) == 0) {
        log.warn("GLAD could not load the current context", .{});
        return error.InitializationFailed;
    }

    const self = try allocator.create(OpenGL);
    self.* = .{ .allocator = allocator };
    errdefer allocator.destroy(self);

    self.version_string = try copyGlString(allocator, glad.VERSION);
    errdefer allocator.free(self.version_string);
    self.renderer = try copyGlString(allocator, glad.RENDERER);
    errdefer allocator.free(self.renderer);
    self.vendor = try copyGlString(allocator, glad.VENDOR);
    errdefer allocator.free(self.vendor);

    self.version = parseVersion(self.version_string) orelse {
        log.warn("cannot parse GL_VERSION '{s}'", .{
            self.version_string,
        });
        return error.InitializationFailed;
    };
    if (self.version.major < 4 or self.version.minor < 5) {
        log.warn(
            "context {f} is older than OpenGL 4.5",
            .{self.version},
        );
        return error.Unsupported;
    }
    if (@as(u32, @bitCast(self.version)) <
        @as(u32, @bitCast(description.api_version)))
    {
        log.warn(
            "context {f} is older than requested {f}",
            .{ self.version, description.api_version },
        );
        return error.Unsupported;
    }

    self.device_type = detectDeviceType(self.renderer);
    self.limits = try queryLimits();
    self.supports_anisotropy = hasExtension("GL_EXT_texture_filter_anisotropic");
    if (self.supports_anisotropy) {
        var value: GLint = 0;
        glad.getIntegerv(0x84ff, &value);
        self.max_anisotropy = @floatFromInt(@max(value, 1));
    }

    glad.clipControl(glad.UPPER_LEFT, glad.ZERO_TO_ONE);
    clearGlErrors();

    log.info("      renderer: {s}", .{self.renderer});
    log.info("        vendor: {s}", .{self.vendor});
    log.info("       version: {s}", .{self.version_string});
    log.debug("OpenGL backend has been created", .{});
    return self;
}

/// Destroys the backend.
///
/// # Note
/// Every RHI resource must be destroyed before this call. Live
/// resources are reported as errors and released best effort.
pub fn deinit(self: *OpenGL) void {
    log.debug("Destroying OpenGL backend", .{});
    if (self.live_count != 0) {
        log.err(
            "OpenGL backend destroyed with {d} live resource(s)",
            .{self.live_count},
        );
        var index: usize = 0;
        while (index < self.slots.items.len) : (index += 1) {
            if (self.slots.items[index]) |slot| {
                const resource: Resource = .{
                    .identifier = .{
                        .generation = slot.generation,
                        .index = @intCast(index),
                    },
                    .tag = slot.tag,
                };
                self.destroyResource(resource);
            }
        }
    }

    glad.finish();
    self.allocator.free(self.version_string);
    self.allocator.free(self.renderer);
    self.allocator.free(self.vendor);
    self.slots.deinit(self.allocator);
    self.generations.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.allocator.destroy(self);
    log.debug("OpenGL backend has been destroyed", .{});
}

/// Returns the RHI device interface of this backend.
///
/// # Return
/// A device whose lifetime is tied to `self`.
pub fn asDevice(self: *OpenGL) Device {
    return .{
        .vptr = self,
        .vtable = &device_vtable,
    };
}

fn queryLimits() !Limits {
    var value: GLint = 0;
    var value64: i64 = 0;
    glad.getIntegerv(glad.MAX_TEXTURE_SIZE, &value);
    var limits: Limits = .{ .max_texture_size = @intCast(value) };
    glad.getIntegerv(glad.MAX_3D_TEXTURE_SIZE, &value);
    limits.max_3d_texture_size = @intCast(value);
    glad.getIntegerv(glad.MAX_ARRAY_TEXTURE_LAYERS, &value);
    limits.max_array_texture_layers = @intCast(value);
    glad.getIntegerv(glad.MAX_UNIFORM_BLOCK_SIZE, &value);
    limits.max_uniform_block_size = @intCast(value);
    glad.getInteger64v(glad.MAX_SHADER_STORAGE_BLOCK_SIZE, &value64);
    limits.max_shader_storage_block_size = @intCast(value64);
    glad.getIntegerv(glad.MAX_VERTEX_ATTRIBS, &value);
    limits.max_vertex_attribs = @intCast(value);
    glad.getIntegerv(glad.MAX_VERTEX_ATTRIB_BINDINGS, &value);
    limits.max_vertex_attrib_bindings = @intCast(value);
    glad.getIntegerv(glad.MAX_COLOR_ATTACHMENTS, &value);
    limits.max_color_attachments = @intCast(value);
    glad.getIntegerv(glad.MAX_UNIFORM_BUFFER_BINDINGS, &value);
    limits.max_uniform_buffer_bindings = @intCast(value);
    glad.getIntegerv(glad.MAX_SHADER_STORAGE_BUFFER_BINDINGS, &value);
    limits.max_shader_storage_buffer_bindings = @intCast(value);
    glad.getIntegerv(glad.MAX_COMBINED_TEXTURE_IMAGE_UNITS, &value);
    limits.max_texture_units = @intCast(value);
    glad.getIntegerv(glad.MAX_IMAGE_UNITS, &value);
    limits.max_image_units = @intCast(value);
    glad.getIntegerv(glad.MAX_SAMPLES, &value);
    limits.max_samples = @intCast(value);
    glad.getIntegerv(glad.UNIFORM_BUFFER_OFFSET_ALIGNMENT, &value);
    limits.uniform_buffer_offset_alignment = @intCast(value);
    return limits;
}

fn copyGlString(allocator: Allocator, name: GLenum) ![]u8 {
    const pointer = glad.getString(name);
    if (pointer == null) return error.InitializationFailed;
    return allocator.dupe(u8, std.mem.span(pointer));
}

fn parseVersion(text: []const u8) ?Version {
    var tokens = std.mem.tokenizeAny(u8, text, " .");
    const major = std.fmt.parseInt(u7, tokens.next() orelse
        return null, 10) catch return null;
    const minor = std.fmt.parseInt(u10, tokens.next() orelse
        return null, 10) catch return null;
    const patch = if (tokens.next()) |token|
        std.fmt.parseInt(u12, token, 10) catch 0
    else
        0;
    return Version.make(0, major, minor, patch);
}

fn detectDeviceType(renderer: []const u8) Device.DeviceType {
    if (containsIgnoreCase(renderer, "llvmpipe") or
        containsIgnoreCase(renderer, "softpipe") or
        containsIgnoreCase(renderer, "swiftshader") or
        containsIgnoreCase(renderer, "software"))
    {
        return .cpu;
    }
    if (containsIgnoreCase(renderer, "intel")) return .integrated_gpu;
    if (containsIgnoreCase(renderer, "nvidia") or
        containsIgnoreCase(renderer, "amd") or
        containsIgnoreCase(renderer, "radeon"))
    {
        return .discrete_gpu;
    }
    return .other;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(
            haystack[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
}

fn hasExtension(name: []const u8) bool {
    var count: GLint = 0;
    glad.getIntegerv(glad.NUM_EXTENSIONS, &count);
    var index: GLuint = 0;
    while (index < @as(GLuint, @intCast(count))) : (index += 1) {
        const pointer = glad.getStringi(glad.EXTENSIONS, index);
        if (pointer == null) continue;
        if (std.mem.eql(u8, std.mem.span(pointer), name)) return true;
    }
    return false;
}

fn clearGlErrors() void {
    while (glad.getError() != glad.NO_ERROR) {}
}

fn takeGlError(self: *OpenGL, what: []const u8) Error!void {
    _ = self;
    const code = glad.getError();
    if (code == glad.NO_ERROR) return;
    while (glad.getError() != glad.NO_ERROR) {}
    log.warn("{s} failed with OpenGL error 0x{x}", .{ what, code });
    return switch (code) {
        glad.OUT_OF_MEMORY => error.OutOfDeviceMemory,
        glad.INVALID_ENUM => error.Unsupported,
        glad.INVALID_VALUE,
        glad.INVALID_OPERATION,
        glad.INVALID_FRAMEBUFFER_OPERATION,
        => error.InvalidDescription,
        else => error.Unknown,
    };
}

fn lookup(
    self: *OpenGL,
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
    self: *OpenGL,
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

fn releaseSlot(self: *OpenGL, resource: Resource) void {
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

fn createResource(
    self: *OpenGL,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    log.debug(
        "create {s} (ret 0x{x})",
        .{ @tagName(description), ret_addr },
    );
    return switch (description) {
        .surface => |value| self.createSurface(value),
        .swapchain => |value| self.createSwapchain(value),
        .buffer => |value| self.createBuffer(value),
        .texture => |value| self.createTexture(value),
        .texture_view => |value| self.createTextureView(value),
        .sampler => |value| self.createSampler(value),
        .shader => |value| self.createShader(value),
        .descriptor_set_layout => |value| {
            return self.createDescriptorSetLayout(value);
        },
        .pipeline_layout => |value| {
            return self.createPipelineLayout(value);
        },
        .descriptor_set => |value| self.createDescriptorSet(value),
        .pipeline => |value| self.createPipeline(value),
        .command_buffer => |value| self.createCommandBuffer(value),
        .fence => |value| self.createFence(value),
        .semaphore => |value| self.createSemaphore(value),
    };
}

fn createSurface(
    self: *OpenGL,
    description: types.SurfaceDescription,
) Error!Resource {
    var viewport: [4]GLint = .{ 0, 0, 0, 0 };
    glad.getIntegerv(glad.VIEWPORT, &viewport);
    var max_dims: [2]GLint = .{ 0, 0 };
    glad.getIntegerv(glad.MAX_VIEWPORT_DIMS, &max_dims);

    const current_width: u32 = if (description.native == .headless)
        description.native.headless.width
    else if (viewport[2] > 0)
        @intCast(viewport[2])
    else
        1;
    const current_height: u32 = if (description.native == .headless)
        description.native.headless.height
    else if (viewport[3] > 0)
        @intCast(viewport[3])
    else
        1;
    if (current_width == 0 or current_height == 0) {
        return error.InvalidDescription;
    }

    const properties: types.SurfaceProperties = .{
        .min_width = 1,
        .min_height = 1,
        .max_width = if (max_dims[0] > 0)
            @intCast(max_dims[0])
        else
            self.limits.max_texture_size,
        .max_height = if (max_dims[1] > 0)
            @intCast(max_dims[1])
        else
            self.limits.max_texture_size,
        .current_width = current_width,
        .current_height = current_height,
        .format_count = 1,
    };
    return self.newSlot(.surface, .{ .surface = .{
        .native = description.native,
        .properties = properties,
    } });
}

fn createSwapchain(
    self: *OpenGL,
    description: types.SwapchainDescription,
) Error!Resource {
    _ = try self.lookup(description.surface, .surface);
    if (description.width == 0 or description.height == 0) {
        return error.InvalidDescription;
    }
    if (description.image_count == 0 or description.image_count > 8) {
        return error.InvalidDescription;
    }
    if (glFormat(description.format) == null) {
        return error.Unsupported;
    }
    if (description.width > self.limits.max_texture_size or
        description.height > self.limits.max_texture_size)
    {
        return error.Unsupported;
    }

    const properties: types.SwapchainProperties = .{
        .width = description.width,
        .height = description.height,
        .format = description.format,
        .image_count = description.image_count,
    };

    const swapchain = try self.newSlot(.swapchain, .{ .swapchain = .{
        .surface = description.surface,
        .fbo = 0,
        .properties = properties,
        .images = &.{},
        .views = &.{},
    } });
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
            if (self.lookup(views[i], .texture_view)) |_| {
                self.destroyResource(views[i]);
            } else |_| {}
        }
        i = image_created;
        while (i > 0) {
            i -= 1;
            if (self.lookup(images[i], .texture)) |_| {
                self.destroyResource(images[i]);
            } else |_| {}
        }
    }

    const texture_description: types.TextureDescription = .{
        .type = .@"2d",
        .format = description.format,
        .width = description.width,
        .height = description.height,
        .usage = .{
            .sampled = true,
            .color_attachment = true,
            .transfer_src = true,
        },
    };
    for (0..description.image_count) |index| {
        const texture = try createTextureObject(
            self,
            texture_description,
            null,
        );
        images[index] = try self.newSlot(.texture, .{ .texture = .{
            .handle = texture,
            .properties = .{
                .type = .@"2d",
                .format = description.format,
                .width = description.width,
                .height = description.height,
                .depth = 1,
                .mip_levels = 1,
                .array_layers = 1,
                .samples = 1,
                .usage = texture_description.usage,
            },
            .layout = .undefined,
            .owns_handle = true,
        } });
        image_created += 1;

        var view: GLuint = 0;
        glad.genTextures(1, &view);
        glad.textureView(
            view,
            glad.TEXTURE_2D,
            texture,
            glInternalFormat(description.format).?,
            0,
            1,
            0,
            1,
        );
        if (takeGlError(self, "glTextureView")) |_| {} else |err| {
            glad.deleteTextures(1, &view);
            return err;
        }
        views[index] = try self.newSlot(.texture_view, .{
            .texture_view = .{
                .handle = view,
                .texture = images[index],
                .format = description.format,
                .type = .@"2d",
                .aspect = .color,
                .arrayed = false,
                .base_mip = 0,
                .mip_count = 1,
                .base_layer = 0,
                .layer_count = 1,
            },
        });
        view_created += 1;
    }

    var fbo: GLuint = 0;
    glad.createFramebuffers(1, &fbo);
    if (takeGlError(self, "glCreateFramebuffers")) |_| {} else |err| {
        return err;
    }

    const slot = try self.lookup(swapchain, .swapchain);
    slot.handle.swapchain.images = images;
    slot.handle.swapchain.views = views;
    slot.handle.swapchain.fbo = fbo;
    return swapchain;
}

fn createBuffer(
    self: *OpenGL,
    description: types.BufferDescription,
) Error!Resource {
    if (description.size == 0) return error.InvalidDescription;
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

    var handle: GLuint = 0;
    glad.createBuffers(1, &handle);
    errdefer glad.deleteBuffers(1, &handle);
    glad.namedBufferData(
        handle,
        @intCast(description.size),
        null,
        glad.DYNAMIC_DRAW,
    );
    if (takeGlError(self, "glNamedBufferData")) |_| {} else |err| {
        return err;
    }
    if (description.initial_data) |data| {
        glad.namedBufferSubData(
            handle,
            0,
            @intCast(data.len),
            data.ptr,
        );
        if (takeGlError(self, "glNamedBufferSubData")) |_| {} else |err| {
            return err;
        }
    }

    return self.newSlot(.buffer, .{ .buffer = .{
        .handle = handle,
        .size = description.size,
        .usage = description.usage,
        .memory = description.memory,
    } });
}

fn createTexture(
    self: *OpenGL,
    description: types.TextureDescription,
) Error!Resource {
    if (description.format == .undefined or description.width == 0 or
        description.height == 0 or description.depth == 0)
    {
        return error.InvalidDescription;
    }
    if (description.mip_levels == 0 or
        description.array_layers == 0 or
        description.samples == 0)
    {
        return error.InvalidDescription;
    }
    if (description.initial_data != null and
        !description.usage.transfer_dst)
    {
        return error.InvalidDescription;
    }
    if (description.type == .@"3d" and
        description.array_layers != 1)
    {
        return error.InvalidDescription;
    }
    if (description.samples > 1 and
        (description.type != .@"2d" or
            description.array_layers != 1 or
            description.depth != 1 or
            description.mip_levels != 1))
    {
        return error.Unsupported;
    }
    if (description.samples > 1 and description.initial_data != null) {
        return error.Unsupported;
    }

    const handle = try createTextureObject(
        self,
        description,
        description.initial_data,
    );
    errdefer glad.deleteTextures(1, &handle);
    try self.takeGlError("glCreateTextures");

    const initial_layout: types.TextureLayout =
        if (description.initial_data == null)
            .undefined
        else switch (description.format.aspect()) {
            .color => .shader_read_only,
            .depth => .depth_read_only,
            .stencil => .stencil_read_only,
            .depth_stencil => .depth_stencil_read_only,
        };

    return self.newSlot(.texture, .{ .texture = .{
        .handle = handle,
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
        .layout = initial_layout,
    } });
}

fn createTextureView(
    self: *OpenGL,
    description: types.TextureViewDescription,
) Error!Resource {
    const texture_slot = try self.lookup(description.texture, .texture);
    const texture = texture_slot.handle.texture.properties;
    const mip_count = if (description.mip_count == 0)
        texture.mip_levels - description.base_mip
    else
        description.mip_count;
    const layer_count = if (description.layer_count == 0)
        texture.array_layers - description.base_layer
    else
        description.layer_count;
    if (description.base_mip >= texture.mip_levels or
        mip_count == 0 or
        description.base_mip + mip_count > texture.mip_levels)
    {
        return error.InvalidDescription;
    }
    if (description.base_layer >= texture.array_layers or
        layer_count == 0 or
        description.base_layer + layer_count > texture.array_layers)
    {
        return error.InvalidDescription;
    }
    if (texture.samples > 1) return error.Unsupported;

    const view_format = description.format orelse texture.format;
    const view_type = description.type orelse texture.type;
    const internal = glInternalFormat(view_format) orelse
        return error.Unsupported;
    const target = textureTarget(
        view_type,
        layer_count > 1,
    ) orelse return error.Unsupported;

    var handle: GLuint = 0;
    glad.genTextures(1, &handle);
    errdefer glad.deleteTextures(1, &handle);
    glad.textureView(
        handle,
        target,
        texture_slot.handle.texture.handle,
        internal,
        @intCast(description.base_mip),
        @intCast(mip_count),
        @intCast(description.base_layer),
        @intCast(layer_count),
    );
    if (takeGlError(self, "glTextureView")) |_| {} else |err| {
        return err;
    }

    return self.newSlot(.texture_view, .{ .texture_view = .{
        .handle = handle,
        .texture = description.texture,
        .format = view_format,
        .type = view_type,
        .aspect = description.aspect orelse texture.format.aspect(),
        .arrayed = texture.array_layers > 1 or layer_count > 1,
        .base_mip = description.base_mip,
        .mip_count = mip_count,
        .base_layer = description.base_layer,
        .layer_count = layer_count,
    } });
}

fn createSampler(
    self: *OpenGL,
    description: types.SamplerDescription,
) Error!Resource {
    if (description.lod_min > description.lod_max) {
        return error.InvalidDescription;
    }
    var handle: GLuint = 0;
    glad.createSamplers(1, &handle);
    errdefer glad.deleteSamplers(1, &handle);

    glad.samplerParameteri(
        handle,
        glad.TEXTURE_MAG_FILTER,
        @intCast(toGlFilter(description.mag_filter)),
    );
    glad.samplerParameteri(
        handle,
        glad.TEXTURE_MIN_FILTER,
        @intCast(toGlMinFilter(
            description.min_filter,
            description.mipmap,
        )),
    );
    glad.samplerParameteri(
        handle,
        glad.TEXTURE_WRAP_S,
        @intCast(toGlAddressMode(description.address_u)),
    );
    glad.samplerParameteri(
        handle,
        glad.TEXTURE_WRAP_T,
        @intCast(toGlAddressMode(description.address_v)),
    );
    glad.samplerParameteri(
        handle,
        glad.TEXTURE_WRAP_R,
        @intCast(toGlAddressMode(description.address_w)),
    );
    glad.samplerParameterf(handle, glad.TEXTURE_MIN_LOD, description.lod_min);
    glad.samplerParameterf(handle, glad.TEXTURE_MAX_LOD, description.lod_max);
    if (description.compare) |compare| {
        glad.samplerParameteri(
            handle,
            glad.TEXTURE_COMPARE_MODE,
            @intCast(glad.COMPARE_REF_TO_TEXTURE),
        );
        glad.samplerParameteri(
            handle,
            glad.TEXTURE_COMPARE_FUNC,
            @intCast(toGlCompareOp(compare)),
        );
    }
    if (description.address_u == .clamp_to_border or
        description.address_v == .clamp_to_border or
        description.address_w == .clamp_to_border)
    {
        const transparent_black = [4]GLfloat{ 0, 0, 0, 0 };
        glad.samplerParameterfv(
            handle,
            glad.TEXTURE_BORDER_COLOR,
            &transparent_black,
        );
    }
    if (description.anisotropy > 0 and self.supports_anisotropy) {
        const value = @min(
            @as(f32, @floatFromInt(description.anisotropy)),
            self.max_anisotropy,
        );
        glad.samplerParameterf(handle, 0x84fe, value);
    }
    if (takeGlError(self, "glCreateSamplers")) |_| {} else |err| {
        return err;
    }
    return self.newSlot(.sampler, .{ .sampler = handle });
}

fn createShader(
    self: *OpenGL,
    description: types.ShaderDescription,
) Error!Resource {
    if (description.code.len == 0) {
        return error.InvalidDescription;
    }
    const translated = spirv.translate(
        self.allocator,
        description.code,
        description.stage,
        description.entry_point,
    ) catch |err| return mapTranslateError(err);
    defer translated.deinit();

    if (std.log.logEnabled(.debug, .opengl)) {
        log.debug("translated GLSL for {s}:\n{s}", .{
            @tagName(description.stage),
            translated.source,
        });
    }

    const gl_stage = switch (description.stage) {
        .vertex => glad.VERTEX_SHADER,
        .fragment => glad.FRAGMENT_SHADER,
        .compute => glad.COMPUTE_SHADER,
        .geometry => glad.GEOMETRY_SHADER,
        .tessellation_control => glad.TESS_CONTROL_SHADER,
        .tessellation_evaluation => glad.TESS_EVALUATION_SHADER,
    };
    const handle = try self.compileGlsl(
        @intCast(gl_stage),
        translated.source,
    );
    errdefer glad.deleteShader(handle);

    return self.newSlot(.shader, .{ .shader = .{
        .handle = handle,
        .stage = description.stage,
    } });
}

fn mapTranslateError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfHostMemory,
        error.InvalidSpirv => error.InvalidDescription,
        error.Unsupported => error.Unsupported,
        else => error.InvalidDescription,
    };
}

fn compileGlsl(
    self: *OpenGL,
    gl_stage: GLenum,
    source_text: []const u8,
) Error!GLuint {
    const handle = glad.createShader(@intCast(gl_stage));
    if (handle == 0) return error.OutOfDeviceMemory;
    errdefer glad.deleteShader(handle);

    const source_pointer: [*c]const u8 = source_text.ptr;
    var length: GLint = @intCast(source_text.len);
    glad.shaderSource(handle, 1, @ptrCast(&source_pointer), &length);
    glad.compileShader(handle);

    var status: GLint = 0;
    glad.getShaderiv(handle, glad.COMPILE_STATUS, &status);
    if (status == 0) {
        var log_length: GLint = 0;
        glad.getShaderiv(handle, glad.INFO_LOG_LENGTH, &log_length);
        const buffer = self.allocator.alloc(
            u8,
            @intCast(@max(log_length, 1)),
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(buffer);
        glad.getShaderInfoLog(
            handle,
            @intCast(buffer.len),
            null,
            @ptrCast(buffer.ptr),
        );
        log.warn("OpenGL shader compilation failed:\n{s}", .{
            std.mem.sliceTo(buffer, 0),
        });
        return error.InvalidDescription;
    }
    return handle;
}

fn createDescriptorSetLayout(
    self: *OpenGL,
    description: types.DescriptorSetLayoutDescription,
) Error!Resource {
    if (description.bindings.len == 0) {
        return error.InvalidDescription;
    }
    for (description.bindings, 0..) |binding, index| {
        if (binding.count == 0) return error.InvalidDescription;
        for (description.bindings[0..index]) |other| {
            if (other.binding == binding.binding) {
                return error.InvalidDescription;
            }
        }
    }
    const bindings = self.allocator.dupe(
        types.DescriptorSetLayoutDescription.DescriptorBinding,
        description.bindings,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(bindings);
    return self.newSlot(.descriptor_set_layout, .{
        .descriptor_set_layout = .{ .bindings = bindings },
    });
}

fn createPipelineLayout(
    self: *OpenGL,
    description: types.PipelineLayoutDescription,
) Error!Resource {
    var push_size: u32 = 0;
    for (description.push_constants, 0..) |range, index| {
        if (range.size == 0 or range.offset + range.size > 256) {
            return error.InvalidDescription;
        }
        push_size = @max(push_size, range.offset + range.size);
        for (description.push_constants[0..index]) |other| {
            const end = other.offset + other.size;
            if (range.offset < end and
                other.offset < range.offset + range.size)
            {
                return error.InvalidDescription;
            }
        }
    }
    for (description.descriptor_sets) |set| {
        _ = try self.lookup(set, .descriptor_set_layout);
    }

    const sets = self.allocator.dupe(
        Resource,
        description.descriptor_sets,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(sets);
    const push_constants = self.allocator.dupe(
        types.PipelineLayoutDescription.PushConstant,
        description.push_constants,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(push_constants);

    var push_buffer: GLuint = 0;
    var push_bytes: []u8 = &.{};
    if (push_size != 0) {
        const size: u32 = std.mem.alignForward(u32, push_size, 16);
        push_bytes = self.allocator.alloc(u8, size) catch
            return error.OutOfHostMemory;
        errdefer self.allocator.free(push_bytes);
        @memset(push_bytes, 0);
        glad.createBuffers(1, &push_buffer);
        errdefer glad.deleteBuffers(1, &push_buffer);
        glad.namedBufferData(
            push_buffer,
            @intCast(size),
            null,
            glad.DYNAMIC_DRAW,
        );
        glad.namedBufferSubData(
            push_buffer,
            0,
            @intCast(size),
            push_bytes.ptr,
        );
        if (takeGlError(self, "push constant buffer")) |_| {} else |err| {
            return err;
        }
        push_size = size;
    }

    return self.newSlot(.pipeline_layout, .{ .pipeline_layout = .{
        .descriptor_sets = sets,
        .push_constants = push_constants,
        .push_buffer = push_buffer,
        .push_bytes = push_bytes,
        .push_size = push_size,
    } });
}

fn createDescriptorSet(
    self: *OpenGL,
    description: types.DescriptorSetDescription,
) Error!Resource {
    _ = try self.lookup(description.layout, .descriptor_set_layout);
    return self.newSlot(.descriptor_set, .{ .descriptor_set = .{
        .layout = description.layout,
    } });
}

fn createPipeline(
    self: *OpenGL,
    description: types.PipelineDescription,
) Error!Resource {
    return switch (description) {
        .graphics => |value| self.createGraphicsPipeline(value),
        .compute => |value| self.createComputePipeline(value),
    };
}

fn createGraphicsPipeline(
    self: *OpenGL,
    description: types.GraphicsPipelineDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .pipeline_layout,
    );
    const vertex = try self.lookup(description.vertex, .shader);
    if (vertex.handle.shader.stage != .vertex) {
        return error.InvalidDescription;
    }
    var fragment_handle: ?GLuint = null;
    if (description.fragment) |fragment_resource| {
        const fragment = try self.lookup(fragment_resource, .shader);
        if (fragment.handle.shader.stage != .fragment) {
            return error.InvalidDescription;
        }
        fragment_handle = fragment.handle.shader.handle;
    }
    if (description.color_formats.len == 0 and
        description.depth_format == null)
    {
        return error.InvalidDescription;
    }
    if (description.samples == 0 or
        !std.math.isPowerOfTwo(description.samples))
    {
        return error.InvalidDescription;
    }
    for (description.color_formats) |format| {
        if (glInternalFormat(format) == null) {
            return error.Unsupported;
        }
        if (format.aspect() != .color) return error.InvalidDescription;
    }
    if (description.depth_format) |format| {
        if (glInternalFormat(format) == null) {
            return error.Unsupported;
        }
        if (format.aspect() == .color) return error.InvalidDescription;
    }
    for (description.vertex_layout.bindings, 0..) |binding, index| {
        if (binding.binding >= self.limits.max_vertex_attrib_bindings) {
            return error.Unsupported;
        }
        for (description.vertex_layout.bindings[0..index]) |other| {
            if (other.binding == binding.binding) {
                return error.InvalidDescription;
            }
        }
    }
    for (description.vertex_layout.attributes) |attribute| {
        if (attribute.location >= self.limits.max_vertex_attribs) {
            return error.Unsupported;
        }
        if (findVertexBinding(
            description.vertex_layout.bindings,
            attribute.binding,
        ) == null) {
            return error.InvalidDescription;
        }
        if (vertexAttributeFormat(attribute.format) == null) {
            return error.Unsupported;
        }
    }

    var owned_fragment: ?GLuint = null;
    defer if (owned_fragment) |handle| glad.deleteShader(handle);
    const fragment = fragment_handle orelse blk: {
        const default_fragment = try self.compileGlsl(
            @intCast(glad.FRAGMENT_SHADER),
            "#version 450 core\nvoid main() {}\n",
        );
        owned_fragment = default_fragment;
        break :blk default_fragment;
    };
    const program = try self.linkProgram(
        vertex.handle.shader.handle,
        fragment,
    );
    errdefer glad.deleteProgram(program);
    var pipeline = try self.buildPipelineBindings(
        program,
        description.layout,
        layout_slot,
    );
    errdefer {
        self.allocator.free(pipeline.bindings);
        if (pipeline.vertex_bindings.len != 0) {
            self.allocator.free(pipeline.vertex_bindings);
        }
        if (pipeline.color_formats.len != 0) {
            self.allocator.free(pipeline.color_formats);
        }
    }
    pipeline.vertex_bindings = self.allocator.dupe(
        types.VertexLayout.Binding,
        description.vertex_layout.bindings,
    ) catch return error.OutOfHostMemory;
    pipeline.color_formats = self.allocator.dupe(
        types.Format,
        description.color_formats,
    ) catch return error.OutOfHostMemory;
    pipeline.topology = description.topology;
    pipeline.cull = description.cull;
    pipeline.front_face = description.front_face;
    pipeline.depth = description.depth;
    pipeline.depth_format = description.depth_format;
    pipeline.blend = description.blend;
    pipeline.samples = description.samples;

    var vao: GLuint = 0;
    glad.createVertexArrays(1, &vao);
    errdefer glad.deleteVertexArrays(1, &vao);
    for (description.vertex_layout.bindings) |binding| {
        glad.vertexArrayBindingDivisor(
            vao,
            binding.binding,
            if (binding.rate == .instance) 1 else 0,
        );
    }
    for (description.vertex_layout.attributes) |attribute| {
        const format = vertexAttributeFormat(attribute.format).?;
        const location = attribute.location;
        glad.enableVertexArrayAttrib(vao, location);
        glad.vertexArrayAttribBinding(vao, location, attribute.binding);
        if (format.integer) {
            glad.vertexArrayAttribIFormat(
                vao,
                location,
                format.size,
                format.kind,
                attribute.offset,
            );
        } else {
            glad.vertexArrayAttribFormat(
                vao,
                location,
                format.size,
                format.kind,
                if (format.normalized) glad.TRUE else glad.FALSE,
                attribute.offset,
            );
        }
    }
    if (takeGlError(self, "graphics pipeline")) |_| {} else |err| {
        return err;
    }

    pipeline.program = program;
    pipeline.vao = vao;
    pipeline.bind_point = .graphics;
    return self.newSlot(.pipeline, .{ .pipeline = pipeline });
}

fn createComputePipeline(
    self: *OpenGL,
    description: types.ComputePipelineDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .pipeline_layout,
    );
    const shader = try self.lookup(description.shader, .shader);
    if (shader.handle.shader.stage != .compute) {
        return error.InvalidDescription;
    }
    const program = try self.linkProgram(
        shader.handle.shader.handle,
        null,
    );
    errdefer glad.deleteProgram(program);
    var pipeline = try self.buildPipelineBindings(
        program,
        description.layout,
        layout_slot,
    );
    errdefer self.allocator.free(pipeline.bindings);
    pipeline.program = program;
    pipeline.bind_point = .compute;
    return self.newSlot(.pipeline, .{ .pipeline = pipeline });
}

fn linkProgram(
    self: *OpenGL,
    vertex: GLuint,
    fragment: ?GLuint,
) Error!GLuint {
    const program = glad.createProgram();
    if (program == 0) return error.OutOfDeviceMemory;
    errdefer glad.deleteProgram(program);
    glad.attachShader(program, vertex);
    if (fragment) |handle| glad.attachShader(program, handle);
    glad.linkProgram(program);
    var status: GLint = 0;
    glad.getProgramiv(program, glad.LINK_STATUS, &status);
    if (status == 0) {
        var log_length: GLint = 0;
        glad.getProgramiv(program, glad.INFO_LOG_LENGTH, &log_length);
        const buffer = self.allocator.alloc(
            u8,
            @intCast(@max(log_length, 1)),
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(buffer);
        glad.getProgramInfoLog(
            program,
            @intCast(buffer.len),
            null,
            @ptrCast(buffer.ptr),
        );
        log.warn("OpenGL program link failed:\n{s}", .{
            std.mem.sliceTo(buffer, 0),
        });
        return error.InvalidDescription;
    }
    return program;
}

fn buildPipelineBindings(
    self: *OpenGL,
    program: GLuint,
    layout_resource: Resource,
    layout_slot: *Slot,
) Error!PipelineState {
    const layout = &layout_slot.handle.pipeline_layout;
    var bindings: std.ArrayListUnmanaged(ProgramBinding) = .empty;
    defer bindings.deinit(self.allocator);

    var ubo_next: u32 = 0;
    var ssbo_next: u32 = 0;
    var texture_next: u32 = 0;
    var image_next: u32 = 0;
    var push_binding: ?u32 = null;

    var block_count: GLint = 0;
    glad.getProgramiv(program, glad.ACTIVE_UNIFORM_BLOCKS, &block_count);
    var block_index: GLuint = 0;
    while (block_index < @as(GLuint, @intCast(block_count))) : (block_index += 1) {
        var name_buffer: [256]u8 = undefined;
        glad.getActiveUniformBlockName(
            program,
            block_index,
            name_buffer.len,
            null,
            @ptrCast(&name_buffer),
        );
        const name = std.mem.sliceTo(&name_buffer, 0);
        if (std.mem.eql(u8, name, "vfrhi_push")) {
            if (layout.push_size == 0) {
                log.warn("shader expects push constants but layout has none", .{});
                return error.InvalidDescription;
            }
            if (ubo_next >= self.limits.max_uniform_buffer_bindings) {
                return error.Unsupported;
            }
            push_binding = ubo_next;
            glad.uniformBlockBinding(program, block_index, ubo_next);
            ubo_next += 1;
            continue;
        }
        const descriptor = parseDescriptorName(name) orelse {
            log.warn("unexpected uniform block '{s}' in shader", .{name});
            return error.InvalidDescription;
        };
        const kind = findLayoutKind(self, layout, descriptor.set, descriptor.binding) orelse {
            log.warn(
                "uniform block set {d} binding {d} is missing from layout",
                .{ descriptor.set, descriptor.binding },
            );
            return error.InvalidDescription;
        };
        if (kind != .uniform_buffer) return error.InvalidDescription;
        if (ubo_next >= self.limits.max_uniform_buffer_bindings) {
            return error.Unsupported;
        }
        glad.uniformBlockBinding(program, block_index, ubo_next);
        bindings.append(self.allocator, .{
            .set = descriptor.set,
            .binding = descriptor.binding,
            .kind = kind,
            .point = ubo_next,
        }) catch return error.OutOfHostMemory;
        ubo_next += 1;
    }
    try self.takeGlError("uniform block bindings");

    var ssbo_count: GLint = 0;
    glad.getProgramInterfaceiv(
        program,
        glad.SHADER_STORAGE_BLOCK,
        glad.ACTIVE_RESOURCES,
        &ssbo_count,
    );
    try self.takeGlError("shader storage block query");
    block_index = 0;
    while (block_index < @as(GLuint, @intCast(ssbo_count))) : (block_index += 1) {
        var name_buffer: [256]u8 = undefined;
        glad.getProgramResourceName(
            program,
            glad.SHADER_STORAGE_BLOCK,
            block_index,
            name_buffer.len,
            null,
            @ptrCast(&name_buffer),
        );
        const name = std.mem.sliceTo(&name_buffer, 0);
        const descriptor = parseDescriptorName(name) orelse {
            log.warn("unexpected storage block '{s}' in shader", .{name});
            return error.InvalidDescription;
        };
        const kind = findLayoutKind(self, layout, descriptor.set, descriptor.binding) orelse
            return error.InvalidDescription;
        if (kind != .storage_buffer) return error.InvalidDescription;
        if (ssbo_next >= self.limits.max_shader_storage_buffer_bindings) {
            return error.Unsupported;
        }
        glad.shaderStorageBlockBinding(program, block_index, ssbo_next);
        bindings.append(self.allocator, .{
            .set = descriptor.set,
            .binding = descriptor.binding,
            .kind = kind,
            .point = ssbo_next,
        }) catch return error.OutOfHostMemory;
        ssbo_next += 1;
    }
    try self.takeGlError("shader storage block bindings");

    var uniform_count: GLint = 0;
    glad.getProgramiv(program, glad.ACTIVE_UNIFORMS, &uniform_count);
    var uniform_index: GLuint = 0;
    while (uniform_index < @as(GLuint, @intCast(uniform_count))) : (uniform_index += 1) {
        var name_buffer: [256]u8 = undefined;
        var size: GLint = 0;
        var uniform_type: GLenum = 0;
        glad.getActiveUniform(
            program,
            uniform_index,
            name_buffer.len,
            null,
            &size,
            &uniform_type,
            @ptrCast(&name_buffer),
        );
        var name = std.mem.sliceTo(&name_buffer, 0);
        if (std.mem.indexOfScalar(u8, name, '.')) |_| {
            // Uniform block members are covered by the block binding.
            continue;
        }
        if (std.mem.indexOfScalar(u8, name, '[')) |bracket| {
            name = name[0..bracket];
        }
        const descriptor = parseDescriptorName(name) orelse {
            log.warn("unexpected uniform '{s}' in shader", .{name});
            return error.InvalidDescription;
        };
        const kind = findLayoutKind(self, layout, descriptor.set, descriptor.binding) orelse
            return error.InvalidDescription;
        const count: u32 = @intCast(@max(size, 1));
        const is_image = isImageUniformType(uniform_type);
        const is_sampler = isSamplerUniformType(uniform_type);
        const point = if (is_image) blk: {
            if (kind != .storage_texture) return error.InvalidDescription;
            if (image_next + count > self.limits.max_image_units) {
                return error.Unsupported;
            }
            const first = image_next;
            image_next += count;
            break :blk first;
        } else if (is_sampler) blk: {
            if (kind == .uniform_buffer or kind == .storage_buffer or
                kind == .storage_texture)
            {
                return error.InvalidDescription;
            }
            if (texture_next + count > self.limits.max_texture_units) {
                return error.Unsupported;
            }
            const first = texture_next;
            const location = glad.getUniformLocation(
                program,
                @ptrCast(name_buffer[0..name.len :0].ptr),
            );
            if (location < 0) return error.InvalidDescription;
            const units = self.allocator.alloc(
                GLint,
                count,
            ) catch return error.OutOfHostMemory;
            defer self.allocator.free(units);
            for (units, 0..) |*unit, index| {
                unit.* = @intCast(first + index);
            }
            glad.programUniform1iv(
                program,
                location,
                @intCast(count),
                units.ptr,
            );
            try self.takeGlError("glProgramUniform1iv");
            texture_next += count;
            break :blk first;
        } else {
            log.warn("uniform '{s}' is not a descriptor", .{name});
            return error.InvalidDescription;
        };
        bindings.append(self.allocator, .{
            .set = descriptor.set,
            .binding = descriptor.binding,
            .kind = kind,
            .point = point,
            .count = count,
        }) catch return error.OutOfHostMemory;
    }
    try self.takeGlError("uniform bindings");

    return .{
        .program = program,
        .bind_point = .graphics,
        .layout = layout_resource,
        .bindings = bindings.toOwnedSlice(self.allocator) catch
            return error.OutOfHostMemory,
        .push_binding = push_binding,
        .push_size = layout.push_size,
        .vertex_bindings = &.{},
        .color_formats = &.{},
    };
}

fn parseDescriptorName(name: []const u8) ?struct {
    set: u32,
    binding: u32,
} {
    const prefix = "vfrhi_set_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const separator = "_binding_";
    const position = std.mem.indexOf(u8, rest, separator) orelse
        return null;
    const set = std.fmt.parseInt(u32, rest[0..position], 10) catch
        return null;
    const binding_text = rest[position + separator.len ..];
    const end = std.mem.indexOfAny(u8, binding_text, "_[") orelse
        binding_text.len;
    const binding = std.fmt.parseInt(
        u32,
        binding_text[0..end],
        10,
    ) catch return null;
    return .{ .set = set, .binding = binding };
}

fn findLayoutKind(
    self: *OpenGL,
    layout: *PipelineLayoutState,
    set: u32,
    binding: u32,
) ?types.DescriptorKind {
    if (set >= layout.descriptor_sets.len) return null;
    const resource = layout.descriptor_sets[set];
    const slot = self.lookup(resource, .descriptor_set_layout) catch
        return null;
    for (slot.handle.descriptor_set_layout.bindings) |candidate| {
        if (candidate.binding == binding) return candidate.kind;
    }
    return null;
}

// Keep buildPipelineBindings free of repeated global lookups by
// deduplicating its vertex bindings through this helper.
fn findVertexBinding(
    bindings: []const types.VertexLayout.Binding,
    binding: u32,
) ?types.VertexLayout.Binding {
    for (bindings) |candidate| {
        if (candidate.binding == binding) return candidate;
    }
    return null;
}

fn createCommandBuffer(
    self: *OpenGL,
    description: types.CommandBufferDescription,
) Error!Resource {
    return self.newSlot(.command_buffer, .{ .command_buffer = .{
        .level = description.level,
    } });
}

fn createFence(
    self: *OpenGL,
    description: types.FenceDescription,
) Error!Resource {
    return self.newSlot(.fence, .{ .fence = .{
        .signaled = description.signaled,
    } });
}

fn createSemaphore(
    self: *OpenGL,
    description: types.SemaphoreDescription,
) Error!Resource {
    _ = description;
    return self.newSlot(.semaphore, .{ .semaphore = .{} });
}

fn createBatch(
    self: *OpenGL,
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
        resources[index] = try self.createResource(description, ret_addr);
        created += 1;
    }
}

fn destroyResource(self: *OpenGL, resource: Resource) void {
    const slot = self.lookup(resource, resource.tag) catch return;
    switch (slot.handle) {
        .surface => {},
        .swapchain => |value| {
            for (value.views) |view| self.destroyIfAlive(view);
            for (value.images) |image| self.destroyIfAlive(image);
            if (value.fbo != 0) glad.deleteFramebuffers(1, &value.fbo);
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .buffer => |value| {
            var handle = value.handle;
            if (value.mapped != null) _ = glad.unmapNamedBuffer(handle);
            glad.deleteBuffers(1, &handle);
        },
        .texture => |value| {
            if (value.owns_handle) {
                var handle = value.handle;
                glad.deleteTextures(1, &handle);
            }
        },
        .texture_view => |value| {
            var handle = value.handle;
            glad.deleteTextures(1, &handle);
        },
        .sampler => |handle| {
            var value = handle;
            glad.deleteSamplers(1, &value);
        },
        .shader => |value| {
            glad.deleteShader(value.handle);
        },
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            if (value.push_buffer != 0) {
                var handle = value.push_buffer;
                glad.deleteBuffers(1, &handle);
            }
            if (value.push_bytes.len != 0) {
                self.allocator.free(value.push_bytes);
            }
            self.allocator.free(value.descriptor_sets);
            self.allocator.free(value.push_constants);
        },
        .descriptor_set => |*value| {
            value.writes.deinit(self.allocator);
        },
        .pipeline => |value| {
            if (value.vao != 0) {
                var vao = value.vao;
                glad.deleteVertexArrays(1, &vao);
            }
            glad.deleteProgram(value.program);
            if (value.bindings.len != 0) {
                self.allocator.free(value.bindings);
            }
            if (value.vertex_bindings.len != 0) {
                self.allocator.free(value.vertex_bindings);
            }
            if (value.color_formats.len != 0) {
                self.allocator.free(value.color_formats);
            }
        },
        .command_buffer => |*value| {
            if (value.fbo != 0) {
                glad.deleteFramebuffers(1, &value.fbo);
            }
            value.bound_sets.deinit(self.allocator);
            value.vertex_buffers.deinit(self.allocator);
        },
        .fence => |value| {
            if (value.sync) |sync| glad.deleteSync(@ptrCast(sync));
        },
        .semaphore => {},
    }
    self.releaseSlot(resource);
}

fn destroyIfAlive(self: *OpenGL, resource: Resource) void {
    _ = self.lookup(resource, resource.tag) catch return;
    self.destroyResource(resource);
}

fn forceRelease(self: *OpenGL, resource: Resource) void {
    if (self.lookup(resource, resource.tag)) |slot| {
        switch (slot.handle) {
            .swapchain => |value| {
                self.allocator.free(value.images);
                self.allocator.free(value.views);
            },
            else => {},
        }
    } else |_| {}
    self.releaseSlot(resource);
}

fn map(
    self: *OpenGL,
    resource: Resource,
    offset: u64,
    size: u64,
) Error![]u8 {
    const slot = try self.lookup(resource, .buffer);
    const buffer = &slot.handle.buffer;
    if (!buffer.memory.host_visible) return error.Unsupported;
    if (buffer.mapped != null) return error.InvalidResource;
    if (size == 0) return error.InvalidDescription;
    if (offset > buffer.size or size > buffer.size - offset) {
        return error.InvalidDescription;
    }
    const pointer = glad.mapNamedBufferRange(
        buffer.handle,
        @intCast(offset),
        @intCast(size),
        glad.MAP_READ_BIT | glad.MAP_WRITE_BIT,
    );
    if (pointer == null) return error.OutOfHostMemory;
    const bytes: [*]u8 = @ptrCast(pointer.?);
    buffer.mapped = bytes;
    return bytes[0..@intCast(size)];
}

fn unmap(
    self: *OpenGL,
    resource: Resource,
    dirty: []const Device.Dirty,
) void {
    _ = dirty;
    const slot = self.lookup(resource, .buffer) catch return;
    const buffer = &slot.handle.buffer;
    if (buffer.mapped == null) {
        log.warn("unmap of an unmapped buffer", .{});
        return;
    }
    buffer.mapped = null;
    if (glad.unmapNamedBuffer(buffer.handle) == glad.FALSE) {
        log.warn("glUnmapNamedBuffer failed", .{});
    }
}

fn getQueue(self: *OpenGL, index: u32) Error!Queue {
    if (index != 0) return error.Unsupported;
    return .{
        .vptr = self,
        .vtable = &queue_vtable,
        .family_index = 0,
        .queue_index = 0,
    };
}

fn record(
    self: *OpenGL,
    resource: Resource,
    command: commands.Command,
) Error!void {
    const slot = try self.lookup(resource, .command_buffer);
    const command_buffer = &slot.handle.command_buffer;

    switch (command) {
        .begin => {
            if (command_buffer.state == .recording) {
                return error.InvalidResource;
            }
            if (command_buffer.fbo != 0) {
                glad.deleteFramebuffers(1, &command_buffer.fbo);
                command_buffer.fbo = 0;
            }
            command_buffer.state = .recording;
            command_buffer.in_rendering = false;
            command_buffer.pipeline = null;
            command_buffer.bound_sets.clearRetainingCapacity();
            command_buffer.vertex_buffers.clearRetainingCapacity();
            command_buffer.index_buffer = null;
            command_buffer.viewport_set = false;
            command_buffer.color_attachment_count = 0;
            command_buffer.depth_attachment = false;
            @memset(&command_buffer.color_dont_care, false);
            command_buffer.depth_dont_care = false;
        },
        .end => {
            if (command_buffer.state != .recording) {
                return error.InvalidResource;
            }
            if (command_buffer.in_rendering) {
                return error.InvalidDescription;
            }
            command_buffer.state = .ended;
        },
        .begin_rendering => |value| try self.beginRendering(
            command_buffer,
            value,
        ),
        .end_rendering => {
            if (!command_buffer.in_rendering) {
                return error.InvalidDescription;
            }
            try self.endRendering(command_buffer);
        },
        .bind_pipeline => |value| {
            try requireRecording(command_buffer);
            const pipeline = try self.lookup(value.pipeline, .pipeline);
            command_buffer.pipeline = value.pipeline;
            try self.applyPipelineState(
                command_buffer,
                &pipeline.handle.pipeline,
            );
        },
        .bind_vertex_buffers => |value| {
            try requireRecording(command_buffer);
            if (value.offsets.len != 0 and
                value.offsets.len != value.buffers.len)
            {
                return error.InvalidDescription;
            }
            for (value.buffers, 0..) |buffer, index| {
                const buffer_slot = try self.lookup(buffer, .buffer);
                if (!buffer_slot.handle.buffer.usage.vertex) {
                    return error.InvalidDescription;
                }
                const binding = value.first_binding + @as(u32, @intCast(index));
                removeVertexBinding(
                    &command_buffer.vertex_buffers,
                    binding,
                );
                command_buffer.vertex_buffers.append(
                    self.allocator,
                    .{
                        .binding = binding,
                        .buffer = buffer,
                        .offset = if (value.offsets.len == 0)
                            0
                        else
                            value.offsets[index],
                    },
                ) catch return error.OutOfHostMemory;
            }
            if (command_buffer.pipeline) |pipeline_resource| {
                const pipeline = try self.lookup(
                    pipeline_resource,
                    .pipeline,
                );
                try self.applyVertexBuffers(
                    command_buffer,
                    &pipeline.handle.pipeline,
                );
            }
        },
        .bind_index_buffer => |value| {
            try requireRecording(command_buffer);
            const index_buffer = try self.lookup(value.buffer, .buffer);
            if (!index_buffer.handle.buffer.usage.index) {
                return error.InvalidDescription;
            }
            command_buffer.index_buffer = .{
                .buffer = value.buffer,
                .offset = value.offset,
                .index_type = value.type,
            };
            if (command_buffer.pipeline) |pipeline_resource| {
                const pipeline = try self.lookup(
                    pipeline_resource,
                    .pipeline,
                );
                if (pipeline.handle.pipeline.vao != 0) {
                    const buffer = try self.lookup(value.buffer, .buffer);
                    glad.vertexArrayElementBuffer(
                        pipeline.handle.pipeline.vao,
                        buffer.handle.buffer.handle,
                    );
                }
            }
        },
        .bind_descriptor_sets => |value| {
            try requireRecording(command_buffer);
            if (value.dynamic_offsets.len != 0) {
                return error.Unsupported;
            }
            _ = try self.lookup(value.layout, .pipeline_layout);
            for (value.sets, 0..) |set, index| {
                _ = try self.lookup(set, .descriptor_set);
                const set_index = value.first_set +
                    @as(u32, @intCast(index));
                removeBoundSet(&command_buffer.bound_sets, set_index);
                command_buffer.bound_sets.append(
                    self.allocator,
                    .{ .set = set_index, .resource = set },
                ) catch return error.OutOfHostMemory;
            }
        },
        .set_viewport => |value| {
            try requireRecording(command_buffer);
            if (value.width <= 0 or value.height <= 0) {
                return error.InvalidDescription;
            }
            glad.viewport(
                @intFromFloat(value.x),
                @intFromFloat(value.y),
                @intFromFloat(value.width),
                @intFromFloat(value.height),
            );
            command_buffer.viewport_set = true;
        },
        .set_scissor => |value| {
            try requireRecording(command_buffer);
            if (value.width == 0 or value.height == 0) {
                return error.InvalidDescription;
            }
            glad.enable(glad.SCISSOR_TEST);
            glad.scissor(
                value.x,
                value.y,
                @intCast(value.width),
                @intCast(value.height),
            );
        },
        .draw => |value| {
            try self.requireDraw(command_buffer);
            if (value.vertex_count == 0) {
                return error.InvalidDescription;
            }
            const pipeline_slot = try self.lookup(
                command_buffer.pipeline.?,
                .pipeline,
            );
            const pipeline = &pipeline_slot.handle.pipeline;
            try self.applyDescriptors(command_buffer, pipeline);
            glad.drawArraysInstancedBaseInstance(
                toGlTopology(pipeline.topology),
                @intCast(value.first_vertex),
                @intCast(value.vertex_count),
                @intCast(value.instance_count),
                value.first_instance,
            );
        },
        .draw_indexed => |value| {
            try self.requireDraw(command_buffer);
            if (value.index_count == 0) {
                return error.InvalidDescription;
            }
            const index = command_buffer.index_buffer orelse
                return error.InvalidDescription;
            const pipeline_slot = try self.lookup(
                command_buffer.pipeline.?,
                .pipeline,
            );
            const pipeline = &pipeline_slot.handle.pipeline;
            try self.applyDescriptors(command_buffer, pipeline);
            glad.drawElementsInstancedBaseVertexBaseInstance(
                toGlTopology(pipeline.topology),
                @intCast(value.index_count),
                switch (index.index_type) {
                    .uint16 => glad.UNSIGNED_SHORT,
                    .uint32 => glad.UNSIGNED_INT,
                },
                @ptrFromInt(@as(usize, @intCast(index.offset))),
                @intCast(value.instance_count),
                value.vertex_offset,
                value.first_instance,
            );
        },
        .dispatch => |value| {
            try requireRecording(command_buffer);
            const pipeline_resource = command_buffer.pipeline orelse
                return error.InvalidDescription;
            const pipeline_slot = try self.lookup(
                pipeline_resource,
                .pipeline,
            );
            const pipeline = &pipeline_slot.handle.pipeline;
            if (pipeline.bind_point != .compute) {
                return error.InvalidDescription;
            }
            if (value.x == 0 or value.y == 0 or value.z == 0) {
                return error.InvalidDescription;
            }
            glad.useProgram(pipeline.program);
            try self.applyDescriptors(command_buffer, pipeline);
            glad.dispatchCompute(value.x, value.y, value.z);
        },
        .copy_buffer => |value| {
            try requireRecording(command_buffer);
            const src = try self.lookup(value.src, .buffer);
            const dst = try self.lookup(value.dst, .buffer);
            for (value.regions) |region| {
                if (region.src_offset > src.handle.buffer.size or
                    region.size > src.handle.buffer.size - region.src_offset or
                    region.dst_offset > dst.handle.buffer.size or
                    region.size > dst.handle.buffer.size - region.dst_offset)
                {
                    return error.InvalidDescription;
                }
                glad.copyNamedBufferSubData(
                    src.handle.buffer.handle,
                    dst.handle.buffer.handle,
                    @intCast(region.src_offset),
                    @intCast(region.dst_offset),
                    @intCast(region.size),
                );
            }
        },
        .copy_buffer_to_texture => |value| try self.copyBufferToTexture(
            command_buffer,
            value,
        ),
        .copy_texture_to_buffer => |value| try self.copyTextureToBuffer(
            command_buffer,
            value,
        ),
        .copy_texture => |value| {
            try requireRecording(command_buffer);
            const src = try self.lookup(value.src, .texture);
            const dst = try self.lookup(value.dst, .texture);
            for (value.regions) |region| {
                if (region.extent.width == 0 or
                    region.extent.height == 0 or
                    region.extent.depth == 0)
                {
                    return error.InvalidDescription;
                }
                if (region.mip_level >=
                    src.handle.texture.properties.mip_levels or
                    region.mip_level >=
                        dst.handle.texture.properties.mip_levels or
                    region.array_layer >=
                        src.handle.texture.properties.array_layers or
                    region.array_layer >=
                        dst.handle.texture.properties.array_layers)
                {
                    return error.InvalidDescription;
                }
                glad.copyImageSubData(
                    src.handle.texture.handle,
                    toGlTextureTarget(src.handle.texture.properties),
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.offset.y),
                    @intCast(region.array_layer),
                    dst.handle.texture.handle,
                    toGlTextureTarget(dst.handle.texture.properties),
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.offset.y),
                    @intCast(region.array_layer),
                    @intCast(region.extent.width),
                    @intCast(region.extent.height),
                    @intCast(region.extent.depth),
                );
            }
        },
        .barrier => |value| {
            try requireRecording(command_buffer);
            const barrier_slot = try self.lookup(
                value.resource,
                value.resource.tag,
            );
            switch (barrier_slot.handle) {
                .texture => |*texture| {
                    if (texture.layout != value.layout_before) {
                        return error.InvalidDescription;
                    }
                    texture.layout = value.layout_after;
                },
                .buffer => {},
                else => return error.InvalidResource,
            }
            glad.memoryBarrier(glad.ALL_BARRIER_BITS);
        },
        .push_constants => |value| {
            try requireRecording(command_buffer);
            const layout_slot = try self.lookup(
                value.layout,
                .pipeline_layout,
            );
            const layout = &layout_slot.handle.pipeline_layout;
            if (value.data.len == 0 or
                value.offset + value.data.len > layout.push_size)
            {
                return error.InvalidDescription;
            }
            @memcpy(
                layout.push_bytes[value.offset..][0..value.data.len],
                value.data,
            );
            glad.namedBufferSubData(
                layout.push_buffer,
                @intCast(value.offset),
                @intCast(value.data.len),
                value.data.ptr,
            );
        },
    }
}

fn requireRecording(command_buffer: *CommandBufferState) Error!void {
    if (command_buffer.state != .recording) {
        return error.InvalidResource;
    }
}

fn requireDraw(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
) Error!void {
    try requireRecording(command_buffer);
    if (!command_buffer.in_rendering) {
        return error.InvalidDescription;
    }
    const pipeline_resource = command_buffer.pipeline orelse
        return error.InvalidDescription;
    const pipeline = try self.lookup(pipeline_resource, .pipeline);
    if (pipeline.handle.pipeline.bind_point != .graphics) {
        return error.InvalidDescription;
    }
    if (!command_buffer.viewport_set) {
        return error.InvalidDescription;
    }
    for (pipeline.handle.pipeline.vertex_bindings) |binding| {
        if (!hasVertexBinding(
            command_buffer.vertex_buffers.items,
            binding.binding,
        )) {
            return error.InvalidDescription;
        }
    }
}

fn hasVertexBinding(
    bindings: []const VertexBinding,
    binding: u32,
) bool {
    for (bindings) |candidate| {
        if (candidate.binding == binding) return true;
    }
    return false;
}

fn removeVertexBinding(
    bindings: *std.ArrayListUnmanaged(VertexBinding),
    binding: u32,
) void {
    var index: usize = 0;
    while (index < bindings.items.len) {
        if (bindings.items[index].binding == binding) {
            _ = bindings.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

fn removeBoundSet(
    sets: *std.ArrayListUnmanaged(BoundSet),
    set: u32,
) void {
    var index: usize = 0;
    while (index < sets.items.len) {
        if (sets.items[index].set == set) {
            _ = sets.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

fn applyPipelineState(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    pipeline: *PipelineState,
) Error!void {
    glad.useProgram(pipeline.program);
    if (pipeline.bind_point != .graphics) {
        glad.bindVertexArray(0);
        return;
    }
    glad.bindVertexArray(pipeline.vao);
    try self.applyVertexBuffers(command_buffer, pipeline);

    glad.frontFace(switch (pipeline.front_face) {
        .clockwise => glad.CW,
        .counter_clockwise => glad.CCW,
    });
    switch (pipeline.cull) {
        .none => glad.disable(glad.CULL_FACE),
        .front => {
            glad.enable(glad.CULL_FACE);
            glad.cullFace(glad.FRONT);
        },
        .back => {
            glad.enable(glad.CULL_FACE);
            glad.cullFace(glad.BACK);
        },
        .front_and_back => {
            glad.enable(glad.CULL_FACE);
            glad.cullFace(glad.FRONT_AND_BACK);
        },
    }
    glad.polygonMode(glad.FRONT_AND_BACK, glad.FILL);

    if (pipeline.depth_format != null and pipeline.depth.enable) {
        glad.enable(glad.DEPTH_TEST);
        glad.depthFunc(toGlCompareOp(pipeline.depth.compare));
        glad.depthMask(if (pipeline.depth.write) glad.TRUE else glad.FALSE);
    } else {
        glad.disable(glad.DEPTH_TEST);
        glad.depthMask(glad.FALSE);
    }

    if (pipeline.blend.enabled) {
        glad.enable(glad.BLEND);
        glad.blendEquationSeparate(
            toGlBlendOp(pipeline.blend.op_color),
            toGlBlendOp(pipeline.blend.op_alpha),
        );
        glad.blendFuncSeparate(
            toGlBlendFactor(pipeline.blend.src_color),
            toGlBlendFactor(pipeline.blend.dst_color),
            toGlBlendFactor(pipeline.blend.src_alpha),
            toGlBlendFactor(pipeline.blend.dst_alpha),
        );
    } else {
        glad.disable(glad.BLEND);
    }
    glad.colorMask(
        glad.TRUE,
        glad.TRUE,
        glad.TRUE,
        glad.TRUE,
    );
}

fn applyVertexBuffers(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    pipeline: *PipelineState,
) Error!void {
    for (command_buffer.vertex_buffers.items) |binding| {
        const vertex_binding = findVertexBinding(
            pipeline.vertex_bindings,
            binding.binding,
        ) orelse return error.InvalidDescription;
        const buffer = try self.lookup(binding.buffer, .buffer);
        glad.vertexArrayVertexBuffer(
            pipeline.vao,
            binding.binding,
            buffer.handle.buffer.handle,
            @intCast(binding.offset),
            @intCast(vertex_binding.stride),
        );
    }
    if (command_buffer.index_buffer) |index| {
        const buffer = try self.lookup(index.buffer, .buffer);
        glad.vertexArrayElementBuffer(
            pipeline.vao,
            buffer.handle.buffer.handle,
        );
    }
}

fn applyDescriptors(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    pipeline: *PipelineState,
) Error!void {
    for (command_buffer.bound_sets.items) |bound| {
        const set_slot = try self.lookup(bound.resource, .descriptor_set);
        const set = &set_slot.handle.descriptor_set;
        for (set.writes.items) |write| {
            const mapping = findProgramBinding(
                pipeline.bindings,
                bound.set,
                write.binding,
            ) orelse continue;
            if (write.array_index >= mapping.count) {
                return error.InvalidDescription;
            }
            const point = mapping.point + write.array_index;
            switch (write.kind) {
                .buffer => |value| {
                    if (mapping.kind != .uniform_buffer and
                        mapping.kind != .storage_buffer)
                    {
                        return error.InvalidDescription;
                    }
                    const buffer = try self.lookup(value.buffer, .buffer);
                    const range = if (value.size == 0)
                        buffer.handle.buffer.size - value.offset
                    else
                        value.size;
                    if (value.offset > buffer.handle.buffer.size or
                        range > buffer.handle.buffer.size - value.offset)
                    {
                        return error.InvalidDescription;
                    }
                    if (mapping.kind == .uniform_buffer and
                        self.limits.uniform_buffer_offset_alignment != 0 and
                        value.offset %
                            self.limits.uniform_buffer_offset_alignment != 0)
                    {
                        return error.InvalidDescription;
                    }
                    glad.bindBufferRange(
                        if (mapping.kind == .uniform_buffer)
                            glad.UNIFORM_BUFFER
                        else
                            glad.SHADER_STORAGE_BUFFER,
                        point,
                        buffer.handle.buffer.handle,
                        @intCast(value.offset),
                        @intCast(range),
                    );
                },
                .texture => |value| {
                    const view = try self.lookup(
                        value.view,
                        .texture_view,
                    );
                    if (mapping.kind == .storage_texture) {
                        const internal = glInternalFormat(
                            view.handle.texture_view.format,
                        ) orelse return error.InvalidDescription;
                        glad.bindImageTexture(
                            point,
                            view.handle.texture_view.handle,
                            0,
                            if (view.handle.texture_view.arrayed)
                                glad.TRUE
                            else
                                glad.FALSE,
                            0,
                            glad.READ_WRITE,
                            internal,
                        );
                    } else {
                        glad.bindTextureUnit(
                            point,
                            view.handle.texture_view.handle,
                        );
                        if (value.sampler) |sampler_resource| {
                            const sampler = try self.lookup(
                                sampler_resource,
                                .sampler,
                            );
                            glad.bindSampler(point, sampler.handle.sampler);
                        } else {
                            glad.bindSampler(point, 0);
                        }
                    }
                },
                .sampler => |sampler_resource| {
                    if (mapping.kind != .sampler) {
                        return error.InvalidDescription;
                    }
                    const sampler = try self.lookup(
                        sampler_resource,
                        .sampler,
                    );
                    glad.bindSampler(point, sampler.handle.sampler);
                },
            }
        }
    }

    if (pipeline.push_binding) |binding| {
        const layout_slot = try self.lookup(
            pipeline.layout,
            .pipeline_layout,
        );
        const layout = &layout_slot.handle.pipeline_layout;
        if (layout.push_buffer != 0) {
            glad.bindBufferBase(
                glad.UNIFORM_BUFFER,
                binding,
                layout.push_buffer,
            );
        }
    }
    try self.takeGlError("descriptor binding");
}

fn findProgramBinding(
    bindings: []const ProgramBinding,
    set: u32,
    binding: u32,
) ?ProgramBinding {
    for (bindings) |candidate| {
        if (candidate.set == set and candidate.binding == binding) {
            return candidate;
        }
    }
    return null;
}

fn beginRendering(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    description: commands.BeginRendering,
) Error!void {
    try requireRecording(command_buffer);
    if (command_buffer.in_rendering) {
        return error.InvalidDescription;
    }
    if (description.area.width == 0 or description.area.height == 0) {
        return error.InvalidDescription;
    }
    if (description.color_attachments.len >
        @min(self.limits.max_color_attachments, 8))
    {
        return error.Unsupported;
    }

    var fbo: GLuint = 0;
    glad.createFramebuffers(1, &fbo);
    errdefer glad.deleteFramebuffers(1, &fbo);

    var attachments: [8]GLenum = undefined;
    for (description.color_attachments, 0..) |attachment, index| {
        const view = try self.lookup(attachment.view, .texture_view);
        glad.namedFramebufferTexture(
            fbo,
            @as(GLenum, @intCast(glad.COLOR_ATTACHMENT0)) +
                @as(GLenum, @intCast(index)),
            view.handle.texture_view.handle,
            0,
        );
        attachments[index] = @as(GLenum, @intCast(glad.COLOR_ATTACHMENT0)) +
            @as(GLenum, @intCast(index));
    }
    if (description.color_attachments.len != 0) {
        glad.namedFramebufferDrawBuffers(
            fbo,
            @intCast(description.color_attachments.len),
            &attachments,
        );
    } else {
        glad.namedFramebufferDrawBuffer(fbo, glad.NONE);
    }

    var depth_attachment: GLenum = glad.NONE;
    if (description.depth_attachment) |attachment| {
        const view = try self.lookup(attachment.view, .texture_view);
        depth_attachment = switch (view.handle.texture_view.aspect) {
            .depth_stencil => glad.DEPTH_STENCIL_ATTACHMENT,
            else => glad.DEPTH_ATTACHMENT,
        };
        glad.namedFramebufferTexture(
            fbo,
            depth_attachment,
            view.handle.texture_view.handle,
            0,
        );
    }

    const status = glad.checkNamedFramebufferStatus(fbo, glad.FRAMEBUFFER);
    if (status != glad.FRAMEBUFFER_COMPLETE) {
        log.warn(
            "framebuffer is incomplete: 0x{x}",
            .{status},
        );
        return error.InvalidDescription;
    }

    glad.bindFramebuffer(glad.FRAMEBUFFER, fbo);
    glad.enable(glad.FRAMEBUFFER_SRGB);
    glad.colorMask(glad.TRUE, glad.TRUE, glad.TRUE, glad.TRUE);

    glad.enable(glad.SCISSOR_TEST);
    glad.scissor(
        description.area.x,
        description.area.y,
        @intCast(description.area.width),
        @intCast(description.area.height),
    );

    command_buffer.fbo = fbo;
    command_buffer.in_rendering = true;
    command_buffer.color_attachment_count = @intCast(
        description.color_attachments.len,
    );
    command_buffer.depth_attachment = description.depth_attachment != null;
    @memset(&command_buffer.color_dont_care, false);
    command_buffer.depth_dont_care = false;

    for (description.color_attachments, 0..) |attachment, index| {
        switch (attachment.load) {
            .clear => {
                const value = [4]GLfloat{
                    attachment.clear.r,
                    attachment.clear.g,
                    attachment.clear.b,
                    attachment.clear.a,
                };
                glad.clearBufferfv(
                    glad.COLOR,
                    @intCast(index),
                    &value,
                );
            },
            .load, .dont_care => {},
        }
        command_buffer.color_dont_care[index] =
            attachment.store == .dont_care;
    }
    if (description.depth_attachment) |attachment| {
        switch (attachment.load) {
            .clear => {
                const aspect = if (attachment.view.tag == .texture_view) blk: {
                    const view = try self.lookup(
                        attachment.view,
                        .texture_view,
                    );
                    break :blk view.handle.texture_view.aspect;
                } else .depth;
                if (aspect == .depth_stencil) {
                    glad.clearBufferfi(
                        glad.DEPTH_STENCIL,
                        0,
                        attachment.clear_depth,
                        @intCast(attachment.clear_stencil),
                    );
                } else {
                    const value = [1]GLfloat{attachment.clear_depth};
                    glad.clearBufferfv(glad.DEPTH, 0, &value);
                }
            },
            .load, .dont_care => {},
        }
        command_buffer.depth_dont_care =
            attachment.store == .dont_care;
    }
    try self.takeGlError("beginRendering");
}

fn endRendering(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
) Error!void {
    if (command_buffer.fbo != 0) {
        var invalidate: [9]GLenum = undefined;
        var count: usize = 0;
        var index: usize = 0;
        while (index < command_buffer.color_attachment_count) : (index += 1) {
            if (!command_buffer.color_dont_care[index]) continue;
            invalidate[count] = @as(GLenum, @intCast(glad.COLOR_ATTACHMENT0)) +
                @as(GLenum, @intCast(index));
            count += 1;
        }
        if (command_buffer.depth_attachment and
            command_buffer.depth_dont_care)
        {
            invalidate[count] = glad.DEPTH_ATTACHMENT;
            count += 1;
        }
        if (count != 0) {
            glad.invalidateNamedFramebufferData(
                command_buffer.fbo,
                @intCast(count),
                &invalidate,
            );
        }
    }
    glad.bindFramebuffer(glad.FRAMEBUFFER, 0);
    if (command_buffer.fbo != 0) {
        glad.deleteFramebuffers(1, &command_buffer.fbo);
        command_buffer.fbo = 0;
    }
    command_buffer.in_rendering = false;
    try self.takeGlError("endRendering");
}

fn copyBufferToTexture(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    value: commands.CopyBufferToTexture,
) Error!void {
    try requireRecording(command_buffer);
    const buffer = try self.lookup(value.buffer, .buffer);
    const texture = try self.lookup(value.texture, .texture);
    const format = glFormat(texture.handle.texture.properties.format) orelse
        return error.InvalidDescription;
    const bpp = texture.handle.texture.properties.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    if (value.region.mip_level >=
        texture.handle.texture.properties.mip_levels or
        value.region.array_layer >=
            texture.handle.texture.properties.array_layers or
        value.region.extent.width == 0 or
        value.region.extent.height == 0 or
        value.region.extent.depth == 0)
    {
        return error.InvalidDescription;
    }
    if (value.row_pitch != 0 and value.row_pitch % bpp != 0) {
        return error.InvalidDescription;
    }
    const row_bytes: u64 = if (value.row_pitch == 0)
        @as(u64, value.region.extent.width) * bpp
    else
        value.row_pitch;
    const copy_rows: u64 = if (value.image_height == 0)
        value.region.extent.height
    else
        value.image_height;
    const required_bytes = row_bytes *
        copy_rows *
        value.region.extent.depth;
    if (value.buffer_offset > buffer.handle.buffer.size or
        required_bytes >
            buffer.handle.buffer.size - value.buffer_offset)
    {
        return error.BufferTooSmall;
    }
    glad.bindBuffer(glad.PIXEL_UNPACK_BUFFER, buffer.handle.buffer.handle);
    defer glad.bindBuffer(glad.PIXEL_UNPACK_BUFFER, 0);
    glad.pixelStorei(glad.UNPACK_ALIGNMENT, 1);
    defer glad.pixelStorei(glad.UNPACK_ALIGNMENT, 4);
    if (value.row_pitch != 0) {
        glad.pixelStorei(
            glad.UNPACK_ROW_LENGTH,
            @intCast(value.row_pitch / bpp),
        );
    }
    if (value.image_height != 0) {
        glad.pixelStorei(
            glad.UNPACK_IMAGE_HEIGHT,
            @intCast(value.image_height),
        );
    }
    defer {
        glad.pixelStorei(glad.UNPACK_ROW_LENGTH, 0);
        glad.pixelStorei(glad.UNPACK_IMAGE_HEIGHT, 0);
    }
    const offset: usize = @intCast(value.buffer_offset);
    const pointer: ?*const anyopaque = if (offset == 0)
        null
    else
        @ptrFromInt(offset);
    const region = value.region;
    switch (texture.handle.texture.properties.type) {
        .@"1d" => {
            if (texture.handle.texture.properties.array_layers > 1) {
                glad.textureSubImage2D(
                    texture.handle.texture.handle,
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.array_layer),
                    @intCast(region.extent.width),
                    @intCast(region.extent.depth),
                    format.format,
                    format.pixel_type,
                    pointer,
                );
            } else {
                glad.textureSubImage1D(
                    texture.handle.texture.handle,
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.extent.width),
                    format.format,
                    format.pixel_type,
                    pointer,
                );
            }
        },
        .@"2d" => {
            if (texture.handle.texture.properties.array_layers > 1) {
                glad.textureSubImage3D(
                    texture.handle.texture.handle,
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.offset.y),
                    @intCast(region.array_layer),
                    @intCast(region.extent.width),
                    @intCast(region.extent.height),
                    @intCast(region.extent.depth),
                    format.format,
                    format.pixel_type,
                    pointer,
                );
            } else {
                glad.textureSubImage2D(
                    texture.handle.texture.handle,
                    @intCast(region.mip_level),
                    @intCast(region.offset.x),
                    @intCast(region.offset.y),
                    @intCast(region.extent.width),
                    @intCast(region.extent.height),
                    format.format,
                    format.pixel_type,
                    pointer,
                );
            }
        },
        .@"3d" => glad.textureSubImage3D(
            texture.handle.texture.handle,
            @intCast(region.mip_level),
            @intCast(region.offset.x),
            @intCast(region.offset.y),
            @intCast(region.offset.z),
            @intCast(region.extent.width),
            @intCast(region.extent.height),
            @intCast(region.extent.depth),
            format.format,
            format.pixel_type,
            pointer,
        ),
    }
    try self.takeGlError("copyBufferToTexture");
}

fn copyTextureToBuffer(
    self: *OpenGL,
    command_buffer: *CommandBufferState,
    value: commands.CopyTextureToBuffer,
) Error!void {
    try requireRecording(command_buffer);
    const buffer = try self.lookup(value.buffer, .buffer);
    const texture = try self.lookup(value.texture, .texture);
    const format = glFormat(texture.handle.texture.properties.format) orelse
        return error.InvalidDescription;
    const bpp = texture.handle.texture.properties.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    if (value.region.mip_level >=
        texture.handle.texture.properties.mip_levels or
        value.region.array_layer >=
            texture.handle.texture.properties.array_layers or
        value.region.extent.width == 0 or
        value.region.extent.height == 0 or
        value.region.extent.depth == 0)
    {
        return error.InvalidDescription;
    }
    if (value.row_pitch != 0 and value.row_pitch % bpp != 0) {
        return error.InvalidDescription;
    }
    glad.bindBuffer(glad.PIXEL_PACK_BUFFER, buffer.handle.buffer.handle);
    defer glad.bindBuffer(glad.PIXEL_PACK_BUFFER, 0);
    glad.pixelStorei(glad.PACK_ALIGNMENT, 1);
    if (value.row_pitch != 0) {
        glad.pixelStorei(
            glad.PACK_ROW_LENGTH,
            @intCast(value.row_pitch / bpp),
        );
    }
    if (value.image_height != 0) {
        glad.pixelStorei(
            glad.PACK_IMAGE_HEIGHT,
            @intCast(value.image_height),
        );
    }
    defer {
        glad.pixelStorei(glad.PACK_ROW_LENGTH, 0);
        glad.pixelStorei(glad.PACK_IMAGE_HEIGHT, 0);
        glad.pixelStorei(glad.PACK_ALIGNMENT, 4);
    }

    const row_bytes: u64 = if (value.row_pitch == 0)
        @as(u64, value.region.extent.width) * bpp
    else
        value.row_pitch;
    const copy_rows: u64 = if (value.image_height == 0)
        value.region.extent.height
    else
        value.image_height;
    const required = row_bytes * copy_rows * value.region.extent.depth;
    if (value.buffer_offset > buffer.handle.buffer.size or
        required > buffer.handle.buffer.size - value.buffer_offset)
    {
        return error.BufferTooSmall;
    }
    const offset: usize = @intCast(value.buffer_offset);
    const pointer: ?*anyopaque = if (offset == 0)
        null
    else
        @ptrFromInt(offset);
    glad.getTextureSubImage(
        texture.handle.texture.handle,
        @intCast(value.region.mip_level),
        @intCast(value.region.offset.x),
        @intCast(value.region.offset.y),
        @intCast(value.region.offset.z),
        @intCast(value.region.extent.width),
        @intCast(value.region.extent.height),
        @intCast(value.region.extent.depth),
        format.format,
        format.pixel_type,
        @intCast(required),
        pointer,
    );
    try self.takeGlError("copyTextureToBuffer");
}

fn deviceOpi(
    self: *OpenGL,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
) Error!?[]const u8 {
    _ = output_mode;
    switch (operator) {
        .wait_idle => {
            glad.finish();
            return null;
        },
        .wait_fence => |value| {
            const fence = try self.lookup(value.fence, .fence);
            try waitFence(&fence.handle.fence, value.timeout_ns);
            return null;
        },
        .reset_fence => |value| {
            const fence = try self.lookup(value.fence, .fence);
            resetFence(&fence.handle.fence);
            return null;
        },
        .write_descriptor_set => |value| {
            try self.writeDescriptorSet(value);
            return null;
        },
    }
}

fn waitFence(fence: *FenceState, timeout_ns: u64) Error!void {
    if (fence.signaled) return;
    const sync = fence.sync orelse return error.Timeout;
    const result = glad.clientWaitSync(
        @ptrCast(sync),
        glad.SYNC_FLUSH_COMMANDS_BIT,
        timeout_ns,
    );
    switch (result) {
        glad.ALREADY_SIGNALED, glad.CONDITION_SATISFIED => {
            fence.signaled = true;
        },
        glad.TIMEOUT_EXPIRED => return error.Timeout,
        glad.WAIT_FAILED => return error.DeviceLost,
        else => return error.Unknown,
    }
}

fn resetFence(fence: *FenceState) void {
    if (fence.sync) |sync| {
        glad.deleteSync(@ptrCast(sync));
        fence.sync = null;
    }
    fence.signaled = false;
}

fn signalFence(fence: *FenceState) void {
    resetFence(fence);
    const sync = glad.fenceSync(glad.SYNC_GPU_COMMANDS_COMPLETE, 0);
    fence.sync = @ptrCast(sync);
    fence.signaled = false;
}

fn writeDescriptorSet(
    self: *OpenGL,
    description: anytype,
) Error!void {
    const set_slot = try self.lookup(
        description.set,
        .descriptor_set,
    );
    const set = &set_slot.handle.descriptor_set;
    const layout_slot = try self.lookup(set.layout, .descriptor_set_layout);
    const bindings = layout_slot.handle.descriptor_set_layout.bindings;

    for (description.writes) |write| {
        const binding = findDescriptorBinding(bindings, write.binding) orelse
            return error.InvalidDescription;
        if (write.array_index >= binding.count) {
            return error.InvalidDescription;
        }
        switch (write.kind) {
            .buffer => |value| {
                if (binding.kind != .uniform_buffer and
                    binding.kind != .storage_buffer)
                {
                    return error.InvalidDescription;
                }
                _ = try self.lookup(value.buffer, .buffer);
            },
            .texture => |value| {
                if (binding.kind != .sampled_texture and
                    binding.kind != .storage_texture and
                    binding.kind != .combined_image_sampler)
                {
                    return error.InvalidDescription;
                }
                _ = try self.lookup(value.view, .texture_view);
                if (binding.kind == .combined_image_sampler and
                    value.sampler == null)
                {
                    return error.InvalidDescription;
                }
                if (value.sampler) |sampler| {
                    _ = try self.lookup(sampler, .sampler);
                }
            },
            .sampler => |sampler| {
                if (binding.kind != .sampler) {
                    return error.InvalidDescription;
                }
                _ = try self.lookup(sampler, .sampler);
            },
        }
    }
    set.writes.appendSlice(
        self.allocator,
        description.writes,
    ) catch return error.OutOfHostMemory;
}

fn findDescriptorBinding(
    bindings: []const types.DescriptorSetLayoutDescription
        .DescriptorBinding,
    binding: u32,
) ?types.DescriptorSetLayoutDescription.DescriptorBinding {
    for (bindings) |candidate| {
        if (candidate.binding == binding) return candidate;
    }
    return null;
}

fn query(
    self: *OpenGL,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
) Error!Device.QueryResult {
    return switch (feature) {
        .api_version => writeFixed(output_mode, self.version),
        .device_name => .{
            .support = .support,
            .result = try writeBytes(output_mode, self.renderer),
        },
        .driver_name => .{
            .support = .support,
            .result = try writeBytes(output_mode, self.vendor),
        },
        .device_type => writeFixed(output_mode, self.device_type),
        .limit => |limit| writeFixed(
            output_mode,
            limitValue(self.limits, limit),
        ),
        .format => |value| blk: {
            if (value.format == .undefined) {
                break :blk .{ .support = .unsupport };
            }
            const props = formatProperties(value.format);
            const usage = value.usage;
            const supported =
                (!usage.sampled or props.sampled) and
                (!usage.storage or props.storage) and
                (!usage.color_attachment or props.color_attachment) and
                (!usage.depth_attachment or props.depth_attachment) and
                (!usage.buffer or props.buffer);
            break :blk .{
                .support = if (supported) .support else .unsupport,
            };
        },
        .surface => blk: {
            const resource = handle orelse
                return error.InvalidDescription;
            const slot = try self.lookup(resource, .surface);
            break :blk writeFixed(
                output_mode,
                slot.handle.surface.properties,
            );
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
                .memory = slot.handle.buffer.memory,
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
            if (feature_index != 0) {
                break :blk .{ .support = .unsupport };
            }
            const heap: types.MemoryHeap = .{
                .size = 0,
                .device_local = true,
            };
            break :blk writeFixed(output_mode, heap);
        },
        .queue => blk: {
            if (feature_index != 0) {
                break :blk .{ .support = .unsupport };
            }
            const properties: types.QueueProperties = .{
                .capabilities = .{
                    .graphics = true,
                    .compute = true,
                    .transfer = true,
                    .present = true,
                },
                .count = 1,
                .timestamp_bits = 64,
            };
            break :blk writeFixed(output_mode, properties);
        },
    };
}

fn writeResourceList(
    self: *OpenGL,
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

fn limitValue(limits: Limits, limit: Device.Limit) u64 {
    return switch (limit) {
        .max_texture_dimension_1d => limits.max_texture_size,
        .max_texture_dimension_2d => limits.max_texture_size,
        .max_texture_dimension_3d => limits.max_3d_texture_size,
        .max_texture_array_layers => limits.max_array_texture_layers,
        .max_buffer_size => limits.max_shader_storage_block_size,
        .max_uniform_buffer_range => limits.max_uniform_block_size,
        .max_storage_buffer_range => limits.max_shader_storage_block_size,
        .max_push_constant_size => 256,
        .max_vertex_bindings => limits.max_vertex_attrib_bindings,
        .max_vertex_attributes => limits.max_vertex_attribs,
        .max_descriptor_sets => limits.max_texture_units,
        .max_color_attachments => limits.max_color_attachments,
    };
}

fn formatProperties(format: types.Format) types.FormatProperties {
    return switch (format) {
        .undefined => .{},
        .d32_float, .d24_unorm_s8_uint => .{
            .sampled = true,
            .depth_attachment = true,
        },
        .r8g8b8a8_srgb, .b8g8r8a8_srgb => .{
            .sampled = true,
            .color_attachment = true,
        },
        .b8g8r8a8_unorm => .{
            .sampled = true,
            .storage = true,
            .color_attachment = true,
        },
        else => .{
            .sampled = true,
            .storage = true,
            .color_attachment = true,
            .buffer = true,
        },
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

const GlFormat = struct {
    internal: GLenum,
    format: GLenum,
    pixel_type: GLenum,
    components: GLint,
    normalized: bool,
    integer: bool,
};

fn glFormat(format: types.Format) ?GlFormat {
    return switch (format) {
        .undefined => null,
        .r8_unorm => .{
            .internal = glad.R8,
            .format = glad.RED,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 1,
            .normalized = true,
            .integer = false,
        },
        .r8g8_unorm => .{
            .internal = glad.RG8,
            .format = glad.RG,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 2,
            .normalized = true,
            .integer = false,
        },
        .r8g8b8a8_unorm => .{
            .internal = glad.RGBA8,
            .format = glad.RGBA,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 4,
            .normalized = true,
            .integer = false,
        },
        .r8g8b8a8_srgb => .{
            .internal = glad.SRGB8_ALPHA8,
            .format = glad.RGBA,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 4,
            .normalized = true,
            .integer = false,
        },
        .b8g8r8a8_unorm => .{
            .internal = glad.RGBA8,
            .format = glad.BGRA,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 4,
            .normalized = true,
            .integer = false,
        },
        .b8g8r8a8_srgb => .{
            .internal = glad.SRGB8_ALPHA8,
            .format = glad.BGRA,
            .pixel_type = glad.UNSIGNED_BYTE,
            .components = 4,
            .normalized = true,
            .integer = false,
        },
        .r16_float => .{
            .internal = glad.R16F,
            .format = glad.RED,
            .pixel_type = glad.HALF_FLOAT,
            .components = 1,
            .normalized = false,
            .integer = false,
        },
        .r16g16_float => .{
            .internal = glad.RG16F,
            .format = glad.RG,
            .pixel_type = glad.HALF_FLOAT,
            .components = 2,
            .normalized = false,
            .integer = false,
        },
        .r16g16b16a16_float => .{
            .internal = glad.RGBA16F,
            .format = glad.RGBA,
            .pixel_type = glad.HALF_FLOAT,
            .components = 4,
            .normalized = false,
            .integer = false,
        },
        .r32_float => .{
            .internal = glad.R32F,
            .format = glad.RED,
            .pixel_type = glad.FLOAT,
            .components = 1,
            .normalized = false,
            .integer = false,
        },
        .r32g32_float => .{
            .internal = glad.RG32F,
            .format = glad.RG,
            .pixel_type = glad.FLOAT,
            .components = 2,
            .normalized = false,
            .integer = false,
        },
        .r32g32b32_float => .{
            .internal = glad.RGB32F,
            .format = glad.RGB,
            .pixel_type = glad.FLOAT,
            .components = 3,
            .normalized = false,
            .integer = false,
        },
        .r32g32b32a32_float => .{
            .internal = glad.RGBA32F,
            .format = glad.RGBA,
            .pixel_type = glad.FLOAT,
            .components = 4,
            .normalized = false,
            .integer = false,
        },
        .r32_uint => .{
            .internal = glad.R32UI,
            .format = glad.RED_INTEGER,
            .pixel_type = glad.UNSIGNED_INT,
            .components = 1,
            .normalized = false,
            .integer = true,
        },
        .r32g32_uint => .{
            .internal = glad.RG32UI,
            .format = glad.RG_INTEGER,
            .pixel_type = glad.UNSIGNED_INT,
            .components = 2,
            .normalized = false,
            .integer = true,
        },
        .r32g32b32_uint => .{
            .internal = glad.RGB32UI,
            .format = glad.RGB_INTEGER,
            .pixel_type = glad.UNSIGNED_INT,
            .components = 3,
            .normalized = false,
            .integer = true,
        },
        .r32g32b32a32_uint => .{
            .internal = glad.RGBA32UI,
            .format = glad.RGBA_INTEGER,
            .pixel_type = glad.UNSIGNED_INT,
            .components = 4,
            .normalized = false,
            .integer = true,
        },
        .d32_float => .{
            .internal = glad.DEPTH_COMPONENT32F,
            .format = glad.DEPTH_COMPONENT,
            .pixel_type = glad.FLOAT,
            .components = 1,
            .normalized = false,
            .integer = false,
        },
        .d24_unorm_s8_uint => .{
            .internal = glad.DEPTH24_STENCIL8,
            .format = glad.DEPTH_STENCIL,
            .pixel_type = glad.UNSIGNED_INT_24_8,
            .components = 2,
            .normalized = false,
            .integer = false,
        },
    };
}

fn glInternalFormat(format: types.Format) ?GLenum {
    return if (glFormat(format)) |value| value.internal else null;
}

fn textureTarget(
    texture_type: types.TextureType,
    arrayed: bool,
) ?GLenum {
    return switch (texture_type) {
        .@"1d" => if (arrayed) glad.TEXTURE_1D_ARRAY else glad.TEXTURE_1D,
        .@"2d" => if (arrayed) glad.TEXTURE_2D_ARRAY else glad.TEXTURE_2D,
        .@"3d" => glad.TEXTURE_3D,
    };
}

fn toGlTextureTarget(properties: types.TextureProperties) GLenum {
    return textureTarget(
        properties.type,
        properties.array_layers > 1,
    ).?;
}

fn toGlMinFilter(
    filter: types.Filter,
    mipmap: types.MipmapMode,
) GLenum {
    return switch (filter) {
        .nearest => switch (mipmap) {
            .nearest => glad.NEAREST_MIPMAP_NEAREST,
            .linear => glad.NEAREST_MIPMAP_LINEAR,
        },
        .linear => switch (mipmap) {
            .nearest => glad.LINEAR_MIPMAP_NEAREST,
            .linear => glad.LINEAR_MIPMAP_LINEAR,
        },
    };
}

fn toGlFilter(filter: types.Filter) GLenum {
    return switch (filter) {
        .nearest => glad.NEAREST,
        .linear => glad.LINEAR,
    };
}

fn toGlAddressMode(mode: types.AddressMode) GLenum {
    return switch (mode) {
        .repeat => glad.REPEAT,
        .mirrored_repeat => glad.MIRRORED_REPEAT,
        .clamp_to_edge => glad.CLAMP_TO_EDGE,
        .clamp_to_border => glad.CLAMP_TO_BORDER,
    };
}

fn toGlCompareOp(op: types.CompareOp) GLenum {
    return switch (op) {
        .never => glad.NEVER,
        .less => glad.LESS,
        .equal => glad.EQUAL,
        .less_equal => glad.LEQUAL,
        .greater => glad.GREATER,
        .not_equal => glad.NOTEQUAL,
        .greater_equal => glad.GEQUAL,
        .always => glad.ALWAYS,
    };
}

fn toGlTopology(topology: types.Topology) GLenum {
    return switch (topology) {
        .point_list => glad.POINTS,
        .line_list => glad.LINES,
        .line_strip => glad.LINE_STRIP,
        .triangle_list => glad.TRIANGLES,
        .triangle_strip => glad.TRIANGLE_STRIP,
        .triangle_fan => glad.TRIANGLE_FAN,
    };
}

fn toGlBlendFactor(factor: types.BlendFactor) GLenum {
    return switch (factor) {
        .zero => glad.ZERO,
        .one => glad.ONE,
        .src_color => glad.SRC_COLOR,
        .one_minus_src_color => glad.ONE_MINUS_SRC_COLOR,
        .dst_color => glad.DST_COLOR,
        .one_minus_dst_color => glad.ONE_MINUS_DST_COLOR,
        .src_alpha => glad.SRC_ALPHA,
        .one_minus_src_alpha => glad.ONE_MINUS_SRC_ALPHA,
        .dst_alpha => glad.DST_ALPHA,
        .one_minus_dst_alpha => glad.ONE_MINUS_DST_ALPHA,
        .constant_color => glad.CONSTANT_COLOR,
        .one_minus_constant_color => glad.ONE_MINUS_CONSTANT_COLOR,
        .constant_alpha => glad.CONSTANT_ALPHA,
        .one_minus_constant_alpha => glad.ONE_MINUS_CONSTANT_ALPHA,
    };
}

fn toGlBlendOp(op: types.BlendOp) GLenum {
    return switch (op) {
        .add => glad.FUNC_ADD,
        .subtract => glad.FUNC_SUBTRACT,
        .reverse_subtract => glad.FUNC_REVERSE_SUBTRACT,
        .min => glad.MIN,
        .max => glad.MAX,
    };
}

const VertexAttributeFormat = struct {
    size: GLint,
    kind: GLenum,
    normalized: bool,
    integer: bool,
};

fn vertexAttributeFormat(
    format: types.Format,
) ?VertexAttributeFormat {
    if (format == .b8g8r8a8_unorm or format == .b8g8r8a8_srgb or
        format == .undefined)
    {
        return null;
    }
    const gl = glFormat(format) orelse return null;
    return .{
        .size = gl.components,
        .kind = gl.pixel_type,
        .normalized = gl.normalized,
        .integer = gl.integer,
    };
}

fn isSamplerUniformType(uniform_type: GLenum) bool {
    return switch (uniform_type) {
        glad.SAMPLER_1D,
        glad.SAMPLER_2D,
        glad.SAMPLER_3D,
        glad.SAMPLER_CUBE,
        glad.SAMPLER_1D_ARRAY,
        glad.SAMPLER_2D_ARRAY,
        glad.SAMPLER_1D_SHADOW,
        glad.SAMPLER_2D_SHADOW,
        glad.SAMPLER_1D_ARRAY_SHADOW,
        glad.SAMPLER_2D_ARRAY_SHADOW,
        glad.SAMPLER_2D_MULTISAMPLE,
        glad.SAMPLER_2D_MULTISAMPLE_ARRAY,
        glad.SAMPLER_CUBE_SHADOW,
        glad.SAMPLER_BUFFER,
        glad.SAMPLER_2D_RECT,
        glad.SAMPLER_2D_RECT_SHADOW,
        glad.INT_SAMPLER_1D,
        glad.INT_SAMPLER_2D,
        glad.INT_SAMPLER_3D,
        glad.INT_SAMPLER_CUBE,
        glad.INT_SAMPLER_1D_ARRAY,
        glad.INT_SAMPLER_2D_ARRAY,
        glad.INT_SAMPLER_2D_MULTISAMPLE,
        glad.INT_SAMPLER_2D_MULTISAMPLE_ARRAY,
        glad.INT_SAMPLER_BUFFER,
        glad.INT_SAMPLER_2D_RECT,
        glad.UNSIGNED_INT_SAMPLER_1D,
        glad.UNSIGNED_INT_SAMPLER_2D,
        glad.UNSIGNED_INT_SAMPLER_3D,
        glad.UNSIGNED_INT_SAMPLER_CUBE,
        glad.UNSIGNED_INT_SAMPLER_1D_ARRAY,
        glad.UNSIGNED_INT_SAMPLER_2D_ARRAY,
        glad.UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE,
        glad.UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY,
        glad.UNSIGNED_INT_SAMPLER_BUFFER,
        glad.UNSIGNED_INT_SAMPLER_2D_RECT,
        => true,
        else => false,
    };
}

fn isImageUniformType(uniform_type: GLenum) bool {
    return switch (uniform_type) {
        glad.IMAGE_1D,
        glad.IMAGE_2D,
        glad.IMAGE_3D,
        glad.IMAGE_2D_RECT,
        glad.IMAGE_CUBE,
        glad.IMAGE_BUFFER,
        glad.IMAGE_1D_ARRAY,
        glad.IMAGE_2D_ARRAY,
        glad.IMAGE_CUBE_MAP_ARRAY,
        glad.IMAGE_2D_MULTISAMPLE,
        glad.IMAGE_2D_MULTISAMPLE_ARRAY,
        glad.INT_IMAGE_1D,
        glad.INT_IMAGE_2D,
        glad.INT_IMAGE_3D,
        glad.INT_IMAGE_2D_RECT,
        glad.INT_IMAGE_CUBE,
        glad.INT_IMAGE_BUFFER,
        glad.INT_IMAGE_1D_ARRAY,
        glad.INT_IMAGE_2D_ARRAY,
        glad.INT_IMAGE_CUBE_MAP_ARRAY,
        glad.INT_IMAGE_2D_MULTISAMPLE,
        glad.INT_IMAGE_2D_MULTISAMPLE_ARRAY,
        glad.UNSIGNED_INT_IMAGE_1D,
        glad.UNSIGNED_INT_IMAGE_2D,
        glad.UNSIGNED_INT_IMAGE_3D,
        glad.UNSIGNED_INT_IMAGE_2D_RECT,
        glad.UNSIGNED_INT_IMAGE_CUBE,
        glad.UNSIGNED_INT_IMAGE_BUFFER,
        glad.UNSIGNED_INT_IMAGE_1D_ARRAY,
        glad.UNSIGNED_INT_IMAGE_2D_ARRAY,
        glad.UNSIGNED_INT_IMAGE_CUBE_MAP_ARRAY,
        glad.UNSIGNED_INT_IMAGE_2D_MULTISAMPLE,
        glad.UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY,
        => true,
        else => false,
    };
}

fn createTextureObject(
    self: *OpenGL,
    description: types.TextureDescription,
    initial_data: ?types.TextureData,
) Error!GLuint {
    const format = glFormat(description.format) orelse
        return error.Unsupported;
    const arrayed = description.array_layers > 1;
    const target = textureTarget(description.type, arrayed) orelse
        return error.Unsupported;
    var handle: GLuint = 0;
    glad.createTextures(target, 1, &handle);
    errdefer glad.deleteTextures(1, &handle);

    if (description.samples > 1) {
        if (description.samples > self.limits.max_samples) {
            return error.Unsupported;
        }
        glad.textureStorage2DMultisample(
            handle,
            @intCast(description.samples),
            format.internal,
            @intCast(description.width),
            @intCast(description.height),
            glad.TRUE,
        );
    } else {
        switch (description.type) {
            .@"1d" => {
                if (arrayed) {
                    glad.textureStorage2D(
                        handle,
                        @intCast(description.mip_levels),
                        format.internal,
                        @intCast(description.width),
                        @intCast(description.array_layers),
                    );
                } else {
                    glad.textureStorage1D(
                        handle,
                        @intCast(description.mip_levels),
                        format.internal,
                        @intCast(description.width),
                    );
                }
            },
            .@"2d" => {
                if (arrayed) {
                    glad.textureStorage3D(
                        handle,
                        @intCast(description.mip_levels),
                        format.internal,
                        @intCast(description.width),
                        @intCast(description.height),
                        @intCast(description.array_layers),
                    );
                } else {
                    glad.textureStorage2D(
                        handle,
                        @intCast(description.mip_levels),
                        format.internal,
                        @intCast(description.width),
                        @intCast(description.height),
                    );
                }
            },
            .@"3d" => glad.textureStorage3D(
                handle,
                @intCast(description.mip_levels),
                format.internal,
                @intCast(description.width),
                @intCast(description.height),
                @intCast(description.depth),
            ),
        }
    }

    const min_filter = if (description.mip_levels > 1)
        glad.LINEAR_MIPMAP_LINEAR
    else
        glad.LINEAR;
    glad.textureParameteri(
        handle,
        glad.TEXTURE_MIN_FILTER,
        @intCast(min_filter),
    );
    glad.textureParameteri(
        handle,
        glad.TEXTURE_MAG_FILTER,
        @intCast(glad.LINEAR),
    );
    glad.textureParameteri(
        handle,
        glad.TEXTURE_WRAP_S,
        @intCast(glad.REPEAT),
    );
    glad.textureParameteri(
        handle,
        glad.TEXTURE_WRAP_T,
        @intCast(glad.REPEAT),
    );
    glad.textureParameteri(
        handle,
        glad.TEXTURE_WRAP_R,
        @intCast(glad.REPEAT),
    );
    glad.textureParameteri(handle, glad.TEXTURE_BASE_LEVEL, 0);
    glad.textureParameteri(
        handle,
        glad.TEXTURE_MAX_LEVEL,
        @intCast(description.mip_levels - 1),
    );

    if (initial_data) |data| {
        try self.uploadTexture(
            handle,
            description,
            format,
            data,
        );
    }
    try self.takeGlError("texture creation");
    return handle;
}

fn uploadTexture(
    self: *OpenGL,
    handle: GLuint,
    description: types.TextureDescription,
    format: GlFormat,
    data: types.TextureData,
) Error!void {
    _ = self;
    const bpp = description.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    const row_bytes: u64 = if (data.row_pitch == 0)
        @as(u64, description.width) * bpp
    else
        data.row_pitch;
    if (data.row_pitch != 0 and data.row_pitch % bpp != 0) {
        return error.InvalidDescription;
    }
    const layers: u64 = if (description.type == .@"3d")
        1
    else
        description.array_layers;
    const required = row_bytes *
        description.height *
        description.depth *
        layers;
    if (data.bytes.len < required) return error.InvalidDescription;

    if (data.row_pitch != 0) {
        glad.pixelStorei(
            glad.UNPACK_ROW_LENGTH,
            @intCast(data.row_pitch / bpp),
        );
    }
    glad.pixelStorei(glad.UNPACK_ALIGNMENT, 1);
    if (description.type == .@"3d" and data.image_height != 0) {
        glad.pixelStorei(
            glad.UNPACK_IMAGE_HEIGHT,
            @intCast(data.image_height),
        );
    }
    defer {
        glad.pixelStorei(glad.UNPACK_ROW_LENGTH, 0);
        glad.pixelStorei(glad.UNPACK_IMAGE_HEIGHT, 0);
        glad.pixelStorei(glad.UNPACK_ALIGNMENT, 4);
    }

    switch (description.type) {
        .@"1d" => {
            if (description.array_layers > 1) {
                glad.textureSubImage2D(
                    handle,
                    0,
                    0,
                    0,
                    @intCast(description.width),
                    @intCast(description.array_layers),
                    format.format,
                    format.pixel_type,
                    data.bytes.ptr,
                );
            } else {
                glad.textureSubImage1D(
                    handle,
                    0,
                    0,
                    @intCast(description.width),
                    format.format,
                    format.pixel_type,
                    data.bytes.ptr,
                );
            }
        },
        .@"2d" => {
            if (description.array_layers > 1) {
                glad.textureSubImage3D(
                    handle,
                    0,
                    0,
                    0,
                    0,
                    @intCast(description.width),
                    @intCast(description.height),
                    @intCast(description.array_layers),
                    format.format,
                    format.pixel_type,
                    data.bytes.ptr,
                );
            } else {
                glad.textureSubImage2D(
                    handle,
                    0,
                    0,
                    0,
                    @intCast(description.width),
                    @intCast(description.height),
                    format.format,
                    format.pixel_type,
                    data.bytes.ptr,
                );
            }
        },
        .@"3d" => glad.textureSubImage3D(
            handle,
            0,
            0,
            0,
            0,
            @intCast(description.width),
            @intCast(description.height),
            @intCast(description.depth),
            format.format,
            format.pixel_type,
            data.bytes.ptr,
        ),
    }
}

fn backend(vptr: *anyopaque) *OpenGL {
    return @ptrCast(@alignCast(vptr));
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

/// References every vtable entry so importing the backend type checks
/// all device and queue implementations.
pub const vtables = .{ &device_vtable, &queue_vtable };

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
    _ = ret_addr;
    return backend(vptr).map(resource, offset, size);
}

fn deviceUnmap(
    vptr: *anyopaque,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    _ = ret_addr;
    backend(vptr).unmap(resource, dirty);
}

fn deviceGetQueue(
    vptr: *anyopaque,
    index: u32,
    ret_addr: usize,
) Error!Queue {
    _ = ret_addr;
    return backend(vptr).getQueue(index);
}

fn deviceRecord(
    vptr: *anyopaque,
    resource: Resource,
    command: commands.Command,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    return backend(vptr).record(resource, command);
}

fn deviceOp(
    vptr: *anyopaque,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    _ = ret_addr;
    return backend(vptr).deviceOpi(operator, output_mode);
}

fn deviceQuery(
    vptr: *anyopaque,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!Device.QueryResult {
    _ = ret_addr;
    return backend(vptr).query(
        feature,
        feature_index,
        handle,
        output_mode,
    );
}

fn queueIndex(
    family_index: u32,
    queue_index: u32,
) Error!void {
    if (family_index != 0 or queue_index != 0) {
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
    try queueIndex(family_index, queue_index);
    const swapchain_slot = try self.lookup(
        description.swapchain,
        .swapchain,
    );
    const swapchain = &swapchain_slot.handle.swapchain;
    if (swapchain.images.len == 0) return error.InvalidResource;
    const image_index = swapchain.next_image % @as(
        u32,
        @intCast(swapchain.images.len),
    );
    swapchain.next_image +%= 1;
    if (self.lookup(swapchain.images[image_index], .texture)) |slot| {
        slot.handle.texture.layout = .undefined;
    } else |_| {}

    if (description.semaphore) |semaphore| {
        const slot = try self.lookup(semaphore, .semaphore);
        slot.handle.semaphore.signaled = true;
    }
    if (description.fence) |fence| {
        const slot = try self.lookup(fence, .fence);
        slot.handle.fence.signaled = true;
    }
    return .{ .image_index = image_index };
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
    try queueIndex(family_index, queue_index);

    for (submission.command_buffers) |resource| {
        const slot = try self.lookup(resource, .command_buffer);
        if (slot.handle.command_buffer.state != .ended) {
            return error.InvalidResource;
        }
    }
    for (submission.wait_semaphores) |semaphore| {
        _ = try self.lookup(semaphore, .semaphore);
    }
    for (submission.signal_semaphores) |semaphore| {
        const slot = try self.lookup(semaphore, .semaphore);
        slot.handle.semaphore.signaled = true;
    }
    if (submission.fence) |fence_resource| {
        const fence_slot = try self.lookup(fence_resource, .fence);
        signalFence(&fence_slot.handle.fence);
    }
    glad.flush();
    for (submission.command_buffers) |resource| {
        const slot = try self.lookup(resource, .command_buffer);
        slot.handle.command_buffer.state = .submitted;
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
    try queueIndex(family_index, queue_index);
    const swapchain_slot = try self.lookup(
        description.swapchain,
        .swapchain,
    );
    const swapchain = &swapchain_slot.handle.swapchain;
    if (description.image_index >= swapchain.images.len) {
        return error.InvalidDescription;
    }
    for (description.wait_semaphores) |semaphore| {
        _ = try self.lookup(semaphore, .semaphore);
    }

    const surface_slot = try self.lookup(
        swapchain.surface,
        .surface,
    );
    const image = try self.lookup(
        swapchain.images[description.image_index],
        .texture,
    );
    glad.namedFramebufferTexture(
        swapchain.fbo,
        glad.COLOR_ATTACHMENT0,
        image.handle.texture.handle,
        0,
    );
    glad.namedFramebufferReadBuffer(
        swapchain.fbo,
        glad.COLOR_ATTACHMENT0,
    );
    const width: GLsizei = @intCast(swapchain.properties.width);
    const height: GLsizei = @intCast(swapchain.properties.height);
    const surface = surface_slot.handle.surface.properties;
    glad.blitNamedFramebuffer(
        swapchain.fbo,
        0,
        0,
        0,
        width,
        height,
        0,
        0,
        @intCast(surface.current_width),
        @intCast(surface.current_height),
        glad.COLOR_BUFFER_BIT,
        glad.NEAREST,
    );
    glad.flush();
    try self.takeGlError("present");
}

fn queueWaitIdle(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    _ = backend(vptr);
    try queueIndex(family_index, queue_index);
    glad.finish();
}
