//! Minimal GLFW 3.5 bindings used by the examples.
//!
//! The examples only need window creation, event polling, and the
//! native window handles. Declaring this small subset directly keeps
//! the example projects free of a translate-c build step.

/// An opaque GLFW window.
pub const Window = opaque {};

/// An opaque GLFW monitor.
pub const Monitor = opaque {};

/// The GLFW boolean true value.
pub const TRUE = 1;
/// The GLFW boolean false value.
pub const FALSE = 0;
/// The GLFW key press state.
pub const PRESS = 1;

/// The window resizable hint.
pub const RESIZABLE = 0x00020003;
/// The client API hint.
pub const CLIENT_API = 0x00022001;
/// The context major version hint.
pub const CONTEXT_VERSION_MAJOR = 0x00022002;
/// The context minor version hint.
pub const CONTEXT_VERSION_MINOR = 0x00022003;
/// The OpenGL profile hint.
pub const OPENGL_PROFILE = 0x00022008;
/// The value that disables a client API.
pub const NO_API = 0;
/// The OpenGL core profile value.
pub const OPENGL_CORE_PROFILE = 0x00032001;
/// The escape key.
pub const KEY_ESCAPE = 256;

/// Initializes GLFW.
pub extern fn glfwInit() c_int;
/// Terminates GLFW.
pub extern fn glfwTerminate() void;
/// Sets a window creation hint.
pub extern fn glfwWindowHint(hint: c_int, value: c_int) void;
/// Creates a window.
pub extern fn glfwCreateWindow(
    width: c_int,
    height: c_int,
    title: [*:0]const u8,
    monitor: ?*Monitor,
    share: ?*Window,
) ?*Window;
/// Destroys a window.
pub extern fn glfwDestroyWindow(window: *Window) void;
/// Returns whether the user asked to close the window.
pub extern fn glfwWindowShouldClose(window: *Window) c_int;
/// Requests or clears window closure.
pub extern fn glfwSetWindowShouldClose(
    window: *Window,
    value: c_int,
) void;
/// Processes pending window events.
pub extern fn glfwPollEvents() void;
/// Returns the state of a key.
pub extern fn glfwGetKey(window: *Window, key: c_int) c_int;
/// Makes a window's OpenGL context current.
pub extern fn glfwMakeContextCurrent(window: *Window) void;
/// Swaps the front and back buffers.
pub extern fn glfwSwapBuffers(window: *Window) void;

/// Returns whether a Vulkan loader is available.
pub extern fn glfwVulkanSupported() c_int;
/// Returns the instance extensions required for window surfaces.
pub extern fn glfwGetRequiredInstanceExtensions(
    count: *u32,
) ?[*]const [*:0]const u8;
/// Loads an OpenGL entry point.
pub extern fn glfwGetProcAddress(
    proc_name: [*:0]const u8,
) ?*anyopaque;
/// Loads a Vulkan instance entry point.
pub extern fn glfwGetInstanceProcAddress(
    instance: ?*anyopaque,
    proc_name: [*:0]const u8,
) ?*anyopaque;

/// Returns the Win32 window handle.
pub extern fn glfwGetWin32Window(window: *Window) ?*anyopaque;
/// Returns the X11 display.
pub extern fn glfwGetX11Display() ?*anyopaque;
/// Returns the X11 window id.
pub extern fn glfwGetX11Window(window: *Window) c_ulong;
/// Returns the Wayland display.
pub extern fn glfwGetWaylandDisplay() ?*anyopaque;
/// Returns the Wayland surface.
pub extern fn glfwGetWaylandWindow(window: *Window) ?*anyopaque;
