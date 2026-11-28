//! A render hardware interface for Zig.
//!
//! The RHI exposes a small set of virtual tables and models every
//! resource through a tagged union of descriptions. Backends are
//! external objects: the RHI never initializes or destroys them.

const std = @import("std");
const build_options = @import("backend");
const surface = @import("resources/surface.zig");
const memory = @import("resources/memory.zig");
const pipeline = @import("resources/pipeline.zig");
const sync = @import("resources/sync.zig");

/// The RHI's own log scope.
pub const log = std.log.scoped(.vfrhi);

pub const types = @import("Resource.zig");
pub const Version = types.Version;
pub const Error = types.Error;
pub const Resource = types.Resource;
pub const ResourceDescription = types.Resource.Description;
pub const Command = CommandBuffer.Command;
pub const Device = @import("Device.zig");
pub const Queue = @import("Queue.zig");
pub const Surface = surface.Surface;
pub const Swapchain = surface.Swapchain;
pub const Buffer = memory.Buffer;
pub const Texture = memory.Texture;
pub const TextureView = memory.TextureView;
pub const Sampler = memory.Sampler;
pub const Shader = pipeline.Shader;
pub const DescriptorSetLayout = pipeline.DescriptorSetLayout;
pub const PipelineLayout = pipeline.PipelineLayout;
pub const DescriptorSet = pipeline.DescriptorSet;
pub const GraphicsPipeline = pipeline.GraphicsPipeline;
pub const ComputePipeline = pipeline.ComputePipeline;
pub const CommandBuffer = @import("resources/CommandBuffer.zig");
pub const Fence = sync.Fence;
pub const Semaphore = sync.Semaphore;
pub const Test = @import("backend/test/root.zig");

/// Whether the Vulkan backend was enabled at build time.
pub const vulkan_enabled = build_options.vulkan;

/// Whether the OpenGL backend was enabled at build time.
pub const opengl_enabled = build_options.opengl;

/// Whether the Direct3D 11 backend was enabled at build time.
pub const dx3d11_enabled = build_options.dx3d11;

/// Whether the Direct3D 12 backend was enabled at build time.
pub const dx3d12_enabled = build_options.dx3d12;

pub const Vulkan =
    if (build_options.vulkan)
        @import("backend/vulkan/root.zig")
    else
        @compileError(
            "If you want to use Vulkan backend, " ++
                "please pass '.vulkan=true' during build time.",
        );

pub const OpenGL =
    if (build_options.opengl)
        @import("backend/opengl/root.zig")
    else
        @compileError(
            "If you want to use OpenGL backend, " ++
                "please pass '.opengl=true' during build time.",
        );

pub const Dx3d11 =
    if (build_options.dx3d11)
        @import("backend/dx3d11/root.zig")
    else
        @compileError(
            "If you want to use the Direct3D 11 backend, " ++
                "please pass '.dx3d11=true' during build time.",
        );

pub const Dx3d12 =
    if (build_options.dx3d12)
        @import("backend/dx3d12/root.zig")
    else
        @compileError(
            "If you want to use the Direct3D 12 backend, " ++
                "please pass '.dx3d12=true' during build time.",
        );

test {
    _ = @import("tests.zig");
}
