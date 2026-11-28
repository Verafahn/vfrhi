const std = @import("std");
const Build = std.Build;

/// Build options that decide which parts of the project are compiled.
const Config = struct {
    use_vulkan: bool,
    use_opengl: bool,
    use_dx3d11: bool,
    use_dx3d12: bool,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config = readConfig(b, target);

    const rhi = createRhiModule(b, target, optimize, config);
    try configureBackends(b, rhi, target, optimize, config);
    addTestStep(b, rhi, target, config);
    addExampleSteps(b);
}

fn readConfig(b: *Build, target: Build.ResolvedTarget) Config {
    const is_root = b.isRoot();
    const disable_render = b.option(
        bool,
        "disable-render",
        "Disable any rendering backend for testing purposes.",
    ) orelse false;

    // Importing vfrhi must not pull in a graphics toolchain. A
    // backend is fetched only when this project is the root package
    // or when the importer enables it explicitly.
    const use_vulkan = b.option(
        bool,
        "vulkan",
        "Enable vulkan backend.",
    ) orelse is_root and !disable_render;
    const use_opengl = b.option(
        bool,
        "opengl",
        "Enable opengl backend.",
    ) orelse is_root and !disable_render;
    const is_windows = target.result.os.tag == .windows;
    const use_dx3d11 = b.option(
        bool,
        "dx3d11",
        "Enable Direct3D 11 backend (Windows only).",
    ) orelse is_root and !disable_render and is_windows;
    const use_dx3d12 = b.option(
        bool,
        "dx3d12",
        "Enable Direct3D 12 backend (Windows only).",
    ) orelse is_root and !disable_render and is_windows;

    return .{
        .use_vulkan = use_vulkan,
        .use_opengl = use_opengl,
        .use_dx3d11 = use_dx3d11,
        .use_dx3d12 = use_dx3d12,
    };
}

fn createRhiModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: Config,
) *Build.Module {
    const backend_options = b.addOptions();
    backend_options.addOption(bool, "vulkan", config.use_vulkan);
    backend_options.addOption(bool, "opengl", config.use_opengl);
    backend_options.addOption(bool, "dx3d11", config.use_dx3d11);
    backend_options.addOption(bool, "dx3d12", config.use_dx3d12);

    const rhi = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rhi.addImport("rhi", rhi);
    rhi.addOptions("backend", backend_options);
    return rhi;
}

fn configureBackends(
    b: *Build,
    rhi: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: Config,
) !void {
    if ((config.use_dx3d11 or config.use_dx3d12) and
        target.result.os.tag != .windows)
    {
        std.log.err(
            "Direct3D backends are only supported on Windows targets",
            .{},
        );
        return error.UnsupportedBackend;
    }
    try addVulkanBackend(b, rhi, config.use_vulkan);
    try addOpenGlBackend(b, rhi, target, optimize, config.use_opengl);
    if (config.use_dx3d11 or config.use_dx3d12) {
        rhi.linkSystemLibrary("dxgi", .{});
    }
    if (config.use_dx3d11) {
        rhi.linkSystemLibrary("d3dcompiler_47", .{});
        rhi.linkSystemLibrary("d3d11", .{});
    }
    if (config.use_dx3d12) {
        rhi.linkSystemLibrary("d3dcompiler_47", .{});
        rhi.linkSystemLibrary("d3d12", .{});
    }
}

fn addVulkanBackend(
    b: *Build,
    rhi: *Build.Module,
    enabled: bool,
) !void {
    if (!enabled) return;

    const headers = try b.dependencyLazy("vulkan_headers", .{});
    const vulkan = try b.dependencyLazy("vulkan", .{
        .registry = headers.path("registry/vk.xml"),
    });
    rhi.addImport("vulkan", vulkan.module("vulkan-zig"));
}

fn addOpenGlBackend(
    b: *Build,
    rhi: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enabled: bool,
) !void {
    if (!enabled) return;

    const vfglad = try b.dependencyLazy("vfglad", .{
        .target = target,
        .optimize = optimize,
    });
    rhi.addImport("glad", vfglad.module("glad"));
}

fn addExampleSteps(b: *Build) void {
    // Examples are not part of the distributed package, so their run
    // steps only exist when this project is the root package.
    if (!b.isRoot()) return;

    const examples = [_]struct {
        name: []const u8,
        description: []const u8,
    }{
        .{ .name = "clear", .description = "Run the clear example." },
        .{ .name = "triangle", .description = "Run the triangle example." },
        .{ .name = "quad", .description = "Run the quad example." },
        .{ .name = "batch", .description = "Run the batch example." },
        .{ .name = "texture", .description = "Run the texture example." },
    };

    for (examples) |example| {
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "run",
        });
        run.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        run.addPassthruArgs();

        const step = b.step(
            b.fmt("run-{s}", .{example.name}),
            example.description,
        );
        step.dependOn(&run.step);
    }
}

fn addTestStep(
    b: *Build,
    rhi: *Build.Module,
    target: Build.ResolvedTarget,
    config: Config,
) void {
    const test_rhi = b.addTest(.{ .root_module = rhi });
    if (target.result.os.tag == .windows and
        (config.use_dx3d11 or config.use_dx3d12))
    {
        test_rhi.root_module.linkSystemLibrary("dxgi", .{});
    }
    if (target.result.os.tag == .windows and config.use_dx3d11) {
        test_rhi.root_module.linkSystemLibrary("d3dcompiler_47", .{});
        test_rhi.root_module.linkSystemLibrary("d3d11", .{});
    }
    if (target.result.os.tag == .windows and config.use_dx3d12) {
        test_rhi.root_module.linkSystemLibrary("d3dcompiler_47", .{});
        test_rhi.root_module.linkSystemLibrary("d3d12", .{});
    }
    const run_test_rhi = b.addRunArtifact(test_rhi);
    const test_step = b.step("test", "Test module 'vfrhi'.");
    test_step.dependOn(&run_test_rhi.step);
}
