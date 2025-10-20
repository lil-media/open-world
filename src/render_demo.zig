const std = @import("std");
const demo = @import("demo.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = demo.DemoOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--max-frames")) {
            if (i + 1 >= args.len) break;
            const value = try std.fmt.parseInt(u32, args[i + 1], 10);
            options.max_frames = if (value == 0) null else value;
            i += 1;
        }
    }

    try demo.runInteractiveDemo(allocator, options);
}
