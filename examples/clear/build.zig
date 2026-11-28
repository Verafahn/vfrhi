const std = @import("std");
const Build = std.Build;

/// Builds the clear example.
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

    const exe = b.addExecutable(.{
        .name = "vfrhi-clear",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "framework", .module = framework },
            },
        }),
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
    const run_step = b.step("run", "Run the clear example");
    run_step.dependOn(&run.step);
}
