const std = @import("std");
const demo = @import("demo.zig");
const persistence = @import("terrain/persistence.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = demo.DemoOptions{};
    var list_worlds = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--max-frames")) {
            if (i + 1 >= args.len) break;
            const value = try std.fmt.parseInt(u32, args[i + 1], 10);
            options.max_frames = if (value == 0) null else value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--world")) {
            if (i + 1 >= args.len) break;
            options.world_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            if (i + 1 >= args.len) break;
            options.world_seed = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--new-world")) {
            options.force_new_world = true;
        } else if (std.mem.eql(u8, arg, "--list-worlds")) {
            list_worlds = true;
        } else if (std.mem.eql(u8, arg, "--worlds-root")) {
            if (i + 1 >= args.len) break;
            options.worlds_root = args[i + 1];
            i += 1;
        }
    }

    if (list_worlds) {
        const infos = try persistence.WorldPersistence.listWorlds(allocator, options.worlds_root);
        defer persistence.WorldPersistence.freeWorldInfoList(allocator, infos);

        if (infos.len == 0) {
            std.debug.print("No worlds found under '{s}'.\n", .{options.worlds_root});
        } else {
            std.debug.print("Available worlds ({s}):\n", .{options.worlds_root});
            for (infos) |info| {
                std.debug.print(" - {s} (seed: {d}, last played: {d})\n", .{ info.name, info.seed, info.last_played_timestamp });
            }
        }
        return;
    }

    try demo.runInteractiveDemo(allocator, options);
}
