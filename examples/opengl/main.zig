const std = @import("std");
const glfw = @import("glfw");
const rhi = @import("vfrhi");

const max_frames = 240;

// Equivalent GLSL:
//   layout(location = 0) in vec3 position;
//   void main() { gl_Position = vec4(position, 1.0); }
//
// `gl_Position` is the first member of the `gl_PerVertex` output
// interface block, which is how glslang represents it.
const vertex_spirv = [_]u32{
    0x07230203, 0x00010000, 0,          20,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0007000f, 0,          13,         0x6e69616d, 0,
    12,         10,         0x00030047, 7,          2,
    0x00050048, 7,          0,          11,         0,
    0x00040047, 12,         30,         0,          0x00020013,
    1,          0x00030021, 2,          1,          0x00030016,
    3,          32,         0x00040017, 4,          3,
    3,          0x00040017, 5,          3,          4,
    0x00040015, 6,          32,         0,          0x0003001e,
    7,          5,          0x00040020, 8,          3,
    7,          0x00040020, 9,          3,          5,
    0x00040020, 11,         1,          4,          0x0004002b,
    6,          15,         0,          0x0004002b, 3,
    17,         0x3f800000, 0x0004003b, 8,          10,
    3,          0x0004003b, 11,         12,         1,
    0x00050036, 1,          13,         0,          2,
    0x000200f8, 14,         0x00050041, 9,          19,
    10,         15,         0x0004003d, 4,          16,
    12,         0x00050050, 5,          18,         16,
    17,         0x0003003e, 19,         18,         0x000100fd,
    0x00010038,
};

// Equivalent GLSL:
//   layout(location = 0) out vec4 color;
//   layout(set = 0, binding = 0) uniform Params { vec4 tint; } params;
//   layout(set = 0, binding = 1) uniform sampler2D tex;
//   void main() { color = params.tint * texture(tex, vec2(0.25)); }
const fragment_spirv = [_]u32{
    0x07230203, 0x00010000, 0,          27,         0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0006000f, 4,          17,         0x6e69616d, 0,
    16,         0x00030047, 7,          2,          0x00050048,
    7,          0,          35,         0,          0x00040047,
    14,         34,         0,          0x00040047, 14,
    33,         0,          0x00040047, 15,         34,
    0,          0x00040047, 15,         33,         1,
    0x00040047, 16,         30,         0,          0x00020013,
    1,          0x00030021, 2,          1,          0x00030016,
    3,          32,         0x00040017, 4,          3,
    2,          0x00040017, 5,          3,          4,
    0x00040015, 6,          32,         0,          0x0003001e,
    7,          5,          0x00040020, 8,          2,
    7,          0x00040020, 9,          2,          5,
    0x00040020, 10,         3,          5,          0x00090019,
    11,         3,          1,          0,          0,
    0,          1,          0,          0x0003001b, 12,
    11,         0x00040020, 13,         0,          12,
    0x0004002b, 6,          19,         0,          0x0004002b,
    3,          20,         0x3e800000, 0x0005002c, 4,
    21,         20,         20,         0x0004003b, 8,
    14,         2,          0x0004003b, 13,         15,
    0,          0x0004003b, 10,         16,         3,
    0x00050036, 1,          17,         0,          2,
    0x000200f8, 18,         0x00050041, 9,          22,
    14,         19,         0x0004003d, 5,          23,
    22,         0x0004003d, 12,         24,         15,
    0x00050057, 5,          25,         24,         21,
    0x00050085, 5,          26,         23,         25,
    0x0003003e, 16,         26,         0x000100fd, 0x00010038,
};

const vertices = [_]f32{
    -0.5, -0.5, 0,
    0.5,  -0.5, 0,
    0.0,  0.5,  0,
};

pub fn main(init: std.process.Init) !void {
    if (glfw.glfwInit() != glfw.GLFW_TRUE) {
        return error.GlfwInitFailed;
    }
    defer glfw.glfwTerminate();

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 5);
    glfw.glfwWindowHint(
        glfw.GLFW_OPENGL_PROFILE,
        glfw.GLFW_OPENGL_CORE_PROFILE,
    );
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);
    const window = glfw.glfwCreateWindow(
        800,
        600,
        "vfrhi opengl",
        null,
        null,
    );
    if (window == null) return error.WindowCreationFailed;
    defer glfw.glfwDestroyWindow(window);

    glfw.glfwMakeContextCurrent(window);

    const allocator = init.gpa;
    const backend = try rhi.OpenGL.init(
        allocator,
        glfw.glfwGetProcAddress,
        .{},
    );
    defer backend.deinit();
    const device = backend.asDevice();
    const queue = try device.getQueue(0);

    const surface = try rhi.Surface.create(device, .{
        .native = .{ .headless = .{
            .width = 800,
            .height = 600,
        } },
    });
    defer surface.destroy();

    const swapchain = try rhi.Swapchain.create(device, .{
        .surface = surface.resource,
        .width = 800,
        .height = 600,
        .format = .b8g8r8a8_srgb,
        .image_count = 3,
    });
    defer swapchain.destroy();

    const images = try swapchain.images(allocator);
    defer allocator.free(images);
    const views = try swapchain.views(allocator);
    defer allocator.free(views);

    const vertex_shader = try rhi.Shader.create(device, .{
        .stage = .vertex,
        .code = &vertex_spirv,
    });
    defer vertex_shader.destroy();

    const set_layout = try rhi.DescriptorSetLayout.create(device, .{
        .bindings = &.{
            .{
                .binding = 0,
                .kind = .uniform_buffer,
                .stages = .{ .fragment = true },
            },
            .{
                .binding = 1,
                .kind = .combined_image_sampler,
                .stages = .{ .fragment = true },
            },
        },
    });
    defer set_layout.destroy();

    const fragment_shader = try rhi.Shader.create(device, .{
        .stage = .fragment,
        .code = &fragment_spirv,
    });
    defer fragment_shader.destroy();

    const pipeline_layout = try rhi.PipelineLayout.create(device, .{
        .descriptor_sets = &.{set_layout.resource},
    });
    defer pipeline_layout.destroy();

    const pipeline = try rhi.GraphicsPipeline.create(device, .{
        .layout = pipeline_layout.resource,
        .vertex = vertex_shader.resource,
        .fragment = fragment_shader.resource,
        .vertex_layout = .{
            .bindings = &.{.{ .binding = 0, .stride = 12 }},
            .attributes = &.{.{
                .location = 0,
                .binding = 0,
                .format = .r32g32b32_float,
            }},
        },
        .depth = .{ .enable = false, .write = false },
        .color_formats = &.{.b8g8r8a8_srgb},
    });
    defer pipeline.destroy();

    const vertex_buffer = try rhi.Buffer.create(device, .{
        .size = std.mem.sliceAsBytes(&vertices).len,
        .usage = .{ .vertex = true },
        .memory = .{ .host_visible = true },
        .initial_data = std.mem.sliceAsBytes(&vertices),
    });
    defer vertex_buffer.destroy();

    const readback = try rhi.Buffer.create(device, .{
        .size = 4,
        .usage = .{ .transfer_dst = true },
        .memory = .{ .host_visible = true },
    });
    defer readback.destroy();

    const tint = [_]f32{ 1.0, 0.55, 0.2, 1.0 };
    const uniform_buffer = try rhi.Buffer.create(device, .{
        .size = std.mem.sliceAsBytes(&tint).len,
        .usage = .{ .uniform = true },
        .memory = .{ .host_visible = true },
        .initial_data = std.mem.sliceAsBytes(&tint),
    });
    defer uniform_buffer.destroy();

    const descriptor_set = try rhi.DescriptorSet.create(device, .{
        .layout = set_layout.resource,
    });
    defer descriptor_set.destroy();

    const pixel_data: [4]u8 = .{ 255, 64, 64, 255 };
    const texture = try rhi.Texture.create(device, .{
        .format = .r8g8b8a8_unorm,
        .width = 1,
        .height = 1,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .initial_data = .{ .bytes = &pixel_data },
    });
    defer texture.destroy();
    const texture_view = try texture.createView(.{});
    defer texture_view.destroy();
    const sampler = try rhi.Sampler.create(device, .{});
    defer sampler.destroy();

    try descriptor_set.update(&.{
        .{
            .binding = 0,
            .kind = .{ .buffer = .{
                .buffer = uniform_buffer.resource,
                .size = std.mem.sliceAsBytes(&tint).len,
            } },
        },
        .{
            .binding = 1,
            .kind = .{ .texture = .{
                .view = texture_view.resource,
                .sampler = sampler.resource,
            } },
        },
    });

    const command_buffer = try rhi.CommandBuffer.create(device, .{});
    defer command_buffer.destroy();

    var frame: u32 = 0;
    while (frame < max_frames and
        glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) : (frame += 1)
    {
        glfw.glfwPollEvents();

        const acquired = try swapchain.acquire(queue, null, null);

        try command_buffer.begin();
        try command_buffer.beginRendering(.{
            .area = .{
                .width = swapchain.properties.width,
                .height = swapchain.properties.height,
            },
            .color_attachments = &.{.{
                .view = views[acquired.image_index],
                .load = .clear,
                .store = .store,
                .clear = .{ .r = 0.05, .g = 0.08, .b = 0.16 },
            }},
        });
        try command_buffer.bindPipeline(.{
            .pipeline = pipeline.resource,
        });
        try command_buffer.bindDescriptorSets(.{
            .layout = pipeline_layout.resource,
            .sets = &.{descriptor_set.resource},
        });
        try command_buffer.bindVertexBuffers(.{
            .buffers = &.{vertex_buffer.resource},
        });
        try command_buffer.setViewport(.{
            .width = @floatFromInt(swapchain.properties.width),
            .height = @floatFromInt(swapchain.properties.height),
        });
        try command_buffer.setScissor(.{
            .width = swapchain.properties.width,
            .height = swapchain.properties.height,
        });
        try command_buffer.draw(.{ .vertex_count = 3 });
        try command_buffer.endRendering();
        if (frame == 0) {
            try command_buffer.copyTextureToBuffer(.{
                .texture = images[acquired.image_index],
                .buffer = readback.resource,
                .region = .{
                    .offset = .{ .x = 400, .y = 300 },
                    .extent = .{ .width = 1, .height = 1 },
                },
            });
        }
        try command_buffer.end();

        try command_buffer.submit(queue, .{});
        if (frame == 0) {
            const pixel = try readback.map(0, 4);
            defer readback.unmap(&.{.{ .offset = 0, .size = 4 }});
            // The swapchain format is b8g8r8a8_srgb, so the bytes are
            // B, G, R, A. The tinted red triangle must dominate the
            // dark clear color at the center of the image.
            if (pixel[2] < 200 or pixel[1] >= 200 or pixel[0] >= 200) {
                std.debug.print("unexpected pixel: {any}\n", .{pixel});
                return error.RenderValidationFailed;
            }
        }
        try swapchain.present(.{
            .queue = queue,
            .image_index = acquired.image_index,
        });
        glfw.glfwSwapBuffers(window);
    }

    try device.waitIdle();
    std.debug.print("vfrhi opengl rendered {d} frame(s)\n", .{frame});
}
