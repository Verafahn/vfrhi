const std = @import("std");
const rhi = @import("vfrhi");
const framework = @import("framework");

const vertex_spv = @embedFile("vert_spv");
const fragment_spv = @embedFile("frag_spv");

const Vertex = extern struct {
    position: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{
        .position = .{ -0.7, -0.6 },
        .color = .{ 1.0, 0.15, 0.15 },
    },
    .{
        .position = .{ 0.7, -0.6 },
        .color = .{ 0.15, 1.0, 0.15 },
    },
    .{
        .position = .{ 0.0, 0.7 },
        .color = .{ 0.2, 0.3, 1.0 },
    },
};

/// Runs the triangle example.
pub fn main(init: std.process.Init) !void {
    const cli = try framework.parseArgs(
        init.gpa,
        init.minimal.args,
    );
    if (cli.help) {
        framework.printUsage(
            "Clears the window and draws a colored triangle.",
        );
        return;
    }

    var app = try framework.App.init(init.gpa, .{
        .title = "vfrhi triangle",
        .backend = cli.backend,
    });
    defer app.deinit();
    const device = app.device;

    const vertex_shader = try framework.createShader(
        init.gpa,
        device,
        .vertex,
        vertex_spv,
    );
    defer vertex_shader.destroy();
    const fragment_shader = try framework.createShader(
        init.gpa,
        device,
        .fragment,
        fragment_spv,
    );
    defer fragment_shader.destroy();

    const pipeline_layout = try device.createPipelineLayout(.{});
    defer pipeline_layout.destroy();

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
                    .format = .r32g32b32_float,
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
        try app.command_buffer.bindVertexBuffers(.{
            .buffers = &.{vertex_buffer.resource},
        });
        try app.setViewport();
        try app.setScissor();
        try app.command_buffer.draw(.{
            .vertex_count = @intCast(vertices.len),
        });
        try app.endPass(frame);
        try app.command_buffer.end();
        try app.endFrame(frame);

        frame_index += 1;
    }

    try app.waitIdle();
    std.debug.print(
        "triangle: rendered {d} frame(s) with {s}\n",
        .{ frame_index, cli.backend.name() },
    );
}
