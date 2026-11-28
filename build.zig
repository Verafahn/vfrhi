const std = @import("std");
const Build = std.Build;

/// Build options that decide which parts of the project are compiled.
const Config = struct {
    is_root: bool,
    use_vulkan: bool,
    use_opengl: bool,
};

/// Modules of the optional rendering backends.
const Backends = struct {
    vulkan: ?*Build.Module = null,
    opengl: ?*Build.Module = null,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config = readConfig(b);

    const rhi = createRhiModule(b, target, optimize, config);
    const backends = try configureBackends(
        b,
        rhi,
        target,
        optimize,
        config,
    );

    addTestStep(b, rhi);

    if (!config.is_root) return;

    try addExamples(b, rhi, backends, target, optimize);
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
        .is_root = is_root,
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
) !Backends {
    var backends: Backends = .{};
    backends.vulkan = try addVulkanBackend(b, rhi, config.use_vulkan);
    backends.opengl = try addOpenGlBackend(
        b,
        rhi,
        target,
        optimize,
        config.use_opengl,
    );
    return backends;
}

fn addVulkanBackend(
    b: *Build,
    rhi: *Build.Module,
    enabled: bool,
) !?*Build.Module {
    if (!enabled) return null;

    const headers = try b.dependencyLazy("vulkan_headers", .{});
    const vulkan = try b.dependencyLazy("vulkan", .{
        .registry = headers.path("registry/vk.xml"),
    });
    const module = vulkan.module("vulkan-zig");
    rhi.addImport("vulkan", module);
    return module;
}

fn addOpenGlBackend(
    b: *Build,
    rhi: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enabled: bool,
) !?*Build.Module {
    if (!enabled) return null;

    const vfglad = try b.dependencyLazy("vfglad", .{
        .target = target,
        .optimize = optimize,
    });
    const module = vfglad.module("glad");
    rhi.addImport("glad", module);
    return module;
}

fn addTestStep(b: *Build, rhi: *Build.Module) void {
    const test_rhi = b.addTest(.{ .root_module = rhi });
    const run_test_rhi = b.addRunArtifact(test_rhi);
    const test_step = b.step("test", "Test module 'vfrhi'.");
    test_step.dependOn(&run_test_rhi.step);
}

fn addExamples(
    b: *Build,
    rhi: *Build.Module,
    backends: Backends,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    var glfw: ?*Build.Module = null;

    if (backends.vulkan) |vulkan_module| {
        glfw = try createGlfwModule(b, target, optimize);
        addClearExample(
            b,
            rhi,
            vulkan_module,
            glfw.?,
            target,
            optimize,
        );
    }

    if (backends.opengl != null) {
        if (glfw == null) {
            glfw = try createGlfwModule(b, target, optimize);
        }
        addOpenGlExample(
            b,
            rhi,
            glfw.?,
            target,
            optimize,
        );
    }
}

fn createGlfwModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*Build.Module {
    const translate_c = b.lazyImport(@This(), "translate_c") orelse
        return error.TranslateCUnavailable;
    const dep_translate_c = try b.dependencyLazy("translate_c", .{});
    const dep_glfw_zig = try b.dependencyLazy("glfw_zig", .{});

    const glfw = translate_c.Translator.init(dep_translate_c, .{
        .c_source_file = dep_glfw_zig.path(
            "glfw/include/GLFW/glfw3.h",
        ),
        .target = target,
        .optimize = optimize,
    });
    glfw.mod.linkLibrary(dep_glfw_zig.artifact("glfw"));
    return glfw.mod;
}

fn addClearExample(
    b: *Build,
    rhi: *Build.Module,
    vulkan: *Build.Module,
    glfw: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const clear = b.addExecutable(.{
        .name = "rhi-clear",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clear/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "glfw", .module = glfw },
                .{ .name = "vfrhi", .module = rhi },
            },
        }),
    });
    b.installArtifact(clear);

    const run_clear = b.addRunArtifact(clear);
    const run_clear_step = b.step(
        "run-rhi",
        "Run the RHI clear example.",
    );
    run_clear_step.dependOn(&run_clear.step);
    run_clear.step.dependOn(b.getInstallStep());
}

fn addOpenGlExample(
    b: *Build,
    rhi: *Build.Module,
    glfw: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const clear = b.addExecutable(.{
        .name = "rhi-opengl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/opengl/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glfw", .module = glfw },
                .{ .name = "vfrhi", .module = rhi },
            },
        }),
    });
    b.installArtifact(clear);

    const run_clear = b.addRunArtifact(clear);
    const run_clear_step = b.step(
        "run-opengl",
        "Run the RHI OpenGL triangle example.",
    );
    run_clear_step.dependOn(&run_clear.step);
    run_clear.step.dependOn(b.getInstallStep());
}
