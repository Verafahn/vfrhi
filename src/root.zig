const std = @import("std");
pub const log = std.log.scoped(.vfrhi);
pub const Device = @import("Device.zig");

const backend = @import("backend");
pub const Vulkan =
    if (backend.vulkan)
        @import("backend/vulkan/root.zig")
    else
        @compileError(
            "If you want to use Vulkan backend, " ++
                "please pass '.vulkan=true' during build time.",
        );
