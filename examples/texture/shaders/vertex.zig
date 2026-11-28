const std = @import("std");

const in_position = @extern(*addrspace(.input) @Vector(2, f32), .{
    .name = "vertex_position",
    .decoration = .{ .location = 0 },
});
const in_uv = @extern(*addrspace(.input) @Vector(2, f32), .{
    .name = "vertex_uv",
    .decoration = .{ .location = 1 },
});
const out_uv = @extern(*addrspace(.output) @Vector(2, f32), .{
    .name = "v_uv",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.spirv_vertex) void {
    std.spirv.position_out.* = .{
        in_position.*[0],
        in_position.*[1],
        0.0,
        1.0,
    };
    out_uv.* = in_uv.*;
}
