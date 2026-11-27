const std = @import("std");
const rhi = @import("rhi");
const testing = std.testing;
const test_log_level: std.log.Level = .err;

fn createHeadlessSurface(device: rhi.Device) !rhi.Surface {
    return rhi.Surface.create(device, .{
        .native = .{ .headless = .{ .width = 800, .height = 600 } },
    });
}

test "test backend starts and stops" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    try backend.validate();
}

test "surface and swapchain lifecycle" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const surface = try createHeadlessSurface(device);
        defer surface.destroy();

        const surface_properties = try surface.getProperties();
        try testing.expectEqual(
            @as(u32, 800),
            surface_properties.current_width,
        );
        try testing.expectEqual(
            @as(u32, 600),
            surface_properties.current_height,
        );

        const swapchain = try rhi.Swapchain.create(device, .{
            .surface = surface.resource,
            .width = 800,
            .height = 600,
            .image_count = 3,
        });
        defer swapchain.destroy();

        const images = try swapchain.images(testing.allocator);
        defer testing.allocator.free(images);
        try testing.expectEqual(@as(usize, 3), images.len);

        const views = try swapchain.views(testing.allocator);
        defer testing.allocator.free(views);
        try testing.expectEqual(@as(usize, 3), views.len);

        const queue = try device.getQueue(0);
        const acquired = try swapchain.acquire(queue, null, null);
        try testing.expect(acquired.image_index < 3);
        try swapchain.present(.{
            .queue = queue,
            .image_index = acquired.image_index,
        });
    }

    try backend.validate();
}

test "buffer mapping and initial data" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const initial = [_]u8{ 1, 2, 3, 4 };
        const buffer = try rhi.Buffer.create(device, .{
            .size = 16,
            .memory = .{ .host_visible = true },
            .usage = .{ .storage = true },
            .initial_data = &initial,
        });
        defer buffer.destroy();

        var read: [4]u8 = undefined;
        try buffer.read(0, &read);
        try testing.expectEqualSlices(u8, &initial, &read);

        try buffer.write(4, &.{ 5, 6, 7, 8 });
        var read_after: [4]u8 = undefined;
        try buffer.read(4, &read_after);
        try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, &read_after);

        const properties = try buffer.getProperties();
        try testing.expectEqual(@as(u64, 16), properties.size);

        const mapped = try buffer.map(0, 4);
        try testing.expectEqual(@as(usize, 4), mapped.len);
        buffer.unmap(&.{.{ .offset = 0, .size = 4 }});
    }

    try backend.validate();
}

test "device local buffer cannot be mapped" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const buffer = try rhi.Buffer.create(device, .{
            .size = 64,
            .memory = .{},
            .usage = .{ .uniform = true },
        });
        defer buffer.destroy();

        try testing.expectError(
            error.Unsupported,
            buffer.map(0, 64),
        );
    }

    backend.clearErrors();
    try backend.validate();
}

test "texture, view, and sampler lifecycle" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        var pixels: [4 * 4 * 4]u8 = undefined;
        @memset(&pixels, 0x7f);

        const texture = try rhi.Texture.create(device, .{
            .format = .r8g8b8a8_unorm,
            .width = 4,
            .height = 4,
            .initial_data = .{ .bytes = &pixels },
            .usage = .{ .sampled = true, .transfer_dst = true },
        });
        defer texture.destroy();

        const properties = try texture.getProperties();
        try testing.expectEqual(@as(u32, 4), properties.width);
        try testing.expectEqual(@as(u32, 4), properties.height);
        try testing.expectEqual(
            rhi.types.Format.r8g8b8a8_unorm,
            properties.format,
        );

        const view = try texture.createView(.{});
        defer view.destroy();
        const sampler = try rhi.Sampler.create(device, .{});
        defer sampler.destroy();

        const descriptor_layout = try rhi.DescriptorSetLayout.create(
            device,
            .{
                .bindings = &.{
                    .{
                        .binding = 0,
                        .kind = .combined_image_sampler,
                        .stages = .{ .fragment = true },
                    },
                    .{
                        .binding = 1,
                        .kind = .uniform_buffer,
                        .stages = .{ .vertex = true },
                    },
                },
            },
        );
        defer descriptor_layout.destroy();

        const pipeline_layout = try rhi.PipelineLayout.create(device, .{
            .descriptor_sets = &.{descriptor_layout.resource},
        });
        defer pipeline_layout.destroy();

        const buffer = try rhi.Buffer.create(device, .{
            .size = 64,
            .memory = .{ .host_visible = true },
            .usage = .{ .uniform = true },
        });
        defer buffer.destroy();

        const set = try rhi.DescriptorSet.create(device, .{
            .layout = descriptor_layout.resource,
        });
        defer set.destroy();

        try set.update(&.{
            .{
                .binding = 0,
                .kind = .{ .texture = .{
                    .view = view.resource,
                    .sampler = sampler.resource,
                } },
            },
            .{
                .binding = 1,
                .kind = .{ .buffer = .{
                    .buffer = buffer.resource,
                    .size = 64,
                } },
            },
        });
    }

    try backend.validate();
}

test "pipeline creation and validation" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const vertex = try rhi.Shader.create(device, .{
            .stage = .vertex,
            .code = &.{0x07230203},
        });
        defer vertex.destroy();

        const fragment = try rhi.Shader.create(device, .{
            .stage = .fragment,
            .code = &.{0x07230203},
        });
        defer fragment.destroy();

        const layout = try rhi.PipelineLayout.create(device, .{});
        defer layout.destroy();

        const pipeline = try rhi.GraphicsPipeline.create(device, .{
            .layout = layout.resource,
            .vertex = vertex.resource,
            .fragment = fragment.resource,
            .vertex_layout = .{
                .bindings = &.{.{ .binding = 0, .stride = 12 }},
                .attributes = &.{
                    .{
                        .location = 0,
                        .binding = 0,
                        .format = .r32g32b32_float,
                    },
                },
            },
            .color_formats = &.{.b8g8r8a8_srgb},
        });
        defer pipeline.destroy();

        const compute_shader = try rhi.Shader.create(device, .{
            .stage = .compute,
            .code = &.{0x07230203},
        });
        defer compute_shader.destroy();

        const compute = try rhi.ComputePipeline.create(device, .{
            .layout = layout.resource,
            .shader = compute_shader.resource,
        });
        defer compute.destroy();
    }

    try backend.validate();
}

test "command buffer draw submission and fence" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();
    const queue = try device.getQueue(0);

    {
        const surface = try createHeadlessSurface(device);
        defer surface.destroy();
        const swapchain = try rhi.Swapchain.create(device, .{
            .surface = surface.resource,
            .width = 64,
            .height = 64,
            .image_count = 2,
        });
        defer swapchain.destroy();

        const views = try swapchain.views(testing.allocator);
        defer testing.allocator.free(views);

        const vertex = try rhi.Shader.create(device, .{
            .stage = .vertex,
            .code = &.{0x07230203},
        });
        defer vertex.destroy();
        const fragment = try rhi.Shader.create(device, .{
            .stage = .fragment,
            .code = &.{0x07230203},
        });
        defer fragment.destroy();
        const layout = try rhi.PipelineLayout.create(device, .{});
        defer layout.destroy();
        const pipeline = try rhi.GraphicsPipeline.create(device, .{
            .layout = layout.resource,
            .vertex = vertex.resource,
            .fragment = fragment.resource,
            .color_formats = &.{.b8g8r8a8_srgb},
        });
        defer pipeline.destroy();

        const command_buffer = try rhi.CommandBuffer.create(device, .{});
        defer command_buffer.destroy();
        const fence = try rhi.Fence.create(device, .{});
        defer fence.destroy();

        try command_buffer.begin();
        try command_buffer.beginRendering(.{
            .area = .{ .width = 64, .height = 64 },
            .color_attachments = &.{.{ .view = views[0] }},
        });
        try command_buffer.bindPipeline(.{
            .pipeline = pipeline.resource,
        });
        try command_buffer.setViewport(.{ .width = 64, .height = 64 });
        try command_buffer.setScissor(.{ .width = 64, .height = 64 });
        try command_buffer.draw(.{ .vertex_count = 3 });
        try command_buffer.endRendering();
        try command_buffer.end();

        try command_buffer.submit(queue, .{ .fence = fence });
        try fence.wait(1_000_000);

        const acquired = try swapchain.acquire(queue, null, null);
        try swapchain.present(.{
            .queue = queue,
            .image_index = acquired.image_index,
        });
    }

    try backend.validate();
}

test "command validation rejects invalid draws" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const command_buffer = try rhi.CommandBuffer.create(device, .{});
        defer command_buffer.destroy();

        try command_buffer.begin();
        try testing.expectError(
            error.InvalidDescription,
            command_buffer.draw(.{ .vertex_count = 3 }),
        );
        try command_buffer.end();
    }

    backend.clearErrors();
    try backend.validate();
}

test "copy commands" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const src = try rhi.Buffer.create(device, .{
            .size = 64,
            .usage = .{ .transfer_src = true },
            .memory = .{ .host_visible = true },
        });
        defer src.destroy();

        const dst = try rhi.Buffer.create(device, .{
            .size = 64,
            .usage = .{ .transfer_dst = true },
        });
        defer dst.destroy();

        const command_buffer = try rhi.CommandBuffer.create(device, .{});
        defer command_buffer.destroy();

        try command_buffer.begin();
        try command_buffer.copyBuffer(.{
            .src = src.resource,
            .dst = dst.resource,
            .regions = &.{.{ .size = 64 }},
        });
        try command_buffer.end();
    }

    try backend.validate();
}

test "query features" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    const version = try device.getApiVersion();
    try testing.expectEqual(@as(u7, 1), version.major);
    try testing.expectEqual(@as(u10, 3), version.minor);

    const name = try device.getDeviceName(testing.allocator);
    defer testing.allocator.free(name);
    try testing.expect(name.len != 0);

    const limit = try device.getLimit(.max_push_constant_size);
    try testing.expectEqual(@as(u64, 256), limit);

    try testing.expect(try device.supportsFormat(
        .b8g8r8a8_srgb,
        .{ .color_attachment = true, .sampled = true },
    ));
    try testing.expect(!try device.supportsFormat(
        .d32_float,
        .{ .color_attachment = true },
    ));

    var heap_bytes: [@sizeOf(rhi.types.MemoryHeap)]u8 = undefined;
    const heap_result = try device.query(
        .memory,
        0,
        null,
        .{ .slice = &heap_bytes },
    );
    try testing.expectEqual(
        rhi.Device.QueryResult.Support.support,
        heap_result.support,
    );
    const heap = std.mem.bytesToValue(
        rhi.types.MemoryHeap,
        &heap_bytes,
    );
    try testing.expect(heap.device_local);
    try testing.expectEqual(
        heap.size,
        (try device.getMemoryHeap(0)).size,
    );

    const direct_heap = try device.getMemoryHeap(0);
    try testing.expect(direct_heap.device_local);
    const queue_properties = try device.getQueueProperties(0);
    try testing.expect(queue_properties.capabilities.graphics);

    var queue_bytes: [@sizeOf(rhi.types.QueueProperties)]u8 = undefined;
    const queue_result = try device.query(
        .queue,
        0,
        null,
        .{ .slice = &queue_bytes },
    );
    try testing.expectEqual(
        rhi.Device.QueryResult.Support.support,
        queue_result.support,
    );

    try backend.validate();
}

test "batch create and destroy" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    var handles: [2]rhi.Resource = undefined;
    try device.createBatch(&.{
        .{ .buffer = .{
            .size = 16,
            .memory = .{ .host_visible = true },
        } },
        .{ .texture = .{
            .format = .r8_unorm,
            .width = 2,
            .height = 2,
        } },
    }, &handles);

    try testing.expectEqual(rhi.Resource.Tag.buffer, handles[0].tag);
    try testing.expectEqual(rhi.Resource.Tag.texture, handles[1].tag);

    device.destroyBatch(&handles);
    try backend.validate();
}

test "leak detection" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    const buffer = try rhi.Buffer.create(device, .{
        .size = 8,
        .memory = .{ .host_visible = true },
    });

    try testing.expectError(error.LeakedResources, backend.validate());
    buffer.destroy();
    try backend.validate();
}

test "dependency violation is logged" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    const surface = try createHeadlessSurface(device);
    const swapchain = try rhi.Swapchain.create(device, .{
        .surface = surface.resource,
        .width = 16,
        .height = 16,
    });

    surface.destroy();
    try testing.expectEqual(@as(usize, 1), backend.errorCount());

    backend.clearErrors();
    swapchain.destroy();
    surface.destroy();
    try backend.validate();
}

test "stale handle is rejected" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    const buffer = try rhi.Buffer.create(device, .{
        .size = 8,
        .memory = .{ .host_visible = true },
    });
    buffer.destroy();
    buffer.destroy();

    try testing.expectEqual(@as(usize, 1), backend.errorCount());
    backend.clearErrors();
    try backend.validate();
}

test "fence wait and reset" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const unsignaled = try rhi.Fence.create(device, .{});
        defer unsignaled.destroy();
        try testing.expectError(error.Timeout, unsignaled.wait(0));
        try unsignaled.reset();

        const signaled = try rhi.Fence.create(
            device,
            .{ .signaled = true },
        );
        defer signaled.destroy();
        try signaled.wait(0);
        try signaled.reset();
    }

    backend.clearErrors();
    try backend.validate();
}

test "invalid descriptor writes are rejected" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const layout = try rhi.DescriptorSetLayout.create(device, .{
            .bindings = &.{.{
                .binding = 0,
                .kind = .uniform_buffer,
                .stages = .{ .vertex = true },
            }},
        });
        defer layout.destroy();
        const set = try rhi.DescriptorSet.create(device, .{
            .layout = layout.resource,
        });
        defer set.destroy();
        const buffer = try rhi.Buffer.create(device, .{
            .size = 16,
            .memory = .{ .host_visible = true },
            .usage = .{ .uniform = true },
        });
        defer buffer.destroy();

        try testing.expectError(error.InvalidDescription, set.update(&.{
            .{
                .binding = 0,
                .kind = .{ .sampler = buffer.resource },
            },
        }));
        try testing.expectError(error.InvalidDescription, set.update(&.{
            .{
                .binding = 9,
                .kind = .{ .buffer = .{
                    .buffer = buffer.resource,
                    .size = 16,
                } },
            },
        }));
    }

    backend.clearErrors();
    try backend.validate();
}

test "texture view depends on its texture" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    const texture = try rhi.Texture.create(device, .{
        .format = .r8_unorm,
        .width = 2,
        .height = 2,
    });
    const view = try texture.createView(.{});

    texture.destroy();
    try testing.expectEqual(@as(usize, 1), backend.errorCount());

    backend.clearErrors();
    view.destroy();
    texture.destroy();
    try backend.validate();
}

test "queue selection" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.initWithOptions(
        testing.allocator,
        .{ .queues = &.{
            .{
                .family_index = 2,
                .queue_index = 1,
                .capabilities = .{ .compute = true },
            },
        } },
    );
    defer backend.deinit();
    const device = backend.asDevice();

    const queue = try device.getQueue(0);
    try testing.expectEqual(@as(u32, 2), queue.family_index);
    try testing.expectEqual(@as(u32, 1), queue.queue_index);

    try testing.expectError(error.Unsupported, device.getQueue(1));
    backend.clearErrors();
    try backend.validate();
}

test "command state validation" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const command_buffer = try rhi.CommandBuffer.create(device, .{});
        defer command_buffer.destroy();

        try testing.expectError(
            error.InvalidDescription,
            command_buffer.end(),
        );
        try command_buffer.begin();
        try testing.expectError(
            error.InvalidDescription,
            command_buffer.endRendering(),
        );
        try command_buffer.end();
        try testing.expectError(
            error.InvalidDescription,
            command_buffer.draw(.{ .vertex_count = 3 }),
        );
    }

    backend.clearErrors();
    try backend.validate();
}

test "external resource data is accessible" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const buffer_bytes = [_]u8{ 9, 8, 7, 6 };
        const buffer = try rhi.Buffer.create(device, .{
            .size = buffer_bytes.len,
            .memory = .{ .host_visible = true },
            .initial_data = &buffer_bytes,
        });
        defer buffer.destroy();
        try testing.expectEqualSlices(
            u8,
            &buffer_bytes,
            backend.bufferData(buffer.resource).?,
        );

        const texture_bytes: [16]u8 = @splat(0x11);
        const texture = try rhi.Texture.create(device, .{
            .format = .r8_unorm,
            .width = 4,
            .height = 4,
            .initial_data = .{ .bytes = &texture_bytes },
            .usage = .{ .sampled = true, .transfer_dst = true },
        });
        defer texture.destroy();
        try testing.expectEqualSlices(
            u8,
            &texture_bytes,
            backend.textureData(texture.resource).?,
        );
    }

    try backend.validate();
}

test "generation reuse rejects old handles" {
    testing.log_level = test_log_level;
    const backend = try rhi.Test.init(testing.allocator);
    defer backend.deinit();
    const device = backend.asDevice();

    {
        const first = try rhi.Buffer.create(device, .{
            .size = 8,
            .memory = .{ .host_visible = true },
        });
        const old_handle = first.resource;
        first.destroy();

        const second = try rhi.Buffer.create(device, .{
            .size = 8,
            .memory = .{ .host_visible = true },
        });
        defer second.destroy();

        try testing.expectEqual(
            old_handle.identifier.index,
            second.resource.identifier.index,
        );
        try testing.expect(
            old_handle.identifier.generation !=
                second.resource.identifier.generation,
        );

        device.destroy(old_handle);
        try testing.expectEqual(@as(usize, 1), backend.errorCount());
    }

    backend.clearErrors();
    try backend.validate();
}

test "vulkan backend compiles when enabled" {
    testing.log_level = test_log_level;
    if (rhi.vulkan_enabled) {
        const Vulkan = rhi.Vulkan;
        _ = Vulkan.init;
        _ = Vulkan.deinit;
        _ = Vulkan.asDevice;
        std.testing.refAllDecls(Vulkan);
    }
}
