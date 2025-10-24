const std = @import("std");
const ascii = std.ascii;
const demo = @import("demo.zig");
const persistence = @import("terrain/persistence.zig");

const ParseDifficultyError = error{InvalidDifficulty};

fn parseDifficulty(value: []const u8) ParseDifficultyError!persistence.Difficulty {
    if (ascii.eqlIgnoreCase(value, "peaceful")) return .peaceful;
    if (ascii.eqlIgnoreCase(value, "easy")) return .easy;
    if (ascii.eqlIgnoreCase(value, "normal")) return .normal;
    if (ascii.eqlIgnoreCase(value, "hard")) return .hard;
    return error.InvalidDifficulty;
}

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
        } else if (std.mem.eql(u8, arg, "--difficulty")) {
            if (i + 1 >= args.len) break;
            options.world_difficulty = parseDifficulty(args[i + 1]) catch {
                std.debug.print("Unknown difficulty '{s}'. Use peaceful|easy|normal|hard.\n", .{args[i + 1]});
                return error.InvalidDifficulty;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--description")) {
            if (i + 1 >= args.len) break;
            options.world_description = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--list-worlds")) {
            list_worlds = true;
        } else if (std.mem.eql(u8, arg, "--worlds-root")) {
            if (i + 1 >= args.len) break;
            options.worlds_root = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            if (i + 1 >= args.len) break;
            options.scenario = demo.parseScenario(args[i + 1]) catch {
                std.debug.print("Unknown scenario '{s}'. Supported: lod-sweep\n", .{args[i + 1]});
                return error.InvalidScenario;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scenario-dir")) {
            if (i + 1 >= args.len) break;
            options.scenario_output = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scenario-settle")) {
            if (i + 1 >= args.len) break;
            options.scenario_settle_frames = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--profile-log")) {
            if (i + 1 >= args.len) break;
            options.profile_log = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--profile-frames")) {
            if (i + 1 >= args.len) break;
            options.profile_frames = try std.fmt.parseInt(u32, args[i + 1], 10);
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
                const desc_preview = if (info.description.len > 0) info.description else "-";
                std.debug.print(
                    " - {s} (seed: {d}, difficulty: {s}, last played: {d})\n     \t{s}\n",
                    .{ info.name, info.seed, persistence.difficultyLabel(info.difficulty), info.last_played_timestamp, desc_preview },
                );
            }
        }
        return;
    }

    if (options.profile_log) |_| {
        try demo.runHeadlessProfile(allocator, options);
        return;
    }

    try demo.runInteractiveDemo(allocator, options);
}
