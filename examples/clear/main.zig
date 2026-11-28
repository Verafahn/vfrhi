const std = @import("std");
const framework = @import("framework");

/// Runs the clear example.
pub fn main(init: std.process.Init) !void {
    const cli = try framework.parseArgs(
        init.gpa,
        init.minimal.args,
    );
    if (cli.help) {
        framework.printUsage(
            "Opens a window and clears it to an animated color.",
        );
        return;
    }

    var app = try framework.App.init(init.gpa, .{
        .title = "vfrhi clear",
        .backend = cli.backend,
    });
    defer app.deinit();

    var frame_index: u32 = 0;
    while (cli.max_frames == 0 or frame_index < cli.max_frames) {
        if (app.shouldClose()) break;
        app.pollEvents();

        const frame = (try app.acquire()) orelse continue;

        const phase = @as(f32, @floatFromInt(frame_index)) * 0.03;
        const clear: framework.ClearColor = .{
            .r = 0.10 + 0.06 * std.math.sin(phase),
            .g = 0.12 + 0.06 * std.math.sin(phase + 2.1),
            .b = 0.22 + 0.06 * std.math.sin(phase + 4.2),
        };

        try app.command_buffer.begin();
        try app.beginPass(frame, clear);
        try app.endPass(frame);
        try app.command_buffer.end();
        try app.endFrame(frame);

        frame_index += 1;
    }

    try app.waitIdle();
    std.debug.print(
        "clear: rendered {d} frame(s) with {s}\n",
        .{ frame_index, cli.backend.name() },
    );
}
