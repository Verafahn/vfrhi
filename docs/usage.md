# Using the interface

This guide covers the conventions shared by every backend. It focuses on
the relationships that the Zig type system cannot express: ownership,
lifetime, command order, and synchronization. Exact parameter and error
lists are documented on the declarations themselves.

## Backend, device, and queue lifetime

A rendering session starts with a backend instance. The way that
instance is created depends on the backend; Vulkan needs a loader and a
device that supports Vulkan 1.3, OpenGL needs a current 4.5 context, and
Direct3D needs Windows and the system libraries. Once the backend
exists, the RHI view of it is always the same:

```zig
const backend = try rhi.Vulkan.init(gpa, loader_fn, .{});
defer backend.deinit();

const device = backend.asDevice();
const queue = try device.getQueue(0);
```

The backend owns the native instance, device, and all native objects
created through it. `Device` and `Queue` are **borrowed views**; there
is no `device.destroy` and no `queue.destroy`. Every RHI resource must
be destroyed before `backend.deinit()` runs. The backend is created
before the first RHI call and outlives the last one.

Current GPU backends expose a single queue at index `0` with graphics
and transfer capabilities. It is also the presentation queue when the
backend supports surfaces. `Test.initWithOptions` can expose a different
queue layout when a test needs one. Asking for an index that does not
exist returns `error.Unsupported`.

A resource handle is meaningful only to the **device that created it**.
The handle stores an index, a generation, and a tag, but not a device
identity. Passing a handle to another backend or another device is a
caller error even if the receiving backend happens to find a slot with
the same index and generation. The same rule applies to queues: use the
queue borrowed from the device that owns the work.

## Resources and handles

Resources are created from descriptions and destroyed explicitly.
Typed wrappers keep the owning device, the raw handle, and a few cached
fields that are useful to callers:

```zig
const buffer = try rhi.Buffer.create(device, .{
    .size = 4096,
    .usage = .{ .vertex = true },
    .memory = .{ .host_visible = true },
});
defer buffer.destroy();
```

The `resource` field is the backend handle used by commands, descriptor
writes, and query calls. The other fields, such as `Buffer.size` or
`Texture.properties`, are copies taken at creation and are not a live
view of backend state.

Handles are **generational**. Destroying a resource invalidates every
copy of its handle, including copies stored in descriptors, command
buffers, and application-side arrays. Backends reject stale handles,
wrong-type handles, and destroyed handles. `Resource.isValid` only
checks the handle encoding; it cannot prove that the resource is still
alive. Only the backend can decide that.

Batch helpers are available when several resources belong to one
operation. `Device.createBatch` creates descriptions in order and, on
failure, destroys everything it created and leaves the output slice
undefined. `Device.destroyBatch` destroys handles in the order supplied;
it does not reorder them. Pass resources in **reverse dependency
order**, exactly as you would for individual `destroy` calls.

Raw handles are useful when a system stores heterogeneous resources,
for example an array of attachments. Most application code should use
the typed wrappers, because they add convenience methods such as
`Buffer.write`, `Texture.createView`, `Swapchain.images`, and
`CommandBuffer.draw`.

## Implicit dependencies and ownership

Resource descriptions refer to other resources by handle. That keeps
descriptions backend independent, but it also means the dependency
edges are not encoded in the types. They are still part of the
contract. The following relationships are the ones that matter most.

| Relationship | Established by | What it means |
| --- | --- | --- |
| Swapchain borrows a surface | `SwapchainDescription.surface` | Destroy the swapchain before the surface. The surface must outlive every swapchain created from it. |
| Swapchain owns its images and views | Swapchain creation, exposed by `images` and `views` | Treat the returned handles as borrowed. Destroy the swapchain, not the individual images or views. The handles become invalid when the swapchain is destroyed. |
| Texture view borrows a texture | `TextureViewDescription.texture` or `Texture.createView` | Destroy the view before the texture. For swapchain views, the swapchain owns both. |
| Descriptor set borrows its layout | `DescriptorSetDescription.layout` | Destroy the set before its descriptor set layout. |
| Pipeline layout borrows descriptor set layouts | `PipelineLayoutDescription.descriptor_sets` | Destroy the pipeline layout before the layouts it references. |
| Pipeline borrows a pipeline layout and shader modules | `GraphicsPipelineDescription` and `ComputePipelineDescription` | Destroy the pipeline before its layout and before either shader module. |
| Descriptor writes borrow buffers, views, and samplers | `DescriptorSet.update` | Keep the written resources alive while the set can be used, and at least until every submitted command that binds it has completed. |
| Recorded commands borrow every resource they name | `CommandBuffer` recording | Keep attachments, pipelines, buffers, sets, and layouts alive until the submission completes. Do not destroy a command buffer while a queue still uses it. |
| Submission borrows its command buffers and synchronization | `Queue.Submission` | Command buffers, wait and signal semaphores, and the fence must stay alive until the submission finishes. |
| Acquire and present borrow the swapchain and synchronization | `Queue.Acquire` and `Queue.Present` | Semaphores and fences must be live, and the image index must belong to the same swapchain that produced it. |

The **swapchain** is the clearest ownership boundary. Its images are
not independent textures that the application allocated; the swapchain
created them and will invalidate them when it is recreated or
destroyed. Fetch `images` and `views` again after recreating the
swapchain, and never destroy the returned handles individually.

Shader modules have a stronger lifetime rule than some native APIs
require. Vulkan, for example, allows a shader module to be destroyed
shortly after pipeline creation. vfrhi requires the **pipeline to be
destroyed first** so every backend can follow the same rule without
special cases. The same applies to descriptor set layouts and pipeline
layouts: destroy the objects that reference them first.

Descriptor sets are allocated from a descriptor set layout, but the
resources written into them are borrowed, not owned. The set may hold
native image views, sampler objects, or buffer handles. Keep those
resources alive until the set is destroyed and until the GPU has
finished any command that binds the set. When in doubt, treat the
descriptor set as an owner for lifetime purposes even though the RHI
does not destroy the referenced resources for you.

A descriptor write also has to match the layout: the binding must exist,
the kind must match the declared `DescriptorKind`, `array_index` must be
inside the declared `count`, and buffer ranges must fit the buffer. A
set bound at draw time must have been allocated from a layout that is
compatible with the pipeline layout used by the bound pipeline, in the
same set index. The test backend checks handle types and ranges; full
layout compatibility is the caller's responsibility and may only be
diagnosed by the native validation layer.

The same pattern applies to push constants. The ranges must be declared
in the pipeline layout, and the `layout` passed to
`CommandBuffer.pushConstants` must be the layout used by the bound
pipeline. The command's stage mask and byte range must fall inside a
declared range.

## Recording commands

A command buffer moves through four logical states: initial,
recording, ended, and submitted. `begin` discards any previous commands
and starts a new recording. Commands are recorded only while the buffer
is in the recording state. `end` closes the recording, and `submit`
sends an ended buffer to a queue. A submitted buffer can be recorded
again with `begin` after the GPU has finished using it.

The command set maps closely to the underlying APIs. A graphics draw
needs an active dynamic rendering pass, a bound graphics pipeline, a
viewport, and vertex buffers for every binding the pipeline declares.
An indexed draw additionally needs an index buffer. A compute dispatch
needs a bound compute pipeline and is recorded outside a render pass.
Copies require the relevant transfer usage flags, valid ranges, and, for
textures, valid mip and array-layer indices.

Dynamic rendering is explicit. `beginRendering` takes the render area
and the color and depth attachments, which must be texture views.
Render passes cannot nest, `endRendering` must be paired with
`beginRendering`, and `end` is rejected while a render pass is still
open.

Barriers are explicit too. A texture barrier names the layout the
texture is expected to be in and the layout it should move to. The
`layout_before` value must match the backend's current layout for that
texture, or the barrier is rejected. A newly created texture without
initial data starts in the `undefined` layout; a texture created with
initial data is left in a shader-readable layout by the upload path.
Buffer barriers express memory dependencies and do not carry a layout.

There is currently no command that executes a secondary command buffer.
`CommandBufferDescription.level` exists, and backends record it, but the
usable recording model is a primary command buffer per submission.
Similarly, indirect draws, timestamp queries, and advanced stages such
as ray tracing or mesh shaders are outside the current command set.

A recording error means the call sequence is invalid. Fix the sequence
before submitting; do not assume that a rejected command made partial
progress. The test backend performs the most thorough validation, which
makes it the best place to reproduce a sequence that a native driver
reports vaguely or not at all.

## Synchronization

Synchronization is split between the device and the queue.
`Device.waitIdle`, `Device.waitFence`, and `Device.resetFence` are
device operations. Acquire, submit, present, and `Queue.waitIdle` are
queue operations. Fences provide **device-to-host** completion: wait for
a fence before the CPU reuses memory or destroys resources that the GPU
may still be reading. Semaphores provide **queue-to-queue** ordering,
most commonly between acquire, rendering, and present.

For a typical swapchain frame, acquire an image before recording work
that targets it. On Vulkan, pass an acquire semaphore or an acquire
fence. If you pass a semaphore, make the submission wait on it. If you
pass a fence, wait for the fence on the host before touching the image.
Then submit the command buffer with the acquire semaphore as a wait,
the render-finished semaphore as a signal, and a per-frame fence. Present
the image with the render-finished semaphore as its wait.

A binary semaphore must not be signaled again before the matching wait
has consumed it. Do not destroy a semaphore or fence while it is
pending, and do not reset a fence that a queue is still using. Reusing a
fence across frames is fine once it has signaled and been reset.

`Queue.waitIdle` is the simple, coarse option. It performs the
strongest idle wait the backend can provide. It is appropriate during
shutdown and in tests, but a frame loop should normally use fences so
the CPU can prepare the next frame while the GPU finishes the previous
one. Fence fidelity differs by backend: Vulkan and Direct3D 12 have
native fences, OpenGL wraps a sync object, and Direct3D 11 tracks
submission state. The [backends guide](backends.md) records those
differences.

If `Swapchain.acquire` or `Swapchain.present` returns
`error.SurfaceOutOfDate` or `error.SurfaceLost`, stop using the
swapchain, destroy it, and create a new one from the same surface in the
same or a new size. Fetch the new images and views; the old handles are
no longer valid. `Acquired.suboptimal` is advisory and means the
swapchain still works but should be recreated at the next convenient
point.

## Host access and data transfer

Only buffers can be mapped. The buffer must have been created with
`Memory.host_visible`. `Device.map` takes an offset and a size and
returns a writable slice that stays valid until `unmap`. Mapping a
device-local buffer, mapping out of bounds, or mapping an already mapped
buffer is rejected.

`Buffer.write` and `Buffer.read` are convenience wrappers around map,
`memcpy`, and unmap. For manual mapping, pass the ranges you actually
wrote to `Device.unmap`. An empty dirty list means the whole mapped
range was written. Non-coherent memory needs those ranges to flush the
right bytes; coherent memory still accepts them. The slice returned by
`map` must not be used after `unmap`.

Textures are filled through `initial_data` at creation or through copy
commands. A non-host-visible buffer with initial data must enable
`usage.transfer_dst`, and a texture with initial data must enable
`usage.transfer_dst`. The backend performs the upload synchronously
during creation, so the resource is ready when `create` returns. Use
`row_pitch` and `image_height` when the source rows or depth slices are
padded.

Do not map or rewrite a buffer while the GPU may be reading it, and do
not destroy a texture while a copy into or out of it is in flight. Use
a barrier, a fence, or `Queue.waitIdle` to establish the dependency
first. The RHI does not insert those barriers for you.

## Queries

Device capabilities are read through `Device.query` and its typed
getters. `Device.Feature` covers the API version, device and driver
names, device type, limits, format support, memory heaps, queue family
properties, and the properties of surfaces, swapchains, buffers, and
textures.

A query result has a support state. `support` means the value is
available, `unsupport` means the backend can answer that the feature is
not available, and `unknown` means the backend cannot answer at all.
Treat `unknown` conservatively; it is not a promise of support. Fixed
size results are written into caller-provided storage or allocated with
an allocator, depending on `OutputMode`. Strings follow the same
pattern; array results such as `swapchain_images` and `swapchain_views`
require a caller-provided slice aligned for `Resource`. If the provided
slice is too small, the call returns `error.BufferTooSmall`.

`Device.supportsFormat` is the usual gate before creating a resource
with a format that the device may not support for the intended usage.
The `FormatProperties` flags describe sampled, storage, color
attachment, depth attachment, and buffer use. Limits come from
`Device.Limit`; query the relevant limit before creating resources near
the boundary. Resource wrappers also cache the properties returned at
creation, so `Buffer.size`, `Texture.properties`, and
`Swapchain.properties` are cheap to read without another query.

## Testing without a GPU

The test backend implements the same interfaces as the rendering
backends, so production resource and command code can run unchanged in
a unit test:

```zig
test "records a draw" {
    const backend = try rhi.Test.init(std.testing.allocator);
    defer backend.deinit();

    const device = backend.asDevice();

    // Create and use resources exactly like the Vulkan path.
    // Destroy every resource before validating.

    try backend.validate();
}
```

`Test.validate` fails with `LeakedResources` if any resource is still
alive and with `ValidationFailed` if the backend observed an invalid
call. Destroy every resource first, then call `validate`, then call
`deinit`. `deinit` also logs leaks at error level, but an explicit
`validate` gives the test a useful stack trace.

The test backend tracks resource generations, creation dependencies,
map and unmap state, command buffer state, descriptor writes, and queue
parameters. It exposes `bufferData` and `textureData` so a test can
assert that external data reached the backend intact. It does not
rasterize and does not compile shaders, so visual behavior still has to
be checked with one of the GPU backends.

## Choosing a backend

Backends are selected at build time, not discovered at runtime. An
application that supports several backends can keep them as a tagged
union and dispatch at the application boundary, which is what the
examples do. Resource handles are never shared across that boundary.

The next page, [Backends](backends.md), explains the platform
requirements and behavioral differences that remain even though the
interface is the same.
