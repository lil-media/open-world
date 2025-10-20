const std = @import("std");
const demo = @import("demo.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run the enhanced interactive demo with visualization
    try demo.runInteractiveDemo(allocator, .{});
}
