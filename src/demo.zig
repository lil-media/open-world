const std = @import("std");
const terrain = @import("terrain/terrain.zig");
const generator = @import("terrain/generator.zig");
const streaming = @import("terrain/streaming.zig");
const persistence = @import("terrain/persistence.zig");
const camera = @import("rendering/camera.zig");
const mesh = @import("rendering/mesh.zig");
const player = @import("physics/player.zig");
const math = @import("utils/math.zig");
const viz = @import("utils/visualization.zig");
const sdl = @import("rendering/sdl_window.zig");
const metal = @import("rendering/metal.zig");
const input = @import("platform/input.zig");
const metal_renderer = @import("rendering/metal_renderer.zig");
const textures = @import("assets/texture_gen.zig");
const raycast = @import("utils/raycast.zig");
const line_text = @import("ui/line_text.zig");

const default_world_name = "default_world";
const autosave_default_presets = [_]u32{ 0, 15, 30, 60, 120 };
const backup_default_presets = [_]usize{ 1, 2, 3, 5, 8, 12, 16 };

pub const DemoOptions = struct {
    max_frames: ?u32 = null,
    world_name: []const u8 = default_world_name,
    world_seed: ?u64 = null,
    force_new_world: bool = false,
    worlds_root: []const u8 = persistence.default_worlds_root,
};

const WorldSelectionResult = struct {
    name: []u8,
    seed: ?u64,
    force_new: bool,
};

fn generateRandomSeed() u64 {
    const ns = std.time.nanoTimestamp();
    const abs_ns: u128 = if (ns < 0) @intCast(-ns) else @intCast(ns);
    const base_seed: u64 = @truncate(abs_ns);
    var prng = std.Random.DefaultPrng.init(base_seed ^ 0x9E3779B97F4A7C15);
    return prng.random().int(u64);
}

fn formatTimestamp(buffer: []u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "never";
    return std.fmt.bufPrint(buffer, "{d}", .{timestamp}) catch "invalid";
}

fn generateUniqueWorldName(allocator: std.mem.Allocator, worlds_root: []const u8) ![]u8 {
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        const timestamp = std.time.timestamp();
        const name = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "world-{d}", .{timestamp})
        else
            try std.fmt.allocPrint(allocator, "world-{d}-{d}", .{ timestamp, attempt });
        const exists = try persistence.WorldPersistence.worldExists(allocator, worlds_root, name);
        if (!exists) {
            return name;
        }
        allocator.free(name);
    }
    return error.WorldNameGenerationFailed;
}

fn deleteWorldDirectory(allocator: std.mem.Allocator, worlds_root: []const u8, world_name: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, world_name });
    defer allocator.free(path);

    std.fs.cwd().deleteTree(path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Failed to delete world '{s}': {any}\n", .{ world_name, err });
        }
    };
}

fn sanitizeWorldName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var cleaned = std.ArrayListUnmanaged(u8){};
    errdefer cleaned.deinit(allocator);

    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
            try cleaned.append(allocator, std.ascii.toUpper(ch));
        } else if (ch == ' ') {
            try cleaned.append(allocator, '_');
        }
    }

    if (cleaned.items.len == 0) {
        return error.InvalidWorldName;
    }

    return cleaned.toOwnedSlice(allocator);
}

fn promptLine(buffer: []u8) ![]u8 {
    const stdin_file = std.fs.File.stdin();
    const read_len = try stdin_file.read(buffer);
    const slice = buffer[0..read_len];

    var start: usize = 0;
    while (start < slice.len and isWhitespace(slice[start])) : (start += 1) {}

    var end = slice.len;
    while (end > start and isWhitespace(slice[end - 1])) : (end -= 1) {}

    return buffer[start..end];
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn renameWorldInteractive(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    current_name: []const u8,
) !bool {
    std.debug.print("Rename world '{s}' -> ", .{current_name});
    var input_buf: [256]u8 = undefined;
    const raw = try promptLine(&input_buf);
    if (raw.len == 0) return false;

    const sanitized = sanitizeWorldName(allocator, raw) catch |err| {
        std.debug.print("Invalid name: {any}\n", .{err});
        return false;
    };
    defer allocator.free(sanitized);

    if (std.mem.eql(u8, sanitized, current_name)) {
        std.debug.print("Name unchanged.\n", .{});
        return false;
    }

    const exists = try persistence.WorldPersistence.worldExists(allocator, worlds_root, sanitized);
    if (exists) {
        std.debug.print("World '{s}' already exists.\n", .{sanitized});
        return false;
    }

    const old_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, current_name });
    defer allocator.free(old_path);
    const new_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, sanitized });
    defer allocator.free(new_path);

    std.fs.cwd().rename(old_path, new_path) catch |err| {
        std.debug.print("Failed to rename world: {any}\n", .{err});
        return false;
    };

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, sanitized });
    defer allocator.free(meta_path);

    var metadata = try persistence.WorldPersistence.loadMetadata(allocator, worlds_root, sanitized);
    defer metadata.deinit(allocator);

    allocator.free(metadata.name);
    metadata.name = try allocator.dupe(u8, sanitized);
    metadata.last_played_timestamp = std.time.timestamp();
    try metadata.save(allocator, meta_path);

    std.debug.print("World renamed to '{s}'.\n", .{sanitized});
    return true;
}

fn updateWorldSeedInteractive(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
) !bool {
    std.debug.print("Enter new seed for '{s}' (blank = random): ", .{world_name});
    var input_buf: [64]u8 = undefined;
    const raw = try promptLine(&input_buf);

    var new_seed: u64 = undefined;
    if (raw.len == 0) {
        new_seed = generateRandomSeed();
    } else {
        new_seed = std.fmt.parseInt(u64, raw, 10) catch |err| {
            std.debug.print("Invalid seed: {any}\n", .{err});
            return false;
        };
    }

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, world_name });
    defer allocator.free(meta_path);

    var metadata = try persistence.WorldPersistence.loadMetadata(allocator, worlds_root, world_name);
    defer metadata.deinit(allocator);

    metadata.seed = new_seed;
    metadata.last_played_timestamp = std.time.timestamp();
    try metadata.save(allocator, meta_path);

    std.debug.print("Seed updated for '{s}' -> {d}.\n", .{ world_name, new_seed });
    return true;
}

fn showWorldSelectionMenu(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    window: *sdl.SDLWindow,
    metal_ctx: *metal.MetalContext,
    input_state: *input.InputState,
) !?WorldSelectionResult {
    defer {
        metal_ctx.setLineMesh(&[_]u8{}, @sizeOf(metal_renderer.Vertex)) catch {};
        metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex)) catch {};
    }

    var infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
    defer persistence.WorldPersistence.freeWorldInfoList(allocator, infos);

    if (infos.len == 0) {
        const name = try generateUniqueWorldName(allocator, worlds_root);
        const seed = generateRandomSeed();
        std.debug.print("No existing worlds found. Creating '{s}' (seed {d}).\n", .{ name, seed });
        return WorldSelectionResult{
            .name = name,
            .seed = seed,
            .force_new = true,
        };
    }

    var selection: usize = 0;
    var confirm_delete: ?usize = null;
    var status_message: []const u8 = "";
    var status_timer: f32 = 0;
    var status_buffer: [128]u8 = undefined;
    var last_settings_selection: ?usize = null;
    var selected_settings = persistence.WorldSettingsSummary{
        .autosave_interval_seconds = persistence.default_autosave_interval_seconds,
        .backup_retention = persistence.default_region_backup_retention,
        .last_backup_timestamp = 0,
    };

    if (window.cursor_locked) {
        window.setCursorLocked(false);
    }

    if (selection < infos.len) {
        selected_settings = persistence.loadWorldSettingsSummary(allocator, worlds_root, infos[selection].name) catch |err| blk: {
            std.debug.print("Failed to load settings for world '{s}': {any}\n", .{ infos[selection].name, err });
            break :blk persistence.WorldSettingsSummary{
                .autosave_interval_seconds = persistence.default_autosave_interval_seconds,
                .backup_retention = persistence.default_region_backup_retention,
                .last_backup_timestamp = 0,
            };
        };
        last_settings_selection = selection;
    }

    const frame_dt: f32 = 1.0 / 60.0;

    while (true) {
        input_state.beginFrame();
        window.pollEvents(input_state);

        if (window.should_close) {
            return null;
        }

        if (status_timer > 0) {
            status_timer -= frame_dt;
            if (status_timer <= 0) {
                status_timer = 0;
                status_message = "";
            }
        }

        const option_count: usize = infos.len + 1;

        if (input_state.wasKeyPressed(.down)) {
            selection = (selection + 1) % option_count;
            confirm_delete = null;
            last_settings_selection = null;
        } else if (input_state.wasKeyPressed(.up)) {
            selection = (selection + option_count - 1) % option_count;
            confirm_delete = null;
            last_settings_selection = null;
        }

        if (input_state.wasKeyPressed(.escape)) {
            window.should_close = true;
            return null;
        }

        if (selection < infos.len) {
            if (last_settings_selection == null or last_settings_selection.? != selection) {
                selected_settings = persistence.loadWorldSettingsSummary(allocator, worlds_root, infos[selection].name) catch |err| blk: {
                    std.debug.print("Failed to load settings for world '{s}': {any}\n", .{ infos[selection].name, err });
                    break :blk persistence.WorldSettingsSummary{
                        .autosave_interval_seconds = persistence.default_autosave_interval_seconds,
                        .backup_retention = persistence.default_region_backup_retention,
                        .last_backup_timestamp = 0,
                    };
                };
                last_settings_selection = selection;
            }
        } else {
            last_settings_selection = null;
        }

        if (selection < infos.len and input_state.wasKeyPressed(.r)) {
            if (try renameWorldInteractive(allocator, worlds_root, infos[selection].name)) {
                persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                if (selection >= infos.len) selection = infos.len - 1;
                last_settings_selection = null;
                status_message = "RENAMED WORLD";
                status_timer = 3.0;
            } else {
                status_message = "RENAME FAILED";
                status_timer = 3.0;
            }
            confirm_delete = null;
            continue;
        }

        if (selection < infos.len and input_state.wasKeyPressed(.s)) {
            if (try updateWorldSeedInteractive(allocator, worlds_root, infos[selection].name)) {
                persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                last_settings_selection = null;
                status_message = "SEED UPDATED";
                status_timer = 3.0;
            } else {
                status_message = "SEED UPDATE FAILED";
                status_timer = 3.0;
            }
            confirm_delete = null;
            continue;
        }

        const delete_pressed = input_state.wasKeyPressed(.delete) or input_state.wasKeyPressed(.backspace);
        if (selection < infos.len and (delete_pressed or input_state.wasKeyPressed(.x))) {
            if (confirm_delete) |idx_confirm| {
                if (idx_confirm == selection) {
                    const target = infos[selection].name;
                    deleteWorldDirectory(allocator, worlds_root, target) catch |err| {
                        std.debug.print("Failed to delete world '{s}': {any}\n", .{ target, err });
                        status_message = "DELETE FAILED";
                        status_timer = 3.0;
                        confirm_delete = null;
                        continue;
                    };
                    persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                    infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                    if (infos.len == 0) {
                        const name = try generateUniqueWorldName(allocator, worlds_root);
                        const seed = generateRandomSeed();
                        std.debug.print("All worlds deleted. Creating '{s}' (seed {d}).\n", .{ name, seed });
                        return WorldSelectionResult{
                            .name = name,
                            .seed = seed,
                            .force_new = true,
                        };
                    }
                    if (selection >= infos.len) selection = infos.len - 1;
                    last_settings_selection = null;
                    status_message = "WORLD DELETED";
                    status_timer = 3.0;
                    confirm_delete = null;
                } else {
                    confirm_delete = selection;
                    status_message = "PRESS DELETE AGAIN TO CONFIRM";
                    status_timer = 3.0;
                }
            } else {
                confirm_delete = selection;
                status_message = "PRESS DELETE AGAIN TO CONFIRM";
                status_timer = 3.0;
            }
            continue;
        }

        if (selection < infos.len) {
            const world_name = infos[selection].name;

            if (input_state.wasKeyPressed(.f5)) {
                const current_interval = selected_settings.autosave_interval_seconds;
                var candidates: [autosave_default_presets.len + 1]u32 = undefined;
                var cand_len: usize = 0;
                inline for (autosave_default_presets) |preset| {
                    candidates[cand_len] = preset;
                    cand_len += 1;
                }
                var has_current = false;
                var ci: usize = 0;
                while (ci < cand_len) : (ci += 1) {
                    if (candidates[ci] == current_interval) {
                        has_current = true;
                        break;
                    }
                }
                if (!has_current) {
                    candidates[cand_len] = current_interval;
                    cand_len += 1;
                }
                std.sort.heap(u32, candidates[0..cand_len], {}, struct {
                    fn lessThan(_: void, lhs: u32, rhs: u32) bool {
                        return lhs < rhs;
                    }
                }.lessThan);
                var unique: [autosave_default_presets.len + 1]u32 = undefined;
                var unique_len: usize = 0;
                var have_prev = false;
                var prev: u32 = 0;
                var ui: usize = 0;
                while (ui < cand_len) : (ui += 1) {
                    const value = candidates[ui];
                    if (!have_prev or value != prev) {
                        unique[unique_len] = value;
                        unique_len += 1;
                        prev = value;
                        have_prev = true;
                    }
                }
                if (unique_len > 0) {
                    var current_idx: usize = 0;
                    for (unique[0..unique_len], 0..) |value, idx| {
                        if (value == current_interval) {
                            current_idx = idx;
                            break;
                        }
                    }
                    const next_idx = (current_idx + 1) % unique_len;
                    const new_interval = unique[next_idx];
                    const autosave_success = blk: {
                        persistence.setWorldAutosaveInterval(allocator, worlds_root, world_name, new_interval) catch |err| {
                            std.debug.print("Failed to update autosave interval for '{s}': {any}\n", .{ world_name, err });
                            status_message = "AUTOSAVE UPDATE FAILED";
                            status_timer = 3.0;
                            break :blk false;
                        };
                        break :blk true;
                    };
                    if (autosave_success) {
                        selected_settings.autosave_interval_seconds = new_interval;
                        status_message = if (new_interval == 0)
                            "AUTOSAVE OFF"
                        else
                            std.fmt.bufPrint(&status_buffer, "AUTOSAVE EVERY {d}s", .{new_interval}) catch "AUTOSAVE UPDATED";
                        status_timer = 3.0;
                        std.debug.print("World '{s}' autosave interval set to {d} seconds.\n", .{ world_name, new_interval });
                    }
                }
            }

            if (input_state.wasKeyPressed(.f7)) {
                const current_retention = selected_settings.backup_retention;
                var candidates: [backup_default_presets.len + 1]usize = undefined;
                var cand_len: usize = 0;
                inline for (backup_default_presets) |preset| {
                    candidates[cand_len] = preset;
                    cand_len += 1;
                }
                var has_current = false;
                var ri: usize = 0;
                while (ri < cand_len) : (ri += 1) {
                    if (candidates[ri] == current_retention) {
                        has_current = true;
                        break;
                    }
                }
                if (!has_current) {
                    candidates[cand_len] = current_retention;
                    cand_len += 1;
                }
                std.sort.heap(usize, candidates[0..cand_len], {}, struct {
                    fn lessThan(_: void, lhs: usize, rhs: usize) bool {
                        return lhs < rhs;
                    }
                }.lessThan);
                var unique: [backup_default_presets.len + 1]usize = undefined;
                var unique_len: usize = 0;
                var prev: usize = 0;
                var have_prev = false;
                var uj: usize = 0;
                while (uj < cand_len) : (uj += 1) {
                    const value = candidates[uj];
                    if (!have_prev or value != prev) {
                        unique[unique_len] = value;
                        unique_len += 1;
                        prev = value;
                        have_prev = true;
                    }
                }
                if (unique_len > 0) {
                    var current_idx: usize = 0;
                    for (unique[0..unique_len], 0..) |value, idx| {
                        if (value == current_retention) {
                            current_idx = idx;
                            break;
                        }
                    }
                    const next_idx = if (current_idx + 1 < unique_len) current_idx + 1 else current_idx;
                    if (next_idx == current_idx) {
                        status_message = "BACKUPS MAX";
                        status_timer = 2.5;
                    } else {
                        const new_retention = unique[next_idx];
                        const backup_success = blk: {
                            persistence.setWorldBackupRetention(allocator, worlds_root, world_name, new_retention) catch |err| {
                                std.debug.print("Failed to update backups retention for '{s}': {any}\n", .{ world_name, err });
                                status_message = "BACKUPS UPDATE FAILED";
                                status_timer = 3.0;
                                break :blk false;
                            };
                            break :blk true;
                        };
                        if (backup_success) {
                            selected_settings.backup_retention = new_retention;
                            status_message = std.fmt.bufPrint(&status_buffer, "BACKUPS KEEP {d}", .{new_retention}) catch "BACKUPS UPDATED";
                            status_timer = 3.0;
                            std.debug.print("World '{s}' backup retention set to {d}.\n", .{ world_name, new_retention });
                        }
                    }
                }
            } else if (input_state.wasKeyPressed(.f8)) {
                const current_retention = selected_settings.backup_retention;
                var candidates: [backup_default_presets.len + 1]usize = undefined;
                var cand_len: usize = 0;
                inline for (backup_default_presets) |preset| {
                    candidates[cand_len] = preset;
                    cand_len += 1;
                }
                var has_current = false;
                var ri: usize = 0;
                while (ri < cand_len) : (ri += 1) {
                    if (candidates[ri] == current_retention) {
                        has_current = true;
                        break;
                    }
                }
                if (!has_current) {
                    candidates[cand_len] = current_retention;
                    cand_len += 1;
                }
                std.sort.heap(usize, candidates[0..cand_len], {}, struct {
                    fn lessThan(_: void, lhs: usize, rhs: usize) bool {
                        return lhs < rhs;
                    }
                }.lessThan);
                var unique: [backup_default_presets.len + 1]usize = undefined;
                var unique_len: usize = 0;
                var prev: usize = 0;
                var have_prev = false;
                var uj: usize = 0;
                while (uj < cand_len) : (uj += 1) {
                    const value = candidates[uj];
                    if (!have_prev or value != prev) {
                        unique[unique_len] = value;
                        unique_len += 1;
                        prev = value;
                        have_prev = true;
                    }
                }
                if (unique_len > 0) {
                    var current_idx: usize = 0;
                    for (unique[0..unique_len], 0..) |value, idx| {
                        if (value == current_retention) {
                            current_idx = idx;
                            break;
                        }
                    }
                    const next_idx = if (current_idx > 0) current_idx - 1 else current_idx;
                    if (next_idx == current_idx) {
                        status_message = "BACKUPS MIN";
                        status_timer = 2.5;
                    } else {
                        const new_retention = unique[next_idx];
                        const backup_success = blk: {
                            persistence.setWorldBackupRetention(allocator, worlds_root, world_name, new_retention) catch |err| {
                                std.debug.print("Failed to update backups retention for '{s}': {any}\n", .{ world_name, err });
                                status_message = "BACKUPS UPDATE FAILED";
                                status_timer = 3.0;
                                break :blk false;
                            };
                            break :blk true;
                        };
                        if (backup_success) {
                            selected_settings.backup_retention = new_retention;
                            status_message = std.fmt.bufPrint(&status_buffer, "BACKUPS KEEP {d}", .{new_retention}) catch "BACKUPS UPDATED";
                            status_timer = 3.0;
                            std.debug.print("World '{s}' backup retention set to {d}.\n", .{ world_name, new_retention });
                        }
                    }
                }
            }

            if (input_state.wasKeyPressed(.f9)) {
                const reset_success = blk: {
                    persistence.resetWorldSettings(allocator, worlds_root, world_name) catch |err| {
                        std.debug.print("Failed to reset settings for '{s}': {any}\n", .{ world_name, err });
                        status_message = "RESET FAILED";
                        status_timer = 3.0;
                        break :blk false;
                    };
                    break :blk true;
                };
                if (reset_success) {
                    selected_settings = persistence.loadWorldSettingsSummary(allocator, worlds_root, world_name) catch |err| blk2: {
                        std.debug.print("Failed to reload settings for '{s}': {any}\n", .{ world_name, err });
                        break :blk2 persistence.WorldSettingsSummary{
                            .autosave_interval_seconds = persistence.default_autosave_interval_seconds,
                            .backup_retention = persistence.default_region_backup_retention,
                            .last_backup_timestamp = 0,
                        };
                    };
                    status_message = "SETTINGS RESET";
                    status_timer = 3.0;
                    std.debug.print("World '{s}' settings reset to defaults.\n", .{world_name});
                }
            }
        }

        if (input_state.wasKeyPressed(.enter)) {
            if (selection < infos.len) {
                const info = infos[selection];
                const name_copy = try allocator.dupe(u8, info.name);
                window.should_close = false;
                return WorldSelectionResult{
                    .name = name_copy,
                    .seed = info.seed,
                    .force_new = false,
                };
            } else {
                const name = try generateUniqueWorldName(allocator, worlds_root);
                const seed = generateRandomSeed();
                std.debug.print("Creating world '{s}' (seed {d})\n", .{ name, seed });
                window.should_close = false;
                return WorldSelectionResult{
                    .name = name,
                    .seed = seed,
                    .force_new = true,
                };
            }
        }

        var overlay_settings: ?persistence.WorldSettingsSummary = null;
        if (selection < infos.len) {
            if (last_settings_selection) |idx| {
                if (idx == selection) {
                    overlay_settings = selected_settings;
                }
            }
        }

        try renderWorldSelectionOverlay(
            allocator,
            metal_ctx,
            infos,
            selection,
            confirm_delete,
            status_message,
            overlay_settings,
            window.width,
            window.height,
        );

        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}

fn renderWorldSelectionOverlay(
    allocator: std.mem.Allocator,
    metal_ctx: *metal.MetalContext,
    infos: []persistence.WorldInfo,
    selection: usize,
    confirm_delete: ?usize,
    status_message: []const u8,
    selected_settings: ?persistence.WorldSettingsSummary,
    screen_width: u32,
    screen_height: u32,
) !void {
    var builder = std.ArrayListUnmanaged(line_text.UIVertex){};
    defer builder.deinit(allocator);

    const screen_size = math.Vec2.init(@floatFromInt(screen_width), @floatFromInt(screen_height));
    const text_scale: f32 = 2.0;
    const line_height = line_text.lineHeightPx(text_scale);
    const padding = 18.0;
    const origin_px = math.Vec2.init(48.0, 80.0);

    var max_width = line_text.textWidth("OPEN WORLD  SELECT SAVE", text_scale);
    var line_count: usize = 1;

    var buf: [128]u8 = undefined;
    var timestamp_buf: [48]u8 = undefined;
    for (infos, 0..) |info, idx| {
        const entry_text = std.fmt.bufPrint(&buf, "{s} {s} SEED {d}", .{ if (selection == idx) ">" else " ", info.name, info.seed }) catch "ENTRY";
        max_width = @max(max_width, line_text.textWidth(entry_text, text_scale));
        line_count += 1;
        if (selection == idx) {
            const detail_text = std.fmt.bufPrint(&buf, "LAST {d}", .{info.last_played_timestamp}) catch "DETAIL";
            max_width = @max(max_width, line_text.textWidth(detail_text, text_scale));
            line_count += 1;

            if (selected_settings) |settings| {
                const autosave_text = if (settings.autosave_interval_seconds == 0)
                    "AUTOSAVE: OFF"
                else
                    std.fmt.bufPrint(&buf, "AUTOSAVE: {d}s", .{settings.autosave_interval_seconds}) catch "AUTOSAVE";
                max_width = @max(max_width, line_text.textWidth(autosave_text, text_scale));
                line_count += 1;

                const retention_text = std.fmt.bufPrint(&buf, "BACKUPS: KEEP {d}", .{settings.backup_retention}) catch "BACKUPS";
                max_width = @max(max_width, line_text.textWidth(retention_text, text_scale));
                line_count += 1;

                const ts_str = formatTimestamp(&timestamp_buf, settings.last_backup_timestamp);
                const backup_last_text = std.fmt.bufPrint(&buf, "BACKUP: LAST {s}", .{ts_str}) catch "BACKUP LAST";
                max_width = @max(max_width, line_text.textWidth(backup_last_text, text_scale));
                line_count += 1;
            }

            if (confirm_delete) |idx_confirm| {
                if (idx_confirm == idx) {
                    max_width = @max(max_width, line_text.textWidth("CONFIRM DELETE", text_scale));
                    line_count += 1;
                }
            }
        }
    }

    max_width = @max(max_width, line_text.textWidth("CREATE NEW WORLD", text_scale));
    line_count += 1;

    if (status_message.len > 0) {
        max_width = @max(max_width, line_text.textWidth(status_message, text_scale));
        line_count += 1;
    }

    const instructions_primary = "ENTER PLAY  R RENAME  S SEED  DEL/BKSP DELETE  ESC QUIT";
    const instructions_secondary = "F5 CYCLE AUTOSAVE  F7/F8 BACKUPS  F9 RESET";
    max_width = @max(max_width, line_text.textWidth(instructions_primary, text_scale));
    line_count += 1;
    max_width = @max(max_width, line_text.textWidth(instructions_secondary, text_scale));
    line_count += 1;

    const panel_width = max_width + padding * 2.0;
    const panel_height = @as(f32, @floatFromInt(line_count)) * line_height + padding * 2.0;

    try line_text.appendQuad(
        &builder,
        allocator,
        origin_px,
        origin_px.add(math.Vec2.init(panel_width, panel_height)),
        screen_size,
        [4]f32{ 0.05, 0.07, 0.12, 0.88 },
    );

    var cursor = origin_px.add(math.Vec2.init(padding, padding));
    try line_text.appendText(&builder, allocator, "OPEN WORLD  SELECT SAVE", cursor, text_scale, screen_size, [4]f32{ 0.9, 0.95, 1.0, 1.0 });
    cursor.y += line_height;

    for (infos, 0..) |info, idx| {
        const entry_text = std.fmt.bufPrint(&buf, "{s} {s} SEED {d}", .{ if (selection == idx) ">" else " ", info.name, info.seed }) catch "ENTRY";
        try line_text.appendText(&builder, allocator, entry_text, cursor, text_scale, screen_size, if (selection == idx) [4]f32{ 1.0, 0.9, 0.3, 1.0 } else [4]f32{ 0.78, 0.82, 0.9, 1.0 });
        cursor.y += line_height;

        if (selection == idx) {
            const detail_text = std.fmt.bufPrint(&buf, "LAST {d}", .{info.last_played_timestamp}) catch "DETAIL";
            try line_text.appendText(&builder, allocator, detail_text, cursor, text_scale, screen_size, [4]f32{ 0.75, 0.88, 0.95, 1.0 });
            cursor.y += line_height;

            if (selected_settings) |settings| {
                const autosave_line = if (settings.autosave_interval_seconds == 0)
                    "AUTOSAVE: OFF"
                else
                    std.fmt.bufPrint(&buf, "AUTOSAVE: {d}s", .{settings.autosave_interval_seconds}) catch "AUTOSAVE";
                try line_text.appendText(&builder, allocator, autosave_line, cursor, text_scale, screen_size, [4]f32{ 0.72, 0.9, 1.0, 1.0 });
                cursor.y += line_height;

                const retention_line = std.fmt.bufPrint(&buf, "BACKUPS: KEEP {d}", .{settings.backup_retention}) catch "BACKUPS";
                try line_text.appendText(&builder, allocator, retention_line, cursor, text_scale, screen_size, [4]f32{ 0.68, 0.92, 0.78, 1.0 });
                cursor.y += line_height;

                const ts_str = formatTimestamp(&timestamp_buf, settings.last_backup_timestamp);
                const last_backup_line = std.fmt.bufPrint(&buf, "BACKUP: LAST {s}", .{ts_str}) catch "BACKUP LAST";
                try line_text.appendText(&builder, allocator, last_backup_line, cursor, text_scale, screen_size, [4]f32{ 0.8, 0.85, 1.0, 1.0 });
                cursor.y += line_height;
            }

            if (confirm_delete) |idx_confirm| {
                if (idx_confirm == idx) {
                    try line_text.appendText(&builder, allocator, "CONFIRM DELETE", cursor, text_scale, screen_size, [4]f32{ 1.0, 0.35, 0.35, 1.0 });
                    cursor.y += line_height;
                }
            }
        }
    }

    const create_color = if (selection == infos.len) [4]f32{ 0.6, 1.0, 0.7, 1.0 } else [4]f32{ 0.75, 0.82, 0.9, 1.0 };
    try line_text.appendText(&builder, allocator, "CREATE NEW WORLD", cursor, text_scale, screen_size, create_color);
    cursor.y += line_height;

    if (status_message.len > 0) {
        try line_text.appendText(&builder, allocator, status_message, cursor, text_scale, screen_size, [4]f32{ 0.95, 0.85, 0.6, 1.0 });
        cursor.y += line_height;
    }
    try line_text.appendText(&builder, allocator, instructions_primary, cursor, text_scale, screen_size, [4]f32{ 0.7, 0.85, 1.0, 1.0 });
    cursor.y += line_height;
    try line_text.appendText(&builder, allocator, instructions_secondary, cursor, text_scale, screen_size, [4]f32{ 0.65, 0.8, 1.0, 1.0 });

    if (builder.items.len == 0) {
        try metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex));
    } else {
        const bytes = std.mem.sliceAsBytes(builder.items);
        try metal_ctx.setUIMesh(bytes, @sizeOf(line_text.UIVertex));
    }

    try metal_ctx.draw(.{ 0.05, 0.08, 0.12, 1.0 });
}

const CachedMesh = struct {
    vertices: []metal_renderer.Vertex,
    indices: []u32,
    in_use: bool,
    selected: bool,
};

const MeshUpdateStats = struct {
    changed: bool,
    total_chunks: usize,
    visible_chunks: usize,
    rendered_chunks: usize,
    culled_chunks: usize,
    budget_skipped: usize,
    total_vertices: usize,
    total_indices: usize,
};

const max_render_chunks: usize = 96;
const max_vertex_budget: usize = 12_000_000;
const max_index_budget: usize = max_vertex_budget * 3;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return math.lerp(a, b, t);
}

/// Helper to get a block from the world at global coordinates
fn getBlockAt(chunk_manager: *streaming.ChunkStreamingManager, x: i32, y: i32, z: i32) ?terrain.BlockType {
    // Check bounds
    if (y < 0 or y >= terrain.Chunk.CHUNK_HEIGHT) {
        return .air;
    }

    // Convert to chunk coordinates
    const chunk_x = @divFloor(x, terrain.Chunk.CHUNK_SIZE);
    const chunk_z = @divFloor(z, terrain.Chunk.CHUNK_SIZE);
    const chunk_pos = streaming.ChunkPos.init(chunk_x, chunk_z);

    // Get chunk
    const chunk = chunk_manager.getChunk(chunk_pos) orelse return .air;

    // Convert to local coordinates
    const local_x: usize = @intCast(@mod(x, terrain.Chunk.CHUNK_SIZE));
    const local_z: usize = @intCast(@mod(z, terrain.Chunk.CHUNK_SIZE));
    const local_y: usize = @intCast(y);

    // Get block
    const block = chunk.getBlock(local_x, local_z, local_y) orelse return .air;
    return block.block_type;
}

/// Set a block in the world at global coordinates
fn setBlockAt(chunk_manager: *streaming.ChunkStreamingManager, x: i32, y: i32, z: i32, block_type: terrain.BlockType) bool {
    // Check bounds
    if (y < 0 or y >= terrain.Chunk.CHUNK_HEIGHT) {
        return false;
    }

    // Convert to chunk coordinates
    const chunk_x = @divFloor(x, terrain.Chunk.CHUNK_SIZE);
    const chunk_z = @divFloor(z, terrain.Chunk.CHUNK_SIZE);
    const chunk_pos = streaming.ChunkPos.init(chunk_x, chunk_z);

    // Get chunk
    const chunk = chunk_manager.getChunk(chunk_pos) orelse return false;

    // Convert to local coordinates
    const local_x: usize = @intCast(@mod(x, terrain.Chunk.CHUNK_SIZE));
    const local_z: usize = @intCast(@mod(z, terrain.Chunk.CHUNK_SIZE));
    const local_y: usize = @intCast(y);

    // Set block
    return chunk.setBlock(local_x, local_z, local_y, terrain.Block.init(block_type));
}

/// Generate vertices for a wireframe cube outline
fn generateCubeOutlineVertices(allocator: std.mem.Allocator, pos: math.Vec3i, offset: f32) ![]metal_renderer.Vertex {
    const x = @as(f32, @floatFromInt(pos.x)) - offset;
    const y = @as(f32, @floatFromInt(pos.y)) - offset;
    const z = @as(f32, @floatFromInt(pos.z)) - offset;
    const size = 1.0 + offset * 2.0;

    // Define 8 corners of the cube
    const corners = [8][3]f32{
        [3]f32{ x, y, z }, // 0: bottom-back-left
        [3]f32{ x + size, y, z }, // 1: bottom-back-right
        [3]f32{ x + size, y, z + size }, // 2: bottom-front-right
        [3]f32{ x, y, z + size }, // 3: bottom-front-left
        [3]f32{ x, y + size, z }, // 4: top-back-left
        [3]f32{ x + size, y + size, z }, // 5: top-back-right
        [3]f32{ x + size, y + size, z + size }, // 6: top-front-right
        [3]f32{ x, y + size, z + size }, // 7: top-front-left
    };

    // 12 edges, 2 vertices each = 24 vertices
    const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    const normal = [3]f32{ 0.0, 1.0, 0.0 };
    const uv = [2]f32{ 0.0, 0.0 };

    var vertices = try allocator.alloc(metal_renderer.Vertex, 24);

    // Bottom edges
    vertices[0] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = white };
    vertices[1] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = white };
    vertices[2] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = white };
    vertices[3] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = white };
    vertices[4] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = white };
    vertices[5] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = white };
    vertices[6] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = white };
    vertices[7] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = white };

    // Top edges
    vertices[8] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = white };
    vertices[9] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = white };
    vertices[10] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = white };
    vertices[11] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = white };
    vertices[12] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = white };
    vertices[13] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = white };
    vertices[14] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = white };
    vertices[15] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = white };

    // Vertical edges
    vertices[16] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = white };
    vertices[17] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = white };
    vertices[18] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = white };
    vertices[19] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = white };
    vertices[20] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = white };
    vertices[21] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = white };
    vertices[22] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = white };
    vertices[23] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = white };

    return vertices;
}

fn blockTypeColor(block_type: terrain.BlockType) [3]f32 {
    return switch (block_type) {
        .grass => [3]f32{ 0.35, 0.7, 0.25 },
        .dirt => [3]f32{ 0.45, 0.3, 0.18 },
        .stone => [3]f32{ 0.6, 0.6, 0.65 },
        .sand => [3]f32{ 0.9, 0.85, 0.6 },
        .water => [3]f32{ 0.2, 0.4, 0.85 },
        .air => [3]f32{ 1.0, 1.0, 1.0 },
    };
}

fn blockTypeAtlasTile(block_type: terrain.BlockType) [2]u32 {
    return switch (block_type) {
        .grass => textures.tileCoord(.grass),
        .dirt => textures.tileCoord(.dirt),
        .stone => textures.tileCoord(.stone),
        .sand => textures.tileCoord(.sand),
        .water => textures.tileCoord(.water),
        .air => textures.tileCoord(.air),
    };
}

fn updateGpuMeshes(
    allocator: std.mem.Allocator,
    chunk_manager: *streaming.ChunkStreamingManager,
    mesh_cache: *std.AutoHashMap(u64, CachedMesh),
    mesher: *mesh.GreedyMesher,
    combined_vertices: *std.ArrayListUnmanaged(metal_renderer.Vertex),
    combined_indices: *std.ArrayListUnmanaged(u32),
    frustum: math.Frustum,
    camera_pos: math.Vec3,
) !MeshUpdateStats {
    var stats = MeshUpdateStats{
        .changed = false,
        .total_chunks = chunk_manager.chunks.count(),
        .visible_chunks = 0,
        .rendered_chunks = 0,
        .culled_chunks = 0,
        .budget_skipped = 0,
        .total_vertices = 0,
        .total_indices = 0,
    };
    const atlas_tile_size = 1.0 / @as(f32, @floatFromInt(textures.tiles_per_row));

    // Limit mesh generation per frame to avoid stuttering
    const max_meshes_per_frame: usize = 3;
    var meshes_generated_this_frame: usize = 0;

    var cache_it = mesh_cache.iterator();
    while (cache_it.next()) |entry| {
        entry.value_ptr.in_use = false;
        entry.value_ptr.selected = false;
    }

    const ChunkCandidate = struct {
        key: u64,
        chunk_ptr: *terrain.Chunk,
        distance2: f32,
    };

    var candidates = std.ArrayListUnmanaged(ChunkCandidate){};
    defer candidates.deinit(allocator);

    var chunk_it = chunk_manager.chunks.iterator();
    while (chunk_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const chunk_ptr = entry.value_ptr.*;

        const chunk_size_f32 = @as(f32, @floatFromInt(terrain.Chunk.CHUNK_SIZE));
        const chunk_x = @as(f32, @floatFromInt(chunk_ptr.x)) * chunk_size_f32;
        const chunk_z = @as(f32, @floatFromInt(chunk_ptr.z)) * chunk_size_f32;
        const chunk_aabb = math.AABB.init(
            math.Vec3.init(chunk_x, 0, chunk_z),
            math.Vec3.init(chunk_x + chunk_size_f32, @as(f32, @floatFromInt(terrain.Chunk.CHUNK_HEIGHT)), chunk_z + chunk_size_f32),
        );
        const margin = 2.0;
        const expanded_aabb = math.AABB.init(
            chunk_aabb.min.sub(math.Vec3.init(margin, margin, margin)),
            chunk_aabb.max.add(math.Vec3.init(margin, margin, margin)),
        );
        if (!frustum.containsAABB(expanded_aabb)) {
            stats.culled_chunks += 1;
            continue;
        }

        stats.visible_chunks += 1;

        const chunk_center_x = chunk_x + chunk_size_f32 * 0.5;
        const chunk_center_z = chunk_z + chunk_size_f32 * 0.5;
        const dx = chunk_center_x - camera_pos.x;
        const dz = chunk_center_z - camera_pos.z;
        const dist2 = dx * dx + dz * dz;

        try candidates.append(allocator, .{
            .key = key,
            .chunk_ptr = chunk_ptr,
            .distance2 = dist2,
        });
    }

    if (candidates.items.len > 1) {
        std.sort.insertion(ChunkCandidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: ChunkCandidate, b: ChunkCandidate) bool {
                return a.distance2 < b.distance2;
            }
        }.lessThan);
    }

    var vertex_budget_used: usize = 0;
    var index_budget_used: usize = 0;

    for (candidates.items) |candidate| {
        const key = candidate.key;
        const chunk_ptr = candidate.chunk_ptr;

        var cache_entry_ptr_opt = mesh_cache.getPtr(key);
        if (cache_entry_ptr_opt == null) {
            try mesh_cache.put(key, .{
                .vertices = &[_]metal_renderer.Vertex{},
                .indices = &[_]u32{},
                .in_use = false,
                .selected = false,
            });
            cache_entry_ptr_opt = mesh_cache.getPtr(key);
            stats.changed = true;
        }

        const cache_entry_ptr = cache_entry_ptr_opt.?;
        var cache_entry = cache_entry_ptr.*;
        const was_selected = cache_entry.selected;

        cache_entry.selected = false;
        cache_entry.in_use = true;

        if (chunk_ptr.modified or cache_entry.vertices.len == 0) {
            if (meshes_generated_this_frame < max_meshes_per_frame) {
                if (cache_entry.vertices.len > 0) allocator.free(cache_entry.vertices);
                if (cache_entry.indices.len > 0) allocator.free(cache_entry.indices);

                var chunk_mesh = try mesher.generateMesh(chunk_ptr);
                defer chunk_mesh.deinit();
                meshes_generated_this_frame += 1;

                const vertex_count = chunk_mesh.vertices.items.len;
                const index_count = chunk_mesh.indices.items.len;

                if (vertex_count == 0 or index_count == 0) {
                    cache_entry.vertices = &[_]metal_renderer.Vertex{};
                    cache_entry.indices = &[_]u32{};
                    cache_entry.in_use = false;
                    cache_entry.selected = false;
                } else {
                    var new_vertices = try allocator.alloc(metal_renderer.Vertex, vertex_count);
                    const new_indices = try allocator.alloc(u32, index_count);

                    const size_i32: i32 = @intCast(terrain.Chunk.CHUNK_SIZE);
                    const origin_x = @as(f32, @floatFromInt(chunk_ptr.x * size_i32));
                    const origin_z = @as(f32, @floatFromInt(chunk_ptr.z * size_i32));

                    for (chunk_mesh.vertices.items, 0..) |src_vertex, i| {
                        const base_color = blockTypeColor(src_vertex.block_type);
                        const ao = src_vertex.ao;
                        const tile = blockTypeAtlasTile(src_vertex.block_type);

                        const uv_raw_u = src_vertex.tex_coords[0];
                        const uv_raw_v = src_vertex.tex_coords[1];
                        const frac_u = uv_raw_u - @floor(uv_raw_u);
                        const frac_v = uv_raw_v - @floor(uv_raw_v);
                        const tile_base_u = @as(f32, @floatFromInt(tile[0])) * atlas_tile_size;
                        const tile_base_v = @as(f32, @floatFromInt(tile[1])) * atlas_tile_size;
                        const final_u = tile_base_u + frac_u * atlas_tile_size;
                        const final_v = tile_base_v + frac_v * atlas_tile_size;

                        new_vertices[i] = .{
                            .position = [3]f32{
                                origin_x + src_vertex.position[0],
                                src_vertex.position[1],
                                origin_z + src_vertex.position[2],
                            },
                            .normal = src_vertex.normal,
                            .tex_coord = [2]f32{ final_u, final_v },
                            .color = [4]f32{
                                base_color[0] * ao,
                                base_color[1] * ao,
                                base_color[2] * ao,
                                1.0,
                            },
                        };
                    }

                    std.mem.copyForwards(u32, new_indices, chunk_mesh.indices.items);

                    cache_entry.vertices = new_vertices;
                    cache_entry.indices = new_indices;
                    cache_entry.in_use = true;
                }

                chunk_ptr.modified = false;
                stats.changed = true;
            }
        }

        const vertex_count = cache_entry.vertices.len;
        const index_count = cache_entry.indices.len;
        if (vertex_count == 0 or index_count == 0) {
            if (was_selected) stats.changed = true;
            cache_entry.in_use = false;
            cache_entry.selected = false;
            cache_entry_ptr.* = cache_entry;
            continue;
        }

        if (stats.rendered_chunks >= max_render_chunks or
            vertex_budget_used + vertex_count > max_vertex_budget or
            index_budget_used + index_count > max_index_budget)
        {
            stats.budget_skipped += 1;
            cache_entry.in_use = true;
            cache_entry.selected = false;
            if (was_selected) stats.changed = true;
            cache_entry_ptr.* = cache_entry;
            continue;
        }

        cache_entry.in_use = true;
        cache_entry.selected = true;
        if (!was_selected) stats.changed = true;
        cache_entry_ptr.* = cache_entry;

        vertex_budget_used += vertex_count;
        index_budget_used += index_count;
        stats.rendered_chunks += 1;
    }

    var keys_to_remove = std.ArrayListUnmanaged(u64){};
    defer keys_to_remove.deinit(allocator);

    var cleanup_it = mesh_cache.iterator();
    while (cleanup_it.next()) |entry| {
        if (!entry.value_ptr.in_use) {
            try keys_to_remove.append(allocator, entry.key_ptr.*);
        }
    }

    for (keys_to_remove.items) |key| {
        if (mesh_cache.get(key)) |cached| {
            if (cached.vertices.len > 0) allocator.free(cached.vertices);
            if (cached.indices.len > 0) allocator.free(cached.indices);
        }
        _ = mesh_cache.remove(key);
        stats.changed = true;
    }

    if (stats.changed or combined_vertices.items.len == 0) {
        combined_vertices.clearRetainingCapacity();
        combined_indices.clearRetainingCapacity();

        var rebuild_it = mesh_cache.iterator();
        while (rebuild_it.next()) |entry| {
            const cached = entry.value_ptr.*;
            if (!cached.selected) continue;
            if (cached.vertices.len == 0 or cached.indices.len == 0) continue;

            const base_vertex = @as(u32, @intCast(combined_vertices.items.len));
            try combined_vertices.appendSlice(allocator, cached.vertices);
            try combined_indices.ensureTotalCapacity(allocator, combined_indices.items.len + cached.indices.len);
            for (cached.indices) |idx| {
                combined_indices.appendAssumeCapacity(base_vertex + idx);
            }
        }
    }

    stats.total_vertices = combined_vertices.items.len;
    stats.total_indices = combined_indices.items.len;
    return stats;
}

/// Console-based interactive demo (legacy)
pub fn runConsoleDemo(allocator: std.mem.Allocator) !void {
    viz.clearScreen();
    viz.displayHeader("Open World Game - Interactive Demo");

    // Initialize systems
    std.debug.print("[Init] Initializing game systems...\n", .{});

    const world_seed: u64 = 42;
    const view_distance: i32 = 8;
    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, world_seed, view_distance);
    defer chunk_manager.deinit();

    const spawn_pos = math.Vec3.init(8.0, 80.0, 8.0);
    var player_physics = player.PlayerPhysics.init(spawn_pos);
    player_physics.is_flying = true;

    var main_camera = camera.Camera.init(player_physics.getEyePosition(), 16.0 / 9.0);
    main_camera.setMode(.free_cam);

    var mesher = mesh.GreedyMesher.init(allocator);

    std.debug.print("  ✓ All systems initialized\n\n", .{});

    // Generate initial chunks
    std.debug.print("[World] Generating initial chunks...\n", .{});
    try chunk_manager.update(player_physics.position, main_camera.front);
    if (chunk_manager.takeAutosaveSummary()) |summary| {
        const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
        const reason_str = switch (summary.reason) {
            .timer => "auto",
            .manual => "manual",
        };
        std.debug.print(
            "[Autosave] Saved {d} chunks ({d} errors) in {d:.2} ms ({s})\n",
            .{ summary.saved_chunks, summary.errors, duration_ms, reason_str },
        );
    }

    viz.displayChunkStats(&chunk_manager);

    // Show terrain samples
    std.debug.print("[Terrain] Biome Samples:\n", .{});
    const terrain_gen = generator.TerrainGenerator.init(world_seed);

    const samples = [_]struct { x: i32, z: i32 }{
        .{ .x = 0, .z = 0 },
        .{ .x = 50, .z = 50 },
        .{ .x = 100, .z = 0 },
        .{ .x = -50, .z = 50 },
    };

    for (samples) |sample| {
        const biome = terrain_gen.getBiomeAt(sample.x, sample.z);
        const height = terrain_gen.getHeightAt(sample.x, sample.z);
        std.debug.print("  • ({d: >4}, {d: >4}): {s: <12} height: {d}\n", .{
            sample.x,
            sample.z,
            @tagName(biome.type),
            height,
        });
    }
    std.debug.print("\n", .{});

    // Test mesh generation
    std.debug.print("[Mesh] Generating sample chunk mesh...\n", .{});
    const test_pos = streaming.ChunkPos.init(0, 0);
    if (chunk_manager.getChunk(test_pos)) |test_chunk| {
        var chunk_mesh = try mesher.generateMesh(test_chunk);
        defer chunk_mesh.deinit();

        std.debug.print("  ✓ Chunk (0, 0):\n", .{});
        std.debug.print("    - Vertices:  {}\n", .{chunk_mesh.vertex_count});
        std.debug.print("    - Triangles: {}\n", .{chunk_mesh.triangle_count});
        std.debug.print("    - Indices:   {}\n\n", .{chunk_mesh.indices.items.len});
    }

    // Initial map
    viz.renderChunkMap(&chunk_manager, player_physics.position, 10);

    // Simulation loop
    std.debug.print("[Simulation] Running interactive demo...\n", .{});
    std.debug.print("(Player will move forward automatically)\n\n", .{});

    const dt: f32 = 1.0 / 60.0;
    var frame: u32 = 0;
    const max_frames = 300; // 5 seconds

    var last_chunk_count = chunk_manager.getLoadedCount();

    while (frame < max_frames) : (frame += 1) {
        const start_time = std.time.nanoTimestamp();

        // Update player (move forward for first 2 seconds)
        if (frame < 120) {
            player_physics.applyMovementInput(1.0, 0.0, main_camera.front, dt);
        }

        player_physics.velocity.x *= 0.9;
        player_physics.velocity.z *= 0.9;
        player_physics.position = player_physics.position.add(player_physics.velocity.mul(dt));

        // Update camera
        main_camera.position = player_physics.getEyePosition();

        // Update chunk loading
        try chunk_manager.update(player_physics.position, main_camera.front);
        if (chunk_manager.takeAutosaveSummary()) |summary| {
            const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
            const reason_str = switch (summary.reason) {
                .timer => "auto",
                .manual => "manual",
            };
            std.debug.print(
                "[Autosave] Saved {d} chunks ({d} errors) in {d:.2} ms ({s})\n",
                .{ summary.saved_chunks, summary.errors, duration_ms, reason_str },
            );
        }

        if (chunk_manager.takeAutosaveSummary()) |summary| {
            const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
            const reason_str = switch (summary.reason) {
                .timer => "auto",
                .manual => "manual",
            };
            std.debug.print(
                "[Autosave] Saved {d} chunks ({d} errors) in {d:.2} ms ({s})\n",
                .{ summary.saved_chunks, summary.errors, duration_ms, reason_str },
            );
        }

        const update_time = std.time.nanoTimestamp();

        // Display updates every second
        if (frame % 60 == 0) {
            viz.clearScreen();
            std.debug.print("\n╔══════════════════════════════════════════════════╗\n", .{});
            std.debug.print("║       Open World Demo - Frame {d: >3}             ║\n", .{frame});
            std.debug.print("╚══════════════════════════════════════════════════╝\n\n", .{});

            viz.displayPlayerInfo(player_physics.position, player_physics.velocity, player_physics.on_ground);

            viz.displayChunkStats(&chunk_manager);

            viz.renderChunkMap(&chunk_manager, player_physics.position, 10);

            const update_time_ms = @as(f32, @floatFromInt(update_time - start_time)) / 1_000_000.0;

            const current_chunks = chunk_manager.getLoadedCount();
            const chunks_loaded = if (current_chunks > last_chunk_count)
                current_chunks - last_chunk_count
            else
                0;
            last_chunk_count = current_chunks;

            viz.displayPerformanceMetrics(16.67, update_time_ms, chunks_loaded);

            // Progress bar for simulation
            viz.drawProgressBar("Simulation", frame, max_frames, 30);

            std.Thread.sleep(16 * std.time.ns_per_ms);
        }
    }

    // Final summary
    viz.clearScreen();
    viz.displayHeader("Simulation Complete!");

    std.debug.print("\n┌─ Final Statistics ─────────────────────────────┐\n", .{});
    std.debug.print("│                                                │\n", .{});
    std.debug.print("│  Frames simulated:       {d: >6}               │\n", .{max_frames});
    std.debug.print("│  Final chunk count:      {d: >6}               │\n", .{chunk_manager.getLoadedCount()});
    std.debug.print("│  Distance traveled:      {d: >6.1}m            │\n", .{
        player_physics.position.sub(spawn_pos).length(),
    });
    std.debug.print("│                                                │\n", .{});
    std.debug.print("│  Start position:  ({d: >5.1}, {d: >5.1}, {d: >5.1})    │\n", .{
        spawn_pos.x,
        spawn_pos.y,
        spawn_pos.z,
    });
    std.debug.print("│  Final position:  ({d: >5.1}, {d: >5.1}, {d: >5.1})    │\n", .{
        player_physics.position.x,
        player_physics.position.y,
        player_physics.position.z,
    });
    std.debug.print("│                                                │\n", .{});
    std.debug.print("└────────────────────────────────────────────────┘\n", .{});

    // Final chunk map
    std.debug.print("\n[Final State]\n", .{});
    viz.renderChunkMap(&chunk_manager, player_physics.position, 12);

    std.debug.print("\n✅ Demo complete! All systems working perfectly.\n", .{});
    std.debug.print("\n🚀 Ready for Metal rendering integration!\n\n", .{});
}

/// SDL + Metal powered interactive demo using real input devices
pub fn runInteractiveDemo(allocator: std.mem.Allocator, options: DemoOptions) !void {
    std.debug.print("\n=== Open World - Interactive Demo (SDL + Metal) ===\n\n", .{});

    // Check if Metal HUD is requested via environment variable
    const show_metal_hud = std.posix.getenv("MTL_HUD_ENABLED") != null;
    if (show_metal_hud) {
        std.debug.print("Metal Performance HUD: ENABLED (via MTL_HUD_ENABLED)\n", .{});
    } else {
        std.debug.print("Tip: Set MTL_HUD_ENABLED=1 to show Metal Performance HUD\n", .{});
    }

    var owned_world_name: ?[]u8 = null;
    defer if (owned_world_name) |name| allocator.free(name);

    var world_name_slice: []const u8 = options.world_name;
    var world_seed = options.world_seed;
    var force_new_world = options.force_new_world;

    const should_prompt_world = options.world_seed == null and !options.force_new_world and std.mem.eql(u8, options.world_name, default_world_name);

    var window = try sdl.SDLWindow.init(1280, 720, "Open World - Interactive Demo");
    defer window.deinit();

    var metal_ctx = try metal.MetalContext.init(window.metal_view);
    defer metal_ctx.deinit();
    std.debug.print("✓ Metal device: {s}\n", .{metal_ctx.getDeviceName()});

    const shader_source = try std.fs.cwd().readFileAlloc(allocator, "shaders/chunk.metal", 1024 * 1024);
    defer allocator.free(shader_source);

    const vertex_entry: []const u8 = "vertex_main";
    const fragment_entry: []const u8 = "fragment_main";
    try metal_ctx.createPipeline(shader_source, vertex_entry, fragment_entry, @sizeOf(metal_renderer.Vertex));
    const ui_vertex_entry: []const u8 = "ui_vertex_main";
    const ui_fragment_entry: []const u8 = "ui_fragment_main";
    metal_ctx.createUIPipeline(ui_vertex_entry, ui_fragment_entry, @sizeOf(line_text.UIVertex)) catch |err| {
        std.debug.print("Warning: failed to create UI pipeline: {any}\n", .{err});
    };

    var input_state = input.InputState{};
    var render_mode = metal.RenderMode.normal;

    if (should_prompt_world) {
        if (try showWorldSelectionMenu(allocator, options.worlds_root, &window, &metal_ctx, &input_state)) |selection| {
            owned_world_name = selection.name;
            world_name_slice = owned_world_name.?;
            world_seed = selection.seed;
            force_new_world = selection.force_new;
        } else {
            std.debug.print("Exiting without selecting a world.\n", .{});
            return;
        }
    }

    window.setCursorLocked(true);
    input_state.beginFrame();

    // Initialize world persistence
    var world_persistence = persistence.WorldPersistence.init(allocator, world_name_slice, .{
        .seed = world_seed,
        .force_new = force_new_world,
        .worlds_root = options.worlds_root,
    }) catch |err| switch (err) {
        error.WorldAlreadyExists => {
            std.debug.print("Error: world '{s}' already exists. Use a different name or omit --new-world.\n", .{world_name_slice});
            if (owned_world_name) |name| allocator.free(name);
            return err;
        },
        error.SeedMismatch => {
            std.debug.print("Error: world '{s}' seed mismatch. Provide matching --seed or omit it.\n", .{world_name_slice});
            if (owned_world_name) |name| allocator.free(name);
            return err;
        },
        else => {
            std.debug.print("Error: failed to open world '{s}': {any}\n", .{ world_name_slice, err });
            if (owned_world_name) |name| allocator.free(name);
            return err;
        },
    };
    defer {
        world_persistence.saveMetadata() catch |err| {
            std.debug.print("Warning: Failed to save world metadata: {any}\n", .{err});
        };
        world_persistence.deinit();
    }

    std.debug.print("Loaded world '{s}' (seed {d})\n", .{ world_name_slice, world_persistence.seed() });

    const view_distance: i32 = 8;
    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, world_persistence.seed(), view_distance);
    defer chunk_manager.deinit();

    // Connect persistence to chunk manager
    chunk_manager.world_persistence = &world_persistence;
    chunk_manager.syncPersistenceSettings();
    chunk_manager.resetAutosaveTimer();

    var autosave_presets = std.ArrayListUnmanaged(u32){};
    defer autosave_presets.deinit(allocator);
    try autosave_presets.appendSlice(allocator, &autosave_default_presets);

    var autosave_preset_index: usize = 0;
    const current_interval = chunk_manager.autosaveIntervalSeconds();
    var autosave_found = false;
    for (autosave_presets.items, 0..) |preset, idx| {
        if (preset == current_interval) {
            autosave_preset_index = idx;
            autosave_found = true;
            break;
        }
    }
    if (!autosave_found and current_interval != 0) {
        try autosave_presets.append(allocator, current_interval);
        std.sort.heap(u32, autosave_presets.items, {}, struct {
            fn lessThan(_: void, lhs: u32, rhs: u32) bool {
                return lhs < rhs;
            }
        }.lessThan);
        for (autosave_presets.items, 0..) |preset, idx| {
            if (preset == current_interval) {
                autosave_preset_index = idx;
                break;
            }
        }
    }
    var backup_retention_presets = std.ArrayListUnmanaged(usize){};
    defer backup_retention_presets.deinit(allocator);
    try backup_retention_presets.appendSlice(allocator, &backup_default_presets);
    var backup_retention_index: usize = 0;
    const current_retention = chunk_manager.backupRetention();
    {
        var found = false;
        for (backup_retention_presets.items, 0..) |preset, idx| {
            if (preset == current_retention) {
                backup_retention_index = idx;
                found = true;
                break;
            }
        }
        if (!found) {
            try backup_retention_presets.append(allocator, current_retention);
            std.sort.heap(usize, backup_retention_presets.items, {}, struct {
                fn lessThan(_: void, lhs: usize, rhs: usize) bool {
                    return lhs < rhs;
                }
            }.lessThan);
            for (backup_retention_presets.items, 0..) |preset, idx| {
                if (preset == current_retention) {
                    backup_retention_index = idx;
                    break;
                }
            }
        }
    }

    // Start async generation AFTER the manager is in its final location
    try chunk_manager.startAsyncGeneration();

    // Spawn at reasonable height above terrain
    const spawn_pos = math.Vec3.init(8.0, 75.0, 8.0); // Slightly above terrain
    var player_physics = player.PlayerPhysics.init(spawn_pos);
    player_physics.is_flying = true;

    var main_camera = camera.Camera.init(player_physics.getEyePosition(), 16.0 / 9.0);
    main_camera.setMode(.free_cam);

    // Look down slightly to see terrain
    main_camera.pitch = -0.3; // Look down about 17 degrees
    main_camera.updateVectors();

    var last_time: i128 = std.time.nanoTimestamp();
    var accumulator: f64 = 0;
    const fixed_dt: f32 = 1.0 / 60.0;
    const fixed_dt_seconds = @as(f64, fixed_dt);

    var total_frames: u64 = 0;
    var fps_counter: u32 = 0;
    var fps_timer: f64 = 0;
    var autosave_elapsed: f32 = 0;
    var autosave_status_timer: f32 = 0;
    var autosave_status_msg: []const u8 = "";

    const autosave_status_cap: usize = 128;
    const autosave_status_buffer = try allocator.alloc(u8, autosave_status_cap);
    defer allocator.free(autosave_status_buffer);

    const manual_message_buffer = try allocator.alloc(u8, autosave_status_cap);
    defer allocator.free(manual_message_buffer);

    std.debug.print("Controls:\n", .{});
    std.debug.print("  Movement: WASD, Space/Ctrl (fly up/down), Shift (sprint), F (toggle fly)\n", .{});
    std.debug.print("  Blocks: Left Click (break), Right Click (place)\n", .{});
    std.debug.print("  Debug: F4 (toggle wireframe)\n", .{});
    std.debug.print("  Autosave: F5 (cycle interval), F6 (manual save)\n", .{});
    std.debug.print("  Backups: F7 (increase retention), F8 (decrease retention)\n", .{});
    std.debug.print("  ESC (unlock cursor), ESC again (quit)\n", .{});

    try chunk_manager.update(player_physics.position, main_camera.front);

    var mesher = mesh.GreedyMesher.init(allocator);

    var atlas = try textures.generateAtlas(allocator);
    defer atlas.deinit(allocator);
    try metal_ctx.setTexture(atlas.data, atlas.width, atlas.height, atlas.width * textures.channels);

    var mesh_cache = std.AutoHashMap(u64, CachedMesh).init(allocator);
    defer {
        var it = mesh_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.vertices.len > 0) allocator.free(entry.value_ptr.vertices);
            if (entry.value_ptr.indices.len > 0) allocator.free(entry.value_ptr.indices);
        }
        mesh_cache.deinit();
    }

    var combined_vertices = std.ArrayListUnmanaged(metal_renderer.Vertex){};
    defer combined_vertices.deinit(allocator);
    var combined_indices = std.ArrayListUnmanaged(u32){};
    defer combined_indices.deinit(allocator);
    var hud_vertices = std.ArrayListUnmanaged(line_text.UIVertex){};
    defer hud_vertices.deinit(allocator);

    const model_matrix = math.Mat4.identity();
    var time_of_day: f32 = 0.25; // 0 = midnight, 0.25 = sunrise
    const day_length_seconds: f32 = 120.0; // full cycle in 2 minutes

    // Track selected block for outline rendering
    var selected_block: ?raycast.RaycastHit = null;

    while (!window.should_close) {
        input_state.beginFrame();
        window.pollEvents(&input_state);

        if (input_state.wasKeyPressed(.escape)) {
            if (window.cursor_locked) {
                window.toggleCursorLock();
                std.debug.print("Cursor unlocked (Press ESC again to quit)\n", .{});
            } else {
                window.should_close = true;
            }
        }

        if (input_state.wasKeyPressed(.f)) {
            player_physics.toggleFlying();
        }

        if (input_state.wasKeyPressed(.f4)) {
            render_mode = render_mode.next();
            metal_ctx.setRenderMode(render_mode);
            std.debug.print("Render Mode: {s}\n", .{render_mode.name()});
        }

        if (input_state.wasKeyPressed(.f5)) {
            autosave_preset_index = (autosave_preset_index + 1) % autosave_presets.items.len;
            const interval = autosave_presets.items[autosave_preset_index];
            chunk_manager.setAutosaveIntervalSeconds(interval);
            chunk_manager.resetAutosaveTimer();
            if (interval == 0) {
                std.debug.print("Autosave disabled.\n", .{});
            } else {
                std.debug.print("Autosave interval set to {d} seconds.\n", .{interval});
            }
            autosave_elapsed = 0;
            const msg = if (chunk_manager.autosaveIntervalSeconds() == 0)
                "Autosave: off"
            else
                std.fmt.bufPrint(autosave_status_buffer, "Autosave: every {d}s", .{chunk_manager.autosaveIntervalSeconds()}) catch "Autosave interval set";
            autosave_status_msg = msg;
            autosave_status_timer = 4.0;
        }

        if (input_state.wasKeyPressed(.f6)) {
            if (chunk_manager.forceAutosave()) |summary| {
                const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
                std.debug.print(
                    "[Autosave] Manual save: saved {d} chunks ({d} errors) in {d:.2} ms\n",
                    .{ summary.saved_chunks, summary.errors, duration_ms },
                );
                const msg = std.fmt.bufPrint(manual_message_buffer, "Manual save: {d} chunks ({d} errors)", .{ summary.saved_chunks, summary.errors }) catch "Manual save";
                autosave_status_msg = msg;
                autosave_status_timer = 4.0;
            } else {
                std.debug.print("[Autosave] Manual save: no modified chunks\n", .{});
                autosave_status_msg = "Manual save: no changes";
                autosave_status_timer = 4.0;
            }
            autosave_elapsed = 0;
        }

        if (input_state.wasKeyPressed(.f7)) {
            if (chunk_manager.world_persistence) |_| {
                if (backup_retention_index + 1 < backup_retention_presets.items.len) {
                    backup_retention_index += 1;
                }
                const retention = backup_retention_presets.items[backup_retention_index];
                chunk_manager.setBackupRetention(retention);
                std.debug.print("Backups retention set to {d} copies per region.\n", .{retention});
                autosave_status_msg = std.fmt.bufPrint(autosave_status_buffer, "Backups: keep {d}", .{retention}) catch "Backups retention set";
                autosave_status_timer = 4.0;
            } else {
                std.debug.print("Backups retention control unavailable: no persistence backend.\n", .{});
            }
        } else if (input_state.wasKeyPressed(.f8)) {
            if (chunk_manager.world_persistence) |_| {
                if (backup_retention_index > 0) {
                    backup_retention_index -= 1;
                }
                const retention = backup_retention_presets.items[backup_retention_index];
                chunk_manager.setBackupRetention(retention);
                std.debug.print("Backups retention set to {d} copies per region.\n", .{retention});
                autosave_status_msg = std.fmt.bufPrint(autosave_status_buffer, "Backups: keep {d}", .{retention}) catch "Backups retention set";
                autosave_status_timer = 4.0;
            }
        }

        player_physics.setSprinting(input_state.isKeyDown(.shift_left));
        player_physics.setSneaking(false);

        const current_time = std.time.nanoTimestamp();
        const delta_ns = current_time - last_time;
        last_time = current_time;

        const delta_seconds = @as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0;
        accumulator += delta_seconds;
        fps_timer += delta_seconds;
        autosave_elapsed += @as(f32, @floatCast(delta_seconds));
        if (autosave_status_timer > 0) {
            autosave_status_timer -= @as(f32, @floatCast(delta_seconds));
            if (autosave_status_timer <= 0) {
                autosave_status_timer = 0;
                autosave_status_msg = "";
            }
        }

        time_of_day += @as(f32, @floatCast(delta_seconds)) / day_length_seconds;
        if (time_of_day >= 1.0) time_of_day -= 1.0;

        if (window.height != 0) {
            const aspect = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(window.height));
            main_camera.setAspectRatio(aspect);
        }

        main_camera.processMouseMovement(input_state.mouse_delta.x, input_state.mouse_delta.y);

        // Block interaction - ray cast from camera
        const GetBlockFn = struct {
            fn get(chunk_mgr: *streaming.ChunkStreamingManager, x: i32, y: i32, z: i32) ?terrain.BlockType {
                return getBlockAt(chunk_mgr, x, y, z);
            }
        }.get;

        const ray_origin = main_camera.getPosition();
        const ray_direction = main_camera.getFront();
        const max_reach = 5.0; // 5 blocks reach distance

        const hit = raycast.raycast(
            ray_origin,
            ray_direction,
            max_reach,
            &chunk_manager,
            GetBlockFn,
        );

        // Store selected block for outline rendering
        selected_block = if (hit.hit) hit else null;

        // Show what block you're looking at (every 30 frames to avoid spam)
        if (hit.hit and total_frames % 30 == 0) {
            const block_type = getBlockAt(&chunk_manager, hit.block_pos.x, hit.block_pos.y, hit.block_pos.z) orelse .air;
            std.debug.print("→ Looking at: {s} at ({d}, {d}, {d}) distance {d:.1}m\n", .{
                @tagName(block_type),
                hit.block_pos.x,
                hit.block_pos.y,
                hit.block_pos.z,
                hit.distance,
            });
        }

        // Handle block breaking (left click)
        if (hit.hit and input_state.wasMousePressed(.left)) {
            const bx = hit.block_pos.x;
            const by = hit.block_pos.y;
            const bz = hit.block_pos.z;
            const block_type = getBlockAt(&chunk_manager, bx, by, bz) orelse .air;
            _ = setBlockAt(&chunk_manager, bx, by, bz, .air);
            std.debug.print("💥 Broke {s} at ({d}, {d}, {d})\n", .{ @tagName(block_type), bx, by, bz });
        }

        // Handle block placing (right click)
        if (hit.hit and input_state.wasMousePressed(.right)) {
            // Place block on the face that was hit
            const place_x = hit.block_pos.x + hit.face_normal.x;
            const place_y = hit.block_pos.y + hit.face_normal.y;
            const place_z = hit.block_pos.z + hit.face_normal.z;

            // Check if player would collide with placed block
            const place_pos = math.Vec3.init(@as(f32, @floatFromInt(place_x)) + 0.5, @as(f32, @floatFromInt(place_y)) + 0.5, @as(f32, @floatFromInt(place_z)) + 0.5);
            const player_aabb = math.AABB.fromCenter(player_physics.position, math.Vec3.init(0.4, 0.9, 0.4));
            const block_aabb = math.AABB.fromCenter(place_pos, math.Vec3.init(0.5, 0.5, 0.5));

            if (!player_aabb.intersects(block_aabb)) {
                _ = setBlockAt(&chunk_manager, place_x, place_y, place_z, .stone);
                std.debug.print("🔨 Placed stone at ({d}, {d}, {d})\n", .{ place_x, place_y, place_z });
            } else {
                std.debug.print("❌ Can't place block - would intersect player!\n", .{});
            }
        }

        while (accumulator >= fixed_dt_seconds) {
            const dt_f32: f32 = fixed_dt;

            var forward: f32 = 0;
            var strafe: f32 = 0;

            if (input_state.isKeyDown(.w)) forward += 1;
            if (input_state.isKeyDown(.s)) forward -= 1;
            if (input_state.isKeyDown(.d)) strafe += 1;
            if (input_state.isKeyDown(.a)) strafe -= 1;

            if (forward != 0 or strafe != 0) {
                player_physics.applyMovementInput(forward, strafe, main_camera.front, dt_f32);
            }

            if (player_physics.is_flying) {
                if (input_state.isKeyDown(.space)) {
                    player_physics.flyUp();
                } else if (input_state.isKeyDown(.ctrl_left)) {
                    player_physics.flyDown();
                } else {
                    player_physics.velocity.y *= 0.92;
                }
            } else if (input_state.wasKeyPressed(.space)) {
                player_physics.jump();
            }

            // Dampen horizontal velocity slightly when no input
            player_physics.velocity.x *= 0.90;
            player_physics.velocity.z *= 0.90;

            player_physics.position = player_physics.position.add(
                player_physics.velocity.mul(dt_f32),
            );

            main_camera.setPosition(player_physics.getEyePosition());

            try chunk_manager.update(player_physics.position, main_camera.front);
            if (chunk_manager.takeAutosaveSummary()) |summary| {
                const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
                const reason_str = switch (summary.reason) {
                    .timer => "auto",
                    .manual => "manual",
                };
                std.debug.print(
                    "[Autosave] Saved {d} chunks ({d} errors) in {d:.2} ms ({s})\n",
                    .{ summary.saved_chunks, summary.errors, duration_ms, reason_str },
                );
                autosave_status_msg = std.fmt.bufPrint(autosave_status_buffer, "Autosave: {d} chunks ({d} errors)", .{ summary.saved_chunks, summary.errors }) catch "Autosave complete";
                autosave_status_timer = 4.0;
                autosave_elapsed = 0;
            }

            accumulator -= fixed_dt_seconds;
        }

        // Create frustum for culling
        const view = main_camera.getViewMatrix();
        const projection = main_camera.getProjectionMatrix();
        const view_proj = projection.multiply(view);
        const frustum = math.Frustum.fromMatrix(view_proj);

        const camera_pos = main_camera.getPosition();
        const mesh_stats = try updateGpuMeshes(allocator, &chunk_manager, &mesh_cache, &mesher, &combined_vertices, &combined_indices, frustum, camera_pos);
        const has_mesh = combined_vertices.items.len > 0;

        if (selected_block) |sel| {
            const outline_vertices = try generateCubeOutlineVertices(allocator, sel.block_pos, 0.01);
            defer allocator.free(outline_vertices);
            if (outline_vertices.len > 0) {
                const outline_bytes = std.mem.sliceAsBytes(outline_vertices);
                try metal_ctx.setLineMesh(outline_bytes, @sizeOf(metal_renderer.Vertex));
            } else {
                try metal_ctx.setLineMesh(&[_]u8{}, @sizeOf(metal_renderer.Vertex));
            }
        } else {
            try metal_ctx.setLineMesh(&[_]u8{}, @sizeOf(metal_renderer.Vertex));
        }

        if (has_mesh) {
            hud_vertices.clearRetainingCapacity();
            var hud_texts: [4][]const u8 = .{ "", "", "", "" };
            var hud_count: usize = 0;
            var max_width: f32 = 0;
            const hud_scale: f32 = 16.0;
            const hud_line_height = line_text.lineHeightPx(hud_scale);
            const hud_padding = 12.0;

            var countdown_buf: [48]u8 = undefined;
            const autosave_interval = chunk_manager.autosaveIntervalSeconds();
            const autosave_line: []const u8 = if (autosave_interval == 0)
                "Autosave: OFF"
            else blk: {
                const interval_f = @as(f32, @floatFromInt(autosave_interval));
                const remaining = @max(0.0, interval_f - autosave_elapsed);
                break :blk std.fmt.bufPrint(&countdown_buf, "Autosave: next ~{d:.0}s", .{std.math.ceil(remaining)}) catch "Autosave countdown";
            };
            hud_texts[hud_count] = autosave_line;
            hud_count += 1;
            max_width = line_text.textWidth(autosave_line, hud_scale);

            if (autosave_status_msg.len > 0) {
                hud_texts[hud_count] = autosave_status_msg;
                hud_count += 1;
                max_width = @max(max_width, line_text.textWidth(autosave_status_msg, hud_scale));
            }

            if (chunk_manager.world_persistence) |wp| {
                const backup_status = wp.backupStatus();
                if (backup_status.retained > 0 or backup_status.last_backup_timestamp != 0) {
                    var time_buf: [32]u8 = undefined;
                    const time_str = if (backup_status.last_backup_timestamp != 0)
                        formatTimestamp(&time_buf, backup_status.last_backup_timestamp)
                    else
                        "none";

                    var backup_buf: [96]u8 = undefined;
                    const backup_line = std.fmt.bufPrint(
                        &backup_buf,
                        "Backups: {d}/{d} (last {s})",
                        .{ backup_status.retained, backup_status.retention_limit, time_str },
                    ) catch "Backups: status";

                    hud_texts[hud_count] = backup_line;
                    hud_count += 1;
                    max_width = @max(max_width, line_text.textWidth(backup_line, hud_scale));
                }
            }

            if (hud_count > 0) {
                const screen_size = math.Vec2.init(@floatFromInt(window.width), @floatFromInt(window.height));
                const panel_width = max_width + hud_padding * 2.0;
                const panel_height = @as(f32, @floatFromInt(hud_count)) * hud_line_height + hud_padding * 2.0;
                const margin = math.Vec2.init(24.0, 24.0);
                const origin = math.Vec2.init(
                    screen_size.x - panel_width - margin.x,
                    screen_size.y - panel_height - margin.y,
                );

                try line_text.appendQuad(
                    &hud_vertices,
                    allocator,
                    origin,
                    origin.add(math.Vec2.init(panel_width, panel_height)),
                    screen_size,
                    [4]f32{ 0.04, 0.05, 0.08, 0.78 },
                );

                var cursor = origin.add(math.Vec2.init(hud_padding, hud_padding));
                var line_index: usize = 0;
                while (line_index < hud_count) : (line_index += 1) {
                    try line_text.appendText(&hud_vertices, allocator, hud_texts[line_index], cursor, hud_scale, screen_size, [4]f32{ 0.9, 0.96, 1.0, 1.0 });
                    cursor.y += hud_line_height;
                }
            }

            if (hud_vertices.items.len == 0) {
                try metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex));
            } else {
                const hud_bytes = std.mem.sliceAsBytes(hud_vertices.items);
                try metal_ctx.setUIMesh(hud_bytes, @sizeOf(line_text.UIVertex));
            }
        } else {
            try metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex));
        }

        total_frames += 1;
        fps_counter += 1;

        const sun_theta = (time_of_day * std.math.tau) - (std.math.pi / 2.0);
        var sun_dir_vec = math.Vec3.init(@cos(sun_theta), @sin(sun_theta), 0.25);
        sun_dir_vec = sun_dir_vec.normalize();
        const sun_elevation = sun_dir_vec.y;
        const day_factor = std.math.clamp((sun_elevation + 0.05) / 1.05, 0.0, 1.0);
        const sun_intensity = lerp(0.0, 1.0, day_factor);

        const sun_color_vec = math.Vec3.init(
            lerp(0.9, 1.0, day_factor),
            lerp(0.55, 1.0, day_factor),
            lerp(0.4, 0.95, day_factor),
        ).mul(sun_intensity);

        const ambient_strength = lerp(0.05, 0.35, day_factor);
        const ambient_color_vec = math.Vec3.init(ambient_strength, ambient_strength, ambient_strength);

        const sky_color_day = math.Vec3.init(0.35, 0.55, 0.9);
        const sky_color_night = math.Vec3.init(0.02, 0.02, 0.05);
        const sky_color_vec = math.Vec3.init(
            lerp(sky_color_night.x, sky_color_day.x, day_factor),
            lerp(sky_color_night.y, sky_color_day.y, day_factor),
            lerp(sky_color_night.z, sky_color_day.z, day_factor),
        );

        if (mesh_stats.changed and has_mesh) {
            try metal_ctx.setMesh(
                std.mem.sliceAsBytes(combined_vertices.items),
                @sizeOf(metal_renderer.Vertex),
                combined_indices.items,
            );
        }

        const fog_start: f32 = 40.0;
        const fog_range: f32 = 80.0;

        if (has_mesh) {
            const vp = projection.multiply(view);
            const mvp = vp.multiply(model_matrix);

            var uniforms = metal_renderer.Uniforms{
                .model_view_projection = mvp.data,
                .model = model_matrix.data,
                .view = view.data,
                .projection = projection.data,
                .sun_direction = [4]f32{ sun_dir_vec.x, sun_dir_vec.y, sun_dir_vec.z, 0.0 },
                .sun_color = [4]f32{ sun_color_vec.x, sun_color_vec.y, sun_color_vec.z, 1.0 },
                .ambient_color = [4]f32{ ambient_color_vec.x, ambient_color_vec.y, ambient_color_vec.z, 1.0 },
                .sky_color = [4]f32{ sky_color_vec.x, sky_color_vec.y, sky_color_vec.z, 1.0 },
                .camera_position = [4]f32{ camera_pos.x, camera_pos.y, camera_pos.z, 1.0 },
                .fog_params = [4]f32{ 0.0, fog_start, fog_range, 0.0 },
            };

            try metal_ctx.setUniforms(std.mem.asBytes(&uniforms));
            try metal_ctx.draw(.{ sky_color_vec.x, sky_color_vec.y, sky_color_vec.z, 1.0 });
        } else {
            if (total_frames < 15) {
                std.debug.print("DEBUG: NO MESH - rendering sky only\n", .{});
            }
            _ = metal_ctx.renderFrame(sky_color_vec.x, sky_color_vec.y, sky_color_vec.z);
        }

        if (fps_timer >= 1.0) {
            std.debug.print(
                "FPS ~{d: >3} | Pos ({d:.1}, {d:.1}, {d:.1}) | Chunks {d}/{d} vis/{d} total (culled {d}, budget {d}) | Verts {d} Tris {d}\n",
                .{
                    fps_counter,
                    player_physics.position.x,
                    player_physics.position.y,
                    player_physics.position.z,
                    mesh_stats.rendered_chunks,
                    mesh_stats.visible_chunks,
                    mesh_stats.total_chunks,
                    mesh_stats.culled_chunks,
                    mesh_stats.budget_skipped,
                    mesh_stats.total_vertices,
                    mesh_stats.total_indices / 3,
                },
            );
            const autosave_interval_console = chunk_manager.autosaveIntervalSeconds();
            if (autosave_interval_console == 0) {
                std.debug.print("Autosave: off\n", .{});
            } else {
                const remaining = @max(0.0, @as(f32, @floatFromInt(autosave_interval_console)) - autosave_elapsed);
                std.debug.print("Autosave: next in ~{d:.1}s\n", .{remaining});
            }
            if (autosave_status_msg.len > 0) {
                std.debug.print("Autosave status: {s}\n", .{autosave_status_msg});
            }
            if (chunk_manager.world_persistence) |wp| {
                const backup_status = wp.backupStatus();
                if (backup_status.retained > 0 or backup_status.last_backup_timestamp != 0) {
                    var time_buf: [32]u8 = undefined;
                    const time_str = if (backup_status.last_backup_timestamp != 0)
                        formatTimestamp(&time_buf, backup_status.last_backup_timestamp)
                    else
                        "never";
                    std.debug.print(
                        "Backups: {d}/{d} (last {s})\n",
                        .{ backup_status.retained, backup_status.retention_limit, time_str },
                    );
                }
            }
            fps_counter = 0;
            fps_timer -= 1.0;
        }

        if (options.max_frames) |limit| {
            if (total_frames >= limit) break;
        }

        std.Thread.sleep(std.time.ns_per_ms); // Sleep 1ms to avoid maxing CPU
    }

    const loaded_before_unload = chunk_manager.getLoadedCount();
    chunk_manager.unloadAll();
    const loaded_after_unload = chunk_manager.getLoadedCount();
    std.debug.assert(chunk_manager.allocated_chunks == 0);
    std.debug.assert(loaded_after_unload == 0);
    std.debug.print(
        "\nDemo terminated. Total frames: {d} (chunks unloaded: {d} -> {d})\n",
        .{ total_frames, loaded_before_unload, loaded_after_unload },
    );
}
