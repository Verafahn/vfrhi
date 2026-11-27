identifier: Identifier,
tag: Tag,

pub const Identifier = packed struct {
    generation: u32,
    index: u32,
};

pub const Tag = enum {
    surface,
};

pub const Description = union(Tag) {
    surface: Surface.Description,
};

pub const Surface = @import("resources/Surface.zig");
