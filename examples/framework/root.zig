//! Shared window, backend, and frame loop plumbing for the vfrhi
//! examples.
//!
//! An example picks a backend at run time with `--backend vulkan`,
//! `--backend opengl`, `--backend dx3d11`, or `--backend dx3d12`, then
//! records its commands between `beginPass` and `endPass`.

const std = @import("std");
const builtin = @import("builtin");
const rhi = @import("vfrhi");
const glfw = @import("glfw.zig");

const log = std.log.scoped(.example);

/// The allocator type used throughout the examples.
pub const Allocator = std.mem.Allocator;

/// A rendering backend selectable on the command line.
pub const BackendKind = enum {
    /// The Vulkan backend.
    vulkan,
    /// The OpenGL backend.
    opengl,
    /// The Direct3D 11 backend.
    dx3d11,
    /// The Direct3D 12 backend.
    dx3d12,

    /// Parses a backend name case-insensitively.
    pub fn parse(text: []const u8) ?BackendKind {
        if (std.ascii.eqlIgnoreCase(text, "vulkan")) return .vulkan;
        if (std.ascii.eqlIgnoreCase(text, "opengl")) return .opengl;
        if (std.ascii.eqlIgnoreCase(text, "dx3d11") or
            std.ascii.eqlIgnoreCase(text, "d3d11"))
        {
            return .dx3d11;
        }
        if (std.ascii.eqlIgnoreCase(text, "dx3d12") or
            std.ascii.eqlIgnoreCase(text, "d3d12"))
        {
            return .dx3d12;
        }
        return null;
    }

    /// Returns the command line spelling of the backend.
    pub fn name(self: BackendKind) []const u8 {
        return @tagName(self);
    }
};

/// Command line options understood by every example.
pub const CommandLine = struct {
    /// Selected backend.
    backend: BackendKind = .vulkan,
    /// Number of frames to render, or zero for unlimited.
    max_frames: u32 = 0,
    /// Whether `--help` was requested.
    help: bool = false,
};

/// Parses the `--backend` and `--frames` options.
///
/// # Args
/// - `allocator`: allocator used to decode the platform arguments.
/// - `args`: the process arguments from `std.process.Init`.
///
/// # Return
/// The parsed command line.
///
/// # Error
/// - `error.InvalidBackend`: the value after `--backend` is unknown.
/// - `error.InvalidFrameCount`: the value after `--frames` is not a
///   number.
/// - `error.MissingValue`: an option has no value.
/// - `error.UnknownArgument`: the argument is not recognized.
pub fn parseArgs(
    allocator: Allocator,
    args: std.process.Args,
) !CommandLine {
    var result: CommandLine = .{};
    var iterator = try args.iterateAllocator(allocator);
    defer iterator.deinit();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help") or
            std.mem.eql(u8, argument, "-h"))
        {
            result.help = true;
        } else if (std.mem.eql(u8, argument, "--backend") or
            std.mem.eql(u8, argument, "-b"))
        {
            const value = iterator.next() orelse
                return error.MissingValue;
            result.backend = BackendKind.parse(value) orelse
                return error.InvalidBackend;
        } else if (std.mem.eql(u8, argument, "--frames")) {
            const value = iterator.next() orelse
                return error.MissingValue;
            result.max_frames = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidFrameCount;
        } else {
            return error.UnknownArgument;
        }
    }
    return result;
}

/// Prints the shared option help.
///
/// # Args
/// - `description`: a one line description of the example.
pub fn printUsage(description: []const u8) void {
    std.debug.print(
        \\{s}
        \\
        \\usage: zig build run -- [options]
        \\
        \\  -b, --backend <name>  vulkan, opengl, dx3d11, or dx3d12
        \\      --frames <count>  stop after count frames, 0 runs until close
        \\  -h, --help                     show this message
        \\
    , .{description});
}

/// Window and backend creation parameters.
pub const Options = struct {
    /// Window title and Vulkan application name.
    title: [:0]const u8,
    /// Window and swapchain width.
    width: u32 = 800,
    /// Window and swapchain height.
    height: u32 = 600,
    /// Backend selected on the command line.
    backend: BackendKind = .vulkan,
};

/// A clear color used when a render pass begins.
pub const ClearColor = struct {
    /// Red component.
    r: f32 = 0.05,
    /// Green component.
    g: f32 = 0.08,
    /// Blue component.
    b: f32 = 0.16,
    /// Alpha component.
    a: f32 = 1.0,
};

/// One acquired swapchain image.
pub const Frame = struct {
    /// Index of the acquired image.
    image_index: u32,
    /// Swapchain texture to transition.
    image: rhi.Resource,
    /// View used as a color attachment.
    view: rhi.Resource,
};

const VulkanSync = struct {
    image_available: rhi.Semaphore,
    render_finished: rhi.Semaphore,
    in_flight: rhi.Fence,

    fn create(device: rhi.Device) !VulkanSync {
        const image_available = try device.createSemaphore(.{});
        errdefer image_available.destroy();
        const render_finished = try device.createSemaphore(.{});
        errdefer render_finished.destroy();
        const in_flight = try device.createFence(.{
            .signaled = true,
        });
        errdefer in_flight.destroy();
        return .{
            .image_available = image_available,
            .render_finished = render_finished,
            .in_flight = in_flight,
        };
    }

    fn destroy(self: VulkanSync) void {
        self.in_flight.destroy();
        self.render_finished.destroy();
        self.image_available.destroy();
    }
};

const dx3d11_available = builtin.os.tag == .windows and
    rhi.dx3d11_enabled;
const dx3d12_available = builtin.os.tag == .windows and
    rhi.dx3d12_enabled;

const Dx3d11Ptr = if (dx3d11_available) *rhi.Dx3d11 else void;
const Dx3d12Ptr = if (dx3d12_available) *rhi.Dx3d12 else void;

const Backend = union(BackendKind) {
    vulkan: *rhi.Vulkan,
    opengl: *rhi.OpenGL,
    dx3d11: Dx3d11Ptr,
    dx3d12: Dx3d12Ptr,
};

const win32 = if (builtin.os.tag == .windows) struct {
    extern fn GetModuleHandleW(
        name: ?[*:0]const u16,
    ) ?*anyopaque;
} else struct {};

/// A window, a rendering backend, and a swapchain.
pub const App = struct {
    /// Allocator used for swapchain arrays.
    allocator: Allocator,
    /// The GLFW window.
    window: *glfw.Window,
    /// Selected backend.
    kind: BackendKind,
    /// The initialized backend instance.
    backend: Backend,
    /// RHI device of the backend.
    device: rhi.Device,
    /// Graphics and present queue.
    queue: rhi.Queue,
    /// Surface of the window.
    surface: rhi.Surface,
    /// Swapchain of the surface.
    swapchain: rhi.Swapchain,
    /// Swapchain images.
    images: []rhi.Resource,
    /// Swapchain views.
    views: []rhi.Resource,
    /// Command buffer used by each frame.
    command_buffer: rhi.CommandBuffer,
    /// Vulkan synchronization objects, or null for OpenGL.
    sync: ?VulkanSync,

    /// Creates a window, a backend, and a swapchain.
    ///
    /// # Args
    /// - `allocator`: allocator for backend bookkeeping and arrays.
    /// - `options`: window and backend parameters.
    ///
    /// # Return
    /// An initialized application. The RHI resources created by the
    /// caller must be destroyed before `deinit` runs.
    ///
    /// # Error
    /// - `error.GlfwInitFailed`: GLFW cannot be initialized.
    /// - `error.WindowCreationFailed`: no window can be created.
    /// - `error.VulkanNotSupported`: GLFW finds no Vulkan loader.
    /// - `error.UnsupportedSurface`: the platform has no supported
    ///   Vulkan surface handle.
    /// - Other errors from backend, surface, or swapchain creation.
    pub fn init(allocator: Allocator, options: Options) !App {
        if (glfw.glfwInit() != glfw.TRUE) {
            return error.GlfwInitFailed;
        }
        errdefer glfw.glfwTerminate();

        switch (options.backend) {
            .vulkan, .dx3d11, .dx3d12 => {
                glfw.glfwWindowHint(glfw.CLIENT_API, glfw.NO_API);
            },
            .opengl => {
                glfw.glfwWindowHint(
                    glfw.CONTEXT_VERSION_MAJOR,
                    4,
                );
                glfw.glfwWindowHint(
                    glfw.CONTEXT_VERSION_MINOR,
                    5,
                );
                glfw.glfwWindowHint(
                    glfw.OPENGL_PROFILE,
                    glfw.OPENGL_CORE_PROFILE,
                );
            },
        }
        glfw.glfwWindowHint(glfw.RESIZABLE, glfw.FALSE);

        const window = glfw.glfwCreateWindow(
            @intCast(options.width),
            @intCast(options.height),
            options.title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;
        errdefer glfw.glfwDestroyWindow(window);

        const backend = try createBackend(
            allocator,
            options,
            window,
        );
        errdefer deinitBackend(backend);

        const device: rhi.Device = switch (backend) {
            .vulkan => |value| value.asDevice(),
            .opengl => |value| value.asDevice(),
            .dx3d11 => |value| if (dx3d11_available)
                value.asDevice()
            else
                unreachable,
            .dx3d12 => |value| if (dx3d12_available)
                value.asDevice()
            else
                unreachable,
        };
        const queue = try device.getQueue(0);

        const native = try surfaceDescription(
            window,
            options,
        );
        const surface = try device.createSurface(native);
        errdefer surface.destroy();

        const swapchain = try device.createSwapchain(.{
            .surface = surface.resource,
            .width = options.width,
            .height = options.height,
            .format = .b8g8r8a8_srgb,
            .image_count = 3,
        });
        errdefer swapchain.destroy();

        const images = try swapchain.images(allocator);
        errdefer allocator.free(images);
        const views = try swapchain.views(allocator);
        errdefer allocator.free(views);

        const command_buffer = try device.createCommandBuffer(.{});
        errdefer command_buffer.destroy();

        const sync: ?VulkanSync = switch (options.backend) {
            .vulkan, .dx3d12 => try VulkanSync.create(device),
            .opengl, .dx3d11 => null,
        };
        errdefer if (sync) |value| value.destroy();

        log.info(
            "backend: {s}, extent: {d}x{d}",
            .{
                options.backend.name(),
                swapchain.properties.width,
                swapchain.properties.height,
            },
        );

        return .{
            .allocator = allocator,
            .window = window,
            .kind = options.backend,
            .backend = backend,
            .device = device,
            .queue = queue,
            .surface = surface,
            .swapchain = swapchain,
            .images = images,
            .views = views,
            .command_buffer = command_buffer,
            .sync = sync,
        };
    }

    /// Destroys the swapchain, backend, and window.
    ///
    /// # Note
    /// Every RHI resource must already be destroyed. The method waits
    /// for the device to become idle before releasing resources.
    pub fn deinit(self: *App) void {
        self.queue.waitIdle() catch |err| {
            log.warn("waitIdle failed: {t}", .{err});
        };
        if (self.sync) |value| value.destroy();
        self.command_buffer.destroy();
        self.allocator.free(self.views);
        self.allocator.free(self.images);
        self.swapchain.destroy();
        self.surface.destroy();
        deinitBackend(self.backend);
        glfw.glfwDestroyWindow(self.window);
        glfw.glfwTerminate();
    }

    /// Returns the swapchain width.
    pub fn width(self: *const App) u32 {
        return self.swapchain.properties.width;
    }

    /// Returns the swapchain height.
    pub fn height(self: *const App) u32 {
        return self.swapchain.properties.height;
    }

    /// Polls window events and handles the escape key.
    pub fn pollEvents(self: *App) void {
        glfw.glfwPollEvents();
        if (glfw.glfwGetKey(self.window, glfw.KEY_ESCAPE) ==
            glfw.PRESS)
        {
            glfw.glfwSetWindowShouldClose(self.window, glfw.TRUE);
        }
    }

    /// Returns whether the user closed the window.
    pub fn shouldClose(self: *const App) bool {
        return glfw.glfwWindowShouldClose(self.window) == glfw.TRUE;
    }

    /// Blocks until the device is idle.
    pub fn waitIdle(self: *App) !void {
        try self.queue.waitIdle();
    }

    /// Acquires the next swapchain image.
    ///
    /// # Return
    /// A frame, or `null` if the swapchain is out of date.
    ///
    /// # Error
    /// - Errors reported by `Swapchain.acquire`.
    pub fn acquire(self: *App) !?Frame {
        switch (self.backend) {
            .vulkan, .dx3d12 => {
                const sync = self.sync.?;
                try sync.in_flight.wait(std.math.maxInt(u64));
                const acquired = self.swapchain.acquire(
                    self.queue,
                    sync.image_available,
                    null,
                ) catch |err| switch (err) {
                    error.SurfaceOutOfDate => return null,
                    else => return err,
                };
                try sync.in_flight.reset();
                return .{
                    .image_index = acquired.image_index,
                    .image = self.images[acquired.image_index],
                    .view = self.views[acquired.image_index],
                };
            },
            .opengl, .dx3d11 => {
                const acquired = self.swapchain.acquire(
                    self.queue,
                    null,
                    null,
                ) catch |err| switch (err) {
                    error.SurfaceOutOfDate => return null,
                    else => return err,
                };
                return .{
                    .image_index = acquired.image_index,
                    .image = self.images[acquired.image_index],
                    .view = self.views[acquired.image_index],
                };
            },
        }
    }

    /// Transitions the frame image and starts a render pass.
    ///
    /// # Args
    /// - `frame`: the frame returned by `acquire`.
    /// - `clear`: the background clear color.
    ///
    /// # Error
    /// - Errors reported by `CommandBuffer.barrier` and
    ///   `CommandBuffer.beginRendering`.
    pub fn beginPass(
        self: *App,
        frame: Frame,
        clear: ClearColor,
    ) !void {
        try self.command_buffer.barrier(.{
            .resource = frame.image,
            .src_stage = .top_of_pipe,
            .dst_stage = .color_attachment,
            .dst_access = .{ .color_attachment_write = true },
            .layout_before = .undefined,
            .layout_after = .color_attachment,
        });
        try self.command_buffer.beginRendering(.{
            .area = .{
                .width = self.width(),
                .height = self.height(),
            },
            .color_attachments = &.{.{
                .view = frame.view,
                .load = .clear,
                .store = .store,
                .clear = .{
                    .r = clear.r,
                    .g = clear.g,
                    .b = clear.b,
                    .a = clear.a,
                },
            }},
        });
    }

    /// Ends the render pass and transitions the image for present.
    ///
    /// # Args
    /// - `frame`: the frame returned by `acquire`.
    ///
    /// # Error
    /// - Errors reported by `CommandBuffer.endRendering` and
    ///   `CommandBuffer.barrier`.
    pub fn endPass(self: *App, frame: Frame) !void {
        try self.command_buffer.endRendering();
        try self.command_buffer.barrier(.{
            .resource = frame.image,
            .src_stage = .color_attachment,
            .dst_stage = .bottom_of_pipe,
            .src_access = .{ .color_attachment_write = true },
            .layout_before = .color_attachment,
            .layout_after = .present,
        });
    }

    /// Submits the recorded commands and presents the frame.
    ///
    /// # Args
    /// - `frame`: the frame returned by `acquire`.
    ///
    /// # Error
    /// - Errors reported by submission or presentation.
    pub fn endFrame(self: *App, frame: Frame) !void {
        switch (self.backend) {
            .vulkan, .dx3d12 => {
                const sync = self.sync.?;
                try self.command_buffer.submit(self.queue, .{
                    .wait_semaphores = &.{
                        sync.image_available.resource,
                    },
                    .signal_semaphores = &.{
                        sync.render_finished.resource,
                    },
                    .fence = sync.in_flight,
                });
                try self.swapchain.present(.{
                    .queue = self.queue,
                    .image_index = frame.image_index,
                    .wait_semaphores = &.{
                        sync.render_finished.resource,
                    },
                });
            },
            .opengl, .dx3d11 => {
                try self.command_buffer.submit(self.queue, .{});
                try self.swapchain.present(.{
                    .queue = self.queue,
                    .image_index = frame.image_index,
                });
                if (self.kind == .opengl) {
                    glfw.glfwSwapBuffers(self.window);
                }
            },
        }
    }

    /// Sets a viewport matching the swapchain.
    pub fn setViewport(self: *App) !void {
        try self.command_buffer.setViewport(.{
            .width = @floatFromInt(self.width()),
            .height = @floatFromInt(self.height()),
        });
    }

    /// Sets a scissor rectangle matching the swapchain.
    pub fn setScissor(self: *App) !void {
        try self.command_buffer.setScissor(.{
            .width = self.width(),
            .height = self.height(),
        });
    }
};

fn createBackend(
    allocator: Allocator,
    options: Options,
    window: *glfw.Window,
) !Backend {
    return switch (options.backend) {
        .vulkan => .{ .vulkan = try createVulkan(allocator, options) },
        .opengl => .{ .opengl = try createOpenGl(allocator, window) },
        .dx3d11 => if (dx3d11_available)
            .{ .dx3d11 = try rhi.Dx3d11.init(allocator, .{}) }
        else
            error.UnsupportedBackend,
        .dx3d12 => if (dx3d12_available)
            .{ .dx3d12 = try rhi.Dx3d12.init(allocator, .{}) }
        else
            error.UnsupportedBackend,
    };
}

fn deinitBackend(backend: Backend) void {
    switch (backend) {
        .vulkan => |value| value.deinit(),
        .opengl => |value| value.deinit(),
        .dx3d11 => |value| if (dx3d11_available) value.deinit(),
        .dx3d12 => |value| if (dx3d12_available) value.deinit(),
    }
}

fn createVulkan(
    allocator: Allocator,
    options: Options,
) !*rhi.Vulkan {
    if (glfw.glfwVulkanSupported() != glfw.TRUE) {
        return error.VulkanNotSupported;
    }
    var extension_count: u32 = 0;
    const extensions = glfw.glfwGetRequiredInstanceExtensions(
        &extension_count,
    ) orelse return error.VulkanExtensionsUnavailable;
    if (extension_count == 0) {
        return error.VulkanExtensionsUnavailable;
    }
    return rhi.Vulkan.init(
        allocator,
        glfw.glfwGetInstanceProcAddress,
        .{
            .application_name = options.title,
            .engine_name = "vfrhi examples",
            .api_version = .api_1_3,
            .enabled_extension = extensions,
            .extension_count = extension_count,
        },
    );
}

fn createOpenGl(
    allocator: Allocator,
    window: *glfw.Window,
) !*rhi.OpenGL {
    glfw.glfwMakeContextCurrent(window);
    return rhi.OpenGL.init(
        allocator,
        glfw.glfwGetProcAddress,
        .{},
    );
}

fn surfaceDescription(
    window: *glfw.Window,
    options: Options,
) !rhi.types.SurfaceDescription {
    if (options.backend == .dx3d11 or
        options.backend == .dx3d12)
    {
        if (builtin.os.tag != .windows) {
            return error.UnsupportedSurface;
        }
        return win32Surface(window, options);
    }
    if (options.backend == .opengl) {
        return .{ .native = .{ .headless = .{
            .width = options.width,
            .height = options.height,
        } } };
    }
    if (builtin.os.tag == .windows) {
        return win32Surface(window, options);
    }
    if (builtin.os.tag == .linux) {
        if (glfw.glfwGetX11Display()) |display| {
            const x11_window = glfw.glfwGetX11Window(window);
            if (x11_window != 0) {
                return .{ .native = .{ .xlib = .{
                    .display = @intFromPtr(display),
                    .window = @intCast(x11_window),
                } } };
            }
        }
        if (glfw.glfwGetWaylandDisplay()) |display| {
            if (glfw.glfwGetWaylandWindow(window)) |surface| {
                return .{ .native = .{ .wayland = .{
                    .display = @intFromPtr(display),
                    .surface = @intFromPtr(surface),
                } } };
            }
        }
        return error.UnsupportedSurface;
    }
    return error.UnsupportedSurface;
}

fn win32Surface(
    window: *glfw.Window,
    options: Options,
) !rhi.types.SurfaceDescription {
    _ = options;
    if (builtin.os.tag != .windows) return error.UnsupportedSurface;
    const hwnd = glfw.glfwGetWin32Window(window) orelse
        return error.WindowHandleUnavailable;
    const hinstance = win32.GetModuleHandleW(null) orelse
        return error.ModuleHandleUnavailable;
    return .{ .native = .{ .win32 = .{
        .hinstance = @intFromPtr(hinstance),
        .hwnd = @intFromPtr(hwnd),
    } } };
}
