const std = @import("std");
const Writer = std.Io.Writer;

/// Errors shared by every backend and every RHI interface.
///
/// Backends translate native error codes into this set so callers
/// only handle backend independent failures.
pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    DeviceLost,
    InitializationFailed,
    Unsupported,
    InvalidResource,
    InvalidDescription,
    SurfaceLost,
    SurfaceOutOfDate,
    Timeout,
    NotReady,
    BufferTooSmall,
    Unknown,
};

/// A packed API version with `variant`, `major`, `minor`, and
/// `patch` components.
///
/// The layout matches Vulkan version encoding, so a `Version` can be
/// passed to APIs that expect a packed `u32`.
pub const Version = packed struct(u32) {
    patch: u12,
    minor: u10,
    major: u7,
    variant: u3,

    /// Builds a `Version` from its parts.
    ///
    /// # Args
    /// - `variant`: API variant, usually `0`.
    /// - `major`: major version number.
    /// - `minor`: minor version number.
    /// - `patch`: patch version number.
    ///
    /// # Return
    /// The packed version value.
    pub fn make(
        variant: u3,
        major: u7,
        minor: u10,
        patch: u12,
    ) Version {
        return .{
            .variant = variant,
            .major = major,
            .minor = minor,
            .patch = patch,
        };
    }

    /// Version 1.0.0.
    pub const api_1_0: Version = .make(0, 1, 0, 0);
    /// Version 1.1.0.
    pub const api_1_1: Version = .make(0, 1, 1, 0);
    /// Version 1.2.0.
    pub const api_1_2: Version = .make(0, 1, 2, 0);
    /// Version 1.3.0.
    pub const api_1_3: Version = .make(0, 1, 3, 0);
    /// Version 1.4.0.
    pub const api_1_4: Version = .make(0, 1, 4, 0);

    /// Formats the version as `variant.major.minor.patch`.
    ///
    /// # Args
    /// - `writer`: destination writer.
    ///
    /// # Error
    /// - `Writer.Error`: writing to `writer` fails.
    pub fn format(
        self: Version,
        writer: *Writer,
    ) Writer.Error!void {
        try writer.print("{d}.{d}.{d}.{d}", .{
            self.variant,
            self.major,
            self.minor,
            self.patch,
        });
    }
};

/// A backend independent handle to a resource.
///
/// Handles are generational: a handle stays valid until its resource
/// is destroyed, and destroying a resource invalidates every copy of
/// the handle. Backends validate handles before every operation.
pub const Resource = struct {
    identifier: Identifier,
    tag: Tag,

    /// The generation protected slot index of a resource.
    ///
    /// The low 32 bits store `generation`, the high 32 bits store
    /// `index`. A generation of `0` marks an invalid handle.
    pub const Identifier = packed struct {
        generation: u32,
        index: u32,
    };

    /// The kind of payload stored in `Description` and in a backend
    /// slot.
    pub const Tag = enum {
        surface,
        swapchain,
        buffer,
        texture,
        texture_view,
        sampler,
        shader,
        descriptor_set_layout,
        pipeline_layout,
        descriptor_set,
        pipeline,
        command_buffer,
        fence,
        semaphore,
    };

    /// Every resource a device can create, discriminated by `Tag`.
    ///
    /// Descriptions only reference other resources through
    /// `Resource` handles, so they stay backend independent.
    pub const Description = union(Tag) {
        surface: SurfaceDescription,
        swapchain: SwapchainDescription,
        buffer: BufferDescription,
        texture: TextureDescription,
        texture_view: TextureViewDescription,
        sampler: SamplerDescription,
        shader: ShaderDescription,
        descriptor_set_layout: DescriptorSetLayoutDescription,
        pipeline_layout: PipelineLayoutDescription,
        descriptor_set: DescriptorSetDescription,
        pipeline: PipelineDescription,
        command_buffer: CommandBufferDescription,
        fence: FenceDescription,
        semaphore: SemaphoreDescription,
    };

    /// An invalid handle. Backends reject it in every operation.
    pub const invalid: Resource = .{
        .identifier = .{
            .generation = 0,
            .index = std.math.maxInt(u32),
        },
        .tag = .buffer,
    };

    /// Compares two handles, including their tag.
    ///
    /// # Args
    /// - `a`: first handle.
    /// - `b`: second handle.
    ///
    /// # Return
    /// `true` when both handles refer to the same resource.
    pub fn eql(a: Resource, b: Resource) bool {
        return a.tag == b.tag and
            a.identifier.index == b.identifier.index and
            a.identifier.generation == b.identifier.generation;
    }

    /// Checks whether the handle can possibly be valid.
    ///
    /// # Return
    /// `false` for `Resource.invalid` or a zero generation.
    ///
    /// # Note
    /// This only checks the handle encoding. It does not prove that
    /// the resource is still alive; only a backend can decide that.
    pub fn isValid(self: Resource) bool {
        return self.identifier.generation != 0;
    }
};

/// A pixel format understood by the RHI.
///
/// The list is intentionally small: it covers the formats the test
/// backend verifies and the formats the Vulkan backend maps.
pub const Format = enum {
    undefined,
    r8_unorm,
    r8g8_unorm,
    r8g8b8a8_unorm,
    r8g8b8a8_srgb,
    b8g8r8a8_unorm,
    b8g8r8a8_srgb,
    r16_float,
    r16g16_float,
    r16g16b16a16_float,
    r32_float,
    r32g32_float,
    r32g32b32_float,
    r32g32b32a32_float,
    r32_uint,
    r32g32_uint,
    r32g32b32_uint,
    r32g32b32a32_uint,
    d32_float,
    d24_unorm_s8_uint,

    /// Returns the tightly packed size of one pixel.
    ///
    /// # Return
    /// Bytes per pixel, or `null` for `undefined`.
    pub fn bytesPerPixel(self: Format) ?u32 {
        return switch (self) {
            .undefined => null,
            .r8_unorm => 1,
            .r8g8_unorm, .r16_float => 2,
            .r8g8b8a8_unorm,
            .r8g8b8a8_srgb,
            .b8g8r8a8_unorm,
            .b8g8r8a8_srgb,
            .r16g16_float,
            .r32_float,
            .r32_uint,
            .d32_float,
            .d24_unorm_s8_uint,
            => 4,
            .r16g16b16a16_float,
            .r32g32_float,
            .r32g32_uint,
            => 8,
            .r32g32b32_float, .r32g32b32_uint => 12,
            .r32g32b32a32_float, .r32g32b32a32_uint => 16,
        };
    }

    /// Returns the image aspect that owns this format.
    ///
    /// # Return
    /// `color` for color formats, `depth` for depth only formats,
    /// and `depth_stencil` for combined depth/stencil formats.
    pub fn aspect(self: Format) TextureAspect {
        return switch (self) {
            .d32_float => .depth,
            .d24_unorm_s8_uint => .depth_stencil,
            else => .color,
        };
    }
};

/// Feature support for one `Format`.
pub const FormatProperties = struct {
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_attachment: bool = false,
    buffer: bool = false,
};

/// Memory residency hints used by `BufferDescription`.
pub const Memory = packed struct {
    /// Prefer memory that is close to the device. Backends may
    /// ignore this when `host_visible` is also set and no memory
    /// type satisfies both.
    device_local: bool = true,
    /// The memory can be mapped by the host.
    host_visible: bool = false,
    /// Host writes are visible to the device without an explicit
    /// flush.
    host_coherent: bool = false,
    /// The memory is optimized for host reads.
    host_cached: bool = false,
};

/// Buffer usage flags.
pub const BufferUsage = packed struct {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
};

/// Texture usage flags.
pub const TextureUsage = packed struct {
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_attachment: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
};

/// The dimensionality of a texture or a texture view.
pub const TextureType = enum {
    @"1d",
    @"2d",
    @"3d",
};

/// The physical layout of a texture.
///
/// Barriers change a texture from one layout to another. Backends
/// track the current layout of every texture so they can reject
/// mismatched transitions.
pub const TextureLayout = enum {
    undefined,
    general,
    color_attachment,
    depth_attachment,
    depth_read_only,
    stencil_read_only,
    depth_stencil_read_only,
    shader_read_only,
    transfer_src,
    transfer_dst,
    present,
};

/// The part of a texture a view or a barrier applies to.
pub const TextureAspect = enum {
    color,
    depth,
    stencil,
    depth_stencil,
};

/// Magnification and minification filtering.
pub const Filter = enum {
    nearest,
    linear,
};

/// Mipmap filtering between mip levels.
pub const MipmapMode = enum {
    nearest,
    linear,
};

/// Texture coordinate addressing.
pub const AddressMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
    clamp_to_border,
};

/// A programmable shader stage.
pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tessellation_control,
    tessellation_evaluation,
};

/// A set of shader stages.
pub const ShaderStageFlags = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    geometry: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
};

/// The kind of data a descriptor binding refers to.
pub const DescriptorKind = enum {
    uniform_buffer,
    storage_buffer,
    sampled_texture,
    storage_texture,
    sampler,
    combined_image_sampler,
};

/// The primitive topology of a graphics pipeline.
pub const Topology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
    triangle_fan,
};

/// Face culling mode.
pub const CullMode = enum {
    none,
    front,
    back,
    front_and_back,
};

/// The winding order that identifies a front face.
pub const FrontFace = enum {
    clockwise,
    counter_clockwise,
};

/// Comparison functions used by depth and stencil state.
pub const CompareOp = enum {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

/// Blend factors used by color attachments.
pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    constant_color,
    one_minus_constant_color,
    constant_alpha,
    one_minus_constant_alpha,
};

/// Blend operations used by color attachments.
pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

/// How an attachment is initialized at the start of a render pass.
pub const LoadOp = enum {
    load,
    clear,
    dont_care,
};

/// How an attachment is preserved at the end of a render pass.
pub const StoreOp = enum {
    store,
    dont_care,
};

/// Index buffer element type.
pub const IndexType = enum {
    uint16,
    uint32,
};

/// The bind point a pipeline or descriptor set belongs to.
pub const BindPoint = enum {
    graphics,
    compute,
};

/// Swapchain presentation mode.
pub const PresentMode = enum {
    immediate,
    mailbox,
    fifo,
    fifo_relaxed,
};

/// How often a vertex attribute advances.
pub const VertexInputRate = enum {
    vertex,
    instance,
};

/// Pipeline stages used by barriers.
pub const PipelineStage = enum {
    top_of_pipe,
    vertex_input,
    vertex_shader,
    fragment_shader,
    color_attachment,
    compute_shader,
    transfer,
    bottom_of_pipe,
    all_commands,
    host,
};

/// Memory accesses used by barriers.
pub const Access = packed struct {
    indirect_command_read: bool = false,
    index_read: bool = false,
    vertex_attribute_read: bool = false,
    uniform_read: bool = false,
    input_attachment_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    depth_stencil_attachment_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    host_read: bool = false,
    host_write: bool = false,
    memory_read: bool = false,
    memory_write: bool = false,
};

/// Queue capabilities reported by `Device.QueryProperties`.
pub const QueueCapabilities = packed struct {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    present: bool = false,
};

/// A native window or surface handed to the RHI.
pub const SurfaceDescription = struct {
    native: Native,

    /// Platform specific surface handles.
    ///
    /// Handles are stored as integers so that the RHI itself does not
    /// depend on any window manager or platform toolkit.
    pub const Native = union(enum) {
        win32: struct {
            hinstance: usize,
            hwnd: usize,
        },
        xlib: struct {
            display: usize,
            window: usize,
        },
        wayland: struct {
            display: usize,
            surface: usize,
        },
        headless: struct {
            width: u32 = 0,
            height: u32 = 0,
        },
    };
};

/// The properties of a native surface.
pub const SurfaceProperties = struct {
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
    current_width: u32,
    current_height: u32,
    format_count: u32,
};

/// A presentable set of textures tied to a surface.
pub const SwapchainDescription = struct {
    surface: Resource,
    width: u32,
    height: u32,
    format: Format = .b8g8r8a8_srgb,
    present_mode: PresentMode = .fifo,
    image_count: u32 = 3,
};

/// The resolved properties of a swapchain.
pub const SwapchainProperties = struct {
    width: u32,
    height: u32,
    format: Format,
    image_count: u32,
};

/// A buffer resource.
pub const BufferDescription = struct {
    size: u64,
    usage: BufferUsage = .{ .vertex = true },
    memory: Memory = .{},
    /// Data copied into the buffer at creation.
    ///
    /// Non host visible buffers must enable `usage.transfer_dst`.
    initial_data: ?[]const u8 = null,
};

/// The properties of a buffer.
pub const BufferProperties = struct {
    size: u64,
    memory: Memory,
};

/// A texture resource.
pub const TextureDescription = struct {
    type: TextureType = .@"2d",
    format: Format,
    width: u32,
    height: u32 = 1,
    depth: u32 = 1,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: u32 = 1,
    usage: TextureUsage = .{
        .sampled = true,
        .transfer_dst = true,
    },
    /// Data copied into the base mip level at creation.
    ///
    /// Textures with initial data must enable
    /// `usage.transfer_dst`.
    initial_data: ?TextureData = null,
};

/// Tightly packed or strided pixel data used to initialize a texture.
pub const TextureData = struct {
    /// Bytes to upload.
    bytes: []const u8,
    /// Bytes between two rows, or `0` for tightly packed rows.
    row_pitch: u32 = 0,
    /// Rows between two depth slices, or `0` for tightly packed
    /// slices.
    image_height: u32 = 0,
};

/// A view over a subresource range of a texture.
pub const TextureViewDescription = struct {
    texture: Resource,
    format: ?Format = null,
    type: ?TextureType = null,
    aspect: ?TextureAspect = null,
    base_mip: u32 = 0,
    mip_count: u32 = 0,
    base_layer: u32 = 0,
    layer_count: u32 = 0,
};

/// The properties of a texture.
pub const TextureProperties = struct {
    type: TextureType,
    format: Format,
    width: u32,
    height: u32,
    depth: u32,
    mip_levels: u32,
    array_layers: u32,
    samples: u32,
    usage: TextureUsage,
};

/// A sampler resource.
pub const SamplerDescription = struct {
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    mipmap: MipmapMode = .linear,
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,
    address_w: AddressMode = .repeat,
    anisotropy: u32 = 0,
    lod_min: f32 = 0,
    lod_max: f32 = 32,
    compare: ?CompareOp = null,
};

/// A SPIR-V shader module.
pub const ShaderDescription = struct {
    stage: ShaderStage,
    code: []const u32,
    entry_point: [:0]const u8 = "main",
};

/// A descriptor set layout.
pub const DescriptorSetLayoutDescription = struct {
    bindings: []const DescriptorBinding,

    /// One binding of a descriptor set layout.
    pub const DescriptorBinding = struct {
        binding: u32,
        kind: DescriptorKind,
        count: u32 = 1,
        stages: ShaderStageFlags = .{
            .vertex = true,
            .fragment = true,
        },
    };
};

/// A pipeline layout.
pub const PipelineLayoutDescription = struct {
    descriptor_sets: []const Resource = &.{},
    push_constants: []const PushConstant = &.{},

    /// One push constant range.
    pub const PushConstant = struct {
        stages: ShaderStageFlags,
        offset: u32 = 0,
        size: u32,
    };
};

/// A descriptor set allocated from a descriptor set layout.
pub const DescriptorSetDescription = struct {
    layout: Resource,
};

/// One host side descriptor update.
pub const DescriptorWrite = struct {
    binding: u32,
    array_index: u32 = 0,
    kind: Kind,

    /// The data written into one binding.
    pub const Kind = union(enum) {
        buffer: struct {
            buffer: Resource,
            offset: u64 = 0,
            size: u64 = 0,
        },
        texture: struct {
            view: Resource,
            sampler: ?Resource = null,
        },
        sampler: Resource,
    };
};

/// A graphics or compute pipeline.
pub const PipelineDescription = union(enum) {
    graphics: GraphicsPipelineDescription,
    compute: ComputePipelineDescription,
};

/// Vertex input state of a graphics pipeline.
pub const VertexLayout = struct {
    bindings: []const Binding = &.{},
    attributes: []const Attribute = &.{},

    /// One vertex buffer binding.
    pub const Binding = struct {
        binding: u32 = 0,
        stride: u32,
        rate: VertexInputRate = .vertex,
    };

    /// One vertex attribute.
    pub const Attribute = struct {
        location: u32,
        binding: u32 = 0,
        format: Format,
        offset: u32 = 0,
    };
};

/// Depth/stencil state of a graphics pipeline.
pub const DepthState = struct {
    enable: bool = true,
    write: bool = true,
    compare: CompareOp = .less_equal,
};

/// Blend state applied to every color attachment.
pub const BlendState = struct {
    enabled: bool = false,
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    op_color: BlendOp = .add,
    op_alpha: BlendOp = .add,
};

/// A graphics pipeline.
pub const GraphicsPipelineDescription = struct {
    layout: Resource,
    vertex: Resource,
    fragment: ?Resource = null,
    vertex_layout: VertexLayout = .{},
    topology: Topology = .triangle_list,
    cull: CullMode = .none,
    front_face: FrontFace = .counter_clockwise,
    depth: DepthState = .{},
    blend: BlendState = .{},
    color_formats: []const Format = &.{},
    depth_format: ?Format = null,
    samples: u32 = 1,
};

/// A compute pipeline.
pub const ComputePipelineDescription = struct {
    layout: Resource,
    shader: Resource,
};

/// A command buffer.
pub const CommandBufferDescription = struct {
    level: Level = .primary,

    /// The level of a command buffer.
    pub const Level = enum {
        primary,
        secondary,
    };
};

/// A fence resource.
pub const FenceDescription = struct {
    signaled: bool = false,
};

/// A semaphore resource.
pub const SemaphoreDescription = struct {};

/// A heap reported by `Device.getMemoryHeap`.
pub const MemoryHeap = struct {
    size: u64,
    device_local: bool,
};

/// A queue family reported by `Device.getQueueProperties`.
pub const QueueProperties = struct {
    capabilities: QueueCapabilities,
    count: u32,
    timestamp_bits: u32,
};
