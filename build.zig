const std = @import("std");
const Build = std.Build;

/// Build options that decide which parts of the project are compiled.
const Config = struct {
    use_vulkan: bool,
    use_opengl: bool,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config = readConfig(b);

    const rhi = createRhiModule(b, target, optimize, config);
    try configureBackends(b, rhi, target, optimize, config);
    addTestStep(b, rhi);
}

fn readConfig(b: *Build) Config {
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

    return .{
        .use_vulkan = use_vulkan,
        .use_opengl = use_opengl,
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
    try addVulkanBackend(b, rhi, config.use_vulkan);
    try addOpenGlBackend(b, rhi, target, optimize, config.use_opengl);
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

fn addTestStep(b: *Build, rhi: *Build.Module) void {
    const test_rhi = b.addTest(.{ .root_module = rhi });
    const run_test_rhi = b.addRunArtifact(test_rhi);
    const test_step = b.step("test", "Test module 'vfrhi'.");
    test_step.dependOn(&run_test_rhi.step);
}
