const std = @import("std");

// C API from metal_bridge.m
extern fn metal_create_context(sdl_metal_view: *anyopaque) ?*anyopaque;
extern fn metal_destroy_context(ctx: *anyopaque) void;
extern fn metal_render_frame(ctx: *anyopaque, r: f32, g: f32, b: f32) bool;
extern fn metal_get_device_name(ctx: *anyopaque) [*:0]const u8;
extern fn metal_create_pipeline(
    ctx: *anyopaque,
    source: [*]const u8,
    source_len: usize,
    vertex_name: [*]const u8,
    vertex_len: usize,
    fragment_name: [*]const u8,
    fragment_len: usize,
    vertex_stride: usize,
) bool;
extern fn metal_set_mesh(
    ctx: *anyopaque,
    vertices: *const anyopaque,
    vertex_count: usize,
    vertex_stride: usize,
    indices: *const u32,
    index_count: usize,
) bool;
extern fn metal_set_uniforms(ctx: *anyopaque, uniforms: *const anyopaque, size: usize) bool;
extern fn metal_draw(ctx: *anyopaque, clear_color: *const f32) bool;
extern fn metal_set_texture(ctx: *anyopaque, data: [*]const u8, width: usize, height: usize, bytes_per_row: usize) bool;

pub const MetalContext = struct {
    ctx: *anyopaque,

    pub fn init(sdl_metal_view: *anyopaque) !MetalContext {
        const ctx = metal_create_context(sdl_metal_view) orelse {
            return error.FailedToCreateMetalContext;
        };

        return MetalContext{ .ctx = ctx };
    }

    pub fn deinit(self: *MetalContext) void {
        metal_destroy_context(self.ctx);
    }

    pub fn renderFrame(self: *MetalContext, r: f32, g: f32, b: f32) bool {
        return metal_render_frame(self.ctx, r, g, b);
    }

    pub fn getDeviceName(self: *MetalContext) []const u8 {
        const name_ptr = metal_get_device_name(self.ctx);
        return std.mem.span(name_ptr);
    }

    pub fn createPipeline(
        self: *MetalContext,
        source: []const u8,
        vertex_name: []const u8,
        fragment_name: []const u8,
        vertex_stride: usize,
    ) !void {
        if (source.len == 0) return error.InvalidShaderSource;
        if (!metal_create_pipeline(
            self.ctx,
            source.ptr,
            source.len,
            vertex_name.ptr,
            vertex_name.len,
            fragment_name.ptr,
            fragment_name.len,
            vertex_stride,
        )) {
            return error.PipelineCreationFailed;
        }
    }

    pub fn setMesh(
        self: *MetalContext,
        vertex_data: []const u8,
        vertex_stride: usize,
        indices: []const u32,
    ) !void {
        if (vertex_data.len == 0 or indices.len == 0 or vertex_stride == 0) return error.InvalidMeshData;
        if (vertex_data.len % vertex_stride != 0) return error.InvalidMeshData;
        const vertex_count = vertex_data.len / vertex_stride;
        const index_ptr: *const u32 = @ptrCast(indices.ptr);
        if (!metal_set_mesh(
            self.ctx,
            vertex_data.ptr,
            vertex_count,
            vertex_stride,
            index_ptr,
            indices.len,
        )) {
            return error.MeshUploadFailed;
        }
    }

    pub fn setUniforms(self: *MetalContext, uniforms: []const u8) !void {
        if (uniforms.len == 0) return error.InvalidUniformData;
        if (!metal_set_uniforms(self.ctx, uniforms.ptr, uniforms.len)) {
            return error.UniformUploadFailed;
        }
    }

    pub fn draw(self: *MetalContext, clear_color: [4]f32) !void {
        if (!metal_draw(self.ctx, &clear_color[0])) {
            return error.DrawFailed;
        }
    }

    pub fn setTexture(self: *MetalContext, data: []const u8, width: usize, height: usize, bytes_per_row: usize) !void {
        if (data.len == 0 or width == 0 or height == 0 or bytes_per_row == 0) {
            return error.InvalidTextureData;
        }
        if (!metal_set_texture(self.ctx, data.ptr, width, height, bytes_per_row)) {
            return error.TextureUploadFailed;
        }
    }
};
