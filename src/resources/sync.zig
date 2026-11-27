const Device = @import("../Device.zig");
const rhi = @import("../Resource.zig");
const Error = rhi.Error;
const Resource = rhi.Resource;

/// A fence resource used for host/device synchronization.
pub const Fence = struct {
    /// The descriptor used to create a fence.
    pub const Description = rhi.FenceDescription;

    device: Device,
    resource: Resource,

    /// Creates a fence with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: initial signaled state.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A fence owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfHostMemory`: creating the fence fails.
    /// - `Error.OutOfDeviceMemory`: creating the fence fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Fence {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .fence = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: initial signaled state.
    ///
    /// # Return
    /// A fence owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Fence {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the fence with an explicit return address.
    ///
    /// # Args
    /// - `self`: the fence to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: Fence, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the fence to destroy.
    pub fn destroy(self: Fence) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Waits for the fence with an explicit return address.
    ///
    /// # Args
    /// - `self`: the fence to wait for.
    /// - `timeout_ns`: timeout in nanoseconds.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.Timeout`: the fence was not signaled in time.
    /// - `Error.DeviceLost`: the device was lost.
    pub fn waitWithAddr(
        self: Fence,
        timeout_ns: u64,
        ret_addr: usize,
    ) Error!void {
        try self.device.waitFenceWithAddr(
            self.resource,
            timeout_ns,
            ret_addr,
        );
    }

    /// Calls `waitWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the fence to wait for.
    /// - `timeout_ns`: timeout in nanoseconds.
    ///
    /// # Error
    /// - See `waitWithAddr`.
    pub fn wait(self: Fence, timeout_ns: u64) Error!void {
        try self.waitWithAddr(timeout_ns, @returnAddress());
    }

    /// Resets the fence with an explicit return address.
    ///
    /// # Args
    /// - `self`: the fence to reset.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the fence is in use.
    /// - `Error.DeviceLost`: the device was lost.
    pub fn resetWithAddr(
        self: Fence,
        ret_addr: usize,
    ) Error!void {
        try self.device.resetFenceWithAddr(self.resource, ret_addr);
    }

    /// Calls `resetWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the fence to reset.
    ///
    /// # Error
    /// - See `resetWithAddr`.
    pub fn reset(self: Fence) Error!void {
        try self.resetWithAddr(@returnAddress());
    }
};

/// A semaphore resource used for queue synchronization.
pub const Semaphore = struct {
    /// The descriptor used to create a semaphore.
    pub const Description = rhi.SemaphoreDescription;

    device: Device,
    resource: Resource,

    /// Creates a semaphore with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: semaphore description.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A semaphore owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfHostMemory`: creating the semaphore fails.
    /// - `Error.OutOfDeviceMemory`: creating the semaphore fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Semaphore {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .semaphore = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: semaphore description.
    ///
    /// # Return
    /// A semaphore owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Semaphore {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the semaphore with an explicit return address.
    ///
    /// # Args
    /// - `self`: the semaphore to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: Semaphore, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the semaphore to destroy.
    pub fn destroy(self: Semaphore) void {
        self.destroyWithAddr(@returnAddress());
    }
};
