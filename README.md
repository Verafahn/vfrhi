# vfrhi

A render hardware interface (RHI) for Zig. Write rendering code once and
run it on Vulkan, OpenGL, or Direct3D 11/12 — or run the exact same code
headlessly in tests, with no GPU.

[![CI](https://github.com/Verafahn/vfrhi/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Verafahn/vfrhi/actions/workflows/ci.yml)
![Zig](https://img.shields.io/badge/zig-0.17.1-f7a41d)

## Features

- **One API, multiple backends.** The same resources and commands run on
  the Vulkan backend, the OpenGL backend, the Direct3D 11 and 12
  backends, and the built-in test backend.
- **Vulkan 1.3 backend.** Dynamic rendering, graphics and compute
  pipelines, SPIR-V shaders, and Win32, Xlib, or Wayland surfaces.
- **OpenGL 4.5 backend.** GLAD loaded entry points, immutable textures,
  direct state access, dynamic rendering emulated with framebuffers, and
  automatic SPIR-V to GLSL translation.
- **Direct3D 11 and 12 backends (Windows).** Native D3D11 devices and a
  D3D12 device with a direct queue, descriptor heaps, and command
  allocators. Shaders are accepted as SPIR-V and translated to HLSL,
  then compiled with the system D3DCompiler at runtime.
- **Tests without a GPU.** `rhi.Test` catches leaks, incorrect
  destruction order, stale handles, invalid map/unmap calls, invalid
  command buffer state, and bad submission parameters. It also exposes
  buffer and texture bytes so tests can assert on uploaded data.
- **All the usual resources.** Buffers, textures, texture views,
  samplers, shader modules, descriptor set layouts, pipeline layouts,
  descriptor sets, graphics and compute pipelines, command buffers,
  fences, semaphores, surfaces, and swapchains.
- **Practical command set.** Dynamic rendering, draws, indexed draws,
  compute dispatches, buffer and texture copies, pipeline barriers, push
  constants, viewport, and scissor.
- **Safe handles.** Destroyed, stale, or wrong-type handles are rejected
  instead of causing undefined behaviour.
- **Five runnable examples.** Clear, triangle, indexed quad, batched
  triangles, and texture mapping. Each one is an independent Zig project
  that compiles its Zig shaders to SPIR-V and switches between Vulkan,
  OpenGL, Direct3D 11, and Direct3D 12 with `--backend`.
- **No window framework required.** You pass vfrhi the native window
  handles; GLFW, SDL, or your own platform layer all work.
- **Small integration cost.** Importing vfrhi does not fetch the Vulkan
  toolchain. The backend is pulled in only when you enable it.

## Requirements

- Zig 0.17.1.
- For the Vulkan backend: a Vulkan 1.3 device with dynamic rendering.
  Enable the instance extension for your window system when you create
  the backend (`VK_KHR_win32_surface`, `VK_KHR_xlib_surface`, or
  `VK_KHR_wayland_surface`).
- For the OpenGL backend: an OpenGL 4.5 core profile context. The caller
  creates and owns the window, context, and loader; vfrhi never touches
  the window system. Shaders are accepted as SPIR-V and decompiled to
  GLSL 4.50 by the backend.
- For the Direct3D 11 and 12 backends: Windows 10 or later. Direct3D 12
  also needs a device that supports feature level 11.0. SPIR-V shaders
  are translated to HLSL 5.x and compiled with `d3dcompiler_47.dll`,
  which ships with Windows.

## Installation

Fetch the package:

```sh
zig fetch --save git+https://github.com/Verafahn/vfrhi.git
```

Then import it in your `build.zig`:

```zig
const vfrhi = b.dependency("vfrhi", .{
    .target = target,
    .optimize = optimize,
    .vulkan = true, // omit to skip the Vulkan toolchain
    .opengl = true, // omit to skip the OpenGL loader
    .dx3d11 = true, // omit to skip the Direct3D 11 backend
    .dx3d12 = true, // omit to skip the Direct3D 12 backend
});

exe.root_module.addImport("vfrhi", vfrhi.module("rhi"));
```

All backends are off by default when vfrhi is a dependency, so
referencing `rhi.Vulkan`, `rhi.OpenGL`, `rhi.Dx3d11`, or `rhi.Dx3d12`
without enabling the matching option is a compile error. When building
vfrhi itself, Vulkan, OpenGL, and (on Windows) both Direct3D backends
are enabled by default; pass `-Dvulkan=false`, `-Dopengl=false`,
`-Ddx3d11=false`, or `-Ddx3d12=false` to `zig build` to turn one off.
The Direct3D backends are only available when the target is Windows:
they stay off for every other target, and enabling them explicitly for
such a target is a build error.

## Quick start

Create a Vulkan backend and borrow a queue from its device:

```zig
const rhi = @import("vfrhi");

// A function with the same signature as vkGetInstanceProcAddr,
// for example glfwGetInstanceProcAddress.
const backend = try rhi.Vulkan.init(
    gpa,
    loader_fn,
    .{
        .application_name = "my app",
        .api_version = .api_1_3,
        // Enable the surface extension your window system needs.
        .enabled_extension = instance_extensions,
        .extension_count = instance_extension_count,
    },
);
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);
```

Destroy every RHI resource before `backend.deinit()`. Each resource has
an explicit `destroy` method, and `device.createBatch` /
`device.destroyBatch` are available when you want to create or destroy
several at once.

### OpenGL

Make the context current first, then initialize the backend with a GLAD
compatible loader such as `glfwGetProcAddress`:

```zig
const backend = try rhi.OpenGL.init(
    gpa,
    glfw.glfwGetProcAddress,
    .{ .api_version = .make(0, 4, 5, 0) },
);
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);
```

The OpenGL backend requires a 4.5 core profile. It exposes swapchain
images as textures rendered through framebuffers and presents them by
blitting to the default framebuffer. Because vfrhi must not depend on a
window system, the caller presents the window itself after
`Swapchain.present`, for example with `glfwSwapBuffers(window)`.

OpenGL has no native SPIR-V entry point that is portable, so the backend
converts SPIR-V to GLSL 4.50 before compiling it. The translator covers
the shader subset emitted by Zig's SPIR-V backend and by
`glslangValidator -V` / `glslc` for the stages and features vfrhi
exposes. Modules that use obscure SPIR-V
instructions return `error.Unsupported` instead of compiling silently
wrong code.

### Direct3D 11 and 12

Both Direct3D backends ship in the same RHI module on Windows and
share one hand-written bindings file, so no extra package is fetched.
When the options are enabled, the module links `dxgi`,
`d3dcompiler_47`, and the matching `d3d11` or `d3d12` library from the
system.

```zig
const backend = try rhi.Dx3d11.init(gpa, .{});
// or
const backend = try rhi.Dx3d12.init(gpa, .{});
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);
```

Like the other backends, vfrhi never creates a window. Pass the Win32
`HWND` in `SurfaceDescription`; a headless surface with a width and
height uses offscreen textures instead. Swapchain presentation calls
`IDXGISwapChain::Present`, so the caller does not swap buffers itself.

Direct3D consumes HLSL and DXBC, not SPIR-V, so both backends translate
the module to HLSL 5.x and call `D3DCompile`. The translator covers the
same SPIR-V subset as the OpenGL translator: rasterization stages,
uniform blocks, push constants, combined image samplers, and simple
control flow. Storage buffers and atomics return `error.Unsupported`.
The generated shaders flip the clip-space Y so the same SPIR-V draws the
same image as it does on Vulkan.

Create a surface from a native window handle and a swapchain from the
surface:

```zig
const surface = try rhi.Surface.create(device, .{
    .native = .{ .win32 = .{
        .hinstance = hinstance,
        .hwnd = hwnd,
    } },
});
defer surface.destroy();

const swapchain = try rhi.Swapchain.create(device, .{
    .surface = surface.resource,
    .width = 800,
    .height = 600,
    .format = .b8g8r8a8_srgb,
    .present_mode = .fifo,
    .image_count = 3,
});
defer swapchain.destroy();
```

`Surface.Description.Native` also accepts `.xlib` and `.wayland` handles.
The actual swapchain extent and image count are available from
`swapchain.properties` after creation.

## Buffers

Host-visible buffers can be written and read directly. Device-local
buffers are filled through commands or `initial_data`.

```zig
const vertices = [_]f32{
    -0.5, -0.5, 0.0,
     0.5, -0.5, 0.0,
     0.0,  0.5, 0.0,
};

const vertex_buffer = try rhi.Buffer.create(device, .{
    .size = std.mem.sliceAsBytes(&vertices).len,
    .usage = .{ .vertex = true },
    .memory = .{ .host_visible = true },
    .initial_data = std.mem.sliceAsBytes(&vertices),
});
defer vertex_buffer.destroy();

// Update part of the buffer later.
try vertex_buffer.write(0, std.mem.sliceAsBytes(&vertices));

// Read it back.
var readback: [12]f32 = undefined;
try vertex_buffer.read(0, std.mem.sliceAsBytes(&readback));
```

`BufferDescription.memory` supports `device_local`, `host_visible`,
`host_coherent`, and `host_cached`. Non-host-visible buffers that use
`initial_data` must enable `usage.transfer_dst`.

## Textures and samplers

Textures take tightly packed or strided pixel data at creation:

```zig
const texture = try rhi.Texture.create(device, .{
    .format = .r8g8b8a8_unorm,
    .width = 256,
    .height = 256,
    .usage = .{ .sampled = true, .transfer_dst = true },
    .initial_data = .{ .bytes = pixels },
});
defer texture.destroy();

const view = try texture.createView(.{});
defer view.destroy();

const sampler = try rhi.Sampler.create(device, .{
    .mag_filter = .linear,
    .min_filter = .linear,
    .address_u = .clamp_to_edge,
    .address_v = .clamp_to_edge,
});
defer sampler.destroy();
```

Use `.row_pitch` and `.image_height` in `TextureData` when the source
rows are padded. Textures also support mip levels, array layers,
multisampling, 1D/2D/3D types, and every format listed in
`rhi.types.Format`.

## Pipelines and descriptors

```zig
const Vertex = extern struct {
    position: [3]f32,
};

const vertex = try rhi.Shader.create(device, .{
    .stage = .vertex,
    .code = vertex_spirv, // []const u32
});
defer vertex.destroy();

const fragment = try rhi.Shader.create(device, .{
    .stage = .fragment,
    .code = fragment_spirv,
});
defer fragment.destroy();

const set_layout = try rhi.DescriptorSetLayout.create(device, .{
    .bindings = &.{
        .{
            .binding = 0,
            .kind = .uniform_buffer,
            .stages = .{ .vertex = true },
        },
        .{
            .binding = 1,
            .kind = .combined_image_sampler,
            .stages = .{ .fragment = true },
        },
    },
});
defer set_layout.destroy();

const pipeline_layout = try rhi.PipelineLayout.create(device, .{
    .descriptor_sets = &.{set_layout.resource},
});
defer pipeline_layout.destroy();

const descriptor_set = try rhi.DescriptorSet.create(device, .{
    .layout = set_layout.resource,
});
defer descriptor_set.destroy();

try descriptor_set.update(&.{
    .{
        .binding = 0,
        .kind = .{ .buffer = .{
            // A buffer created like vertex_buffer above.
            .buffer = uniform_buffer.resource,
            .size = uniform_buffer.size,
        } },
    },
    .{
        .binding = 1,
        .kind = .{ .texture = .{
            .view = view.resource,
            .sampler = sampler.resource,
        } },
    },
});

const pipeline = try rhi.GraphicsPipeline.create(device, .{
    .layout = pipeline_layout.resource,
    .vertex = vertex.resource,
    .fragment = fragment.resource,
    .vertex_layout = .{
        .bindings = &.{.{ .stride = @sizeOf(Vertex) }},
        .attributes = &.{
            .{
                .location = 0,
                .format = .r32g32b32_float,
                .offset = 0,
            },
        },
    },
    .depth = .{ .enable = false, .write = false },
    .color_formats = &.{.b8g8r8a8_srgb},
});
defer pipeline.destroy();
```

Compute pipelines use the same layouts with a single compute shader via
`rhi.ComputePipeline.create`.

Shaders are SPIR-V modules. The examples write shaders as Zig functions
with the SPIR-V calling conventions and compile them to the
`spirv32-vulkan` target in `build.zig`. Any SPIR-V producer, such as
`glslangValidator -V` or `glslc`, also works.

## Render a frame

```zig
const images = try swapchain.images(gpa);
defer gpa.free(images);

const views = try swapchain.views(gpa);
defer gpa.free(views);

const image_available = try rhi.Semaphore.create(device, .{});
defer image_available.destroy();

const render_finished = try rhi.Semaphore.create(device, .{});
defer render_finished.destroy();

const in_flight = try rhi.Fence.create(device, .{ .signaled = true });
defer in_flight.destroy();

const command_buffer = try rhi.CommandBuffer.create(device, .{});
defer command_buffer.destroy();

// Once per frame:
try in_flight.wait(std.math.maxInt(u64));
try in_flight.reset();

const acquired = try swapchain.acquire(queue, image_available, null);
const target_image = images[acquired.image_index];
const target_view = views[acquired.image_index];

try command_buffer.begin();
try command_buffer.barrier(.{
    .resource = target_image,
    .src_stage = .top_of_pipe,
    .dst_stage = .color_attachment,
    .dst_access = .{ .color_attachment_write = true },
    .layout_before = .undefined,
    .layout_after = .color_attachment,
});
try command_buffer.beginRendering(.{
    .area = .{ .width = width, .height = height },
    .color_attachments = &.{.{
        .view = target_view,
        .load = .clear,
        .store = .store,
        .clear = .{ .r = 0.05, .g = 0.08, .b = 0.16 },
    }},
});
try command_buffer.bindPipeline(.{ .pipeline = pipeline.resource });
try command_buffer.bindVertexBuffers(.{
    .buffers = &.{vertex_buffer.resource},
});
try command_buffer.draw(.{ .vertex_count = 3 });
try command_buffer.endRendering();
try command_buffer.barrier(.{
    .resource = target_image,
    .src_stage = .color_attachment,
    .dst_stage = .bottom_of_pipe,
    .src_access = .{ .color_attachment_write = true },
    .layout_before = .color_attachment,
    .layout_after = .present,
});
try command_buffer.end();

try command_buffer.submit(queue, .{
    .wait_semaphores = &.{image_available.resource},
    .signal_semaphores = &.{render_finished.resource},
    .fence = in_flight,
});

try swapchain.present(.{
    .queue = queue,
    .image_index = acquired.image_index,
    .wait_semaphores = &.{render_finished.resource},
});
```

`swapchain.images(gpa)` and `swapchain.views(gpa)` return arrays of
handles that you free with the same allocator. Handle
`error.SurfaceOutOfDate` by recreating the swapchain.

Use the submission fence (`in_flight.wait(timeout_ns)`) or
`queue.waitIdle()` before reading or rewriting resources that the GPU
may still be using.

## Queries

Ask the device about its capabilities before relying on them:

```zig
const name = try device.getDeviceName(gpa);
defer gpa.free(name);

const max_texture = try device.getLimit(.max_texture_dimension_2d);
const queue_props = try device.getQueueProperties(0);

if (try device.supportsFormat(.r8g8b8a8_unorm, .{ .storage = true })) {
    // The format can be used as a storage image.
}
```

`Device.Feature` also exposes the API version, device and driver names,
device type, memory heaps, and buffer, texture, surface, and swapchain
properties.

## Testing without a GPU

`rhi.Test` implements the same device interface as the Vulkan backend,
so production resource and command code runs unchanged in tests.
`validate` fails on leaked resources or validation errors.

```zig
test "records a draw" {
    const backend = try rhi.Test.init(std.testing.allocator);
    defer backend.deinit();

    const device = backend.asDevice();

    // Create and use resources exactly like the Vulkan path.

    try backend.validate();
}
```

To assert on uploaded data, use `backend.bufferData(resource)` or
`backend.textureData(resource)`:

```zig
const bytes = backend.bufferData(vertex_buffer.resource).?;
try std.testing.expectEqualSlices(
    u8,
    std.mem.sliceAsBytes(&vertices),
    bytes,
);
```

## Building and running

```sh
zig build test --summary all    # headless test suite, no GPU needed
zig build test -Dvulkan=false   # skip the Vulkan backend and toolchain
zig build test -Dopengl=false   # skip the OpenGL backend and loader
zig build test -Ddx3d11=false -Ddx3d12=false # skip the Direct3D backends
zig build test -Ddisable-render=true # only build the test backend
```

### Examples

Every directory under `examples/` is an independent Zig project with its
own `build.zig` and `build.zig.zon`. The manifest pulls in vfrhi from this
repository, so the examples stay in sync with the interface. Examples are
not part of the package distribution; their run steps are only added when
vfrhi is the root project.

| Example | Run step | Demonstrates |
| --- | --- | --- |
| `examples/clear` | `zig build run-clear` | Window creation and clearing a render pass |
| `examples/triangle` | `zig build run-triangle` | Vertex buffer, shaders, and a graphics pipeline |
| `examples/quad` | `zig build run-quad` | Element buffer with `drawIndexed` |
| `examples/batch` | `zig build run-batch` | Thousands of triangles in a single draw call |
| `examples/texture` | `zig build run-texture` | Texture upload, sampler, and descriptor set |

Each step changes into the example directory and runs `zig build run`
there. Arguments after the outer `--` are forwarded to that build, so
build options go before a second `--` and program arguments go after it:

```sh
zig build run-triangle -- -Doptimize=ReleaseFast -- --backend vulkan --frames 2
```

Without build options, keep the empty argument group:

```sh
zig build run-triangle -- -- --backend opengl --frames 2
```

Running from the example directory is equivalent:

```sh
cd examples/triangle
zig build run -- --backend vulkan --frames 2
```

`--frames 0` keeps the window open until it is closed. Shaders live in
each example's `shaders/` directory as Zig source files. The example
`build.zig` compiles them to SPIR-V objects and embeds the resulting
binaries with `@embedFile`; no external shader compiler is required.
The Direct3D backends are only compiled into the examples on Windows.

The examples use GLFW for window creation and input. vfrhi itself does
not depend on GLFW, and `src/` never assumes a window system exists.

## Limitations

- The test backend validates calls but does not rasterize anything.
- The Vulkan backend requires Vulkan 1.3 and dynamic rendering, and it
  does not provide a headless surface. Use the test backend for GPU-free
  runs.
- The OpenGL backend requires OpenGL 4.5 core, a current context, and a
  caller supplied loader. It emulates swapchains with textures, has no
  real semaphores, and reports one memory heap with size `0` because
  OpenGL exposes no heap size. Shaders are translated from SPIR-V to
  GLSL before compiling, and presentation does not swap the window
  buffer.
- The Direct3D backends are Windows only and require
  `d3dcompiler_47.dll` at runtime. Shaders are translated from SPIR-V to
  HLSL 5.x; storage buffers, atomics, and geometry or tessellation
  stages are not supported yet. Some drivers expose flip-model
  swapchains whose non-zero back buffers cannot be used as render
  targets; the Direct3D 11 backend detects this and falls back to a
  single-buffer bitblt swapchain whose images alias one back buffer.
- The command set does not yet include indirect draws, timestamp
  queries, or advanced features such as ray tracing and mesh shaders.
- The project is pre-1.0 and the API may change between releases.
