//! A render hardware interface for Zig.
//!
//! The RHI exposes a small set of virtual tables and models every
//! resource through a tagged union of descriptions. Backends are
//! external objects: the RHI never initializes or destroys them.

const std = @import("std");
const build_options = @import("backend");

/// The RHI's own log scope.
pub const log = std.log.scoped(.vfrhi);

pub const types = @import("Resource.zig");
pub const Version = types.Version;
pub const Error = types.Error;
pub const Resource = types.Resource;
pub const ResourceDescription = types.Resource.Description;
pub const Command = @import("Command.zig").Command;
pub const Device = @import("Device.zig");
pub const Queue = @import("Queue.zig").Queue;
pub const Surface = @import("resources/Surface.zig").Surface;
pub const Swapchain = @import("resources/Surface.zig").Swapchain;
pub const Buffer = @import("resources/Memory.zig").Buffer;
pub const Texture = @import("resources/Memory.zig").Texture;
pub const TextureView = @import("resources/Memory.zig").TextureView;
pub const Sampler = @import("resources/Memory.zig").Sampler;
pub const Shader = @import("resources/Pipeline.zig").Shader;
pub const DescriptorSetLayout = @import("resources/Pipeline.zig")
    .DescriptorSetLayout;
pub const PipelineLayout = @import("resources/Pipeline.zig")
    .PipelineLayout;
pub const DescriptorSet = @import("resources/Pipeline.zig").DescriptorSet;
pub const GraphicsPipeline = @import("resources/Pipeline.zig")
    .GraphicsPipeline;
pub const ComputePipeline = @import("resources/Pipeline.zig")
    .ComputePipeline;
pub const CommandBuffer = @import("resources/Command.zig").CommandBuffer;
pub const Fence = @import("resources/Sync.zig").Fence;
pub const Semaphore = @import("resources/Sync.zig").Semaphore;
pub const Test = @import("backend/test/root.zig").Test;

/// Whether the Vulkan backend was enabled at build time.
pub const vulkan_enabled = build_options.vulkan;

pub const Vulkan =
    if (build_options.vulkan)
        @import("backend/vulkan/root.zig").Vulkan
    else
        @compileError(
            "If you want to use Vulkan backend, " ++
                "please pass '.vulkan=true' during build time.",
        );

test {
    _ = @import("tests.zig");
}
