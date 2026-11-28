//! A Direct3D 12 backend for vfrhi.
//!
//! The backend owns a D3D12 device, a direct command queue, the
//! shader-visible descriptor heaps, and every RHI resource created
//! through it. SPIR-V shaders are decompiled to HLSL and compiled with
//! the system D3DCompiler at runtime.
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
const log = std.log.scoped(.dx3d12);
const Dx3d12 = @This();

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("The Direct3D 12 backend is only available on Windows.");
    }
}

/// The API version type used by this backend.
pub const Version = rhi.Version;

/// Creation parameters of a Direct3D 12 backend.
pub const Desc = struct {};

const HEAP_SHADER_DESCRIPTORS: u32 = 4096;
const HEAP_SAMPLER_DESCRIPTORS: u32 = 256;
const HEAP_RTV_DESCRIPTORS: u32 = 256;
const HEAP_DSV_DESCRIPTORS: u32 = 64;

const DescriptorHeap = struct {
    handle: *win.ID3D12DescriptorHeap,
    increment: u32,
    cpu_start: win.D3D12_CPU_DESCRIPTOR_HANDLE,
    gpu_start: win.D3D12_GPU_DESCRIPTOR_HANDLE,
    capacity: u32,
    used: std.DynamicBitSetUnmanaged,
    visible: bool,

    fn init(
        allocator: Allocator,
        device: *win.ID3D12Device,
        heap_type: u32,
        capacity: u32,
        visible: bool,
    ) Error!DescriptorHeap {
        var desc = std.mem.zeroes(win.D3D12_DESCRIPTOR_HEAP_DESC);
        desc.type = heap_type;
        desc.num_descriptors = capacity;
        desc.flags = if (visible)
            win.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE
        else
            win.D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        desc.node_mask = 0;
        var raw: ?*anyopaque = null;
        const hr = device.createDescriptorHeap(
            &desc,
            &win.IID_ID3D12DescriptorHeap,
            &raw,
        );
        if (win.failed(hr) or raw == null) return mapError(hr);
        const handle: *win.ID3D12DescriptorHeap = @ptrCast(@alignCast(
            raw.?,
        ));
        errdefer _ = handle.release();
        const used = std.DynamicBitSetUnmanaged.initEmpty(
            allocator,
            capacity,
        ) catch return error.OutOfHostMemory;
        var cpu_start = win.D3D12_CPU_DESCRIPTOR_HANDLE{ .ptr = 0 };
        handle.getCPUDescriptorHandleForHeapStart(&cpu_start);
        var gpu_start = win.D3D12_GPU_DESCRIPTOR_HANDLE{ .ptr = 0 };
        if (visible) {
            handle.getGPUDescriptorHandleForHeapStart(&gpu_start);
        }
        return .{
            .handle = handle,
            .increment = device.getDescriptorHandleIncrementSize(
                heap_type,
            ),
            .cpu_start = cpu_start,
            .gpu_start = gpu_start,
            .capacity = capacity,
            .used = used,
            .visible = visible,
        };
    }

    fn deinit(self: *DescriptorHeap, allocator: Allocator) void {
        self.used.deinit(allocator);
        _ = self.handle.release();
    }

    fn alloc(self: *DescriptorHeap, count: u32) ?u32 {
        if (count == 0) return null;
        var start: u32 = 0;
        while (start + count <= self.capacity) : (start += 1) {
            var index = start;
            while (index < start + count) : (index += 1) {
                if (self.used.isSet(index)) break;
            } else {
                index = start;
                while (index < start + count) : (index += 1) {
                    self.used.set(index);
                }
                return start;
            }
        }
        return null;
    }

    fn free(self: *DescriptorHeap, start: u32, count: u32) void {
        var index = start;
        while (index < start + count and index < self.capacity) : (index += 1) {
            self.used.unset(index);
        }
    }

    fn cpu(self: DescriptorHeap, index: u32) win.D3D12_CPU_DESCRIPTOR_HANDLE {
        return .{
            .ptr = self.cpu_start.ptr + @as(usize, index) * self.increment,
        };
    }

    fn gpu(self: DescriptorHeap, index: u32) win.D3D12_GPU_DESCRIPTOR_HANDLE {
        return .{
            .ptr = self.gpu_start.ptr + @as(u64, index) * self.increment,
        };
    }
};

const BufferState = struct {
    resource: *win.ID3D12Resource,
    size: u64,
    gpu_va: u64,
    hints: types.Memory,
    usage: types.BufferUsage,
    host_visible: bool,
    mapped: bool = false,
    state: u32,
};

const TextureState = struct {
    resource: *win.ID3D12Resource,
    properties: types.TextureProperties,
    state: u32,
};

const TextureViewState = struct {
    srv: ?u32 = null,
    uav: ?u32 = null,
    rtv: ?u32 = null,
    dsv: ?u32 = null,
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
    handle3: ?*win.IDXGISwapChain3,
    surface: Resource,
    properties: types.SwapchainProperties,
    images: []Resource,
    views: []Resource,
    headless: bool,
    next_index: u32 = 0,
    present_mode: types.PresentMode,
};

const ShaderState = struct {
    stage: types.ShaderStage,
    bytecode: []u8,

    fn bytes(self: ShaderState) win.D3D12_SHADER_BYTECODE {
        return .{
            .shader_bytecode = self.bytecode.ptr,
            .bytecode_length = self.bytecode.len,
        };
    }
};

const DescriptorSetLayoutState = struct {
    bindings: []types.DescriptorSetLayoutDescription.DescriptorBinding,
};

const SetRootParams = struct {
    shader: ?u32 = null,
    sampler: ?u32 = null,
};

const PipelineLayoutState = struct {
    descriptor_sets: []Resource,
    push_constants: []types.PipelineLayoutDescription.PushConstant,
    root_signature: *win.ID3D12RootSignature,
    set_params: []SetRootParams,
    push_param: ?u32 = null,
    push_size: u32 = 0,
};

const DescriptorSetState = struct {
    layout: Resource,
    shader_start: u32 = 0,
    shader_count: u32 = 0,
    sampler_start: u32 = 0,
    sampler_count: u32 = 0,
};

const PipelineState = struct {
    bind_point: types.BindPoint,
    layout: Resource,
    root_signature: *win.ID3D12RootSignature,
    pso: *win.ID3D12PipelineState,
    topology: u32 = win.D3D12_PRIMITIVE_TOPOLOGY_UNDEFINED,
    strides: []u32 = &.{},
};

const CommandBufferState = struct {
    allocator: *win.ID3D12CommandAllocator,
    list: *win.ID3D12GraphicsCommandList,
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
    fence: *win.ID3D12Fence,
    value: u64,
    pending: bool,
};

const SemaphoreState = struct {};

const Handle = union(Resource.Tag) {
    surface: SurfaceState,
    swapchain: SwapchainState,
    buffer: BufferState,
    texture: TextureState,
    texture_view: TextureViewState,
    sampler: u32,
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
device: *win.ID3D12Device,
queue: *win.ID3D12CommandQueue,
factory: *win.IDXGIFactory2,

shader_heap: DescriptorHeap,
sampler_heap: DescriptorHeap,
rtv_heap: DescriptorHeap,
dsv_heap: DescriptorHeap,

upload_allocator: *win.ID3D12CommandAllocator,
upload_list: *win.ID3D12GraphicsCommandList,
upload_fence: *win.ID3D12Fence,
upload_value: u64 = 0,

slots: std.ArrayListUnmanaged(?Slot) = .empty,
generations: std.ArrayListUnmanaged(u32) = .empty,
free_slots: std.ArrayListUnmanaged(u32) = .empty,
live_count: usize = 0,

/// Creates a Direct3D 12 device and a direction command queue.
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
/// - `error.InitializationFailed`: no Direct3D 12 device or DXGI
///   factory can be created.
///
/// # Note
/// Destroy every RHI resource before calling `deinit`.
pub fn init(allocator: Allocator, description: Desc) !*Dx3d12 {
    _ = description;
    log.debug("Creating Direct3D 12 backend", .{});
    errdefer log.warn("Direct3D 12 backend creation failed", .{});

    var device_raw: ?*anyopaque = null;
    const device_hr = win.D3D12CreateDevice(
        null,
        win.D3D_FEATURE_LEVEL_11_0,
        &win.IID_ID3D12Device,
        &device_raw,
    );
    if (win.failed(device_hr) or device_raw == null) {
        log.warn("D3D12CreateDevice failed: 0x{x}", .{
            @as(u32, @bitCast(device_hr)),
        });
        return error.InitializationFailed;
    }
    const device: *win.ID3D12Device = @ptrCast(@alignCast(device_raw.?));
    errdefer _ = device.release();

    var queue_desc = std.mem.zeroes(win.D3D12_COMMAND_QUEUE_DESC);
    queue_desc.type = win.D3D12_COMMAND_LIST_TYPE_DIRECT;
    queue_desc.priority = 0;
    queue_desc.flags = 0;
    queue_desc.node_mask = 0;
    var queue_raw: ?*anyopaque = null;
    const queue_hr = device.createCommandQueue(
        &queue_desc,
        &win.IID_ID3D12CommandQueue,
        &queue_raw,
    );
    if (win.failed(queue_hr) or queue_raw == null) {
        return mapError(queue_hr);
    }
    const queue: *win.ID3D12CommandQueue = @ptrCast(@alignCast(
        queue_raw.?,
    ));
    errdefer _ = queue.release();

    var factory_raw: ?*anyopaque = null;
    const factory_hr = win.CreateDXGIFactory2(
        0,
        &win.IID_IDXGIFactory2,
        &factory_raw,
    );
    if (win.failed(factory_hr) or factory_raw == null) {
        return error.InitializationFailed;
    }
    const factory: *win.IDXGIFactory2 = @ptrCast(@alignCast(
        factory_raw.?,
    ));
    errdefer _ = factory.release();

    var shader_heap = try DescriptorHeap.init(
        allocator,
        device,
        win.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
        HEAP_SHADER_DESCRIPTORS,
        true,
    );
    errdefer shader_heap.deinit(allocator);
    var sampler_heap = try DescriptorHeap.init(
        allocator,
        device,
        win.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
        HEAP_SAMPLER_DESCRIPTORS,
        true,
    );
    errdefer sampler_heap.deinit(allocator);
    var rtv_heap = try DescriptorHeap.init(
        allocator,
        device,
        win.D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
        HEAP_RTV_DESCRIPTORS,
        false,
    );
    errdefer rtv_heap.deinit(allocator);
    var dsv_heap = try DescriptorHeap.init(
        allocator,
        device,
        win.D3D12_DESCRIPTOR_HEAP_TYPE_DSV,
        HEAP_DSV_DESCRIPTORS,
        false,
    );
    errdefer dsv_heap.deinit(allocator);

    var upload_allocator_raw: ?*anyopaque = null;
    var upload_hr = device.createCommandAllocator(
        win.D3D12_COMMAND_LIST_TYPE_DIRECT,
        &win.IID_ID3D12CommandAllocator,
        &upload_allocator_raw,
    );
    if (win.failed(upload_hr) or upload_allocator_raw == null) {
        return mapError(upload_hr);
    }
    const upload_allocator: *win.ID3D12CommandAllocator =
        @ptrCast(@alignCast(upload_allocator_raw.?));
    errdefer _ = upload_allocator.release();

    var upload_list_raw: ?*anyopaque = null;
    upload_hr = device.createCommandList(
        0,
        win.D3D12_COMMAND_LIST_TYPE_DIRECT,
        upload_allocator,
        null,
        &win.IID_ID3D12GraphicsCommandList,
        &upload_list_raw,
    );
    if (win.failed(upload_hr) or upload_list_raw == null) {
        return mapError(upload_hr);
    }
    const upload_list: *win.ID3D12GraphicsCommandList =
        @ptrCast(@alignCast(upload_list_raw.?));
    errdefer _ = upload_list.release();
    _ = upload_list.close();

    var upload_fence_raw: ?*anyopaque = null;
    upload_hr = device.createFence(
        0,
        0,
        &win.IID_ID3D12Fence,
        &upload_fence_raw,
    );
    if (win.failed(upload_hr) or upload_fence_raw == null) {
        return mapError(upload_hr);
    }
    const upload_fence: *win.ID3D12Fence = @ptrCast(@alignCast(
        upload_fence_raw.?,
    ));
    errdefer _ = upload_fence.release();

    const self = try allocator.create(Dx3d12);
    self.* = .{
        .allocator = allocator,
        .device = device,
        .queue = queue,
        .factory = factory,
        .shader_heap = shader_heap,
        .sampler_heap = sampler_heap,
        .rtv_heap = rtv_heap,
        .dsv_heap = dsv_heap,
        .upload_allocator = upload_allocator,
        .upload_list = upload_list,
        .upload_fence = upload_fence,
    };

    log.info("device_name: Direct3D 12 device", .{});
    log.debug("Direct3D 12 backend has been created", .{});
    return self;
}

/// Destroys the backend.
///
/// # Note
/// Every RHI resource must be destroyed before this call. Live
/// resources are reported as errors.
pub fn deinit(self: *Dx3d12) void {
    log.debug("Destroying Direct3D 12 backend", .{});
    if (self.live_count != 0) {
        log.err(
            "Direct3D 12 backend destroyed with {d} live resource(s)",
            .{self.live_count},
        );
        for (self.slots.items) |slot| {
            if (slot) |value| self.releaseHostData(&value);
        }
    }
    self.waitForGpu();
    _ = self.upload_fence.release();
    _ = self.upload_list.release();
    _ = self.upload_allocator.release();
    self.dsv_heap.deinit(self.allocator);
    self.rtv_heap.deinit(self.allocator);
    self.sampler_heap.deinit(self.allocator);
    self.shader_heap.deinit(self.allocator);
    _ = self.queue.release();
    _ = self.device.release();
    _ = self.factory.release();
    self.slots.deinit(self.allocator);
    self.generations.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.allocator.destroy(self);
    log.debug("Direct3D 12 backend has been destroyed", .{});
}

/// Returns the RHI device interface of this backend.
///
/// # Return
/// A device whose lifetime is tied to `self`.
pub fn asDevice(self: *Dx3d12) Device {
    return .{
        .vptr = self,
        .vtable = &device_vtable,
    };
}

fn lookup(
    self: *Dx3d12,
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
    self: *Dx3d12,
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

fn releaseSlot(self: *Dx3d12, resource: Resource) void {
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

fn releaseHostData(self: *Dx3d12, slot: *const Slot) void {
    switch (slot.handle) {
        .swapchain => |value| {
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .shader => |value| self.allocator.free(value.bytecode),
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            self.allocator.free(value.descriptor_sets);
            self.allocator.free(value.push_constants);
            self.allocator.free(value.set_params);
        },
        .pipeline => |value| self.allocator.free(value.strides),
        else => {},
    }
}

fn createResource(
    self: *Dx3d12,
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
    self: *Dx3d12,
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
    self: *Dx3d12,
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
    const swap_format = switch (description.format) {
        .b8g8r8a8_srgb, .b8g8r8a8_unorm => win.DXGI_FORMAT_B8G8R8A8_UNORM,
        .r8g8b8a8_srgb, .r8g8b8a8_unorm => win.DXGI_FORMAT_R8G8B8A8_UNORM,
        else => toDxgiFormat(description.format) orelse
            return error.Unsupported,
    };

    var state = SwapchainState{
        .handle = null,
        .handle3 = null,
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
        const hr = win.createFlipSwapChainForHwnd(
            self.factory,
            @ptrCast(self.queue),
            hwnd,
            &desc,
            &win.IID_ID3D12Resource,
            &swapchain_raw,
        );
        if (win.failed(hr) or swapchain_raw == null) {
            log.warn("CreateSwapChainForHwnd failed: 0x{x}", .{
                @as(u32, @bitCast(hr)),
            });
            return mapError(hr);
        }
        state.handle = swapchain_raw;
        errdefer _ = swapchain_raw.?.release();
        var swapchain3_raw: ?*anyopaque = null;
        const qi_hr = swapchain_raw.?.queryInterface(
            &win.IID_IDXGISwapChain3,
            &swapchain3_raw,
        );
        if (win.failed(qi_hr) or swapchain3_raw == null) {
            return mapError(qi_hr);
        }
        state.handle3 = @ptrCast(@alignCast(swapchain3_raw.?));
        errdefer _ = state.handle3.?.release();
        _ = self.factory.makeWindowAssociation(hwnd, 1);
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
            var raw: ?*anyopaque = null;
            const get_hr = handle.getBuffer(
                index,
                &win.IID_ID3D12Resource,
                &raw,
            );
            if (win.failed(get_hr) or raw == null) {
                return mapError(get_hr);
            }
            const resource: *win.ID3D12Resource = @ptrCast(@alignCast(
                raw.?,
            ));
            break :blk try self.newSlot(.texture, .{
                .texture = .{
                    .resource = resource,
                    .properties = .{
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
                    },
                    .state = win.D3D12_RESOURCE_STATE_PRESENT,
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

        const view_resource = try self.createTextureView(.{
            .texture = image_resource,
            .format = description.format,
        });
        views[index] = view_resource;
        errdefer self.destroyIfAlive(view_resource);
    }

    return self.newSlot(.swapchain, .{ .swapchain = state });
}

fn createBuffer(
    self: *Dx3d12,
    description: types.BufferDescription,
) Error!Resource {
    if (description.size == 0) return error.InvalidDescription;
    if (description.initial_data) |data| {
        if (data.len > description.size) {
            return error.InvalidDescription;
        }
    }
    const alignment: u64 = if (description.usage.uniform) 256 else 16;
    const allocation_size = alignForward(
        @max(description.size, 1),
        alignment,
    );
    const host_visible = description.memory.host_visible;
    const heap_type = if (host_visible)
        win.D3D12_HEAP_TYPE_UPLOAD
    else
        win.D3D12_HEAP_TYPE_DEFAULT;
    const initial_state = if (host_visible)
        win.D3D12_RESOURCE_STATE_GENERIC_READ
    else if (description.initial_data != null)
        win.D3D12_RESOURCE_STATE_COPY_DEST
    else
        win.D3D12_RESOURCE_STATE_COMMON;

    var desc = std.mem.zeroes(win.D3D12_RESOURCE_DESC);
    desc.dimension = win.D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.alignment = 0;
    desc.width = allocation_size;
    desc.height = 1;
    desc.depth_or_array_size = 1;
    desc.mip_levels = 1;
    desc.format = win.DXGI_FORMAT_UNKNOWN;
    desc.sample_desc = .{ .count = 1, .quality = 0 };
    desc.layout = win.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.flags = win.D3D12_RESOURCE_FLAG_NONE;

    var resource = try self.createCommittedResource(
        heap_type,
        &desc,
        initial_state,
        null,
    );
    errdefer _ = resource.release();

    if (description.initial_data) |data| {
        if (host_visible) {
            var ptr: ?*anyopaque = null;
            const hr = resource.map(0, null, &ptr);
            if (win.failed(hr) or ptr == null) return mapError(hr);
            @memcpy(
                @as([*]u8, @ptrCast(ptr.?))[0..data.len],
                data,
            );
            resource.unmap(0, null);
        } else {
            try self.uploadBufferData(
                resource,
                allocation_size,
                data,
            );
            try self.transitionBuffer(
                resource,
                win.D3D12_RESOURCE_STATE_COPY_DEST,
                win.D3D12_RESOURCE_STATE_COMMON,
            );
        }
    }

    return self.newSlot(.buffer, .{
        .buffer = .{
            .resource = resource,
            .size = description.size,
            .gpu_va = resource.getGPUVirtualAddress(),
            .hints = description.memory,
            .usage = description.usage,
            .host_visible = host_visible,
            .state = if (host_visible)
                win.D3D12_RESOURCE_STATE_GENERIC_READ
            else
                win.D3D12_RESOURCE_STATE_COMMON,
        },
    });
}

fn createTexture(
    self: *Dx3d12,
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
    const samples: u32 = description.samples;
    if (samples != 1 and description.mip_levels != 1) {
        return error.InvalidDescription;
    }
    var flags: u32 = win.D3D12_RESOURCE_FLAG_NONE;
    if (description.usage.color_attachment) {
        flags |= win.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    }
    if (description.usage.depth_attachment) {
        flags |= win.D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    }
    if (description.usage.storage) {
        flags |= win.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    }

    const initial_state = initialStateForUsage(description.usage);
    const transitory_state = if (description.initial_data != null)
        win.D3D12_RESOURCE_STATE_COPY_DEST
    else
        initial_state;

    var desc = std.mem.zeroes(win.D3D12_RESOURCE_DESC);
    desc.dimension = switch (description.type) {
        .@"1d" => win.D3D12_RESOURCE_DIMENSION_TEXTURE1D,
        .@"2d" => win.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
        .@"3d" => win.D3D12_RESOURCE_DIMENSION_TEXTURE3D,
    };
    desc.alignment = 0;
    desc.width = description.width;
    desc.height = description.height;
    desc.depth_or_array_size = if (description.type == .@"3d")
        @intCast(description.depth)
    else
        @intCast(description.array_layers);
    desc.mip_levels = @intCast(description.mip_levels);
    desc.format = format;
    desc.sample_desc = .{ .count = samples, .quality = 0 };
    desc.layout = win.D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.flags = flags;

    var resource = try self.createCommittedResource(
        win.D3D12_HEAP_TYPE_DEFAULT,
        &desc,
        transitory_state,
        null,
    );
    errdefer _ = resource.release();

    if (description.initial_data) |data| {
        try self.uploadTextureData(
            resource,
            description,
            data,
        );
        if (transitory_state != initial_state) {
            try self.transitionTexture(
                resource,
                transitory_state,
                initial_state,
            );
        }
    }

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
            .state = initial_state,
        },
    });
}

fn createTextureView(
    self: *Dx3d12,
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
    var owned_shader: [2]?u32 = .{ null, null };
    var owned_rtv: ?u32 = null;
    var owned_dsv: ?u32 = null;
    errdefer {
        for (owned_shader) |index| {
            if (index) |value| self.shader_heap.free(value, 1);
        }
        if (owned_rtv) |index| self.rtv_heap.free(index, 1);
        if (owned_dsv) |index| self.dsv_heap.free(index, 1);
    }

    if (properties.usage.sampled and
        (aspect == .color or aspect == .depth or
            aspect == .depth_stencil))
    {
        const index = self.shader_heap.alloc(1) orelse
            return error.OutOfDeviceMemory;
        owned_shader[0] = index;
        var desc = std.mem.zeroes(win.D3D12_SHADER_RESOURCE_VIEW_DESC);
        desc.format = dxgi_format;
        desc.shader_4_component_mapping =
            win.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                        .resource_min_lod_clamp = 0,
                    };
                } else {
                    desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .resource_min_lod_clamp = 0,
                    };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                        .plane_slice = 0,
                        .resource_min_lod_clamp = 0,
                    };
                } else {
                    desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{
                        .most_detailed_mip = base_mip,
                        .mip_levels = mip_count,
                        .plane_slice = 0,
                        .resource_min_lod_clamp = 0,
                    };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D12_SRV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .most_detailed_mip = base_mip,
                    .mip_levels = mip_count,
                    .resource_min_lod_clamp = 0,
                };
            },
        }
        self.device.createShaderResourceView(
            texture.resource,
            &desc,
            self.shader_heap.cpu(index),
        );
        state.srv = index;
        created = true;
    }

    if (properties.usage.color_attachment and aspect == .color) {
        const index = self.rtv_heap.alloc(1) orelse
            return error.OutOfDeviceMemory;
        owned_rtv = index;
        var desc = std.mem.zeroes(win.D3D12_RENDER_TARGET_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                        .plane_slice = 0,
                    };
                } else {
                    desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{
                        .mip_slice = base_mip,
                        .plane_slice = 0,
                    };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D12_RTV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .mip_slice = base_mip,
                    .first_w_slice = 0,
                    .w_size = properties.depth,
                };
            },
        }
        self.device.createRenderTargetView(
            texture.resource,
            &desc,
            self.rtv_heap.cpu(index),
        );
        state.rtv = index;
        created = true;
    }

    if (properties.usage.depth_attachment and
        (aspect == .depth or aspect == .stencil or
            aspect == .depth_stencil))
    {
        const index = self.dsv_heap.alloc(1) orelse
            return error.OutOfDeviceMemory;
        owned_dsv = index;
        var desc = std.mem.zeroes(win.D3D12_DEPTH_STENCIL_VIEW_DESC);
        desc.format = dxgi_format;
        desc.flags = win.D3D12_DSV_FLAG_NONE;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.samples > 1) {
                    if (properties.array_layers > 1) {
                        desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY;
                        desc.u.texture_2dms_array = .{
                            .first_array_slice = base_layer,
                            .array_size = layer_count,
                        };
                    } else {
                        desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE2DMS;
                        desc.u.texture_2dms = .{
                            .unused_field_nothing_to_define = 0,
                        };
                    }
                } else if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D12_DSV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{ .mip_slice = base_mip };
                }
            },
            .@"3d" => return error.Unsupported,
        }
        self.device.createDepthStencilView(
            texture.resource,
            &desc,
            self.dsv_heap.cpu(index),
        );
        state.dsv = index;
        created = true;
    }

    if (properties.usage.storage) {
        const index = self.shader_heap.alloc(1) orelse
            return error.OutOfDeviceMemory;
        owned_shader[1] = index;
        var desc = std.mem.zeroes(win.D3D12_UNORDERED_ACCESS_VIEW_DESC);
        desc.format = dxgi_format;
        switch (view_type) {
            .@"1d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_UAV_DIMENSION_TEXTURE1DARRAY;
                    desc.u.texture_1d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                    };
                } else {
                    desc.view_dimension = win.D3D12_UAV_DIMENSION_TEXTURE1D;
                    desc.u.texture_1d = .{ .mip_slice = base_mip };
                }
            },
            .@"2d" => {
                if (properties.array_layers > 1) {
                    desc.view_dimension = win.D3D12_UAV_DIMENSION_TEXTURE2DARRAY;
                    desc.u.texture_2d_array = .{
                        .mip_slice = base_mip,
                        .first_array_slice = base_layer,
                        .array_size = layer_count,
                        .plane_slice = 0,
                    };
                } else {
                    desc.view_dimension = win.D3D12_UAV_DIMENSION_TEXTURE2D;
                    desc.u.texture_2d = .{
                        .mip_slice = base_mip,
                        .plane_slice = 0,
                    };
                }
            },
            .@"3d" => {
                desc.view_dimension = win.D3D12_UAV_DIMENSION_TEXTURE3D;
                desc.u.texture_3d = .{
                    .mip_slice = base_mip,
                    .first_w_slice = 0,
                    .w_size = properties.depth,
                };
            },
        }
        self.device.createUnorderedAccessView(
            texture.resource,
            null,
            &desc,
            self.shader_heap.cpu(index),
        );
        state.uav = index;
        created = true;
    }

    if (!created) return error.Unsupported;
    return self.newSlot(.texture_view, .{ .texture_view = state });
}

fn createSampler(
    self: *Dx3d12,
    description: types.SamplerDescription,
) Error!Resource {
    const index = self.sampler_heap.alloc(1) orelse
        return error.OutOfDeviceMemory;
    errdefer self.sampler_heap.free(index, 1);
    var desc = std.mem.zeroes(win.D3D12_SAMPLER_DESC);
    desc.filter = toD3D12Filter(description);
    desc.address_u = toD3D12Address(description.address_u);
    desc.address_v = toD3D12Address(description.address_v);
    desc.address_w = toD3D12Address(description.address_w);
    desc.mip_lod_bias = 0;
    desc.max_anisotropy = if (description.anisotropy == 0)
        1
    else
        description.anisotropy;
    desc.comparison_func = if (description.compare) |compare|
        toD3D12Compare(compare)
    else
        win.D3D12_COMPARISON_FUNC_ALWAYS;
    desc.border_color = .{ 0, 0, 0, 0 };
    desc.min_lod = description.lod_min;
    desc.max_lod = description.lod_max;
    self.device.createSampler(&desc, self.sampler_heap.cpu(index));
    return self.newSlot(.sampler, .{ .sampler = index });
}

fn createShader(
    self: *Dx3d12,
    description: types.ShaderDescription,
) Error!Resource {
    if (description.code.len == 0) return error.InvalidDescription;
    const stage = description.stage;
    const target: [:0]const u8 = switch (stage) {
        .vertex => "vs_5_1",
        .fragment => "ps_5_1",
        .compute => "cs_5_1",
        else => return error.Unsupported,
    };
    const translated = spirv.translate(
        self.allocator,
        description.code,
        stage,
        description.entry_point,
        .d3d12,
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
    defer _ = blob.?.release();
    const ptr = blob.?.getBufferPointer() orelse
        return error.InvalidDescription;
    const len = blob.?.getBufferSize();
    const source = @as([*]const u8, @ptrCast(ptr))[0..len];
    const bytecode = self.allocator.dupe(u8, source) catch
        return error.OutOfHostMemory;
    return self.newSlot(.shader, .{
        .shader = .{ .stage = stage, .bytecode = bytecode },
    });
}

fn createDescriptorSetLayout(
    self: *Dx3d12,
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
    self: *Dx3d12,
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

    var total_ranges: usize = 0;
    for (sets) |set_resource| {
        const slot = try self.lookup(
            set_resource,
            .descriptor_set_layout,
        );
        for (slot.handle.descriptor_set_layout.bindings) |binding| {
            switch (binding.kind) {
                .sampler => total_ranges += 1,
                .combined_image_sampler => total_ranges += 2,
                else => total_ranges += 1,
            }
        }
    }
    const ranges = self.allocator.alloc(
        win.D3D12_DESCRIPTOR_RANGE,
        total_ranges,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(ranges);
    const params = self.allocator.alloc(
        win.D3D12_ROOT_PARAMETER,
        sets.len * 2 + 1,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(params);
    const set_params = self.allocator.alloc(
        SetRootParams,
        sets.len,
    ) catch return error.OutOfHostMemory;
    errdefer self.allocator.free(set_params);
    @memset(set_params, .{});

    var range_index: usize = 0;
    var param_index: u32 = 0;
    for (sets, 0..) |set_resource, set_index| {
        const slot = try self.lookup(
            set_resource,
            .descriptor_set_layout,
        );
        var shader_ranges: u32 = 0;
        var sampler_ranges: u32 = 0;
        for (slot.handle.descriptor_set_layout.bindings) |binding| {
            switch (binding.kind) {
                .sampler => sampler_ranges += 1,
                .combined_image_sampler => {
                    shader_ranges += 1;
                    sampler_ranges += 1;
                },
                else => shader_ranges += 1,
            }
        }
        if (shader_ranges != 0) {
            const start = range_index;
            for (slot.handle.descriptor_set_layout.bindings) |binding| {
                const range_type = switch (binding.kind) {
                    .uniform_buffer => win.D3D12_DESCRIPTOR_RANGE_TYPE_CBV,
                    .storage_buffer, .storage_texture => win.D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
                    .sampled_texture, .combined_image_sampler => win.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
                    .sampler => continue,
                };
                ranges[range_index] = .{
                    .range_type = range_type,
                    .num_descriptors = binding.count,
                    .base_shader_register = binding.binding,
                    .register_space = @intCast(set_index),
                    .offset_in_descriptors_from_table_start = win.D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
                };
                range_index += 1;
            }
            params[param_index] = .{
                .parameter_type = win.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
                .u = .{ .descriptor_table = .{
                    .num_descriptor_ranges = shader_ranges,
                    .descriptor_ranges = &ranges[start],
                } },
                .shader_visibility = win.D3D12_SHADER_VISIBILITY_ALL,
            };
            set_params[set_index].shader = param_index;
            param_index += 1;
        }
        if (sampler_ranges != 0) {
            const start = range_index;
            for (slot.handle.descriptor_set_layout.bindings) |binding| {
                if (binding.kind != .sampler and
                    binding.kind != .combined_image_sampler)
                {
                    continue;
                }
                ranges[range_index] = .{
                    .range_type = win.D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,
                    .num_descriptors = binding.count,
                    .base_shader_register = binding.binding,
                    .register_space = @intCast(set_index),
                    .offset_in_descriptors_from_table_start = win.D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
                };
                range_index += 1;
            }
            params[param_index] = .{
                .parameter_type = win.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
                .u = .{ .descriptor_table = .{
                    .num_descriptor_ranges = sampler_ranges,
                    .descriptor_ranges = &ranges[start],
                } },
                .shader_visibility = win.D3D12_SHADER_VISIBILITY_ALL,
            };
            set_params[set_index].sampler = param_index;
            param_index += 1;
        }
    }

    var push_param: ?u32 = null;
    if (push_size != 0) {
        params[param_index] = .{
            .parameter_type = win.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
            .u = .{ .constants = .{
                .shader_register = 0,
                .register_space = 15,
                .num_32bit_values = (push_size + 3) / 4,
            } },
            .shader_visibility = win.D3D12_SHADER_VISIBILITY_ALL,
        };
        push_param = param_index;
        param_index += 1;
    }

    var root_desc = std.mem.zeroes(win.D3D12_ROOT_SIGNATURE_DESC);
    root_desc.num_parameters = param_index;
    root_desc.parameters = &params[0];
    root_desc.num_static_samplers = 0;
    root_desc.static_samplers = null;
    root_desc.flags = win.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

    var signature_blob: ?*win.ID3DBlob = null;
    var error_blob: ?*win.ID3DBlob = null;
    const serialize_hr = win.D3D12SerializeRootSignature(
        &root_desc,
        1,
        &signature_blob,
        &error_blob,
    );
    if (error_blob) |blob| {
        const ptr = blob.getBufferPointer();
        const len = blob.getBufferSize();
        if (ptr) |bytes| {
            log.warn("root signature: {s}", .{
                @as([*]const u8, @ptrCast(bytes))[0..len],
            });
        }
        _ = blob.release();
    }
    if (win.failed(serialize_hr) or signature_blob == null) {
        return mapError(serialize_hr);
    }
    defer _ = signature_blob.?.release();
    const code = signature_blob.?.getBufferPointer() orelse
        return error.InvalidDescription;
    const code_size = signature_blob.?.getBufferSize();
    var root_raw: ?*anyopaque = null;
    const root_hr = self.device.createRootSignature(
        0,
        code,
        code_size,
        &win.IID_ID3D12RootSignature,
        &root_raw,
    );
    if (win.failed(root_hr) or root_raw == null) {
        return mapError(root_hr);
    }
    const root_signature: *win.ID3D12RootSignature = @ptrCast(@alignCast(
        root_raw.?,
    ));
    errdefer _ = root_signature.release();

    return self.newSlot(.pipeline_layout, .{
        .pipeline_layout = .{
            .descriptor_sets = sets,
            .push_constants = push,
            .root_signature = root_signature,
            .set_params = set_params,
            .push_param = push_param,
            .push_size = push_size,
        },
    });
}

fn createDescriptorSet(
    self: *Dx3d12,
    description: types.DescriptorSetDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .descriptor_set_layout,
    );
    var shader_count: u32 = 0;
    var sampler_count: u32 = 0;
    for (layout_slot.handle.descriptor_set_layout.bindings) |binding| {
        switch (binding.kind) {
            .sampler => sampler_count += binding.count,
            .combined_image_sampler => {
                shader_count += binding.count;
                sampler_count += binding.count;
            },
            else => shader_count += binding.count,
        }
    }
    var state = DescriptorSetState{ .layout = description.layout };
    if (shader_count != 0) {
        state.shader_start = self.shader_heap.alloc(shader_count) orelse
            return error.OutOfDeviceMemory;
        state.shader_count = shader_count;
    }
    errdefer {
        if (state.shader_count != 0) {
            self.shader_heap.free(state.shader_start, state.shader_count);
        }
    }
    if (sampler_count != 0) {
        state.sampler_start = self.sampler_heap.alloc(sampler_count) orelse
            return error.OutOfDeviceMemory;
        state.sampler_count = sampler_count;
    }
    errdefer {
        if (state.sampler_count != 0) {
            self.sampler_heap.free(state.sampler_start, state.sampler_count);
        }
    }
    return self.newSlot(.descriptor_set, .{ .descriptor_set = state });
}

fn createPipeline(
    self: *Dx3d12,
    description: types.PipelineDescription,
) Error!Resource {
    return switch (description) {
        .graphics => |value| self.createGraphicsPipeline(value),
        .compute => |value| self.createComputePipeline(value),
    };
}

fn createGraphicsPipeline(
    self: *Dx3d12,
    description: types.GraphicsPipelineDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .pipeline_layout,
    );
    const layout = &layout_slot.handle.pipeline_layout;
    const vertex_slot = try self.lookup(description.vertex, .shader);
    if (vertex_slot.handle.shader.stage != .vertex) {
        return error.InvalidDescription;
    }
    var pixel_bytecode = std.mem.zeroes(win.D3D12_SHADER_BYTECODE);
    if (description.fragment) |fragment_resource| {
        const fragment_slot = try self.lookup(
            fragment_resource,
            .shader,
        );
        if (fragment_slot.handle.shader.stage != .fragment) {
            return error.InvalidDescription;
        }
        pixel_bytecode = fragment_slot.handle.shader.bytes();
    }

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
    var strides: []u32 = &.{};
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

    var elements: []win.D3D12_INPUT_ELEMENT_DESC = &.{};
    defer if (elements.len != 0) self.allocator.free(elements);
    if (description.vertex_layout.attributes.len != 0) {
        elements = self.allocator.alloc(
            win.D3D12_INPUT_ELEMENT_DESC,
            description.vertex_layout.attributes.len,
        ) catch return error.OutOfHostMemory;
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
                    .vertex => win.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                    .instance => win.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
                },
                .instance_data_step_rate = switch (rate) {
                    .vertex => 0,
                    .instance => 1,
                },
            };
        }
    }

    var desc = std.mem.zeroes(win.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    desc.root_signature = layout.root_signature;
    desc.vs = vertex_slot.handle.shader.bytes();
    desc.ps = pixel_bytecode;
    desc.blend_state.alpha_to_coverage_enable = 0;
    desc.blend_state.independent_blend_enable = 0;
    const rt = &desc.blend_state.render_target[0];
    rt.blend_enable = if (description.blend.enabled) 1 else 0;
    rt.src_blend = toD3D12Blend(description.blend.src_color);
    rt.dest_blend = toD3D12Blend(description.blend.dst_color);
    rt.blend_op = toD3D12BlendOp(description.blend.op_color);
    rt.src_blend_alpha = toD3D12Blend(description.blend.src_alpha);
    rt.dest_blend_alpha = toD3D12Blend(description.blend.dst_alpha);
    rt.blend_op_alpha = toD3D12BlendOp(description.blend.op_alpha);
    rt.render_target_write_mask = 0xf;
    desc.sample_mask = 0xffffffff;
    desc.rasterizer_state.fill_mode = win.D3D12_FILL_MODE_SOLID;
    desc.rasterizer_state.cull_mode = toD3D12Cull(description.cull);
    desc.rasterizer_state.front_counter_clockwise =
        switch (description.front_face) {
            .counter_clockwise => 0,
            .clockwise => 1,
        };
    desc.rasterizer_state.depth_clip_enable = 1;
    desc.rasterizer_state.multisample_enable =
        if (description.samples > 1) 1 else 0;
    desc.depth_stencil_state.depth_enable =
        if (description.depth.enable) 1 else 0;
    desc.depth_stencil_state.depth_write_mask =
        if (description.depth.write)
            win.D3D12_DEPTH_WRITE_MASK_ALL
        else
            win.D3D12_DEPTH_WRITE_MASK_ZERO;
    desc.depth_stencil_state.depth_func =
        toD3D12Compare(description.depth.compare);
    desc.depth_stencil_state.stencil_enable = 0;
    desc.depth_stencil_state.stencil_read_mask = 0xff;
    desc.depth_stencil_state.stencil_write_mask = 0xff;
    desc.input_layout = .{
        .input_element_descs = if (elements.len == 0)
            null
        else
            &elements[0],
        .num_elements = @intCast(elements.len),
    };
    desc.ib_strip_cut_value =
        win.D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
    desc.primitive_topology_type = toD3D12TopologyType(
        description.topology,
    );
    const color_count = @min(description.color_formats.len, 8);
    desc.num_render_targets = @intCast(color_count);
    for (description.color_formats[0..color_count], 0..) |format, index| {
        desc.rtv_formats[index] = toDxgiFormat(format) orelse
            return error.Unsupported;
    }
    desc.dsv_format = if (description.depth_format) |format|
        toDxgiFormat(format) orelse return error.Unsupported
    else
        win.DXGI_FORMAT_UNKNOWN;
    desc.sample_desc = .{ .count = description.samples, .quality = 0 };
    desc.node_mask = 0;
    desc.flags = 0;

    var pso_raw: ?*anyopaque = null;
    const hr = self.device.createGraphicsPipelineState(
        &desc,
        &win.IID_ID3D12PipelineState,
        &pso_raw,
    );
    if (win.failed(hr) or pso_raw == null) {
        log.warn("CreateGraphicsPipelineState failed: 0x{x}", .{
            @as(u32, @bitCast(hr)),
        });
        return mapError(hr);
    }
    const pso: *win.ID3D12PipelineState = @ptrCast(@alignCast(
        pso_raw.?,
    ));
    errdefer _ = pso.release();

    return self.newSlot(.pipeline, .{
        .pipeline = .{
            .bind_point = .graphics,
            .layout = description.layout,
            .root_signature = layout.root_signature,
            .pso = pso,
            .topology = toD3D12Topology(description.topology),
            .strides = strides,
        },
    });
}

fn createComputePipeline(
    self: *Dx3d12,
    description: types.ComputePipelineDescription,
) Error!Resource {
    const layout_slot = try self.lookup(
        description.layout,
        .pipeline_layout,
    );
    const layout = &layout_slot.handle.pipeline_layout;
    const shader_slot = try self.lookup(description.shader, .shader);
    if (shader_slot.handle.shader.stage != .compute) {
        return error.InvalidDescription;
    }
    var desc = std.mem.zeroes(win.D3D12_COMPUTE_PIPELINE_STATE_DESC);
    desc.root_signature = layout.root_signature;
    desc.cs = shader_slot.handle.shader.bytes();
    desc.node_mask = 0;
    desc.flags = 0;
    var pso_raw: ?*anyopaque = null;
    const hr = self.device.createComputePipelineState(
        &desc,
        &win.IID_ID3D12PipelineState,
        &pso_raw,
    );
    if (win.failed(hr) or pso_raw == null) return mapError(hr);
    const pso: *win.ID3D12PipelineState = @ptrCast(@alignCast(
        pso_raw.?,
    ));
    return self.newSlot(.pipeline, .{
        .pipeline = .{
            .bind_point = .compute,
            .layout = description.layout,
            .root_signature = layout.root_signature,
            .pso = pso,
        },
    });
}

fn createCommandBuffer(
    self: *Dx3d12,
    description: types.CommandBufferDescription,
) Error!Resource {
    _ = description;
    var allocator_raw: ?*anyopaque = null;
    var hr = self.device.createCommandAllocator(
        win.D3D12_COMMAND_LIST_TYPE_DIRECT,
        &win.IID_ID3D12CommandAllocator,
        &allocator_raw,
    );
    if (win.failed(hr) or allocator_raw == null) return mapError(hr);
    const allocator: *win.ID3D12CommandAllocator = @ptrCast(@alignCast(
        allocator_raw.?,
    ));
    errdefer _ = allocator.release();
    var list_raw: ?*anyopaque = null;
    hr = self.device.createCommandList(
        0,
        win.D3D12_COMMAND_LIST_TYPE_DIRECT,
        allocator,
        null,
        &win.IID_ID3D12GraphicsCommandList,
        &list_raw,
    );
    if (win.failed(hr) or list_raw == null) return mapError(hr);
    const list: *win.ID3D12GraphicsCommandList = @ptrCast(@alignCast(
        list_raw.?,
    ));
    _ = list.close();
    return self.newSlot(.command_buffer, .{
        .command_buffer = .{
            .allocator = allocator,
            .list = list,
        },
    });
}

fn createFence(
    self: *Dx3d12,
    description: types.FenceDescription,
) Error!Resource {
    const initial: u64 = if (description.signaled) 1 else 0;
    var raw: ?*anyopaque = null;
    const hr = self.device.createFence(
        initial,
        0,
        &win.IID_ID3D12Fence,
        &raw,
    );
    if (win.failed(hr) or raw == null) return mapError(hr);
    const fence: *win.ID3D12Fence = @ptrCast(@alignCast(raw.?));
    return self.newSlot(.fence, .{
        .fence = .{
            .fence = fence,
            .value = initial,
            .pending = !description.signaled,
        },
    });
}

fn createSemaphore(
    self: *Dx3d12,
    description: types.SemaphoreDescription,
) Error!Resource {
    _ = description;
    return self.newSlot(.semaphore, .{ .semaphore = .{} });
}

fn createBatch(
    self: *Dx3d12,
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

fn destroyResource(self: *Dx3d12, resource: Resource) void {
    const slot = self.lookup(resource, resource.tag) catch return;
    switch (slot.handle) {
        .surface => {},
        .swapchain => |value| {
            for (value.views) |view| self.destroyIfAlive(view);
            for (value.images) |image| self.destroyIfAlive(image);
            if (value.handle3) |handle| _ = handle.release();
            if (value.handle) |handle| _ = handle.release();
            self.allocator.free(value.images);
            self.allocator.free(value.views);
        },
        .buffer => |value| {
            _ = value.resource.release();
        },
        .texture => |value| {
            _ = value.resource.release();
        },
        .texture_view => |value| {
            if (value.srv) |index| self.shader_heap.free(index, 1);
            if (value.uav) |index| self.shader_heap.free(index, 1);
            if (value.rtv) |index| self.rtv_heap.free(index, 1);
            if (value.dsv) |index| self.dsv_heap.free(index, 1);
        },
        .sampler => |index| self.sampler_heap.free(index, 1),
        .shader => |value| self.allocator.free(value.bytecode),
        .descriptor_set_layout => |value| {
            self.allocator.free(value.bindings);
        },
        .pipeline_layout => |value| {
            _ = value.root_signature.release();
            self.allocator.free(value.descriptor_sets);
            self.allocator.free(value.push_constants);
            self.allocator.free(value.set_params);
        },
        .descriptor_set => |value| {
            if (value.shader_count != 0) {
                self.shader_heap.free(
                    value.shader_start,
                    value.shader_count,
                );
            }
            if (value.sampler_count != 0) {
                self.sampler_heap.free(
                    value.sampler_start,
                    value.sampler_count,
                );
            }
        },
        .pipeline => |value| {
            _ = value.pso.release();
            self.allocator.free(value.strides);
        },
        .command_buffer => |value| {
            _ = value.list.release();
            _ = value.allocator.release();
        },
        .fence => |value| _ = value.fence.release(),
        .semaphore => {},
    }
    self.releaseSlot(resource);
}

fn destroyIfAlive(self: *Dx3d12, resource: Resource) void {
    _ = self.lookup(resource, resource.tag) catch return;
    self.destroyResource(resource);
}

fn map(
    self: *Dx3d12,
    resource: Resource,
    offset: u64,
    size: u64,
    ret_addr: usize,
) Error![]u8 {
    _ = ret_addr;
    const slot = try self.lookup(resource, .buffer);
    const buffer = &slot.handle.buffer;
    if (!buffer.host_visible) return error.Unsupported;
    if (buffer.mapped) return error.InvalidResource;
    if (offset > buffer.size or size > buffer.size - offset) {
        return error.InvalidDescription;
    }
    var ptr: ?*anyopaque = null;
    const hr = buffer.resource.map(0, null, &ptr);
    if (win.failed(hr) or ptr == null) return mapError(hr);
    buffer.mapped = true;
    const bytes: [*]u8 = @ptrCast(ptr.?);
    return bytes[@intCast(offset)..][0..@intCast(size)];
}

fn unmap(
    self: *Dx3d12,
    resource: Resource,
    dirty: []const Device.Dirty,
    ret_addr: usize,
) void {
    _ = dirty;
    _ = ret_addr;
    const slot = self.lookup(resource, .buffer) catch return;
    const buffer = &slot.handle.buffer;
    if (!buffer.mapped) {
        log.warn("unmap of an unmapped buffer", .{});
        return;
    }
    buffer.resource.unmap(0, null);
    buffer.mapped = false;
}

fn getQueue(self: *Dx3d12, index: u32, ret_addr: usize) Error!Queue {
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
    self: *Dx3d12,
    resource: Resource,
    command: commands.Command,
    ret_addr: usize,
) Error!void {
    _ = ret_addr;
    const slot = try self.lookup(resource, .command_buffer);
    const command_buffer = &slot.handle.command_buffer;
    const list = command_buffer.list;

    switch (command) {
        .begin => {
            if (command_buffer.state == .recording) {
                return error.InvalidResource;
            }
            const reset_hr = command_buffer.allocator.reset();
            if (win.failed(reset_hr)) return mapError(reset_hr);
            const list_hr = list.reset(command_buffer.allocator, null);
            if (win.failed(list_hr)) return mapError(list_hr);
            command_buffer.state = .recording;
            command_buffer.in_rendering = false;
            command_buffer.pipeline = null;
        },
        .end => {
            if (command_buffer.state != .recording) {
                return error.InvalidResource;
            }
            const close_hr = list.close();
            if (win.failed(close_hr)) return mapError(close_hr);
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
            list.oMSetRenderTargets(0, null, 0, null);
        },
        .bind_pipeline => |value| {
            try requireRecording(command_buffer);
            const pipeline_slot = try self.lookup(
                value.pipeline,
                .pipeline,
            );
            const pipeline = &pipeline_slot.handle.pipeline;
            command_buffer.pipeline = pipeline;
            const heaps = [_]?*win.ID3D12DescriptorHeap{
                self.shader_heap.handle,
                self.sampler_heap.handle,
            };
            list.setDescriptorHeaps(2, &heaps);
            list.setPipelineState(pipeline.pso);
            switch (pipeline.bind_point) {
                .graphics => {
                    list.setGraphicsRootSignature(
                        pipeline.root_signature,
                    );
                    list.iASetPrimitiveTopology(pipeline.topology);
                },
                .compute => {
                    list.setComputeRootSignature(
                        pipeline.root_signature,
                    );
                },
            }
        },
        .bind_vertex_buffers => |value| {
            try requireRecording(command_buffer);
            const pipeline = command_buffer.pipeline orelse
                return error.InvalidResource;
            if (value.buffers.len == 0) return;
            const views = self.allocator.alloc(
                win.D3D12_VERTEX_BUFFER_VIEW,
                value.buffers.len,
            ) catch return error.OutOfHostMemory;
            defer self.allocator.free(views);
            for (value.buffers, 0..) |buffer_resource, index| {
                const buffer_slot = try self.lookup(
                    buffer_resource,
                    .buffer,
                );
                const buffer = buffer_slot.handle.buffer;
                const offset = if (index < value.offsets.len)
                    value.offsets[index]
                else
                    0;
                if (offset > buffer.size) {
                    return error.InvalidDescription;
                }
                const binding = value.first_binding +
                    @as(u32, @intCast(index));
                const stride = if (binding < pipeline.strides.len)
                    pipeline.strides[binding]
                else
                    0;
                const size = buffer.size - offset;
                if (size > std.math.maxInt(u32)) {
                    return error.Unsupported;
                }
                views[index] = .{
                    .buffer_location = buffer.gpu_va + offset,
                    .size_in_bytes = @intCast(size),
                    .stride_in_bytes = stride,
                };
            }
            list.iASetVertexBuffers(
                value.first_binding,
                @intCast(views.len),
                &views[0],
            );
        },
        .bind_index_buffer => |value| {
            try requireRecording(command_buffer);
            const buffer_slot = try self.lookup(value.buffer, .buffer);
            const buffer = buffer_slot.handle.buffer;
            if (value.offset > buffer.size) {
                return error.InvalidDescription;
            }
            const size = buffer.size - value.offset;
            if (size > std.math.maxInt(u32)) {
                return error.Unsupported;
            }
            const view = win.D3D12_INDEX_BUFFER_VIEW{
                .buffer_location = buffer.gpu_va + value.offset,
                .size_in_bytes = @intCast(size),
                .format = switch (value.type) {
                    .uint16 => 57,
                    .uint32 => 42,
                },
            };
            list.iASetIndexBuffer(&view);
        },
        .bind_descriptor_sets => |value| {
            try requireRecording(command_buffer);
            try self.bindDescriptorSets(list, value);
        },
        .set_viewport => |value| {
            try requireRecording(command_buffer);
            const viewport = win.D3D12_VIEWPORT{
                .top_left_x = value.x,
                .top_left_y = value.y,
                .width = value.width,
                .height = value.height,
                .min_depth = value.min_depth,
                .max_depth = value.max_depth,
            };
            list.rSSetViewports(1, &viewport);
        },
        .set_scissor => |value| {
            try requireRecording(command_buffer);
            const rect = win.D3D12_RECT{
                .left = value.x,
                .top = value.y,
                .right = value.x + @as(i32, @intCast(value.width)),
                .bottom = value.y + @as(i32, @intCast(value.height)),
            };
            list.rSSetScissorRects(1, &rect);
        },
        .draw => |value| {
            try requireDraw(command_buffer);
            list.drawInstanced(
                value.vertex_count,
                value.instance_count,
                value.first_vertex,
                value.first_instance,
            );
        },
        .draw_indexed => |value| {
            try requireDraw(command_buffer);
            list.drawIndexedInstanced(
                value.index_count,
                value.instance_count,
                value.first_index,
                value.vertex_offset,
                value.first_instance,
            );
        },
        .dispatch => |value| {
            try requireRecording(command_buffer);
            list.dispatch(value.x, value.y, value.z);
        },
        .copy_buffer => |value| {
            try requireRecording(command_buffer);
            const src = try self.lookup(value.src, .buffer);
            const dst = try self.lookup(value.dst, .buffer);
            for (value.regions) |region| {
                list.copyBufferRegion(
                    dst.handle.buffer.resource,
                    region.dst_offset,
                    src.handle.buffer.resource,
                    region.src_offset,
                    region.size,
                );
            }
        },
        .copy_buffer_to_texture => |value| {
            try requireRecording(command_buffer);
            try self.copyBufferToTexture(list, value);
        },
        .copy_texture_to_buffer => |value| {
            try requireRecording(command_buffer);
            try self.copyTextureToBuffer(list, value);
        },
        .copy_texture => |value| {
            try requireRecording(command_buffer);
            try self.copyTexture(list, value);
        },
        .barrier => |value| {
            try requireRecording(command_buffer);
            try self.recordBarrier(list, value);
        },
        .push_constants => |value| {
            try requireRecording(command_buffer);
            try self.pushConstants(list, value);
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
    self: *Dx3d12,
    command_buffer: *CommandBufferState,
    value: commands.BeginRendering,
) Error!void {
    if (command_buffer.in_rendering) {
        return error.InvalidResource;
    }
    const list = command_buffer.list;
    const rtvs = self.allocator.alloc(
        win.D3D12_CPU_DESCRIPTOR_HANDLE,
        value.color_attachments.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(rtvs);
    for (value.color_attachments, 0..) |attachment, index| {
        const view_slot = try self.lookup(
            attachment.view,
            .texture_view,
        );
        const rtv = view_slot.handle.texture_view.rtv orelse
            return error.InvalidDescription;
        rtvs[index] = self.rtv_heap.cpu(rtv);
    }
    var dsv: ?*win.D3D12_CPU_DESCRIPTOR_HANDLE = null;
    var dsv_handle = std.mem.zeroes(win.D3D12_CPU_DESCRIPTOR_HANDLE);
    if (value.depth_attachment) |attachment| {
        const view_slot = try self.lookup(
            attachment.view,
            .texture_view,
        );
        const index = view_slot.handle.texture_view.dsv orelse
            return error.InvalidDescription;
        dsv_handle = self.dsv_heap.cpu(index);
        dsv = &dsv_handle;
    }
    list.oMSetRenderTargets(
        @intCast(rtvs.len),
        if (rtvs.len == 0) null else &rtvs[0],
        0,
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
        list.clearRenderTargetView(
            self.rtv_heap.cpu(rtv),
            &color,
            0,
            null,
        );
    }
    if (value.depth_attachment) |attachment| {
        if (attachment.load == .clear) {
            const view_slot = try self.lookup(
                attachment.view,
                .texture_view,
            );
            const index = view_slot.handle.texture_view.dsv orelse
                return error.InvalidDescription;
            list.clearDepthStencilView(
                self.dsv_heap.cpu(index),
                win.D3D12_CLEAR_FLAG_DEPTH |
                    win.D3D12_CLEAR_FLAG_STENCIL,
                attachment.clear_depth,
                @intCast(attachment.clear_stencil),
                0,
                null,
            );
        }
    }
}

fn bindDescriptorSets(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.BindDescriptorSets,
) Error!void {
    const layout_slot = try self.lookup(
        value.layout,
        .pipeline_layout,
    );
    const layout = &layout_slot.handle.pipeline_layout;
    if (value.dynamic_offsets.len != 0) {
        return error.Unsupported;
    }
    for (value.sets, 0..) |set_resource, index| {
        const set_index = value.first_set + @as(u32, @intCast(index));
        if (set_index >= layout.set_params.len) {
            return error.InvalidDescription;
        }
        const set_slot = try self.lookup(set_resource, .descriptor_set);
        const set = &set_slot.handle.descriptor_set;
        const params = layout.set_params[set_index];
        if (params.shader) |param| {
            const handle = self.shader_heap.gpu(set.shader_start);
            switch (value.bind_point) {
                .graphics => list.setGraphicsRootDescriptorTable(
                    param,
                    handle,
                ),
                .compute => list.setComputeRootDescriptorTable(
                    param,
                    handle,
                ),
            }
        }
        if (params.sampler) |param| {
            const handle = self.sampler_heap.gpu(set.sampler_start);
            switch (value.bind_point) {
                .graphics => list.setGraphicsRootDescriptorTable(
                    param,
                    handle,
                ),
                .compute => list.setComputeRootDescriptorTable(
                    param,
                    handle,
                ),
            }
        }
    }
}

fn pushConstants(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.PushConstants,
) Error!void {
    const layout_slot = try self.lookup(
        value.layout,
        .pipeline_layout,
    );
    const layout = &layout_slot.handle.pipeline_layout;
    const param = layout.push_param orelse
        return error.InvalidDescription;
    if (value.data.len % 4 != 0 or value.offset % 4 != 0) {
        return error.InvalidDescription;
    }
    const word_count = value.data.len / 4;
    const words = self.allocator.alloc(u32, word_count) catch
        return error.OutOfHostMemory;
    defer self.allocator.free(words);
    @memcpy(std.mem.sliceAsBytes(words), value.data);
    switch (value.stages.vertex or value.stages.fragment) {
        true => list.setGraphicsRoot32BitConstants(
            param,
            @intCast(word_count),
            words.ptr,
            value.offset / 4,
        ),
        false => list.setComputeRoot32BitConstants(
            param,
            @intCast(word_count),
            words.ptr,
            value.offset / 4,
        ),
    }
}

fn recordBarrier(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.Barrier,
) Error!void {
    const slot = try self.lookup(value.resource, value.resource.tag);
    switch (slot.handle) {
        .texture => |*texture| {
            const after = textureState(value.layout_after);
            if (after != texture.state and after != 0) {
                var barrier = std.mem.zeroes(win.D3D12_RESOURCE_BARRIER);
                barrier.type = win.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
                barrier.flags = win.D3D12_RESOURCE_BARRIER_FLAG_NONE;
                barrier.u = .{ .transition = .{
                    .resource = texture.resource,
                    .subresource = win.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    .state_before = texture.state,
                    .state_after = after,
                } };
                list.resourceBarrier(1, &barrier);
                texture.state = after;
            }
        },
        .buffer => |*buffer| {
            const after = bufferState(value.layout_after);
            if (after == 0 or after == buffer.state) return;
            var barrier = std.mem.zeroes(win.D3D12_RESOURCE_BARRIER);
            barrier.type = win.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            barrier.flags = win.D3D12_RESOURCE_BARRIER_FLAG_NONE;
            barrier.u = .{ .transition = .{
                .resource = buffer.resource,
                .subresource = win.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .state_before = buffer.state,
                .state_after = after,
            } };
            list.resourceBarrier(1, &barrier);
            buffer.state = after;
        },
        else => return error.InvalidResource,
    }
}

fn copyBufferToTexture(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.CopyBufferToTexture,
) Error!void {
    const buffer_slot = try self.lookup(value.buffer, .buffer);
    const texture_slot = try self.lookup(value.texture, .texture);
    const properties = texture_slot.handle.texture.properties;
    if (value.region.mip_level >= properties.mip_levels or
        value.region.array_layer >= properties.array_layers)
    {
        return error.InvalidDescription;
    }
    const bpp = properties.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    const tight_row = @as(u64, value.region.extent.width) * bpp;
    const row_pitch: u32 = if (value.row_pitch == 0)
        @intCast(alignForward(tight_row, 4))
    else
        value.row_pitch;
    const subresource = value.region.mip_level +
        value.region.array_layer * properties.mip_levels;
    var dst = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
    dst.resource = texture_slot.handle.texture.resource;
    dst.type = win.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.u = .{ .subresource_index = subresource };
    var src = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
    src.resource = buffer_slot.handle.buffer.resource;
    src.type = win.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.u = .{ .placed_footprint = .{
        .offset = value.buffer_offset,
        .footprint = .{
            .format = toDxgiFormat(properties.format) orelse
                return error.Unsupported,
            .width = value.region.extent.width,
            .height = value.region.extent.height,
            .depth = value.region.extent.depth,
            .row_pitch = row_pitch,
        },
    } };
    list.copyTextureRegion(
        &dst,
        value.region.offset.x,
        value.region.offset.y,
        value.region.offset.z,
        &src,
        null,
    );
}

fn copyTextureToBuffer(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.CopyTextureToBuffer,
) Error!void {
    const buffer_slot = try self.lookup(value.buffer, .buffer);
    const texture_slot = try self.lookup(value.texture, .texture);
    const properties = texture_slot.handle.texture.properties;
    if (value.region.mip_level >= properties.mip_levels or
        value.region.array_layer >= properties.array_layers)
    {
        return error.InvalidDescription;
    }
    const bpp = properties.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    const tight_row = @as(u64, value.region.extent.width) * bpp;
    const row_pitch: u32 = if (value.row_pitch == 0)
        @intCast(alignForward(tight_row, 4))
    else
        value.row_pitch;
    const subresource = value.region.mip_level +
        value.region.array_layer * properties.mip_levels;
    var src = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
    src.resource = texture_slot.handle.texture.resource;
    src.type = win.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.u = .{ .subresource_index = subresource };
    var dst = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
    dst.resource = buffer_slot.handle.buffer.resource;
    dst.type = win.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.u = .{ .placed_footprint = .{
        .offset = value.buffer_offset,
        .footprint = .{
            .format = toDxgiFormat(properties.format) orelse
                return error.Unsupported,
            .width = value.region.extent.width,
            .height = value.region.extent.height,
            .depth = value.region.extent.depth,
            .row_pitch = row_pitch,
        },
    } };
    list.copyTextureRegion(
        &dst,
        0,
        0,
        0,
        &src,
        null,
    );
}

fn copyTexture(
    self: *Dx3d12,
    list: *win.ID3D12GraphicsCommandList,
    value: commands.CopyTexture,
) Error!void {
    const src_slot = try self.lookup(value.src, .texture);
    const dst_slot = try self.lookup(value.dst, .texture);
    for (value.regions) |region| {
        const src_subresource = region.mip_level +
            region.array_layer * src_slot.handle.texture.properties.mip_levels;
        const dst_subresource = region.mip_level +
            region.array_layer * dst_slot.handle.texture.properties.mip_levels;
        var src = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
        src.resource = src_slot.handle.texture.resource;
        src.type = win.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.u = .{ .subresource_index = src_subresource };
        var dst = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
        dst.resource = dst_slot.handle.texture.resource;
        dst.type = win.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst.u = .{ .subresource_index = dst_subresource };
        const box = win.D3D12_BOX{
            .left = region.offset.x,
            .top = region.offset.y,
            .front = region.offset.z,
            .right = region.offset.x + region.extent.width,
            .bottom = region.offset.y + region.extent.height,
            .back = region.offset.z + region.extent.depth,
        };
        list.copyTextureRegion(
            &dst,
            region.offset.x,
            region.offset.y,
            region.offset.z,
            &src,
            &box,
        );
    }
}

fn deviceOpi(
    self: *Dx3d12,
    operator: Device.DeviceOp,
    output_mode: ?Device.OutputMode,
    ret_addr: usize,
) Error!?[]const u8 {
    _ = output_mode;
    _ = ret_addr;
    switch (operator) {
        .wait_idle => {
            self.waitForGpu();
            return null;
        },
        .wait_fence => |value| {
            const slot = try self.lookup(value.fence, .fence);
            const fence = &slot.handle.fence;
            const target = if (fence.pending)
                fence.value + 1
            else
                fence.value;
            try waitFenceValue(
                fence.fence,
                target,
                value.timeout_ns,
            );
            return null;
        },
        .reset_fence => |value| {
            const slot = try self.lookup(value.fence, .fence);
            slot.handle.fence.pending = true;
            return null;
        },
        .write_descriptor_set => |value| {
            try self.writeDescriptorSet(value.set, value.writes);
            return null;
        },
    }
}

fn waitFenceValue(
    fence: *win.ID3D12Fence,
    target: u64,
    timeout_ns: u64,
) Error!void {
    const infinite = timeout_ns == std.math.maxInt(u64);
    const start = win.GetTickCount64();
    const timeout_ms: u64 = if (infinite)
        std.math.maxInt(u64)
    else
        (timeout_ns + 999_999) / 1_000_000;
    while (fence.getCompletedValue() < target) {
        if (!infinite and win.GetTickCount64() - start >= timeout_ms) {
            return error.Timeout;
        }
        win.Sleep(0);
    }
}

fn writeDescriptorSet(
    self: *Dx3d12,
    set_resource: Resource,
    writes: []const types.DescriptorWrite,
) Error!void {
    const set_slot = try self.lookup(set_resource, .descriptor_set);
    const set = &set_slot.handle.descriptor_set;
    const layout_slot = try self.lookup(
        set.layout,
        .descriptor_set_layout,
    );
    const bindings = layout_slot.handle.descriptor_set_layout.bindings;

    for (writes) |write| {
        var shader_offset: u32 = 0;
        var sampler_offset: u32 = 0;
        var found: ?types.DescriptorSetLayoutDescription.DescriptorBinding = null;
        for (bindings) |binding| {
            if (binding.kind != .sampler) {
                shader_offset += binding.count;
                if (binding.kind == .combined_image_sampler) {
                    sampler_offset += binding.count;
                }
            } else {
                sampler_offset += binding.count;
            }
            if (binding.binding == write.binding) {
                found = binding;
                break;
            }
        }
        const binding = found orelse return error.InvalidDescription;
        if (write.array_index >= binding.count) {
            return error.InvalidDescription;
        }
        if (binding.kind != .sampler) shader_offset -= binding.count;
        if (binding.kind == .sampler or
            binding.kind == .combined_image_sampler)
        {
            sampler_offset -= binding.count;
        }
        const shader_index = if (binding.kind == .sampler)
            0
        else
            set.shader_start + shader_offset + write.array_index;
        const sampler_index = if (binding.kind == .sampler or
            binding.kind == .combined_image_sampler)
            set.sampler_start + sampler_offset + write.array_index
        else
            0;

        switch (write.kind) {
            .buffer => |buffer_write| {
                const buffer_slot = try self.lookup(
                    buffer_write.buffer,
                    .buffer,
                );
                const buffer = buffer_slot.handle.buffer;
                switch (binding.kind) {
                    .uniform_buffer => {
                        if (buffer_write.offset % 256 != 0) {
                            return error.Unsupported;
                        }
                        const size: u32 = if (buffer_write.size == 0)
                            @intCast(@min(buffer.size, 65536))
                        else
                            @intCast(@min(buffer_write.size, 65536));
                        const view = win.D3D12_CONSTANT_BUFFER_VIEW_DESC{
                            .buffer_location = buffer.gpu_va + buffer_write.offset,
                            .size_in_bytes = @intCast(alignForward(
                                size,
                                256,
                            )),
                        };
                        self.device.createConstantBufferView(
                            &view,
                            self.shader_heap.cpu(shader_index),
                        );
                    },
                    .storage_buffer => {
                        const count: u32 = if (buffer_write.size == 0)
                            @intCast((buffer.size - buffer_write.offset) / 4)
                        else
                            @intCast(buffer_write.size / 4);
                        var view = std.mem.zeroes(win.D3D12_UNORDERED_ACCESS_VIEW_DESC);
                        view.format = win.DXGI_FORMAT_UNKNOWN;
                        view.view_dimension = win.D3D12_UAV_DIMENSION_BUFFER;
                        view.u.buffer = .{
                            .first_element = buffer_write.offset / 4,
                            .num_elements = count,
                            .structure_byte_stride = 0,
                            .counter_offset_in_bytes = 0,
                            .flags = 1,
                        };
                        self.device.createUnorderedAccessView(
                            buffer.resource,
                            null,
                            &view,
                            self.shader_heap.cpu(shader_index),
                        );
                    },
                    else => return error.InvalidDescription,
                }
            },
            .texture => |texture_write| {
                const view_slot = try self.lookup(
                    texture_write.view,
                    .texture_view,
                );
                const view = view_slot.handle.texture_view;
                switch (binding.kind) {
                    .sampled_texture, .combined_image_sampler => {
                        const source = view.srv orelse
                            return error.Unsupported;
                        self.device.copyDescriptorsSimple(
                            1,
                            self.shader_heap.cpu(shader_index),
                            self.shader_heap.cpu(source),
                            win.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
                        );
                    },
                    .storage_texture => {
                        const source = view.uav orelse
                            return error.Unsupported;
                        self.device.copyDescriptorsSimple(
                            1,
                            self.shader_heap.cpu(shader_index),
                            self.shader_heap.cpu(source),
                            win.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
                        );
                    },
                    else => return error.InvalidDescription,
                }
                if (binding.kind == .combined_image_sampler) {
                    const sampler_resource = texture_write.sampler orelse
                        return error.InvalidDescription;
                    const sampler_slot = try self.lookup(
                        sampler_resource,
                        .sampler,
                    );
                    self.device.copyDescriptorsSimple(
                        1,
                        self.sampler_heap.cpu(sampler_index),
                        self.sampler_heap.cpu(sampler_slot.handle.sampler),
                        win.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
                    );
                }
            },
            .sampler => |sampler_resource| {
                if (binding.kind != .sampler) {
                    return error.InvalidDescription;
                }
                const sampler_slot = try self.lookup(
                    sampler_resource,
                    .sampler,
                );
                self.device.copyDescriptorsSimple(
                    1,
                    self.sampler_heap.cpu(sampler_index),
                    self.sampler_heap.cpu(sampler_slot.handle.sampler),
                    win.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
                );
            },
        }
    }
}

fn query(
    self: *Dx3d12,
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
            Version.make(0, 12, 0, 0),
        ),
        .device_name => .{
            .support = .support,
            .result = try writeBytes(
                output_mode,
                "Direct3D 12 device",
            ),
        },
        .driver_name => .{
            .support = .support,
            .result = try writeBytes(output_mode, "Direct3D 12"),
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
            if (toDxgiFormat(value.format) == null) {
                break :blk .{ .support = .unsupport };
            }
            const wanted = value.usage;
            const supported =
                (!wanted.storage or
                    value.format == .r8g8b8a8_unorm or
                    value.format == .r8g8b8a8_srgb or
                    value.format == .r32_float or
                    value.format == .r32_uint or
                    value.format == .r32g32b32a32_float) and
                !wanted.depth_attachment;
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
    self: *Dx3d12,
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

fn createCommittedResource(
    self: *Dx3d12,
    heap_type: u32,
    desc: *const win.D3D12_RESOURCE_DESC,
    initial_state: u32,
    clear_value: ?*const win.D3D12_CLEAR_VALUE,
) Error!*win.ID3D12Resource {
    var heap_properties = std.mem.zeroes(win.D3D12_HEAP_PROPERTIES);
    heap_properties.type = heap_type;
    heap_properties.cpu_page_property = win.D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    heap_properties.memory_pool_preference = win.D3D12_MEMORY_POOL_UNKNOWN;
    var raw: ?*anyopaque = null;
    const hr = self.device.createCommittedResource(
        &heap_properties,
        win.D3D12_HEAP_FLAG_NONE,
        desc,
        initial_state,
        clear_value,
        &win.IID_ID3D12Resource,
        &raw,
    );
    if (win.failed(hr) or raw == null) return mapError(hr);
    return @ptrCast(@alignCast(raw.?));
}

fn beginUpload(self: *Dx3d12) Error!void {
    const reset_hr = self.upload_allocator.reset();
    if (win.failed(reset_hr)) return mapError(reset_hr);
    const list_hr = self.upload_list.reset(
        self.upload_allocator,
        null,
    );
    if (win.failed(list_hr)) return mapError(list_hr);
}

fn endUpload(self: *Dx3d12) Error!void {
    const close_hr = self.upload_list.close();
    if (win.failed(close_hr)) return mapError(close_hr);
    const lists = [_]?*win.ID3D12CommandList{
        @ptrCast(self.upload_list),
    };
    self.queue.executeCommandLists(1, &lists);
    self.upload_value += 1;
    const signal_hr = self.queue.signal(
        self.upload_fence,
        self.upload_value,
    );
    if (win.failed(signal_hr)) return mapError(signal_hr);
    try waitFenceValue(
        self.upload_fence,
        self.upload_value,
        std.math.maxInt(u64),
    );
}

fn uploadBufferData(
    self: *Dx3d12,
    destination: *win.ID3D12Resource,
    destination_size: u64,
    data: []const u8,
) Error!void {
    if (data.len == 0) return;
    if (data.len > destination_size) return error.InvalidDescription;
    var desc = std.mem.zeroes(win.D3D12_RESOURCE_DESC);
    desc.dimension = win.D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.width = alignForward(data.len, 512);
    desc.height = 1;
    desc.depth_or_array_size = 1;
    desc.mip_levels = 1;
    desc.format = win.DXGI_FORMAT_UNKNOWN;
    desc.sample_desc = .{ .count = 1, .quality = 0 };
    desc.layout = win.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    const upload = try self.createCommittedResource(
        win.D3D12_HEAP_TYPE_UPLOAD,
        &desc,
        win.D3D12_RESOURCE_STATE_GENERIC_READ,
        null,
    );
    defer _ = upload.release();
    var ptr: ?*anyopaque = null;
    const map_hr = upload.map(0, null, &ptr);
    if (win.failed(map_hr) or ptr == null) return mapError(map_hr);
    @memcpy(@as([*]u8, @ptrCast(ptr.?))[0..data.len], data);
    upload.unmap(0, null);
    try self.beginUpload();
    self.upload_list.copyBufferRegion(
        destination,
        0,
        upload,
        0,
        data.len,
    );
    try self.endUpload();
}

fn uploadTextureData(
    self: *Dx3d12,
    destination: *win.ID3D12Resource,
    description: types.TextureDescription,
    data: types.TextureData,
) Error!void {
    const bpp = description.format.bytesPerPixel() orelse
        return error.InvalidDescription;
    const tight_row = @as(u64, description.width) * bpp;
    const source_row_pitch: u64 = if (data.row_pitch == 0)
        tight_row
    else
        data.row_pitch;
    const source_image_height: u64 = if (data.image_height == 0)
        description.height
    else
        data.image_height;
    const row_pitch = alignForward(tight_row, 256);
    const depth: u32 = if (description.type == .@"3d")
        description.depth
    else
        1;
    const layers: u32 = if (description.type == .@"3d")
        1
    else
        description.array_layers;
    const slice_size = row_pitch * description.height * depth;
    const total_size = slice_size * layers;
    const required = source_row_pitch * source_image_height * depth * layers;
    if (data.bytes.len < required) return error.InvalidDescription;
    if (total_size > std.math.maxInt(u32)) return error.Unsupported;

    var desc = std.mem.zeroes(win.D3D12_RESOURCE_DESC);
    desc.dimension = win.D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.width = alignForward(total_size, 512);
    desc.height = 1;
    desc.depth_or_array_size = 1;
    desc.mip_levels = 1;
    desc.format = win.DXGI_FORMAT_UNKNOWN;
    desc.sample_desc = .{ .count = 1, .quality = 0 };
    desc.layout = win.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    const upload = try self.createCommittedResource(
        win.D3D12_HEAP_TYPE_UPLOAD,
        &desc,
        win.D3D12_RESOURCE_STATE_GENERIC_READ,
        null,
    );
    defer _ = upload.release();
    var ptr: ?*anyopaque = null;
    const map_hr = upload.map(0, null, &ptr);
    if (win.failed(map_hr) or ptr == null) return mapError(map_hr);
    const dst_bytes: [*]u8 = @ptrCast(ptr.?);
    var layer: u32 = 0;
    while (layer < layers) : (layer += 1) {
        var z: u32 = 0;
        while (z < depth) : (z += 1) {
            const source_base = @as(u64, layer) * source_row_pitch *
                source_image_height * depth +
                @as(u64, z) * source_row_pitch * source_image_height;
            const dst_base = @as(u64, layer) * slice_size +
                @as(u64, z) * row_pitch * description.height;
            var y: u32 = 0;
            while (y < description.height) : (y += 1) {
                const source_offset = source_base +
                    @as(u64, y) * source_row_pitch;
                const dst_offset = dst_base +
                    @as(u64, y) * row_pitch;
                @memcpy(
                    dst_bytes[@intCast(dst_offset)..][0..@intCast(tight_row)],
                    data.bytes[@intCast(source_offset)..][0..@intCast(tight_row)],
                );
            }
        }
    }
    upload.unmap(0, null);

    try self.beginUpload();
    const format = toDxgiFormat(description.format) orelse
        return error.Unsupported;
    var copy_layer: u32 = 0;
    while (copy_layer < layers) : (copy_layer += 1) {
        var dst = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
        dst.resource = destination;
        dst.type = win.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst.u = .{
            .subresource_index = if (description.type == .@"3d")
                0
            else
                copy_layer,
        };
        var src = std.mem.zeroes(win.D3D12_TEXTURE_COPY_LOCATION);
        src.resource = upload;
        src.type = win.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src.u = .{ .placed_footprint = .{
            .offset = @as(u64, copy_layer) * slice_size,
            .footprint = .{
                .format = format,
                .width = description.width,
                .height = description.height,
                .depth = if (description.type == .@"3d")
                    description.depth
                else
                    1,
                .row_pitch = @intCast(row_pitch),
            },
        } };
        self.upload_list.copyTextureRegion(
            &dst,
            0,
            0,
            0,
            &src,
            null,
        );
    }
    try self.endUpload();
}

fn transitionTexture(
    self: *Dx3d12,
    resource: *win.ID3D12Resource,
    before: u32,
    after: u32,
) Error!void {
    if (before == after) return;
    try self.beginUpload();
    var barrier = std.mem.zeroes(win.D3D12_RESOURCE_BARRIER);
    barrier.type = win.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.flags = win.D3D12_RESOURCE_BARRIER_FLAG_NONE;
    barrier.u = .{ .transition = .{
        .resource = resource,
        .subresource = win.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        .state_before = before,
        .state_after = after,
    } };
    self.upload_list.resourceBarrier(1, &barrier);
    try self.endUpload();
}

fn transitionBuffer(
    self: *Dx3d12,
    resource: *win.ID3D12Resource,
    before: u32,
    after: u32,
) Error!void {
    if (before == after) return;
    try self.beginUpload();
    var barrier = std.mem.zeroes(win.D3D12_RESOURCE_BARRIER);
    barrier.type = win.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.flags = win.D3D12_RESOURCE_BARRIER_FLAG_NONE;
    barrier.u = .{ .transition = .{
        .resource = resource,
        .subresource = win.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        .state_before = before,
        .state_after = after,
    } };
    self.upload_list.resourceBarrier(1, &barrier);
    try self.endUpload();
}

fn waitForGpu(self: *Dx3d12) void {
    self.upload_value += 1;
    const signal_hr = self.queue.signal(
        self.upload_fence,
        self.upload_value,
    );
    if (win.failed(signal_hr)) {
        log.warn("queue signal failed: 0x{x}", .{
            @as(u32, @bitCast(signal_hr)),
        });
        return;
    }
    waitFenceValue(
        self.upload_fence,
        self.upload_value,
        std.math.maxInt(u64),
    ) catch |err| {
        log.warn("wait for GPU failed: {}", .{err});
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

fn initialStateForUsage(usage: types.TextureUsage) u32 {
    if (usage.color_attachment) {
        return win.D3D12_RESOURCE_STATE_RENDER_TARGET;
    }
    if (usage.depth_attachment) {
        return win.D3D12_RESOURCE_STATE_DEPTH_WRITE;
    }
    if (usage.storage) {
        return win.D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    }
    if (usage.sampled) {
        return win.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
            win.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    }
    return win.D3D12_RESOURCE_STATE_COMMON;
}

fn textureState(layout: types.TextureLayout) u32 {
    return switch (layout) {
        .undefined => 0,
        .general => win.D3D12_RESOURCE_STATE_COMMON,
        .color_attachment => win.D3D12_RESOURCE_STATE_RENDER_TARGET,
        .depth_attachment => win.D3D12_RESOURCE_STATE_DEPTH_WRITE,
        .depth_read_only => win.D3D12_RESOURCE_STATE_DEPTH_READ,
        .stencil_read_only => win.D3D12_RESOURCE_STATE_DEPTH_READ,
        .depth_stencil_read_only => win.D3D12_RESOURCE_STATE_DEPTH_READ,
        .shader_read_only => win.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
            win.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        .transfer_src => win.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .transfer_dst => win.D3D12_RESOURCE_STATE_COPY_DEST,
        .present => win.D3D12_RESOURCE_STATE_PRESENT,
    };
}

fn bufferState(layout: types.TextureLayout) u32 {
    return switch (layout) {
        .transfer_src => win.D3D12_RESOURCE_STATE_COPY_SOURCE,
        .transfer_dst => win.D3D12_RESOURCE_STATE_COPY_DEST,
        .general => win.D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
        .shader_read_only => win.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
            win.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        else => 0,
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
        .undefined => return null,
    };
}

fn toD3D12Filter(value: types.SamplerDescription) u32 {
    if (value.anisotropy > 1) return win.D3D12_FILTER_ANISOTROPIC;
    if (value.min_filter == .linear and
        value.mag_filter == .linear and
        value.mipmap == .linear)
    {
        return win.D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    }
    if (value.min_filter == .nearest and
        value.mag_filter == .nearest and
        value.mipmap == .nearest)
    {
        return win.D3D12_FILTER_MIN_MAG_MIP_POINT;
    }
    return win.D3D12_FILTER_MIN_MAG_MIP_LINEAR;
}

fn toD3D12Address(mode: types.AddressMode) u32 {
    return switch (mode) {
        .repeat => win.D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .mirrored_repeat => win.D3D12_TEXTURE_ADDRESS_MODE_MIRROR,
        .clamp_to_edge => win.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .clamp_to_border => win.D3D12_TEXTURE_ADDRESS_MODE_BORDER,
    };
}

fn toD3D12Compare(op: types.CompareOp) u32 {
    return switch (op) {
        .never => win.D3D12_COMPARISON_FUNC_NEVER,
        .less => win.D3D12_COMPARISON_FUNC_LESS,
        .equal => win.D3D12_COMPARISON_FUNC_EQUAL,
        .less_equal => win.D3D12_COMPARISON_FUNC_LESS_EQUAL,
        .greater => win.D3D12_COMPARISON_FUNC_GREATER,
        .not_equal => win.D3D12_COMPARISON_FUNC_NOT_EQUAL,
        .greater_equal => win.D3D12_COMPARISON_FUNC_GREATER_EQUAL,
        .always => win.D3D12_COMPARISON_FUNC_ALWAYS,
    };
}

fn toD3D12Blend(factor: types.BlendFactor) u32 {
    return switch (factor) {
        .zero => win.D3D12_BLEND_ZERO,
        .one => win.D3D12_BLEND_ONE,
        .src_color => win.D3D12_BLEND_SRC_COLOR,
        .one_minus_src_color => win.D3D12_BLEND_INV_SRC_COLOR,
        .dst_color => win.D3D12_BLEND_DEST_COLOR,
        .one_minus_dst_color => win.D3D12_BLEND_INV_DEST_COLOR,
        .src_alpha => win.D3D12_BLEND_SRC_ALPHA,
        .one_minus_src_alpha => win.D3D12_BLEND_INV_SRC_ALPHA,
        .dst_alpha => win.D3D12_BLEND_DEST_ALPHA,
        .one_minus_dst_alpha => win.D3D12_BLEND_INV_DEST_ALPHA,
        .constant_color => win.D3D12_BLEND_BLEND_FACTOR,
        .one_minus_constant_color => win.D3D12_BLEND_INV_BLEND_FACTOR,
        .constant_alpha => win.D3D12_BLEND_BLEND_FACTOR,
        .one_minus_constant_alpha => win.D3D12_BLEND_INV_BLEND_FACTOR,
    };
}

fn toD3D12BlendOp(op: types.BlendOp) u32 {
    return switch (op) {
        .add => win.D3D12_BLEND_OP_ADD,
        .subtract => win.D3D12_BLEND_OP_SUBTRACT,
        .reverse_subtract => win.D3D12_BLEND_OP_REV_SUBTRACT,
        .min => win.D3D12_BLEND_OP_MIN,
        .max => win.D3D12_BLEND_OP_MAX,
    };
}

fn toD3D12Cull(cull: types.CullMode) u32 {
    return switch (cull) {
        .none => win.D3D12_CULL_MODE_NONE,
        .front => win.D3D12_CULL_MODE_FRONT,
        .back => win.D3D12_CULL_MODE_BACK,
        .front_and_back => win.D3D12_CULL_MODE_BACK,
    };
}

fn toD3D12Topology(topology: types.Topology) u32 {
    return switch (topology) {
        .point_list => win.D3D12_PRIMITIVE_TOPOLOGY_POINTLIST,
        .line_list => win.D3D12_PRIMITIVE_TOPOLOGY_LINELIST,
        .line_strip => win.D3D12_PRIMITIVE_TOPOLOGY_LINESTRIP,
        .triangle_list => win.D3D12_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
        .triangle_strip => win.D3D12_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        .triangle_fan => win.D3D12_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    };
}

fn toD3D12TopologyType(topology: types.Topology) u32 {
    return switch (topology) {
        .point_list => win.D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT,
        .line_list, .line_strip => win.D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE,
        .triangle_list, .triangle_strip, .triangle_fan => win.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
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

fn backend(vptr: *anyopaque) *Dx3d12 {
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
    const index = if (swapchain.handle3) |handle|
        handle.getCurrentBackBufferIndex()
    else blk: {
        const value = swapchain.next_index %
            swapchain.properties.image_count;
        swapchain.next_index +%= 1;
        break :blk value;
    };
    if (index >= swapchain.images.len) {
        return error.SurfaceOutOfDate;
    }
    if (swapchain.handle3 != null) {
        if (self.lookup(swapchain.images[index], .texture)) |image_slot| {
            image_slot.handle.texture.state = win.D3D12_RESOURCE_STATE_PRESENT;
        } else |_| {}
    }
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
    if (submission.command_buffers.len == 0) {
        if (submission.fence) |fence_resource| {
            try self.signalFence(fence_resource);
        }
        return;
    }
    const lists = self.allocator.alloc(
        ?*win.ID3D12CommandList,
        submission.command_buffers.len,
    ) catch return error.OutOfHostMemory;
    defer self.allocator.free(lists);
    for (submission.command_buffers, 0..) |resource, index| {
        const slot = try self.lookup(resource, .command_buffer);
        if (slot.handle.command_buffer.state != .ended) {
            return error.InvalidResource;
        }
        lists[index] = @ptrCast(slot.handle.command_buffer.list);
    }
    self.queue.executeCommandLists(
        @intCast(lists.len),
        lists.ptr,
    );
    for (submission.command_buffers) |resource| {
        if (self.lookup(resource, .command_buffer)) |slot| {
            slot.handle.command_buffer.state = .submitted;
        } else |_| {}
    }
    if (submission.fence) |fence_resource| {
        try self.signalFence(fence_resource);
    }
}

fn signalFence(self: *Dx3d12, fence_resource: Resource) Error!void {
    const slot = try self.lookup(fence_resource, .fence);
    const fence = &slot.handle.fence;
    fence.value += 1;
    fence.pending = false;
    const hr = self.queue.signal(fence.fence, fence.value);
    if (win.failed(hr)) return mapError(hr);
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
    self.waitForGpu();
}
