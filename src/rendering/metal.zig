const std = @import("std");

// C API from metal_bridge.m
extern fn metal_create_context(sdl_metal_view: *anyopaque) ?*anyopaque;
extern fn metal_destroy_context(ctx: *anyopaque) void;
extern fn metal_render_frame(ctx: *anyopaque, r: f32, g: f32, b: f32) bool;
extern fn metal_get_device_name(ctx: *anyopaque) [*:0]const u8;

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
};
