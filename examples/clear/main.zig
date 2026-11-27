const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const rhi = @import("vfrhi");

extern fn glfwGetInstanceProcAddress(
    instance: ?vk.Instance,
    proc_name: [*:0]const u8,
) vk.PfnVoidFunction;

const windows = if (builtin.os.tag == .windows) struct {
    extern fn glfwGetWin32Window(window: ?*anyopaque) ?*anyopaque;
    extern fn GetModuleHandleW(name: ?[*:0]const u16) ?*anyopaque;
} else struct {};

const max_frames = 240;

pub fn main(init: std.process.Init) !void {
    if (glfw.glfwInit() != glfw.GLFW_TRUE) {
        return error.GlfwInitFailed;
    }
    defer glfw.glfwTerminate();

    if (glfw.glfwVulkanSupported() != glfw.GLFW_TRUE) {
        return error.VulkanNotSupported;
    }

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);
    const window = glfw.glfwCreateWindow(
        800,
        600,
        "vfrhi clear",
        null,
        null,
    );
    if (window == null) return error.WindowCreationFailed;
    defer glfw.glfwDestroyWindow(window);

    var extension_count: u32 = 0;
    const extensions = glfw.glfwGetRequiredInstanceExtensions(
        &extension_count,
    );
    if (extensions == null or extension_count == 0) {
        return error.VulkanExtensionsUnavailable;
    }

    const allocator = init.gpa;
    const vulkan = try rhi.Vulkan.init(
        allocator,
        glfwGetInstanceProcAddress,
        .{
            .application_name = "vfrhi clear",
            .engine_name = "vfrhi",
            .api_version = .api_1_3,
            .enabled_extension = @ptrCast(extensions),
            .extension_count = extension_count,
        },
    );
    defer vulkan.deinit();
    const device = vulkan.asDevice();
    const queue = try device.getQueue(0);

    const surface_description: rhi.types.SurfaceDescription =
        if (builtin.os.tag == .windows) blk: {
            const native = windows.glfwGetWin32Window(
                @ptrCast(window),
            ) orelse return error.WindowHandleUnavailable;
            const hinstance = windows.GetModuleHandleW(null) orelse
                return error.ModuleHandleUnavailable;
            break :blk .{
                .native = .{ .win32 = .{
                    .hinstance = @intFromPtr(hinstance),
                    .hwnd = @intFromPtr(native),
                } },
            };
        } else .{
            .native = .{ .headless = .{
                .width = 800,
                .height = 600,
            } },
        };

    const surface = try rhi.Surface.create(device, surface_description);
    defer surface.destroy();

    const swapchain = try rhi.Swapchain.create(device, .{
        .surface = surface.resource,
        .width = 800,
        .height = 600,
        .format = .b8g8r8a8_srgb,
        .image_count = 3,
    });
    defer swapchain.destroy();

    const images = try swapchain.images(allocator);
    defer allocator.free(images);
    const views = try swapchain.views(allocator);
    defer allocator.free(views);

    const image_available = try rhi.Semaphore.create(device, .{});
    defer image_available.destroy();
    const render_finished = try rhi.Semaphore.create(device, .{});
    defer render_finished.destroy();
    const in_flight = try rhi.Fence.create(device, .{ .signaled = true });
    defer in_flight.destroy();
    const command_buffer = try rhi.CommandBuffer.create(device, .{});
    defer command_buffer.destroy();

    const uniform_data: [64]u8 = @splat(0);
    const uniform_buffer = try rhi.Buffer.create(device, .{
        .size = uniform_data.len,
        .memory = .{ .host_visible = true },
        .usage = .{ .uniform = true },
        .initial_data = &uniform_data,
    });
    defer uniform_buffer.destroy();

    const texture = try rhi.Texture.create(device, .{
        .format = .r8g8b8a8_unorm,
        .width = 4,
        .height = 4,
        .usage = .{ .sampled = true, .transfer_dst = true },
    });
    defer texture.destroy();
    const texture_view = try texture.createView(.{});
    defer texture_view.destroy();
    const sampler = try rhi.Sampler.create(device, .{});
    defer sampler.destroy();

    const set_layout = try rhi.DescriptorSetLayout.create(device, .{
        .bindings = &.{
            .{
                .binding = 0,
                .kind = .uniform_buffer,
                .stages = .{ .vertex = true },
            },
            .{
                .binding = 1,
                .kind = .combined_image_sampler,
                .stages = .{ .fragment = true },
            },
        },
    });
    defer set_layout.destroy();
    const pipeline_layout = try rhi.PipelineLayout.create(device, .{
        .descriptor_sets = &.{set_layout.resource},
    });
    defer pipeline_layout.destroy();
    const descriptor_set = try rhi.DescriptorSet.create(device, .{
        .layout = set_layout.resource,
    });
    defer descriptor_set.destroy();
    try descriptor_set.update(&.{
        .{
            .binding = 0,
            .kind = .{ .buffer = .{
                .buffer = uniform_buffer.resource,
                .size = uniform_data.len,
            } },
        },
        .{
            .binding = 1,
            .kind = .{ .texture = .{
                .view = texture_view.resource,
                .sampler = sampler.resource,
            } },
        },
    });

    var frame: u32 = 0;
    while (frame < max_frames and
        glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) : (frame += 1)
    {
        glfw.glfwPollEvents();

        try in_flight.wait(std.math.maxInt(u64));
        try in_flight.reset();

        const acquired = swapchain.acquire(
            queue,
            image_available,
            null,
        ) catch |err| switch (err) {
            error.SurfaceOutOfDate => continue,
            else => return err,
        };

        try command_buffer.begin();
        try command_buffer.barrier(.{
            .resource = images[acquired.image_index],
            .src_stage = .top_of_pipe,
            .dst_stage = .color_attachment,
            .dst_access = .{ .color_attachment_write = true },
            .layout_before = .undefined,
            .layout_after = .color_attachment,
        });
        try command_buffer.beginRendering(.{
            .area = .{
                .width = swapchain.properties.width,
                .height = swapchain.properties.height,
            },
            .color_attachments = &.{.{
                .view = views[acquired.image_index],
                .load = .clear,
                .store = .store,
                .clear = .{ .r = 0.05, .g = 0.08, .b = 0.16 },
            }},
        });
        try command_buffer.endRendering();
        try command_buffer.barrier(.{
            .resource = images[acquired.image_index],
            .src_stage = .color_attachment,
            .dst_stage = .bottom_of_pipe,
            .src_access = .{ .color_attachment_write = true },
            .layout_before = .color_attachment,
            .layout_after = .present,
        });
        try command_buffer.end();

        try command_buffer.submit(queue, .{
            .wait_semaphores = &.{image_available.resource},
            .signal_semaphores = &.{render_finished.resource},
            .fence = in_flight,
        });

        try swapchain.present(.{
            .queue = queue,
            .image_index = acquired.image_index,
            .wait_semaphores = &.{render_finished.resource},
        });
    }

    try device.waitIdle();
    std.debug.print("vfrhi clear rendered {d} frame(s)\n", .{frame});
}
