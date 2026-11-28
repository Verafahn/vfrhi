const std = @import("std");
const Build = std.Build;

/// Builds the triangle example.
pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rhi_dep = b.dependency("vfrhi", .{
        .target = target,
        .optimize = optimize,
        .vulkan = true,
        .opengl = true,
        .dx3d11 = target.result.os.tag == .windows,
        .dx3d12 = target.result.os.tag == .windows,
    });
    const rhi = rhi_dep.module("rhi");

    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const framework = b.createModule(.{
        .root_source_file = b.path("../framework/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vfrhi", .module = rhi },
        },
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vfrhi", .module = rhi },
            .{ .name = "framework", .module = framework },
        },
    });
    addShader(
        b,
        root_module,
        "triangle_vertex",
        "vert_spv",
        "shaders/vertex.zig",
    );
    addShader(
        b,
        root_module,
        "triangle_fragment",
        "frag_spv",
        "shaders/fragment.zig",
    );

    const exe = b.addExecutable(.{
        .name = "vfrhi-triangle",
        .root_module = root_module,
    });
    exe.root_module.linkLibrary(glfw_dep.artifact("glfw"));
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("dxgi", .{});
        exe.root_module.linkSystemLibrary("d3dcompiler_47", .{});
        exe.root_module.linkSystemLibrary("d3d11", .{});
        exe.root_module.linkSystemLibrary("d3d12", .{});
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the triangle example");
    run_step.dependOn(&run.step);
}

/// Compiles a Zig shader to SPIR-V and embeds it under `import_name`.
fn addShader(
    b: *Build,
    module: *Build.Module,
    object_name: []const u8,
    import_name: []const u8,
    source: []const u8,
) void {
    const object = b.addObject(.{
        .name = object_name,
        // Shader modules require the self-hosted SPIR-V backend.
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .spirv32,
                .os_tag = .vulkan,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    module.addAnonymousImport(import_name, .{
        .root_source_file = object.getEmittedBin(),
    });
}
