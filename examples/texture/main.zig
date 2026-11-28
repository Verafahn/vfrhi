const std = @import("std");
const rhi = @import("vfrhi");
const framework = @import("framework");

const vertex_spv align(32) = @embedFile("vert_spv").*;
const fragment_spv align(32) = @embedFile("frag_spv").*;

const texture_size: u32 = 64;
const checker_size: u32 = 8;

const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
};

const vertices = [_]Vertex{
    .{ .position = .{ -0.8, -0.8 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ 0.8, -0.8 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.8, 0.8 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.8, 0.8 }, .uv = .{ 0.0, 1.0 } },
};

const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

/// Generates an RGBA checkerboard.
fn fillPixels(pixels: []u8) void {
    for (0..texture_size) |y| {
        for (0..texture_size) |x| {
            const checker = (x / checker_size + y / checker_size) % 2 == 0;
            const offset = (y * texture_size + x) * 4;
            const color: [4]u8 = if (checker)
                .{ 235, 105, 75, 255 }
            else
                .{ 40, 55, 95, 255 };
            @memcpy(pixels[offset..][0..4], &color);
        }
    }
}

/// Runs the texture example.
pub fn main(init: std.process.Init) !void {
    const cli = try framework.parseArgs(
        init.gpa,
        init.minimal.args,
    );
    if (cli.help) {
        framework.printUsage(
            "Draws a textured quad with a checkerboard texture.",
        );
        return;
    }

    var pixels: [texture_size * texture_size * 4]u8 = undefined;
    fillPixels(&pixels);

    var app = try framework.App.init(init.gpa, .{
        .title = "vfrhi texture",
        .backend = cli.backend,
    });
    defer app.deinit();
    const device = app.device;

    const vertex_shader = try device.createShader(.{
        .code = @ptrCast(&vertex_spv),
        .entry_point = "main",
        .stage = .vertex,
    });
    defer vertex_shader.destroy();
    const fragment_shader = try device.createShader(.{
        .code = @ptrCast(&fragment_spv),
        .entry_point = "main",
        .stage = .fragment,
    });
    defer fragment_shader.destroy();

    const texture = try device.createTexture(.{
        .format = .r8g8b8a8_unorm,
        .width = texture_size,
        .height = texture_size,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .initial_data = .{ .bytes = &pixels },
    });
    defer texture.destroy();
    const view = try texture.createView(.{});
    defer view.destroy();
    const sampler = try device.createSampler(.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .address_u = .clamp_to_edge,
        .address_v = .clamp_to_edge,
    });
    defer sampler.destroy();

    const set_layout = try device.createDescriptorSetLayout(.{
        .bindings = &.{.{
            .binding = 0,
            .kind = .combined_image_sampler,
            .stages = .{ .fragment = true },
        }},
    });
    defer set_layout.destroy();
    const pipeline_layout = try device.createPipelineLayout(.{
        .descriptor_sets = &.{set_layout.resource},
    });
    defer pipeline_layout.destroy();
    const descriptor_set = try device.createDescriptorSet(.{
        .layout = set_layout.resource,
    });
    defer descriptor_set.destroy();
    try descriptor_set.update(&.{.{
        .binding = 0,
        .kind = .{ .texture = .{
            .view = view.resource,
            .sampler = sampler.resource,
        } },
    }});

    const pipeline = try device.createGraphicsPipeline(.{
        .layout = pipeline_layout.resource,
        .vertex = vertex_shader.resource,
        .fragment = fragment_shader.resource,
        .vertex_layout = .{
            .bindings = &.{.{ .stride = @sizeOf(Vertex) }},
            .attributes = &.{
                .{
                    .location = 0,
                    .format = .r32g32_float,
                    .offset = 0,
                },
                .{
                    .location = 1,
                    .format = .r32g32_float,
                    .offset = 8,
                },
            },
        },
        .depth = .{ .enable = false, .write = false },
        .color_formats = &.{.b8g8r8a8_srgb},
    });
    defer pipeline.destroy();

    const vertex_buffer = try device.createBuffer(.{
        .size = std.mem.sliceAsBytes(&vertices).len,
        .usage = .{ .vertex = true },
        .memory = .{ .host_visible = true },
        .initial_data = std.mem.sliceAsBytes(&vertices),
    });
    defer vertex_buffer.destroy();

    const index_buffer = try device.createBuffer(.{
        .size = std.mem.sliceAsBytes(&indices).len,
        .usage = .{ .index = true },
        .memory = .{ .host_visible = true },
        .initial_data = std.mem.sliceAsBytes(&indices),
    });
    defer index_buffer.destroy();

    var frame_index: u32 = 0;
    while (cli.max_frames == 0 or frame_index < cli.max_frames) {
        if (app.shouldClose()) break;
        app.pollEvents();

        const frame = (try app.acquire()) orelse continue;

        try app.command_buffer.begin();
        try app.beginPass(frame, .{});
        try app.command_buffer.bindPipeline(.{
            .pipeline = pipeline.resource,
        });
        try app.command_buffer.bindDescriptorSets(.{
            .layout = pipeline_layout.resource,
            .sets = &.{descriptor_set.resource},
        });
        try app.command_buffer.bindVertexBuffers(.{
            .buffers = &.{vertex_buffer.resource},
        });
        try app.command_buffer.bindIndexBuffer(.{
            .buffer = index_buffer.resource,
            .type = .uint16,
        });
        try app.setViewport();
        try app.setScissor();
        try app.command_buffer.drawIndexed(.{
            .index_count = @intCast(indices.len),
        });
        try app.endPass(frame);
        try app.command_buffer.end();
        try app.endFrame(frame);

        frame_index += 1;
    }

    try app.waitIdle();
    std.debug.print(
        "texture: rendered {d} frame(s) with {s}\n",
        .{ frame_index, cli.backend.name() },
    );
}
