const Device = @import("../Device.zig");
const rhi = @import("../Resource.zig");
const Error = rhi.Error;
const Resource = rhi.Resource;

/// A SPIR-V shader module.
pub const Shader = struct {
    pub const Description = rhi.ShaderDescription;
    pub const Stage = rhi.ShaderStage;

    device: Device,
    resource: Resource,
    stage: Stage,

    /// Creates a shader with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: shader stage, SPIR-V code, and entry point.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A shader owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidDescription`: `code` is empty or malformed.
    /// - `Error.OutOfHostMemory`: creating the module fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Shader {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .shader = description },
                ret_addr,
            ),
            .stage = description.stage,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: shader description.
    ///
    /// # Return
    /// A shader owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Shader {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the shader with an explicit return address.
    ///
    /// # Args
    /// - `self`: the shader to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Pipelines that use this shader must be destroyed first.
    pub fn destroyWithAddr(self: Shader, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the shader to destroy.
    pub fn destroy(self: Shader) void {
        self.destroyWithAddr(@returnAddress());
    }
};

/// A descriptor set layout.
pub const DescriptorSetLayout = struct {
    pub const Description = rhi.DescriptorSetLayoutDescription;
    pub const Binding = Description.DescriptorBinding;
    pub const DescriptorKind = rhi.DescriptorKind;

    device: Device,
    resource: Resource,

    /// Creates a descriptor set layout with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: descriptor bindings.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A layout owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidDescription`: bindings overlap or are empty.
    /// - `Error.OutOfDeviceMemory`: creating the layout fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!DescriptorSetLayout {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .descriptor_set_layout = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: layout description.
    ///
    /// # Return
    /// A layout owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!DescriptorSetLayout {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the layout with an explicit return address.
    ///
    /// # Args
    /// - `self`: the layout to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Descriptor sets and pipeline layouts using this layout must be
    /// destroyed first.
    pub fn destroyWithAddr(
        self: DescriptorSetLayout,
        ret_addr: usize,
    ) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the layout to destroy.
    pub fn destroy(self: DescriptorSetLayout) void {
        self.destroyWithAddr(@returnAddress());
    }
};

/// A pipeline layout.
pub const PipelineLayout = struct {
    pub const Description = rhi.PipelineLayoutDescription;
    pub const PushConstant = Description.PushConstant;

    device: Device,
    resource: Resource,

    /// Creates a pipeline layout with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: descriptor set layouts and push constants.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A pipeline layout owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a descriptor set layout handle is
    ///   stale.
    /// - `Error.InvalidDescription`: push constant ranges overlap.
    /// - `Error.OutOfDeviceMemory`: creating the layout fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!PipelineLayout {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .pipeline_layout = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: pipeline layout description.
    ///
    /// # Return
    /// A pipeline layout owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!PipelineLayout {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the pipeline layout with an explicit return address.
    ///
    /// # Args
    /// - `self`: the layout to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Pipelines using this layout must be destroyed first.
    pub fn destroyWithAddr(
        self: PipelineLayout,
        ret_addr: usize,
    ) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the layout to destroy.
    pub fn destroy(self: PipelineLayout) void {
        self.destroyWithAddr(@returnAddress());
    }
};

/// An allocated descriptor set.
pub const DescriptorSet = struct {
    pub const Description = rhi.DescriptorSetDescription;
    pub const Write = rhi.DescriptorWrite;

    device: Device,
    resource: Resource,
    layout: Resource,

    /// Allocates a descriptor set with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: the layout that describes the set.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A descriptor set owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the layout is stale.
    /// - `Error.OutOfDeviceMemory`: descriptor memory is exhausted.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!DescriptorSet {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .descriptor_set = description },
                ret_addr,
            ),
            .layout = description.layout,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: descriptor set description.
    ///
    /// # Return
    /// A descriptor set owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!DescriptorSet {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the descriptor set with an explicit return address.
    ///
    /// # Args
    /// - `self`: the set to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: DescriptorSet, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the set to destroy.
    pub fn destroy(self: DescriptorSet) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Updates descriptors of the set.
    ///
    /// # Args
    /// - `self`: the set to update.
    /// - `writes`: host side descriptor data.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a referenced resource is stale.
    /// - `Error.InvalidDescription`: a write targets a missing
    ///   binding or a mismatched descriptor kind.
    pub fn updateWithAddr(
        self: DescriptorSet,
        writes: []const Write,
        ret_addr: usize,
    ) Error!void {
        try self.device.writeDescriptorSetWithAddr(
            self.resource,
            writes,
            ret_addr,
        );
    }

    /// Calls `updateWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the set to update.
    /// - `writes`: host side descriptor data.
    ///
    /// # Error
    /// - See `updateWithAddr`.
    pub fn update(
        self: DescriptorSet,
        writes: []const Write,
    ) Error!void {
        try self.updateWithAddr(writes, @returnAddress());
    }
};

/// A graphics pipeline.
pub const GraphicsPipeline = struct {
    pub const Description = rhi.GraphicsPipelineDescription;
    pub const VertexLayout = rhi.VertexLayout;
    pub const Depth = rhi.DepthState;
    pub const Blend = rhi.BlendState;

    device: Device,
    resource: Resource,

    /// Creates a graphics pipeline with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: fixed function state and shaders.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A graphics pipeline owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: a shader or the layout is stale.
    /// - `Error.InvalidDescription`: shader stages or formats do not
    ///   match the description.
    /// - `Error.OutOfDeviceMemory`: creating the pipeline fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!GraphicsPipeline {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .pipeline = .{ .graphics = description } },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: graphics pipeline description.
    ///
    /// # Return
    /// A graphics pipeline owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!GraphicsPipeline {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the graphics pipeline with an explicit return address.
    ///
    /// # Args
    /// - `self`: the pipeline to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(
        self: GraphicsPipeline,
        ret_addr: usize,
    ) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the pipeline to destroy.
    pub fn destroy(self: GraphicsPipeline) void {
        self.destroyWithAddr(@returnAddress());
    }
};

/// A compute pipeline.
pub const ComputePipeline = struct {
    pub const Description = rhi.ComputePipelineDescription;

    device: Device,
    resource: Resource,

    /// Creates a compute pipeline with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: compute shader and pipeline layout.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A compute pipeline owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the shader or the layout is stale.
    /// - `Error.InvalidDescription`: the shader is not a compute
    ///   shader.
    /// - `Error.OutOfDeviceMemory`: creating the pipeline fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!ComputePipeline {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .pipeline = .{ .compute = description } },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: compute pipeline description.
    ///
    /// # Return
    /// A compute pipeline owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!ComputePipeline {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the compute pipeline with an explicit return address.
    ///
    /// # Args
    /// - `self`: the pipeline to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(
        self: ComputePipeline,
        ret_addr: usize,
    ) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the pipeline to destroy.
    pub fn destroy(self: ComputePipeline) void {
        self.destroyWithAddr(@returnAddress());
    }
};
