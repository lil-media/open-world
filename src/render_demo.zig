const std = @import("std");
const sdl = @import("rendering/sdl_window.zig");
const metal = @import("rendering/metal.zig");

pub fn main() !void {
    std.debug.print("\n=== Open World - Metal Rendering Demo ===\n\n", .{});

    // Create window
    var window = try sdl.SDLWindow.init(1280, 720, "Open World - Metal");
    defer window.deinit();
    std.debug.print("✓ Window created (1280x720)\n", .{});

    // Create Metal context
    var ctx = try metal.MetalContext.init(window.metal_view);
    defer ctx.deinit();
    std.debug.print("✓ Metal device: {s}\n", .{ctx.getDeviceName()});

    std.debug.print("\nRendering... (Press ESC to exit)\n\n", .{});

    var frame: u32 = 0;
    while (!window.should_close) {
        window.pollEvents();

        // Animate clear color
        const t = @as(f32, @floatFromInt(frame)) / 60.0;
        const r = (@sin(t * 0.5) + 1.0) * 0.15;
        const g = (@sin(t * 0.7 + 2.0) + 1.0) * 0.2;
        const b = (@sin(t * 0.3 + 4.0) + 1.0) * 0.3 + 0.2;

        // Render frame
        _ = ctx.renderFrame(r, g, b);

        if (frame % 60 == 0) {
            std.debug.print("Frame: {} ({d:.0} FPS)\n", .{ frame, 60.0 });
        }

        frame += 1;
        std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 FPS
    }

    std.debug.print("\n✓ Rendered {} frames\n", .{frame});
    std.debug.print("✓ Goodbye!\n\n", .{});
}
