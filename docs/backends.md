# Backends

Every backend implements the same `Device` and `Queue` interfaces, but
the native APIs do not offer the same guarantees. This page describes
what each backend needs from its platform, how it maps the abstract
model, and where behavior intentionally differs.

## Common model

All current GPU backends expose **one queue** at index `0` with
graphics and transfer capabilities, and it is the presentation queue
when the backend supports surfaces. `Test.initWithOptions` can expose a
configurable queue layout for tests, but its default queue has the same
capabilities. Asking for any other index returns `error.Unsupported`.

All backends validate handle generation and tag on use, translate
native failures into the shared `Error` set, and report capabilities
through `Device.query`. None of them creates a window, an event loop, or
an application-owned graphics context.

The table below is a quick map of the backend-specific behavior that
follows.

| Property | Vulkan | OpenGL | Direct3D 11 | Direct3D 12 | Test |
| --- | --- | --- | --- | --- | --- |
| Command execution | Deferred until submit | Immediate during recording | Immediate during recording | Deferred until submit | Recorded bookkeeping only |
| Native semaphores | Yes | No | No | No | Bookkeeping only |
| Fence behavior | Native Vulkan fence | OpenGL sync object | Submission state | Native D3D12 fence | Bookkeeping only |
| Presentation | Native swapchain present | Blit to the default framebuffer; caller swaps | DXGI `Present` | DXGI `Present` | No-op |
| Headless surface | Not supported | Supported | Supported | Supported | Supported |

Semaphores on the non-Vulkan backends are accepted for interface
compatibility, but they do not create cross-queue dependencies. Those
backends have a single queue and execute or submit work in a way that
does not need a binary semaphore. Code that must work on every backend
should not rely on semaphore ordering; use the synchronization
primitives the target backend actually implements and check the table
above.

## Test backend

The test backend is the reference implementation for call sequences.
It tracks resource generations, creation dependencies, mapping state,
descriptor writes, command buffer state, and queue parameters, and it
stores shadow bytes for buffers and textures. It does not rasterize,
compile shaders, or model GPU time.

Use it for unit tests of library code, not for visual validation.
`Test.validate` fails on leaks or validation errors, and
`Test.bufferData` / `Test.textureData` expose uploaded data for
assertions.

## Vulkan

The Vulkan backend requires a **Vulkan 1.3** device with dynamic
rendering and a graphics-capable queue. It does not enable validation
layers or surface extensions on its own. The caller provides a
`vkGetInstanceProcAddr` compatible loader and enables the instance
extensions it needs, such as `VK_KHR_win32_surface`,
`VK_KHR_xlib_surface`, or `VK_KHR_wayland_surface`. Creating a surface
whose extension was not enabled returns `error.Unsupported`.

Vulkan is the only backend with **native binary semaphores**, and it
presents through a native Vulkan swapchain. Acquire, submit, and present
map directly to the Vulkan queue operations, and fences map directly to
`VkFence`. The requested swapchain extent, image count, format, and
present mode may be adjusted by the surface; read
`Swapchain.properties` after creation for the actual values.

Vulkan surfaces are built from native window handles. There is no
headless RHI surface on this backend; use the test backend for runs
without a display. Shaders are consumed as SPIR-V without translation.

## OpenGL

The OpenGL backend requires an **OpenGL 4.5 core profile** context that
the caller created and made current. The caller also supplies a GLAD
compatible loader, for example `glfwGetProcAddress`. The backend never
creates, destroys, or switches contexts, and it never calls
`SwapBuffers`. The context must remain current for the lifetime of the
backend, because creating and destroying resources, recording commands,
and presenting all issue GL calls.

The backend does not consume native window handles. A headless surface
supplies explicit width and height; for other surface descriptions it
uses the current viewport dimensions. A window-managed application
therefore typically passes `SurfaceDescription.Native.headless` with the
window's client size and keeps the real window under its own control,
which is what the examples do.

Swapchains are emulated. Each swapchain image is a color texture, and
each view is a texture view over it. Acquire selects images in
round-robin order. Present blits the acquired image into the default
framebuffer and flushes; the caller must swap the window buffers after
`Swapchain.present` returns. A visible window or other default
framebuffer is required for on-screen output.

There are no real semaphores and no memory heaps. Fences wrap OpenGL
sync objects, `Queue.waitIdle` calls `glFinish`, and the device reports
a single memory heap with size `0` because OpenGL exposes no heap size.
Swapchain formats are limited to the formats the backend can map to GL
internal formats, and `image_count` is limited to eight. Multisampled
textures cannot be created with initial data.

Shaders are decompiled from SPIR-V to **GLSL 4.50** and compiled by the
driver. The translator covers the subset emitted by Zig's SPIR-V
backend and by common `glslangValidator` / `glslc` invocations. It does
not cover 16-bit arithmetic, 64-bit integers, descriptor indexing,
physical storage buffers, ray tracing, or mesh shader stages. A module
outside the supported subset returns `error.Unsupported`; it is never
compiled into a shader with different semantics. Vertex, fragment, and
compute stages are the demonstrated path; geometry and tessellation
stages depend on translator coverage and driver support and are not
exercised by the examples.

## Direct3D 11 and 12

Both Direct3D backends are available only on **Windows**. They share
the hand-written bindings in `src/backend/dx3d/windows.zig` and the
SPIR-V to HLSL translator, so enabling them does not fetch an external
package. They link the system `dxgi`, `d3dcompiler_47`, and `d3d11` or
`d3d12` libraries. The caller owns the window and its message loop; the
backends never pump messages.

A surface is either a Win32 `HWND` or a headless width and height. For
an `HWND`, presentation is a DXGI `Present` call with the requested
interval. A headless swapchain uses offscreen textures and presents as a
no-op. The `Win32` handle is the only native surface kind these
backends accept; Xlib and Wayland descriptions return
`error.Unsupported`.

Direct3D 11 records commands into the immediate context, so most work
is applied while the command buffer is being recorded. Command buffer
begin and end are logical states, and submission marks the buffer as
submitted and updates fence bookkeeping. `Queue.waitIdle` flushes the
context. Some drivers expose flip-model swapchains whose non-zero back
buffers cannot be used as render targets; the backend detects this and
falls back to a single-buffer bitblt swapchain whose images alias one
back buffer.

Direct3D 12 records into command lists and executes them on a direct
queue during submission. Fences are real `ID3D12Fence` objects.
Descriptor heaps are fixed size, so descriptor exhaustion returns
`error.OutOfDeviceMemory` rather than growing silently.

Both backends accept SPIR-V, translate it to **HLSL 5.x**, and compile
the result at runtime with `d3dcompiler_47.dll`. The translator covers
vertex, fragment, and compute stages, uniform blocks, push constants,
combined image samplers, and simple control flow. Atomics, storage buffers, 16-bit and
64-bit arithmetic, descriptor indexing, ray tracing, mesh shader
stages, and geometry or tessellation stages are unsupported and return
`error.Unsupported`. The generated vertex shader flips clip-space Y, so
the same SPIR-V produces the same image on Direct3D as it does on
Vulkan, and both backends use a positive viewport height.

## Choosing a backend

Use Vulkan when you need native swapchains, real semaphores, and direct
SPIR-V. Use OpenGL when you already own a GL context and want the
broadest desktop reach with the least platform plumbing. Use Direct3D
11 or 12 when you target Windows and want a native DXGI presentation
path. Use the test backend for call-sequence tests and for CI, where no
GPU is available.

The [usage guide](usage.md) explains the interface rules that apply to
all of them, including the dependency and synchronization rules that do
not change between backends.
