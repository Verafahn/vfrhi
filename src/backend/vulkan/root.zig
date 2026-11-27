const std = @import("std");
const vk = @import("vulkan");
const Vulkan = @This();
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vulkan);
const Writer = std.Io.Writer;

pub const Version = packed struct(u32) {
    patch: u12,
    minor: u10,
    major: u7,
    variant: u3,

    pub fn make(
        variant: u3,
        major: u7,
        minor: u10,
        patch: u12,
    ) Version {
        return .{
            .patch = patch,
            .minor = minor,
            .major = major,
            .variant = variant,
        };
    }

    pub const api_1_0: Version = .make(0, 1, 0, 0);
    pub const api_1_1: Version = .make(0, 1, 1, 0);
    pub const api_1_2: Version = .make(0, 1, 2, 0);
    pub const api_1_3: Version = .make(0, 1, 3, 0);
    pub const api_1_4: Version = .make(0, 1, 4, 0);

    pub fn format(self: Version, w: *Writer) Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}", .{
            self.variant,
            self.major,
            self.minor,
            self.patch,
        });
    }
};

pub const VulkanDesc = struct {
    application_name: ?[:0]const u8,
    application_version: Version,
    engine_name: ?[:0]const u8,
    engine_version: Version,
    api_version: Version,
    enabled_extension: ?[*]const [*:0]const u8,
    extension_count: u32,
    allocator: ?*const vk.AllocationCallbacks = null,
};

vki: vk.InstanceProxy,
allocator: Allocator,
instance: vk.Instance,
vki_wrapper: vk.InstanceWrapper,
vk_allocator: ?*const vk.AllocationCallbacks,

pub fn init(allocator: Allocator, loader_fn: anytype, info: VulkanDesc) !*Vulkan {
    log.debug("Creating vulkan backend", .{});
    errdefer log.warn("Vulkan backend creation failed.", .{});

    if (info.application_name) |name| {
        log.info("   application_name: {s}", .{name});
    }
    log.info("application_version: {f}", .{info.application_version});
    if (info.engine_name) |name| {
        log.info("        engine_name: {s}", .{name});
    }
    log.info("     engine_version: {f}", .{info.engine_version});
    log.info("        api_version: {f}", .{info.api_version});
    log.info("    extension_count: {d}", .{info.extension_count});
    log.info("  enabled_extension:", .{});
    for (0..info.extension_count) |i| {
        std.debug.print("\t\t\t - {s},\n", .{
            info.enabled_extension.?[i],
        });
    }

    const this = try allocator.create(Vulkan);
    this.allocator = allocator;
    this.vk_allocator = info.allocator;

    const vkb = vk.BaseWrapper.load(loader_fn);

    const app_name: ?[*:0]const u8 =
        if (info.application_name) |name|
            @ptrCast(name)
        else
            null;
    const engine_name: ?[*:0]const u8 =
        if (info.engine_name) |name|
            @ptrCast(name)
        else
            null;
    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = @backingInt(info.application_version),
        .p_engine_name = engine_name,
        .engine_version = @backingInt(info.engine_version),
        .api_version = @backingInt(info.api_version),
    };

    this.instance = try vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = info.extension_count,
        .pp_enabled_extension_names = info.enabled_extension,
    }, this.vk_allocator);

    this.vki_wrapper = vk.InstanceWrapper.load(this.instance, loader_fn);
    this.vki = vk.InstanceProxy.init(this.instance, &this.vki_wrapper);

    log.debug("Vulkan backend has been created.", .{});
    return this;
}

pub fn deinit(this: *Vulkan) void {
    log.debug("Destroying Vulkan backend.", .{});
    this.vki.destroyInstance(this.vk_allocator);
    const allocator = this.allocator;
    this.* = undefined;
    allocator.destroy(this);
    log.debug("Vulkan backend has been destroyed.", .{});
}
