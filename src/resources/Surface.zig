pub const Description = struct {
    win32: struct {
        hinstance: std.os.windows.HMODULE,
        hwnd: std.os.windows.HWND,
    },
};

const std = @import("std");
const rhi = @import("rhi");
const Device = rhi.Device;
const Resource = Device.Resource;
const Surface = @This();

device: Device,
resource: Resource,

pub fn create(device: Device, description: Description) !Surface {
    const resource = try device.create(description);
    return .{
        .device = device,
        .resource = resource,
    };
}

pub fn destroy(self: Surface) void {
    self.device.destroy(self.resource);
}
