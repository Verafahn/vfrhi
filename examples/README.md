# vfrhi examples

Each directory is an independent Zig project. The `build.zig.zon` in every
example pulls in vfrhi with a path dependency and fetches GLFW for window
creation:

```zig
.dependencies = .{
    .vfrhi = .{ .path = "../.." },
    .glfw_zig = .{ .url = "...", .hash = "..." },
},
```

The Vulkan, OpenGL, and (on Windows) Direct3D 11 and 12 backends are
enabled at build time, and the example picks one at run time with
`--backend`.

From the repository root, each example has a `run-<name>` step:

```sh
zig build run-triangle
```

The step changes into the example directory and runs `zig build run`
there. Arguments after the outer `--` are forwarded to that build, so a
second `--` separates build options from program arguments:

```sh
zig build run-triangle -- -- --backend vulkan --frames 2
zig build run-triangle -- -Doptimize=ReleaseFast -- --backend opengl
```

Running from the example directory is equivalent:

```sh
cd triangle
zig build run -- --backend vulkan
zig build run -- --backend opengl
zig build run -- --backend dx3d11
zig build run -- --backend dx3d12
```

The Direct3D backends are only compiled into the examples when the
build runs on Windows.

`--frames <count>` stops after the given number of frames (default 240).
Pass `--frames 0` to keep the window open until it is closed, and
`--help` to print the available options.

## Examples

| Directory | Feature |
| --- | --- |
| `clear` | Window plus an animated background clear |
| `triangle` | Vertex buffer and a colored triangle |
| `quad` | Element buffer and `drawIndexed` |
| `batch` | 8192 triangles in one draw call |
| `texture` | Checkerboard texture, sampler, and descriptor set |

## Shaders

Shaders are Zig source files under `<example>/shaders/`. The example
`build.zig` compiles each one to an object with the `spirv32-vulkan`
target and `use_llvm = false`, then embeds the resulting binary as an
anonymous module import. The shaders use `@extern` globals in the
`input`, `output`, `uniform`, and `constant` address spaces:

```zig
const in_position = @extern(*addrspace(.input) @Vector(2, f32), .{
    .name = "vertex_position",
    .decoration = .{ .location = 0 },
});
```

Descriptor bindings are declared with
`.decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } }`. The
built-in position output is written through `std.spirv.position_out`.

## Shared code

`framework/` contains the shared window, backend selection, swapchain,
and frame loop code. It is not a package; each example's `build.zig`
compiles `../framework/root.zig` as a module that imports the example's
own `vfrhi` module, so both see the exact same RHI types.

The framework declares the small subset of GLFW it needs directly and
links the C library from the `glfw_zig` package. This keeps the examples
free of a translate-c build step.
