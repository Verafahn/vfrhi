vptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    create: *const fn (
        *anyopaque,
        description: Resource.Description,
        ret_addr: usize,
    ) Error!Resource,

    destroy: *const fn (
        *anyopaque,
        resource: Resource,
        ret_addr: usize,
    ) void,

    create_batch: *const fn (
        *anyopaque,
        descriptions: []const Resource.Description,
        resources: []Resource,
        ret_addr: usize,
    ) Error!void,

    destroy_batch: *const fn (
        *anyopaque,
        resources: []const Resource,
        ret_addr: usize,
    ) void,

    map: *const fn (
        *anyopaque,
        resource: Resource,
        offset: u64,
        size: u64,
        ret_addr: usize,
    ) Error![]u8,

    unmap: *const fn (
        *anyopaque,
        resource: Resource,
        dirty: []const Dirty,
        ret_addr: usize,
    ) void,

    get_queue: *const fn (
        *anyopaque,
        index: u32,
        ret_addr: usize,
    ) Error!Queue,

    record: *const fn (
        *anyopaque,
        resource: Resource,
        command: Command,
        ret_addr: usize,
    ) Error!void,

    device_op: *const fn (
        *anyopaque,
        operator: DeviceOp,
        output_mode: ?OutputMode,
        ret_addr: usize,
    ) Error!?[]const u8,

    query: *const fn (
        *anyopaque,
        feature: Feature,
        feature_index: u32,
        handle: ?Resource,
        output_mode: ?OutputMode,
        ret_addr: usize,
    ) Error!QueryResult,
};

pub const Queue = @import("Queue.zig");
pub const Resource = @import("Resource.zig");
pub const Command = union(enum) {};
pub const DeviceOp = union(enum) {};
pub const Feature = union(enum) {};
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OutputMode = union(enum) {
    slice: []u8,
    allocator: Allocator,
};

pub const QueryResult = struct {
    support: Support,
    result: ?[]const u8 = null,

    pub const Support = enum {
        unknown,
        support,
        unsupport,
    };
};

const Device = @This();

pub const Error = error{
    DeviceLost,
};
pub const Dirty = struct {
    offset: u64,
    size: u64,
};

pub inline fn rawCreate(
    self: Device,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    return try self.vtable.create(self.vptr, description, ret_addr);
}

pub inline fn create(
    self: Device,
    description: Resource.Description,
) Error!Resource {
    return try self.rawCreate(description, @returnAddress());
}

pub inline fn rawDestroy(self: Device, resource: Resource, ret_addr: usize) void {
    self.vtable.destroy(self.vptr, resource, ret_addr);
}

pub inline fn destroy(self: Device, resource: Resource) void {
    self.rawDestroy(resource, @returnAddress());
}

pub inline fn rawCreateBatch(
    self: Device,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Error!void {
    try self.vtable.create_batch(
        self.vptr,
        descriptions,
        resources,
        ret_addr,
    );
}

pub inline fn createBatch(
    self: Device,
    descriptions: []const Resource.Description,
    resources: []Resource,
) Error!void {
    try self.rawCreateBatch(descriptions, resources);
}

pub inline fn rawDestroyBatch(
    self: Device,
    resources: []const Resource,
    ret_addr: usize,
) void {
    self.vtable.destroy_batch(self.vptr, resources, ret_addr);
}

pub inline fn destroyBatch(self: Device, resources: []const Resource) void {
    self.rawDestroyBatch(resources, @returnAddress());
}

pub inline fn rawMap(
    self: Device,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    return try self.vtable.map(self.vptr, resource, offset, size, ret_addr);
}

pub inline fn map(
    self: Device,
    resource: Resource,
    offset: u64,
    size: u64,
) Error![]u8 {
    return try self.rawMap(resource, offset, size, @returnAddress());
}

pub inline fn rawUnmap(
    self: Device,
    resource: Resource,
    dirty: []const Dirty,
    ret_addr: usize,
) void {
    self.vtable.unmap(self.vptr, resource, dirty, ret_addr);
}

pub inline fn unmap(
    self: Device,
    resource: Resource,
    dirty: []const Dirty,
) void {
    self.rawUnmap(resource, dirty, @returnAddress());
}

pub inline fn rawGetQueue(
    self: Device,
    index: u32,
    ret_addr: usize,
) Error!Queue {
    return try self.vtable.get_queue(self.vptr, index, ret_addr);
}

pub inline fn getQueue(
    self: Device,
    index: u32,
) Error!Queue {
    return try self.rawGetQueue(index, @returnAddress());
}
