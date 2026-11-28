//! A Direct3D 11 backend for vfrhi.
//!
//! The backend owns a D3D11 device, its immediate context, and every
//! RHI resource created through it. SPIR-V shaders are decompiled to
//! HLSL and compiled with the system D3DCompiler at runtime.
//!
//! The caller owns the window. Surfaces are described by a Win32
//! `HWND`; headless surfaces use offscreen swapchain textures and
//! presentation is a no-op.

const std = @import("std");
const builtin = @import("builtin");
const win = @import("../dx3d/windows.zig");
const spirv = @import("../dx3d/spirv.zig");
const rhi = @import("rhi");
const types = rhi.types;
const commands = @import("../../Command.zig");
const Resource = rhi.Resource;
const Device = rhi.Device;
const Queue = rhi.Queue;
const Error = rhi.Error;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dx3d11);
const Dx3d11 = @This();

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("The Direct3D 11 backend is only available on Windows.");
    }
}

/// The API version type used by this backend.
pub const Version = rhi.Version;

/// Creation parameters of a Direct3D 11 backend.
pub const Desc = struct {};

const BufferState = struct {
    resource: *win.ID3D11Buffer,
    staging: ?*win.ID3D11Buffer,
    size: u64,
    hints: types.Memory,
    usage: types.BufferUsage,
    host_visible: bool,
    mapped: bool = false,
};

const TextureState = struct {
    resource: *win.ID3D11Resource,
    properties: types.TextureProperties,
};

const TextureViewState = struct {
    srv: ?*win.ID3D11ShaderResourceView = null,
    rtv: ?*win.ID3D11RenderTargetView = null,
    dsv: ?*win.ID3D11DepthStencilView = null,
    uav: ?*win.ID3D11UnorderedAccessView = null,
    aspect: types.TextureAspect,
    format: types.Format,
};

const SurfaceState = struct {
    hwnd: ?win.HWND,
    width: u32,
    height: u32,
};

const SwapchainState = struct {
    handle: ?*win.IDXGISwapChain1,
    surface: Resource,
    properties: types.SwapchainProperties,
    images: []Resource,
    views: []Resource,
    headless: bool,
    bitblt: bool = false,
    next_index: u32 = 0,
    present_mode: types.PresentMode,
};

const ShaderState = struct {
    stage: types.ShaderStage,
    blob: *win.ID3DBlob,
    vertex: ?*win.ID3D11VertexShader = null,
    pixel: ?*win.ID3D11PixelShader = null,
    compute: ?*win.ID3D11ComputeShader = null,

    fn bytecode(self: ShaderState) struct {
        ptr: [*]const u8,
        len: usize,
    } {
        const ptr = self.blob.getBufferPointer() orelse
            @as(?*anyopaque, null);
        return .{
            .ptr = @ptrCast(ptr),
            .len = self.blob.getBufferSize(),
        };
    }
};

const DescriptorSetLayoutState = struct {
    bindings: []types.DescriptorSetLayoutDescription.DescriptorBinding,
};

const PipelineLayoutState = struct {
    descriptor_sets: []Resource,
    push_constants: []types.PipelineLayoutDescription.PushConstant,
    push_buffer: ?*win.ID3D11Buffer = null,
    push_shadow: []u8 = &.{},
};

const BoundValue = struct {
    binding: u32,
    array_index: u32,
    kind: Kind,

    const Kind = union(enum) {
        buffer: struct {
            resource: *win.ID3D11Buffer,
            offset: u64,
            size: u64,
        },
        texture: struct {
            srv: ?*win.ID3D11ShaderResourceView,
            sampler: ?*win.ID3D11SamplerState,
        },
        sampler: *win.ID3D11SamplerState,
    };
};

const DescriptorSetState = struct {
    layout: Resource,
    values: []?BoundValue,
};

const PipelineState = struct {
    bind_point: types.BindPoint,
    layout: Resource,
    vertex: ?*win.ID3D11VertexShader = null,
    pixel: ?*win.ID3D11PixelShader = null,
    compute: ?*win.ID3D11ComputeShader = null,
    input_layout: ?*win.ID3D11InputLayout = null,
    blend: ?*win.ID3D11BlendState = null,
    depth_stencil: ?*win.ID3D11DepthStencilState = null,
    rasterizer: ?*win.ID3D11RasterizerState = null,
    topology: u32 = win.D3D_PRIMITIVE_TOPOLOGY_UNDEFINED,
    strides: []u32 = &.{},
};

const CommandBufferState = struct {
    level: types.CommandBufferDescription.Level,
    state: State = .initial,
    in_rendering: bool = false,
    pipeline: ?*PipelineState = null,

    const State = enum {
        initial,
        recording,
        ended,
        submitted,
    };
};

const FenceState = struct {
    signaled: bool,
};

const SemaphoreState = struct {};

const Handle = union(Resource.Tag) {
    surface: SurfaceState,
    swapchain: SwapchainState,
    buffer: BufferState,
    texture: TextureState,
    texture_view: TextureViewState,
    sampler: *win.ID3D11SamplerState,
    shader: ShaderState,
    descriptor_set_layout: DescriptorSetLayoutState,
    pipeline_layout: PipelineLayoutState,
    descriptor_set: DescriptorSetState,
    pipeline: PipelineState,
    command_buffer: CommandBufferState,
    fence: FenceState,
    semaphore: SemaphoreState,
};

const Slot = struct {
    generation: u32,
    tag: Resource.Tag,
    handle: Handle,
};

allocator: Allocator,
device: *win.ID3D11Device,
context: *win.ID3D11DeviceContext,
factory: *win.IDXGIFactory2,
feature_level: u32,

slots: std.ArrayListUnmanaged(?Slot) = .empty,
generations: std.ArrayListUnmanaged(u32) = .empty,
free_slots: std.ArrayListUnmanaged(u32) = .empty,
live_count: usize = 0,

/// Creates a Direct3D 11 device.
///
/// # Args
/// - `allocator`: allocator for backend bookkeeping.
/// - `description`: reserved for future parameters.
///
/// # Return
/// An initialized backend owned by the caller.
///
/// # Error
/// - `error.OutOfHostMemory`: an allocation fails.
/// - `error.InitializationFailed`: no Direct3D 11 device or DXGI
///   factory can be created.
///
/// # Note
/// Destroy every RHI resource before calling `deinit`.
pub fn init(allocator: Allocator, description: Desc) !*Dx3d11 {
    _ = description;
    log.debug("Creating Direct3D 11 backend", .{});
    errdefer log.warn("Direct3D 11 backend creation failed", .{});

    var device: ?*win.ID3D11Device = null;
    var context: ?*win.ID3D11DeviceContext = null;
    var feature_level: u32 = 0;
    const levels = [_]u32{
        win.D3D_FEATURE_LEVEL_11_1,
        win.D3D_FEATURE_LEVEL_11_0,
    };
    const hr = win.D3D11CreateDevice(
        null,
        win.D3D_DRIVER_TYPE_HARDWARE,
        null,
        win.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        &levels,
        levels.len,
        win.D3D11_SDK_VERSION,
        &device,
        &feature_level,
        &context,
    );
    if (win.failed(hr) or device == null or context == null) {
        log.warn("D3D11CreateDevice failed: 0x{x}", .{
            @as(u32, @bitCast(hr)),
        });
        return error.InitializationFailed;
    }
    errdefer {
        if (context) |value| _ = value.release();
    }
    errdefer {
        if (device) |value| _ = value.release();
    }

    var factory_raw: ?*anyopaque = null;
    const factory_hr = win.CreateDXGIFactory2(
        0,
        &win.IID_IDXGIFactory2,
        &factory_raw,
    );
    if (win.failed(factory_hr) or factory_raw == null) {
        log.warn("CreateDXGIFactory2 failed: 0x{x}", .{
            @as(u32, @bitCast(factory_hr)),
        });
        return error.InitializationFailed;
    }
    const factory: *win.IDXGIFactory2 = @ptrCast(@alignCast(
        factory_raw.?,
    ));
    errdefer _ = factory.release();

    const self = try allocator.create(Dx3d11);
    self.* = .{
        .allocator = allocator,
        .device = device.?,
        .context = context.?,
        .factory = factory,
        .feature_level = feature_level,
    };

    log.info("device_name: Direct3D 11 device", .{});
    log.info("feature_level: 0x{x}", .{feature_level});
    log.debug("Direct3D 11 backend has been created", .{});
    return self;
}

/// Destroys the backend.
///
/// # Note
/// Every RHI resource must be destroyed before this call. Live
/// resources are reported as errors.
pub fn deinit(self: *Dx3d11) void {
    log.debug("Destroying Direct3D 11 backend", .{});
    if (self.live_count != 0) {
        log.err(
            "Direct3D 11 backend destroyed with {d} live resource(s)",
            .{self.live_count},
        );
        for (self.slots.items) |slot| {
            if (slot) |value| self.releaseHostData(&value);
        }
    }
    _ = self.context.flush();
    _ = self.context.release();
    _ = self.device.release();
    _ = self.factory.release();
    self.slots.deinit(self.allocator);
    self.generations.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.allocator.destroy(self);
    log.debug("Direct3D 11 backend has been destroyed", .{});
}

/// Returns the RHI device interface of this backend.
///
/// # Return
/// A device whose lifetime is tied to `self`.
pub fn asDevice(self: *Dx3d11) Device {
    return .{
        .vptr = self,
        .vtable = &device_vtable,
    };
}

fn lookup(
    self: *Dx3d11,
    resource: Resource,
    tag: Resource.Tag,
) Error!*Slot {
    const index = resource.identifier.index;
    if (index >= self.slots.items.len) {
        log.warn("unknown resource index {d}", .{index});
        return error.InvalidResource;
    }
    const slot = if (self.slots.items[index]) |*value|
        value
    else {
        log.warn("destroyed resource index {d}", .{index});
        return error.InvalidResource;
    };
    if (slot.generation != resource.identifier.generation) {
        log.warn("stale resource index {d}", .{index});
        return error.InvalidResource;
    }
    if (slot.tag != tag) {
        log.warn(
            "expected {s}, got {s}",
            .{ @tagName(tag), @tagName(slot.tag) },
        );
        return error.InvalidResource;
    }
    return slot;
}

fn newSlot(
    self: *Dx3d11,
    tag: Resource.Tag,
    handle: Handle,
) Error!Resource {
    var index: u32 = undefined;
    if (self.free_slots.pop()) |free_index| {
        index = free_index;
    } else {
        index = @intCast(self.slots.items.len);
        self.slots.append(
            self.allocator,
            null,
        ) catch return error.OutOfHostMemory;
        self.generations.append(
            self.allocator,
            0,
        ) catch {
            _ = self.slots.pop();
            return error.OutOfHostMemory;
        };
    }

    const next_generation = self.generations.items[index] +% 1;
    const generation = if (next_generation == 0) 1 else next_generation;
    self.generations.items[index] = generation;
    self.slots.items[index] = .{
        .generation = generation,
        .tag = tag,
        .handle = handle,
    };
    self.live_count += 1;

    return .{
        .identifier = .{
            .generation = generation,
            .index = index,
        },
        .tag = tag,
    };
}

fn releaseSlot(self: *Dx3d11, resource: Resource) void {
    const index = resource.identifier.index;
    if (index >= self.slots.items.len) return;
    if (self.slots.items[index] == null) return;
    self.slots.items[index] = null;
    self.live_count -= 1;
    self.free_slots.append(
        self.allocator,
        index,
    ) catch |err| log.warn(
        "cannot recycle resource slot {d}: {}",
        .{ index, err },
    );
}

fn releaseHostData(self: *Dx3d11, slot: *const Slot) void {
    switch (slot.handle) {
        .swapchain => |value| {
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            self.allocator.free(value.descriptor_sets);
            self.allocator.free(value.push_constants);
            self.allocator.free(value.push_shadow);
        },
        .descriptor_set => |value| {
            self.allocator.free(value.values);
        },
        .pipeline => |value| {
            self.allocator.free(value.strides);
        },
        else => {},
    }
}

fn createResource(
    self: *Dx3d11,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    log.debug(
        "create {s} (ret 0x{x})",
        .{ @tagName(description), ret_addr },
    );
    return switch (description) {
        .surface => |value| self.createSurface(value),
        .swapchain => |value| self.createSwapchain(value),
        .buffer => |value| self.createBuffer(value),
        .texture => |value| self.createTexture(value),
        .texture_view => |value| self.createTextureView(value),
        .sampler => |value| self.createSampler(value),
        .shader => |value| self.createShader(value),
        .descriptor_set_layout => |value| self.createDescriptorSetLayout(
            value,
        ),
        .pipeline_layout => |value| self.createPipelineLayout(value),
        .descriptor_set => |value| self.createDescriptorSet(value),
        .pipeline => |value| self.createPipeline(value),
        .command_buffer => |value| self.createCommandBuffer(value),
        .fence => |value| self.createFence(value),
        .semaphore => |value| self.createSemaphore(value),
    };
}

fn createSurface(
    self: *Dx3d11,
    description: types.SurfaceDescription,
) Error!Resource {
    return switch (description.native) {
        .win32 => |value| blk: {
            if (value.hwnd == 0) return error.InvalidDescription;
            break :blk self.newSlot(.surface, .{
                .surface = .{
                    .hwnd = @ptrFromInt(value.hwnd),
                    .width = 0,
                    .height = 0,
                },
            });
        },
        .headless => |value| self.newSlot(.surface, .{
            .surface = .{
                .hwnd = null,
                .width = value.width,
                .height = value.height,
            },
        }),
        else => error.Unsupported,
    };
}

fn createSwapchain(
    self: *Dx3d11,
    description: types.SwapchainDescription,
) Error!Resource {
    const surface_slot = try self.lookup(
        description.surface,
        .surface,
    );
    const surface = surface_slot.handle.surface;
    if (description.width == 0 or description.height == 0) {
        return error.InvalidDescription;
    }
    if (description.image_count < 1 or
        description.image_count > 16)
    {
        return error.InvalidDescription;
    }
    const dxgi_format = toDxgiFormat(description.format) orelse
        return error.Unsupported;
    const swap_format = switch (description.format) {
        .b8g8r8a8_srgb, .b8g8r8a8_unorm => win.DXGI_FORMAT_B8G8R8A8_UNORM,
        .r8g8b8a8_srgb, .r8g8b8a8_unorm => win.DXGI_FORMAT_R8G8B8A8_UNORM,
        else => dxgi_format,
    };

    var state = SwapchainState{
        .handle = null,
        .surface = description.surface,
        .properties = .{
            .width = description.width,
            .height = description.height,
            .format = description.format,
            .image_count = description.image_count,
        },
        .images = &.{},
        .views = &.{},
        .headless = surface.hwnd == null,
        .present_mode = description.present_mode,
    };

    if (surface.hwnd) |hwnd| {
        var desc = std.mem.zeroes(win.DXGI_SWAP_CHAIN_DESC1);
        desc.width = description.width;
        desc.height = description.height;
        desc.format = swap_format;
        desc.stereo = 0;
        desc.sample_desc = .{ .count = 1, .quality = 0 };
        desc.buffer_usage = win.DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.buffer_count = description.image_count;
        desc.scaling = win.DXGI_SCALING_STRETCH;
        desc.alpha_mode = win.DXGI_ALPHA_MODE_IGNORE;
        desc.flags = 0;
        var swapchain_raw: ?*win.IDXGISwapChain1 = null;
        var hr = win.createFlipSwapChainForHwnd(
            self.factory,
            @ptrCast(self.device),
            hwnd,
            &desc,
            &win.IID_ID3D11Texture2D,
            &swapchain_raw,
        );
        var use_bitblt = win.failed(hr) or swapchain_raw == null;
        if (!use_bitblt and !self.swapchainBuffersViewable(
            swapchain_raw.?,
            description.image_count,
            description.format,
        )) {
            // Some drivers accept a flip-model description but only
            // expose a usable view for buffer 0.
            log.info(
                "flip-model back buffers are not viewable; using a bitblt swap chain",
                .{},
            );
            use_bitblt = true;
        }
        if (use_bitblt) {
            // Fall back to a single-buffer bitblt swap chain; every
            // RHI image then aliases that one back buffer.
            if (swapchain_raw) |handle| _ = handle.release();
            swapchain_raw = null;
            desc.swap_effect = win.DXGI_SWAP_EFFECT_DISCARD;
            desc.buffer_count = 1;
            hr = self.factory.createSwapChainForHwnd(
                @ptrCast(self.device),
                hwnd,
                &desc,
                null,
                null,
                &swapchain_raw,
            );
            if (win.failed(hr) or swapchain_raw == null) {
                log.warn("CreateSwapChainForHwnd failed: 0x{x}", .{
                    @as(u32, @bitCast(hr)),
                });
                return mapError(hr);
            }
            state.bitblt = true;
        }
        state.handle = swapchain_raw;
        errdefer {
            if (state.handle) |handle| _ = handle.release();
        }
        _ = self.factory.makeWindowAssociation(hwnd, 1);
        var actual = std.mem.zeroes(win.DXGI_SWAP_CHAIN_DESC1);
        if (swapchain_raw.?.getDesc1(&actual) == 0) {
            log.info(
                "swapchain buffers={d} size={d}x{d} format=0x{x} effect={d}",
                .{
                    actual.buffer_count,
                    actual.width,
                    actual.height,
                    actual.format,
                    actual.swap_effect,
                },
            );
        }
    }

    const images = self.allocator.alloc(
        Resource,
        description.image_count,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(images);
    state.images = images;
    const views = self.allocator.alloc(
        Resource,
        description.image_count,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(views);
    state.views = views;

    var index: u32 = 0;
    while (index < description.image_count) : (index += 1) {
        const image_resource = if (state.handle) |handle| blk: {
            // Bitblt swap chains expose only buffer 0; every RHI image
            // aliases it so acquisition and presentation stay valid.
            const buffer_index: u32 = if (state.bitblt) 0 else index;
            var raw: ?*anyopaque = null;
            const get_hr = handle.getBuffer(
                buffer_index,
                &win.IID_ID3D11Texture2D,
                &raw,
            );
            if (win.failed(get_hr) or raw == null) {
                log.warn("GetBuffer({d}) failed: 0x{x}", .{
                    buffer_index,
                    @as(u32, @bitCast(get_hr)),
                });
                return mapError(get_hr);
            }
            const texture: *win.ID3D11Resource = @ptrCast(@alignCast(
                raw.?,
            ));
            const properties: types.TextureProperties = .{
                .type = .@"2d",
                .format = description.format,
                .width = description.width,
                .height = description.height,
                .depth = 1,
                .mip_levels = 1,
                .array_layers = 1,
                .samples = 1,
                .usage = .{
                    .color_attachment = true,
                    .transfer_src = true,
                },
            };
            break :blk try self.newSlot(.texture, .{
                .texture = .{
                    .resource = texture,
                    .properties = properties,
                },
            });
        } else try self.createTexture(.{
            .format = description.format,
            .width = description.width,
            .height = description.height,
            .usage = .{
                .color_attachment = true,
                .transfer_src = true,
            },
        });
        images[index] = image_resource;
        errdefer self.destroyIfAlive(image_resource);
    }

    index = 0;
    while (index < description.image_count) : (index += 1) {
        const view_resource = try self.createTextureView(.{
            .texture = images[index],
            .format = description.format,
        });
        views[index] = view_resource;
        errdefer self.destroyIfAlive(view_resource);
    }

    const resource = try self.newSlot(.swapchain, .{
        .swapchain = state,
    });
    return resource;
}

/// Returns `true` when every swap chain buffer accepts a render target
/// view in `format`.
///
/// Flip-model back buffers are supposed to be viewable, but some
/// drivers silently expose a bitblt swap chain instead: `GetBuffer`
/// succeeds for every index while only buffer 0 accepts a view. The
/// probe lets the backend downgrade to an aliased bitblt swap chain
/// instead of handing out broken images.
fn swapchainBuffersViewable(
    self: *Dx3d11,
    handle: *win.IDXGISwapChain1,
    image_count: u32,
    format: types.Format,
) bool {
    const dxgi_format = toDxgiFormat(format) orelse return false;
    var index: u32 = 0;
    while (index < image_count) : (index += 1) {
        var raw: ?*anyopaque = null;
        if (win.failed(handle.getBuffer(
            index,
            &win.IID_ID3D11Texture2D,
            &raw,
        )) or raw == null) {
            return false;
        }
        const texture: *win.ID3D11Resource = @ptrCast(@alignCast(raw.?));
        var desc = std.mem.zeroes(win.D3D11_RENDER_TARGET_VIEW_DESC);
        desc.format = dxgi_format;
        desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE2D;
        desc.u.texture_2d = .{ .mip_slice = 0 };
        var view: ?*win.ID3D11RenderTargetView = null;
        const hr = self.device.createRenderTargetView(texture, &desc, &view);
        if (view) |valid| _ = valid.release();
        _ = texture.release();
        if (win.failed(hr)) return false;
    }
    return true;
}

fn createBuffer(
    self: *Dx3d11,
    description: types.BufferDescription,
) Error!Resource {
    if (description.size == 0) return error.InvalidDescription;
    if (description.initial_data) |data| {
        if (data.len > description.size) {
            return error.InvalidDescription;
        }
    }
    const bind_flags = toBindFlags(description.usage);
    const byte_width = alignForward(
        @max(description.size, 1),
        16,
    );
    if (byte_width > std.math.maxInt(u32)) {
        return error.Unsupported;
    }

    var buffer_desc = std.mem.zeroes(win.D3D11_BUFFER_DESC);
    buffer_desc.byte_width = @intCast(byte_width);
    buffer_desc.usage = win.D3D11_USAGE_DEFAULT;
    buffer_desc.bind_flags = bind_flags;
    buffer_desc.cpu_access_flags = 0;
    buffer_desc.misc_flags = 0;
    buffer_desc.structure_byte_stride = 0;

    var initial = std.mem.zeroes(win.D3D11_SUBRESOURCE_DATA);
    var initial_ptr: ?*const win.D3D11_SUBRESOURCE_DATA = null;
    if (description.initial_data) |data| {
        initial.sys_mem = @ptrCast(data.ptr);
        initial.sys_mem_pitch = 0;
        initial.sys_mem_slice_pitch = 0;
        initial_ptr = &initial;
    }
    var resource_raw: ?*win.ID3D11Buffer = null;
    const hr = self.device.createBuffer(
        &buffer_desc,
        initial_ptr,
        &resource_raw,
    );
    if (win.failed(hr) or resource_raw == null) {
        return mapError(hr);
    }
    errdefer _ = resource_raw.?.release();

    var staging: ?*win.ID3D11Buffer = null;
    if (description.memory.host_visible) {
        var staging_desc = std.mem.zeroes(win.D3D11_BUFFER_DESC);
        staging_desc.byte_width = buffer_desc.byte_width;
        staging_desc.usage = win.D3D11_USAGE_STAGING;
        staging_desc.bind_flags = 0;
        staging_desc.cpu_access_flags = win.D3D11_CPU_ACCESS_READ |
            win.D3D11_CPU_ACCESS_WRITE;
        var staging_raw: ?*win.ID3D11Buffer = null;
        const staging_hr = self.device.createBuffer(
            &staging_desc,
            initial_ptr,
            &staging_raw,
        );
        if (win.failed(staging_hr) or staging_raw == null) {
            return mapError(staging_hr);
        }
        staging = staging_raw;
    }

    return self.newSlot(.buffer, .{
        .buffer = .{
            .resource = resource_raw.?,
            .staging = staging,
            .size = description.size,
            .hints = description.memory,
            .usage = description.usage,
            .host_visible = description.memory.host_visible,
        },
    });
}

fn createTexture(
    self: *Dx3d11,
    description: types.TextureDescription,
) Error!Resource {
    if (description.width == 0 or description.height == 0 or
        description.depth == 0)
    {
        return error.InvalidDescription;
    }
    if (description.mip_levels == 0 or
        description.array_layers == 0)
    {
        return error.InvalidDescription;
    }
    const format = toDxgiFormat(description.format) orelse
        return error.Unsupported;
    const bind_flags = toTextureBindFlags(description.usage);
    const samples: u32 = description.samples;
    if (samples != 1 and description.mip_levels != 1) {
        return error.InvalidDescription;
    }

    var subresources: []win.D3D11_SUBRESOURCE_DATA = &.{};
    var subresource_count: usize = 0;
    defer if (subresources.len != 0) {
        self.allocator.free(subresources);
    };
    if (description.initial_data) |data| {
        const bpp = description.format.bytesPerPixel() orelse
            return error.InvalidDescription;
        const tight_row = @as(u64, description.width) * bpp;
        const row_pitch: u64 = if (data.row_pitch == 0)
            tight_row
        else
            data.row_pitch;
        const rows: u64 = if (data.image_height == 0)
            description.height
        else
            data.image_height;
        const layer_bytes = row_pitch * rows;
        const required = layer_bytes *
            @as(u64, description.array_layers) *
            @as(u64, if (description.type == .@"3d") 1 else description.depth);
        if (data.bytes.len < required) {
            return error.InvalidDescription;
        }
        subresource_count = @as(usize, description.mip_levels) *
            @as(usize, description.array_layers);
        subresources = self.allocator.alloc(
            win.D3D11_SUBRESOURCE_DATA,
            subresource_count,
        ) catch return error.OutOfHostMemory;
        @memset(subresources, std.mem.zeroes(win.D3D11_SUBRESOURCE_DATA));
        var mip: u32 = 0;
        while (mip < description.mip_levels) : (mip += 1) {
            var layer: u32 = 0;
            while (layer < description.array_layers) : (layer += 1) {
                const index = @as(usize, mip) *
                    description.array_layers + layer;
                if (mip != 0) continue;
                const offset = @as(usize, @intCast(layer_bytes * layer));
                subresources[index] = .{
                    .sys_mem = @ptrCast(data.bytes.ptr + offset),
                    .sys_mem_pitch = @intCast(row_pitch),
                    .sys_mem_slice_pitch = if (description.type == .@"3d")
                        @intCast(layer_bytes)
                    else
                        0,
                };
            }
        }
    }

    var resource_raw: ?*anyopaque = null;
    var hr: win.HRESULT = 0;
    switch (description.type) {
        .@"1d" => {
            var desc = std.mem.zeroes(win.D3D11_TEXTURE1D_DESC);
            desc.width = description.width;
            desc.mip_levels = description.mip_levels;
            desc.array_size = description.array_layers;
            desc.format = format;
            desc.usage = win.D3D11_USAGE_DEFAULT;
            desc.bind_flags = bind_flags;
            hr = self.device.createTexture1D(
                &desc,
                if (subresources.len == 0) null else &subresources[0],
                @ptrCast(&resource_raw),
            );
        },
        .@"2d" => {
            var desc = std.mem.zeroes(win.D3D11_TEXTURE2D_DESC);
            desc.width = description.width;
            desc.height = description.height;
            desc.mip_levels = description.mip_levels;
            desc.array_size = description.array_layers;
            desc.format = format;
            desc.sample_desc = .{ .count = samples, .quality = 0 };
            desc.usage = win.D3D11_USAGE_DEFAULT;
            desc.bind_flags = bind_flags;
            hr = self.device.createTexture2D(
                &desc,
                if (subresources.len == 0) null else &subresources[0],
                @ptrCast(&resource_raw),
            );
        },
        .@"3d" => {
            var desc = std.mem.zeroes(win.D3D11_TEXTURE3D_DESC);
            desc.width = description.width;
            desc.height = description.height;
            desc.depth = description.depth;
            desc.mip_levels = description.mip_levels;
            desc.format = format;
            desc.usage = win.D3D11_USAGE_DEFAULT;
            desc.bind_flags = bind_flags;
            hr = self.device.createTexture3D(
                &desc,
                if (subresources.len == 0) null else &subresources[0],
                @ptrCast(&resource_raw),
            );
        },
    }
    if (win.failed(hr) or resource_raw == null) {
        return mapError(hr);
    }
    const resource: *win.ID3D11Resource = @ptrCast(@alignCast(
        resource_raw.?,
    ));
    errdefer _ = resource.release();

    return self.newSlot(.texture, .{
        .texture = .{
            .resource = resource,
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
        },
    });
}

fn createTextureView(
    self: *Dx3d11,
    description: types.TextureViewDescription,
) Error!Resource {
    const texture_slot = try self.lookup(
        description.texture,
        .texture,
    );
    const texture = texture_slot.handle.texture;
    const properties = texture.properties;
    const format = description.format orelse properties.format;
    const dxgi_format = toDxgiFormat(format) orelse
        return error.Unsupported;
    const aspect = description.aspect orelse format.aspect();
    const view_type = description.type orelse properties.type;
    const base_mip = description.base_mip;
    const mip_count = if (description.mip_count == 0)
        properties.mip_levels - base_mip
    else
        description.mip_count;
    const base_layer = description.base_layer;
    const layer_count = if (description.layer_count == 0)
        properties.array_layers - base_layer
    else
        description.layer_count;
    if (base_mip >= properties.mip_levels or
        mip_count > properties.mip_levels - base_mip or
        base_layer >= properties.array_layers or
        layer_count > properties.array_layers - base_layer)
    {
        return error.InvalidDescription;
    }

    var state = TextureViewState{
        .aspect = aspect,
        .format = format,
    };
    var created = false;

    if (properties.usage.sampled and
        (aspect == .color or aspect == .depth or
            aspect == .depth_stencil))
    {
        var desc = std.mem.zeroes(win.D3D11_SHADER_RESOURCE_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                    };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                    };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D11_SRV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .most_detailed_mip = base_mip,
                    .mip_levels = mip_count,
                };
            },
        }
        var raw: ?*win.ID3D11ShaderResourceView = null;
        const hr = self.device.createShaderResourceView(
            texture.resource,
            &desc,
            &raw,
        );
        if (win.failed(hr)) return mapError(hr);
        state.srv = raw;
        created = true;
    }

    if (properties.usage.color_attachment and aspect == .color) {
        var desc = std.mem.zeroes(win.D3D11_RENDER_TARGET_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{ .mip_slice = base_mip };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D11_RTV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .mip_slice = base_mip,
                    .first_w_slice = 0,
                    .w_size = properties.depth,
                };
            },
        }
        var raw: ?*win.ID3D11RenderTargetView = null;
        const hr = self.device.createRenderTargetView(
            texture.resource,
            &desc,
            &raw,
        );
        if (win.failed(hr)) {
            log.warn(
                "CreateRenderTargetView failed: 0x{x} format=0x{x} mip={d} layers={d}",
                .{
                    @as(u32, @bitCast(hr)),
                    desc.format,
                    base_mip,
                    layer_count,
                },
            );
            return mapError(hr);
        }
        state.rtv = raw;
        created = true;
    }

    if (properties.usage.depth_attachment and
        (aspect == .depth or aspect == .stencil or
            aspect == .depth_stencil))
    {
        var desc = std.mem.zeroes(win.D3D11_DEPTH_STENCIL_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_DSV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{ .mip_slice = base_mip };
                }
            },
            .@"3d" => return error.Unsupported,
        }
        var raw: ?*win.ID3D11DepthStencilView = null;
        const hr = self.device.createDepthStencilView(
            texture.resource,
            &desc,
            &raw,
        );
        if (win.failed(hr)) return mapError(hr);
        state.dsv = raw;
        created = true;
    }

    if (properties.usage.storage) {
        var desc = std.mem.zeroes(win.D3D11_UNORDERED_ACCESS_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_UAV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_UAV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D11_UAV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D11_UAV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{ .mip_slice = base_mip };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D11_UAV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .mip_slice = base_mip,
                    .first_w_slice = 0,
                    .w_size = properties.depth,
                };
            },
        }
        var raw: ?*win.ID3D11UnorderedAccessView = null;
        const hr = self.device.createUnorderedAccessView(
            texture.resource,
            &desc,
            &raw,
        );
        if (win.failed(hr)) return mapError(hr);
        state.uav = raw;
        created = true;
    }

    if (!created) return error.Unsupported;
    return self.newSlot(.texture_view, .{ .texture_view = state });
}

fn createSampler(
    self: *Dx3d11,
    description: types.SamplerDescription,
) Error!Resource {
    var desc = std.mem.zeroes(win.D3D11_SAMPLER_DESC);
    desc.filter = toD3D11Filter(description);
    desc.address_u = toD3D11Address(description.address_u);
    desc.address_v = toD3D11Address(description.address_v);
    desc.address_w = toD3D11Address(description.address_w);
    desc.mip_lod_bias = 0;
    desc.max_anisotropy = if (description.anisotropy == 0)
        1
    else
        description.anisotropy;
    desc.comparison_func = if (description.compare) |compare|
        toD3D11Compare(compare)
    else
        win.D3D11_COMPARISON_ALWAYS;
    desc.border_color = .{ 0, 0, 0, 0 };
    desc.min_lod = description.lod_min;
    desc.max_lod = description.lod_max;

    var raw: ?*win.ID3D11SamplerState = null;
    const hr = self.device.createSamplerState(&desc, &raw);
    if (win.failed(hr) or raw == null) return mapError(hr);
    return self.newSlot(.sampler, .{ .sampler = raw.? });
}

fn createShader(
    self: *Dx3d11,
    description: types.ShaderDescription,
) Error!Resource {
    if (description.code.len == 0) return error.InvalidDescription;
    const stage = description.stage;
    const target: [:0]const u8 = switch (stage) {
        .vertex => "vs_5_0",
        .fragment => "ps_5_0",
        .compute => "cs_5_0",
        else => return error.Unsupported,
    };

    const translated = spirv.translate(
        self.allocator,
        description.code,
        stage,
        description.entry_point,
        .d3d11,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfHostMemory,
        error.InvalidSpirv, error.Unsupported => {
            log.warn("SPIR-V translation failed: {}", .{err});
            return error.Unsupported;
        },
    };
    defer translated.deinit();

    var blob: ?*win.ID3DBlob = null;
    var errors: ?*win.ID3DBlob = null;
    const hr = win.D3DCompile(
        @ptrCast(translated.source.ptr),
        translated.source.len,
        null,
        null,
        null,
        "main",
        target.ptr,
        0x800 | 0x10,
        0,
        &blob,
        &errors,
    );
    if (errors) |error_blob| {
        const ptr = error_blob.getBufferPointer();
        const len = error_blob.getBufferSize();
        if (ptr) |bytes| {
            log.warn("HLSL compiler: {s}", .{
                @as([*]const u8, @ptrCast(bytes))[0..len],
            });
        }
        _ = error_blob.release();
    }
    if (win.failed(hr) or blob == null) {
        log.warn("D3DCompile failed: 0x{x}", .{
            @as(u32, @bitCast(hr)),
        });
        return error.InvalidDescription;
    }

    const bytecode = .{
        .ptr = @as([*]const u8, @ptrCast(
            blob.?.getBufferPointer().?,
        )),
        .len = blob.?.getBufferSize(),
    };
    var state = ShaderState{
        .stage = stage,
        .blob = blob.?,
    };
    errdefer _ = state.blob.release();

    switch (stage) {
        .vertex => {
            var raw: ?*win.ID3D11VertexShader = null;
            const shader_hr = self.device.createVertexShader(
                @ptrCast(bytecode.ptr),
                bytecode.len,
                null,
                &raw,
            );
            if (win.failed(shader_hr) or raw == null) {
                return mapError(shader_hr);
            }
            state.vertex = raw;
        },
        .fragment => {
            var raw: ?*win.ID3D11PixelShader = null;
            const shader_hr = self.device.createPixelShader(
                @ptrCast(bytecode.ptr),
                bytecode.len,
                null,
                &raw,
            );
            if (win.failed(shader_hr) or raw == null) {
                return mapError(shader_hr);
            }
            state.pixel = raw;
        },
        .compute => {
            var raw: ?*win.ID3D11ComputeShader = null;
            const shader_hr = self.device.createComputeShader(
                @ptrCast(bytecode.ptr),
                bytecode.len,
                null,
                &raw,
            );
            if (win.failed(shader_hr) or raw == null) {
                return mapError(shader_hr);
            }
            state.compute = raw;
        },
        else => return error.Unsupported,
    }

    return self.newSlot(.shader, .{ .shader = state });
}

fn createDescriptorSetLayout(
    self: *Dx3d11,
    description: types.DescriptorSetLayoutDescription,
) Error!Resource {
    if (description.bindings.len == 0) {
        return error.InvalidDescription;
    }
    for (description.bindings, 0..) |binding, index| {
        for (description.bindings[index + 1 ..]) |other| {
            if (binding.binding == other.binding) {
                return error.InvalidDescription;
            }
        }
        if (binding.count == 0) return error.InvalidDescription;
    }
    const bindings = self.allocator.dupe(
        types.DescriptorSetLayoutDescription.DescriptorBinding,
        description.bindings,
    ) catch return error.OutOfHostMemory;
    return self.newSlot(.descriptor_set_layout, .{
        .descriptor_set_layout = .{ .bindings = bindings },
    });
}

fn createPipelineLayout(
    self: *Dx3d11,
    description: types.PipelineLayoutDescription,
) Error!Resource {
    const sets = self.allocator.dupe(
        Resource,
        description.descriptor_sets,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(sets);
    for (sets) |set| _ = try self.lookup(set, .descriptor_set_layout);

    const push = self.allocator.dupe(
        types.PipelineLayoutDescription.PushConstant,
        description.push_constants,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(push);

    var push_size: u32 = 0;
    for (push) |range| {
        const end = range.offset + range.size;
        if (end > push_size) push_size = end;
    }
    var push_shadow: []u8 = &.{};
    var push_buffer: ?*win.ID3D11Buffer = null;
    if (push_size != 0) {
        const aligned = alignForward(push_size, 16);
        push_shadow = self.allocator.alloc(u8, aligned) catch
            return error.OutOfHostMemory;
        @memset(push_shadow, 0);
        var desc = std.mem.zeroes(win.D3D11_BUFFER_DESC);
        desc.byte_width = @intCast(aligned);
        desc.usage = win.D3D11_USAGE_DEFAULT;
        desc.bind_flags = win.D3D11_BIND_CONSTANT_BUFFER;
        var raw: ?*win.ID3D11Buffer = null;
        const hr = self.device.createBuffer(&desc, null, &raw);
        if (win.failed(hr) or raw == null) {
            self.allocator.free(push_shadow);
            return mapError(hr);
        }
        push_buffer = raw;
    }
    errdefer {
        if (push_buffer) |buffer| _ = buffer.release();
    }
    errdefer self.allocator.free(push_shadow);

    return self.newSlot(.pipeline_layout, .{
        .pipeline_layout = .{
            .descriptor_sets = sets,
            .push_constants = push,
            .push_buffer = push_buffer,
            .push_shadow = push_shadow,
        },
    });
}

fn createDescriptorSet(
    self: *Dx3d11,
    description: types.DescriptorSetDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .descriptor_set_layout,
    );
    var count: usize = 0;
    for (layout_slot.handle.descriptor_set_layout.bindings) |binding| {
        count += binding.count;
    }
    const values = self.allocator.alloc(?BoundValue, count) catch
        return error.OutOfHostMemory;
    @memset(values, null);
    return self.newSlot(.descriptor_set, .{
        .descriptor_set = .{
            .layout = description.layout,
            .values = values,
        },
    });
}

fn createPipeline(
    self: *Dx3d11,
    description: types.PipelineDescription,
) Error!Resource {
    return switch (description) {
        .graphics => |value| self.createGraphicsPipeline(value),
        .compute => |value| self.createComputePipeline(value),
    };
}

fn createGraphicsPipeline(
    self: *Dx3d11,
    description: types.GraphicsPipelineDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .pipeline_layout,
    );
    _ = layout_slot;
    const vertex_slot = try self.lookup(description.vertex, .shader);
    if (vertex_slot.handle.shader.stage != .vertex) {
        return error.InvalidDescription;
    }
    var pixel: ?*win.ID3D11PixelShader = null;
    if (description.fragment) |fragment_resource| {
        const fragment_slot = try self.lookup(
            fragment_resource,
            .shader,
        );
        if (fragment_slot.handle.shader.stage != .fragment) {
            return error.InvalidDescription;
        }
        pixel = fragment_slot.handle.shader.pixel;
    }

    var input_layout: ?*win.ID3D11InputLayout = null;
    var strides: []u32 = &.{};
    var max_binding: u32 = 0;
    for (description.vertex_layout.bindings) |binding| {
        if (binding.binding + 1 > max_binding) {
            max_binding = binding.binding + 1;
        }
    }
    for (description.vertex_layout.attributes) |attribute| {
        if (attribute.binding + 1 > max_binding) {
            max_binding = attribute.binding + 1;
        }
    }
    if (max_binding != 0) {
        strides = self.allocator.alloc(u32, max_binding) catch
            return error.OutOfHostMemory;
        @memset(strides, 0);
        for (description.vertex_layout.bindings) |binding| {
            if (binding.binding < strides.len) {
                strides[binding.binding] = binding.stride;
            }
        }
    }
    errdefer self.allocator.free(strides);

    if (description.vertex_layout.attributes.len != 0) {
        const elements = self.allocator.alloc(
            win.D3D11_INPUT_ELEMENT_DESC,
            description.vertex_layout.attributes.len,
        ) catch return error.OutOfHostMemory;
        defer self.allocator.free(elements);
        for (description.vertex_layout.attributes, 0..) |attribute, index| {
            const rate = blk: {
                for (description.vertex_layout.bindings) |binding| {
                    if (binding.binding == attribute.binding) {
                        break :blk binding.rate;
                    }
                }
                break :blk types.VertexInputRate.vertex;
            };
            elements[index] = .{
                .semantic_name = "LOCATION",
                .semantic_index = attribute.location,
                .format = toDxgiFormat(attribute.format) orelse
                    return error.Unsupported,
                .input_slot = attribute.binding,
                .aligned_byte_offset = attribute.offset,
                .input_slot_class = switch (rate) {
                    .vertex => win.D3D11_INPUT_PER_VERTEX_DATA,
                    .instance => win.D3D11_INPUT_PER_INSTANCE_DATA,
                },
                .instance_data_step_rate = switch (rate) {
                    .vertex => 0,
                    .instance => 1,
                },
            };
        }
        const vertex = vertex_slot.handle.shader;
        const bytecode = vertex.bytecode();
        var raw: ?*win.ID3D11InputLayout = null;
        const hr = self.device.createInputLayout(
            &elements[0],
            @intCast(elements.len),
            @ptrCast(bytecode.ptr),
            bytecode.len,
            &raw,
        );
        if (win.failed(hr) or raw == null) {
            return mapError(hr);
        }
        input_layout = raw;
    }
    errdefer {
        if (input_layout) |value| _ = value.release();
    }

    var blend_desc = std.mem.zeroes(win.D3D11_BLEND_DESC);
    blend_desc.alpha_to_coverage_enable = 0;
    blend_desc.independent_blend_enable = 0;
    const rt = &blend_desc.render_target[0];
    rt.blend_enable = if (description.blend.enabled) 1 else 0;
    rt.src_blend = toD3D11Blend(description.blend.src_color);
    rt.dest_blend = toD3D11Blend(description.blend.dst_color);
    rt.blend_op = toD3D11BlendOp(description.blend.op_color);
    rt.src_blend_alpha = toD3D11Blend(description.blend.src_alpha);
    rt.dest_blend_alpha = toD3D11Blend(description.blend.dst_alpha);
    rt.blend_op_alpha = toD3D11BlendOp(description.blend.op_alpha);
    rt.render_target_write_mask = 0xf;
    var blend: ?*win.ID3D11BlendState = null;
    var hr = self.device.createBlendState(&blend_desc, &blend);
    if (win.failed(hr) or blend == null) return mapError(hr);
    errdefer _ = blend.?.release();

    var depth_desc = std.mem.zeroes(win.D3D11_DEPTH_STENCIL_DESC);
    depth_desc.depth_enable = if (description.depth.enable) 1 else 0;
    depth_desc.depth_write_mask = if (description.depth.write)
        win.D3D11_DEPTH_WRITE_MASK_ALL
    else
        win.D3D11_DEPTH_WRITE_MASK_ZERO;
    depth_desc.depth_func = toD3D11Compare(description.depth.compare);
    depth_desc.stencil_enable = 0;
    depth_desc.stencil_read_mask = 0xff;
    depth_desc.stencil_write_mask = 0xff;
    var depth_stencil: ?*win.ID3D11DepthStencilState = null;
    hr = self.device.createDepthStencilState(
        &depth_desc,
        &depth_stencil,
    );
    if (win.failed(hr) or depth_stencil == null) return mapError(hr);
    errdefer _ = depth_stencil.?.release();

    var raster_desc = std.mem.zeroes(win.D3D11_RASTERIZER_DESC);
    raster_desc.fill_mode = win.D3D11_FILL_SOLID;
    raster_desc.cull_mode = toD3D11Cull(description.cull);
    raster_desc.front_counter_clockwise = switch (description.front_face) {
        .counter_clockwise => 0,
        .clockwise => 1,
    };
    raster_desc.depth_bias = 0;
    raster_desc.depth_bias_clamp = 0;
    raster_desc.slope_scaled_depth_bias = 0;
    raster_desc.depth_clip_enable = 1;
    raster_desc.scissor_enable = 1;
    raster_desc.multisample_enable = if (description.samples > 1) 1 else 0;
    raster_desc.antialiased_line_enable = 0;
    var rasterizer: ?*win.ID3D11RasterizerState = null;
    hr = self.device.createRasterizerState(
        &raster_desc,
        &rasterizer,
    );
    if (win.failed(hr) or rasterizer == null) return mapError(hr);
    errdefer _ = rasterizer.?.release();

    return self.newSlot(.pipeline, .{
        .pipeline = .{
            .bind_point = .graphics,
            .layout = description.layout,
            .vertex = vertex_slot.handle.shader.vertex,
            .pixel = pixel,
            .input_layout = input_layout,
            .blend = blend,
            .depth_stencil = depth_stencil,
            .rasterizer = rasterizer,
            .topology = toD3D11Topology(description.topology),
            .strides = strides,
        },
    });
}

fn createComputePipeline(
    self: *Dx3d11,
    description: types.ComputePipelineDescription,
) Error!Resource {
    _ = try self.lookup(description.layout, .pipeline_layout);
    const shader_slot = try self.lookup(description.shader, .shader);
    if (shader_slot.handle.shader.stage != .compute) {
        return error.InvalidDescription;
    }
    return self.newSlot(.pipeline, .{
        .pipeline = .{
            .bind_point = .compute,
            .layout = description.layout,
            .compute = shader_slot.handle.shader.compute,
        },
    });
}

fn createCommandBuffer(
    self: *Dx3d11,
    description: types.CommandBufferDescription,
) Error!Resource {
    return self.newSlot(.command_buffer, .{
        .command_buffer = .{ .level = description.level },
    });
}

fn createFence(
    self: *Dx3d11,
    description: types.FenceDescription,
) Error!Resource {
    return self.newSlot(.fence, .{
        .fence = .{ .signaled = description.signaled },
    });
}

fn createSemaphore(
    self: *Dx3d11,
    description: types.SemaphoreDescription,
) Error!Resource {
    _ = description;
    return self.newSlot(.semaphore, .{ .semaphore = .{} });
}

fn createBatch(
    self: *Dx3d11,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Error!void {
    if (descriptions.len != resources.len) {
        return error.InvalidDescription;
    }
    var created: usize = 0;
    errdefer {
        for (resources[0..created]) |resource| {
            self.destroyResource(resource);
        }
    }
    for (descriptions, 0..) |description, index| {
        resources[index] = try self.createResource(
            description,
            ret_addr,
        );
        created += 1;
    }
}

fn destroyResource(self: *Dx3d11, resource: Resource) void {
    const slot = self.lookup(resource, resource.tag) catch return;
    switch (slot.handle) {
        .surface => {},
        .swapchain => |value| {
            for (value.views) |view| self.destroyIfAlive(view);
            for (value.images) |image| self.destroyIfAlive(image);
            if (value.handle) |handle| _ = handle.release();
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .buffer => |value| {
            _ = value.resource.release();
            if (value.staging) |staging| _ = staging.release();
        },
        .texture => |value| {
            _ = value.resource.release();
        },
        .texture_view => |value| {
            if (value.srv) |handle| _ = handle.release();
            if (value.rtv) |handle| _ = handle.release();
            if (value.dsv) |handle| _ = handle.release();
            if (value.uav) |handle| _ = handle.release();
        },
        .sampler => |handle| _ = handle.release(),
        .shader => |value| {
            if (value.vertex) |handle| _ = handle.release();
            if (value.pixel) |handle| _ = handle.release();
            if (value.compute) |handle| _ = handle.release();
            _ = value.blob.release();
        },
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            if (value.push_buffer) |handle| _ = handle.release();
            self.allocator.free(value.push_shadow);
            self.allocator.free(value.descriptor_sets);
            self.allocator.free(value.push_constants);
        },
        .descriptor_set => |value| {
            self.allocator.free(value.values);
        },
        .pipeline => |value| {
            if (value.input_layout) |handle| _ = handle.release();
            if (value.blend) |handle| _ = handle.release();
            if (value.depth_stencil) |handle| _ = handle.release();
            if (value.rasterizer) |handle| _ = handle.release();
            self.allocator.free(value.strides);
        },
        .command_buffer => {},
        .fence => {},
        .semaphore => {},
    }
    self.releaseSlot(resource);
}

fn destroyIfAlive(self: *Dx3d11, resource: Resource) void {
    _ = self.lookup(resource, resource.tag) catch return;
    self.destroyResource(resource);
}

fn map(
    self: *Dx3d11,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    _ = ret_addr;
    const slot = try self.lookup(resource, .buffer);
    const buffer = &slot.handle.buffer;
    if (!buffer.host_visible) return error.Unsupported;
    const staging = buffer.staging orelse return error.Unsupported;
    if (buffer.mapped) return error.InvalidResource;
    if (offset > buffer.size or size > buffer.size - offset) {
        return error.InvalidDescription;
    }
    self.context.copyResource(
        @ptrCast(staging),
        @ptrCast(buffer.resource),
    );
    var mapped_resource = std.mem.zeroes(win.D3D11_MAPPED_SUBRESOURCE);
    var hr = self.context.map(
        @ptrCast(staging),
        0,
        win.D3D11_MAP_READ_WRITE,
        0,
        &mapped_resource,
    );
    if (win.failed(hr)) {
        hr = self.context.map(
            @ptrCast(staging),
            0,
            win.D3D11_MAP_WRITE,
            0,
            &mapped_resource,
        );
    }
    if (win.failed(hr) or mapped_resource.data == null) {
        return mapError(hr);
    }
    buffer.mapped = true;
    const bytes: [*]u8 = @ptrCast(mapped_resource.data.?);
    return bytes[@intCast(offset)..][0..@intCast(size)];
}

fn unmap(
    self: *Dx3d11,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    _ = ret_addr;
    const slot = self.lookup(resource, .buffer) catch return;
    const buffer = &slot.handle.buffer;
    if (!buffer.mapped) {
        log.warn("unmap of an unmapped buffer", .{});
        return;
    }
    const staging = buffer.staging orelse return;
    self.context.unmap(@ptrCast(staging), 0);
    buffer.mapped = false;

    if (dirty.len == 0) {
        self.context.copyResource(
            @ptrCast(buffer.resource),
            @ptrCast(staging),
        );
        return;
    }
    for (dirty) |range| {
        if (range.size == 0) continue;
        if (range.offset > buffer.size or
            range.size > buffer.size - range.offset)
        {
            log.warn("ignoring out of bounds dirty range", .{});
            continue;
        }
        var box = std.mem.zeroes(win.D3D11_BOX);
        box.left = @intCast(range.offset);
        box.right = @intCast(range.offset + range.size);
        box.top = 0;
        box.bottom = 1;
        box.front = 0;
        box.back = 1;
        self.context.copySubresourceRegion(
            @ptrCast(buffer.resource),
            0,
            @intCast(range.offset),
            0,
            0,
            @ptrCast(staging),
            0,
            &box,
        );
    }
}

fn getQueue(self: *Dx3d11, index: u32, ret_addr: usize) Error!Queue {
    _ = ret_addr;
    if (index != 0) return error.Unsupported;
    return .{
        .vptr = self,
        .vtable = &queue_vtable,
        .family_index = 0,
        .queue_index = 0,
    };
}

fn record(
    self: *Dx3d11,
    resource: Resource,
    command: commands.Command,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const slot = try self.lookup(resource, .command_buffer);
    const command_buffer = &slot.handle.command_buffer;

    switch (command) {
        .begin => {
            if (command_buffer.state == .recording) {
                return error.InvalidResource;
            }
            command_buffer.state = .recording;
            command_buffer.in_rendering = false;
            command_buffer.pipeline = null;
        },
        .end => {
            if (command_buffer.state != .recording) {
                return error.InvalidResource;
            }
            command_buffer.state = .ended;
        },
        .begin_rendering => |value| {
            try requireRecording(command_buffer);
            try self.beginRendering(command_buffer, value);
        },
        .end_rendering => {
            try requireRecording(command_buffer);
            if (!command_buffer.in_rendering) {
                return error.InvalidResource;
            }
            command_buffer.in_rendering = false;
            self.context.oMSetRenderTargets(0, undefined, null);
        },
        .bind_pipeline => |value| {
            try requireRecording(command_buffer);
            const pipeline_slot = try self.lookup(
                value.pipeline,
                .pipeline,
            );
            const pipeline = &pipeline_slot.handle.pipeline;
            command_buffer.pipeline = pipeline;
            switch (pipeline.bind_point) {
                .graphics => {
                    self.context.vSSetShader(
                        pipeline.vertex,
                        undefined,
                        0,
                    );
                    self.context.pSSetShader(
                        pipeline.pixel,
                        undefined,
                        0,
                    );
                    self.context.iASetInputLayout(
                        pipeline.input_layout,
                    );
                    self.context.iASetPrimitiveTopology(
                        pipeline.topology,
                    );
                    self.context.oMSetBlendState(
                        pipeline.blend,
                        &.{ 1, 1, 1, 1 },
                        0xffffffff,
                    );
                    self.context.oMSetDepthStencilState(
                        pipeline.depth_stencil,
                        0,
                    );
                    self.context.rSSetState(pipeline.rasterizer);
                },
                .compute => {
                    self.context.cSSetShader(
                        pipeline.compute,
                        undefined,
                        0,
                    );
                },
            }
        },
        .bind_vertex_buffers => |value| {
            try requireRecording(command_buffer);
            const pipeline = command_buffer.pipeline orelse
                return error.InvalidResource;
            const buffer_count = value.buffers.len;
            if (buffer_count == 0) return;
            const buffers = self.allocator.alloc(
                ?*win.ID3D11Buffer,
                buffer_count,
            ) catch return error.OutOfHostMemory;
            defer self.allocator.free(buffers);
            const strides = self.allocator.alloc(
                u32,
                buffer_count,
            ) catch return error.OutOfHostMemory;
            defer self.allocator.free(strides);
            const offsets = self.allocator.alloc(
                u32,
                buffer_count,
            ) catch return error.OutOfHostMemory;
            defer self.allocator.free(offsets);
            for (value.buffers, 0..) |buffer_resource, index| {
                const buffer_slot = try self.lookup(
                    buffer_resource,
                    .buffer,
                );
                buffers[index] = buffer_slot.handle.buffer.resource;
                const binding = value.first_binding + @as(u32, @intCast(index));
                strides[index] = if (binding < pipeline.strides.len)
                    pipeline.strides[binding]
                else
                    0;
                offsets[index] = if (index < value.offsets.len)
                    @intCast(value.offsets[index])
                else
                    0;
            }
            self.context.iASetVertexBuffers(
                value.first_binding,
                @intCast(buffer_count),
                buffers.ptr,
                strides.ptr,
                offsets.ptr,
            );
        },
        .bind_index_buffer => |value| {
            try requireRecording(command_buffer);
            const buffer_slot = try self.lookup(value.buffer, .buffer);
            self.context.iASetIndexBuffer(
                buffer_slot.handle.buffer.resource,
                switch (value.type) {
                    .uint16 => 57,
                    .uint32 => 42,
                },
                @intCast(value.offset),
            );
        },
        .bind_descriptor_sets => |value| {
            try requireRecording(command_buffer);
            try self.bindDescriptorSets(value);
        },
        .set_viewport => |value| {
            try requireRecording(command_buffer);
            const viewport = win.D3D11_VIEWPORT{
                .top_left_x = value.x,
                .top_left_y = value.y,
                .width = value.width,
                .height = value.height,
                .min_depth = value.min_depth,
                .max_depth = value.max_depth,
            };
            self.context.rSSetViewports(1, &viewport);
        },
        .set_scissor => |value| {
            try requireRecording(command_buffer);
            const rect = win.D3D11_RECT{
                .left = value.x,
                .top = value.y,
                .right = value.x + @as(i32, @intCast(value.width)),
                .bottom = value.y + @as(i32, @intCast(value.height)),
            };
            self.context.rSSetScissorRects(1, &rect);
        },
        .draw => |value| {
            try requireDraw(command_buffer);
            self.context.drawInstanced(
                value.vertex_count,
                value.instance_count,
                value.first_vertex,
                value.first_instance,
            );
        },
        .draw_indexed => |value| {
            try requireDraw(command_buffer);
            self.context.drawIndexedInstanced(
                value.index_count,
                value.instance_count,
                value.first_index,
                value.vertex_offset,
                value.first_instance,
            );
        },
        .dispatch => |value| {
            try requireRecording(command_buffer);
            self.context.dispatch(value.x, value.y, value.z);
        },
        .copy_buffer => |value| {
            try requireRecording(command_buffer);
            const src = try self.lookup(value.src, .buffer);
            const dst = try self.lookup(value.dst, .buffer);
            for (value.regions) |region| {
                var box = std.mem.zeroes(win.D3D11_BOX);
                box.left = @intCast(region.src_offset);
                box.right = @intCast(region.src_offset + region.size);
                box.top = 0;
                box.bottom = 1;
                box.front = 0;
                box.back = 1;
                self.context.copySubresourceRegion(
                    @ptrCast(dst.handle.buffer.resource),
                    0,
                    @intCast(region.dst_offset),
                    0,
                    0,
                    @ptrCast(src.handle.buffer.resource),
                    0,
                    &box,
                );
            }
        },
        .copy_buffer_to_texture => |value| {
            try requireRecording(command_buffer);
            try self.copyBufferToTexture(value);
        },
        .copy_texture_to_buffer => |value| {
            _ = value;
            return error.Unsupported;
        },
        .copy_texture => |value| {
            try requireRecording(command_buffer);
            const src = try self.lookup(value.src, .texture);
            const dst = try self.lookup(value.dst, .texture);
            for (value.regions) |region| {
                const src_subresource = region.mip_level +
                    region.array_layer *
                        src.handle.texture.properties.mip_levels;
                const dst_subresource = region.mip_level +
                    region.array_layer *
                        dst.handle.texture.properties.mip_levels;
                var box = std.mem.zeroes(win.D3D11_BOX);
                box.left = region.offset.x;
                box.top = region.offset.y;
                box.front = region.offset.z;
                box.right = region.offset.x + region.extent.width;
                box.bottom = region.offset.y + region.extent.height;
                box.back = region.offset.z + region.extent.depth;
                self.context.copySubresourceRegion(
                    dst.handle.texture.resource,
                    dst_subresource,
                    region.offset.x,
                    region.offset.y,
                    region.offset.z,
                    src.handle.texture.resource,
                    src_subresource,
                    &box,
                );
            }
        },
        .barrier => |value| {
            try requireRecording(command_buffer);
            _ = try self.lookup(value.resource, value.resource.tag);
        },
        .push_constants => |value| {
            try requireRecording(command_buffer);
            try self.pushConstants(value);
        },
    }
}

fn requireRecording(command_buffer: *CommandBufferState) Error!void {
    if (command_buffer.state != .recording) {
        return error.InvalidResource;
    }
}

fn requireDraw(command_buffer: *CommandBufferState) Error!void {
    try requireRecording(command_buffer);
    if (!command_buffer.in_rendering) {
        return error.InvalidResource;
    }
    if (command_buffer.pipeline == null) {
        return error.InvalidResource;
    }
}

fn beginRendering(
    self: *Dx3d11,
    command_buffer: *CommandBufferState,
    value: commands.BeginRendering,
) Error!void {
    if (command_buffer.in_rendering) {
        return error.InvalidResource;
    }
    const rtvs = self.allocator.alloc(
        ?*win.ID3D11RenderTargetView,
        value.color_attachments.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(rtvs);
    for (value.color_attachments, 0..) |attachment, index| {
        const view_slot = try self.lookup(
            attachment.view,
            .texture_view,
        );
        rtvs[index] = view_slot.handle.texture_view.rtv orelse
            return error.InvalidDescription;
    }
    var dsv: ?*win.ID3D11DepthStencilView = null;
    if (value.depth_attachment) |attachment| {
        const view_slot = try self.lookup(
            attachment.view,
            .texture_view,
        );
        dsv = view_slot.handle.texture_view.dsv orelse
            return error.InvalidDescription;
    }
    self.context.oMSetRenderTargets(
        @intCast(rtvs.len),
        rtvs.ptr,
        dsv,
    );
    command_buffer.in_rendering = true;
    for (value.color_attachments) |attachment| {
        if (attachment.load != .clear) continue;
        const view_slot = try self.lookup(
            attachment.view,
            .texture_view,
        );
        const rtv = view_slot.handle.texture_view.rtv orelse
            return error.InvalidDescription;
        const color = [4]f32{
            attachment.clear.r,
            attachment.clear.g,
            attachment.clear.b,
            attachment.clear.a,
        };
        self.context.clearRenderTargetView(rtv, &color);
    }
    if (value.depth_attachment) |attachment| {
        if (attachment.load == .clear) {
            const view_slot = try self.lookup(
                attachment.view,
                .texture_view,
            );
            const dsv_handle = view_slot.handle.texture_view.dsv orelse
                return error.InvalidDescription;
            self.context.clearDepthStencilView(
                dsv_handle,
                win.D3D11_CLEAR_DEPTH | win.D3D11_CLEAR_STENCIL,
                attachment.clear_depth,
                @intCast(attachment.clear_stencil),
            );
        }
    }
}

fn bindDescriptorSets(
    self: *Dx3d11,
    value: commands.BindDescriptorSets,
) Error!void {
    _ = try self.lookup(value.layout, .pipeline_layout);
    if (value.dynamic_offsets.len != 0) {
        return error.Unsupported;
    }
    for (value.sets, 0..) |set_resource, index| {
        const set_slot = try self.lookup(set_resource, .descriptor_set);
        const layout_slot = try self.lookup(
            set_slot.handle.descriptor_set.layout,
            .descriptor_set_layout,
        );
        const set_index = value.first_set + @as(u32, @intCast(index));
        for (layout_slot.handle.descriptor_set_layout.bindings) |binding| {
            const slot = set_index * 16 + binding.binding;
            if (slot >= 128) return error.Unsupported;
            const stages = binding.stages;
            if (slot < 16 and binding.kind != .uniform_buffer and
                slot >= 14 and binding.kind == .uniform_buffer)
            {
                return error.Unsupported;
            }
            for (0..binding.count) |array_index| {
                const found = findBoundValue(
                    set_slot.handle.descriptor_set.values,
                    binding.binding,
                    @intCast(array_index),
                );
                try self.applyDescriptor(
                    value.bind_point,
                    stages,
                    binding.kind,
                    slot,
                    found,
                );
            }
        }
    }
}

fn findBoundValue(
    values: []?BoundValue,
    binding: u32,
    array_index: u32,
) ?BoundValue {
    for (values) |value| {
        if (value) |present| {
            if (present.binding == binding and
                present.array_index == array_index)
            {
                return present;
            }
        }
    }
    return null;
}

fn applyDescriptor(
    self: *Dx3d11,
    bind_point: types.BindPoint,
    stages: types.ShaderStageFlags,
    kind: types.DescriptorKind,
    slot: u32,
    value: ?BoundValue,
) Error!void {
    switch (bind_point) {
        .graphics => {
            if (stages.vertex) try self.applyDescriptorStage(
                .vertex,
                kind,
                slot,
                value,
            );
            if (stages.fragment) try self.applyDescriptorStage(
                .fragment,
                kind,
                slot,
                value,
            );
        },
        .compute => {
            if (stages.compute) try self.applyDescriptorStage(
                .compute,
                kind,
                slot,
                value,
            );
        },
    }
}

const Stage = enum { vertex, fragment, compute };

fn applyDescriptorStage(
    self: *Dx3d11,
    stage: Stage,
    kind: types.DescriptorKind,
    slot: u32,
    value: ?BoundValue,
) Error!void {
    var buffer: ?*win.ID3D11Buffer = null;
    var srv: ?*win.ID3D11ShaderResourceView = null;
    var sampler: ?*win.ID3D11SamplerState = null;
    if (value) |present| {
        switch (present.kind) {
            .buffer => |buffer_value| {
                if (buffer_value.offset != 0) {
                    return error.Unsupported;
                }
                buffer = buffer_value.resource;
            },
            .texture => |texture| {
                srv = texture.srv;
                sampler = texture.sampler;
            },
            .sampler => |sampler_value| sampler = sampler_value,
        }
    }

    switch (kind) {
        .uniform_buffer => {
            if (slot >= 14) return error.Unsupported;
            switch (stage) {
                .vertex => self.context.vSSetConstantBuffers(
                    slot,
                    1,
                    @ptrCast(&buffer),
                ),
                .fragment => self.context.pSSetConstantBuffers(
                    slot,
                    1,
                    @ptrCast(&buffer),
                ),
                .compute => self.context.cSSetConstantBuffers(
                    slot,
                    1,
                    @ptrCast(&buffer),
                ),
            }
        },
        .storage_buffer => {
            if (slot >= 128) return error.Unsupported;
            switch (stage) {
                .vertex => self.context.vSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
                .fragment => self.context.pSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
                .compute => self.context.cSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
            }
        },
        .sampled_texture, .storage_texture, .combined_image_sampler => {
            if (slot >= 128) return error.Unsupported;
            switch (stage) {
                .vertex => self.context.vSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
                .fragment => self.context.pSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
                .compute => self.context.cSSetShaderResources(
                    slot,
                    1,
                    @ptrCast(&srv),
                ),
            }
            if (kind == .combined_image_sampler) {
                if (slot >= 16) return error.Unsupported;
                switch (stage) {
                    .vertex => self.context.vSSetSamplers(
                        slot,
                        1,
                        @ptrCast(&sampler),
                    ),
                    .fragment => self.context.pSSetSamplers(
                        slot,
                        1,
                        @ptrCast(&sampler),
                    ),
                    .compute => self.context.cSSetSamplers(
                        slot,
                        1,
                        @ptrCast(&sampler),
                    ),
                }
            }
        },
        .sampler => {
            if (slot >= 16) return error.Unsupported;
            switch (stage) {
                .vertex => self.context.vSSetSamplers(
                    slot,
                    1,
                    @ptrCast(&sampler),
                ),
                .fragment => self.context.pSSetSamplers(
                    slot,
                    1,
                    @ptrCast(&sampler),
                ),
                .compute => self.context.cSSetSamplers(
                    slot,
                    1,
                    @ptrCast(&sampler),
                ),
            }
        },
    }
}

fn pushConstants(
    self: *Dx3d11,
    value: commands.PushConstants,
) Error!void {
    const layout_slot = try self.lookup(
        value.layout,
        .pipeline_layout,
    );
    const layout = &layout_slot.handle.pipeline_layout;
    const buffer = layout.push_buffer orelse
        return error.InvalidDescription;
    const end = @as(u64, value.offset) + value.data.len;
    if (end > layout.push_shadow.len) {
        return error.InvalidDescription;
    }
    @memcpy(
        layout.push_shadow[value.offset..][0..value.data.len],
        value.data,
    );
    self.context.updateSubresource(
        @ptrCast(buffer),
        0,
        null,
        @ptrCast(layout.push_shadow.ptr),
        0,
        0,
    );
    const slot: u32 = 13;
    if (value.stages.vertex) {
        self.context.vSSetConstantBuffers(
            slot,
            1,
            @ptrCast(&buffer),
        );
    }
    if (value.stages.fragment) {
        self.context.pSSetConstantBuffers(
            slot,
            1,
            @ptrCast(&buffer),
        );
    }
    if (value.stages.compute) {
        self.context.cSSetConstantBuffers(
            slot,
            1,
            @ptrCast(&buffer),
        );
    }
}

fn copyBufferToTexture(
    self: *Dx3d11,
    value: commands.CopyBufferToTexture,
) Error!void {
    const buffer_slot = try self.lookup(value.buffer, .buffer);
    const texture_slot = try self.lookup(value.texture, .texture);
    const buffer = &buffer_slot.handle.buffer;
    if (!buffer.host_visible) return error.Unsupported;
    const staging = buffer.staging orelse return error.Unsupported;
    self.context.copyResource(
        @ptrCast(staging),
        @ptrCast(buffer.resource),
    );
    var mapped = std.mem.zeroes(win.D3D11_MAPPED_SUBRESOURCE);
    const hr = self.context.map(
        @ptrCast(staging),
        0,
        win.D3D11_MAP_READ,
        0,
        &mapped,
    );
    if (win.failed(hr) or mapped.data == null) {
        return mapError(hr);
    }
    defer self.context.unmap(@ptrCast(staging), 0);

    const region = value.region;
    const properties = texture_slot.handle.texture.properties;
    if (region.mip_level >= properties.mip_levels or
        region.array_layer >= properties.array_layers)
    {
        return error.InvalidDescription;
    }
    const subresource = region.mip_level +
        region.array_layer * properties.mip_levels;
    const data: [*]const u8 = @ptrCast(mapped.data.?);
    const source = data + @as(usize, @intCast(value.buffer_offset));
    var box = std.mem.zeroes(win.D3D11_BOX);
    box.left = region.offset.x;
    box.top = region.offset.y;
    box.front = region.offset.z;
    box.right = region.offset.x + region.extent.width;
    box.bottom = region.offset.y + region.extent.height;
    box.back = region.offset.z + region.extent.depth;
    self.context.updateSubresource(
        texture_slot.handle.texture.resource,
        subresource,
        &box,
        source,
        if (value.row_pitch == 0)
            @intCast(@as(u64, region.extent.width) *
                (properties.format.bytesPerPixel() orelse
                    return error.InvalidDescription))
        else
            value.row_pitch,
        if (value.image_height == 0)
            0
        else
            value.image_height,
    );
}

fn deviceOpi(
    self: *Dx3d11,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    _ = output_mode;
    _ = ret_addr;
    switch (operator) {
        .wait_idle => {
            self.context.flush();
            return null;
        },
        .wait_fence => |value| {
            const slot = try self.lookup(value.fence, .fence);
            try waitFence(slot.handle.fence, value.timeout_ns);
            return null;
        },
        .reset_fence => |value| {
            const slot = try self.lookup(value.fence, .fence);
            slot.handle.fence.signaled = false;
            return null;
        },
        .write_descriptor_set => |value| {
            try self.writeDescriptorSet(value.set, value.writes);
            return null;
        },
    }
}

fn waitFence(fence: FenceState, timeout_ns: u64) Error!void {
    var remaining_ms: u64 = if (timeout_ns == std.math.maxInt(u64))
        std.math.maxInt(u64) - 1
    else
        timeout_ns / 1_000_000;
    while (!fence.signaled) {
        if (remaining_ms == 0 and
            timeout_ns != std.math.maxInt(u64))
        {
            return error.Timeout;
        }
        win.Sleep(1);
        if (remaining_ms != std.math.maxInt(u64) - 1) {
            remaining_ms -|= 1;
        }
    }
}

fn writeDescriptorSet(
    self: *Dx3d11,
    set_resource: Resource,
    writes: []const types.DescriptorWrite,
) Error!void {
    const set_slot = try self.lookup(set_resource, .descriptor_set);
    const layout_slot = try self.lookup(
        set_slot.handle.descriptor_set.layout,
        .descriptor_set_layout,
    );
    for (writes) |write| {
        const binding = findBinding(
            layout_slot.handle.descriptor_set_layout.bindings,
            write.binding,
        ) orelse return error.InvalidDescription;
        if (write.array_index >= binding.count) {
            return error.InvalidDescription;
        }
        var value: BoundValue = .{
            .binding = write.binding,
            .array_index = write.array_index,
            .kind = undefined,
        };
        switch (write.kind) {
            .buffer => |buffer_write| {
                if (binding.kind != .uniform_buffer and
                    binding.kind != .storage_buffer)
                {
                    return error.InvalidDescription;
                }
                const buffer_slot = try self.lookup(
                    buffer_write.buffer,
                    .buffer,
                );
                value.kind = .{ .buffer = .{
                    .resource = buffer_slot.handle.buffer.resource,
                    .offset = buffer_write.offset,
                    .size = buffer_write.size,
                } };
            },
            .texture => |texture_write| {
                if (binding.kind != .sampled_texture and
                    binding.kind != .storage_texture and
                    binding.kind != .combined_image_sampler)
                {
                    return error.InvalidDescription;
                }
                const view_slot = try self.lookup(
                    texture_write.view,
                    .texture_view,
                );
                var sampler: ?*win.ID3D11SamplerState = null;
                if (texture_write.sampler) |sampler_resource| {
                    const sampler_slot = try self.lookup(
                        sampler_resource,
                        .sampler,
                    );
                    sampler = sampler_slot.handle.sampler;
                }
                if (binding.kind == .combined_image_sampler and
                    sampler == null)
                {
                    return error.InvalidDescription;
                }
                value.kind = .{ .texture = .{
                    .srv = view_slot.handle.texture_view.srv,
                    .sampler = sampler,
                } };
            },
            .sampler => |sampler_resource| {
                if (binding.kind != .sampler) {
                    return error.InvalidDescription;
                }
                const sampler_slot = try self.lookup(
                    sampler_resource,
                    .sampler,
                );
                value.kind = .{ .sampler = sampler_slot.handle.sampler };
            },
        }
        var replaced = false;
        for (set_slot.handle.descriptor_set.values) |*entry| {
            if (entry.*) |present| {
                if (present.binding == write.binding and
                    present.array_index == write.array_index)
                {
                    entry.* = value;
                    replaced = true;
                    break;
                }
            }
        }
        if (!replaced) {
            for (set_slot.handle.descriptor_set.values) |*entry| {
                if (entry.* == null) {
                    entry.* = value;
                    replaced = true;
                    break;
                }
            }
        }
        if (!replaced) return error.OutOfDeviceMemory;
    }
}

fn query(
    self: *Dx3d11,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!Device.QueryResult {
    _ = ret_addr;
    return switch (feature) {
        .api_version => writeFixed(
            output_mode,
            Version.make(0, 11, 0, 0),
        ),
        .device_name => .{
            .support = .support,
            .result = try writeBytes(
                output_mode,
                "Direct3D 11 device",
            ),
        },
        .driver_name => .{
            .support = .support,
            .result = try writeBytes(
                output_mode,
                "Direct3D 11",
            ),
        },
        .device_type => writeFixed(
            output_mode,
            Device.DeviceType.discrete_gpu,
        ),
        .limit => |limit| writeFixed(
            output_mode,
            @as(u64, switch (limit) {
                .max_texture_dimension_1d => 16384,
                .max_texture_dimension_2d => 16384,
                .max_texture_dimension_3d => 2048,
                .max_texture_array_layers => 2048,
                .max_buffer_size => 1 << 30,
                .max_uniform_buffer_range => 65536,
                .max_storage_buffer_range => 1 << 28,
                .max_push_constant_size => 256,
                .max_vertex_bindings => 32,
                .max_vertex_attributes => 32,
                .max_descriptor_sets => 8,
                .max_color_attachments => 8,
            }),
        ),
        .format => |value| blk: {
            const format = toDxgiFormat(value.format) orelse
                break :blk .{ .support = .unsupport };
            var support: u32 = 0;
            const hr = self.device.checkFormatSupport(
                format,
                &support,
            );
            if (win.failed(hr)) {
                break :blk .{ .support = .unsupport };
            }
            const wanted = value.usage;
            const supported =
                (!wanted.sampled or
                    support & win.D3D11_FORMAT_SUPPORT_SHADER_SAMPLE != 0) and
                (!wanted.storage or
                    support & win.D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW != 0) and
                (!wanted.color_attachment or
                    support & win.D3D11_FORMAT_SUPPORT_RENDER_TARGET != 0) and
                (!wanted.depth_attachment or
                    support & win.D3D11_FORMAT_SUPPORT_DEPTH_STENCIL != 0) and
                (!wanted.buffer or
                    support & win.D3D11_FORMAT_SUPPORT_BUFFER != 0);
            break :blk .{
                .support = if (supported) .support else .unsupport,
            };
        },
        .surface => blk: {
            const resource = handle orelse
                return error.InvalidDescription;
            const slot = try self.lookup(resource, .surface);
            const properties: types.SurfaceProperties = .{
                .min_width = 1,
                .min_height = 1,
                .max_width = 16384,
                .max_height = 16384,
                .current_width = slot.handle.surface.width,
                .current_height = slot.handle.surface.height,
                .format_count = 1,
            };
            break :blk writeFixed(output_mode, properties);
        },
        .swapchain => blk: {
            const resource = handle orelse
                return error.InvalidDescription;
            const slot = try self.lookup(resource, .swapchain);
            break :blk writeFixed(
                output_mode,
                slot.handle.swapchain.properties,
            );
        },
        .swapchain_images => self.writeResourceList(
            handle,
            output_mode,
            true,
        ),
        .swapchain_views => self.writeResourceList(
            handle,
            output_mode,
            false,
        ),
        .buffer => blk: {
            const resource = handle orelse
                return error.InvalidDescription;
            const slot = try self.lookup(resource, .buffer);
            const properties: types.BufferProperties = .{
                .size = slot.handle.buffer.size,
                .memory = slot.handle.buffer.hints,
            };
            break :blk writeFixed(output_mode, properties);
        },
        .texture => blk: {
            const resource = handle orelse
                return error.InvalidDescription;
            const slot = try self.lookup(resource, .texture);
            break :blk writeFixed(
                output_mode,
                slot.handle.texture.properties,
            );
        },
        .memory => blk: {
            if (feature_index != 0) {
                break :blk .{ .support = .unsupport };
            }
            break :blk writeFixed(output_mode, types.MemoryHeap{
                .size = 0,
                .device_local = true,
            });
        },
        .queue => blk: {
            if (feature_index != 0) {
                break :blk .{ .support = .unsupport };
            }
            break :blk writeFixed(output_mode, types.QueueProperties{
                .capabilities = .{
                    .graphics = true,
                    .compute = true,
                    .transfer = true,
                    .present = true,
                },
                .count = 1,
                .timestamp_bits = 64,
            });
        },
    };
}

fn writeResourceList(
    self: *Dx3d11,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    images: bool,
) Error!Device.QueryResult {
    const resource = handle orelse return error.InvalidDescription;
    const slot = try self.lookup(resource, .swapchain);
    const list = if (images)
        slot.handle.swapchain.images
    else
        slot.handle.swapchain.views;
    const mode = output_mode orelse
        return .{ .support = .unsupport };
    return switch (mode) {
        .slice => |slice| blk: {
            const bytes = std.mem.sliceAsBytes(list);
            if (slice.len < bytes.len) {
                return error.BufferTooSmall;
            }
            @memcpy(slice[0..bytes.len], bytes);
            break :blk .{
                .support = .support,
                .result = slice[0..bytes.len],
            };
        },
        .allocator => error.Unsupported,
    };
}

fn writeFixed(
    output_mode: ?Device.OutputMode,
    value: anytype,
) Error!Device.QueryResult {
    const bytes = std.mem.asBytes(&value);
    const result = try writeBytes(output_mode, bytes);
    return .{ .support = .support, .result = result };
}

fn writeBytes(
    output_mode: ?Device.OutputMode,
    bytes: []const u8,
) Error!?[]const u8 {
    const mode = output_mode orelse return null;
    return switch (mode) {
        .slice => |slice| blk: {
            if (slice.len < bytes.len) return error.BufferTooSmall;
            @memcpy(slice[0..bytes.len], bytes);
            break :blk slice[0..bytes.len];
        },
        .allocator => |allocator| blk: {
            const result = allocator.dupe(
                u8,
                bytes,
            ) catch return error.OutOfHostMemory;
            break :blk @as(?[]const u8, result);
        },
    };
}

fn findBinding(
    bindings: []const types.DescriptorSetLayoutDescription
        .DescriptorBinding,
    binding: u32,
) ?types.DescriptorSetLayoutDescription.DescriptorBinding {
    for (bindings) |candidate| {
        if (candidate.binding == binding) return candidate;
    }
    return null;
}

fn alignForward(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) / alignment * alignment;
}

fn mapError(hr: win.HRESULT) Error {
    return switch (hr) {
        win.E_OUTOFMEMORY => error.OutOfHostMemory,
        win.DXGI_ERROR_DEVICE_REMOVED,
        win.DXGI_ERROR_DEVICE_RESET,
        => error.DeviceLost,
        win.DXGI_ERROR_UNSUPPORTED => error.Unsupported,
        win.E_INVALIDARG => error.InvalidDescription,
        else => error.Unknown,
    };
}

fn toDxgiFormat(format: types.Format) ?u32 {
    return switch (format) {
        .r8_unorm => win.DXGI_FORMAT_R8_UNORM,
        .r8g8_unorm => win.DXGI_FORMAT_R8G8_UNORM,
        .r8g8b8a8_unorm => win.DXGI_FORMAT_R8G8B8A8_UNORM,
        .r8g8b8a8_srgb => win.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        .b8g8r8a8_unorm => win.DXGI_FORMAT_B8G8R8A8_UNORM,
        .b8g8r8a8_srgb => win.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        .r16_float => win.DXGI_FORMAT_R16_FLOAT,
        .r16g16_float => win.DXGI_FORMAT_R16G16_FLOAT,
        .r16g16b16a16_float => win.DXGI_FORMAT_R16G16B16A16_FLOAT,
        .r32_float => win.DXGI_FORMAT_R32_FLOAT,
        .r32g32_float => win.DXGI_FORMAT_R32G32_FLOAT,
        .r32g32b32_float => win.DXGI_FORMAT_R32G32B32_FLOAT,
        .r32g32b32a32_float => win.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .r32_uint => win.DXGI_FORMAT_R32_UINT,
        .r32g32_uint => win.DXGI_FORMAT_R32G32_UINT,
        .r32g32b32_uint => win.DXGI_FORMAT_R32G32B32_UINT,
        .r32g32b32a32_uint => win.DXGI_FORMAT_R32G32B32A32_UINT,
        .d32_float => win.DXGI_FORMAT_D32_FLOAT,
        .d24_unorm_s8_uint => win.DXGI_FORMAT_D24_UNORM_S8_UINT,
        .undefined => null,
    };
}

fn toBindFlags(usage: types.BufferUsage) u32 {
    var flags: u32 = 0;
    if (usage.vertex) flags |= win.D3D11_BIND_VERTEX_BUFFER;
    if (usage.index) flags |= win.D3D11_BIND_INDEX_BUFFER;
    if (usage.uniform) flags |= win.D3D11_BIND_CONSTANT_BUFFER;
    if (usage.storage) flags |= win.D3D11_BIND_UNORDERED_ACCESS;
    if (usage.storage) flags |= win.D3D11_BIND_SHADER_RESOURCE;
    if (usage.transfer_src or usage.transfer_dst) {
        flags |= win.D3D11_BIND_SHADER_RESOURCE;
    }
    return flags;
}

fn toTextureBindFlags(usage: types.TextureUsage) u32 {
    var flags: u32 = 0;
    if (usage.sampled) flags |= win.D3D11_BIND_SHADER_RESOURCE;
    if (usage.storage) flags |= win.D3D11_BIND_UNORDERED_ACCESS;
    if (usage.color_attachment) flags |= win.D3D11_BIND_RENDER_TARGET;
    if (usage.depth_attachment) flags |= win.D3D11_BIND_DEPTH_STENCIL;
    return flags;
}

fn toD3D11Filter(value: types.SamplerDescription) u32 {
    if (value.anisotropy > 1) return win.D3D11_FILTER_ANISOTROPIC;
    const min: u32 = if (value.min_filter == .linear) 0x10 else 0;
    const mag: u32 = if (value.mag_filter == .linear) 0x4 else 0;
    const mip: u32 = if (value.mipmap == .linear) 0x1 else 0;
    return min | mag | mip;
}

fn toD3D11Address(mode: types.AddressMode) u32 {
    return switch (mode) {
        .repeat => win.D3D11_TEXTURE_ADDRESS_WRAP,
        .mirrored_repeat => win.D3D11_TEXTURE_ADDRESS_MIRROR,
        .clamp_to_edge => win.D3D11_TEXTURE_ADDRESS_CLAMP,
        .clamp_to_border => win.D3D11_TEXTURE_ADDRESS_BORDER,
    };
}

fn toD3D11Compare(op: types.CompareOp) u32 {
    return switch (op) {
        .never => win.D3D11_COMPARISON_NEVER,
        .less => win.D3D11_COMPARISON_LESS,
        .equal => win.D3D11_COMPARISON_EQUAL,
        .less_equal => win.D3D11_COMPARISON_LESS_EQUAL,
        .greater => win.D3D11_COMPARISON_GREATER,
        .not_equal => win.D3D11_COMPARISON_NOT_EQUAL,
        .greater_equal => win.D3D11_COMPARISON_GREATER_EQUAL,
        .always => win.D3D11_COMPARISON_ALWAYS,
    };
}

fn toD3D11Blend(factor: types.BlendFactor) u32 {
    return switch (factor) {
        .zero => win.D3D11_BLEND_ZERO,
        .one => win.D3D11_BLEND_ONE,
        .src_color => win.D3D11_BLEND_SRC_COLOR,
        .one_minus_src_color => win.D3D11_BLEND_INV_SRC_COLOR,
        .dst_color => win.D3D11_BLEND_DEST_COLOR,
        .one_minus_dst_color => win.D3D11_BLEND_INV_DEST_COLOR,
        .src_alpha => win.D3D11_BLEND_SRC_ALPHA,
        .one_minus_src_alpha => win.D3D11_BLEND_INV_SRC_ALPHA,
        .dst_alpha => win.D3D11_BLEND_DEST_ALPHA,
        .one_minus_dst_alpha => win.D3D11_BLEND_INV_DEST_ALPHA,
        .constant_color => win.D3D11_BLEND_BLEND_FACTOR,
        .one_minus_constant_color => win.D3D11_BLEND_INV_BLEND_FACTOR,
        .constant_alpha => win.D3D11_BLEND_BLEND_FACTOR,
        .one_minus_constant_alpha => win.D3D11_BLEND_INV_BLEND_FACTOR,
    };
}

fn toD3D11BlendOp(op: types.BlendOp) u32 {
    return switch (op) {
        .add => win.D3D11_BLEND_OP_ADD,
        .subtract => win.D3D11_BLEND_OP_SUBTRACT,
        .reverse_subtract => win.D3D11_BLEND_OP_REV_SUBTRACT,
        .min => win.D3D11_BLEND_OP_MIN,
        .max => win.D3D11_BLEND_OP_MAX,
    };
}

fn toD3D11Cull(cull: types.CullMode) u32 {
    return switch (cull) {
        .none => win.D3D11_CULL_NONE,
        .front => win.D3D11_CULL_FRONT,
        .back => win.D3D11_CULL_BACK,
        .front_and_back => win.D3D11_CULL_BACK,
    };
}

fn toD3D11Topology(topology: types.Topology) u32 {
    return switch (topology) {
        .point_list => win.D3D_PRIMITIVE_TOPOLOGY_POINTLIST,
        .line_list => win.D3D_PRIMITIVE_TOPOLOGY_LINELIST,
        .line_strip => win.D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,
        .triangle_list => win.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
        .triangle_strip => win.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        .triangle_fan => win.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    };
}

const device_vtable: Device.VTable = .{
    .create = deviceCreate,
    .destroy = deviceDestroy,
    .create_batch = deviceCreateBatch,
    .destroy_batch = deviceDestroyBatch,
    .map = deviceMap,
    .unmap = deviceUnmap,
    .get_queue = deviceGetQueue,
    .record = deviceRecord,
    .device_op = deviceOp,
    .query = deviceQuery,
};

const queue_vtable: Queue.VTable = .{
    .acquire = queueAcquire,
    .submit = queueSubmit,
    .present = queuePresent,
    .wait_idle = queueWaitIdle,
};

fn backend(vptr: *anyopaque) *Dx3d11 {
    return @ptrCast(@alignCast(vptr));
}

fn deviceCreate(
    vptr: *anyopaque,
    description: Resource.Description,
    ret_addr: usize,
) Error!Resource {
    return backend(vptr).createResource(description, ret_addr);
}

fn deviceDestroy(
    vptr: *anyopaque,
    resource: Resource,
    ret_addr: usize,
) void {
    log.debug(
        "destroy {s} index={d} (ret 0x{x})",
        .{
            @tagName(resource.tag),
            resource.identifier.index,
            ret_addr,
        },
    );
    backend(vptr).destroyResource(resource);
}

fn deviceCreateBatch(
    vptr: *anyopaque,
    descriptions: []const Resource.Description,
    resources: []Resource,
    ret_addr: usize,
) Error!void {
    return backend(vptr).createBatch(
        descriptions,
        resources,
        ret_addr,
    );
}

fn deviceDestroyBatch(
    vptr: *anyopaque,
    resources: []const Resource,
    ret_addr: usize,
) void {
    log.debug(
        "destroy {d} resource(s) (ret 0x{x})",
        .{ resources.len, ret_addr },
    );
    const self = backend(vptr);
    for (resources) |resource| {
        self.destroyResource(resource);
    }
}

fn deviceMap(
    vptr: *anyopaque,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    return backend(vptr).map(resource, offset, size, ret_addr);
}

fn deviceUnmap(
    vptr: *anyopaque,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    backend(vptr).unmap(resource, dirty, ret_addr);
}

fn deviceGetQueue(
    vptr: *anyopaque,
    index: u32,
    ret_addr: usize,
) Error!Queue {
    return backend(vptr).getQueue(index, ret_addr);
}

fn deviceRecord(
    vptr: *anyopaque,
    resource: Resource,
    command: commands.Command,
    ret_addr: usize,
) Error!void {
    return backend(vptr).record(resource, command, ret_addr);
}

fn deviceOp(
    vptr: *anyopaque,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    return backend(vptr).deviceOpi(operator, output_mode, ret_addr);
}

fn deviceQuery(
    vptr: *anyopaque,
    feature: Device.Feature,
    feature_index: u32,
    handle: ?Resource,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!Device.QueryResult {
    return backend(vptr).query(
        feature,
        feature_index,
        handle,
        output_mode,
        ret_addr,
    );
}

fn queueIndex(family_index: u32, queue_index: u32) Error!void {
    if (family_index != 0 or queue_index != 0) {
        return error.InvalidResource;
    }
}

fn queueAcquire(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Acquire,
    ret_addr: usize,
) Error!Queue.Acquired {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(family_index, queue_index);
    const slot = try self.lookup(description.swapchain, .swapchain);
    const swapchain = &slot.handle.swapchain;
    if (swapchain.properties.image_count == 0) {
        return error.InvalidDescription;
    }
    const index = swapchain.next_index %
        swapchain.properties.image_count;
    swapchain.next_index +%= 1;
    return .{ .image_index = index };
}

fn queueSubmit(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    submission: Queue.Submission,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(family_index, queue_index);
    for (submission.command_buffers) |resource| {
        const slot = try self.lookup(resource, .command_buffer);
        if (slot.handle.command_buffer.state != .ended) {
            return error.InvalidResource;
        }
        slot.handle.command_buffer.state = .submitted;
    }
    if (submission.fence) |fence_resource| {
        const slot = try self.lookup(fence_resource, .fence);
        slot.handle.fence.signaled = true;
    }
}

fn queuePresent(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    description: Queue.Present,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(family_index, queue_index);
    const slot = try self.lookup(description.swapchain, .swapchain);
    const swapchain = &slot.handle.swapchain;
    const handle = swapchain.handle orelse return;
    const sync_interval: u32 = switch (swapchain.present_mode) {
        .immediate => 0,
        .mailbox, .fifo, .fifo_relaxed => 1,
    };
    const hr = handle.present(sync_interval, 0);
    if (win.failed(hr)) return mapError(hr);
}

fn queueWaitIdle(
    vptr: *anyopaque,
    family_index: u32,
    queue_index: u32,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const self = backend(vptr);
    try queueIndex(family_index, queue_index);
    self.context.flush();
}
