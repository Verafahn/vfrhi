const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");
const rhi = @import("vfrhi");

extern fn glfwGetInstanceProcAddress(
    instance: ?vk.Instance,
    proc_name: [*:0]const u8,
) vk.PfnVoidFunction;

extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: ?*anyopaque,
    allocator: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) vk.Result;

// Keep the smoke test self-terminating: about four seconds at 60 Hz.
const max_frames = 240;

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    queue_family_index: u32,
};

pub fn main(init: std.process.Init) !void {
    if (glfw.glfwInit() != glfw.GLFW_TRUE) return error.GlfwInitFailed;
    defer glfw.glfwTerminate();

    if (glfw.glfwVulkanSupported() != glfw.GLFW_TRUE) return error.VulkanNotSupported;

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);

    const window = glfw.glfwCreateWindow(
        800,
        600,
        "Lien Vulkan Smoke Test",
        null,
        null,
    );
    if (window == null) return error.WindowCreationFailed;
    defer glfw.glfwDestroyWindow(window);

    const allocator = init.gpa;

    var extension_count: u32 = 0;
    const glfw_extensions = glfw.glfwGetRequiredInstanceExtensions(&extension_count);
    if (glfw_extensions == null or extension_count == 0) {
        return error.VulkanExtensionsUnavailable;
    }

    const vulkan = try rhi.Vulkan.init(
        allocator,
        glfwGetInstanceProcAddress,
        .{
            .application_name = "Hello",
            .engine_name = "Hello Vulkan",
            .engine_version = .make(0, 1, 0, 0),
            .application_version = .make(0, 1, 0, 0),
            .api_version = .api_1_0,
            .enabled_extension = @ptrCast(glfw_extensions),
            .extension_count = extension_count,
        },
    );
    defer vulkan.deinit();

    const instance = vulkan.instance;
    const vki = vulkan.vki;
    const vki_wrapper = vulkan.vki_wrapper;

    var surface: vk.SurfaceKHR = undefined;
    if (glfwCreateWindowSurface(instance, window, null, &surface) != .success) {
        return error.SurfaceCreationFailed;
    }
    defer vki.destroySurfaceKHR(surface, null);

    const selection = try selectPhysicalDevice(vki, allocator, surface);
    const physical_device = selection.physical_device;
    const queue_family_index = selection.queue_family_index;

    const queue_priorities = [_]f32{1.0};
    const queue_info = vk.DeviceQueueCreateInfo{
        .queue_family_index = queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = &queue_priorities,
    };
    const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
    const device = try vki.createDevice(physical_device, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_info),
        .enabled_extension_count = device_extensions.len,
        .pp_enabled_extension_names = &device_extensions,
    }, null);

    const vkd_wrapper = vk.DeviceWrapper.load(device, vki_wrapper.dispatch.vkGetDeviceProcAddr.?);
    const vkd = vk.DeviceProxy.init(device, &vkd_wrapper);
    defer {
        vkd.deviceWaitIdle() catch {};
        vkd.destroyDevice(null);
    }

    const queue = vkd.getDeviceQueue(queue_family_index, 0);

    const surface_caps = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    var extent = surface_caps.current_extent;
    if (extent.width == std.math.maxInt(u32)) {
        var framebuffer_width: c_int = 0;
        var framebuffer_height: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &framebuffer_width, &framebuffer_height);
        extent = .{
            .width = std.math.clamp(
                @as(u32, @intCast(framebuffer_width)),
                surface_caps.min_image_extent.width,
                surface_caps.max_image_extent.width,
            ),
            .height = std.math.clamp(
                @as(u32, @intCast(framebuffer_height)),
                surface_caps.min_image_extent.height,
                surface_caps.max_image_extent.height,
            ),
        };
    }

    const formats = try vki.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
    defer allocator.free(formats);
    if (formats.len == 0) return error.NoSurfaceFormats;

    var surface_format = formats[0];
    if (formats.len == 1 and surface_format.format == .undefined) {
        surface_format.format = .b8g8r8a8_srgb;
        surface_format.color_space = .srgb_nonlinear_khr;
    } else {
        for (formats) |format| {
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                surface_format = format;
                break;
            }
        }
    }

    var image_count = surface_caps.min_image_count + 1;
    if (surface_caps.max_image_count != 0 and image_count > surface_caps.max_image_count) {
        image_count = surface_caps.max_image_count;
    }

    const swapchain = try vkd.createSwapchainKHR(&.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = surface_caps.current_transform,
        .composite_alpha = .{ .opaque_khr = true },
        .present_mode = .fifo_khr,
        .clipped = .true,
    }, null);
    defer vkd.destroySwapchainKHR(swapchain, null);

    const swapchain_images = try vkd.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(swapchain_images);
    if (swapchain_images.len == 0) return error.NoSwapchainImages;

    const image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);
    defer {
        for (image_views) |view| vkd.destroyImageView(view, null);
        allocator.free(image_views);
    }
    for (swapchain_images, 0..) |image, i| {
        image_views[i] = try vkd.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }

    const attachment = vk.AttachmentDescription{
        .format = surface_format.format,
        .samples = .{ .@"1" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_attachment = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
    };
    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output = true },
        .dst_stage_mask = .{ .color_attachment_output = true },
        .dst_access_mask = .{ .color_attachment_write = true },
    };
    const render_pass = try vkd.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    }, null);
    defer vkd.destroyRenderPass(render_pass, null);

    const framebuffers = try allocator.alloc(vk.Framebuffer, image_views.len);
    defer {
        for (framebuffers) |framebuffer| vkd.destroyFramebuffer(framebuffer, null);
        allocator.free(framebuffers);
    }
    for (image_views, 0..) |view, i| {
        framebuffers[i] = try vkd.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&view),
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        }, null);
    }

    const command_pool = try vkd.createCommandPool(&.{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = queue_family_index,
    }, null);
    defer vkd.destroyCommandPool(command_pool, null);

    const command_buffers = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    defer allocator.free(command_buffers);
    try vkd.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(command_buffers.len),
    }, command_buffers.ptr);

    const clear_value = vk.ClearValue{
        .color = .{ .float_32 = .{ 0.05, 0.08, 0.16, 1.0 } },
    };
    for (command_buffers, 0..) |command_buffer, i| {
        try vkd.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit = true },
        });
        vkd.cmdBeginRenderPass(command_buffer, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffers[i],
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear_value),
        }, .@"inline");
        vkd.cmdEndRenderPass(command_buffer);
        try vkd.endCommandBuffer(command_buffer);
    }

    const image_available = try vkd.createSemaphore(&.{}, null);
    defer vkd.destroySemaphore(image_available, null);

    const render_finished = try vkd.createSemaphore(&.{}, null);
    defer vkd.destroySemaphore(render_finished, null);

    const wait_stage_flags = vk.PipelineStageFlags{ .color_attachment_output = true };

    var frame: u32 = 0;
    while (frame < max_frames and glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) : (frame += 1) {
        glfw.glfwPollEvents();

        const acquired = vkd.acquireNextImageKHR(
            swapchain,
            std.math.maxInt(u64),
            image_available,
            .null,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => continue,
            else => return err,
        };
        switch (acquired.result) {
            .success, .suboptimal_khr => {},
            else => return error.ImageAcquireFailed,
        }
        const image_index = acquired.image_index;

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&image_available),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage_flags),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffers[image_index]),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&render_finished),
        };
        try vkd.queueSubmit(queue, &.{submit_info}, .null);

        _ = vkd.queuePresentKHR(queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain),
            .p_image_indices = @ptrCast(&image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => continue,
            else => return err,
        };

        try vkd.queueWaitIdle(queue);
    }

    try vkd.deviceWaitIdle();
    std.debug.print("Vulkan smoke test rendered {d} frame(s)\n", .{frame});
}

fn selectPhysicalDevice(
    vki: vk.InstanceProxy,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !DeviceSelection {
    const devices = try vki.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(devices);
    if (devices.len == 0) return error.NoPhysicalDevice;

    for (devices) |physical_device| {
        const families = try vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(families);

        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics) continue;

            const present_support = try vki.getPhysicalDeviceSurfaceSupportKHR(
                physical_device,
                @intCast(index),
                surface,
            );
            if (present_support == .true) {
                return .{
                    .physical_device = physical_device,
                    .queue_family_index = @intCast(index),
                };
            }
        }
    }

    return error.NoSuitableQueueFamily;
}
