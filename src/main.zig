const std = @import("std");
const terrain = @import("terrain.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Open World Game - Starting...\n", .{});

    // Initialize terrain system
    var world = try terrain.World.init(allocator, 256, 256);
    defer world.deinit();

    std.debug.print("World initialized: {}x{} chunks\n", .{ world.width, world.height });

    // Main game loop placeholder
    const running = true;
    var frame: u32 = 0;

    while (running and frame < 5) : (frame += 1) {
        // Update
        try world.update();

        // Render (placeholder)
        std.debug.print("Frame {}: Rendering world...\n", .{frame});

        // For now, just run a few frames to demonstrate
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    std.debug.print("Open World Game - Shutting down...\n", .{});
}

test "basic test" {
    try std.testing.expectEqual(42, 42);
}
