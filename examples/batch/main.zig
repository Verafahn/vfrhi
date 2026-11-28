const std = @import("std");
const rhi = @import("vfrhi");
const framework = @import("framework");

const vertex_spv = @embedFile("vert_spv");
const fragment_spv = @embedFile("frag_spv");

/// Number of grid cells along one axis.
const grid_size: u32 = 64;
const cell_count = grid_size * grid_size;
/// Two triangles per cell, three vertices per triangle.
const vertex_count = cell_count * 6;
const triangle_count = cell_count * 2;

const Vertex = extern struct {
    position: [2]f32,
    color: [3]f32,
};

/// Fills a grid of colored triangles covering the screen.
fn fillVertices(vertices: []Vertex) void {
    const inverse: f32 = 1.0 / @as(f32, @floatFromInt(grid_size));
    for (0..cell_count) |cell| {
        const cell_x = cell % grid_size;
        const cell_y = cell / grid_size;
        const fx: f32 = @floatFromInt(cell_x);
        const fy: f32 = @floatFromInt(cell_y);
        const x0 = -0.95 + 1.9 * fx * inverse;
        const x1 = -0.95 + 1.9 * (fx + 1.0) * inverse;
        const y0 = -0.95 + 1.9 * fy * inverse;
        const y1 = -0.95 + 1.9 * (fy + 1.0) * inverse;
        const color: [3]f32 = .{
            0.15 + 0.75 * fx * inverse,
            0.2 + 0.7 * fy * inverse,
            0.95 - 0.55 * fx * inverse,
        };

        const first = cell * 6;
        vertices[first + 0] = .{
            .position = .{ x0, y0 },
            .color = color,
        };
        vertices[first + 1] = .{
            .position = .{ x1, y0 },
            .color = color,
        };
        vertices[first + 2] = .{
            .position = .{ x1, y1 },
            .color = color,
        };
        vertices[first + 3] = .{
            .position = .{ x0, y0 },
            .color = color,
        };
        vertices[first + 4] = .{
            .position = .{ x1, y1 },
            .color = color,
        };
        vertices[first + 5] = .{
            .position = .{ x0, y1 },
            .color = color,
        };
    }
}

/// Runs the batch example.
pub fn main(init: std.process.Init) !void {
    const cli = try framework.parseArgs(
        init.gpa,
        init.minimal.args,
    );
    if (cli.help) {
        framework.printUsage(
            "Draws thousands of triangles in a single draw call.",
        );
        return;
    }

    const vertices = try init.gpa.alloc(Vertex, vertex_count);
    defer init.gpa.free(vertices);
    fillVertices(vertices);

    var app = try framework.App.init(init.gpa, .{
        .title = "vfrhi batch",
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

    const pipeline_layout = try rhi.PipelineLayout.create(
        device,
        .{},
    );
    defer pipeline_layout.destroy();

    const pipeline = try rhi.GraphicsPipeline.create(device, .{
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

    const vertex_buffer = try rhi.Buffer.create(device, .{
        .size = std.mem.sliceAsBytes(vertices).len,
        .usage = .{ .vertex = true },
        .memory = .{ .host_visible = true },
        .initial_data = std.mem.sliceAsBytes(vertices),
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
            .vertex_count = vertex_count,
        });
        try app.endPass(frame);
        try app.command_buffer.end();
        try app.endFrame(frame);

        frame_index += 1;
    }

    try app.waitIdle();
    std.debug.print(
        "batch: rendered {d} frame(s), {d} triangles per frame, {s}\n",
        .{ frame_index, triangle_count, cli.backend.name() },
    );
}
