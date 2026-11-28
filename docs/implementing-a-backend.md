# Implementing a backend

A backend turns the abstract `Device` and `Queue` interfaces into calls
on a native graphics API. It is not loaded at runtime and it is not
registered in a global table. A backend is a Zig module compiled into
the application, selected at build time, whose object implements two
virtual tables.

This guide defines the contract behind those tables. It is written for
someone adding a backend or changing the behavior of an existing one.
The backend checklists in [`AGENT.md`](../AGENT.md) remain the canonical
rules for this repository; this page explains the reasoning behind them
and the parts that are easy to get wrong.

## Where a backend fits

The backend owns the native instance or device, the native objects
behind every RHI handle, and the slot table that validates handles. It
does not own the application's window, its event loop, or its OpenGL
context. It also does not own its own lifetime from the RHI's point of
view: the application creates the backend, asks for a `Device`, and
destroys the backend after every resource is gone.

The RHI adds no global state on top of that. A `Device` stores a
pointer to the backend and a pointer to its virtual table. A `Queue` is
a small value that stores the same backend pointer, the virtual table,
and the queue indices. Every operation starts from one of those two
values.

## Build integration

A new backend is a new module under `src/backend/<name>/root.zig`. Its
build and packaging wiring follows the existing backends.

1. Add any external package to `build.zig.zon` as a **lazy**
   dependency. Vulkan and the GLAD package are the existing examples.
2. Add an option to `readConfig` in `build.zig`, store it in the
   `Config` struct, and expose it through `addOptions` so the root
   module can see it.
3. Make the option default to off when vfrhi is a dependency and to the
   appropriate value when vfrhi is the root project. Direct3D defaults
   to on only for Windows targets.
4. Add the module import in the build only when the option is enabled.
   Enforce platform restrictions with a clear build error, and add a
   `comptime` check in the backend for a second line of defense.
5. Export the backend from `src/root.zig` behind a compile-time
   condition. Referencing a disabled backend should produce a
   `@compileError` that names the option to enable.
6. Export a `<name>_enabled` boolean next to the existing feature
   flags.
7. Add a compile test to `src/tests.zig` so the backend is built when
   the option is on.
8. Document the option, the platform requirements, and the backend's
   limitations in the user documentation.

Do not introduce a top-level `@import` of a lazy dependency in
`build.zig`. Use `dependencyLazy` and propagate the lazy dependency
state through the helper functions, as the existing backends do. A user
who disables a backend must not pay for its package fetch or its system
libraries.

## Backend state and handles

The backend needs a **slot table** that maps a `Resource` to a native
object. The existing backends use an array of optional slots, a parallel
array of generations, and a free list of reusable indices. The exact
data structure is not part of the interface, but the invariants are.

A slot stores the generation, the tag, the native payload, and any
backend bookkeeping such as the current texture layout or a mapping
pointer. Reusing an index must advance its generation and must never
produce generation `0`, because zero marks an invalid handle. A new
handle combines the slot index, the current generation, and the tag of
the payload.

Every operation that accepts a handle must validate all of these parts:
index in range, slot occupied, generation equal, and tag equal. A stale
handle, a destroyed handle, or a handle of the wrong type is an
**invalid resource**, not undefined behavior. The error should be
`error.InvalidResource` when the function can return an error, and a
logged warning when it cannot, as with `destroy`.

A queue does not own a slot. It stores the backend pointer plus a
family index and a queue index. The queue virtual table receives those
indices on every call so a backend can verify that the queue belongs to
it and still exists.

The `ret_addr` value that every virtual function receives is diagnostic.
Use it in log messages to identify the caller; never dereference it or
store it as part of the resource state.

## Device virtual table

The device virtual table is deliberately small. Every entry represents
a category of operation, not a resource kind or a command.

| Entry | Responsibility |
| --- | --- |
| `create` | Turn one `Resource.Description` into a native object and a new handle |
| `destroy` | Release a resource, its owned children, and its host memory |
| `create_batch` | Create several descriptions with all-or-nothing cleanup on failure |
| `destroy_batch` | Destroy several handles in the order supplied |
| `map` | Return a writable CPU view of a host-visible buffer range |
| `unmap` | End a mapping and flush the ranges the host wrote |
| `get_queue` | Return a borrowed queue value for a backend queue index |
| `record` | Validate and record one command into one command buffer |
| `device_op` | Run waits, fence resets, and descriptor writes |
| `query` | Fill a fixed-size value, a string, or an array for a capability |

### `create`

The implementation switches on `Resource.Description` and handles every
tag it claims to support. For each tag it validates the description,
resolves every referenced handle through the slot table, and checks that
the referenced tag is the expected one. A swapchain that references a
stale surface, a pipeline that references a compute shader in its vertex
slot, or a descriptor set built from a destroyed layout must fail before
any native object is created.

The caller's description slices are only valid for the duration of the
call. Copy any binding array, push constant range, shader entry point,
or initial data that the backend needs to keep. In particular, initial
data must be uploaded during creation or copied into backend storage;
the caller may free the source bytes as soon as `create` returns.

A created resource must be complete. If it has dependent child objects,
as a swapchain has images and views, create those children as slots of
their own and store their handles in the parent slot so `destroy` can
release them. If any step fails, release every native object and slot
created so far and return an error that matches the shared `Error` set.

Textures deserve one extra convention: a texture created without
initial data starts in the `undefined` layout, while one created with
initial data is left in the shader-readable layout for its aspect after
the upload barrier. The test backend enforces this so command recording
can check barrier layouts consistently.

### `destroy`

Destruction cannot return an error, so an invalid or stale handle is
logged and ignored. For a valid handle, release the native object, any
owned children, any mapped memory, and any host allocations recorded in
the slot, then release the slot itself.

Destroy resources in **reverse dependency order**. The test backend
records creation dependencies and rejects destroying a resource while a
dependent handle is alive. A native backend should make the same
violation visible where it can; at minimum it must not free memory that
a live native object still references. Destroying the same handle twice
must not free the native object twice.

### `create_batch` and `destroy_batch`

`create_batch` receives parallel slices. A length mismatch is
`error.InvalidDescription`. Create the descriptions in order. If one
fails, release every resource created by this call in reverse order and
leave the output slice undefined, so the caller does not observe partial
success. A simple loop over `create` is acceptable; internal release is
preferred over a public `destroy` call so a rollback cannot be blocked
by extra validation.

`destroy_batch` destroys the supplied handles in the order given. It
does not sort them by dependency. The caller is responsible for passing
reverse dependency order, just as it is for individual destroys.

### `map` and `unmap`

Only buffers can be mapped, and only when the requested memory includes
host visibility. Validate that the handle is a buffer, that the range is
inside the buffer, and that the buffer is not already mapped. Return a
writable slice that remains valid until `unmap`. If the native API
cannot expose a stable CPU pointer for that range, return
`error.Unsupported` rather than a temporary copy that the caller might
assume is persistent.

`unmap` receives the ranges the host wrote. An empty list means the
entire mapped range was written. Validate that the buffer is mapped and
that every range lies inside the mapped range, then flush or invalidate
as the native API requires. Clear the mapping state even when a range is
invalid; a failed unmap must not leave the buffer permanently
unmappable.

### `get_queue`

Return a `Queue` whose `vptr` is the backend, whose `vtable` is the
backend's queue table, and whose indices identify a real queue. An
unknown index is `error.Unsupported`. The returned queue borrows the
backend; there is nothing to destroy.

Current backends expose index `0` only and use the family index chosen
at initialization. The test backend can expose more queues, which is
useful for tests that check index validation.

### `record`

`record` is the only command path. It receives one command buffer
handle and one member of the `Command` union, so a backend never needs a
virtual function per draw, copy, or barrier.

First validate the command buffer and its logical state. `begin` moves
the buffer to recording and discards previous commands. Most commands
require recording. `end` requires recording and no active render pass.
`submit` accepts only an ended buffer. A buffer that has been submitted
can be recorded again with `begin` once the GPU is done with it.

Then validate the command-specific resources and flags. A draw needs an
active render pass, a bound graphics pipeline, a viewport, and enough
vertex buffers for the pipeline's declared bindings. An indexed draw
also needs an index buffer with index usage. A dispatch needs a bound
compute pipeline. A copy needs transfer usage, valid bounds, and valid
mip and layer ranges. A barrier on a texture must name the current
layout as `layout_before`. A descriptor set bind must reference a
pipeline layout and sets of the right tag. Push constant data must fit
the declared ranges.

The test backend's recorder is the most complete statement of these
checks. Reuse its validation order as a reference when implementing a
new command path, even if the native backend relies on a driver for some
of the deeper checks.

Some APIs execute immediately during recording, while others defer
until submission. The backend must preserve the same **logical state
machine** either way. OpenGL and Direct3D 11 issue work while recording;
Vulkan and Direct3D 12 record native commands and execute them on
submit. The interface does not promise when work reaches the GPU, only
that it is ordered by submission.

A rejected command should not leave a half-updated state that makes the
next valid sequence fail unexpectedly. Validate before mutating native
state where the platform allows it; if the platform cannot validate
without recording, document the limitation and make the error path
consistent within the backend.

### `device_op`

`device_op` covers operations that are neither resource creation nor
command recording:

- `wait_idle` performs the strongest device-wide idle wait the native
  API provides.
- `wait_fence` validates that the handle is a fence and waits up to the
  timeout, returning `error.Timeout` if it expires.
- `reset_fence` only resets a fence that is not in use and returns an
  invalid-resource error otherwise.
- `write_descriptor_set` validates the set, its layout, each write's
  binding and array index, the descriptor kind, and every referenced
  resource before applying the writes.

The function also receives an optional `OutputMode`. Operations that
produce no bytes ignore it; operations that do produce bytes must honor
the same slice-versus-allocator rule as `query`.

### `query`

`query` answers a `Device.Feature` with a `QueryResult`. The support
field is as important as the payload. Use `support` when the value is
available, `unsupport` when the backend can prove the feature is not
available, and `unknown` when the backend has no way to answer. Do not
return a fabricated value with `support`.

Fixed-size features are written as raw bytes into the provided slice.
If the slice is too small, return `error.BufferTooSmall`. String queries,
such as the device and driver names, use the allocator mode when the
caller does not provide storage; ownership of allocated bytes passes to
the caller. Array queries such as `swapchain_images` require a slice
that can hold every element and are not satisfiable through the
allocator mode because `Resource` has alignment requirements.

Validate `feature_index` for array features such as memory heaps and
queue families, and validate that any handle is present and of the
expected tag. Stale handles are `error.InvalidResource`. Resource
properties such as `BufferProperties` and `TextureProperties` must match
the values stored at creation; the typed wrappers decode them from the
exact byte layout.

## Queue virtual table

The queue table has four entries. Every call receives the family and
queue indices, which the backend should revalidate even though
`get_queue` already returned them.

| Entry | Responsibility |
| --- | --- |
| `acquire` | Acquire the next image from a swapchain and return its index |
| `submit` | Send ended command buffers to the queue with synchronization |
| `present` | Present an acquired image, optionally waiting on semaphores |
| `wait_idle` | Perform the strongest idle wait the native API provides |

### `acquire`

Validate the swapchain handle and the optional semaphore and fence
handles. Ask the native API for the next image with the requested
timeout and return its index, plus the suboptimal flag when the native
API reports one. If the backend supports acquire synchronization,
signal the supplied semaphore or fence on success and document any
backend where the objects are bookkeeping only. If the backend needs at
least one synchronization object and none was provided, return
`error.InvalidDescription`.

Do not call presentation or submission from `acquire`. The application
decides how the acquire semaphore is consumed.

### `submit`

Validate every command buffer in the submission and require the ended
state. Validate the fence and any synchronization objects the backend
actually uses. Then execute the submission with the native queue,
marking the command buffers as submitted and signaling the fence when
the backend provides one.

An empty submission is legal and useful for signaling a fence or
semaphores; do not reject it just because the command buffer list is
empty. Validate before submitting work where the native API allows it,
and return a mapped error if the submission fails.

### `present`

Validate the swapchain, the image index, and any wait semaphores the
backend uses. Present the image through the native swapchain or the
backend's emulation. `error.SurfaceOutOfDate` and `error.SurfaceLost` must be
preserved so the application can recreate the swapchain.

OpenGL is the exception in presentation: it blits the image into the
default framebuffer and flushes, but it never calls `SwapBuffers`. The
application owns the window and performs the buffer swap. Direct3D
headless swapchains accept presentation as a no-op.

### `wait_idle`

Wait for the strongest idle condition the native API can provide. This
is a shutdown and debugging tool, not a per-frame synchronization
primitive. It must not destroy resources or change the logical state of
command buffers beyond what the native API requires.

## Errors, validation, and logging

Backends translate native failures into the shared `Error` set. The
important distinctions are:

- `OutOfHostMemory` for CPU allocations and host mapping failures.
- `OutOfDeviceMemory` for GPU allocations and descriptor exhaustion.
- `DeviceLost` for a lost native device.
- `SurfaceOutOfDate` and `SurfaceLost` for swapchain recreation.
- `Timeout` for fence and acquire timeouts.
- `Unsupported` for a valid request the backend cannot implement.
- `InvalidResource` for stale or wrong-type handles.
- `InvalidDescription` for internally inconsistent parameters.
- `BufferTooSmall` for undersized query output.

Do not leak native error codes into the public interface. Do not turn an
unsupported feature into a silently different behavior. If a native API
cannot express a command or a format, return `error.Unsupported` and
document the limitation.

Logging follows the repository scopes: `.vulkan`, `.opengl`, `.dx3d`,
`.dx3d11`, `.dx3d12`, or `.test_rhi`, with `.vfrhi` reserved for the
interface layer. Use `debug` for routine create, destroy, and submit
traffic, `info` for a backend initialization summary, `warn` for invalid
calls and rejected handles, and `err` for leaks or unrecoverable state.
Include the `ret_addr` in warnings that report caller mistakes.

## Shader and capability rules

Every backend accepts **SPIR-V** as its shader input. If the native API
does not consume SPIR-V, the backend translates the module itself and
returns `error.Unsupported` for anything outside the translator's
subset. It must not silently compile a shader whose semantics differ
from the SPIR-V source. The OpenGL and Direct3D translators both follow
this rule and have GPU-free tests in `src/tests.zig`.

Capability queries must tell the truth. `supportsFormat` should reflect
what the backend can actually create for the requested usage, limits
should come from the native device, and a query the backend cannot
answer should use `unknown`, not a guess. Applications rely on those
answers to choose formats and resource sizes before creating anything.

## Extending the resource and command model

New functionality normally extends the tagged unions, not the virtual
tables. A new resource kind requires a `Resource.Tag` member, a
`Resource.Description` member, description and property structs, a typed
wrapper with `create`, `destroy`, and `WithAddr` variants, a test
backend implementation, implementations in every GPU backend, query
support where relevant, and tests for both the success path and at
least one failure path. If destroying the new resource while a
dependent resource is alive is invalid, the test backend must record
that edge and the test must assert that the destruction is rejected.

A new command requires a `Command` union member with a flat parameter
struct, a `CommandBuffer` method plus its `WithAddr` variant, validation
and state tracking in the test backend, recording support in every GPU
backend, and tests. Commands with six or more semantic parameters should
carry a struct rather than a long argument list.

A new query or device operation extends `Device.Feature` or
`Device.DeviceOp`, adds the high-level getter or wrapper, implements the
fixed byte layout in every backend, and adds tests. The same rule as
elsewhere applies: one virtual function per operation category, never
one per resource or command.

## Checklist for a new backend

1. Add the build option, lazy dependency, conditional import, and
   feature flag.
2. Implement the backend object, slot table, generation validation, and
   `asDevice`.
3. Implement every `Resource.Tag` in `create`, `destroy`, and the
   relevant query paths.
4. Implement every `Command` member in `record`, including the command
   buffer state machine and per-command validation.
5. Implement the four queue operations and their handle checks.
6. Implement mapping and unmapping for host-visible buffers.
7. Implement capabilities, limits, and format support truthfully.
8. Provide a SPIR-V path, translating inside the backend if necessary,
   and return `error.Unsupported` outside the supported subset.
9. Add a compile test and use the test backend to model call sequences.
10. Run at least the triangle example on real hardware for the new
    backend, plus the texture, quad, or batch example when the change
    touches those paths.
11. Update the backend documentation and the build option table.

The existing backends are useful references at different levels of
complexity. The test backend is the smallest complete implementation and
the best source for validation rules. The Vulkan backend is the most
direct mapping of the abstract model. The OpenGL backend shows how to
emulate swapchains and translate shaders. The Direct3D backends show
how to share bindings, translate to HLSL, and keep two native APIs
producing the same image.
