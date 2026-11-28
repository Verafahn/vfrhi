const std = @import("std");
const spirv = std.spirv;

const Image = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
    .format = .unknown,
    .dim = .@"2d",
    .depth = .not_depth,
    .access = .unknown,
    .arrayed = false,
    .multisampled = false,
} });
const SampledImage = @SpirvType(.{ .sampled_image = Image });

const in_uv = @extern(*addrspace(.input) @Vector(2, f32), .{
    .name = "v_uv",
    .decoration = .{ .location = 0 },
});
const albedo = @extern(*addrspace(.constant) SampledImage, .{
    .name = "albedo",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});
const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    out_color.* = spirv.imageSampleImplicitLod(albedo, in_uv.*);
}
