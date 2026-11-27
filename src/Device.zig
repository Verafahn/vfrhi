const std = @import("std");
const Allocator = std.mem.Allocator;
const rhi = @import("Resource.zig");
pub const Error = rhi.Error;
const Version = rhi.Version;
const Device = @This();

/// The abstract device interface.
///
/// A `Device` is created by a backend and owns every RHI resource
/// created through it. The backend itself is external to the RHI:
/// initialize the backend first, call `asDevice`, and destroy the
/// backend only after every resource has been destroyed.
///
/// The interface deliberately has a small vtable. Resource kinds and
/// command kinds are encoded in tagged unions instead of adding one
/// virtual function per operation.
vptr: *anyopaque,
vtable: *const VTable,

/// The virtual table of a device.
pub const VTable = struct {
    create: *const fn (
        *anyopaque,
        description: rhi.Resource.Description,
        ret_addr: usize,
    ) Error!rhi.Resource,

    destroy: *const fn (
        *anyopaque,
        resource: rhi.Resource,
        ret_addr: usize,
    ) void,

    create_batch: *const fn (
        *anyopaque,
        descriptions: []const rhi.Resource.Description,
        resources: []rhi.Resource,
        ret_addr: usize,
    ) Error!void,

    destroy_batch: *const fn (
        *anyopaque,
        resources: []const rhi.Resource,
        ret_addr: usize,
    ) void,

    map: *const fn (
        *anyopaque,
        resource: rhi.Resource,
        offset: u64,
        size: u64,
        ret_addr: usize,
    ) Error![]u8,

    unmap: *const fn (
        *anyopaque,
        resource: rhi.Resource,
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
        resource: rhi.Resource,
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
        handle: ?rhi.Resource,
        output_mode: ?OutputMode,
        ret_addr: usize,
    ) Error!QueryResult,
};

pub const Resource = rhi.Resource;
pub const Queue = @import("Queue.zig").Queue;
pub const Command = @import("Command.zig").Command;
pub const DescriptorWrite = rhi.DescriptorWrite;

/// A range of resource memory dirtied by the host.
pub const Dirty = struct {
    offset: u64,
    size: u64,
};

/// Where a query result is written.
pub const OutputMode = union(enum) {
    /// Write into caller owned memory. The slice must be large enough
    /// for the query result.
    slice: []u8,
    /// Allocate the result with the given allocator. The caller owns
    /// the returned bytes and must free them with the same allocator.
    allocator: Allocator,
};

/// The result of a device query.
pub const QueryResult = struct {
    /// Whether the queried feature or resource property is available.
    support: Support,
    /// The raw query result, or `null` when no data applies.
    result: ?[]const u8 = null,

    /// The support state of a query.
    pub const Support = enum {
        /// The backend cannot answer the query.
        unknown,
        /// The queried feature is supported.
        support,
        /// The queried feature is not supported.
        unsupport,
    };
};

/// A device level capability that can be queried.
///
/// Fixed size features write a value of the type shown below. The
/// high level getters on `Device` perform the cast for the caller.
pub const Feature = union(enum) {
    /// Result: a `Version`.
    api_version,
    /// Result: the UTF-8 device name without a terminator.
    device_name,
    /// Result: the UTF-8 driver name without a terminator.
    driver_name,
    /// Result: a `DeviceType`.
    device_type,
    /// Result: a `u64` limit value.
    limit: Limit,
    /// Result: none. The `support` field reports format support.
    format: struct {
        format: rhi.Format,
        usage: rhi.FormatProperties = .{ .sampled = true },
    },
    /// Result: `SurfaceProperties`. `handle` must be a surface.
    surface,
    /// Result: `SwapchainProperties`. `handle` must be a swapchain.
    swapchain,
    /// Result: a `[]Resource` of texture handles.
    ///
    /// `handle` must be a swapchain. Provide `OutputMode.slice`
    /// backed by a `[]Resource` large enough for every image;
    /// `OutputMode.allocator` is not supported because the result
    /// needs `@alignOf(Resource)` alignment.
    swapchain_images,
    /// Result: a `[]Resource` of texture view handles.
    ///
    /// `handle` must be a swapchain. Provide `OutputMode.slice`
    /// backed by a `[]Resource` large enough for every view.
    swapchain_views,
    /// Result: `BufferProperties`. `handle` must be a buffer.
    buffer,
    /// Result: `TextureProperties`. `handle` must be a texture.
    texture,
    /// Result: `MemoryHeap`. `feature_index` selects the heap.
    memory,
    /// Result: `QueueProperties`. `feature_index` selects the queue
    /// family.
    queue,
};

/// A device limit that can be queried.
pub const Limit = enum {
    max_texture_dimension_1d,
    max_texture_dimension_2d,
    max_texture_dimension_3d,
    max_texture_array_layers,
    max_buffer_size,
    max_uniform_buffer_range,
    max_storage_buffer_range,
    max_push_constant_size,
    max_vertex_bindings,
    max_vertex_attributes,
    max_descriptor_sets,
    max_color_attachments,
};

/// The kind of physical device backing the RHI.
pub const DeviceType = enum {
    other,
    integrated_gpu,
    discrete_gpu,
    virtual_gpu,
    cpu,
};

/// A device level operation that does not create or destroy data.
pub const DeviceOp = union(enum) {
    /// Wait for every queue of the device to become idle.
    wait_idle,
    /// Wait for a fence to become signaled.
    wait_fence: struct {
        fence: rhi.Resource,
        timeout_ns: u64 = std.math.maxInt(u64),
    },
    /// Reset a fence to the unsignaled state.
    reset_fence: struct {
        fence: rhi.Resource,
    },
    /// Overwrite descriptors of an allocated descriptor set.
    write_descriptor_set: struct {
        set: rhi.Resource,
        writes: []const DescriptorWrite,
    },
};

/// Calls `vtable.create` with an explicit return address.
///
/// # Args
/// - `description`: the resource to create.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// A new handle. Destroy it with `destroy`.
///
/// # Error
/// - `Error.OutOfHostMemory`: a host allocation failed.
/// - `Error.OutOfDeviceMemory`: a device allocation failed.
/// - `Error.InvalidDescription`: `description` is inconsistent.
/// - `Error.Unsupported`: the backend cannot create this resource.
/// - `Error.InvalidResource`: a referenced resource is stale.
pub inline fn rawCreate(
    self: Device,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    return try self.vtable.create(self.vptr, description, ret_addr);
}

/// Calls `rawCreate` with `@returnAddress()`.
///
/// # Args
/// - `description`: the resource to create.
///
/// # Return
/// A new handle owned by the caller.
///
/// # Error
/// - See `rawCreate`.
pub inline fn create(
    self: Device,
    description: Resource.Description,
) Error!Resource {
    return try self.rawCreate(description, @returnAddress());
}

/// Destroys a resource with an explicit return address.
///
/// # Args
/// - `resource`: handle returned by `create`.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Note
/// Destroy resources in reverse dependency order. Backends log and
/// ignore stale handles; use their validation helpers to detect
/// lifetime errors in tests.
pub inline fn rawDestroy(
    self: Device,
    resource: Resource,
    ret_addr: usize,
) void {
    self.vtable.destroy(self.vptr, resource, ret_addr);
}

/// Calls `rawDestroy` with `@returnAddress()`.
///
/// # Args
/// - `resource`: handle returned by `create`.
pub inline fn destroy(self: Device, resource: Resource) void {
    self.rawDestroy(resource, @returnAddress());
}

/// Creates several resources with an explicit return address.
///
/// # Args
/// - `descriptions`: resources to create, one per output slot.
/// - `resources`: output handles, must have the same length.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - See `rawCreate`.
///
/// # Note
/// On failure, every resource created by this call is destroyed
/// again and the output slice is left undefined.
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

/// Calls `rawCreateBatch` with `@returnAddress()`.
///
/// # Args
/// - `descriptions`: resources to create.
/// - `resources`: output handles, same length as `descriptions`.
///
/// # Error
/// - See `rawCreateBatch`.
pub inline fn createBatch(
    self: Device,
    descriptions: []const Resource.Description,
    resources: []Resource,
) Error!void {
    try self.rawCreateBatch(descriptions, resources, @returnAddress());
}

/// Destroys several resources with an explicit return address.
///
/// # Args
/// - `resources`: handles to destroy.
/// - `ret_addr`: return address used for leak tracking.
pub inline fn rawDestroyBatch(
    self: Device,
    resources: []const Resource,
    ret_addr: usize,
) void {
    self.vtable.destroy_batch(self.vptr, resources, ret_addr);
}

/// Calls `rawDestroyBatch` with `@returnAddress()`.
///
/// # Args
/// - `resources`: handles to destroy.
pub inline fn destroyBatch(self: Device, resources: []const Resource) void {
    self.rawDestroyBatch(resources, @returnAddress());
}

/// Maps a range of a resource with an explicit return address.
///
/// # Args
/// - `resource`: a buffer that supports host mapping.
/// - `offset`: byte offset into the resource.
/// - `size`: number of bytes to map.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// A writable slice valid until `unmap`.
///
/// # Error
/// - `Error.InvalidResource`: `resource` is not a mappable buffer.
/// - `Error.InvalidDescription`: the range is out of bounds.
/// - `Error.OutOfHostMemory`: the backend cannot map the memory.
/// - `Error.Unsupported`: the resource cannot be mapped.
pub inline fn rawMap(
    self: Device,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    return try self.vtable.map(self.vptr, resource, offset, size, ret_addr);
}

/// Calls `rawMap` with `@returnAddress()`.
///
/// # Args
/// - `resource`: a mappable buffer.
/// - `offset`: byte offset into the resource.
/// - `size`: number of bytes to map.
///
/// # Return
/// A writable slice valid until `unmap`.
///
/// # Error
/// - See `rawMap`.
pub inline fn map(
    self: Device,
    resource: Resource,
    offset: u64,
    size: u64,
) Error![]u8 {
    return try self.rawMap(resource, offset, size, @returnAddress());
}

/// Unmaps a resource with an explicit return address.
///
/// # Args
/// - `resource`: the mapped resource.
/// - `dirty`: ranges written by the host. An empty slice means every
///   mapped byte was written.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Note
/// The slice returned by `map` is invalid after this call.
pub inline fn rawUnmap(
    self: Device,
    resource: Resource,
    dirty: []const Dirty,
    ret_addr: usize,
) void {
    self.vtable.unmap(self.vptr, resource, dirty, ret_addr);
}

/// Calls `rawUnmap` with `@returnAddress()`.
///
/// # Args
/// - `resource`: the mapped resource.
/// - `dirty`: ranges written by the host.
pub inline fn unmap(
    self: Device,
    resource: Resource,
    dirty: []const Dirty,
) void {
    self.rawUnmap(resource, dirty, @returnAddress());
}

/// Fetches a queue with an explicit return address.
///
/// # Args
/// - `index`: backend defined queue index, usually `0`.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// A queue interface borrowing the device.
///
/// # Error
/// - `Error.Unsupported`: `index` does not exist.
pub inline fn rawGetQueue(
    self: Device,
    index: u32,
    ret_addr: usize,
) Error!Queue {
    return try self.vtable.get_queue(self.vptr, index, ret_addr);
}

/// Calls `rawGetQueue` with `@returnAddress()`.
///
/// # Args
/// - `index`: backend defined queue index.
///
/// # Return
/// A queue interface borrowing the device.
///
/// # Error
/// - See `rawGetQueue`.
pub inline fn getQueue(self: Device, index: u32) Error!Queue {
    return try self.rawGetQueue(index, @returnAddress());
}

/// Records one command with an explicit return address.
///
/// # Args
/// - `resource`: a command buffer.
/// - `command`: the command to record.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.InvalidResource`: `resource` is not a command buffer or
///   is in the wrong state.
/// - `Error.InvalidDescription`: `command` references stale or
///   mismatched resources.
/// - `Error.OutOfHostMemory`: recording needs temporary memory and
///   the allocation fails.
pub inline fn rawRecord(
    self: Device,
    resource: Resource,
    command: Command,
    ret_addr: usize,
) Error!void {
    try self.vtable.record(self.vptr, resource, command, ret_addr);
}

/// Calls `rawRecord` with `@returnAddress()`.
///
/// # Args
/// - `resource`: a command buffer.
/// - `command`: the command to record.
///
/// # Error
/// - See `rawRecord`.
pub inline fn record(
    self: Device,
    resource: Resource,
    command: Command,
) Error!void {
    try self.rawRecord(resource, command, @returnAddress());
}

/// Runs a device operation with an explicit return address.
///
/// # Args
/// - `operator`: the operation to run.
/// - `output_mode`: where an operation that produces data writes its
///   result. Operations without output ignore it.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// Operation specific bytes, or `null` when the operation has no
/// output.
///
/// # Error
/// - `Error.InvalidResource`: a referenced resource is stale.
/// - `Error.Timeout`: a wait operation timed out.
/// - `Error.DeviceLost`: the device was lost.
/// - `Error.Unsupported`: the operation is not implemented.
/// - `Error.BufferTooSmall`: `output_mode` provides too little space.
pub inline fn rawDeviceOp(
    self: Device,
    operator: DeviceOp,
    output_mode: ?OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    return try self.vtable.device_op(
        self.vptr,
        operator,
        output_mode,
        ret_addr,
    );
}

/// Calls `rawDeviceOp` with `@returnAddress()`.
///
/// # Args
/// - `operator`: the operation to run.
/// - `output_mode`: destination for operation output.
///
/// # Return
/// Operation specific bytes, or `null`.
///
/// # Error
/// - See `rawDeviceOp`.
pub inline fn deviceOp(
    self: Device,
    operator: DeviceOp,
    output_mode: ?OutputMode,
) Error!?[]const u8 {
    return try self.rawDeviceOp(operator, output_mode, @returnAddress());
}

/// Queries a capability with an explicit return address.
///
/// # Args
/// - `feature`: the capability to query.
/// - `feature_index`: selects an element of array features such as
///   memory heaps and queue families. Ignored otherwise.
/// - `handle`: resource the query applies to, if any.
/// - `output_mode`: where the result bytes are written.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// A `QueryResult`. `result` is `null` for support only queries.
///
/// # Error
/// - `Error.InvalidResource`: `handle` is stale or of the wrong type.
/// - `Error.InvalidDescription`: `feature_index` is out of range.
/// - `Error.OutOfHostMemory`: allocating the result fails.
/// - `Error.BufferTooSmall`: the provided slice is too small.
/// - `Error.Unsupported`: the backend cannot answer the query.
pub inline fn rawQuery(
    self: Device,
    feature: Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?OutputMode,
    ret_addr: usize,
) Error!QueryResult {
    return try self.vtable.query(
        self.vptr,
        feature,
        feature_index,
        handle,
        output_mode,
        ret_addr,
    );
}

/// Calls `rawQuery` with `@returnAddress()`.
///
/// # Args
/// - `feature`: the capability to query.
/// - `feature_index`: index for array features.
/// - `handle`: resource the query applies to.
/// - `output_mode`: destination for result bytes.
///
/// # Return
/// A `QueryResult`.
///
/// # Error
/// - See `rawQuery`.
pub inline fn query(
    self: Device,
    feature: Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?OutputMode,
) Error!QueryResult {
    return try self.rawQuery(
        feature,
        feature_index,
        handle,
        output_mode,
        @returnAddress(),
    );
}

fn queryFixed(
    self: Device,
    comptime T: type,
    feature: Feature,
    feature_index: u32,
    handle: ?Resource,
    ret_addr: usize,
) Error!?T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    const result = try self.rawQuery(
        feature,
        feature_index,
        handle,
        .{ .slice = &bytes },
        ret_addr,
    );
    return switch (result.support) {
        .support => std.mem.bytesToValue(T, &bytes),
        .unsupport, .unknown => null,
    };
}

/// Returns the API version of the device.
///
/// # Args
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// The version reported by the backend.
///
/// # Error
/// - `Error.Unsupported`: the backend does not expose a version.
pub fn getApiVersionWithAddr(
    self: Device,
    ret_addr: usize,
) Error!Version {
    return try self.queryFixed(
        Version,
        .api_version,
        0,
        null,
        ret_addr,
    ) orelse error.Unsupported;
}

/// Calls `getApiVersionWithAddr` with `@returnAddress()`.
///
/// # Return
/// The version reported by the backend.
///
/// # Error
/// - See `getApiVersionWithAddr`.
pub fn getApiVersion(self: Device) Error!Version {
    return try self.getApiVersionWithAddr(@returnAddress());
}

/// Returns the kind of the physical device.
///
/// # Args
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// The `DeviceType` reported by the backend.
///
/// # Error
/// - `Error.Unsupported`: the backend does not report a device type.
pub fn getDeviceTypeWithAddr(
    self: Device,
    ret_addr: usize,
) Error!DeviceType {
    return try self.queryFixed(
        DeviceType,
        .device_type,
        0,
        null,
        ret_addr,
    ) orelse error.Unsupported;
}

/// Calls `getDeviceTypeWithAddr` with `@returnAddress()`.
///
/// # Return
/// The `DeviceType` reported by the backend.
///
/// # Error
/// - See `getDeviceTypeWithAddr`.
pub fn getDeviceType(self: Device) Error!DeviceType {
    return try self.getDeviceTypeWithAddr(@returnAddress());
}

/// Returns the UTF-8 name of the device.
///
/// # Args
/// - `allocator`: allocator used for the returned name.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// An allocated name owned by the caller.
///
/// # Error
/// - `Error.OutOfHostMemory`: allocating the name fails.
/// - `Error.Unsupported`: the backend does not expose a name.
pub fn getDeviceNameWithAddr(
    self: Device,
    allocator: Allocator,
    ret_addr: usize,
) Error![]u8 {
    const result = try self.rawQuery(
        .device_name,
        0,
        null,
        .{ .allocator = allocator },
        ret_addr,
    );
    return switch (result.support) {
        .support => @constCast(result.result orelse return error.Unsupported),
        .unsupport, .unknown => error.Unsupported,
    };
}

/// Calls `getDeviceNameWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `allocator`: allocator used for the returned name.
///
/// # Return
/// An allocated name owned by the caller.
///
/// # Error
/// - See `getDeviceNameWithAddr`.
pub fn getDeviceName(
    self: Device,
    allocator: Allocator,
) Error![]u8 {
    return try self.getDeviceNameWithAddr(allocator, @returnAddress());
}

/// Returns a device limit.
///
/// # Args
/// - `limit`: the limit to query.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// The limit value as a `u64`.
///
/// # Error
/// - `Error.Unsupported`: the backend does not expose the limit.
pub fn getLimitWithAddr(
    self: Device,
    limit: Limit,
    ret_addr: usize,
) Error!u64 {
    return try self.queryFixed(
        u64,
        .{ .limit = limit },
        0,
        null,
        ret_addr,
    ) orelse error.Unsupported;
}

/// Calls `getLimitWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `limit`: the limit to query.
///
/// # Return
/// The limit value as a `u64`.
///
/// # Error
/// - See `getLimitWithAddr`.
pub fn getLimit(self: Device, limit: Limit) Error!u64 {
    return try self.getLimitWithAddr(limit, @returnAddress());
}

/// Returns one memory heap of the device.
///
/// # Args
/// - `index`: heap index, starting at zero.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// Size and residency of the heap.
///
/// # Error
/// - `Error.Unsupported`: `index` does not exist.
pub fn getMemoryHeapWithAddr(
    self: Device,
    index: u32,
    ret_addr: usize,
) Error!rhi.MemoryHeap {
    return try self.queryFixed(
        rhi.MemoryHeap,
        .memory,
        index,
        null,
        ret_addr,
    ) orelse error.Unsupported;
}

/// Calls `getMemoryHeapWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `index`: heap index, starting at zero.
///
/// # Return
/// Size and residency of the heap.
///
/// # Error
/// - See `getMemoryHeapWithAddr`.
pub fn getMemoryHeap(
    self: Device,
    index: u32,
) Error!rhi.MemoryHeap {
    return try self.getMemoryHeapWithAddr(index, @returnAddress());
}

/// Returns the properties of a queue family.
///
/// # Args
/// - `index`: queue family index, starting at zero.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// Capabilities and queue count of the family.
///
/// # Error
/// - `Error.Unsupported`: `index` does not exist.
pub fn getQueuePropertiesWithAddr(
    self: Device,
    index: u32,
    ret_addr: usize,
) Error!rhi.QueueProperties {
    return try self.queryFixed(
        rhi.QueueProperties,
        .queue,
        index,
        null,
        ret_addr,
    ) orelse error.Unsupported;
}

/// Calls `getQueuePropertiesWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `index`: queue family index, starting at zero.
///
/// # Return
/// Capabilities and queue count of the family.
///
/// # Error
/// - See `getQueuePropertiesWithAddr`.
pub fn getQueueProperties(
    self: Device,
    index: u32,
) Error!rhi.QueueProperties {
    return try self.getQueuePropertiesWithAddr(index, @returnAddress());
}

/// Checks whether a format supports some usage.
///
/// # Args
/// - `format`: the format to check.
/// - `usage`: the usages that must be supported.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// `true` when every requested usage is supported.
///
/// # Error
/// - `Error.Unsupported`: the backend cannot answer the query.
pub fn supportsFormatWithAddr(
    self: Device,
    format: rhi.Format,
    usage: rhi.FormatProperties,
    ret_addr: usize,
) Error!bool {
    const result = try self.rawQuery(
        .{ .format = .{ .format = format, .usage = usage } },
        0,
        null,
        null,
        ret_addr,
    );
    return switch (result.support) {
        .support => true,
        .unsupport => false,
        .unknown => error.Unsupported,
    };
}

/// Calls `supportsFormatWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `format`: the format to check.
/// - `usage`: the usages that must be supported.
///
/// # Return
/// `true` when every requested usage is supported.
///
/// # Error
/// - See `supportsFormatWithAddr`.
pub fn supportsFormat(
    self: Device,
    format: rhi.Format,
    usage: rhi.FormatProperties,
) Error!bool {
    return try self.supportsFormatWithAddr(
        format,
        usage,
        @returnAddress(),
    );
}

/// Waits for the device to become idle.
///
/// # Args
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.DeviceLost`: the device was lost while waiting.
pub fn waitIdleWithAddr(self: Device, ret_addr: usize) Error!void {
    _ = try self.rawDeviceOp(.wait_idle, null, ret_addr);
}

/// Calls `waitIdleWithAddr` with `@returnAddress()`.
///
/// # Error
/// - See `waitIdleWithAddr`.
pub fn waitIdle(self: Device) Error!void {
    try self.waitIdleWithAddr(@returnAddress());
}

/// Waits for a fence to become signaled.
///
/// # Args
/// - `fence`: a fence resource.
/// - `timeout_ns`: timeout in nanoseconds.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.Timeout`: the fence was not signaled in time.
/// - `Error.InvalidResource`: `fence` is not a fence.
/// - `Error.DeviceLost`: the device was lost while waiting.
pub fn waitFenceWithAddr(
    self: Device,
    fence: Resource,
    timeout_ns: u64,
    ret_addr: usize,
) Error!void {
    _ = try self.rawDeviceOp(
        .{ .wait_fence = .{
            .fence = fence,
            .timeout_ns = timeout_ns,
        } },
        null,
        ret_addr,
    );
}

/// Calls `waitFenceWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `fence`: a fence resource.
/// - `timeout_ns`: timeout in nanoseconds.
///
/// # Error
/// - See `waitFenceWithAddr`.
pub fn waitFence(
    self: Device,
    fence: Resource,
    timeout_ns: u64,
) Error!void {
    try self.waitFenceWithAddr(fence, timeout_ns, @returnAddress());
}

/// Resets a fence to the unsignaled state.
///
/// # Args
/// - `fence`: a fence resource that is not in use.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.InvalidResource`: `fence` is not a fence.
/// - `Error.DeviceLost`: the device was lost.
pub fn resetFenceWithAddr(
    self: Device,
    fence: Resource,
    ret_addr: usize,
) Error!void {
    _ = try self.rawDeviceOp(
        .{ .reset_fence = .{ .fence = fence } },
        null,
        ret_addr,
    );
}

/// Calls `resetFenceWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `fence`: a fence resource that is not in use.
///
/// # Error
/// - See `resetFenceWithAddr`.
pub fn resetFence(self: Device, fence: Resource) Error!void {
    try self.resetFenceWithAddr(fence, @returnAddress());
}

/// Overwrites descriptors of a descriptor set.
///
/// # Args
/// - `set`: a descriptor set resource.
/// - `writes`: host side descriptor updates.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.InvalidResource`: `set` or a write resource is stale.
/// - `Error.InvalidDescription`: a write references a missing
///   binding or mismatched descriptor kind.
pub fn writeDescriptorSetWithAddr(
    self: Device,
    set: Resource,
    writes: []const DescriptorWrite,
    ret_addr: usize,
) Error!void {
    _ = try self.rawDeviceOp(
        .{ .write_descriptor_set = .{
            .set = set,
            .writes = writes,
        } },
        null,
        ret_addr,
    );
}

/// Calls `writeDescriptorSetWithAddr` with `@returnAddress()`.
///
/// # Args
/// - `set`: a descriptor set resource.
/// - `writes`: host side descriptor updates.
///
/// # Error
/// - See `writeDescriptorSetWithAddr`.
pub fn writeDescriptorSet(
    self: Device,
    set: Resource,
    writes: []const DescriptorWrite,
) Error!void {
    try self.writeDescriptorSetWithAddr(
        set,
        writes,
        @returnAddress(),
    );
}
