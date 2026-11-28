# vfrhi

A render hardware interface for Zig. One rendering API for **Vulkan**,
**OpenGL**, **Direct3D 11/12**, and a headless test backend that needs no
GPU.

[![CI](https://github.com/Verafahn/vfrhi/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Verafahn/vfrhi/actions/workflows/ci.yml)
![Zig](https://img.shields.io/badge/zig-0.17.1-f7a41d)

vfrhi gives rendering code a backend-neutral vocabulary for resources,
commands, and synchronization. Backends own the native objects; your
application owns the backend instance, the window, and the event loop.
The same buffers, textures, pipelines, and command buffers run unchanged
on every compiled backend, including in unit tests.

## Highlights

- **Small, data-driven interface.** Only `Device` and `Queue` are
  virtual. Resource kinds and commands are tagged unions, so adding a
  resource or command does not add a virtual function.
- **Five implementations.** Vulkan 1.3, OpenGL 4.5 core, Direct3D 11,
  Direct3D 12, and a test backend that validates lifetimes and command
  state without a GPU.
- **SPIR-V only.** Vulkan consumes it directly; OpenGL and Direct3D
  translate it internally and return `error.Unsupported` instead of
  compiling semantically different shaders.
- **Safe handles.** Generational handles reject stale, destroyed, and
  wrong-type resources.
- **No window framework required.** Surfaces are described by native
  handles or headless dimensions. `src/` never assumes a window system.
- **Lazy backend dependencies.** Importing vfrhi fetches no graphics
  toolchain unless the matching backend is enabled.

## Requirements

| Backend | Requirement |
| --- | --- |
| All | Zig **0.17.1** |
| Vulkan | Vulkan **1.3** device with dynamic rendering; caller supplies a loader and enables the surface extensions |
| OpenGL | OpenGL **4.5 core** context, current when the backend is used; caller supplies a GLAD-compatible loader |
| Direct3D 11/12 | **Windows 10** or later; Direct3D 12 needs feature level 11.0; `d3dcompiler_47.dll` at runtime |
| Test | Nothing beyond Zig |

## Installation

```sh
zig fetch --save git+https://github.com/Verafahn/vfrhi.git
```

```zig
const vfrhi = b.dependency("vfrhi", .{
    .target = target,
    .optimize = optimize,
    .vulkan = true, // enable only the backends this application uses
});

exe.root_module.addImport("vfrhi", vfrhi.module("rhi"));
```

All rendering backends are **off by default** when vfrhi is a
dependency. Referencing a disabled backend is a compile error that names
the option to enable. Root builds default to Vulkan, OpenGL, and, on
Windows, both Direct3D backends. See [Building and
testing](docs/building.md) for every option.

## Quick start

```zig
const rhi = @import("vfrhi");

// A function with the same signature as vkGetInstanceProcAddr.
const backend = try rhi.Vulkan.init(gpa, loader_fn, .{
    .application_name = "my app",
    .api_version = .api_1_3,
    // Enable VK_KHR_win32_surface, VK_KHR_xlib_surface, or
    // VK_KHR_wayland_surface when the application creates surfaces.
    .enabled_extension = instance_extensions,
    .extension_count = instance_extension_count,
});
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);
```

Create resources through `device`, record them into a
`CommandBuffer`, and submit through `queue`. Destroy every RHI resource
before `backend.deinit()`. The [usage guide](docs/usage.md) explains
lifetimes, implicit dependencies, command state, and synchronization.

## Documentation

| Guide | Contents |
| --- | --- |
| [Overview](docs/overview.md) | Project structure, design principles, execution model, and non-goals |
| [Using the interface](docs/usage.md) | Backend and resource lifetimes, implicit dependencies, command recording, synchronization, data transfer, queries, and GPU-free tests |
| [Backends](docs/backends.md) | Platform requirements, native behavior, shader translation, and limitations of each backend |
| [Building and testing](docs/building.md) | Root and dependency builds, options, examples, and CI |
| [Implementing a backend](docs/implementing-a-backend.md) | Vtable contracts, handle validation, error mapping, and extending resources or commands |
| [Contributing](docs/contributing.md) | Bug reports, fixes, new backends, tests, style, and review expectations |

## Examples

Each directory under `examples/` is an independent Zig project with its
own `build.zig` and `build.zig.zon`. It can be run from the repository
root with a `run-<name>` step.

| Example | Run | Demonstrates |
| --- | --- | --- |
| `clear` | `zig build run-clear` | Window and render pass clear |
| `triangle` | `zig build run-triangle` | Vertex buffer, shaders, and a graphics pipeline |
| `quad` | `zig build run-quad` | Element buffer and indexed drawing |
| `batch` | `zig build run-batch` | Thousands of triangles in one draw call |
| `texture` | `zig build run-texture` | Texture upload, sampler, and descriptor set |

Pass arguments after the run step to choose a backend and stop after a
finite number of frames, for example
`zig build run-triangle -- -- --backend vulkan --frames 2`. The Direct3D
backends are available only on Windows. Shaders are Zig source files compiled to
SPIR-V by each example's build, so no external shader compiler is
required. The examples use GLFW for windowing; vfrhi does not.

## Testing

```sh
zig build test --summary all
```

The suite runs without a GPU: it exercises the test backend, resource
lifetimes, command validation, and the GLSL and HLSL translators. GPU
behavior is validated by running an example on hardware.

## Status

vfrhi is **pre-1.0** and the API may change between releases. The
command set currently omits indirect draws, timestamp queries, ray
tracing, and mesh shaders. The [backends guide](docs/backends.md) records
further limitations, including unsupported shader features and
backend-specific synchronization behavior.

## Contributing

Bug reports, fixes, tests, examples, and new backend implementations are
welcome. Read [Contributing](docs/contributing.md) before opening a
pull request, and [`AGENT.md`](AGENT.md) before changing code.
