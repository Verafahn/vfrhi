const std = @import("std");
const Allocator = std.mem.Allocator;
const Device = @import("../Device.zig");
const rhi = @import("../Resource.zig");
const Error = rhi.Error;
const Queue = @import("../Queue.zig").Queue;
const Sync = @import("Sync.zig");
const Resource = rhi.Resource;
const log = std.log.scoped(.vfrhi);

/// An RHI surface backed by a native window or a headless target.
pub const Surface = struct {
    pub const Description = rhi.SurfaceDescription;
    pub const Properties = rhi.SurfaceProperties;

    device: Device,
    resource: Resource,

    /// Creates a surface with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: the native window handle.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A surface owned by the caller.
    ///
    /// # Error
    /// - `Error.Unsupported`: the backend cannot create this surface
    ///   kind or the required instance extension is not enabled.
    /// - `Error.OutOfHostMemory`: creating the surface fails.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Surface {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .surface = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: the native window handle.
    ///
    /// # Return
    /// A surface owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Surface {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the surface with an explicit return address.
    ///
    /// # Args
    /// - `self`: the surface to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Every swapchain created from this surface must be destroyed
    /// first.
    pub fn destroyWithAddr(self: Surface, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the surface to destroy.
    pub fn destroy(self: Surface) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Queries the properties of the surface.
    ///
    /// # Args
    /// - `self`: the surface to query.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// Extent limits and format count of the surface.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the surface is stale.
    /// - `Error.Unsupported`: the backend cannot query surfaces.
    pub fn getPropertiesWithAddr(
        self: Surface,
        ret_addr: usize,
    ) Error!Properties {
        var bytes: [@sizeOf(Properties)]u8 = undefined;
        const result = try self.device.rawQuery(
            .surface,
            0,
            self.resource,
            .{ .slice = &bytes },
            ret_addr,
        );
        return switch (result.support) {
            .support => std.mem.bytesToValue(Properties, &bytes),
            .unsupport, .unknown => error.Unsupported,
        };
    }

    /// Calls `getPropertiesWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the surface to query.
    ///
    /// # Return
    /// The surface properties.
    ///
    /// # Error
    /// - See `getPropertiesWithAddr`.
    pub fn getProperties(self: Surface) Error!Properties {
        return try self.getPropertiesWithAddr(@returnAddress());
    }
};

/// A presentable chain of textures owned by a surface.
pub const Swapchain = struct {
    pub const Description = rhi.SwapchainDescription;
    pub const Properties = rhi.SwapchainProperties;

    device: Device,
    resource: Resource,
    surface: Resource,
    properties: Properties,

    /// Creates a swapchain with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: surface, extent, format, and present mode.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A swapchain owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: `description.surface` is stale or
    ///   not a surface.
    /// - `Error.Unsupported`: the requested format or present mode is
    ///   not supported by the surface.
    /// - `Error.OutOfDeviceMemory`: creating the swapchain fails.
    ///
    /// # Note
    /// The resolved extent can differ from the requested extent
    /// because of surface limits. Read `properties` for the actual
    /// values.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Swapchain {
        const resource = try device.rawCreate(
            .{ .swapchain = description },
            ret_addr,
        );
        errdefer device.rawDestroy(resource, ret_addr);

        var properties: Properties = .{
            .width = description.width,
            .height = description.height,
            .format = description.format,
            .image_count = description.image_count,
        };
        var bytes: [@sizeOf(Properties)]u8 = undefined;
        if (device.rawQuery(
            .swapchain,
            0,
            resource,
            .{ .slice = &bytes },
            ret_addr,
        )) |result| {
            if (result.support == .support) {
                properties = std.mem.bytesToValue(Properties, &bytes);
            }
        } else |err| {
            log.warn("Cannot query swapchain properties: {}", .{err});
        }

        return .{
            .device = device,
            .resource = resource,
            .surface = description.surface,
            .properties = properties,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: surface, extent, format, and present mode.
    ///
    /// # Return
    /// A swapchain owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Swapchain {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the swapchain with an explicit return address.
    ///
    /// # Args
    /// - `self`: the swapchain to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Texture handles returned by `images` and `views` become invalid.
    pub fn destroyWithAddr(self: Swapchain, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the swapchain to destroy.
    pub fn destroy(self: Swapchain) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Returns the textures of the swapchain.
    ///
    /// # Args
    /// - `self`: the swapchain to query.
    /// - `allocator`: allocator for the returned array.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// An array of texture handles owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfHostMemory`: allocating the array fails.
    /// - `Error.Unsupported`: the backend cannot list images.
    pub fn imagesWithAddr(
        self: Swapchain,
        allocator: Allocator,
        ret_addr: usize,
    ) Error![]Resource {
        const image_list = allocator.alloc(
            Resource,
            self.properties.image_count,
        ) catch return error.OutOfHostMemory;
        errdefer allocator.free(image_list);
        const result = try self.device.rawQuery(
            .swapchain_images,
            0,
            self.resource,
            .{ .slice = std.mem.sliceAsBytes(image_list) },
            ret_addr,
        );
        if (result.support != .support) return error.Unsupported;
        return image_list;
    }

    /// Calls `imagesWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the swapchain to query.
    /// - `allocator`: allocator for the returned array.
    ///
    /// # Return
    /// An array of texture handles owned by the caller.
    ///
    /// # Error
    /// - See `imagesWithAddr`.
    pub fn images(
        self: Swapchain,
        allocator: Allocator,
    ) Error![]Resource {
        return imagesWithAddr(self, allocator, @returnAddress());
    }

    /// Returns the texture views of the swapchain.
    ///
    /// # Args
    /// - `self`: the swapchain to query.
    /// - `allocator`: allocator for the returned array.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// An array of view handles owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfHostMemory`: allocating the array fails.
    /// - `Error.Unsupported`: the backend cannot list views.
    pub fn viewsWithAddr(
        self: Swapchain,
        allocator: Allocator,
        ret_addr: usize,
    ) Error![]Resource {
        const view_list = allocator.alloc(
            Resource,
            self.properties.image_count,
        ) catch return error.OutOfHostMemory;
        errdefer allocator.free(view_list);
        const result = try self.device.rawQuery(
            .swapchain_views,
            0,
            self.resource,
            .{ .slice = std.mem.sliceAsBytes(view_list) },
            ret_addr,
        );
        if (result.support != .support) return error.Unsupported;
        return view_list;
    }

    /// Calls `viewsWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the swapchain to query.
    /// - `allocator`: allocator for the returned array.
    ///
    /// # Return
    /// An array of view handles owned by the caller.
    ///
    /// # Error
    /// - See `viewsWithAddr`.
    pub fn views(
        self: Swapchain,
        allocator: Allocator,
    ) Error![]Resource {
        return viewsWithAddr(self, allocator, @returnAddress());
    }

    /// Acquires the next swapchain image.
    ///
    /// # Args
    /// - `self`: the swapchain to acquire from.
    /// - `queue`: a queue that supports presentation.
    /// - `semaphore`: semaphore signaled when the image is available.
    /// - `fence`: fence signaled when the image is available.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// The acquired image index.
    ///
    /// # Error
    /// - `Error.SurfaceOutOfDate`: the swapchain must be recreated.
    /// - `Error.Timeout`: no image became available in time.
    /// - `Error.InvalidDescription`: neither a semaphore nor a fence
    ///   was supplied on a backend that requires one.
    pub fn acquireWithAddr(
        self: Swapchain,
        queue: Queue,
        semaphore: ?Sync.Semaphore,
        fence: ?Sync.Fence,
        ret_addr: usize,
    ) Error!Queue.Acquired {
        return try queue.rawAcquire(.{
            .swapchain = self.resource,
            .semaphore = if (semaphore) |value| value.resource else null,
            .fence = if (fence) |value| value.resource else null,
        }, ret_addr);
    }

    /// Calls `acquireWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the swapchain to acquire from.
    /// - `queue`: a queue that supports presentation.
    /// - `semaphore`: optional acquire semaphore.
    /// - `fence`: optional acquire fence.
    ///
    /// # Return
    /// The acquired image index.
    ///
    /// # Error
    /// - See `acquireWithAddr`.
    pub fn acquire(
        self: Swapchain,
        queue: Queue,
        semaphore: ?Sync.Semaphore,
        fence: ?Sync.Fence,
    ) Error!Queue.Acquired {
        return acquireWithAddr(
            self,
            queue,
            semaphore,
            fence,
            @returnAddress(),
        );
    }

    /// Parameters of a swapchain presentation.
    pub const Present = struct {
        queue: Queue,
        image_index: u32,
        wait_semaphores: []const Resource = &.{},
    };

    /// Presents an image with an explicit return address.
    ///
    /// # Args
    /// - `self`: the swapchain to present from.
    /// - `description`: queue, image index, and wait semaphores.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - `Error.SurfaceOutOfDate`: the swapchain must be recreated.
    /// - `Error.SurfaceLost`: the surface was lost.
    /// - `Error.InvalidResource`: a semaphore is stale.
    pub fn presentWithAddr(
        self: Swapchain,
        description: Present,
        ret_addr: usize,
    ) Error!void {
        try description.queue.rawPresent(.{
            .swapchain = self.resource,
            .image_index = description.image_index,
            .wait_semaphores = description.wait_semaphores,
        }, ret_addr);
    }

    /// Calls `presentWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the swapchain to present from.
    /// - `description`: queue, image index, and wait semaphores.
    ///
    /// # Error
    /// - See `presentWithAddr`.
    pub fn present(
        self: Swapchain,
        description: Present,
    ) Error!void {
        return presentWithAddr(self, description, @returnAddress());
    }
};
