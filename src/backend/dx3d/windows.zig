//! Windows / Direct3D bindings for the dx3d11 and dx3d12 backends.
//!
//! Every Windows/Direct3D API surface used by vfrhi lives in this single
//! file. Functions are linked through `extern` declarations and COM objects
//! are wrapped as thin `extern struct` handles whose methods call into the
//! interface vtable by index. Layouts, enum values, GUIDs and vtable indices
//! follow the MinGW headers shipped with Zig.
//!
//! Method wrappers keep the order and names of their Windows SDK
//! counterparts, so they are not documented one by one. Methods that
//! return a struct by value follow the MinGW ABI and take an out
//! pointer instead of returning the struct.

/// A Windows `HRESULT`.
pub const HRESULT = i32;

/// Returns `true` when `hr` represents success (non-negative).
pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// Returns `true` when `hr` represents failure (negative).
pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

/// A Windows `GUID`.
pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// A Windows `LUID`.
pub const LUID = extern struct {
    low_part: u32,
    high_part: i32,
};

pub const HINSTANCE = *anyopaque;
pub const HWND = *anyopaque;
pub const HANDLE = *anyopaque;

pub const D3D12_GPU_VIRTUAL_ADDRESS = u64;

// ---------------------------------------------------------------------------
// DXGI format constants (subset used by vfrhi's `Format`).
// ---------------------------------------------------------------------------

pub const DXGI_FORMAT_UNKNOWN: u32 = 0x0;
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 0x2;
pub const DXGI_FORMAT_R32G32B32A32_UINT: u32 = 0x3;
pub const DXGI_FORMAT_R32G32B32_FLOAT: u32 = 0x6;
pub const DXGI_FORMAT_R32G32B32_UINT: u32 = 0x7;
pub const DXGI_FORMAT_R16G16B16A16_FLOAT: u32 = 0xa;
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 0x10;
pub const DXGI_FORMAT_R32G32_UINT: u32 = 0x11;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 0x1c;
pub const DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: u32 = 0x1d;
pub const DXGI_FORMAT_R16G16_FLOAT: u32 = 0x22;
pub const DXGI_FORMAT_D32_FLOAT: u32 = 0x28;
pub const DXGI_FORMAT_R32_FLOAT: u32 = 0x29;
pub const DXGI_FORMAT_R32_UINT: u32 = 0x2a;
pub const DXGI_FORMAT_D24_UNORM_S8_UINT: u32 = 0x2d;
pub const DXGI_FORMAT_R8G8_UNORM: u32 = 0x31;
pub const DXGI_FORMAT_R16_FLOAT: u32 = 0x36;
pub const DXGI_FORMAT_R8_UNORM: u32 = 0x3d;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 0x57;
pub const DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: u32 = 0x5b;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SWAP_EFFECT_DISCARD: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: u32 = 3;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

// ---------------------------------------------------------------------------
// D3D common constants.
// ---------------------------------------------------------------------------

pub const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;
pub const D3D_FEATURE_LEVEL_11_1: u32 = 0xb100;
pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;

pub const D3D_PRIMITIVE_TOPOLOGY_UNDEFINED: u32 = 0;
pub const D3D_PRIMITIVE_TOPOLOGY_POINTLIST: u32 = 1;
pub const D3D_PRIMITIVE_TOPOLOGY_LINELIST: u32 = 2;
pub const D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: u32 = 3;
pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const D3D12_PRIMITIVE_TOPOLOGY_UNDEFINED: u32 = 0;
pub const D3D12_PRIMITIVE_TOPOLOGY_POINTLIST: u32 = 1;
pub const D3D12_PRIMITIVE_TOPOLOGY_LINELIST: u32 = 2;
pub const D3D12_PRIMITIVE_TOPOLOGY_LINESTRIP: u32 = 3;
pub const D3D12_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const D3D12_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

// ---------------------------------------------------------------------------
// D3D12 enums (as `u32` constants).
// ---------------------------------------------------------------------------

pub const D3D12_COMMAND_LIST_TYPE_DIRECT: u32 = 0;
pub const D3D12_COMMAND_LIST_TYPE_BUNDLE: u32 = 1;
pub const D3D12_COMMAND_LIST_TYPE_COMPUTE: u32 = 2;
pub const D3D12_COMMAND_LIST_TYPE_COPY: u32 = 3;

pub const D3D12_COMMAND_QUEUE_PRIORITY_NORMAL: u32 = 0;
pub const D3D12_COMMAND_QUEUE_PRIORITY_HIGH: u32 = 100;
pub const D3D12_COMMAND_QUEUE_PRIORITY_GLOBAL_REALTIME: u32 = 10000;
pub const D3D12_COMMAND_QUEUE_FLAG_NONE: u32 = 0x0;

pub const D3D12_HEAP_TYPE_DEFAULT: u32 = 1;
pub const D3D12_HEAP_TYPE_UPLOAD: u32 = 2;
pub const D3D12_HEAP_TYPE_READBACK: u32 = 3;
pub const D3D12_HEAP_TYPE_CUSTOM: u32 = 4;

pub const D3D12_CPU_PAGE_PROPERTY_UNKNOWN: u32 = 0;
pub const D3D12_CPU_PAGE_PROPERTY_NOT_AVAILABLE: u32 = 1;
pub const D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE: u32 = 2;
pub const D3D12_CPU_PAGE_PROPERTY_WRITE_BACK: u32 = 3;

pub const D3D12_MEMORY_POOL_UNKNOWN: u32 = 0;
pub const D3D12_MEMORY_POOL_L0: u32 = 1;
pub const D3D12_MEMORY_POOL_L1: u32 = 2;

pub const D3D12_HEAP_FLAG_NONE: u32 = 0x0;

pub const D3D12_RESOURCE_STATE_COMMON: u32 = 0;
pub const D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER: u32 = 0x1;
pub const D3D12_RESOURCE_STATE_INDEX_BUFFER: u32 = 0x2;
pub const D3D12_RESOURCE_STATE_RENDER_TARGET: u32 = 0x4;
pub const D3D12_RESOURCE_STATE_UNORDERED_ACCESS: u32 = 0x8;
pub const D3D12_RESOURCE_STATE_DEPTH_WRITE: u32 = 0x10;
pub const D3D12_RESOURCE_STATE_DEPTH_READ: u32 = 0x20;
pub const D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE: u32 = 0x40;
pub const D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE: u32 = 0x80;
pub const D3D12_RESOURCE_STATE_COPY_DEST: u32 = 0x400;
pub const D3D12_RESOURCE_STATE_COPY_SOURCE: u32 = 0x800;
pub const D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT: u32 = 0x200;
pub const D3D12_RESOURCE_STATE_STREAM_OUT: u32 = 0x100;
pub const D3D12_RESOURCE_STATE_GENERIC_READ: u32 = 0x1 | 0x2 | 0x40 | 0x80 | 0x200 | 0x800;
pub const D3D12_RESOURCE_STATE_PRESENT: u32 = 0x0;

pub const D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX: u32 = 0;
pub const D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT: u32 = 1;

pub const D3D12_RESOURCE_BARRIER_TYPE_TRANSITION: u32 = 0;
pub const D3D12_RESOURCE_BARRIER_TYPE_ALIASING: u32 = 1;
pub const D3D12_RESOURCE_BARRIER_TYPE_UAV: u32 = 2;
pub const D3D12_RESOURCE_BARRIER_FLAG_NONE: u32 = 0x0;
pub const D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY: u32 = 0x1;
pub const D3D12_RESOURCE_BARRIER_FLAG_END_ONLY: u32 = 0x2;
pub const D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES: u32 = 0xffffffff;

pub const D3D12_RESOURCE_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D12_RESOURCE_DIMENSION_BUFFER: u32 = 1;
pub const D3D12_RESOURCE_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D12_RESOURCE_DIMENSION_TEXTURE2D: u32 = 3;
pub const D3D12_RESOURCE_DIMENSION_TEXTURE3D: u32 = 4;

pub const D3D12_TEXTURE_LAYOUT_UNKNOWN: u32 = 0;
pub const D3D12_TEXTURE_LAYOUT_ROW_MAJOR: u32 = 1;
pub const D3D12_TEXTURE_LAYOUT_64KB_UNDEFINED_SWIZZLE: u32 = 2;
pub const D3D12_TEXTURE_LAYOUT_64KB_STANDARD_SWIZZLE: u32 = 3;

pub const D3D12_RESOURCE_FLAG_NONE: u32 = 0x0;
pub const D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET: u32 = 0x1;
pub const D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL: u32 = 0x2;
pub const D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS: u32 = 0x4;

pub const D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV: u32 = 0;
pub const D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER: u32 = 1;
pub const D3D12_DESCRIPTOR_HEAP_TYPE_RTV: u32 = 2;
pub const D3D12_DESCRIPTOR_HEAP_TYPE_DSV: u32 = 3;
pub const D3D12_DESCRIPTOR_HEAP_FLAG_NONE: u32 = 0x0;
pub const D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE: u32 = 0x1;

pub const D3D12_DESCRIPTOR_RANGE_TYPE_SRV: u32 = 0;
pub const D3D12_DESCRIPTOR_RANGE_TYPE_UAV: u32 = 1;
pub const D3D12_DESCRIPTOR_RANGE_TYPE_CBV: u32 = 2;
pub const D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER: u32 = 3;
pub const D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND: u32 = 0xffffffff;

pub const D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: u32 = 0;
pub const D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS: u32 = 1;
pub const D3D12_ROOT_PARAMETER_TYPE_CBV: u32 = 2;
pub const D3D12_ROOT_PARAMETER_TYPE_SRV: u32 = 3;
pub const D3D12_ROOT_PARAMETER_TYPE_UAV: u32 = 4;

pub const D3D12_SHADER_VISIBILITY_ALL: u32 = 0;
pub const D3D12_SHADER_VISIBILITY_VERTEX: u32 = 1;
pub const D3D12_SHADER_VISIBILITY_PIXEL: u32 = 5;

pub const D3D12_ROOT_SIGNATURE_FLAG_NONE: u32 = 0x0;
pub const D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT: u32 = 0x1;
pub const D3D12_ROOT_SIGNATURE_FLAG_ALLOW_STREAM_OUTPUT: u32 = 0x40;

pub const D3D12_FILTER_MIN_MAG_MIP_POINT: u32 = 0x0;
pub const D3D12_FILTER_MIN_MAG_POINT_MIP_LINEAR: u32 = 0x1;
pub const D3D12_FILTER_MIN_POINT_MAG_LINEAR_MIP_POINT: u32 = 0x4;
pub const D3D12_FILTER_MIN_POINT_MAG_MIP_LINEAR: u32 = 0x5;
pub const D3D12_FILTER_MIN_LINEAR_MAG_MIP_POINT: u32 = 0x10;
pub const D3D12_FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR: u32 = 0x11;
pub const D3D12_FILTER_MIN_MAG_LINEAR_MIP_POINT: u32 = 0x14;
pub const D3D12_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D12_FILTER_ANISOTROPIC: u32 = 0x55;

pub const D3D12_TEXTURE_ADDRESS_MODE_WRAP: u32 = 1;
pub const D3D12_TEXTURE_ADDRESS_MODE_MIRROR: u32 = 2;
pub const D3D12_TEXTURE_ADDRESS_MODE_CLAMP: u32 = 3;
pub const D3D12_TEXTURE_ADDRESS_MODE_BORDER: u32 = 4;
pub const D3D12_TEXTURE_ADDRESS_MODE_MIRROR_ONCE: u32 = 5;

pub const D3D12_COMPARISON_FUNC_NEVER: u32 = 1;
pub const D3D12_COMPARISON_FUNC_LESS: u32 = 2;
pub const D3D12_COMPARISON_FUNC_EQUAL: u32 = 3;
pub const D3D12_COMPARISON_FUNC_LESS_EQUAL: u32 = 4;
pub const D3D12_COMPARISON_FUNC_GREATER: u32 = 5;
pub const D3D12_COMPARISON_FUNC_NOT_EQUAL: u32 = 6;
pub const D3D12_COMPARISON_FUNC_GREATER_EQUAL: u32 = 7;
pub const D3D12_COMPARISON_FUNC_ALWAYS: u32 = 8;

pub const D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK: u32 = 0;
pub const D3D12_STATIC_BORDER_COLOR_OPAQUE_BLACK: u32 = 1;
pub const D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE: u32 = 2;

pub const D3D12_STENCIL_OP_KEEP: u32 = 1;
pub const D3D12_STENCIL_OP_ZERO: u32 = 2;
pub const D3D12_STENCIL_OP_REPLACE: u32 = 3;
pub const D3D12_STENCIL_OP_INCR_SAT: u32 = 4;
pub const D3D12_STENCIL_OP_DECR_SAT: u32 = 5;
pub const D3D12_STENCIL_OP_INVERT: u32 = 6;
pub const D3D12_STENCIL_OP_INCR: u32 = 7;
pub const D3D12_STENCIL_OP_DECR: u32 = 8;

pub const D3D12_DEPTH_WRITE_MASK_ZERO: u32 = 0;
pub const D3D12_DEPTH_WRITE_MASK_ALL: u32 = 1;

pub const D3D12_BLEND_ZERO: u32 = 1;
pub const D3D12_BLEND_ONE: u32 = 2;
pub const D3D12_BLEND_SRC_COLOR: u32 = 3;
pub const D3D12_BLEND_INV_SRC_COLOR: u32 = 4;
pub const D3D12_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D12_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D12_BLEND_DEST_ALPHA: u32 = 7;
pub const D3D12_BLEND_INV_DEST_ALPHA: u32 = 8;
pub const D3D12_BLEND_DEST_COLOR: u32 = 9;
pub const D3D12_BLEND_INV_DEST_COLOR: u32 = 10;
pub const D3D12_BLEND_SRC_ALPHA_SAT: u32 = 11;
pub const D3D12_BLEND_BLEND_FACTOR: u32 = 14;
pub const D3D12_BLEND_INV_BLEND_FACTOR: u32 = 15;

pub const D3D12_BLEND_OP_ADD: u32 = 1;
pub const D3D12_BLEND_OP_SUBTRACT: u32 = 2;
pub const D3D12_BLEND_OP_REV_SUBTRACT: u32 = 3;
pub const D3D12_BLEND_OP_MIN: u32 = 4;
pub const D3D12_BLEND_OP_MAX: u32 = 5;

pub const D3D12_LOGIC_OP_CLEAR: u32 = 0x0;
pub const D3D12_LOGIC_OP_SET: u32 = 0x1;
pub const D3D12_LOGIC_OP_COPY: u32 = 0x2;
pub const D3D12_LOGIC_OP_NOOP: u32 = 0x4;

pub const D3D12_COLOR_WRITE_ENABLE_RED: u32 = 0x1;
pub const D3D12_COLOR_WRITE_ENABLE_GREEN: u32 = 0x2;
pub const D3D12_COLOR_WRITE_ENABLE_BLUE: u32 = 0x4;
pub const D3D12_COLOR_WRITE_ENABLE_ALPHA: u32 = 0x8;
pub const D3D12_COLOR_WRITE_ENABLE_ALL: u32 = 0xf;

pub const D3D12_FILL_MODE_WIREFRAME: u32 = 2;
pub const D3D12_FILL_MODE_SOLID: u32 = 3;

pub const D3D12_CULL_MODE_NONE: u32 = 1;
pub const D3D12_CULL_MODE_FRONT: u32 = 2;
pub const D3D12_CULL_MODE_BACK: u32 = 3;

pub const D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA: u32 = 0;
pub const D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA: u32 = 1;

pub const D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED: u32 = 0;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_UNDEFINED: u32 = 0;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT: u32 = 1;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE: u32 = 2;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE: u32 = 3;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_PATCH: u32 = 4;

pub const D3D12_SRV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D12_SRV_DIMENSION_BUFFER: u32 = 1;
pub const D3D12_SRV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D12_SRV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D12_SRV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D12_SRV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D12_SRV_DIMENSION_TEXTURE2DMS: u32 = 6;
pub const D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY: u32 = 7;
pub const D3D12_SRV_DIMENSION_TEXTURE3D: u32 = 8;
pub const D3D12_SRV_DIMENSION_TEXTURECUBE: u32 = 9;
pub const D3D12_SRV_DIMENSION_TEXTURECUBEARRAY: u32 = 10;

pub const D3D12_UAV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D12_UAV_DIMENSION_BUFFER: u32 = 1;
pub const D3D12_UAV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D12_UAV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D12_UAV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D12_UAV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D12_UAV_DIMENSION_TEXTURE3D: u32 = 8;

pub const D3D12_RTV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D12_RTV_DIMENSION_BUFFER: u32 = 1;
pub const D3D12_RTV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D12_RTV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D12_RTV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D12_RTV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D12_RTV_DIMENSION_TEXTURE2DMS: u32 = 6;
pub const D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY: u32 = 7;
pub const D3D12_RTV_DIMENSION_TEXTURE3D: u32 = 8;

pub const D3D12_DSV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D12_DSV_DIMENSION_TEXTURE1D: u32 = 1;
pub const D3D12_DSV_DIMENSION_TEXTURE1DARRAY: u32 = 2;
pub const D3D12_DSV_DIMENSION_TEXTURE2D: u32 = 3;
pub const D3D12_DSV_DIMENSION_TEXTURE2DARRAY: u32 = 4;
pub const D3D12_DSV_DIMENSION_TEXTURE2DMS: u32 = 5;
pub const D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY: u32 = 6;
pub const D3D12_DSV_FLAG_NONE: u32 = 0x0;
pub const D3D12_DSV_FLAG_READ_ONLY_DEPTH: u32 = 0x1;
pub const D3D12_DSV_FLAG_READ_ONLY_STENCIL: u32 = 0x2;

pub const D3D12_CLEAR_FLAG_DEPTH: u32 = 0x1;
pub const D3D12_CLEAR_FLAG_STENCIL: u32 = 0x2;

pub const D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING: u32 = 0x1688;
pub const D3D12_DEFAULT_STENCIL_READ_MASK: u32 = 0xff;
pub const D3D12_DEFAULT_STENCIL_WRITE_MASK: u32 = 0xff;

// ---------------------------------------------------------------------------
// DXGI structs.
// ---------------------------------------------------------------------------

/// Matches the Windows `DXGI_SAMPLE_DESC` structure.
pub const DXGI_SAMPLE_DESC = extern struct {
    count: u32,
    quality: u32,
};

/// Matches the Windows `DXGI_SWAP_CHAIN_DESC1` structure.
pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    width: u32,
    height: u32,
    format: u32,
    stereo: i32,
    sample_desc: DXGI_SAMPLE_DESC,
    buffer_usage: u32,
    buffer_count: u32,
    scaling: u32,
    swap_effect: u32,
    alpha_mode: u32,
    flags: u32,
};

/// Matches the Windows `DXGI_ADAPTER_DESC1` structure.
pub const DXGI_ADAPTER_DESC1 = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    adapter_luid: LUID,
    flags: u32,
};

// ---------------------------------------------------------------------------
// D3D12 structs.
// ---------------------------------------------------------------------------

/// Matches the Windows `D3D12_COMMAND_QUEUE_DESC` structure.
pub const D3D12_COMMAND_QUEUE_DESC = extern struct {
    type: u32,
    priority: i32,
    flags: u32,
    node_mask: u32,
};

/// Matches the Windows `D3D12_HEAP_PROPERTIES` structure.
pub const D3D12_HEAP_PROPERTIES = extern struct {
    type: u32,
    cpu_page_property: u32,
    memory_pool_preference: u32,
    creation_node_mask: u32,
    visible_node_mask: u32,
};

/// Matches the Windows `D3D12_RESOURCE_DESC` structure.
pub const D3D12_RESOURCE_DESC = extern struct {
    dimension: u32,
    alignment: u64,
    width: u64,
    height: u32,
    depth_or_array_size: u16,
    mip_levels: u16,
    format: u32,
    sample_desc: DXGI_SAMPLE_DESC,
    layout: u32,
    flags: u32,
};

/// Matches the Windows `D3D12_RESOURCE_TRANSITION_BARRIER` structure.
pub const D3D12_RESOURCE_TRANSITION_BARRIER = extern struct {
    resource: ?*ID3D12Resource,
    subresource: u32,
    state_before: u32,
    state_after: u32,
};

/// Matches the Windows `D3D12_RESOURCE_ALIASING_BARRIER` structure.
pub const D3D12_RESOURCE_ALIASING_BARRIER = extern struct {
    resource_before: ?*ID3D12Resource,
    resource_after: ?*ID3D12Resource,
};

/// Matches the Windows `D3D12_RESOURCE_UAV_BARRIER` structure.
pub const D3D12_RESOURCE_UAV_BARRIER = extern struct {
    resource: ?*ID3D12Resource,
};

/// Matches the Windows `D3D12_RESOURCE_BARRIER` structure.
pub const D3D12_RESOURCE_BARRIER = extern struct {
    type: u32,
    flags: u32,
    u: extern union {
        transition: D3D12_RESOURCE_TRANSITION_BARRIER,
        aliasing: D3D12_RESOURCE_ALIASING_BARRIER,
        uav: D3D12_RESOURCE_UAV_BARRIER,
    },
};

/// Matches the Windows `D3D12_RANGE` structure.
pub const D3D12_RANGE = extern struct {
    begin: usize,
    end: usize,
};

/// Matches the Windows `D3D12_CPU_DESCRIPTOR_HANDLE` structure.
pub const D3D12_CPU_DESCRIPTOR_HANDLE = extern struct {
    ptr: usize,
};

/// Matches the Windows `D3D12_GPU_DESCRIPTOR_HANDLE` structure.
pub const D3D12_GPU_DESCRIPTOR_HANDLE = extern struct {
    ptr: u64,
};

/// Matches the Windows `D3D12_DESCRIPTOR_HEAP_DESC` structure.
pub const D3D12_DESCRIPTOR_HEAP_DESC = extern struct {
    type: u32,
    num_descriptors: u32,
    flags: u32,
    node_mask: u32,
};

/// Matches the Windows `D3D12_DESCRIPTOR_RANGE` structure.
pub const D3D12_DESCRIPTOR_RANGE = extern struct {
    range_type: u32,
    num_descriptors: u32,
    base_shader_register: u32,
    register_space: u32,
    offset_in_descriptors_from_table_start: u32,
};

/// Matches the Windows `D3D12_ROOT_DESCRIPTOR_TABLE` structure.
pub const D3D12_ROOT_DESCRIPTOR_TABLE = extern struct {
    num_descriptor_ranges: u32,
    descriptor_ranges: ?*const D3D12_DESCRIPTOR_RANGE,
};

/// Matches the Windows `D3D12_ROOT_CONSTANTS` structure.
pub const D3D12_ROOT_CONSTANTS = extern struct {
    shader_register: u32,
    register_space: u32,
    num_32bit_values: u32,
};

/// Matches the Windows `D3D12_ROOT_DESCRIPTOR` structure.
pub const D3D12_ROOT_DESCRIPTOR = extern struct {
    shader_register: u32,
    register_space: u32,
};

/// Matches the Windows `D3D12_ROOT_PARAMETER` structure.
pub const D3D12_ROOT_PARAMETER = extern struct {
    parameter_type: u32,
    u: extern union {
        descriptor_table: D3D12_ROOT_DESCRIPTOR_TABLE,
        constants: D3D12_ROOT_CONSTANTS,
        descriptor: D3D12_ROOT_DESCRIPTOR,
    },
    shader_visibility: u32,
};

/// Matches the Windows `D3D12_ROOT_SIGNATURE_DESC` structure.
pub const D3D12_ROOT_SIGNATURE_DESC = extern struct {
    num_parameters: u32,
    parameters: ?*const D3D12_ROOT_PARAMETER,
    num_static_samplers: u32,
    static_samplers: ?*const D3D12_STATIC_SAMPLER_DESC,
    flags: u32,
};

/// Matches the Windows `D3D12_STATIC_SAMPLER_DESC` structure.
pub const D3D12_STATIC_SAMPLER_DESC = extern struct {
    filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    mip_lod_bias: f32,
    max_anisotropy: u32,
    comparison_func: u32,
    border_color: u32,
    min_lod: f32,
    max_lod: f32,
    shader_register: u32,
    register_space: u32,
    shader_visibility: u32,
};

/// Matches the Windows `D3D12_CONSTANT_BUFFER_VIEW_DESC` structure.
pub const D3D12_CONSTANT_BUFFER_VIEW_DESC = extern struct {
    buffer_location: u64,
    size_in_bytes: u32,
};

/// Matches the Windows `D3D12_BUFFER_SRV` structure.
pub const D3D12_BUFFER_SRV = extern struct {
    first_element: u64,
    num_elements: u32,
    structure_byte_stride: u32,
    flags: u32,
};

/// Matches the Windows `D3D12_TEX1D_SRV` structure.
pub const D3D12_TEX1D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEX1D_ARRAY_SRV` structure.
pub const D3D12_TEX1D_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_array_slice: u32,
    array_size: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEX2D_SRV` structure.
pub const D3D12_TEX2D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    plane_slice: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEX2D_ARRAY_SRV` structure.
pub const D3D12_TEX2D_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_array_slice: u32,
    array_size: u32,
    plane_slice: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEX2DMS_SRV` structure.
pub const D3D12_TEX2DMS_SRV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D12_TEX2DMS_ARRAY_SRV` structure.
pub const D3D12_TEX2DMS_ARRAY_SRV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX3D_SRV` structure.
pub const D3D12_TEX3D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEXCUBE_SRV` structure.
pub const D3D12_TEXCUBE_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_TEXCUBE_ARRAY_SRV` structure.
pub const D3D12_TEXCUBE_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_2d_array_face: u32,
    num_cubes: u32,
    resource_min_lod_clamp: f32,
};

/// Matches the Windows `D3D12_SHADER_RESOURCE_VIEW_DESC` structure.
pub const D3D12_SHADER_RESOURCE_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    shader_4_component_mapping: u32,
    u: extern union {
        buffer: D3D12_BUFFER_SRV,
        texture_1d: D3D12_TEX1D_SRV,
        texture_1d_array: D3D12_TEX1D_ARRAY_SRV,
        texture_2d: D3D12_TEX2D_SRV,
        texture_2d_array: D3D12_TEX2D_ARRAY_SRV,
        texture_2dms: D3D12_TEX2DMS_SRV,
        texture_2dms_array: D3D12_TEX2DMS_ARRAY_SRV,
        texture_3d: D3D12_TEX3D_SRV,
        texture_cube: D3D12_TEXCUBE_SRV,
        texture_cube_array: D3D12_TEXCUBE_ARRAY_SRV,
    },
};

/// Matches the Windows `D3D12_BUFFER_UAV` structure.
pub const D3D12_BUFFER_UAV = extern struct {
    first_element: u64,
    num_elements: u32,
    structure_byte_stride: u32,
    counter_offset_in_bytes: u64,
    flags: u32,
};

/// Matches the Windows `D3D12_TEX1D_UAV` structure.
pub const D3D12_TEX1D_UAV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D12_TEX1D_ARRAY_UAV` structure.
pub const D3D12_TEX1D_ARRAY_UAV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX2D_UAV` structure.
pub const D3D12_TEX2D_UAV = extern struct {
    mip_slice: u32,
    plane_slice: u32,
};

/// Matches the Windows `D3D12_TEX2D_ARRAY_UAV` structure.
pub const D3D12_TEX2D_ARRAY_UAV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
    plane_slice: u32,
};

/// Matches the Windows `D3D12_TEX3D_UAV` structure.
pub const D3D12_TEX3D_UAV = extern struct {
    mip_slice: u32,
    first_w_slice: u32,
    w_size: u32,
};

/// Matches the Windows `D3D12_UNORDERED_ACCESS_VIEW_DESC` structure.
pub const D3D12_UNORDERED_ACCESS_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    u: extern union {
        buffer: D3D12_BUFFER_UAV,
        texture_1d: D3D12_TEX1D_UAV,
        texture_1d_array: D3D12_TEX1D_ARRAY_UAV,
        texture_2d: D3D12_TEX2D_UAV,
        texture_2d_array: D3D12_TEX2D_ARRAY_UAV,
        texture_3d: D3D12_TEX3D_UAV,
    },
};

/// Matches the Windows `D3D12_BUFFER_RTV` structure.
pub const D3D12_BUFFER_RTV = extern struct {
    first_element: u64,
    num_elements: u32,
};

/// Matches the Windows `D3D12_TEX1D_RTV` structure.
pub const D3D12_TEX1D_RTV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D12_TEX1D_ARRAY_RTV` structure.
pub const D3D12_TEX1D_ARRAY_RTV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX2D_RTV` structure.
pub const D3D12_TEX2D_RTV = extern struct {
    mip_slice: u32,
    plane_slice: u32,
};

/// Matches the Windows `D3D12_TEX2D_ARRAY_RTV` structure.
pub const D3D12_TEX2D_ARRAY_RTV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
    plane_slice: u32,
};

/// Matches the Windows `D3D12_TEX2DMS_RTV` structure.
pub const D3D12_TEX2DMS_RTV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D12_TEX2DMS_ARRAY_RTV` structure.
pub const D3D12_TEX2DMS_ARRAY_RTV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX3D_RTV` structure.
pub const D3D12_TEX3D_RTV = extern struct {
    mip_slice: u32,
    first_w_slice: u32,
    w_size: u32,
};

/// Matches the Windows `D3D12_RENDER_TARGET_VIEW_DESC` structure.
pub const D3D12_RENDER_TARGET_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    u: extern union {
        buffer: D3D12_BUFFER_RTV,
        texture_1d: D3D12_TEX1D_RTV,
        texture_1d_array: D3D12_TEX1D_ARRAY_RTV,
        texture_2d: D3D12_TEX2D_RTV,
        texture_2d_array: D3D12_TEX2D_ARRAY_RTV,
        texture_2dms: D3D12_TEX2DMS_RTV,
        texture_2dms_array: D3D12_TEX2DMS_ARRAY_RTV,
        texture_3d: D3D12_TEX3D_RTV,
    },
};

/// Matches the Windows `D3D12_TEX1D_DSV` structure.
pub const D3D12_TEX1D_DSV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D12_TEX1D_ARRAY_DSV` structure.
pub const D3D12_TEX1D_ARRAY_DSV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX2D_DSV` structure.
pub const D3D12_TEX2D_DSV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D12_TEX2D_ARRAY_DSV` structure.
pub const D3D12_TEX2D_ARRAY_DSV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_TEX2DMS_DSV` structure.
pub const D3D12_TEX2DMS_DSV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D12_TEX2DMS_ARRAY_DSV` structure.
pub const D3D12_TEX2DMS_ARRAY_DSV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D12_DEPTH_STENCIL_VIEW_DESC` structure.
pub const D3D12_DEPTH_STENCIL_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    flags: u32,
    u: extern union {
        texture_1d: D3D12_TEX1D_DSV,
        texture_1d_array: D3D12_TEX1D_ARRAY_DSV,
        texture_2d: D3D12_TEX2D_DSV,
        texture_2d_array: D3D12_TEX2D_ARRAY_DSV,
        texture_2dms: D3D12_TEX2DMS_DSV,
        texture_2dms_array: D3D12_TEX2DMS_ARRAY_DSV,
    },
};

/// Matches the Windows `D3D12_SAMPLER_DESC` structure.
pub const D3D12_SAMPLER_DESC = extern struct {
    filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    mip_lod_bias: f32,
    max_anisotropy: u32,
    comparison_func: u32,
    border_color: [4]f32,
    min_lod: f32,
    max_lod: f32,
};

/// Matches the Windows `D3D12_INPUT_ELEMENT_DESC` structure.
pub const D3D12_INPUT_ELEMENT_DESC = extern struct {
    semantic_name: ?[*:0]const u8,
    semantic_index: u32,
    format: u32,
    input_slot: u32,
    aligned_byte_offset: u32,
    input_slot_class: u32,
    instance_data_step_rate: u32,
};

/// Matches the Windows `D3D12_INPUT_LAYOUT_DESC` structure.
pub const D3D12_INPUT_LAYOUT_DESC = extern struct {
    input_element_descs: ?*const D3D12_INPUT_ELEMENT_DESC,
    num_elements: u32,
};

/// Matches the Windows `D3D12_VIEWPORT` structure.
pub const D3D12_VIEWPORT = extern struct {
    top_left_x: f32,
    top_left_y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

/// Matches the Windows `D3D12_RECT` structure.
pub const D3D12_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Matches the Windows `D3D12_BOX` structure.
pub const D3D12_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

/// Matches the Windows `D3D12_SHADER_BYTECODE` structure.
pub const D3D12_SHADER_BYTECODE = extern struct {
    shader_bytecode: ?*const anyopaque,
    bytecode_length: usize,
};

/// Matches the Windows `D3D12_STREAM_OUTPUT_DESC` structure.
pub const D3D12_STREAM_OUTPUT_DESC = extern struct {
    so_declaration: ?*const anyopaque,
    num_entries: u32,
    buffer_strides: ?[*]const u32,
    num_strides: u32,
    rasterized_stream: u32,
};

/// Matches the Windows `D3D12_RENDER_TARGET_BLEND_DESC` structure.
pub const D3D12_RENDER_TARGET_BLEND_DESC = extern struct {
    blend_enable: i32,
    logic_op_enable: i32,
    src_blend: u32,
    dest_blend: u32,
    blend_op: u32,
    src_blend_alpha: u32,
    dest_blend_alpha: u32,
    blend_op_alpha: u32,
    logic_op: u32,
    render_target_write_mask: u8,
};

/// Matches the Windows `D3D12_BLEND_DESC` structure.
pub const D3D12_BLEND_DESC = extern struct {
    alpha_to_coverage_enable: i32,
    independent_blend_enable: i32,
    render_target: [8]D3D12_RENDER_TARGET_BLEND_DESC,
};

/// Matches the Windows `D3D12_RASTERIZER_DESC` structure.
pub const D3D12_RASTERIZER_DESC = extern struct {
    fill_mode: u32,
    cull_mode: u32,
    front_counter_clockwise: i32,
    depth_bias: i32,
    depth_bias_clamp: f32,
    slope_scaled_depth_bias: f32,
    depth_clip_enable: i32,
    multisample_enable: i32,
    antialiased_line_enable: i32,
    forced_sample_count: u32,
    conservative_raster: u32,
};

/// Matches the Windows `D3D12_DEPTH_STENCILOP_DESC` structure.
pub const D3D12_DEPTH_STENCILOP_DESC = extern struct {
    stencil_fail_op: u32,
    stencil_depth_fail_op: u32,
    stencil_pass_op: u32,
    stencil_func: u32,
};

/// Matches the Windows `D3D12_DEPTH_STENCIL_DESC` structure.
pub const D3D12_DEPTH_STENCIL_DESC = extern struct {
    depth_enable: i32,
    depth_write_mask: u32,
    depth_func: u32,
    stencil_enable: i32,
    stencil_read_mask: u8,
    stencil_write_mask: u8,
    front_face: D3D12_DEPTH_STENCILOP_DESC,
    back_face: D3D12_DEPTH_STENCILOP_DESC,
};

/// Matches the Windows `D3D12_CACHED_PIPELINE_STATE` structure.
pub const D3D12_CACHED_PIPELINE_STATE = extern struct {
    cached_blob: ?*const anyopaque,
    cached_blob_size_in_bytes: usize,
};

/// Matches the Windows `D3D12_GRAPHICS_PIPELINE_STATE_DESC` structure.
pub const D3D12_GRAPHICS_PIPELINE_STATE_DESC = extern struct {
    root_signature: ?*ID3D12RootSignature,
    vs: D3D12_SHADER_BYTECODE,
    ps: D3D12_SHADER_BYTECODE,
    ds: D3D12_SHADER_BYTECODE,
    hs: D3D12_SHADER_BYTECODE,
    gs: D3D12_SHADER_BYTECODE,
    stream_output: D3D12_STREAM_OUTPUT_DESC,
    blend_state: D3D12_BLEND_DESC,
    sample_mask: u32,
    rasterizer_state: D3D12_RASTERIZER_DESC,
    depth_stencil_state: D3D12_DEPTH_STENCIL_DESC,
    input_layout: D3D12_INPUT_LAYOUT_DESC,
    ib_strip_cut_value: u32,
    primitive_topology_type: u32,
    num_render_targets: u32,
    rtv_formats: [8]u32,
    dsv_format: u32,
    sample_desc: DXGI_SAMPLE_DESC,
    node_mask: u32,
    cached_pso: D3D12_CACHED_PIPELINE_STATE,
    flags: u32,
};

/// Matches the Windows `D3D12_COMPUTE_PIPELINE_STATE_DESC` structure.
pub const D3D12_COMPUTE_PIPELINE_STATE_DESC = extern struct {
    root_signature: ?*ID3D12RootSignature,
    cs: D3D12_SHADER_BYTECODE,
    node_mask: u32,
    cached_pso: D3D12_CACHED_PIPELINE_STATE,
    flags: u32,
};

/// Matches the Windows `D3D12_SUBRESOURCE_FOOTPRINT` structure.
pub const D3D12_SUBRESOURCE_FOOTPRINT = extern struct {
    format: u32,
    width: u32,
    height: u32,
    depth: u32,
    row_pitch: u32,
};

/// Matches the Windows `D3D12_PLACED_SUBRESOURCE_FOOTPRINT` structure.
pub const D3D12_PLACED_SUBRESOURCE_FOOTPRINT = extern struct {
    offset: u64,
    footprint: D3D12_SUBRESOURCE_FOOTPRINT,
};

/// Matches the Windows `D3D12_TEXTURE_COPY_LOCATION` structure.
pub const D3D12_TEXTURE_COPY_LOCATION = extern struct {
    resource: ?*ID3D12Resource,
    type: u32,
    u: extern union {
        placed_footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT,
        subresource_index: u32,
    },
};

/// Matches the Windows `D3D12_INDEX_BUFFER_VIEW` structure.
pub const D3D12_INDEX_BUFFER_VIEW = extern struct {
    buffer_location: u64,
    size_in_bytes: u32,
    format: u32,
};

/// Matches the Windows `D3D12_VERTEX_BUFFER_VIEW` structure.
pub const D3D12_VERTEX_BUFFER_VIEW = extern struct {
    buffer_location: u64,
    size_in_bytes: u32,
    stride_in_bytes: u32,
};

/// Matches the Windows `D3D12_DEPTH_STENCIL_VALUE` structure.
pub const D3D12_DEPTH_STENCIL_VALUE = extern struct {
    depth: f32,
    stencil: u8,
};

/// Matches the Windows `D3D12_CLEAR_VALUE` structure.
pub const D3D12_CLEAR_VALUE = extern struct {
    format: u32,
    u: extern union {
        color: [4]f32,
        depth_stencil: D3D12_DEPTH_STENCIL_VALUE,
    },
};

// ---------------------------------------------------------------------------
// D3D11 enums (as `u32` constants).
// ---------------------------------------------------------------------------

pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
pub const D3D11_SDK_VERSION: u32 = 7;

pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_IMMUTABLE: u32 = 1;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;
pub const D3D11_USAGE_STAGING: u32 = 3;

pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_INDEX_BUFFER: u32 = 0x2;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;
pub const D3D11_BIND_DEPTH_STENCIL: u32 = 0x40;
pub const D3D11_BIND_UNORDERED_ACCESS: u32 = 0x80;

pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;
pub const D3D11_CPU_ACCESS_READ: u32 = 0x20000;

pub const D3D11_CLEAR_DEPTH: u32 = 0x1;
pub const D3D11_CLEAR_STENCIL: u32 = 0x2;

pub const D3D11_FORMAT_SUPPORT_BUFFER: u32 = 0x1;
pub const D3D11_FORMAT_SUPPORT_IA_VERTEX_BUFFER: u32 = 0x2;
pub const D3D11_FORMAT_SUPPORT_IA_INDEX_BUFFER: u32 = 0x4;
pub const D3D11_FORMAT_SUPPORT_SHADER_LOAD: u32 = 0x100;
pub const D3D11_FORMAT_SUPPORT_SHADER_SAMPLE: u32 = 0x200;
pub const D3D11_FORMAT_SUPPORT_RENDER_TARGET: u32 = 0x4000;
pub const D3D11_FORMAT_SUPPORT_BLENDABLE: u32 = 0x8000;
pub const D3D11_FORMAT_SUPPORT_DEPTH_STENCIL: u32 = 0x10000;
pub const D3D11_FORMAT_SUPPORT_CPU_LOCKABLE: u32 = 0x20000;
pub const D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW: u32 = 0x2000000;

pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const DXGI_ERROR_INVALID_CALL: HRESULT = @bitCast(@as(u32, 0x887A0001));
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
pub const DXGI_ERROR_WAS_STILL_DRAWING: HRESULT = @bitCast(@as(u32, 0x887A000A));
pub const DXGI_ERROR_UNSUPPORTED: HRESULT = @bitCast(@as(u32, 0x887A0004));

pub const D3D11_MAP_READ: u32 = 1;
pub const D3D11_MAP_WRITE: u32 = 2;
pub const D3D11_MAP_READ_WRITE: u32 = 3;
pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;
pub const D3D11_MAP_WRITE_NO_OVERWRITE: u32 = 5;

pub const D3D11_FILTER_MIN_MAG_MIP_POINT: u32 = 0x0;
pub const D3D11_FILTER_MIN_MAG_POINT_MIP_LINEAR: u32 = 0x1;
pub const D3D11_FILTER_MIN_POINT_MAG_LINEAR_MIP_POINT: u32 = 0x4;
pub const D3D11_FILTER_MIN_POINT_MAG_MIP_LINEAR: u32 = 0x5;
pub const D3D11_FILTER_MIN_LINEAR_MAG_MIP_POINT: u32 = 0x10;
pub const D3D11_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D11_FILTER_ANISOTROPIC: u32 = 0x55;

pub const D3D11_TEXTURE_ADDRESS_WRAP: u32 = 1;
pub const D3D11_TEXTURE_ADDRESS_MIRROR: u32 = 2;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_TEXTURE_ADDRESS_BORDER: u32 = 4;
pub const D3D11_TEXTURE_ADDRESS_MIRROR_ONCE: u32 = 5;

pub const D3D11_COMPARISON_NEVER: u32 = 1;
pub const D3D11_COMPARISON_LESS: u32 = 2;
pub const D3D11_COMPARISON_EQUAL: u32 = 3;
pub const D3D11_COMPARISON_LESS_EQUAL: u32 = 4;
pub const D3D11_COMPARISON_GREATER: u32 = 5;
pub const D3D11_COMPARISON_NOT_EQUAL: u32 = 6;
pub const D3D11_COMPARISON_GREATER_EQUAL: u32 = 7;
pub const D3D11_COMPARISON_ALWAYS: u32 = 8;

pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_COLOR: u32 = 3;
pub const D3D11_BLEND_INV_SRC_COLOR: u32 = 4;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_DEST_ALPHA: u32 = 7;
pub const D3D11_BLEND_INV_DEST_ALPHA: u32 = 8;
pub const D3D11_BLEND_DEST_COLOR: u32 = 9;
pub const D3D11_BLEND_INV_DEST_COLOR: u32 = 10;
pub const D3D11_BLEND_SRC_ALPHA_SAT: u32 = 11;
pub const D3D11_BLEND_BLEND_FACTOR: u32 = 14;
pub const D3D11_BLEND_INV_BLEND_FACTOR: u32 = 15;

pub const D3D11_BLEND_OP_ADD: u32 = 1;
pub const D3D11_BLEND_OP_SUBTRACT: u32 = 2;
pub const D3D11_BLEND_OP_REV_SUBTRACT: u32 = 3;
pub const D3D11_BLEND_OP_MIN: u32 = 4;
pub const D3D11_BLEND_OP_MAX: u32 = 5;

pub const D3D11_CULL_NONE: u32 = 1;
pub const D3D11_CULL_FRONT: u32 = 2;
pub const D3D11_CULL_BACK: u32 = 3;

pub const D3D11_FILL_WIREFRAME: u32 = 2;
pub const D3D11_FILL_SOLID: u32 = 3;

pub const D3D11_STENCIL_OP_KEEP: u32 = 1;
pub const D3D11_STENCIL_OP_ZERO: u32 = 2;
pub const D3D11_STENCIL_OP_REPLACE: u32 = 3;
pub const D3D11_STENCIL_OP_INCR_SAT: u32 = 4;
pub const D3D11_STENCIL_OP_DECR_SAT: u32 = 5;
pub const D3D11_STENCIL_OP_INVERT: u32 = 6;
pub const D3D11_STENCIL_OP_INCR: u32 = 7;
pub const D3D11_STENCIL_OP_DECR: u32 = 8;

pub const D3D11_DEPTH_WRITE_MASK_ZERO: u32 = 0;
pub const D3D11_DEPTH_WRITE_MASK_ALL: u32 = 1;

pub const D3D11_COLOR_WRITE_ENABLE_RED: u32 = 1;
pub const D3D11_COLOR_WRITE_ENABLE_GREEN: u32 = 2;
pub const D3D11_COLOR_WRITE_ENABLE_BLUE: u32 = 4;
pub const D3D11_COLOR_WRITE_ENABLE_ALPHA: u32 = 8;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u32 = 0xf;

pub const D3D11_APPEND_ALIGNED_ELEMENT: u32 = 0xffffffff;

pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_INPUT_PER_INSTANCE_DATA: u32 = 1;

pub const D3D11_SRV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D11_SRV_DIMENSION_BUFFER: u32 = 1;
pub const D3D11_SRV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D11_SRV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D11_SRV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D11_SRV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D11_SRV_DIMENSION_TEXTURE2DMS: u32 = 6;
pub const D3D11_SRV_DIMENSION_TEXTURE2DMSARRAY: u32 = 7;
pub const D3D11_SRV_DIMENSION_TEXTURE3D: u32 = 8;
pub const D3D11_SRV_DIMENSION_TEXTURECUBE: u32 = 9;
pub const D3D11_SRV_DIMENSION_TEXTURECUBEARRAY: u32 = 10;
pub const D3D11_SRV_DIMENSION_BUFFEREX: u32 = 11;

pub const D3D11_UAV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D11_UAV_DIMENSION_BUFFER: u32 = 1;
pub const D3D11_UAV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D11_UAV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D11_UAV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D11_UAV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D11_UAV_DIMENSION_TEXTURE3D: u32 = 8;

pub const D3D11_RTV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D11_RTV_DIMENSION_BUFFER: u32 = 1;
pub const D3D11_RTV_DIMENSION_TEXTURE1D: u32 = 2;
pub const D3D11_RTV_DIMENSION_TEXTURE1DARRAY: u32 = 3;
pub const D3D11_RTV_DIMENSION_TEXTURE2D: u32 = 4;
pub const D3D11_RTV_DIMENSION_TEXTURE2DARRAY: u32 = 5;
pub const D3D11_RTV_DIMENSION_TEXTURE2DMS: u32 = 6;
pub const D3D11_RTV_DIMENSION_TEXTURE2DMSARRAY: u32 = 7;
pub const D3D11_RTV_DIMENSION_TEXTURE3D: u32 = 8;

pub const D3D11_DSV_DIMENSION_UNKNOWN: u32 = 0;
pub const D3D11_DSV_DIMENSION_TEXTURE1D: u32 = 1;
pub const D3D11_DSV_DIMENSION_TEXTURE1DARRAY: u32 = 2;
pub const D3D11_DSV_DIMENSION_TEXTURE2D: u32 = 3;
pub const D3D11_DSV_DIMENSION_TEXTURE2DARRAY: u32 = 4;
pub const D3D11_DSV_DIMENSION_TEXTURE2DMS: u32 = 5;
pub const D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY: u32 = 6;
pub const D3D11_DSV_READ_ONLY_DEPTH: u32 = 0x1;
pub const D3D11_DSV_READ_ONLY_STENCIL: u32 = 0x2;

// ---------------------------------------------------------------------------
// D3D11 structs.
// ---------------------------------------------------------------------------

/// Matches the Windows `D3D11_BUFFER_DESC` structure.
pub const D3D11_BUFFER_DESC = extern struct {
    byte_width: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
    structure_byte_stride: u32,
};

/// Matches the Windows `D3D11_TEXTURE1D_DESC` structure.
pub const D3D11_TEXTURE1D_DESC = extern struct {
    width: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

/// Matches the Windows `D3D11_TEXTURE2D_DESC` structure.
pub const D3D11_TEXTURE2D_DESC = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_desc: DXGI_SAMPLE_DESC,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

/// Matches the Windows `D3D11_TEXTURE3D_DESC` structure.
pub const D3D11_TEXTURE3D_DESC = extern struct {
    width: u32,
    height: u32,
    depth: u32,
    mip_levels: u32,
    format: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

/// Matches the Windows `D3D11_SUBRESOURCE_DATA` structure.
pub const D3D11_SUBRESOURCE_DATA = extern struct {
    sys_mem: ?*const anyopaque,
    sys_mem_pitch: u32,
    sys_mem_slice_pitch: u32,
};

/// Matches the Windows `D3D11_MAPPED_SUBRESOURCE` structure.
pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    data: ?*anyopaque,
    row_pitch: u32,
    depth_pitch: u32,
};

/// Matches the Windows `D3D11_BUFFER_SRV` structure.
pub const D3D11_BUFFER_SRV = extern struct {
    first: extern union {
        first_element: u32,
        element_offset: u32,
    },
    second: extern union {
        num_elements: u32,
        element_width: u32,
    },
};

/// Matches the Windows `D3D11_TEX1D_SRV` structure.
pub const D3D11_TEX1D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
};

/// Matches the Windows `D3D11_TEX1D_ARRAY_SRV` structure.
pub const D3D11_TEX1D_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2D_SRV` structure.
pub const D3D11_TEX2D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
};

/// Matches the Windows `D3D11_TEX2D_ARRAY_SRV` structure.
pub const D3D11_TEX2D_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_SRV` structure.
pub const D3D11_TEX2DMS_SRV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_ARRAY_SRV` structure.
pub const D3D11_TEX2DMS_ARRAY_SRV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX3D_SRV` structure.
pub const D3D11_TEX3D_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
};

/// Matches the Windows `D3D11_TEXCUBE_SRV` structure.
pub const D3D11_TEXCUBE_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
};

/// Matches the Windows `D3D11_TEXCUBE_ARRAY_SRV` structure.
pub const D3D11_TEXCUBE_ARRAY_SRV = extern struct {
    most_detailed_mip: u32,
    mip_levels: u32,
    first_2d_array_face: u32,
    num_cubes: u32,
};

/// Matches the Windows `D3D11_BUFFEREX_SRV` structure.
pub const D3D11_BUFFEREX_SRV = extern struct {
    first_element: u32,
    num_elements: u32,
    flags: u32,
};

/// Matches the Windows `D3D11_SHADER_RESOURCE_VIEW_DESC` structure.
pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    u: extern union {
        buffer: D3D11_BUFFER_SRV,
        texture_1d: D3D11_TEX1D_SRV,
        texture_1d_array: D3D11_TEX1D_ARRAY_SRV,
        texture_2d: D3D11_TEX2D_SRV,
        texture_2d_array: D3D11_TEX2D_ARRAY_SRV,
        texture_2dms: D3D11_TEX2DMS_SRV,
        texture_2dms_array: D3D11_TEX2DMS_ARRAY_SRV,
        texture_3d: D3D11_TEX3D_SRV,
        texture_cube: D3D11_TEXCUBE_SRV,
        texture_cube_array: D3D11_TEXCUBE_ARRAY_SRV,
        buffer_ex: D3D11_BUFFEREX_SRV,
    },
};

/// Matches the Windows `D3D11_BUFFER_UAV` structure.
pub const D3D11_BUFFER_UAV = extern struct {
    first_element: u32,
    num_elements: u32,
    flags: u32,
};

/// Matches the Windows `D3D11_TEX1D_UAV` structure.
pub const D3D11_TEX1D_UAV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX1D_ARRAY_UAV` structure.
pub const D3D11_TEX1D_ARRAY_UAV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2D_UAV` structure.
pub const D3D11_TEX2D_UAV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX2D_ARRAY_UAV` structure.
pub const D3D11_TEX2D_ARRAY_UAV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX3D_UAV` structure.
pub const D3D11_TEX3D_UAV = extern struct {
    mip_slice: u32,
    first_w_slice: u32,
    w_size: u32,
};

/// Matches the Windows `D3D11_UNORDERED_ACCESS_VIEW_DESC` structure.
pub const D3D11_UNORDERED_ACCESS_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    u: extern union {
        buffer: D3D11_BUFFER_UAV,
        texture_1d: D3D11_TEX1D_UAV,
        texture_1d_array: D3D11_TEX1D_ARRAY_UAV,
        texture_2d: D3D11_TEX2D_UAV,
        texture_2d_array: D3D11_TEX2D_ARRAY_UAV,
        texture_3d: D3D11_TEX3D_UAV,
    },
};

/// Matches the Windows `D3D11_BUFFER_RTV` structure.
pub const D3D11_BUFFER_RTV = extern struct {
    first: extern union {
        first_element: u32,
        element_offset: u32,
    },
    second: extern union {
        num_elements: u32,
        element_width: u32,
    },
};

/// Matches the Windows `D3D11_TEX1D_RTV` structure.
pub const D3D11_TEX1D_RTV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX1D_ARRAY_RTV` structure.
pub const D3D11_TEX1D_ARRAY_RTV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2D_RTV` structure.
pub const D3D11_TEX2D_RTV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX2D_ARRAY_RTV` structure.
pub const D3D11_TEX2D_ARRAY_RTV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_RTV` structure.
pub const D3D11_TEX2DMS_RTV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_ARRAY_RTV` structure.
pub const D3D11_TEX2DMS_ARRAY_RTV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX3D_RTV` structure.
pub const D3D11_TEX3D_RTV = extern struct {
    mip_slice: u32,
    first_w_slice: u32,
    w_size: u32,
};

/// Matches the Windows `D3D11_RENDER_TARGET_VIEW_DESC` structure.
pub const D3D11_RENDER_TARGET_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    u: extern union {
        buffer: D3D11_BUFFER_RTV,
        texture_1d: D3D11_TEX1D_RTV,
        texture_1d_array: D3D11_TEX1D_ARRAY_RTV,
        texture_2d: D3D11_TEX2D_RTV,
        texture_2d_array: D3D11_TEX2D_ARRAY_RTV,
        texture_2dms: D3D11_TEX2DMS_RTV,
        texture_2dms_array: D3D11_TEX2DMS_ARRAY_RTV,
        texture_3d: D3D11_TEX3D_RTV,
    },
};

/// Matches the Windows `D3D11_TEX1D_DSV` structure.
pub const D3D11_TEX1D_DSV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX1D_ARRAY_DSV` structure.
pub const D3D11_TEX1D_ARRAY_DSV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2D_DSV` structure.
pub const D3D11_TEX2D_DSV = extern struct {
    mip_slice: u32,
};

/// Matches the Windows `D3D11_TEX2D_ARRAY_DSV` structure.
pub const D3D11_TEX2D_ARRAY_DSV = extern struct {
    mip_slice: u32,
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_DSV` structure.
pub const D3D11_TEX2DMS_DSV = extern struct {
    unused_field_nothing_to_define: u32,
};

/// Matches the Windows `D3D11_TEX2DMS_ARRAY_DSV` structure.
pub const D3D11_TEX2DMS_ARRAY_DSV = extern struct {
    first_array_slice: u32,
    array_size: u32,
};

/// Matches the Windows `D3D11_DEPTH_STENCIL_VIEW_DESC` structure.
pub const D3D11_DEPTH_STENCIL_VIEW_DESC = extern struct {
    format: u32,
    view_dimension: u32,
    flags: u32,
    u: extern union {
        texture_1d: D3D11_TEX1D_DSV,
        texture_1d_array: D3D11_TEX1D_ARRAY_DSV,
        texture_2d: D3D11_TEX2D_DSV,
        texture_2d_array: D3D11_TEX2D_ARRAY_DSV,
        texture_2dms: D3D11_TEX2DMS_DSV,
        texture_2dms_array: D3D11_TEX2DMS_ARRAY_DSV,
    },
};

/// Matches the Windows `D3D11_SAMPLER_DESC` structure.
pub const D3D11_SAMPLER_DESC = extern struct {
    filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    mip_lod_bias: f32,
    max_anisotropy: u32,
    comparison_func: u32,
    border_color: [4]f32,
    min_lod: f32,
    max_lod: f32,
};

/// Matches the Windows `D3D11_INPUT_ELEMENT_DESC` structure.
pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    semantic_name: ?[*:0]const u8,
    semantic_index: u32,
    format: u32,
    input_slot: u32,
    aligned_byte_offset: u32,
    input_slot_class: u32,
    instance_data_step_rate: u32,
};

/// Matches the Windows `D3D11_VIEWPORT` structure.
pub const D3D11_VIEWPORT = extern struct {
    top_left_x: f32,
    top_left_y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

/// Matches the Windows `D3D11_RECT` structure.
pub const D3D11_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Matches the Windows `D3D11_RENDER_TARGET_BLEND_DESC` structure.
pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    blend_enable: i32,
    src_blend: u32,
    dest_blend: u32,
    blend_op: u32,
    src_blend_alpha: u32,
    dest_blend_alpha: u32,
    blend_op_alpha: u32,
    render_target_write_mask: u8,
};

/// Matches the Windows `D3D11_BLEND_DESC` structure.
pub const D3D11_BLEND_DESC = extern struct {
    alpha_to_coverage_enable: i32,
    independent_blend_enable: i32,
    render_target: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

/// Matches the Windows `D3D11_DEPTH_STENCILOP_DESC` structure.
pub const D3D11_DEPTH_STENCILOP_DESC = extern struct {
    stencil_fail_op: u32,
    stencil_depth_fail_op: u32,
    stencil_pass_op: u32,
    stencil_func: u32,
};

/// Matches the Windows `D3D11_DEPTH_STENCIL_DESC` structure.
pub const D3D11_DEPTH_STENCIL_DESC = extern struct {
    depth_enable: i32,
    depth_write_mask: u32,
    depth_func: u32,
    stencil_enable: i32,
    stencil_read_mask: u8,
    stencil_write_mask: u8,
    front_face: D3D11_DEPTH_STENCILOP_DESC,
    back_face: D3D11_DEPTH_STENCILOP_DESC,
};

/// Matches the Windows `D3D11_RASTERIZER_DESC` structure.
pub const D3D11_RASTERIZER_DESC = extern struct {
    fill_mode: u32,
    cull_mode: u32,
    front_counter_clockwise: i32,
    depth_bias: i32,
    depth_bias_clamp: f32,
    slope_scaled_depth_bias: f32,
    depth_clip_enable: i32,
    scissor_enable: i32,
    multisample_enable: i32,
    antialiased_line_enable: i32,
};

/// Matches the Windows `D3D11_BOX` structure.
pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

// ---------------------------------------------------------------------------
// GUIDs (IIDs).
// ---------------------------------------------------------------------------

pub const IID_ID3D12Device: GUID = .{ .data1 = 0x189819f1, .data2 = 0x1db6, .data3 = 0x4b57, .data4 = .{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 } };
pub const IID_ID3D12CommandQueue: GUID = .{ .data1 = 0x0ec870a6, .data2 = 0x5d7e, .data3 = 0x4c22, .data4 = .{ 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed } };
pub const IID_ID3D12CommandAllocator: GUID = .{ .data1 = 0x6102dee4, .data2 = 0xaf59, .data3 = 0x4b09, .data4 = .{ 0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24 } };
pub const IID_ID3D12GraphicsCommandList: GUID = .{ .data1 = 0x5b160d0f, .data2 = 0xac1b, .data3 = 0x4185, .data4 = .{ 0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55 } };
pub const IID_ID3D12DescriptorHeap: GUID = .{ .data1 = 0x8efb471d, .data2 = 0x616c, .data3 = 0x4f49, .data4 = .{ 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 } };
pub const IID_ID3D12Resource: GUID = .{ .data1 = 0x696442be, .data2 = 0xa72e, .data3 = 0x4059, .data4 = .{ 0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad } };
pub const IID_ID3D12Fence: GUID = .{ .data1 = 0x0a753dcf, .data2 = 0xc4d8, .data3 = 0x4b91, .data4 = .{ 0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76 } };
pub const IID_ID3D12RootSignature: GUID = .{ .data1 = 0xc54a6b66, .data2 = 0x72df, .data3 = 0x4ee8, .data4 = .{ 0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14 } };
pub const IID_ID3D12PipelineState: GUID = .{ .data1 = 0x765a30f3, .data2 = 0xf624, .data3 = 0x4c6f, .data4 = .{ 0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45 } };
pub const IID_ID3D11Device: GUID = .{ .data1 = 0xdb6f6ddb, .data2 = 0xac77, .data3 = 0x4e88, .data4 = .{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 } };
pub const IID_ID3D11Texture2D: GUID = .{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };
pub const IID_ID3D11Texture3D: GUID = .{ .data1 = 0x037e866e, .data2 = 0xf56d, .data3 = 0x4357, .data4 = .{ 0xa8, 0xaf, 0x9d, 0xab, 0xbe, 0x6e, 0x25, 0x0e } };
pub const IID_ID3D11Buffer: GUID = .{ .data1 = 0x48570b85, .data2 = 0xd1ee, .data3 = 0x4fcd, .data4 = .{ 0xa2, 0x50, 0xeb, 0x35, 0x07, 0x22, 0xb0, 0x37 } };
pub const IID_IDXGIFactory2: GUID = .{ .data1 = 0x50c83a1c, .data2 = 0xe072, .data3 = 0x4c48, .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
pub const IID_IDXGISwapChain1: GUID = .{ .data1 = 0x790a45f7, .data2 = 0x0d42, .data3 = 0x4876, .data4 = .{ 0x98, 0x3a, 0x0a, 0x55, 0xcf, 0xe6, 0xf4, 0xaa } };
pub const IID_IDXGISwapChain3: GUID = .{ .data1 = 0x94d99bdb, .data2 = 0xf1f8, .data3 = 0x4ab0, .data4 = .{ 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1 } };
pub const IID_IDXGIAdapter1: GUID = .{ .data1 = 0x29038f61, .data2 = 0x3839, .data3 = 0x4626, .data4 = .{ 0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05 } };
pub const IID_IDXGIDevice: GUID = .{ .data1 = 0x54ec77fa, .data2 = 0x1377, .data3 = 0x44e6, .data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };

// ---------------------------------------------------------------------------
// COM interface wrappers.
// ---------------------------------------------------------------------------

fn method(self: anytype, comptime index: usize, comptime Fn: type) Fn {
    const table: [*]const *const anyopaque = @ptrCast(@alignCast(
        self.vtable,
    ));
    return @ptrCast(table[index]);
}

/// Wraps the Windows `IUnknown` COM interface.
pub const IUnknown = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IUnknown, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IUnknown, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IUnknown) u32 {
        const Fn = *const fn (*IUnknown) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IUnknown) u32 {
        const Fn = *const fn (*IUnknown) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3DBlob` COM interface.
pub const ID3DBlob = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3DBlob, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3DBlob, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3DBlob) u32 {
        const Fn = *const fn (*ID3DBlob) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3DBlob) u32 {
        const Fn = *const fn (*ID3DBlob) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getBufferPointer(self: *ID3DBlob) ?*anyopaque {
        const Fn = *const fn (*ID3DBlob) callconv(.winapi) ?*anyopaque;
        return method(self, 3, Fn)(self);
    }

    pub fn getBufferSize(self: *ID3DBlob) usize {
        const Fn = *const fn (*ID3DBlob) callconv(.winapi) usize;
        return method(self, 4, Fn)(self);
    }
};

/// Wraps the Windows `ID3D12Device` COM interface.
pub const ID3D12Device = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12Device, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12Device) u32 {
        const Fn = *const fn (*ID3D12Device) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12Device) u32 {
        const Fn = *const fn (*ID3D12Device) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn createCommandQueue(self: *ID3D12Device, desc: *const D3D12_COMMAND_QUEUE_DESC, riid: *const GUID, command_queue: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const D3D12_COMMAND_QUEUE_DESC, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self, desc, riid, command_queue);
    }

    pub fn createCommandAllocator(self: *ID3D12Device, @"type": u32, riid: *const GUID, command_allocator: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, u32, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 9, Fn)(self, @"type", riid, command_allocator);
    }

    pub fn createGraphicsPipelineState(self: *ID3D12Device, desc: *const D3D12_GRAPHICS_PIPELINE_STATE_DESC, riid: *const GUID, pipeline_state: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const D3D12_GRAPHICS_PIPELINE_STATE_DESC, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 10, Fn)(self, desc, riid, pipeline_state);
    }

    pub fn createComputePipelineState(self: *ID3D12Device, desc: *const D3D12_COMPUTE_PIPELINE_STATE_DESC, riid: *const GUID, pipeline_state: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const D3D12_COMPUTE_PIPELINE_STATE_DESC, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 11, Fn)(self, desc, riid, pipeline_state);
    }

    pub fn createCommandList(self: *ID3D12Device, node_mask: u32, @"type": u32, command_allocator: ?*ID3D12CommandAllocator, initial_pipeline_state: ?*ID3D12PipelineState, riid: *const GUID, command_list: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, u32, u32, ?*ID3D12CommandAllocator, ?*ID3D12PipelineState, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 12, Fn)(self, node_mask, @"type", command_allocator, initial_pipeline_state, riid, command_list);
    }

    pub fn createDescriptorHeap(self: *ID3D12Device, desc: *const D3D12_DESCRIPTOR_HEAP_DESC, riid: *const GUID, descriptor_heap: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const D3D12_DESCRIPTOR_HEAP_DESC, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 14, Fn)(self, desc, riid, descriptor_heap);
    }

    pub fn copyDescriptorsSimple(self: *ID3D12Device, num_descriptors: u32, dest_descriptor_range_start: D3D12_CPU_DESCRIPTOR_HANDLE, src_descriptor_range_start: D3D12_CPU_DESCRIPTOR_HANDLE, descriptor_heaps_type: u32) void {
        const Fn = *const fn (*ID3D12Device, u32, D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_CPU_DESCRIPTOR_HANDLE, u32) callconv(.winapi) void;
        return method(self, 24, Fn)(self, num_descriptors, dest_descriptor_range_start, src_descriptor_range_start, descriptor_heaps_type);
    }

    pub fn getDescriptorHandleIncrementSize(self: *ID3D12Device, descriptor_heap_type: u32) u32 {
        const Fn = *const fn (*ID3D12Device, u32) callconv(.winapi) u32;
        return method(self, 15, Fn)(self, descriptor_heap_type);
    }

    pub fn createRootSignature(self: *ID3D12Device, node_mask: u32, bytecode: ?*const anyopaque, bytecode_length: usize, riid: *const GUID, root_signature: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, u32, ?*const anyopaque, usize, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 16, Fn)(self, node_mask, bytecode, bytecode_length, riid, root_signature);
    }

    pub fn createConstantBufferView(self: *ID3D12Device, desc: *const D3D12_CONSTANT_BUFFER_VIEW_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, *const D3D12_CONSTANT_BUFFER_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 17, Fn)(self, desc, descriptor);
    }

    pub fn createShaderResourceView(self: *ID3D12Device, resource: ?*ID3D12Resource, desc: ?*const D3D12_SHADER_RESOURCE_VIEW_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, ?*ID3D12Resource, ?*const D3D12_SHADER_RESOURCE_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 18, Fn)(self, resource, desc, descriptor);
    }

    pub fn createUnorderedAccessView(self: *ID3D12Device, resource: ?*ID3D12Resource, counter_resource: ?*ID3D12Resource, desc: ?*const D3D12_UNORDERED_ACCESS_VIEW_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, ?*ID3D12Resource, ?*ID3D12Resource, ?*const D3D12_UNORDERED_ACCESS_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 19, Fn)(self, resource, counter_resource, desc, descriptor);
    }

    pub fn createRenderTargetView(self: *ID3D12Device, resource: ?*ID3D12Resource, desc: ?*const D3D12_RENDER_TARGET_VIEW_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, ?*ID3D12Resource, ?*const D3D12_RENDER_TARGET_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 20, Fn)(self, resource, desc, descriptor);
    }

    pub fn createDepthStencilView(self: *ID3D12Device, resource: ?*ID3D12Resource, desc: ?*const D3D12_DEPTH_STENCIL_VIEW_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, ?*ID3D12Resource, ?*const D3D12_DEPTH_STENCIL_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 21, Fn)(self, resource, desc, descriptor);
    }

    pub fn createSampler(self: *ID3D12Device, desc: *const D3D12_SAMPLER_DESC, descriptor: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12Device, *const D3D12_SAMPLER_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 22, Fn)(self, desc, descriptor);
    }

    pub fn createCommittedResource(self: *ID3D12Device, heap_properties: *const D3D12_HEAP_PROPERTIES, heap_flags: u32, desc: *const D3D12_RESOURCE_DESC, initial_state: u32, optimized_clear_value: ?*const D3D12_CLEAR_VALUE, riid: *const GUID, resource: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, *const D3D12_HEAP_PROPERTIES, u32, *const D3D12_RESOURCE_DESC, u32, ?*const D3D12_CLEAR_VALUE, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 27, Fn)(self, heap_properties, heap_flags, desc, initial_state, optimized_clear_value, riid, resource);
    }

    pub fn createFence(self: *ID3D12Device, initial_value: u64, flags: u32, riid: *const GUID, fence: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Device, u64, u32, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 36, Fn)(self, initial_value, flags, riid, fence);
    }

    pub fn getDeviceRemovedReason(self: *ID3D12Device) HRESULT {
        const Fn = *const fn (*ID3D12Device) callconv(.winapi) HRESULT;
        return method(self, 37, Fn)(self);
    }

    pub fn getAdapterLuid(self: *ID3D12Device, luid: *LUID) void {
        const Fn = *const fn (*ID3D12Device, *LUID) callconv(.winapi) *LUID;
        _ = method(self, 43, Fn)(self, luid);
    }
};

/// Wraps the Windows `ID3D12CommandQueue` COM interface.
pub const ID3D12CommandQueue = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12CommandQueue, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12CommandQueue, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12CommandQueue) u32 {
        const Fn = *const fn (*ID3D12CommandQueue) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12CommandQueue) u32 {
        const Fn = *const fn (*ID3D12CommandQueue) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn executeCommandLists(self: *ID3D12CommandQueue, command_list_count: u32, command_lists: [*]const ?*ID3D12CommandList) void {
        const Fn = *const fn (*ID3D12CommandQueue, u32, [*]const ?*ID3D12CommandList) callconv(.winapi) void;
        return method(self, 10, Fn)(self, command_list_count, command_lists);
    }

    pub fn signal(self: *ID3D12CommandQueue, fence: ?*ID3D12Fence, value: u64) HRESULT {
        const Fn = *const fn (*ID3D12CommandQueue, ?*ID3D12Fence, u64) callconv(.winapi) HRESULT;
        return method(self, 14, Fn)(self, fence, value);
    }

    pub fn wait(self: *ID3D12CommandQueue, fence: ?*ID3D12Fence, value: u64) HRESULT {
        const Fn = *const fn (*ID3D12CommandQueue, ?*ID3D12Fence, u64) callconv(.winapi) HRESULT;
        return method(self, 15, Fn)(self, fence, value);
    }

    pub fn getTimestampFrequency(self: *ID3D12CommandQueue, frequency: *u64) HRESULT {
        const Fn = *const fn (*ID3D12CommandQueue, *u64) callconv(.winapi) HRESULT;
        return method(self, 16, Fn)(self, frequency);
    }
};

/// Wraps the Windows `ID3D12CommandAllocator` COM interface.
pub const ID3D12CommandAllocator = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12CommandAllocator, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12CommandAllocator, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12CommandAllocator) u32 {
        const Fn = *const fn (*ID3D12CommandAllocator) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12CommandAllocator) u32 {
        const Fn = *const fn (*ID3D12CommandAllocator) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn reset(self: *ID3D12CommandAllocator) HRESULT {
        const Fn = *const fn (*ID3D12CommandAllocator) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self);
    }
};

/// Wraps the Windows `ID3D12GraphicsCommandList` COM interface.
pub const ID3D12GraphicsCommandList = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12GraphicsCommandList, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12GraphicsCommandList, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12GraphicsCommandList) u32 {
        const Fn = *const fn (*ID3D12GraphicsCommandList) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12GraphicsCommandList) u32 {
        const Fn = *const fn (*ID3D12GraphicsCommandList) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn close(self: *ID3D12GraphicsCommandList) HRESULT {
        const Fn = *const fn (*ID3D12GraphicsCommandList) callconv(.winapi) HRESULT;
        return method(self, 9, Fn)(self);
    }

    pub fn reset(self: *ID3D12GraphicsCommandList, allocator: ?*ID3D12CommandAllocator, initial_state: ?*ID3D12PipelineState) HRESULT {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12CommandAllocator, ?*ID3D12PipelineState) callconv(.winapi) HRESULT;
        return method(self, 10, Fn)(self, allocator, initial_state);
    }

    pub fn drawInstanced(self: *ID3D12GraphicsCommandList, vertex_count_per_instance: u32, instance_count: u32, start_vertex_location: u32, start_instance_location: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, u32, u32) callconv(.winapi) void;
        return method(self, 12, Fn)(self, vertex_count_per_instance, instance_count, start_vertex_location, start_instance_location);
    }

    pub fn drawIndexedInstanced(self: *ID3D12GraphicsCommandList, index_count_per_instance: u32, instance_count: u32, start_vertex_location: u32, base_vertex_location: i32, start_instance_location: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, u32, i32, u32) callconv(.winapi) void;
        return method(self, 13, Fn)(self, index_count_per_instance, instance_count, start_vertex_location, base_vertex_location, start_instance_location);
    }

    pub fn dispatch(self: *ID3D12GraphicsCommandList, x: u32, y: u32, z: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, u32) callconv(.winapi) void;
        return method(self, 14, Fn)(self, x, y, z);
    }

    pub fn copyBufferRegion(self: *ID3D12GraphicsCommandList, dst_buffer: ?*ID3D12Resource, dst_offset: u64, src_buffer: ?*ID3D12Resource, src_offset: u64, byte_count: u64) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12Resource, u64, ?*ID3D12Resource, u64, u64) callconv(.winapi) void;
        return method(self, 15, Fn)(self, dst_buffer, dst_offset, src_buffer, src_offset, byte_count);
    }

    pub fn copyTextureRegion(self: *ID3D12GraphicsCommandList, dst: *const D3D12_TEXTURE_COPY_LOCATION, dst_x: u32, dst_y: u32, dst_z: u32, src: *const D3D12_TEXTURE_COPY_LOCATION, src_box: ?*const D3D12_BOX) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, *const D3D12_TEXTURE_COPY_LOCATION, u32, u32, u32, *const D3D12_TEXTURE_COPY_LOCATION, ?*const D3D12_BOX) callconv(.winapi) void;
        return method(self, 16, Fn)(self, dst, dst_x, dst_y, dst_z, src, src_box);
    }

    pub fn copyResource(self: *ID3D12GraphicsCommandList, dst_resource: ?*ID3D12Resource, src_resource: ?*ID3D12Resource) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12Resource, ?*ID3D12Resource) callconv(.winapi) void;
        return method(self, 17, Fn)(self, dst_resource, src_resource);
    }

    pub fn iASetPrimitiveTopology(self: *ID3D12GraphicsCommandList, primitive_topology: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32) callconv(.winapi) void;
        return method(self, 20, Fn)(self, primitive_topology);
    }

    pub fn rSSetViewports(self: *ID3D12GraphicsCommandList, viewport_count: u32, viewports: ?*const D3D12_VIEWPORT) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, ?*const D3D12_VIEWPORT) callconv(.winapi) void;
        return method(self, 21, Fn)(self, viewport_count, viewports);
    }

    pub fn rSSetScissorRects(self: *ID3D12GraphicsCommandList, rect_count: u32, rects: ?*const D3D12_RECT) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, ?*const D3D12_RECT) callconv(.winapi) void;
        return method(self, 22, Fn)(self, rect_count, rects);
    }

    pub fn setPipelineState(self: *ID3D12GraphicsCommandList, pipeline_state: ?*ID3D12PipelineState) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12PipelineState) callconv(.winapi) void;
        return method(self, 25, Fn)(self, pipeline_state);
    }

    pub fn resourceBarrier(self: *ID3D12GraphicsCommandList, barrier_count: u32, barriers: ?*const D3D12_RESOURCE_BARRIER) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, ?*const D3D12_RESOURCE_BARRIER) callconv(.winapi) void;
        return method(self, 26, Fn)(self, barrier_count, barriers);
    }

    pub fn setDescriptorHeaps(self: *ID3D12GraphicsCommandList, heap_count: u32, heaps: [*]const ?*ID3D12DescriptorHeap) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, [*]const ?*ID3D12DescriptorHeap) callconv(.winapi) void;
        return method(self, 28, Fn)(self, heap_count, heaps);
    }

    pub fn setComputeRootSignature(self: *ID3D12GraphicsCommandList, root_signature: ?*ID3D12RootSignature) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12RootSignature) callconv(.winapi) void;
        return method(self, 29, Fn)(self, root_signature);
    }

    pub fn setGraphicsRootSignature(self: *ID3D12GraphicsCommandList, root_signature: ?*ID3D12RootSignature) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*ID3D12RootSignature) callconv(.winapi) void;
        return method(self, 30, Fn)(self, root_signature);
    }

    pub fn setComputeRootDescriptorTable(self: *ID3D12GraphicsCommandList, root_parameter_index: u32, base_descriptor: D3D12_GPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 31, Fn)(self, root_parameter_index, base_descriptor);
    }

    pub fn setGraphicsRootDescriptorTable(self: *ID3D12GraphicsCommandList, root_parameter_index: u32, base_descriptor: D3D12_GPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 32, Fn)(self, root_parameter_index, base_descriptor);
    }

    pub fn setComputeRoot32BitConstants(self: *ID3D12GraphicsCommandList, root_parameter_index: u32, constant_count: u32, data: ?*const anyopaque, dst_offset: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, ?*const anyopaque, u32) callconv(.winapi) void;
        return method(self, 35, Fn)(self, root_parameter_index, constant_count, data, dst_offset);
    }

    pub fn setGraphicsRoot32BitConstants(self: *ID3D12GraphicsCommandList, root_parameter_index: u32, constant_count: u32, data: ?*const anyopaque, dst_offset: u32) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, ?*const anyopaque, u32) callconv(.winapi) void;
        return method(self, 36, Fn)(self, root_parameter_index, constant_count, data, dst_offset);
    }

    pub fn iASetIndexBuffer(self: *ID3D12GraphicsCommandList, view: ?*const D3D12_INDEX_BUFFER_VIEW) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, ?*const D3D12_INDEX_BUFFER_VIEW) callconv(.winapi) void;
        return method(self, 43, Fn)(self, view);
    }

    pub fn iASetVertexBuffers(self: *ID3D12GraphicsCommandList, start_slot: u32, view_count: u32, views: ?*const D3D12_VERTEX_BUFFER_VIEW) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, u32, ?*const D3D12_VERTEX_BUFFER_VIEW) callconv(.winapi) void;
        return method(self, 44, Fn)(self, start_slot, view_count, views);
    }

    pub fn oMSetRenderTargets(self: *ID3D12GraphicsCommandList, render_target_descriptor_count: u32, render_target_descriptors: ?*const D3D12_CPU_DESCRIPTOR_HANDLE, single_descriptor_handle: i32, depth_stencil_descriptor: ?*const D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, u32, ?*const D3D12_CPU_DESCRIPTOR_HANDLE, i32, ?*const D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) void;
        return method(self, 46, Fn)(self, render_target_descriptor_count, render_target_descriptors, single_descriptor_handle, depth_stencil_descriptor);
    }

    pub fn clearDepthStencilView(self: *ID3D12GraphicsCommandList, dsv: D3D12_CPU_DESCRIPTOR_HANDLE, flags: u32, depth: f32, stencil: u8, rect_count: u32, rects: ?*const D3D12_RECT) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, D3D12_CPU_DESCRIPTOR_HANDLE, u32, f32, u8, u32, ?*const D3D12_RECT) callconv(.winapi) void;
        return method(self, 47, Fn)(self, dsv, flags, depth, stencil, rect_count, rects);
    }

    pub fn clearRenderTargetView(self: *ID3D12GraphicsCommandList, rtv: D3D12_CPU_DESCRIPTOR_HANDLE, color: *const [4]f32, rect_count: u32, rects: ?*const D3D12_RECT) void {
        const Fn = *const fn (*ID3D12GraphicsCommandList, D3D12_CPU_DESCRIPTOR_HANDLE, *const [4]f32, u32, ?*const D3D12_RECT) callconv(.winapi) void;
        return method(self, 48, Fn)(self, rtv, color, rect_count, rects);
    }
};

/// Wraps the Windows `ID3D12DescriptorHeap` COM interface.
pub const ID3D12DescriptorHeap = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12DescriptorHeap, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12DescriptorHeap, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12DescriptorHeap) u32 {
        const Fn = *const fn (*ID3D12DescriptorHeap) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12DescriptorHeap) u32 {
        const Fn = *const fn (*ID3D12DescriptorHeap) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getDesc(self: *ID3D12DescriptorHeap, desc: *D3D12_DESCRIPTOR_HEAP_DESC) void {
        const Fn = *const fn (*ID3D12DescriptorHeap, *D3D12_DESCRIPTOR_HEAP_DESC) callconv(.winapi) *D3D12_DESCRIPTOR_HEAP_DESC;
        _ = method(self, 8, Fn)(self, desc);
    }

    pub fn getCPUDescriptorHandleForHeapStart(self: *ID3D12DescriptorHeap, handle: *D3D12_CPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12DescriptorHeap, *D3D12_CPU_DESCRIPTOR_HANDLE) callconv(.winapi) *D3D12_CPU_DESCRIPTOR_HANDLE;
        _ = method(self, 9, Fn)(self, handle);
    }

    pub fn getGPUDescriptorHandleForHeapStart(self: *ID3D12DescriptorHeap, handle: *D3D12_GPU_DESCRIPTOR_HANDLE) void {
        const Fn = *const fn (*ID3D12DescriptorHeap, *D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.winapi) *D3D12_GPU_DESCRIPTOR_HANDLE;
        _ = method(self, 10, Fn)(self, handle);
    }
};

/// Wraps the Windows `ID3D12Resource` COM interface.
pub const ID3D12Resource = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12Resource, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Resource, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12Resource) u32 {
        const Fn = *const fn (*ID3D12Resource) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12Resource) u32 {
        const Fn = *const fn (*ID3D12Resource) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn map(self: *ID3D12Resource, sub_resource: u32, read_range: ?*const D3D12_RANGE, data: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Resource, u32, ?*const D3D12_RANGE, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self, sub_resource, read_range, data);
    }

    pub fn unmap(self: *ID3D12Resource, sub_resource: u32, written_range: ?*const D3D12_RANGE) void {
        const Fn = *const fn (*ID3D12Resource, u32, ?*const D3D12_RANGE) callconv(.winapi) void;
        return method(self, 9, Fn)(self, sub_resource, written_range);
    }

    pub fn getDesc(self: *ID3D12Resource, desc: *D3D12_RESOURCE_DESC) void {
        const Fn = *const fn (*ID3D12Resource, *D3D12_RESOURCE_DESC) callconv(.winapi) *D3D12_RESOURCE_DESC;
        _ = method(self, 10, Fn)(self, desc);
    }

    pub fn getGPUVirtualAddress(self: *ID3D12Resource) u64 {
        const Fn = *const fn (*ID3D12Resource) callconv(.winapi) u64;
        return method(self, 11, Fn)(self);
    }
};

/// Wraps the Windows `ID3D12Fence` COM interface.
pub const ID3D12Fence = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D12Fence, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Fence, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D12Fence) u32 {
        const Fn = *const fn (*ID3D12Fence) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D12Fence) u32 {
        const Fn = *const fn (*ID3D12Fence) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getCompletedValue(self: *ID3D12Fence) u64 {
        const Fn = *const fn (*ID3D12Fence) callconv(.winapi) u64;
        return method(self, 8, Fn)(self);
    }

    pub fn setEventOnCompletion(self: *ID3D12Fence, value: u64, event: ?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D12Fence, u64, ?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 9, Fn)(self, value, event);
    }

    pub fn signal(self: *ID3D12Fence, value: u64) HRESULT {
        const Fn = *const fn (*ID3D12Fence, u64) callconv(.winapi) HRESULT;
        return method(self, 10, Fn)(self, value);
    }
};

/// Wraps the Windows `ID3D12RootSignature` COM interface.
pub const ID3D12RootSignature = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D12RootSignature) u32 {
        const Fn = *const fn (*ID3D12RootSignature) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D12PipelineState` COM interface.
pub const ID3D12PipelineState = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D12PipelineState) u32 {
        const Fn = *const fn (*ID3D12PipelineState) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D12CommandList` COM interface.
pub const ID3D12CommandList = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D12CommandList) u32 {
        const Fn = *const fn (*ID3D12CommandList) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

// ---------------------------------------------------------------------------
// D3D11 interfaces.
// ---------------------------------------------------------------------------

/// Wraps the Windows `ID3D11Device` COM interface.
pub const ID3D11Device = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D11Device, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D11Device) u32 {
        const Fn = *const fn (*ID3D11Device) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D11Device) u32 {
        const Fn = *const fn (*ID3D11Device) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn createBuffer(self: *ID3D11Device, desc: *const D3D11_BUFFER_DESC, initial_data: ?*const D3D11_SUBRESOURCE_DATA, buffer: ?*?*ID3D11Buffer) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?*ID3D11Buffer) callconv(.winapi) HRESULT;
        return method(self, 3, Fn)(self, desc, initial_data, buffer);
    }

    pub fn createTexture1D(self: *ID3D11Device, desc: *const D3D11_TEXTURE1D_DESC, initial_data: ?*const D3D11_SUBRESOURCE_DATA, texture_1d: ?*?*ID3D11Texture1D) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_TEXTURE1D_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?*ID3D11Texture1D) callconv(.winapi) HRESULT;
        return method(self, 4, Fn)(self, desc, initial_data, texture_1d);
    }

    pub fn createTexture2D(self: *ID3D11Device, desc: *const D3D11_TEXTURE2D_DESC, initial_data: ?*const D3D11_SUBRESOURCE_DATA, texture_2d: ?*?*ID3D11Texture2D) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?*ID3D11Texture2D) callconv(.winapi) HRESULT;
        return method(self, 5, Fn)(self, desc, initial_data, texture_2d);
    }

    pub fn createTexture3D(self: *ID3D11Device, desc: *const D3D11_TEXTURE3D_DESC, initial_data: ?*const D3D11_SUBRESOURCE_DATA, texture_3d: ?*?*ID3D11Texture3D) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_TEXTURE3D_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?*ID3D11Texture3D) callconv(.winapi) HRESULT;
        return method(self, 6, Fn)(self, desc, initial_data, texture_3d);
    }

    pub fn createShaderResourceView(self: *ID3D11Device, resource: ?*ID3D11Resource, desc: ?*const D3D11_SHADER_RESOURCE_VIEW_DESC, sr_view: ?*?*ID3D11ShaderResourceView) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*ID3D11Resource, ?*const D3D11_SHADER_RESOURCE_VIEW_DESC, ?*?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT;
        return method(self, 7, Fn)(self, resource, desc, sr_view);
    }

    pub fn createUnorderedAccessView(self: *ID3D11Device, resource: ?*ID3D11Resource, desc: ?*const D3D11_UNORDERED_ACCESS_VIEW_DESC, ua_view: ?*?*ID3D11UnorderedAccessView) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*ID3D11Resource, ?*const D3D11_UNORDERED_ACCESS_VIEW_DESC, ?*?*ID3D11UnorderedAccessView) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self, resource, desc, ua_view);
    }

    pub fn createRenderTargetView(self: *ID3D11Device, resource: ?*ID3D11Resource, desc: ?*const D3D11_RENDER_TARGET_VIEW_DESC, rt_view: ?*?*ID3D11RenderTargetView) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*ID3D11Resource, ?*const D3D11_RENDER_TARGET_VIEW_DESC, ?*?*ID3D11RenderTargetView) callconv(.winapi) HRESULT;
        return method(self, 9, Fn)(self, resource, desc, rt_view);
    }

    pub fn createDepthStencilView(self: *ID3D11Device, resource: ?*ID3D11Resource, desc: ?*const D3D11_DEPTH_STENCIL_VIEW_DESC, depth_stencil_view: ?*?*ID3D11DepthStencilView) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*ID3D11Resource, ?*const D3D11_DEPTH_STENCIL_VIEW_DESC, ?*?*ID3D11DepthStencilView) callconv(.winapi) HRESULT;
        return method(self, 10, Fn)(self, resource, desc, depth_stencil_view);
    }

    pub fn createInputLayout(self: *ID3D11Device, input_element_descs: ?*const D3D11_INPUT_ELEMENT_DESC, num_elements: u32, shader_bytecode_with_input_signature: ?*const anyopaque, bytecode_length: usize, input_layout: ?*?*ID3D11InputLayout) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*const D3D11_INPUT_ELEMENT_DESC, u32, ?*const anyopaque, usize, ?*?*ID3D11InputLayout) callconv(.winapi) HRESULT;
        return method(self, 11, Fn)(self, input_element_descs, num_elements, shader_bytecode_with_input_signature, bytecode_length, input_layout);
    }

    pub fn createVertexShader(self: *ID3D11Device, shader_bytecode: ?*const anyopaque, bytecode_length: usize, class_linkage: ?*ID3D11ClassLinkage, vertex_shader: ?*?*ID3D11VertexShader) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*const anyopaque, usize, ?*ID3D11ClassLinkage, ?*?*ID3D11VertexShader) callconv(.winapi) HRESULT;
        return method(self, 12, Fn)(self, shader_bytecode, bytecode_length, class_linkage, vertex_shader);
    }

    pub fn createPixelShader(self: *ID3D11Device, shader_bytecode: ?*const anyopaque, bytecode_length: usize, class_linkage: ?*ID3D11ClassLinkage, pixel_shader: ?*?*ID3D11PixelShader) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*const anyopaque, usize, ?*ID3D11ClassLinkage, ?*?*ID3D11PixelShader) callconv(.winapi) HRESULT;
        return method(self, 15, Fn)(self, shader_bytecode, bytecode_length, class_linkage, pixel_shader);
    }

    pub fn createComputeShader(self: *ID3D11Device, shader_bytecode: ?*const anyopaque, bytecode_length: usize, class_linkage: ?*ID3D11ClassLinkage, compute_shader: ?*?*ID3D11ComputeShader) HRESULT {
        const Fn = *const fn (*ID3D11Device, ?*const anyopaque, usize, ?*ID3D11ClassLinkage, ?*?*ID3D11ComputeShader) callconv(.winapi) HRESULT;
        return method(self, 18, Fn)(self, shader_bytecode, bytecode_length, class_linkage, compute_shader);
    }

    pub fn createBlendState(self: *ID3D11Device, desc: *const D3D11_BLEND_DESC, blend_state: ?*?*ID3D11BlendState) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_BLEND_DESC, ?*?*ID3D11BlendState) callconv(.winapi) HRESULT;
        return method(self, 20, Fn)(self, desc, blend_state);
    }

    pub fn createDepthStencilState(self: *ID3D11Device, desc: *const D3D11_DEPTH_STENCIL_DESC, depth_stencil_state: ?*?*ID3D11DepthStencilState) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_DEPTH_STENCIL_DESC, ?*?*ID3D11DepthStencilState) callconv(.winapi) HRESULT;
        return method(self, 21, Fn)(self, desc, depth_stencil_state);
    }

    pub fn createRasterizerState(self: *ID3D11Device, desc: *const D3D11_RASTERIZER_DESC, rasterizer_state: ?*?*ID3D11RasterizerState) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_RASTERIZER_DESC, ?*?*ID3D11RasterizerState) callconv(.winapi) HRESULT;
        return method(self, 22, Fn)(self, desc, rasterizer_state);
    }

    pub fn createSamplerState(self: *ID3D11Device, desc: *const D3D11_SAMPLER_DESC, sampler_state: ?*?*ID3D11SamplerState) HRESULT {
        const Fn = *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, ?*?*ID3D11SamplerState) callconv(.winapi) HRESULT;
        return method(self, 23, Fn)(self, desc, sampler_state);
    }

    pub fn checkFormatSupport(self: *ID3D11Device, format: u32, format_support: ?*u32) HRESULT {
        const Fn = *const fn (*ID3D11Device, u32, ?*u32) callconv(.winapi) HRESULT;
        return method(self, 29, Fn)(self, format, format_support);
    }

    pub fn getFeatureLevel(self: *ID3D11Device) u32 {
        const Fn = *const fn (*ID3D11Device) callconv(.winapi) u32;
        return method(self, 37, Fn)(self);
    }

    pub fn getImmediateContext(self: *ID3D11Device, immediate_context: ?*?*ID3D11DeviceContext) void {
        const Fn = *const fn (*ID3D11Device, ?*?*ID3D11DeviceContext) callconv(.winapi) void;
        return method(self, 40, Fn)(self, immediate_context);
    }

    pub fn getDeviceRemovedReason(self: *ID3D11Device) HRESULT {
        const Fn = *const fn (*ID3D11Device) callconv(.winapi) HRESULT;
        return method(self, 39, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11DeviceContext` COM interface.
pub const ID3D11DeviceContext = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *ID3D11DeviceContext, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*ID3D11DeviceContext, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *ID3D11DeviceContext) u32 {
        const Fn = *const fn (*ID3D11DeviceContext) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *ID3D11DeviceContext) u32 {
        const Fn = *const fn (*ID3D11DeviceContext) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn vSSetConstantBuffers(self: *ID3D11DeviceContext, start_slot: u32, num_buffers: u32, constant_buffers: [*]const ?*ID3D11Buffer) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11Buffer) callconv(.winapi) void;
        return method(self, 7, Fn)(self, start_slot, num_buffers, constant_buffers);
    }

    pub fn pSSetShaderResources(self: *ID3D11DeviceContext, start_slot: u32, num_views: u32, shader_resource_views: [*]const ?*ID3D11ShaderResourceView) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void;
        return method(self, 8, Fn)(self, start_slot, num_views, shader_resource_views);
    }

    pub fn pSSetShader(self: *ID3D11DeviceContext, pixel_shader: ?*ID3D11PixelShader, class_instances: [*]const ?*ID3D11ClassInstance, num_class_instances: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, [*]const ?*ID3D11ClassInstance, u32) callconv(.winapi) void;
        return method(self, 9, Fn)(self, pixel_shader, class_instances, num_class_instances);
    }

    pub fn pSSetSamplers(self: *ID3D11DeviceContext, start_slot: u32, num_samplers: u32, samplers: [*]const ?*ID3D11SamplerState) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11SamplerState) callconv(.winapi) void;
        return method(self, 10, Fn)(self, start_slot, num_samplers, samplers);
    }

    pub fn vSSetShader(self: *ID3D11DeviceContext, vertex_shader: ?*ID3D11VertexShader, class_instances: [*]const ?*ID3D11ClassInstance, num_class_instances: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, [*]const ?*ID3D11ClassInstance, u32) callconv(.winapi) void;
        return method(self, 11, Fn)(self, vertex_shader, class_instances, num_class_instances);
    }

    pub fn drawIndexed(self: *ID3D11DeviceContext, index_count: u32, start_index_location: u32, base_vertex_location: i32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, i32) callconv(.winapi) void;
        return method(self, 12, Fn)(self, index_count, start_index_location, base_vertex_location);
    }

    pub fn draw(self: *ID3D11DeviceContext, vertex_count: u32, start_vertex_location: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32) callconv(.winapi) void;
        return method(self, 13, Fn)(self, vertex_count, start_vertex_location);
    }

    pub fn map(self: *ID3D11DeviceContext, resource: ?*ID3D11Resource, subresource: u32, map_type: u32, map_flags: u32, mapped_resource: ?*D3D11_MAPPED_SUBRESOURCE) HRESULT {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Resource, u32, u32, u32, ?*D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT;
        return method(self, 14, Fn)(self, resource, subresource, map_type, map_flags, mapped_resource);
    }

    pub fn unmap(self: *ID3D11DeviceContext, resource: ?*ID3D11Resource, subresource: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Resource, u32) callconv(.winapi) void;
        return method(self, 15, Fn)(self, resource, subresource);
    }

    pub fn pSSetConstantBuffers(self: *ID3D11DeviceContext, start_slot: u32, num_buffers: u32, constant_buffers: [*]const ?*ID3D11Buffer) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11Buffer) callconv(.winapi) void;
        return method(self, 16, Fn)(self, start_slot, num_buffers, constant_buffers);
    }

    pub fn iASetInputLayout(self: *ID3D11DeviceContext, input_layout: ?*ID3D11InputLayout) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11InputLayout) callconv(.winapi) void;
        return method(self, 17, Fn)(self, input_layout);
    }

    pub fn iASetVertexBuffers(self: *ID3D11DeviceContext, start_slot: u32, num_buffers: u32, vertex_buffers: [*]const ?*ID3D11Buffer, strides: ?[*]const u32, offsets: ?[*]const u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11Buffer, ?[*]const u32, ?[*]const u32) callconv(.winapi) void;
        return method(self, 18, Fn)(self, start_slot, num_buffers, vertex_buffers, strides, offsets);
    }

    pub fn iASetIndexBuffer(self: *ID3D11DeviceContext, index_buffer: ?*ID3D11Buffer, format: u32, offset: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Buffer, u32, u32) callconv(.winapi) void;
        return method(self, 19, Fn)(self, index_buffer, format, offset);
    }

    pub fn drawIndexedInstanced(self: *ID3D11DeviceContext, index_count_per_instance: u32, instance_count: u32, start_index_location: u32, base_vertex_location: i32, start_instance_location: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, u32, i32, u32) callconv(.winapi) void;
        return method(self, 20, Fn)(self, index_count_per_instance, instance_count, start_index_location, base_vertex_location, start_instance_location);
    }

    pub fn drawInstanced(self: *ID3D11DeviceContext, vertex_count_per_instance: u32, instance_count: u32, start_vertex_location: u32, start_instance_location: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, u32, u32) callconv(.winapi) void;
        return method(self, 21, Fn)(self, vertex_count_per_instance, instance_count, start_vertex_location, start_instance_location);
    }

    pub fn iASetPrimitiveTopology(self: *ID3D11DeviceContext, topology: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32) callconv(.winapi) void;
        return method(self, 24, Fn)(self, topology);
    }

    pub fn vSSetShaderResources(self: *ID3D11DeviceContext, start_slot: u32, num_views: u32, shader_resource_views: [*]const ?*ID3D11ShaderResourceView) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void;
        return method(self, 25, Fn)(self, start_slot, num_views, shader_resource_views);
    }

    pub fn vSSetSamplers(self: *ID3D11DeviceContext, start_slot: u32, num_samplers: u32, samplers: [*]const ?*ID3D11SamplerState) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11SamplerState) callconv(.winapi) void;
        return method(self, 26, Fn)(self, start_slot, num_samplers, samplers);
    }

    pub fn oMSetRenderTargets(self: *ID3D11DeviceContext, num_views: u32, render_target_views: [*]const ?*ID3D11RenderTargetView, depth_stencil_view: ?*ID3D11DepthStencilView) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, [*]const ?*ID3D11RenderTargetView, ?*ID3D11DepthStencilView) callconv(.winapi) void;
        return method(self, 33, Fn)(self, num_views, render_target_views, depth_stencil_view);
    }

    pub fn oMSetBlendState(self: *ID3D11DeviceContext, blend_state: ?*ID3D11BlendState, blend_factor: *const [4]f32, sample_mask: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, *const [4]f32, u32) callconv(.winapi) void;
        return method(self, 35, Fn)(self, blend_state, blend_factor, sample_mask);
    }

    pub fn oMSetDepthStencilState(self: *ID3D11DeviceContext, depth_stencil_state: ?*ID3D11DepthStencilState, stencil_ref: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11DepthStencilState, u32) callconv(.winapi) void;
        return method(self, 36, Fn)(self, depth_stencil_state, stencil_ref);
    }

    pub fn dispatch(self: *ID3D11DeviceContext, thread_group_count_x: u32, thread_group_count_y: u32, thread_group_count_z: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, u32) callconv(.winapi) void;
        return method(self, 41, Fn)(self, thread_group_count_x, thread_group_count_y, thread_group_count_z);
    }

    pub fn rSSetState(self: *ID3D11DeviceContext, rasterizer_state: ?*ID3D11RasterizerState) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11RasterizerState) callconv(.winapi) void;
        return method(self, 43, Fn)(self, rasterizer_state);
    }

    pub fn rSSetViewports(self: *ID3D11DeviceContext, num_viewports: u32, viewports: ?*const D3D11_VIEWPORT) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, ?*const D3D11_VIEWPORT) callconv(.winapi) void;
        return method(self, 44, Fn)(self, num_viewports, viewports);
    }

    pub fn rSSetScissorRects(self: *ID3D11DeviceContext, num_rects: u32, rects: ?*const D3D11_RECT) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, ?*const D3D11_RECT) callconv(.winapi) void;
        return method(self, 45, Fn)(self, num_rects, rects);
    }

    pub fn copySubresourceRegion(self: *ID3D11DeviceContext, dst_resource: ?*ID3D11Resource, dst_subresource: u32, dst_x: u32, dst_y: u32, dst_z: u32, src_resource: ?*ID3D11Resource, src_subresource: u32, src_box: ?*const D3D11_BOX) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Resource, u32, u32, u32, u32, ?*ID3D11Resource, u32, ?*const D3D11_BOX) callconv(.winapi) void;
        return method(self, 46, Fn)(self, dst_resource, dst_subresource, dst_x, dst_y, dst_z, src_resource, src_subresource, src_box);
    }

    pub fn copyResource(self: *ID3D11DeviceContext, dst_resource: ?*ID3D11Resource, src_resource: ?*ID3D11Resource) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Resource, ?*ID3D11Resource) callconv(.winapi) void;
        return method(self, 47, Fn)(self, dst_resource, src_resource);
    }

    pub fn updateSubresource(self: *ID3D11DeviceContext, dst_resource: ?*ID3D11Resource, dst_subresource: u32, dst_box: ?*const D3D11_BOX, src_data: ?*const anyopaque, src_row_pitch: u32, src_depth_pitch: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11Resource, u32, ?*const D3D11_BOX, ?*const anyopaque, u32, u32) callconv(.winapi) void;
        return method(self, 48, Fn)(self, dst_resource, dst_subresource, dst_box, src_data, src_row_pitch, src_depth_pitch);
    }

    pub fn clearRenderTargetView(self: *ID3D11DeviceContext, render_target_view: ?*ID3D11RenderTargetView, color_rgba: *const [4]f32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11RenderTargetView, *const [4]f32) callconv(.winapi) void;
        return method(self, 50, Fn)(self, render_target_view, color_rgba);
    }

    pub fn clearDepthStencilView(self: *ID3D11DeviceContext, depth_stencil_view: ?*ID3D11DepthStencilView, clear_flags: u32, depth: f32, stencil: u8) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11DepthStencilView, u32, f32, u8) callconv(.winapi) void;
        return method(self, 53, Fn)(self, depth_stencil_view, clear_flags, depth, stencil);
    }

    pub fn cSSetShaderResources(self: *ID3D11DeviceContext, start_slot: u32, num_views: u32, shader_resource_views: [*]const ?*ID3D11ShaderResourceView) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void;
        return method(self, 67, Fn)(self, start_slot, num_views, shader_resource_views);
    }

    pub fn cSSetUnorderedAccessViews(self: *ID3D11DeviceContext, start_slot: u32, num_uavs: u32, unordered_access_views: [*]const ?*ID3D11UnorderedAccessView, uav_initial_counts: ?[*]const u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11UnorderedAccessView, ?[*]const u32) callconv(.winapi) void;
        return method(self, 68, Fn)(self, start_slot, num_uavs, unordered_access_views, uav_initial_counts);
    }

    pub fn cSSetShader(self: *ID3D11DeviceContext, compute_shader: ?*ID3D11ComputeShader, class_instances: [*]const ?*ID3D11ClassInstance, num_class_instances: u32) void {
        const Fn = *const fn (*ID3D11DeviceContext, ?*ID3D11ComputeShader, [*]const ?*ID3D11ClassInstance, u32) callconv(.winapi) void;
        return method(self, 69, Fn)(self, compute_shader, class_instances, num_class_instances);
    }

    pub fn cSSetSamplers(self: *ID3D11DeviceContext, start_slot: u32, num_samplers: u32, samplers: [*]const ?*ID3D11SamplerState) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11SamplerState) callconv(.winapi) void;
        return method(self, 70, Fn)(self, start_slot, num_samplers, samplers);
    }

    pub fn cSSetConstantBuffers(self: *ID3D11DeviceContext, start_slot: u32, num_buffers: u32, constant_buffers: [*]const ?*ID3D11Buffer) void {
        const Fn = *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11Buffer) callconv(.winapi) void;
        return method(self, 71, Fn)(self, start_slot, num_buffers, constant_buffers);
    }

    pub fn flush(self: *ID3D11DeviceContext) void {
        const Fn = *const fn (*ID3D11DeviceContext) callconv(.winapi) void;
        return method(self, 111, Fn)(self);
    }
};

// ---------------------------------------------------------------------------
// D3D11 resource interfaces (release only).
// ---------------------------------------------------------------------------

/// Wraps the Windows `ID3D11Resource` COM interface.
pub const ID3D11Resource = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11Resource) u32 {
        const Fn = *const fn (*ID3D11Resource) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11Buffer` COM interface.
pub const ID3D11Buffer = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11Buffer) u32 {
        const Fn = *const fn (*ID3D11Buffer) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11Texture1D` COM interface.
pub const ID3D11Texture1D = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11Texture1D) u32 {
        const Fn = *const fn (*ID3D11Texture1D) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11Texture2D` COM interface.
pub const ID3D11Texture2D = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11Texture2D) u32 {
        const Fn = *const fn (*ID3D11Texture2D) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11Texture3D` COM interface.
pub const ID3D11Texture3D = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11Texture3D) u32 {
        const Fn = *const fn (*ID3D11Texture3D) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11ShaderResourceView` COM interface.
pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11ShaderResourceView) u32 {
        const Fn = *const fn (*ID3D11ShaderResourceView) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11RenderTargetView` COM interface.
pub const ID3D11RenderTargetView = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11RenderTargetView) u32 {
        const Fn = *const fn (*ID3D11RenderTargetView) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11DepthStencilView` COM interface.
pub const ID3D11DepthStencilView = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11DepthStencilView) u32 {
        const Fn = *const fn (*ID3D11DepthStencilView) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11UnorderedAccessView` COM interface.
pub const ID3D11UnorderedAccessView = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11UnorderedAccessView) u32 {
        const Fn = *const fn (*ID3D11UnorderedAccessView) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11SamplerState` COM interface.
pub const ID3D11SamplerState = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11SamplerState) u32 {
        const Fn = *const fn (*ID3D11SamplerState) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11VertexShader` COM interface.
pub const ID3D11VertexShader = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11VertexShader) u32 {
        const Fn = *const fn (*ID3D11VertexShader) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11PixelShader` COM interface.
pub const ID3D11PixelShader = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11PixelShader) u32 {
        const Fn = *const fn (*ID3D11PixelShader) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11ComputeShader` COM interface.
pub const ID3D11ComputeShader = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11ComputeShader) u32 {
        const Fn = *const fn (*ID3D11ComputeShader) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11InputLayout` COM interface.
pub const ID3D11InputLayout = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11InputLayout) u32 {
        const Fn = *const fn (*ID3D11InputLayout) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11BlendState` COM interface.
pub const ID3D11BlendState = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11BlendState) u32 {
        const Fn = *const fn (*ID3D11BlendState) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11DepthStencilState` COM interface.
pub const ID3D11DepthStencilState = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11DepthStencilState) u32 {
        const Fn = *const fn (*ID3D11DepthStencilState) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11RasterizerState` COM interface.
pub const ID3D11RasterizerState = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11RasterizerState) u32 {
        const Fn = *const fn (*ID3D11RasterizerState) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11ClassInstance` COM interface.
pub const ID3D11ClassInstance = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11ClassInstance) u32 {
        const Fn = *const fn (*ID3D11ClassInstance) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `ID3D11ClassLinkage` COM interface.
pub const ID3D11ClassLinkage = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *ID3D11ClassLinkage) u32 {
        const Fn = *const fn (*ID3D11ClassLinkage) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

// ---------------------------------------------------------------------------
// DXGI interfaces.
// ---------------------------------------------------------------------------

/// Wraps the Windows `IDXGIAdapter` COM interface.
pub const IDXGIAdapter = extern struct {
    vtable: *const anyopaque,

    pub fn release(self: *IDXGIAdapter) u32 {
        const Fn = *const fn (*IDXGIAdapter) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }
};

/// Wraps the Windows `IDXGIAdapter1` COM interface.
pub const IDXGIAdapter1 = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IDXGIAdapter1, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGIAdapter1, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IDXGIAdapter1) u32 {
        const Fn = *const fn (*IDXGIAdapter1) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IDXGIAdapter1) u32 {
        const Fn = *const fn (*IDXGIAdapter1) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getDesc1(self: *IDXGIAdapter1, desc: ?*DXGI_ADAPTER_DESC1) HRESULT {
        const Fn = *const fn (*IDXGIAdapter1, ?*DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT;
        return method(self, 10, Fn)(self, desc);
    }
};

/// Wraps the Windows `IDXGIDevice` COM interface.
pub const IDXGIDevice = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IDXGIDevice, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGIDevice, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IDXGIDevice) u32 {
        const Fn = *const fn (*IDXGIDevice) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IDXGIDevice) u32 {
        const Fn = *const fn (*IDXGIDevice) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getAdapter(self: *IDXGIDevice, adapter: ?*?*IDXGIAdapter) HRESULT {
        const Fn = *const fn (*IDXGIDevice, ?*?*IDXGIAdapter) callconv(.winapi) HRESULT;
        return method(self, 7, Fn)(self, adapter);
    }
};

/// Wraps the Windows `IDXGIFactory2` COM interface.
pub const IDXGIFactory2 = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IDXGIFactory2, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGIFactory2, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IDXGIFactory2) u32 {
        const Fn = *const fn (*IDXGIFactory2) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IDXGIFactory2) u32 {
        const Fn = *const fn (*IDXGIFactory2) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn makeWindowAssociation(self: *IDXGIFactory2, window: ?*anyopaque, flags: u32) HRESULT {
        const Fn = *const fn (*IDXGIFactory2, ?*anyopaque, u32) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self, window, flags);
    }

    pub fn createSwapChainForHwnd(self: *IDXGIFactory2, device: ?*IUnknown, hwnd: ?*anyopaque, desc: *const DXGI_SWAP_CHAIN_DESC1, fullscreen_desc: ?*const anyopaque, restrict_to_output: ?*anyopaque, swap_chain: ?*?*IDXGISwapChain1) HRESULT {
        const Fn = *const fn (*IDXGIFactory2, ?*IUnknown, ?*anyopaque, *const DXGI_SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, ?*?*IDXGISwapChain1) callconv(.winapi) HRESULT;
        return method(self, 15, Fn)(self, device, hwnd, desc, fullscreen_desc, restrict_to_output, swap_chain);
    }
};

/// Wraps the Windows `IDXGISwapChain1` COM interface.
pub const IDXGISwapChain1 = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IDXGISwapChain1, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGISwapChain1, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IDXGISwapChain1) u32 {
        const Fn = *const fn (*IDXGISwapChain1) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IDXGISwapChain1) u32 {
        const Fn = *const fn (*IDXGISwapChain1) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn present(self: *IDXGISwapChain1, sync_interval: u32, flags: u32) HRESULT {
        const Fn = *const fn (*IDXGISwapChain1, u32, u32) callconv(.winapi) HRESULT;
        return method(self, 8, Fn)(self, sync_interval, flags);
    }

    pub fn getBuffer(self: *IDXGISwapChain1, buffer_idx: u32, riid: *const GUID, surface: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGISwapChain1, u32, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 9, Fn)(self, buffer_idx, riid, surface);
    }

    pub fn getDesc1(self: *IDXGISwapChain1, desc: ?*DXGI_SWAP_CHAIN_DESC1) HRESULT {
        const Fn = *const fn (*IDXGISwapChain1, ?*DXGI_SWAP_CHAIN_DESC1) callconv(.winapi) HRESULT;
        return method(self, 18, Fn)(self, desc);
    }
};

/// Wraps the Windows `IDXGISwapChain3` COM interface.
pub const IDXGISwapChain3 = extern struct {
    vtable: *const anyopaque,

    pub fn queryInterface(self: *IDXGISwapChain3, riid: *const GUID, obj: ?*?*anyopaque) HRESULT {
        const Fn = *const fn (*IDXGISwapChain3, *const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
        return method(self, 0, Fn)(self, riid, obj);
    }

    pub fn addRef(self: *IDXGISwapChain3) u32 {
        const Fn = *const fn (*IDXGISwapChain3) callconv(.winapi) u32;
        return method(self, 1, Fn)(self);
    }

    pub fn release(self: *IDXGISwapChain3) u32 {
        const Fn = *const fn (*IDXGISwapChain3) callconv(.winapi) u32;
        return method(self, 2, Fn)(self);
    }

    pub fn getCurrentBackBufferIndex(self: *IDXGISwapChain3) u32 {
        const Fn = *const fn (*IDXGISwapChain3) callconv(.winapi) u32;
        return method(self, 36, Fn)(self);
    }
};

/// Creates a flip-model swap chain for a window.
///
/// Tries `DXGI_SWAP_EFFECT_FLIP_DISCARD` first and falls back to
/// `DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL` when creation fails or when
/// only back buffer 0 can be retrieved. Some drivers accept a
/// `FLIP_DISCARD` description but keep bitblt behavior, so every
/// buffer past zero becomes unavailable and `Swapchain.images`
/// would hand out broken handles.
///
/// # Args
/// - `factory`: factory that creates the swap chain.
/// - `device`: D3D11 device or D3D12 command queue.
/// - `hwnd`: target window owned by the caller.
/// - `desc`: swap chain description; `swap_effect` is overwritten.
/// - `probe_iid`: interface used to fetch the last back buffer.
/// - `swap_chain`: receives the new swap chain on success.
///
/// # Return
/// `S_OK` on success, or the last failing `HRESULT`.
///
/// # Note
/// A flip-model swap chain needs `buffer_count >= 2`. The caller
/// owns the returned swap chain.
pub fn createFlipSwapChainForHwnd(
    factory: *IDXGIFactory2,
    device: ?*IUnknown,
    hwnd: HWND,
    desc: *DXGI_SWAP_CHAIN_DESC1,
    probe_iid: *const GUID,
    swap_chain: *?*IDXGISwapChain1,
) HRESULT {
    if (desc.buffer_count == 0) return E_INVALIDARG;
    const effects = [_]u32{
        DXGI_SWAP_EFFECT_FLIP_DISCARD,
        DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
    };
    var last_error: HRESULT = E_INVALIDARG;
    for (effects) |effect| {
        desc.swap_effect = effect;
        swap_chain.* = null;
        const hr = factory.createSwapChainForHwnd(
            device,
            hwnd,
            desc,
            null,
            null,
            swap_chain,
        );
        if (failed(hr) or swap_chain.* == null) {
            last_error = hr;
            continue;
        }
        var buffer: ?*anyopaque = null;
        const probe_hr = swap_chain.*.?.getBuffer(
            desc.buffer_count - 1,
            probe_iid,
            &buffer,
        );
        if (buffer) |ptr| {
            const unknown: *IUnknown = @ptrCast(@alignCast(ptr));
            _ = unknown.release();
        }
        if (succeeded(probe_hr)) return 0;
        last_error = probe_hr;
        _ = swap_chain.*.?.release();
        swap_chain.* = null;
    }
    return last_error;
}

// ---------------------------------------------------------------------------
// External functions.
// ---------------------------------------------------------------------------

/// Links `D3D12CreateDevice` from `d3d12`.
pub extern "d3d12" fn D3D12CreateDevice(adapter: ?*IUnknown, minimum_feature_level: u32, riid: *const GUID, device: ?*?*anyopaque) callconv(.winapi) HRESULT;
/// Links `D3D12SerializeRootSignature` from `d3d12`.
pub extern "d3d12" fn D3D12SerializeRootSignature(root_signature_desc: *const D3D12_ROOT_SIGNATURE_DESC, version: u32, blob: ?*?*ID3DBlob, error_blob: ?*?*ID3DBlob) callconv(.winapi) HRESULT;

/// Links `CreateDXGIFactory1` from `dxgi`.
pub extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, factory: ?*?*anyopaque) callconv(.winapi) HRESULT;
/// Links `CreateDXGIFactory2` from `dxgi`.
pub extern "dxgi" fn CreateDXGIFactory2(flags: u32, riid: *const GUID, factory: ?*?*anyopaque) callconv(.winapi) HRESULT;

/// Links `D3D11CreateDevice` from `d3d11`.
pub extern "d3d11" fn D3D11CreateDevice(adapter: ?*IDXGIAdapter, driver_type: u32, software: ?*anyopaque, flags: u32, feature_levels: ?[*]const u32, feature_level_count: u32, sdk_version: u32, device: ?*?*ID3D11Device, feature_level: ?*u32, immediate_context: ?*?*ID3D11DeviceContext) callconv(.winapi) HRESULT;

/// Links `D3DCompile` from `d3dcompiler_47`.
pub extern "d3dcompiler_47" fn D3DCompile(data: ?*const anyopaque, data_size: usize, filename: ?[*:0]const u8, defines: ?*const anyopaque, include: ?*anyopaque, entrypoint: ?[*:0]const u8, target: ?[*:0]const u8, sflags: u32, eflags: u32, shader: ?*?*ID3DBlob, error_messages: ?*?*ID3DBlob) callconv(.winapi) HRESULT;

/// Links `Sleep` from `kernel32`.
pub extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
/// Links `GetTickCount64` from `kernel32`.
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
