const std = @import("std");
const c = @cImport({
    @cInclude("Metal/Metal.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
    @cInclude("AppKit/AppKit.h");
});

const math = @import("../utils/math.zig");
const mesh = @import("mesh.zig");

pub const MetalRenderer = struct {
    device: *c.MTLDevice,
    command_queue: *c.MTLCommandQueue,
    pipeline_state: *c.MTLRenderPipelineState,
    depth_stencil_state: *c.MTLDepthStencilState,

    allocator: std.mem.Allocator,

    /// Initialize the Metal renderer
    pub fn init(allocator: std.mem.Allocator) !MetalRenderer {
        // Get default Metal device
        const device = c.MTLCreateSystemDefaultDevice() orelse {
            return error.NoMetalDevice;
        };

        // Create command queue
        const command_queue = c.MTLDevice_newCommandQueue(device) orelse {
            return error.FailedToCreateCommandQueue;
        };

        // For now, we'll create the pipeline state and depth stencil state later
        // when we have the actual shader library loaded

        return MetalRenderer{
            .device = device,
            .command_queue = command_queue,
            .pipeline_state = undefined, // Will be set later
            .depth_stencil_state = undefined, // Will be set later
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        _ = self;
        // Metal uses ARC, objects are automatically released
    }

    /// Create render pipeline state from shader source
    pub fn createPipelineState(
        self: *MetalRenderer,
        vertex_shader: []const u8,
        fragment_shader: []const u8,
    ) !void {
        _ = self;
        _ = vertex_shader;
        _ = fragment_shader;
        // TODO: Implement shader compilation and pipeline state creation
    }

    /// Begin a render pass
    pub fn beginRenderPass(
        self: *MetalRenderer,
        drawable: *c.CAMetalDrawable,
        clear_color: [4]f32,
    ) !*c.MTLRenderCommandEncoder {
        const command_buffer = c.MTLCommandQueue_commandBuffer(self.command_queue) orelse {
            return error.FailedToCreateCommandBuffer;
        };

        // Create render pass descriptor
        const render_pass_descriptor = c.MTLRenderPassDescriptor_new() orelse {
            return error.FailedToCreateRenderPassDescriptor;
        };

        // Configure color attachment
        const color_attachment = c.MTLRenderPassDescriptor_colorAttachments(render_pass_descriptor, 0);
        c.MTLRenderPassColorAttachmentDescriptor_setTexture(color_attachment, drawable.texture);
        c.MTLRenderPassColorAttachmentDescriptor_setLoadAction(color_attachment, c.MTLLoadActionClear);
        c.MTLRenderPassColorAttachmentDescriptor_setStoreAction(color_attachment, c.MTLStoreActionStore);
        c.MTLRenderPassColorAttachmentDescriptor_setClearColor(
            color_attachment,
            .{ .red = clear_color[0], .green = clear_color[1], .blue = clear_color[2], .alpha = clear_color[3] },
        );

        const encoder = c.MTLCommandBuffer_renderCommandEncoderWithDescriptor(
            command_buffer,
            render_pass_descriptor,
        ) orelse {
            return error.FailedToCreateRenderEncoder;
        };

        return encoder;
    }

    /// End render pass and present
    pub fn endRenderPass(
        self: *MetalRenderer,
        encoder: *c.MTLRenderCommandEncoder,
        command_buffer: *c.MTLCommandBuffer,
        drawable: *c.CAMetalDrawable,
    ) void {
        _ = self;
        c.MTLRenderCommandEncoder_endEncoding(encoder);
        c.MTLCommandBuffer_presentDrawable(command_buffer, drawable);
        c.MTLCommandBuffer_commit(command_buffer);
    }
};

/// GPU vertex format for chunk rendering
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    tex_coord: [2]f32,
    color: [4]f32,
};

/// Uniform buffer for MVP matrices
pub const Uniforms = extern struct {
    model_view_projection: [16]f32,
    model: [16]f32,
    view: [16]f32,
    projection: [16]f32,
    sun_direction: [4]f32,
    sun_color: [4]f32,
    ambient_color: [4]f32,
    sky_color: [4]f32,
    camera_position: [4]f32,
    fog_params: [4]f32,
};
