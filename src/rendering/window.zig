const std = @import("std");
const c = @cImport({
    @cInclude("AppKit/AppKit.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
    @cInclude("Metal/Metal.h");
});

pub const Window = struct {
    ns_window: *c.NSWindow,
    metal_layer: *c.CAMetalLayer,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32, title: [*:0]const u8) !Window {
        // Initialize AppKit (required for GUI apps)
        _ = c.NSApplicationLoad();

        // Create window rect
        const content_rect = c.NSMakeRect(0, 0, @floatFromInt(width), @floatFromInt(height));

        // Create window
        const style_mask = c.NSWindowStyleMaskTitled |
            c.NSWindowStyleMaskClosable |
            c.NSWindowStyleMaskResizable;

        const ns_window = c.NSWindow_alloc();
        _ = c.NSWindow_initWithContentRect(
            ns_window,
            content_rect,
            style_mask,
            c.NSBackingStoreBuffered,
            false,
        );

        if (ns_window == null) {
            return error.FailedToCreateWindow;
        }

        // Set window title
        const ns_title = c.NSString_stringWithUTF8String(title);
        c.NSWindow_setTitle(ns_window, ns_title);

        // Center window
        c.NSWindow_center(ns_window);

        // Create Metal layer
        const metal_layer = c.CAMetalLayer_layer();
        if (metal_layer == null) {
            return error.FailedToCreateMetalLayer;
        }

        // Get Metal device
        const device = c.MTLCreateSystemDefaultDevice();
        if (device == null) {
            return error.NoMetalDevice;
        }

        // Configure Metal layer
        c.CAMetalLayer_setDevice(metal_layer, device);
        c.CAMetalLayer_setPixelFormat(metal_layer, c.MTLPixelFormatBGRA8Unorm);
        c.CAMetalLayer_setFramebufferOnly(metal_layer, true);

        // Set layer as window's content view layer
        const content_view = c.NSWindow_contentView(ns_window);
        c.NSView_setWantsLayer(content_view, true);
        c.NSView_setLayer(content_view, @ptrCast(metal_layer));

        // Make window key and order front
        c.NSWindow_makeKeyAndOrderFront(ns_window, null);

        return Window{
            .ns_window = ns_window,
            .metal_layer = metal_layer,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Window) void {
        c.NSWindow_close(self.ns_window);
    }

    /// Get next drawable from Metal layer
    pub fn nextDrawable(self: *Window) ?*c.CAMetalDrawable {
        return c.CAMetalLayer_nextDrawable(self.metal_layer);
    }

    /// Check if window should close
    pub fn shouldClose(self: *Window) bool {
        // For now, we'll just run for a fixed time
        // TODO: Implement proper event handling
        _ = self;
        return false;
    }

    /// Update window size
    pub fn updateSize(self: *Window) void {
        const content_view = c.NSWindow_contentView(self.ns_window);
        const bounds = c.NSView_bounds(content_view);
        self.width = @intFromFloat(bounds.size.width);
        self.height = @intFromFloat(bounds.size.height);

        // Update Metal layer drawable size
        c.CAMetalLayer_setDrawableSize(
            self.metal_layer,
            .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) },
        );
    }

    /// Process events (non-blocking)
    pub fn pollEvents() void {
        const app = c.NSApplication_sharedApplication();
        while (true) {
            const event = c.NSApplication_nextEventMatchingMask(
                app,
                c.NSEventMaskAny,
                null,
                c.NSEventTrackingRunLoopMode,
                true,
            );

            if (event == null) break;

            c.NSApplication_sendEvent(app, event);
        }
    }
};
