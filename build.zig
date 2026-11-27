const std = @import("std");
const translate_c = @import("translate_c");
const Translator = translate_c.Translator;
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_vulkan = b.option(
        bool,
        "vulkan",
        "Enable vulkan backend.",
    ) orelse b.isRoot();
    const backend_options = b.addOptions();

    const vulkan = blk: {
        if (use_vulkan) {
            const dep_vulkan_headers = try b.dependencyLazy(
                "vulkan_headers",
                .{},
            );
            const dep_vulkan = try b.dependencyLazy(
                "vulkan",
                .{
                    .registry = dep_vulkan_headers.path("registry/vk.xml"),
                },
            );
            backend_options.addOption(bool, "vulkan", true);
            break :blk dep_vulkan.module("vulkan-zig");
        } else {
            backend_options.addOption(bool, "vulkan", false);
            break :blk null;
        }
    };

    const rhi = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rhi.addImport("rhi", rhi);
    if (vulkan) |vk_mod| {
        rhi.addImport("vulkan", vk_mod);
    }
    rhi.addOptions("backend", backend_options);

    const test_rhi = b.addTest(.{ .root_module = rhi });
    const run_test_rhi = b.addRunArtifact(test_rhi);
    const test_step = b.step("test", "Test module 'vfrhi'.");
    test_step.dependOn(&run_test_rhi.step);

    if (b.isRoot()) {
        const dep_translate_c = try b.dependencyLazy(
            "translate_c",
            .{},
        );
        const dep_glfw_zig = try b.dependencyLazy(
            "glfw_zig",
            .{},
        );
        const vk_mod = vulkan orelse blk: {
            const dep_vulkan_headers = try b.dependencyLazy(
                "vulkan_headers",
                .{},
            );
            const dep_vulkan = try b.dependencyLazy("vulkan", .{
                .registry = dep_vulkan_headers.path("registry/vk.xml"),
            });
            break :blk dep_vulkan.module("vulkan-zig");
        };
        const glfw = Translator.init(dep_translate_c, .{
            .c_source_file = dep_glfw_zig.path("glfw/include/GLFW/glfw3.h"),
            .target = target,
            .optimize = optimize,
        });
        glfw.mod.linkLibrary(dep_glfw_zig.artifact("glfw"));

        const triangle = b.addExecutable(.{
            .name = "triangle",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/triangle/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{
                        .name = "vulkan",
                        .module = vk_mod,
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
        b.installArtifact(triangle);

        const run_triangle = b.addRunArtifact(triangle);
        const run_triangle_step = b.step("run", "");
        run_triangle_step.dependOn(&run_triangle.step);
        run_triangle.step.dependOn(b.getInstallStep());
    }
}
