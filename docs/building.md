# Building and testing

vfrhi is a normal Zig package. It can be built as the root project for
development, or fetched as a dependency by an application. The two modes
have deliberately different defaults so that importing vfrhi never
pulls in a graphics toolchain the application does not use.

## Toolchain

The minimum Zig version is **0.17.1**. When every rendering backend is
disabled, the build has no dependencies beyond the standard library and
the test backend.

## Building as the root project

From the repository root:

```sh
zig build test --summary all
```

The root project enables **Vulkan, OpenGL, and, on Windows, both
Direct3D backends** by default. The test suite builds those modules and
runs the headless tests; it does not initialize a GPU device. This makes
the suite usable in CI and on machines without a display.

The build options are ordinary Zig build options.

| Option | Root default | Dependency default | Effect |
| --- | --- | --- | --- |
| `-Dvulkan` | On | Off | Fetches `vulkan-zig` and Vulkan-Headers and builds the Vulkan backend |
| `-Dopengl` | On | Off | Fetches the GLAD package and builds the OpenGL backend |
| `-Ddx3d11` | On for Windows targets | Off | Builds the Direct3D 11 backend and links the system libraries; rejected on non-Windows targets |
| `-Ddx3d12` | On for Windows targets | Off | Builds the Direct3D 12 backend and links the system libraries; rejected on non-Windows targets |
| `-Ddisable-render` | `false` | `false` | Turns off every rendering backend, leaving the RHI and the test backend |

Individual backends can be turned off without disabling the rest:

```sh
zig build test -Dvulkan=false
zig build test -Dopengl=false
zig build test -Ddx3d11=false -Ddx3d12=false
```

The last form is useful when you do not want to fetch or build those
backends. `-Ddisable-render` is the smallest configuration and is what
the project's CI uses on every operating system.

## Building as a dependency

Fetch the package:

```sh
zig fetch --save git+https://github.com/Verafahn/vfrhi.git
```

Then declare the options you need in `build.zig`:

```zig
const vfrhi = b.dependency("vfrhi", .{
    .target = target,
    .optimize = optimize,
    .vulkan = true, // omit unless this application uses Vulkan
    .opengl = false,
    .dx3d11 = false,
    .dx3d12 = false,
});

exe.root_module.addImport("vfrhi", vfrhi.module("rhi"));
```

All rendering backends are **off by default** for a dependency. A
reference to `rhi.Vulkan` without `.vulkan = true` is a compile error
with a message that names the missing option. The same is true for
`rhi.OpenGL`, `rhi.Dx3d11`, and `rhi.Dx3d12`. Applications that
conditionally reference a backend can check the exported flags
`rhi.vulkan_enabled`, `rhi.opengl_enabled`, `rhi.dx3d11_enabled`, and
`rhi.dx3d12_enabled` instead of duplicating the build configuration.

The Direct3D options are only valid when the target is Windows. Enabling
either one for another target is a build error, not a runtime failure.

## Dependencies

The Vulkan backend depends on `vulkan-zig` and the Vulkan-Headers
package. The OpenGL backend depends on the GLAD package exposed as
`glad`. Both are **lazy dependencies**: they are fetched only when the
matching option is enabled. The Direct3D backends depend on the standard
library and the hand-written bindings in the repository; they link
system libraries but fetch no package.

The examples additionally depend on GLFW for window creation, through
the `glfw_zig` package. vfrhi itself does not depend on GLFW, and `src/`
never assumes a window system exists.

## Tests

The main test command is:

```sh
zig build test --summary all
```

The suite has three kinds of coverage. The test backend validates
resource lifetimes, generations, mapping, command state, descriptor
writes, and queue parameters. The translator tests feed SPIR-V to the
GLSL and HLSL translators and inspect the generated source without
needing a GPU. The backend compile tests make sure that each enabled
backend still builds and exposes its public declarations.

Run the smallest configuration when a change should not depend on any
graphics API:

```sh
zig build test -Ddisable-render --summary all
```

When a change touches a specific backend, run the full suite with that
backend enabled, then run an example on real hardware. The next section
explains the example commands. GPU behavior is not covered by the
automated suite, so the hardware run is the validation that catches
driver-level problems.

The repository CI builds and tests on Ubuntu, Windows, and macOS in
Debug, ReleaseFast, and ReleaseSafe, always with `-Ddisable-render`.
That checks the interface, the test backend, and the translators, but
not Vulkan, OpenGL, or Direct3D execution.

## Examples

Every directory under `examples/` is an independent Zig project with
its own `build.zig` and `build.zig.zon`. The manifest imports vfrhi as a
path dependency, so the examples always compile against the current
source tree. Examples are not part of the distributed package, and
their run steps exist only when vfrhi is the root project.

| Example | Run step | What it demonstrates |
| --- | --- | --- |
| `examples/clear` | `zig build run-clear` | Window creation and clearing a render pass |
| `examples/triangle` | `zig build run-triangle` | Vertex buffer, shaders, and a graphics pipeline |
| `examples/quad` | `zig build run-quad` | Element buffer and indexed drawing |
| `examples/batch` | `zig build run-batch` | Thousands of triangles in one draw call |
| `examples/texture` | `zig build run-texture` | Texture upload, sampler, and descriptor set |

Each run step changes into the example directory and invokes
`zig build run` there. Arguments after the outer `--` are forwarded to
that build, so build options go before a second `--` and program
arguments go after it:

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

The `--backend` value is `vulkan`, `opengl`, `dx3d11`, or `dx3d12`.
Direct3D choices are only available on Windows. `--frames <count>`
stops after the given number of frames; `--frames 0` keeps the window
open until it is closed. The default is 240 frames.

Shaders live in each example's `shaders/` directory as Zig source files.
The example build compiles them to SPIR-V objects and embeds them in the
executable. No external shader compiler is needed. The examples use
GLFW for the window and input, but the RHI module itself never touches
the window system.

For guidance on which example to run after a particular change, see the
[contributing guide](contributing.md).

## Packaging

The package manifest includes only `build.zig`, `build.zig.zon`, and the
`src/` tree. Documentation and examples stay in the repository and are
not downloaded by applications that depend on vfrhi. This keeps the
dependency small and avoids shipping build steps that only make sense
in the root project.
