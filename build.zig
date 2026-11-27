const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_root = b.isRoot();

    // Importing vfrhi must not pull in the Vulkan toolchain. The
    // backend is fetched only when this project is the root package
    // or when the importer enables the 'vulkan' feature.
    const use_vulkan = b.option(
        bool,
        "vulkan",
        "Enable vulkan backend.",
    ) orelse is_root;

    const backend_options = b.addOptions();
    backend_options.addOption(bool, "vulkan", use_vulkan);

    const rhi = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rhi.addImport("rhi", rhi);
    rhi.addOptions("backend", backend_options);

    var vulkan_module: ?*Build.Module = null;
    if (use_vulkan) {
        const dep_vulkan_headers = try b.dependencyLazy(
            "vulkan_headers",
            .{},
        );
        const dep_vulkan = try b.dependencyLazy(
            "vulkan",
            .{
                .registry = dep_vulkan_headers.path(
                    "registry/vk.xml",
                ),
            },
        );
        const module = dep_vulkan.module("vulkan-zig");
        rhi.addImport("vulkan", module);
        vulkan_module = module;
    }

    const test_rhi = b.addTest(.{ .root_module = rhi });

    const run_test_rhi = b.addRunArtifact(test_rhi);
    const test_step = b.step("test", "Test module 'vfrhi'.");
    test_step.dependOn(&run_test_rhi.step);

    if (!is_root) return;

    // Examples and their window manager dependency are only built
    // when this project is the root package.
    if (vulkan_module == null) {
        return;
    }

    const translate_c = b.lazyImport(@This(), "translate_c") orelse
        return;
    const dep_translate_c = try b.dependencyLazy(
        "translate_c",
        .{},
    );
    const Translator = translate_c.Translator;

    const dep_glfw_zig = try b.dependencyLazy("glfw_zig", .{});
    const glfw = Translator.init(dep_translate_c, .{
        .c_source_file = dep_glfw_zig.path(
            "glfw/include/GLFW/glfw3.h",
        ),
        .target = target,
        .optimize = optimize,
    });
    glfw.mod.linkLibrary(dep_glfw_zig.artifact("glfw"));

    const clear = b.addExecutable(.{
        .name = "rhi-clear",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clear/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "vulkan",
                    .module = vulkan_module.?,
                },
                .{
                    .name = "glfw",
                    .module = glfw.mod,
                },
                .{
                    .name = "vfrhi",
                    .module = rhi,
                },
            },
        }),
    });

    const run_clear = b.addRunArtifact(clear);
    const run_clear_step = b.step(
        "run-rhi",
        "Run the RHI clear example.",
    );
    run_clear_step.dependOn(&run_clear.step);
}
