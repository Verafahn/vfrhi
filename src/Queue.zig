//! The abstract queue interface.
//!
//! A queue is borrowed from a device. Queue lifecycle is owned by the
//! device: do not destroy a queue, destroy the device resource owner
//! instead.
const std = @import("std");
const rhi = @import("Resource.zig");
const Resource = rhi.Resource;
pub const Error = rhi.Error;
const Queue = @This();

vptr: *anyopaque,
vtable: *const VTable,
family_index: u32,
queue_index: u32,

/// Queue capabilities.
pub const Capabilities = rhi.QueueCapabilities;

/// The virtual table of a queue.
///
/// Every function receives the backend pointer plus the queue
/// identity, because queues are lightweight values and do not
/// own backend state.
pub const VTable = struct {
    acquire: *const fn (
        *anyopaque,
        family_index: u32,
        queue_index: u32,
        description: Acquire,
        ret_addr: usize,
    ) Error!Acquired,

    submit: *const fn (
        *anyopaque,
        family_index: u32,
        queue_index: u32,
        submission: Submission,
        ret_addr: usize,
    ) Error!void,

    present: *const fn (
        *anyopaque,
        family_index: u32,
        queue_index: u32,
        description: Present,
        ret_addr: usize,
    ) Error!void,

    wait_idle: *const fn (
        *anyopaque,
        family_index: u32,
        queue_index: u32,
        ret_addr: usize,
    ) Error!void,
};

/// Parameters of an image acquire.
pub const Acquire = struct {
    swapchain: Resource,
    semaphore: ?Resource = null,
    fence: ?Resource = null,
    timeout_ns: u64 = std.math.maxInt(u64),
};

/// One queue submission.
pub const Submission = struct {
    command_buffers: []const Resource = &.{},
    wait_semaphores: []const Resource = &.{},
    signal_semaphores: []const Resource = &.{},
    fence: ?Resource = null,
};

/// Parameters of a presentation.
pub const Present = struct {
    swapchain: Resource,
    image_index: u32,
    wait_semaphores: []const Resource = &.{},
};

/// The result of a successful acquire.
pub const Acquired = struct {
    image_index: u32,
    suboptimal: bool = false,
};

/// Acquires an image with an explicit return address.
///
/// # Args
/// - `description`: the swapchain and optional synchronization.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Return
/// The acquired image index.
///
/// # Error
/// - `Error.SurfaceOutOfDate`: the swapchain must be recreated.
/// - `Error.SurfaceLost`: the surface was lost.
/// - `Error.Timeout`: no image became available in time.
/// - `Error.InvalidResource`: a referenced resource is stale.
pub inline fn rawAcquire(
    self: Queue,
    description: Acquire,
    ret_addr: usize,
) Error!Acquired {
    return try self.vtable.acquire(
        self.vptr,
        self.family_index,
        self.queue_index,
        description,
        ret_addr,
    );
}

/// Calls `rawAcquire` with `@returnAddress()`.
///
/// # Args
/// - `description`: the swapchain and optional synchronization.
///
/// # Return
/// The acquired image index.
///
/// # Error
/// - See `rawAcquire`.
pub inline fn acquire(
    self: Queue,
    description: Acquire,
) Error!Acquired {
    return try self.rawAcquire(description, @returnAddress());
}

/// Submits work with an explicit return address.
///
/// # Args
/// - `submission`: command buffers and synchronization.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.DeviceLost`: the device was lost.
/// - `Error.InvalidResource`: a referenced resource is stale.
/// - `Error.OutOfHostMemory`: the submission cannot be recorded.
pub inline fn rawSubmit(
    self: Queue,
    submission: Submission,
    ret_addr: usize,
) Error!void {
    return try self.vtable.submit(
        self.vptr,
        self.family_index,
        self.queue_index,
        submission,
        ret_addr,
    );
}

/// Calls `rawSubmit` with `@returnAddress()`.
///
/// # Args
/// - `submission`: command buffers and synchronization.
///
/// # Error
/// - See `rawSubmit`.
pub inline fn submit(
    self: Queue,
    submission: Submission,
) Error!void {
    return try self.rawSubmit(submission, @returnAddress());
}

/// Presents an image with an explicit return address.
///
/// # Args
/// - `description`: the swapchain, image index, and wait
///   semaphores.
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.SurfaceOutOfDate`: the swapchain must be recreated.
/// - `Error.SurfaceLost`: the surface was lost.
/// - `Error.InvalidResource`: a referenced resource is stale.
pub inline fn rawPresent(
    self: Queue,
    description: Present,
    ret_addr: usize,
) Error!void {
    return try self.vtable.present(
        self.vptr,
        self.family_index,
        self.queue_index,
        description,
        ret_addr,
    );
}

/// Calls `rawPresent` with `@returnAddress()`.
///
/// # Args
/// - `description`: the swapchain and image to present.
///
/// # Error
/// - See `rawPresent`.
pub inline fn present(
    self: Queue,
    description: Present,
) Error!void {
    return try self.rawPresent(description, @returnAddress());
}

/// Waits for the queue to become idle.
///
/// # Args
/// - `ret_addr`: return address used for leak tracking.
///
/// # Error
/// - `Error.DeviceLost`: the device was lost while waiting.
pub inline fn rawWaitIdle(
    self: Queue,
    ret_addr: usize,
) Error!void {
    return try self.vtable.wait_idle(
        self.vptr,
        self.family_index,
        self.queue_index,
        ret_addr,
    );
}

/// Calls `rawWaitIdle` with `@returnAddress()`.
///
/// # Error
/// - See `rawWaitIdle`.
pub inline fn waitIdle(self: Queue) Error!void {
    return try self.rawWaitIdle(@returnAddress());
}
