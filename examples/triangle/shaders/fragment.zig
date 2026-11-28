const in_color = @extern(*addrspace(.input) @Vector(3, f32), .{
    .name = "v_color",
    .decoration = .{ .location = 0 },
});
const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    out_color.* = .{
        in_color.*[0],
        in_color.*[1],
        in_color.*[2],
        1.0,
    };
}
