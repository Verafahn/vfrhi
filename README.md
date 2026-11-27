# vfrhi

A backend independent **Render Hardware Interface** for Zig.

vfrhi models explicit graphics APIs such as Vulkan with a deliberately
small set of virtual tables. Resource kinds, commands, device
operations, and queries are encoded as tagged unions, so adding a
resource does not add a virtual function.

## Design

- Two interfaces: `Device` and `Queue`.
- One `create` / `destroy` pair for every resource, plus batch variants.
- One `map` / `unmap` pair for host-visible memory.
- One `record` function for command buffers; commands are a union.
- One `device_op` union for device level operations.
- One `query` function for capabilities and properties.
- Resources are generation protected handles; stale handles are
  rejected by backends.
- Backends are externally owned: the RHI never creates or destroys a
  backend instance.
- The RHI does not assume a window system. Surfaces are described with
  native handles supplied by the application.

## Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public entry point |
| `src/Resource.zig` | Handles, tags, descriptions, formats |
| `src/Device.zig` | Device vtable and device level helpers |
| `src/Queue.zig` | Queue vtable |
| `src/Command.zig` | Command union and command payloads |
| `src/resources/` | Typed resource wrappers |
| `src/backend/test/` | Headless validation backend |
| `src/backend/vulkan/` | Vulkan backend |
| `examples/` | GLFW smoke tests |

## Using vfrhi as a dependency

By default only the RHI and the test backend are built. The Vulkan
backend and its toolchain are fetched lazily.

```zig
const vfrhi = b.dependency("vfrhi", .{
    .target = target,
    .optimize = optimize,
});
```

Enable Vulkan explicitly:

```zig
const vfrhi = b.dependency("vfrhi", .{
    .target = target,
    .optimize = optimize,
    .vulkan = true,
});

exe.root_module.addImport("vfrhi", vfrhi.module("rhi"));
```

When vfrhi is the root project, `zig build` enables Vulkan, fetches all
dependencies, and builds both examples. Use `-Dvulkan=false` to build
only the RHI and the test backend.

## Minimal setup

```zig
const rhi = @import("vfrhi");

const backend = try rhi.Vulkan.init(
    gpa,
    loader_fn,
    .{
        .application_name = "my app",
        .api_version = .api_1_3,
        .enabled_extension = extensions,
        .extension_count = extension_count,
    },
);
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);

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
});
defer swapchain.destroy();
```

Destroy every RHI resource before `backend.deinit()`. The Vulkan
backend requires Vulkan 1.3 with dynamic rendering.

## Buffers and mapping

```zig
const buffer = try rhi.Buffer.create(device, .{
    .size = data.len,
    .memory = .{ .host_visible = true },
    .usage = .{ .vertex = true },
    .initial_data = data,
});
defer buffer.destroy();

try buffer.write(0, new_data);

var readback: [16]u8 = undefined;
try buffer.read(0, &readback);
```

## Commands and submission

```zig
const command_buffer = try rhi.CommandBuffer.create(device, .{});
defer command_buffer.destroy();

try command_buffer.begin();
try command_buffer.beginRendering(.{
    .area = .{ .width = 800, .height = 600 },
    .color_attachments = &.{.{
        .view = swapchain_view,
        .load = .clear,
        .clear = .{ .r = 0.05, .g = 0.08, .b = 0.16 },
    }},
});
try command_buffer.endRendering();
try command_buffer.end();

try command_buffer.submit(queue, .{});
try queue.waitIdle();
```

## Test backend

`rhi.Test` validates call sequences without a GPU:

```zig
const backend = try rhi.Test.init(std.testing.allocator);
defer backend.deinit();

const device = backend.asDevice();
// ... create and use resources ...
try backend.validate();
```

It checks handle generations, resource type mismatches, destruction
order, leaks, map/unmap state, command buffer state, submission
parameters, and initial buffer contents.

## Building

```sh
zig build                # RHI, test backend, examples
zig build test           # headless integration tests
zig build run-rhi        # RHI clear example, needs a GPU
zig build run            # raw Vulkan triangle example
```

Run the project tests with:

```sh
zig build test --summary all
```

## Documentation

Public declarations use the `zig-api-docs` comment template. See
`AGENT.md` for architecture rules, naming conventions, and the
checklist for adding resources or commands.
