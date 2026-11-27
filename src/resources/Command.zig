const Device = @import("../Device.zig");
const rhi = @import("../Resource.zig");
const Error = rhi.Error;
const Queue = @import("../Queue.zig").Queue;
const rhi_command = @import("../Command.zig");
const Sync = @import("Sync.zig");
const Resource = rhi.Resource;

/// A command buffer recorded through `Device.record`.
pub const CommandBuffer = struct {
    pub const Description = rhi.CommandBufferDescription;
    pub const Level = Description.Level;

    /// The command union accepted by `record`.
    pub const Command = rhi_command.Command;
    pub const BeginRendering = rhi_command.BeginRendering;
    pub const BindPipeline = rhi_command.BindPipeline;
    pub const BindVertexBuffers = rhi_command.BindVertexBuffers;
    pub const BindIndexBuffer = rhi_command.BindIndexBuffer;
    pub const BindDescriptorSets = rhi_command.BindDescriptorSets;
    pub const Viewport = rhi_command.Viewport;
    pub const Scissor = rhi_command.Scissor;
    pub const Draw = rhi_command.Draw;
    pub const DrawIndexed = rhi_command.DrawIndexed;
    pub const Dispatch = rhi_command.Dispatch;
    pub const CopyBuffer = rhi_command.CopyBuffer;
    pub const CopyBufferToTexture = rhi_command.CopyBufferToTexture;
    pub const CopyTextureToBuffer = rhi_command.CopyTextureToBuffer;
    pub const CopyTexture = rhi_command.CopyTexture;
    pub const Barrier = rhi_command.Barrier;
    pub const PushConstants = rhi_command.PushConstants;

    device: Device,
    resource: Resource,
    level: Level,

    /// Creates a command buffer with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: command buffer level.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A command buffer owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfDeviceMemory`: allocation fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!CommandBuffer {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .command_buffer = description },
                ret_addr,
            ),
            .level = description.level,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: command buffer description.
    ///
    /// # Return
    /// A command buffer owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!CommandBuffer {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the command buffer with an explicit return address.
    ///
    /// # Args
    /// - `self`: the command buffer to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// The command buffer must not be in use by a queue.
    pub fn destroyWithAddr(self: CommandBuffer, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the command buffer to destroy.
    pub fn destroy(self: CommandBuffer) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Records an arbitrary command with an explicit return address.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    /// - `command`: the command to record.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is in the wrong
    ///   state.
    /// - `Error.InvalidDescription`: `command` references stale or
    ///   mismatched resources.
    pub fn recordWithAddr(
        self: CommandBuffer,
        command: Command,
        ret_addr: usize,
    ) Error!void {
        try self.device.rawRecord(self.resource, command, ret_addr);
    }

    /// Calls `recordWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    /// - `command`: the command to record.
    ///
    /// # Error
    /// - See `recordWithAddr`.
    pub fn record(
        self: CommandBuffer,
        command: Command,
    ) Error!void {
        try self.recordWithAddr(command, @returnAddress());
    }

    /// Starts recording, discarding previous commands.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is in use.
    pub fn beginWithAddr(
        self: CommandBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(.begin, ret_addr);
    }

    /// Calls `beginWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    ///
    /// # Error
    /// - See `beginWithAddr`.
    pub fn begin(self: CommandBuffer) Error!void {
        try self.beginWithAddr(@returnAddress());
    }

    /// Finishes recording.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is not
    ///   recording.
    pub fn endWithAddr(
        self: CommandBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(.end, ret_addr);
    }

    /// Calls `endWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the target command buffer.
    ///
    /// # Error
    /// - See `endWithAddr`.
    pub fn end(self: CommandBuffer) Error!void {
        try self.endWithAddr(@returnAddress());
    }

    /// Starts dynamic rendering.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: area and attachments.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is not
    ///   recording.
    /// - `Error.InvalidDescription`: an attachment is not a texture
    ///   view.
    pub fn beginRenderingWithAddr(
        self: CommandBuffer,
        description: BeginRendering,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .begin_rendering = description },
            ret_addr,
        );
    }

    /// Calls `beginRenderingWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: area and attachments.
    ///
    /// # Error
    /// - See `beginRenderingWithAddr`.
    pub fn beginRendering(
        self: CommandBuffer,
        description: BeginRendering,
    ) Error!void {
        try self.beginRenderingWithAddr(description, @returnAddress());
    }

    /// Ends dynamic rendering.
    ///
    /// # Args
    /// - `self`: a recording command buffer inside a render pass.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: no render pass is active.
    pub fn endRenderingWithAddr(
        self: CommandBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(.end_rendering, ret_addr);
    }

    /// Calls `endRenderingWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer inside a render pass.
    ///
    /// # Error
    /// - See `endRenderingWithAddr`.
    pub fn endRendering(self: CommandBuffer) Error!void {
        try self.endRenderingWithAddr(@returnAddress());
    }

    /// Binds a pipeline.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: the pipeline to bind.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the pipeline is stale.
    pub fn bindPipelineWithAddr(
        self: CommandBuffer,
        description: BindPipeline,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .bind_pipeline = description },
            ret_addr,
        );
    }

    /// Calls `bindPipelineWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: the pipeline to bind.
    ///
    /// # Error
    /// - See `bindPipelineWithAddr`.
    pub fn bindPipeline(
        self: CommandBuffer,
        description: BindPipeline,
    ) Error!void {
        try self.bindPipelineWithAddr(description, @returnAddress());
    }

    /// Binds vertex buffers.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: buffers and offsets.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a buffer is stale or not a buffer.
    pub fn bindVertexBuffersWithAddr(
        self: CommandBuffer,
        description: BindVertexBuffers,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .bind_vertex_buffers = description },
            ret_addr,
        );
    }

    /// Calls `bindVertexBuffersWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: buffers and offsets.
    ///
    /// # Error
    /// - See `bindVertexBuffersWithAddr`.
    pub fn bindVertexBuffers(
        self: CommandBuffer,
        description: BindVertexBuffers,
    ) Error!void {
        try self.bindVertexBuffersWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Binds an index buffer.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: buffer, offset, and index type.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the buffer is stale.
    pub fn bindIndexBufferWithAddr(
        self: CommandBuffer,
        description: BindIndexBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .bind_index_buffer = description },
            ret_addr,
        );
    }

    /// Calls `bindIndexBufferWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: buffer, offset, and index type.
    ///
    /// # Error
    /// - See `bindIndexBufferWithAddr`.
    pub fn bindIndexBuffer(
        self: CommandBuffer,
        description: BindIndexBuffer,
    ) Error!void {
        try self.bindIndexBufferWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Binds descriptor sets.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: layout and sets to bind.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a set or the layout is stale.
    pub fn bindDescriptorSetsWithAddr(
        self: CommandBuffer,
        description: BindDescriptorSets,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .bind_descriptor_sets = description },
            ret_addr,
        );
    }

    /// Calls `bindDescriptorSetsWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: layout and sets to bind.
    ///
    /// # Error
    /// - See `bindDescriptorSetsWithAddr`.
    pub fn bindDescriptorSets(
        self: CommandBuffer,
        description: BindDescriptorSets,
    ) Error!void {
        try self.bindDescriptorSetsWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Sets the viewport.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: viewport rectangle.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is not
    ///   recording.
    pub fn setViewportWithAddr(
        self: CommandBuffer,
        description: Viewport,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .set_viewport = description },
            ret_addr,
        );
    }

    /// Calls `setViewportWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: viewport rectangle.
    ///
    /// # Error
    /// - See `setViewportWithAddr`.
    pub fn setViewport(
        self: CommandBuffer,
        description: Viewport,
    ) Error!void {
        try self.setViewportWithAddr(description, @returnAddress());
    }

    /// Sets the scissor rectangle.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: scissor rectangle.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is not
    ///   recording.
    pub fn setScissorWithAddr(
        self: CommandBuffer,
        description: Scissor,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .set_scissor = description },
            ret_addr,
        );
    }

    /// Calls `setScissorWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: scissor rectangle.
    ///
    /// # Error
    /// - See `setScissorWithAddr`.
    pub fn setScissor(
        self: CommandBuffer,
        description: Scissor,
    ) Error!void {
        try self.setScissorWithAddr(description, @returnAddress());
    }

    /// Records a non indexed draw.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: draw parameters.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: no graphics pipeline is bound or
    ///   no render pass is active.
    pub fn drawWithAddr(
        self: CommandBuffer,
        description: Draw,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(.{ .draw = description }, ret_addr);
    }

    /// Calls `drawWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: draw parameters.
    ///
    /// # Error
    /// - See `drawWithAddr`.
    pub fn draw(
        self: CommandBuffer,
        description: Draw,
    ) Error!void {
        try self.drawWithAddr(description, @returnAddress());
    }

    /// Records an indexed draw.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: indexed draw parameters.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: no index buffer or graphics
    ///   pipeline is bound.
    pub fn drawIndexedWithAddr(
        self: CommandBuffer,
        description: DrawIndexed,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .draw_indexed = description },
            ret_addr,
        );
    }

    /// Calls `drawIndexedWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: indexed draw parameters.
    ///
    /// # Error
    /// - See `drawIndexedWithAddr`.
    pub fn drawIndexed(
        self: CommandBuffer,
        description: DrawIndexed,
    ) Error!void {
        try self.drawIndexedWithAddr(description, @returnAddress());
    }

    /// Records a compute dispatch.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: workgroup counts.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: no compute pipeline is bound.
    pub fn dispatchWithAddr(
        self: CommandBuffer,
        description: Dispatch,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .dispatch = description },
            ret_addr,
        );
    }

    /// Calls `dispatchWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: workgroup counts.
    ///
    /// # Error
    /// - See `dispatchWithAddr`.
    pub fn dispatch(
        self: CommandBuffer,
        description: Dispatch,
    ) Error!void {
        try self.dispatchWithAddr(description, @returnAddress());
    }

    /// Copies between buffers.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: source, destination, and regions.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a buffer is stale or lacks the
    ///   transfer usage.
    /// - `Error.InvalidDescription`: a region is out of bounds.
    pub fn copyBufferWithAddr(
        self: CommandBuffer,
        description: CopyBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .copy_buffer = description },
            ret_addr,
        );
    }

    /// Calls `copyBufferWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: copy parameters.
    ///
    /// # Error
    /// - See `copyBufferWithAddr`.
    pub fn copyBuffer(
        self: CommandBuffer,
        description: CopyBuffer,
    ) Error!void {
        try self.copyBufferWithAddr(description, @returnAddress());
    }

    /// Copies a buffer into a texture.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: source buffer and texture region.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a resource is stale or lacks the
    ///   transfer usage.
    /// - `Error.InvalidDescription`: the region is out of bounds.
    pub fn copyBufferToTextureWithAddr(
        self: CommandBuffer,
        description: CopyBufferToTexture,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .copy_buffer_to_texture = description },
            ret_addr,
        );
    }

    /// Calls `copyBufferToTextureWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: copy parameters.
    ///
    /// # Error
    /// - See `copyBufferToTextureWithAddr`.
    pub fn copyBufferToTexture(
        self: CommandBuffer,
        description: CopyBufferToTexture,
    ) Error!void {
        try self.copyBufferToTextureWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Copies a texture into a buffer.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: source texture and destination buffer.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a resource is stale or lacks the
    ///   transfer usage.
    /// - `Error.InvalidDescription`: the region is out of bounds.
    pub fn copyTextureToBufferWithAddr(
        self: CommandBuffer,
        description: CopyTextureToBuffer,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .copy_texture_to_buffer = description },
            ret_addr,
        );
    }

    /// Calls `copyTextureToBufferWithAddr` with
    /// `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: copy parameters.
    ///
    /// # Error
    /// - See `copyTextureToBufferWithAddr`.
    pub fn copyTextureToBuffer(
        self: CommandBuffer,
        description: CopyTextureToBuffer,
    ) Error!void {
        try self.copyTextureToBufferWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Copies between textures.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: source, destination, and regions.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a texture is stale or lacks the
    ///   transfer usage.
    /// - `Error.InvalidDescription`: a region is out of bounds.
    pub fn copyTextureWithAddr(
        self: CommandBuffer,
        description: CopyTexture,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .copy_texture = description },
            ret_addr,
        );
    }

    /// Calls `copyTextureWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: copy parameters.
    ///
    /// # Error
    /// - See `copyTextureWithAddr`.
    pub fn copyTexture(
        self: CommandBuffer,
        description: CopyTexture,
    ) Error!void {
        try self.copyTextureWithAddr(description, @returnAddress());
    }

    /// Records a memory barrier or layout transition.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: dependency and layout transition.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the resource is stale.
    /// - `Error.InvalidDescription`: `layout_before` does not match
    ///   the current texture layout.
    pub fn barrierWithAddr(
        self: CommandBuffer,
        description: Barrier,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .barrier = description },
            ret_addr,
        );
    }

    /// Calls `barrierWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: barrier parameters.
    ///
    /// # Error
    /// - See `barrierWithAddr`.
    pub fn barrier(
        self: CommandBuffer,
        description: Barrier,
    ) Error!void {
        try self.barrierWithAddr(description, @returnAddress());
    }

    /// Updates push constants.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: layout, stages, and data.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the layout is stale.
    /// - `Error.InvalidDescription`: the range is outside the layout
    ///   push constants.
    pub fn pushConstantsWithAddr(
        self: CommandBuffer,
        description: PushConstants,
        ret_addr: usize,
    ) Error!void {
        try self.recordWithAddr(
            .{ .push_constants = description },
            ret_addr,
        );
    }

    /// Calls `pushConstantsWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a recording command buffer.
    /// - `description`: push constant parameters.
    ///
    /// # Error
    /// - See `pushConstantsWithAddr`.
    pub fn pushConstants(
        self: CommandBuffer,
        description: PushConstants,
    ) Error!void {
        try self.pushConstantsWithAddr(
            description,
            @returnAddress(),
        );
    }

    /// Parameters of a single command buffer submission.
    pub const Submit = struct {
        wait_semaphores: []const Resource = &.{},
        signal_semaphores: []const Resource = &.{},
        fence: ?Sync.Fence = null,
    };

    /// Submits this command buffer to a queue.
    ///
    /// # Args
    /// - `self`: an ended command buffer.
    /// - `queue`: the destination queue.
    /// - `description`: synchronization for the submission.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the command buffer is not ended.
    /// - `Error.DeviceLost`: the device was lost.
    pub fn submitWithAddr(
        self: CommandBuffer,
        queue: Queue,
        description: Submit,
        ret_addr: usize,
    ) Error!void {
        try queue.rawSubmit(.{
            .command_buffers = &.{self.resource},
            .wait_semaphores = description.wait_semaphores,
            .signal_semaphores = description.signal_semaphores,
            .fence = if (description.fence) |fence| fence.resource else null,
        }, ret_addr);
    }

    /// Calls `submitWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: an ended command buffer.
    /// - `queue`: the destination queue.
    /// - `description`: synchronization for the submission.
    ///
    /// # Error
    /// - See `submitWithAddr`.
    pub fn submit(
        self: CommandBuffer,
        queue: Queue,
        description: Submit,
    ) Error!void {
        try self.submitWithAddr(queue, description, @returnAddress());
    }
};
