const std = @import("std");
const Device = @import("../Device.zig");
const rhi = @import("../Resource.zig");
const Error = rhi.Error;
const Resource = rhi.Resource;

/// A buffer resource.
pub const Buffer = struct {
    pub const Description = rhi.BufferDescription;
    pub const Properties = rhi.BufferProperties;

    device: Device,
    resource: Resource,
    size: u64,
    memory: rhi.Memory,

    /// Creates a buffer with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: size, usage, memory hints, and initial data.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A buffer owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfDeviceMemory`: allocation fails.
    /// - `Error.OutOfHostMemory`: staging or host mapping fails.
    /// - `Error.InvalidDescription`: `initial_data` is larger than
    ///   `size`.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Buffer {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .buffer = description },
                ret_addr,
            ),
            .size = description.size,
            .memory = description.memory,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: buffer description.
    ///
    /// # Return
    /// A buffer owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Buffer {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the buffer with an explicit return address.
    ///
    /// # Args
    /// - `self`: the buffer to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: Buffer, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the buffer to destroy.
    pub fn destroy(self: Buffer) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Maps a range of the buffer.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: byte offset into the buffer.
    /// - `size`: number of bytes to map.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A writable slice valid until `unmap`.
    ///
    /// # Error
    /// - `Error.Unsupported`: the buffer is not host visible.
    /// - `Error.InvalidDescription`: the range is out of bounds.
    /// - `Error.OutOfHostMemory`: mapping fails.
    pub fn mapWithAddr(
        self: Buffer,
        offset: u64,
        size: u64,
        ret_addr: usize,
    ) Error![]u8 {
        return try self.device.rawMap(
            self.resource,
            offset,
            size,
            ret_addr,
        );
    }

    /// Calls `mapWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: byte offset into the buffer.
    /// - `size`: number of bytes to map.
    ///
    /// # Return
    /// A writable slice valid until `unmap`.
    ///
    /// # Error
    /// - See `mapWithAddr`.
    pub fn map(
        self: Buffer,
        offset: u64,
        size: u64,
    ) Error![]u8 {
        return try self.mapWithAddr(offset, size, @returnAddress());
    }

    /// Unmaps the buffer.
    ///
    /// # Args
    /// - `self`: the mapped buffer.
    /// - `dirty`: written ranges, or an empty slice for the whole
    ///   mapped range.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn unmapWithAddr(
        self: Buffer,
        dirty: []const Device.Dirty,
        ret_addr: usize,
    ) void {
        self.device.rawUnmap(self.resource, dirty, ret_addr);
    }

    /// Calls `unmapWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the mapped buffer.
    /// - `dirty`: written ranges.
    pub fn unmap(
        self: Buffer,
        dirty: []const Device.Dirty,
    ) void {
        self.unmapWithAddr(dirty, @returnAddress());
    }

    /// Uploads bytes into the buffer.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: destination byte offset.
    /// - `data`: bytes to copy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - See `mapWithAddr`.
    pub fn writeWithAddr(
        self: Buffer,
        offset: u64,
        data: []const u8,
        ret_addr: usize,
    ) Error!void {
        const mapped = try self.mapWithAddr(
            offset,
            data.len,
            ret_addr,
        );
        @memcpy(mapped, data);
        self.unmapWithAddr(&.{
            .{ .offset = offset, .size = data.len },
        }, ret_addr);
    }

    /// Calls `writeWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: destination byte offset.
    /// - `data`: bytes to copy.
    ///
    /// # Error
    /// - See `writeWithAddr`.
    pub fn write(
        self: Buffer,
        offset: u64,
        data: []const u8,
    ) Error!void {
        return writeWithAddr(self, offset, data, @returnAddress());
    }

    /// Reads bytes from the buffer.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: source byte offset.
    /// - `out`: destination memory.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Error
    /// - See `mapWithAddr`.
    pub fn readWithAddr(
        self: Buffer,
        offset: u64,
        out: []u8,
        ret_addr: usize,
    ) Error!void {
        const mapped = try self.mapWithAddr(
            offset,
            out.len,
            ret_addr,
        );
        @memcpy(out, mapped);
        self.unmapWithAddr(&.{}, ret_addr);
    }

    /// Calls `readWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: a host visible buffer.
    /// - `offset`: source byte offset.
    /// - `out`: destination memory.
    ///
    /// # Error
    /// - See `readWithAddr`.
    pub fn read(
        self: Buffer,
        offset: u64,
        out: []u8,
    ) Error!void {
        return readWithAddr(self, offset, out, @returnAddress());
    }

    /// Queries the buffer properties.
    ///
    /// # Args
    /// - `self`: the buffer to query.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// Size and memory hints of the buffer.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the buffer is stale.
    /// - `Error.Unsupported`: the backend cannot query buffers.
    pub fn getPropertiesWithAddr(
        self: Buffer,
        ret_addr: usize,
    ) Error!Properties {
        var bytes: [@sizeOf(Properties)]u8 = undefined;
        const result = try self.device.rawQuery(
            .buffer,
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
    /// - `self`: the buffer to query.
    ///
    /// # Return
    /// The buffer properties.
    ///
    /// # Error
    /// - See `getPropertiesWithAddr`.
    pub fn getProperties(self: Buffer) Error!Properties {
        return try self.getPropertiesWithAddr(@returnAddress());
    }
};

/// A texture resource.
pub const Texture = struct {
    pub const Description = rhi.TextureDescription;
    pub const Properties = rhi.TextureProperties;

    device: Device,
    resource: Resource,
    properties: Properties,

    /// Creates a texture with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: extent, format, usage, and initial data.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A texture owned by the caller.
    ///
    /// # Error
    /// - `Error.Unsupported`: the format, sample count, or texture
    ///   type is not supported.
    /// - `Error.OutOfDeviceMemory`: allocation fails.
    /// - `Error.OutOfHostMemory`: staging fails.
    /// - `Error.InvalidDescription`: the extent or initial data is
    ///   inconsistent.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Texture {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .texture = description },
                ret_addr,
            ),
            .properties = .{
                .type = description.type,
                .format = description.format,
                .width = description.width,
                .height = description.height,
                .depth = description.depth,
                .mip_levels = description.mip_levels,
                .array_layers = description.array_layers,
                .samples = description.samples,
                .usage = description.usage,
            },
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: texture description.
    ///
    /// # Return
    /// A texture owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Texture {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the texture with an explicit return address.
    ///
    /// # Args
    /// - `self`: the texture to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Note
    /// Every view of this texture must be destroyed first.
    pub fn destroyWithAddr(self: Texture, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the texture to destroy.
    pub fn destroy(self: Texture) void {
        self.destroyWithAddr(@returnAddress());
    }

    /// Parameters of a texture view created from a texture.
    pub const ViewDescription = struct {
        format: ?rhi.Format = null,
        type: ?rhi.TextureType = null,
        aspect: ?rhi.TextureAspect = null,
        base_mip: u32 = 0,
        mip_count: u32 = 0,
        base_layer: u32 = 0,
        layer_count: u32 = 0,
    };

    /// Creates a view of the texture.
    ///
    /// # Args
    /// - `self`: the texture to view.
    /// - `description`: format, aspect, and subresource range.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A texture view owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidDescription`: the subresource range is out of
    ///   bounds.
    /// - `Error.Unsupported`: the view format or type is not
    ///   supported.
    pub fn createViewWithAddr(
        self: Texture,
        description: ViewDescription,
        ret_addr: usize,
    ) Error!TextureView {
        return TextureView.createWithAddr(
            self.device,
            .{
                .texture = self.resource,
                .format = description.format,
                .type = description.type,
                .aspect = description.aspect,
                .base_mip = description.base_mip,
                .mip_count = description.mip_count,
                .base_layer = description.base_layer,
                .layer_count = description.layer_count,
            },
            ret_addr,
        );
    }

    /// Calls `createViewWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the texture to view.
    /// - `description`: view parameters.
    ///
    /// # Return
    /// A texture view owned by the caller.
    ///
    /// # Error
    /// - See `createViewWithAddr`.
    pub fn createView(
        self: Texture,
        description: ViewDescription,
    ) Error!TextureView {
        return self.createViewWithAddr(description, @returnAddress());
    }

    /// Queries the texture properties.
    ///
    /// # Args
    /// - `self`: the texture to query.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// Extent, format, and usage of the texture.
    ///
    /// # Error
    /// - `Error.InvalidResource`: the texture is stale.
    /// - `Error.Unsupported`: the backend cannot query textures.
    pub fn getPropertiesWithAddr(
        self: Texture,
        ret_addr: usize,
    ) Error!Properties {
        var bytes: [@sizeOf(Properties)]u8 = undefined;
        const result = try self.device.rawQuery(
            .texture,
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
    /// - `self`: the texture to query.
    ///
    /// # Return
    /// The texture properties.
    ///
    /// # Error
    /// - See `getPropertiesWithAddr`.
    pub fn getProperties(self: Texture) Error!Properties {
        return try self.getPropertiesWithAddr(@returnAddress());
    }
};

/// A view over a texture subresource.
pub const TextureView = struct {
    pub const Description = rhi.TextureViewDescription;

    device: Device,
    resource: Resource,
    texture: Resource,

    /// Creates a texture view with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: source texture and view range.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A view owned by the caller.
    ///
    /// # Error
    /// - `Error.InvalidResource`: `description.texture` is stale.
    /// - `Error.OutOfDeviceMemory`: creating the view fails.
    /// - `Error.InvalidDescription`: the view range is out of bounds.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!TextureView {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .texture_view = description },
                ret_addr,
            ),
            .texture = description.texture,
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: view description.
    ///
    /// # Return
    /// A view owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!TextureView {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the view with an explicit return address.
    ///
    /// # Args
    /// - `self`: the view to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: TextureView, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the view to destroy.
    pub fn destroy(self: TextureView) void {
        self.destroyWithAddr(@returnAddress());
    }
};

/// A sampler resource.
pub const Sampler = struct {
    pub const Description = rhi.SamplerDescription;

    device: Device,
    resource: Resource,

    /// Creates a sampler with an explicit return address.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: filtering and addressing state.
    /// - `ret_addr`: return address used for leak tracking.
    ///
    /// # Return
    /// A sampler owned by the caller.
    ///
    /// # Error
    /// - `Error.OutOfDeviceMemory`: creating the sampler fails.
    /// - `Error.Unsupported`: the requested state is not supported.
    pub fn createWithAddr(
        device: Device,
        description: Description,
        ret_addr: usize,
    ) Error!Sampler {
        return .{
            .device = device,
            .resource = try device.rawCreate(
                .{ .sampler = description },
                ret_addr,
            ),
        };
    }

    /// Calls `createWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `device`: owning device.
    /// - `description`: sampler description.
    ///
    /// # Return
    /// A sampler owned by the caller.
    ///
    /// # Error
    /// - See `createWithAddr`.
    pub fn create(
        device: Device,
        description: Description,
    ) Error!Sampler {
        return createWithAddr(device, description, @returnAddress());
    }

    /// Destroys the sampler with an explicit return address.
    ///
    /// # Args
    /// - `self`: the sampler to destroy.
    /// - `ret_addr`: return address used for leak tracking.
    pub fn destroyWithAddr(self: Sampler, ret_addr: usize) void {
        self.device.rawDestroy(self.resource, ret_addr);
    }

    /// Calls `destroyWithAddr` with `@returnAddress()`.
    ///
    /// # Args
    /// - `self`: the sampler to destroy.
    pub fn destroy(self: Sampler) void {
        self.destroyWithAddr(@returnAddress());
    }
};
