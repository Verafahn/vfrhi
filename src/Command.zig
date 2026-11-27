const rhi = @import("Resource.zig");
const Resource = rhi.Resource;

/// A single command recorded into a command buffer.
///
/// `Device.record` executes exactly one command per call. The union
/// keeps command recording to a single virtual function instead of
/// adding one vtable entry per command.
pub const Command = union(enum) {
    begin,
    end,
    begin_rendering: BeginRendering,
    end_rendering,
    bind_pipeline: BindPipeline,
    bind_vertex_buffers: BindVertexBuffers,
    bind_index_buffer: BindIndexBuffer,
    bind_descriptor_sets: BindDescriptorSets,
    set_viewport: Viewport,
    set_scissor: Scissor,
    draw: Draw,
    draw_indexed: DrawIndexed,
    dispatch: Dispatch,
    copy_buffer: CopyBuffer,
    copy_buffer_to_texture: CopyBufferToTexture,
    copy_texture_to_buffer: CopyTextureToBuffer,
    copy_texture: CopyTexture,
    barrier: Barrier,
    push_constants: PushConstants,
};

/// Starts dynamic rendering.
pub const BeginRendering = struct {
    area: Area,
    color_attachments: []const ColorAttachment = &.{},
    depth_attachment: ?DepthAttachment = null,
};

/// The area covered by a render pass.
pub const Area = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32,
    height: u32,
};

/// A color attachment of a dynamic render pass.
pub const ColorAttachment = struct {
    view: Resource,
    load: rhi.LoadOp = .clear,
    store: rhi.StoreOp = .store,
    clear: ClearColor = .{},
};

/// A depth/stencil attachment of a dynamic render pass.
pub const DepthAttachment = struct {
    view: Resource,
    load: rhi.LoadOp = .clear,
    store: rhi.StoreOp = .store,
    clear_depth: f32 = 1.0,
    clear_stencil: u32 = 0,
    read_only: bool = false,
};

/// A linear color used to clear an attachment.
pub const ClearColor = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

/// Binds a graphics or compute pipeline.
pub const BindPipeline = struct {
    pipeline: Resource,
};

/// Binds one or more vertex buffers.
pub const BindVertexBuffers = struct {
    first_binding: u32 = 0,
    buffers: []const Resource,
    offsets: []const u64 = &.{},
};

/// Binds an index buffer.
pub const BindIndexBuffer = struct {
    buffer: Resource,
    offset: u64 = 0,
    type: rhi.IndexType = .uint32,
};

/// Binds one or more descriptor sets.
pub const BindDescriptorSets = struct {
    bind_point: rhi.BindPoint = .graphics,
    layout: Resource,
    first_set: u32 = 0,
    sets: []const Resource,
    dynamic_offsets: []const u32 = &.{},
};

/// Sets the viewport of a graphics pipeline.
pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

/// Sets the scissor rectangle of a graphics pipeline.
pub const Scissor = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32,
    height: u32,
};

/// A non indexed draw call.
pub const Draw = struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

/// An indexed draw call.
pub const DrawIndexed = struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

/// A compute dispatch.
pub const Dispatch = struct {
    x: u32,
    y: u32 = 1,
    z: u32 = 1,
};

/// One region of a buffer to buffer copy.
pub const BufferCopy = struct {
    src_offset: u64 = 0,
    dst_offset: u64 = 0,
    size: u64,
};

/// Copies between two buffers.
pub const CopyBuffer = struct {
    src: Resource,
    dst: Resource,
    regions: []const BufferCopy,
};

/// A three dimensional offset in texels.
pub const Offset3 = struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

/// A three dimensional extent in texels.
pub const Extent3 = struct {
    width: u32,
    height: u32 = 1,
    depth: u32 = 1,
};

/// One region of a texture copy.
pub const TextureCopyRegion = struct {
    mip_level: u32 = 0,
    array_layer: u32 = 0,
    offset: Offset3 = .{},
    extent: Extent3,
};

/// Copies a buffer into a texture.
pub const CopyBufferToTexture = struct {
    buffer: Resource,
    texture: Resource,
    buffer_offset: u64 = 0,
    row_pitch: u32 = 0,
    image_height: u32 = 0,
    region: TextureCopyRegion,
};

/// Copies a texture into a buffer.
pub const CopyTextureToBuffer = struct {
    texture: Resource,
    buffer: Resource,
    buffer_offset: u64 = 0,
    row_pitch: u32 = 0,
    image_height: u32 = 0,
    region: TextureCopyRegion,
};

/// Copies one texture into another texture.
pub const CopyTexture = struct {
    src: Resource,
    dst: Resource,
    regions: []const TextureCopyRegion,
};

/// A memory dependency or layout transition.
pub const Barrier = struct {
    resource: Resource,
    src_stage: rhi.PipelineStage = .all_commands,
    dst_stage: rhi.PipelineStage = .all_commands,
    src_access: rhi.Access = .{},
    dst_access: rhi.Access = .{},
    layout_before: rhi.TextureLayout = .undefined,
    layout_after: rhi.TextureLayout = .undefined,
};

/// Updates push constants of a pipeline layout.
pub const PushConstants = struct {
    layout: Resource,
    stages: rhi.ShaderStageFlags,
    offset: u32 = 0,
    data: []const u8,
};
