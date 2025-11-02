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
const max_world_name_len: usize = 48;
const seed_digits_max: usize = 20; // enough for u64
const max_description_len: usize = 256;
const RenameWorldError = error{
    NameEmpty,
    NameUnchanged,
    AlreadyExists,
    PersistenceFailure,
};
const difficulty_cycle = [_]persistence.Difficulty{ .peaceful, .easy, .normal, .hard };
const autosave_default_presets = [_]u32{ 0, 15, 30, 60, 120 };
const backup_default_presets = [_]usize{ 1, 2, 3, 5, 8, 12, 16 };

pub const TestScenario = enum {
    none,
    lod_sweep,
};

const ParseScenarioError = error{InvalidScenario};

const HudNotification = struct {
    text: [128]u8,
    len: usize,
    timer: f32,
};

fn pushHudNotification(list: *std.ArrayListUnmanaged(HudNotification), allocator: std.mem.Allocator, message: []const u8, duration: f32) void {
    var notif = HudNotification{
        .text = [_]u8{0} ** 128,
        .len = 0,
        .timer = duration,
    };
    const copy_len = @min(message.len, notif.text.len);
    std.mem.copyForwards(u8, notif.text[0..copy_len], message[0..copy_len]);
    notif.len = copy_len;
    if (list.items.len >= 4) {
        _ = list.orderedRemove(0);
    }
    list.append(allocator, notif) catch {};
}

fn updateHudNotifications(list: *std.ArrayListUnmanaged(HudNotification), delta: f32) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].timer > delta) {
            list.items[i].timer -= delta;
            i += 1;
        } else {
            _ = list.orderedRemove(i);
        }
    }
}

const SaveSettingsPanel = struct {
    open: bool = false,
    selection: usize = 0,
    autosave_options: std.ArrayListUnmanaged(u32) = .{},
    autosave_index: usize = 0,
    backup_options: std.ArrayListUnmanaged(usize) = .{},
    backup_index: usize = 0,

    fn deinit(self: *SaveSettingsPanel, allocator: std.mem.Allocator) void {
        self.autosave_options.deinit(allocator);
        self.backup_options.deinit(allocator);
    }

    fn refresh(self: *SaveSettingsPanel, allocator: std.mem.Allocator, autosave_value: u32, backup_value: usize) !void {
        self.autosave_options.clearRetainingCapacity();
        self.backup_options.clearRetainingCapacity();

        try self.autosave_options.appendSlice(allocator, &autosave_default_presets);
        try self.backup_options.appendSlice(allocator, &backup_default_presets);

        if (autosave_value != 0) {
            var found = false;
            for (self.autosave_options.items, 0..) |value, idx| {
                if (value == autosave_value) {
                    self.autosave_index = idx;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.autosave_options.append(allocator, autosave_value);
            }
        } else {
            self.autosave_index = 0;
        }

        var found_backup = false;
        for (self.backup_options.items, 0..) |value, idx| {
            if (value == backup_value) {
                self.backup_index = idx;
                found_backup = true;
                break;
            }
        }
        if (!found_backup) {
            try self.backup_options.append(allocator, backup_value);
        }

        std.sort.heap(u32, self.autosave_options.items, {}, struct {
            fn lessThan(_: void, lhs: u32, rhs: u32) bool {
                return lhs < rhs;
            }
        }.lessThan);
        std.sort.heap(usize, self.backup_options.items, {}, struct {
            fn lessThan(_: void, lhs: usize, rhs: usize) bool {
                return lhs < rhs;
            }
        }.lessThan);

        // Recompute indices after sorting.
        self.autosave_index = 0;
        for (self.autosave_options.items, 0..) |value, idx| {
            if (value == autosave_value) {
                self.autosave_index = idx;
                break;
            }
        }

        self.backup_index = 0;
        for (self.backup_options.items, 0..) |value, idx| {
            if (value == backup_value) {
                self.backup_index = idx;
                break;
            }
        }

        if (self.selection > 1) self.selection = 1;
    }

    fn autosaveCurrent(self: *const SaveSettingsPanel) u32 {
        if (self.autosave_options.items.len == 0) return persistence.default_autosave_interval_seconds;
        return self.autosave_options.items[self.autosave_index];
    }

    fn backupCurrent(self: *const SaveSettingsPanel) usize {
        if (self.backup_options.items.len == 0) return persistence.default_region_backup_retention;
        return self.backup_options.items[self.backup_index];
    }
};

const SaveSettingsPanelView = struct {
    open: bool,
    selection: usize,
    autosave: []const u32,
    autosave_index: usize,
    backup: []const usize,
    backup_index: usize,
};

fn difficultyLabelShort(diff: persistence.Difficulty) []const u8 {
    return persistence.difficultyLabel(diff);
}

fn cycleDifficulty(current: persistence.Difficulty, delta: i32) persistence.Difficulty {
    var idx: usize = 0;
    while (idx < difficulty_cycle.len and difficulty_cycle[idx] != current) : (idx += 1) {}
    const len_i32: i32 = @intCast(difficulty_cycle.len);
    const new_index = @mod(@as(i32, @intCast(idx)) + delta + len_i32, len_i32);
    return difficulty_cycle[@intCast(new_index)];
}

fn viewDistanceForDifficulty(diff: persistence.Difficulty) i32 {
    return switch (diff) {
        .peaceful => 6,
        .easy => 8,
        .normal => 10,
        .hard => 12,
    };
}

fn autosaveIntervalForDifficulty(diff: persistence.Difficulty) u32 {
    return switch (diff) {
        .peaceful => 120,
        .easy => 60,
        .normal => 30,
        .hard => 15,
    };
}

fn chunkBudgetForDifficulty(diff: persistence.Difficulty) u32 {
    return switch (diff) {
        .peaceful => 6,
        .easy => 5,
        .normal => 4,
        .hard => 3,
    };
}

pub const DemoOptions = struct {
    max_frames: ?u32 = null,
    world_name: []const u8 = default_world_name,
    world_seed: ?u64 = null,
    force_new_world: bool = false,
    worlds_root: []const u8 = persistence.default_worlds_root,
    world_difficulty: ?persistence.Difficulty = null,
    world_description: ?[]const u8 = null,
    scenario: TestScenario = .none,
    scenario_output: ?[]const u8 = null,
    scenario_settle_frames: u32 = 120,
    profile_log: ?[]const u8 = null,
    profile_frames: u32 = 600,
};

const WorldSelectionResult = struct {
    name: []u8,
    seed: ?u64,
    force_new: bool,
    difficulty: persistence.Difficulty,
};

fn generateRandomSeed() u64 {
    const ns = std.time.nanoTimestamp();
    const abs_ns: u128 = if (ns < 0) @intCast(-ns) else @intCast(ns);
    const base_seed: u64 = @truncate(abs_ns);
    var prng = std.Random.DefaultPrng.init(base_seed ^ 0x9E3779B97F4A7C15);
    return prng.random().int(u64);
}

pub fn parseScenario(value: []const u8) ParseScenarioError!TestScenario {
    if (std.ascii.eqlIgnoreCase(value, "lod-sweep")) return .lod_sweep;
    if (std.ascii.eqlIgnoreCase(value, "lod_sweep")) return .lod_sweep;
    return error.InvalidScenario;
}

fn runScenarioLodSweep(
    allocator: std.mem.Allocator,
    options: DemoOptions,
    metal_ctx: *metal.MetalContext,
    chunk_manager: *streaming.ChunkStreamingManager,
    player_physics: *player.PlayerPhysics,
    main_camera: *camera.Camera,
    model_matrix: math.Mat4,
    mesher: *mesh.GreedyMesher,
    mesh_cache: *std.AutoHashMap(u64, CachedMesh),
    combined_vertices: *std.ArrayListUnmanaged(metal_renderer.Vertex),
    combined_indices: *std.ArrayListUnmanaged(u32),
) !void {
    const default_dir = "screenshots";
    const base_dir = options.scenario_output orelse default_dir;
    try std.fs.cwd().makePath(base_dir);
    const sep = std.fs.path.sep_str;
    const scenario_dir = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_dir, sep, "lod_sweep" });
    defer allocator.free(scenario_dir);
    try std.fs.cwd().makePath(scenario_dir);

    std.debug.print("Running LOD sweep scenario -> {s}\n", .{scenario_dir});

    const Shot = struct {
        name: []const u8,
        offset: math.Vec3,
        look_offset: math.Vec3,
    };

    const shots = [_]Shot{
        .{ .name = "far_front", .offset = math.Vec3.init(0, 60, -160), .look_offset = math.Vec3.zero() },
        .{ .name = "mid_front", .offset = math.Vec3.init(0, 30, -80), .look_offset = math.Vec3.zero() },
        .{ .name = "east_high", .offset = math.Vec3.init(140, 60, 0), .look_offset = math.Vec3.zero() },
        .{ .name = "near_ground", .offset = math.Vec3.init(0, 6, -16), .look_offset = math.Vec3.zero() },
        .{ .name = "below", .offset = math.Vec3.init(0, -8, -10), .look_offset = math.Vec3.init(0, 6, 0) },
    };

    const settle_frames = @max(@as(usize, @intCast(options.scenario_settle_frames)), @as(usize, 1));
    const anchor = math.Vec3.init(8.0, 75.0, 8.0);

    const original_budget = chunk_manager.max_chunks_per_frame;
    const span_side: i32 = chunk_manager.view_distance * 2 + 1;
    const view_span: u32 = @as(u32, @intCast(span_side * span_side));
    chunk_manager.max_chunks_per_frame = @max(original_budget, view_span);
    defer chunk_manager.max_chunks_per_frame = original_budget;

    player_physics.is_flying = true;

    for (shots, 0..) |shot, idx| {
        const shot_position = anchor.add(shot.offset);
        player_physics.teleport(shot_position);
        main_camera.setPosition(player_physics.getEyePosition());
        main_camera.setMode(.free_cam);

        var dir = anchor.add(shot.look_offset).sub(main_camera.getPosition());
        if (dir.lengthSquared() > 0.0001) {
            dir = dir.normalize();
            const yaw = std.math.atan2(dir.z, dir.x);
            const pitch = std.math.asin(dir.y);
            main_camera.setRotation(yaw, pitch);
        } else {
            main_camera.updateVectors();
        }

        var settle: usize = 0;
        while (settle < settle_frames) : (settle += 1) {
            try chunk_manager.update(player_physics.position, main_camera.front);
            std.Thread.sleep(std.time.ns_per_ms);
        }

        var attempts: usize = 0;
        var mesh_stats = try updateGpuMeshes(allocator, chunk_manager, mesh_cache, mesher, combined_vertices, combined_indices, main_camera.getFrustum(), main_camera.getPosition(), default_meshes_per_frame);
        var mesh_changed = mesh_stats.changed;
        while (mesh_stats.changed and attempts < 3) : (attempts += 1) {
            std.Thread.sleep(std.time.ns_per_ms);
            mesh_stats = try updateGpuMeshes(allocator, chunk_manager, mesh_cache, mesher, combined_vertices, combined_indices, main_camera.getFrustum(), main_camera.getPosition(), default_meshes_per_frame);
            mesh_changed = mesh_changed or mesh_stats.changed;
        }

        const has_mesh = combined_vertices.items.len > 0 and combined_indices.items.len > 0;
        if (mesh_changed and has_mesh) {
            try metal_ctx.setMesh(std.mem.sliceAsBytes(combined_vertices.items), @sizeOf(metal_renderer.Vertex), combined_indices.items);
        }

        try metal_ctx.setLineMesh(&[_]u8{}, @sizeOf(metal_renderer.Vertex));
        try metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex));

        const shot_file = try std.fmt.allocPrint(allocator, "{s}-{d:02}.png", .{ shot.name, idx + 1 });
        defer allocator.free(shot_file);
        const shot_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ scenario_dir, sep, shot_file });
        defer allocator.free(shot_path);

        try metal_ctx.requestCapture(shot_path);

        const view = main_camera.getViewMatrix();
        const projection = main_camera.getProjectionMatrix();
        const camera_pos = main_camera.getPosition();

        const time_of_day: f32 = 0.55;
        const sun_theta = (time_of_day * std.math.tau) - (std.math.pi / 2.0);
        const sun_dir_vec = math.Vec3.init(@cos(sun_theta), @sin(sun_theta), 0.25).normalize();
        const sun_elevation = sun_dir_vec.y;
        const base_day_factor = std.math.clamp((sun_elevation + 0.05) / 1.05, 0.0, 1.0);
        const day_factor = math.clamp(base_day_factor, 0.85, 1.0);
        const sun_intensity = lerp(1.0, 1.3, day_factor);
        const sun_color_vec = math.Vec3.init(
            lerp(0.9, 1.05, day_factor),
            lerp(0.55, 1.05, day_factor),
            lerp(0.4, 1.0, day_factor),
        ).mul(sun_intensity);
        const ambient_strength = lerp(0.2, 0.55, day_factor);
        const ambient_color_vec = math.Vec3.init(ambient_strength, ambient_strength, ambient_strength);
        const sky_color_day = math.Vec3.init(0.6, 0.78, 1.0);
        const sky_color_night = math.Vec3.init(0.02, 0.02, 0.05);
        const sky_color_vec = math.Vec3.init(
            lerp(sky_color_night.x, sky_color_day.x, day_factor),
            lerp(sky_color_night.y, sky_color_day.y, day_factor),
            lerp(sky_color_night.z, sky_color_day.z, day_factor),
        );

        if (has_mesh) {
            const vp = projection.multiply(view);
            const mvp = vp.multiply(model_matrix);
            const fog_start: f32 = 40.0;
            const fog_range: f32 = 80.0;

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
            _ = metal_ctx.renderFrame(sky_color_vec.x, sky_color_vec.y, sky_color_vec.z);
        }

        std.debug.print("Captured {s}\n", .{shot_path});
    }

    std.debug.print("LOD sweep complete. Images saved to {s}\n", .{scenario_dir});
}

fn runScenario(
    allocator: std.mem.Allocator,
    options: DemoOptions,
    metal_ctx: *metal.MetalContext,
    chunk_manager: *streaming.ChunkStreamingManager,
    player_physics: *player.PlayerPhysics,
    main_camera: *camera.Camera,
    model_matrix: math.Mat4,
    mesher: *mesh.GreedyMesher,
    mesh_cache: *std.AutoHashMap(u64, CachedMesh),
    combined_vertices: *std.ArrayListUnmanaged(metal_renderer.Vertex),
    combined_indices: *std.ArrayListUnmanaged(u32),
) !void {
    switch (options.scenario) {
        .lod_sweep => try runScenarioLodSweep(allocator, options, metal_ctx, chunk_manager, player_physics, main_camera, model_matrix, mesher, mesh_cache, combined_vertices, combined_indices),
        else => {},
    }
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

fn renameWorld(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    current_name: []const u8,
    new_name: []const u8,
) RenameWorldError!void {
    if (new_name.len == 0) return error.NameEmpty;
    if (std.mem.eql(u8, new_name, current_name)) return error.NameUnchanged;

    const exists = persistence.WorldPersistence.worldExists(allocator, worlds_root, new_name) catch {
        return error.PersistenceFailure;
    };
    if (exists) return error.AlreadyExists;

    const old_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, current_name }) catch {
        return error.PersistenceFailure;
    };
    defer allocator.free(old_path);
    const new_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, new_name }) catch {
        return error.PersistenceFailure;
    };
    defer allocator.free(new_path);

    std.fs.cwd().rename(old_path, new_path) catch {
        return error.PersistenceFailure;
    };

    const meta_path = std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, new_name }) catch {
        return error.PersistenceFailure;
    };
    defer allocator.free(meta_path);

    var metadata = persistence.WorldPersistence.loadMetadata(allocator, worlds_root, new_name) catch {
        return error.PersistenceFailure;
    };
    defer metadata.deinit(allocator);

    allocator.free(metadata.name);
    metadata.name = allocator.dupe(u8, new_name) catch {
        return error.PersistenceFailure;
    };
    metadata.last_played_timestamp = std.time.timestamp();
    metadata.save(allocator, meta_path) catch {
        return error.PersistenceFailure;
    };
}

fn setWorldSeed(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
    new_seed: u64,
) !void {
    const meta_path = std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, world_name }) catch {
        return error.PersistenceFailure;
    };
    defer allocator.free(meta_path);

    var metadata = persistence.WorldPersistence.loadMetadata(allocator, worlds_root, world_name) catch {
        return error.PersistenceFailure;
    };
    defer metadata.deinit(allocator);

    metadata.seed = new_seed;
    metadata.last_played_timestamp = std.time.timestamp();
    metadata.save(allocator, meta_path) catch {
        return error.PersistenceFailure;
    };
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
        window.stopTextInput();
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
            .difficulty = persistence.default_world_difficulty,
        };
    }

    var selection: usize = 0;
    var confirm_delete: ?usize = null;
    var status_message: []const u8 = "";
    var status_timer: f32 = 0;
    var status_buffer: [128]u8 = undefined;
    var last_settings_selection: ?usize = null;
    var settings_panel = SaveSettingsPanel{};
    defer settings_panel.deinit(allocator);
    var selected_settings = persistence.WorldSettingsSummary{
        .autosave_interval_seconds = persistence.default_autosave_interval_seconds,
        .backup_retention = persistence.default_region_backup_retention,
        .last_backup_timestamp = 0,
        .difficulty = persistence.default_world_difficulty,
        .maintenance_last_timestamp = 0,
        .maintenance_queued = 0,
        .maintenance_interval_seconds = persistence.default_backup_schedule_interval_seconds,
        .maintenance_activity_score = 0,
    };
    var renaming = false;
    var rename_buffer: [max_world_name_len]u8 = undefined;
    var rename_len: usize = 0;
    var editing_seed = false;
    var seed_buffer: [seed_digits_max]u8 = undefined;
    var seed_len: usize = 0;
    var editing_description = false;
    var description_buffer: [max_description_len]u8 = undefined;
    var description_len: usize = 0;

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
                .difficulty = persistence.default_world_difficulty,
                .maintenance_last_timestamp = 0,
                .maintenance_queued = 0,
                .maintenance_interval_seconds = persistence.default_backup_schedule_interval_seconds,
                .maintenance_activity_score = 0,
            };
        };
        last_settings_selection = selection;
        settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
            std.debug.print("Failed to prepare settings panel: {any}\n", .{err});
        };
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

        if (renaming) {
            const typed = input_state.takeTextInput();
            if (typed.len > 0) {
                var idx: usize = 0;
                while (idx < typed.len) : (idx += 1) {
                    const raw = typed[idx];
                    if ((raw & 0x80) != 0) continue;
                    var ch = raw;
                    if (std.ascii.isAlphabetic(ch)) {
                        ch = std.ascii.toUpper(ch);
                    } else if (std.ascii.isDigit(ch)) {
                        // keep as is
                    } else if (ch == '_' or ch == '-') {
                        // allow
                    } else if (ch == ' ') {
                        ch = '_';
                    } else {
                        continue;
                    }

                    if (rename_len >= max_world_name_len) {
                        status_message = "NAME TOO LONG";
                        status_timer = 2.0;
                        break;
                    }
                    rename_buffer[rename_len] = ch;
                    rename_len += 1;
                }
            }

            if (input_state.wasKeyPressed(.backspace)) {
                if (rename_len > 0) {
                    rename_len -= 1;
                }
            }

            if (input_state.wasKeyPressed(.enter)) {
                if (rename_len == 0) {
                    status_message = "NAME REQUIRED";
                    status_timer = 3.0;
                } else {
                    const sanitized = sanitizeWorldName(allocator, rename_buffer[0..rename_len]) catch |err| switch (err) {
                        error.InvalidWorldName => {
                            status_message = "INVALID NAME";
                            status_timer = 3.0;
                            continue;
                        },
                        else => return err,
                    };
                    defer allocator.free(sanitized);

                    if (std.mem.eql(u8, sanitized, infos[selection].name)) {
                        status_message = "NAME UNCHANGED";
                        status_timer = 2.0;
                        continue;
                    }

                    const exists = persistence.WorldPersistence.worldExists(allocator, worlds_root, sanitized) catch |err| {
                        status_message = std.fmt.bufPrint(&status_buffer, "Rename check failed: {any}", .{err}) catch "Rename failed";
                        status_timer = 3.0;
                        continue;
                    };
                    if (exists) {
                        status_message = "NAME ALREADY EXISTS";
                        status_timer = 3.0;
                        continue;
                    }

                    renameWorld(allocator, worlds_root, infos[selection].name, sanitized) catch |err| {
                        status_message = std.fmt.bufPrint(&status_buffer, "Rename failed: {any}", .{err}) catch "Rename failed";
                        status_timer = 3.0;
                        continue;
                    };

                    persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                    infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                    var new_selection: usize = 0;
                    for (infos, 0..) |info, idx| {
                        if (std.mem.eql(u8, info.name, sanitized)) {
                            new_selection = idx;
                            break;
                        }
                    }
                    selection = new_selection;
                    renaming = false;
                    rename_len = 0;
                    window.stopTextInput();
                    status_message = "WORLD RENAMED";
                    status_timer = 3.0;
                    last_settings_selection = null;
                    continue;
                }
            } else if (input_state.wasKeyPressed(.escape)) {
                renaming = false;
                rename_len = 0;
                window.stopTextInput();
                status_message = "Rename canceled";
                status_timer = 2.0;
                continue;
            }

            var overlay_settings: ?persistence.WorldSettingsSummary = null;
            if (selection < infos.len) {
                overlay_settings = selected_settings;
            }

            try renderWorldSelectionOverlay(
                allocator,
                metal_ctx,
                infos,
                selection,
                null,
                status_message,
                overlay_settings,
                rename_buffer[0..rename_len],
                null,
                null,
                null,
                window.width,
                window.height,
            );

            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

        if (editing_seed) {
            const typed_seed = input_state.takeTextInput();
            if (typed_seed.len > 0) {
                for (typed_seed) |raw| {
                    if (raw >= '0' and raw <= '9') {
                        if (seed_len < seed_digits_max) {
                            seed_buffer[seed_len] = raw;
                            seed_len += 1;
                        } else {
                            status_message = "SEED TOO LONG";
                            status_timer = 2.0;
                            break;
                        }
                    }
                }
            }

            if (input_state.wasKeyPressed(.backspace)) {
                if (seed_len > 0) seed_len -= 1;
            }

            if (input_state.wasKeyPressed(.r)) {
                const random_seed = generateRandomSeed();
                var tmp: [seed_digits_max]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}", .{random_seed}) catch "0";
                const count = @min(slice.len, seed_digits_max);
                std.mem.copyForwards(u8, seed_buffer[0..count], slice[0..count]);
                seed_len = count;
                status_message = std.fmt.bufPrint(&status_buffer, "Random seed staged: {d}", .{random_seed}) catch "Random seed";
                status_timer = 3.0;
            }

            if (input_state.wasKeyPressed(.enter)) {
                var new_seed: u64 = undefined;
                if (seed_len == 0) {
                    new_seed = generateRandomSeed();
                    var tmp: [seed_digits_max]u8 = undefined;
                    const slice = std.fmt.bufPrint(&tmp, "{d}", .{new_seed}) catch "0";
                    const count = @min(slice.len, seed_digits_max);
                    std.mem.copyForwards(u8, seed_buffer[0..count], slice[0..count]);
                    seed_len = count;
                } else {
                    new_seed = std.fmt.parseInt(u64, seed_buffer[0..seed_len], 10) catch {
                        status_message = "INVALID SEED";
                        status_timer = 3.0;
                        continue;
                    };
                }

                const current_name_copy = try allocator.dupe(u8, infos[selection].name);
                defer allocator.free(current_name_copy);

                setWorldSeed(allocator, worlds_root, current_name_copy, new_seed) catch |err| {
                    status_message = std.fmt.bufPrint(&status_buffer, "Seed update failed: {any}", .{err}) catch "Seed update failed";
                    status_timer = 3.0;
                    continue;
                };

                persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                var new_selection: usize = 0;
                for (infos, 0..) |info, idx| {
                    if (std.mem.eql(u8, info.name, current_name_copy)) {
                        new_selection = idx;
                        break;
                    }
                }
                selection = new_selection;
                editing_seed = false;
                seed_len = 0;
                window.stopTextInput();
                status_message = std.fmt.bufPrint(&status_buffer, "Seed set to {d}", .{new_seed}) catch "Seed updated";
                status_timer = 3.0;
                last_settings_selection = null;
                continue;
            } else if (input_state.wasKeyPressed(.escape)) {
                editing_seed = false;
                seed_len = 0;
                window.stopTextInput();
                status_message = "Seed edit canceled";
                status_timer = 2.0;
                continue;
            }

            var overlay_settings_seed: ?persistence.WorldSettingsSummary = null;
            if (selection < infos.len) overlay_settings_seed = selected_settings;

            try renderWorldSelectionOverlay(
                allocator,
                metal_ctx,
                infos,
                selection,
                null,
                status_message,
                overlay_settings_seed,
                null,
                seed_buffer[0..seed_len],
                null,
                null,
                window.width,
                window.height,
            );

            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

        if (editing_description) {
            const typed_desc = input_state.takeTextInput();
            if (typed_desc.len > 0) {
                for (typed_desc) |raw| {
                    if (raw == '\r' or raw == '\n') continue;
                    if (raw >= 32 and raw <= 126) {
                        if (description_len < max_description_len) {
                            description_buffer[description_len] = raw;
                            description_len += 1;
                        } else {
                            status_message = "DESC TOO LONG";
                            status_timer = 2.0;
                            break;
                        }
                    }
                }
            }

            if (input_state.wasKeyPressed(.backspace)) {
                if (description_len > 0) description_len -= 1;
            }

            if (input_state.wasKeyPressed(.enter)) {
                const new_desc = description_buffer[0..description_len];
                persistence.setWorldDescription(allocator, worlds_root, infos[selection].name, new_desc) catch |err| {
                    status_message = std.fmt.bufPrint(&status_buffer, "Desc update failed: {any}", .{err}) catch "Desc update failed";
                    status_timer = 3.0;
                    continue;
                };
                persistence.WorldPersistence.freeWorldInfoList(allocator, infos);
                infos = try persistence.WorldPersistence.listWorlds(allocator, worlds_root);
                if (selection >= infos.len) selection = infos.len - 1;
                editing_description = false;
                description_len = 0;
                window.stopTextInput();
                status_message = "DESCRIPTION SAVED";
                status_timer = 3.0;
                last_settings_selection = null;
                continue;
            } else if (input_state.wasKeyPressed(.escape)) {
                editing_description = false;
                description_len = 0;
                window.stopTextInput();
                status_message = "Description edit canceled";
                status_timer = 2.0;
                continue;
            }

            var overlay_settings_desc: ?persistence.WorldSettingsSummary = null;
            if (selection < infos.len) overlay_settings_desc = selected_settings;

            try renderWorldSelectionOverlay(
                allocator,
                metal_ctx,
                infos,
                selection,
                null,
                status_message,
                overlay_settings_desc,
                null,
                null,
                description_buffer[0..description_len],
                null,
                window.width,
                window.height,
            );

            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

        if (input_state.wasKeyPressed(.down)) {
            selection = (selection + 1) % option_count;
            confirm_delete = null;
            last_settings_selection = null;
            settings_panel.open = false;
        } else if (input_state.wasKeyPressed(.up)) {
            selection = (selection + option_count - 1) % option_count;
            confirm_delete = null;
            last_settings_selection = null;
            settings_panel.open = false;
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
                        .difficulty = persistence.default_world_difficulty,
                        .maintenance_last_timestamp = 0,
                        .maintenance_queued = 0,
                        .maintenance_interval_seconds = persistence.default_backup_schedule_interval_seconds,
                        .maintenance_activity_score = 0,
                    };
                };
                last_settings_selection = selection;
                settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
                    std.debug.print("Failed to prepare settings panel: {any}\n", .{err});
                };
            }
        } else {
            last_settings_selection = null;
            settings_panel.open = false;
        }

        if (settings_panel.open and selection < infos.len) {
            if (input_state.wasKeyPressed(.escape) or input_state.wasKeyPressed(.f6)) {
                settings_panel.open = false;
                continue;
            }

            var panel_selection = settings_panel.selection;
            if (input_state.wasKeyPressed(.down)) {
                if (panel_selection < 1) panel_selection += 1;
            } else if (input_state.wasKeyPressed(.up)) {
                if (panel_selection > 0) panel_selection -= 1;
            }
            settings_panel.selection = panel_selection;

            if (input_state.wasKeyPressed(.right) or input_state.wasKeyPressed(.left)) {
                const dir: i32 = if (input_state.wasKeyPressed(.right)) 1 else -1;
                switch (settings_panel.selection) {
                    0 => {
                        if (settings_panel.autosave_options.items.len > 0) {
                            const len_i32: i32 = @intCast(settings_panel.autosave_options.items.len);
                            const next = @mod(@as(i32, @intCast(settings_panel.autosave_index)) + dir + len_i32, len_i32);
                            const new_index: usize = @intCast(next);
                            const new_value = settings_panel.autosave_options.items[new_index];
                            if (new_value != selected_settings.autosave_interval_seconds) {
                                const world_name = infos[selection].name;
                                const autosave_success = blk: {
                                    persistence.setWorldAutosaveInterval(allocator, worlds_root, world_name, new_value) catch |err| {
                                        std.debug.print("Failed to update autosave interval for '{s}': {any}\n", .{ world_name, err });
                                        status_message = "AUTOSAVE UPDATE FAILED";
                                        status_timer = 3.0;
                                        break :blk false;
                                    };
                                    break :blk true;
                                };
                                if (autosave_success) {
                                    settings_panel.autosave_index = new_index;
                                    selected_settings.autosave_interval_seconds = new_value;
                                    status_message = if (new_value == 0)
                                        "AUTOSAVE OFF"
                                    else
                                        std.fmt.bufPrint(&status_buffer, "AUTOSAVE EVERY {d}s", .{new_value}) catch "AUTOSAVE UPDATED";
                                    status_timer = 3.0;
                                    std.debug.print("World '{s}' autosave interval set to {d} seconds.\n", .{ world_name, new_value });
                                }
                            }
                        }
                    },
                    1 => {
                        if (settings_panel.backup_options.items.len > 0) {
                            const len_i32: i32 = @intCast(settings_panel.backup_options.items.len);
                            const next = @mod(@as(i32, @intCast(settings_panel.backup_index)) + dir + len_i32, len_i32);
                            const new_index: usize = @intCast(next);
                            const new_value = settings_panel.backup_options.items[new_index];
                            if (new_value != selected_settings.backup_retention) {
                                const world_name = infos[selection].name;
                                const backup_success = blk: {
                                    persistence.setWorldBackupRetention(allocator, worlds_root, world_name, new_value) catch |err| {
                                        std.debug.print("Failed to update backups retention for '{s}': {any}\n", .{ world_name, err });
                                        status_message = "BACKUPS UPDATE FAILED";
                                        status_timer = 3.0;
                                        break :blk false;
                                    };
                                    break :blk true;
                                };
                                if (backup_success) {
                                    settings_panel.backup_index = new_index;
                                    selected_settings.backup_retention = new_value;
                                    status_message = std.fmt.bufPrint(&status_buffer, "BACKUPS KEEP {d}", .{new_value}) catch "BACKUPS UPDATED";
                                    status_timer = 3.0;
                                    std.debug.print("World '{s}' backup retention set to {d}.\n", .{ world_name, new_value });
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            try renderWorldSelectionOverlay(
                allocator,
                metal_ctx,
                infos,
                selection,
                confirm_delete,
                status_message,
                selected_settings,
                null,
                null,
                null,
                window.width,
                window.height,
                .{
                    .open = true,
                    .selection = settings_panel.selection,
                    .autosave = settings_panel.autosave_options.items,
                    .autosave_index = settings_panel.autosave_index,
                    .backup = settings_panel.backup_options.items,
                    .backup_index = settings_panel.backup_index,
                },
            );

            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

        var panel_view: ?SaveSettingsPanelView = null;
        if (settings_panel.open and selection < infos.len) {
            panel_view = SaveSettingsPanelView{
                .open = true,
                .selection = settings_panel.selection,
                .autosave = settings_panel.autosave_options.items,
                .autosave_index = settings_panel.autosave_index,
                .backup = settings_panel.backup_options.items,
                .backup_index = settings_panel.backup_index,
            };
        }

        if (selection < infos.len and input_state.wasKeyPressed(.f10)) {
            editing_description = true;
            renaming = false;
            editing_seed = false;
            rename_len = 0;
            seed_len = 0;
            description_len = 0;
            if (infos[selection].description.len > 0) {
                const copy_len = @min(infos[selection].description.len, max_description_len);
                std.mem.copyForwards(u8, description_buffer[0..copy_len], infos[selection].description[0..copy_len]);
                description_len = copy_len;
            }
            window.startTextInput();
            status_message = "EDIT DESCRIPTION - ENTER confirm, ESC cancel";
            status_timer = 0;
            confirm_delete = null;
            continue;
        }

        if (!renaming and !editing_seed and !editing_description and selection < infos.len) {
            var diff_delta: i32 = 0;
            if (input_state.wasKeyPressed(.f1)) diff_delta -= 1;
            if (input_state.wasKeyPressed(.f2)) diff_delta += 1;
            if (diff_delta != 0) {
                const current_diff = selected_settings.difficulty;
                const new_diff = cycleDifficulty(current_diff, diff_delta);
                if (new_diff != current_diff) {
                    persistence.setWorldDifficulty(allocator, worlds_root, infos[selection].name, new_diff) catch |err| {
                        status_message = std.fmt.bufPrint(&status_buffer, "Difficulty update failed: {any}", .{err}) catch "Difficulty update failed";
                        status_timer = 3.0;
                        continue;
                    };

                    selected_settings.difficulty = new_diff;
                    infos[selection].difficulty = new_diff;
                    status_message = std.fmt.bufPrint(&status_buffer, "Difficulty: {s}", .{difficultyLabelShort(new_diff)}) catch "Difficulty updated";
                    status_timer = 3.0;
                    continue;
                }
            }
        }

        if (!renaming and !editing_seed and !editing_description and selection < infos.len and input_state.wasKeyPressed(.f6)) {
            settings_panel.open = !settings_panel.open;
            if (settings_panel.open) {
                settings_panel.selection = 0;
            }
        }

        if (selection < infos.len and input_state.wasKeyPressed(.r)) {
            renaming = true;
            editing_seed = false;
            seed_len = 0;
            rename_len = 0;
            const current = infos[selection].name;
            const limit = @min(current.len, max_world_name_len);
            if (limit > 0) {
                std.mem.copyForwards(u8, rename_buffer[0..limit], current[0..limit]);
                rename_len = limit;
            }
            window.startTextInput();
            status_message = "RENAME WORLD - ENTER confirm, ESC cancel";
            status_timer = 0;
            confirm_delete = null;
            continue;
        }

        if (selection < infos.len and input_state.wasKeyPressed(.s)) {
            editing_seed = true;
            renaming = false;
            rename_len = 0;
            seed_len = 0;
            var tmp_seed: [seed_digits_max]u8 = undefined;
            const slice = std.fmt.bufPrint(&tmp_seed, "{d}", .{infos[selection].seed}) catch null;
            if (slice) |s| {
                const count = @min(s.len, seed_digits_max);
                std.mem.copyForwards(u8, seed_buffer[0..count], s[0..count]);
                seed_len = count;
            }
            window.startTextInput();
            status_message = "EDIT SEED - digits only, blank = random, R = reroll";
            status_timer = 0;
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
                    std.debug.print("Deleted world '{s}'.\n", .{target});
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
                            .difficulty = persistence.default_world_difficulty,
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
                    std.debug.print("Press Delete again to confirm removal of '{s}'.\n", .{infos[selection].name});
                }
            } else {
                confirm_delete = selection;
                status_message = "PRESS DELETE AGAIN TO CONFIRM";
                status_timer = 3.0;
                std.debug.print("Press Delete again to confirm removal of '{s}'.\n", .{infos[selection].name});
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
                        settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
                            std.debug.print("Failed to refresh settings panel after autosave change: {any}\n", .{err});
                        };
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
                            settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
                                std.debug.print("Failed to refresh settings panel after backups change: {any}\n", .{err});
                            };
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
                            settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
                                std.debug.print("Failed to refresh settings panel after backups change: {any}\n", .{err});
                            };
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
                            .difficulty = persistence.default_world_difficulty,
                            .maintenance_last_timestamp = 0,
                            .maintenance_queued = 0,
                            .maintenance_interval_seconds = persistence.default_backup_schedule_interval_seconds,
                            .maintenance_activity_score = 0,
                        };
                    };
                    infos[selection].difficulty = selected_settings.difficulty;
                    settings_panel.refresh(allocator, selected_settings.autosave_interval_seconds, selected_settings.backup_retention) catch |err| {
                        std.debug.print("Failed to refresh settings panel after reset: {any}\n", .{err});
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
                    .difficulty = selected_settings.difficulty,
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
                    .difficulty = persistence.default_world_difficulty,
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
            null,
            null,
            null,
            panel_view,
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
    rename_text: ?[]const u8,
    seed_text: ?[]const u8,
    description_text: ?[]const u8,
    settings_panel: ?SaveSettingsPanelView,
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

            const diff_value = if (selected_settings) |settings| settings.difficulty else infos[idx].difficulty;
            const diff_text = std.fmt.bufPrint(&buf, "DIFFICULTY: {s}", .{difficultyLabelShort(diff_value)}) catch "DIFFICULTY";
            max_width = @max(max_width, line_text.textWidth(diff_text, text_scale));
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

                const maintenance_seconds = settings.maintenance_interval_seconds;
                const maintenance_minutes = if (maintenance_seconds == 0)
                    0
                else
                    @divFloor(maintenance_seconds + 59, 60);
                const maintenance_text = if (maintenance_seconds == 0)
                    "MAINT: OFF"
                else
                    std.fmt.bufPrint(&buf, "MAINT: EVERY {d}m", .{maintenance_minutes}) catch "MAINT";
                max_width = @max(max_width, line_text.textWidth(maintenance_text, text_scale));
                line_count += 1;

                const maint_queue_text = std.fmt.bufPrint(&buf, "MAINT: QUEUED {d}", .{settings.maintenance_queued}) catch "MAINT QUEUED";
                max_width = @max(max_width, line_text.textWidth(maint_queue_text, text_scale));
                line_count += 1;

                const maint_activity_text = std.fmt.bufPrint(&buf, "MAINT: ACT {d:.1}", .{settings.maintenance_activity_score}) catch "MAINT ACT";
                max_width = @max(max_width, line_text.textWidth(maint_activity_text, text_scale));
                line_count += 1;

                const ts_str = formatTimestamp(&timestamp_buf, settings.last_backup_timestamp);
                const backup_last_text = std.fmt.bufPrint(&buf, "BACKUP: LAST {s}", .{ts_str}) catch "BACKUP LAST";
                max_width = @max(max_width, line_text.textWidth(backup_last_text, text_scale));
                line_count += 1;

                const maint_last_str = formatTimestamp(&timestamp_buf, settings.maintenance_last_timestamp);
                const maint_last_text = std.fmt.bufPrint(&buf, "MAINT: LAST {s}", .{maint_last_str}) catch "MAINT LAST";
                max_width = @max(max_width, line_text.textWidth(maint_last_text, text_scale));
                line_count += 1;
            }

            if (rename_text) |text| {
                const rename_preview = std.fmt.bufPrint(&buf, "RENAME: {s}_", .{text}) catch "RENAME";
                max_width = @max(max_width, line_text.textWidth(rename_preview, text_scale));
                line_count += 1;
                max_width = @max(max_width, line_text.textWidth("ENTER confirm  ESC cancel", text_scale));
                line_count += 1;
            }

            if (seed_text) |text| {
                const seed_preview = if (text.len == 0)
                    "SEED: _"
                else
                    std.fmt.bufPrint(&buf, "SEED: {s}_", .{text}) catch "SEED";
                max_width = @max(max_width, line_text.textWidth(seed_preview, text_scale));
                line_count += 1;
                max_width = @max(max_width, line_text.textWidth("ENTER confirm  ESC cancel  R random (blank=random)", text_scale));
                line_count += 1;
            }

            if (description_text) |text| {
                const preview_slice = if (text.len > 64) text[0..64] else text;
                const desc_preview = std.fmt.bufPrint(&buf, "DESC: {s}_", .{preview_slice}) catch "DESC";
                max_width = @max(max_width, line_text.textWidth(desc_preview, text_scale));
                line_count += 1;
                max_width = @max(max_width, line_text.textWidth("ENTER confirm  ESC cancel", text_scale));
                line_count += 1;
            } else if (info.description.len > 0) {
                const desc_slice = if (info.description.len > 64)
                    info.description[0..64]
                else
                    info.description;
                const desc_line = std.fmt.bufPrint(&buf, "DESC: {s}", .{desc_slice}) catch "DESC";
                max_width = @max(max_width, line_text.textWidth(desc_line, text_scale));
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
    const instructions_secondary = "F1/F2 DIFFICULTY  F5 AUTOSAVE  F6 SETTINGS  F7/F8 BACKUPS  F9 RESET  F10 DESC  F11 BACKUP";
    max_width = @max(max_width, line_text.textWidth(instructions_primary, text_scale));
    line_count += 1;
    max_width = @max(max_width, line_text.textWidth(instructions_secondary, text_scale));
    line_count += 1;

    const panel_hint = if (settings_panel) |panel| if (panel.open)
        "PANEL: UP/DOWN SELECT  LEFT/RIGHT CHANGE  ESC CLOSE"
    else
        null
    else
        null;
    if (panel_hint) |hint| {
        max_width = @max(max_width, line_text.textWidth(hint, text_scale));
        line_count += 1;
    }

    const main_panel_width = max_width + padding * 2.0;
    const main_panel_height = @as(f32, @floatFromInt(line_count)) * line_height + padding * 2.0;

    try line_text.appendQuad(
        &builder,
        allocator,
        origin_px,
        origin_px.add(math.Vec2.init(main_panel_width, main_panel_height)),
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

            const diff_value = if (selected_settings) |settings| settings.difficulty else infos[idx].difficulty;
            const diff_line = std.fmt.bufPrint(&buf, "DIFFICULTY: {s}", .{difficultyLabelShort(diff_value)}) catch "DIFFICULTY";
            try line_text.appendText(&builder, allocator, diff_line, cursor, text_scale, screen_size, [4]f32{ 0.95, 0.9, 0.7, 1.0 });
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

                const maintenance_seconds = settings.maintenance_interval_seconds;
                const maintenance_minutes = if (maintenance_seconds == 0)
                    0
                else
                    @divFloor(maintenance_seconds + 59, 60);
                const maintenance_line = if (maintenance_seconds == 0)
                    "MAINT: OFF"
                else
                    std.fmt.bufPrint(&buf, "MAINT: EVERY {d}m", .{maintenance_minutes}) catch "MAINT";
                try line_text.appendText(&builder, allocator, maintenance_line, cursor, text_scale, screen_size, [4]f32{ 0.7, 0.9, 1.0, 1.0 });
                cursor.y += line_height;

                const maintenance_queue_line = std.fmt.bufPrint(&buf, "MAINT: QUEUED {d}", .{settings.maintenance_queued}) catch "MAINT QUEUED";
                try line_text.appendText(&builder, allocator, maintenance_queue_line, cursor, text_scale, screen_size, [4]f32{ 0.7, 0.9, 1.0, 1.0 });
                cursor.y += line_height;

                const maintenance_activity_line = std.fmt.bufPrint(&buf, "MAINT: ACT {d:.1}", .{settings.maintenance_activity_score}) catch "MAINT ACT";
                try line_text.appendText(&builder, allocator, maintenance_activity_line, cursor, text_scale, screen_size, [4]f32{ 0.68, 0.92, 0.86, 1.0 });
                cursor.y += line_height;

                const ts_str = formatTimestamp(&timestamp_buf, settings.last_backup_timestamp);
                const last_backup_line = std.fmt.bufPrint(&buf, "BACKUP: LAST {s}", .{ts_str}) catch "BACKUP LAST";
                try line_text.appendText(&builder, allocator, last_backup_line, cursor, text_scale, screen_size, [4]f32{ 0.8, 0.85, 1.0, 1.0 });
                cursor.y += line_height;

                const maintenance_last_str = formatTimestamp(&timestamp_buf, settings.maintenance_last_timestamp);
                const maintenance_last_line = std.fmt.bufPrint(&buf, "MAINT: LAST {s}", .{maintenance_last_str}) catch "MAINT LAST";
                try line_text.appendText(&builder, allocator, maintenance_last_line, cursor, text_scale, screen_size, [4]f32{ 0.7, 0.9, 1.0, 1.0 });
                cursor.y += line_height;
            }

            if (rename_text) |text| {
                const rename_line = std.fmt.bufPrint(&buf, "RENAME: {s}_", .{text}) catch "RENAME";
                try line_text.appendText(&builder, allocator, rename_line, cursor, text_scale, screen_size, [4]f32{ 1.0, 0.95, 0.7, 1.0 });
                cursor.y += line_height;

                const rename_hint = "ENTER confirm  ESC cancel";
                try line_text.appendText(&builder, allocator, rename_hint, cursor, text_scale, screen_size, [4]f32{ 0.85, 0.9, 1.0, 1.0 });
                cursor.y += line_height;
            }

            if (seed_text) |text| {
                const seed_line = if (text.len == 0)
                    "SEED: _"
                else
                    std.fmt.bufPrint(&buf, "SEED: {s}_", .{text}) catch "SEED";
                try line_text.appendText(&builder, allocator, seed_line, cursor, text_scale, screen_size, [4]f32{ 0.95, 0.85, 0.7, 1.0 });
                cursor.y += line_height;

                const seed_hint = "ENTER confirm  ESC cancel  R random (blank=random)";
                try line_text.appendText(&builder, allocator, seed_hint, cursor, text_scale, screen_size, [4]f32{ 0.8, 0.9, 1.0, 1.0 });
                cursor.y += line_height;
            }

            if (description_text) |text| {
                const preview_slice = if (text.len > 64) text[0..64] else text;
                const desc_line = std.fmt.bufPrint(&buf, "DESC: {s}_", .{preview_slice}) catch "DESC";
                try line_text.appendText(&builder, allocator, desc_line, cursor, text_scale, screen_size, [4]f32{ 0.9, 0.95, 0.85, 1.0 });
                cursor.y += line_height;

                const desc_hint = "ENTER confirm  ESC cancel";
                try line_text.appendText(&builder, allocator, desc_hint, cursor, text_scale, screen_size, [4]f32{ 0.8, 0.9, 1.0, 1.0 });
                cursor.y += line_height;
            } else if (info.description.len > 0) {
                const desc_slice = if (info.description.len > 64)
                    info.description[0..64]
                else
                    info.description;
                const desc_line = std.fmt.bufPrint(&buf, "DESC: {s}", .{desc_slice}) catch "DESC";
                try line_text.appendText(&builder, allocator, desc_line, cursor, text_scale, screen_size, [4]f32{ 0.9, 0.95, 0.85, 1.0 });
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
    cursor.y += line_height;
    if (panel_hint) |hint| {
        try line_text.appendText(&builder, allocator, hint, cursor, text_scale, screen_size, [4]f32{ 0.6, 0.78, 1.0, 1.0 });
        cursor.y += line_height;
    }

    if (settings_panel) |panel| {
        if (panel.open) {
            var settings_width = line_text.textWidth("SAVE SETTINGS", text_scale);
            var settings_lines: usize = 1;

            var autosave_value_buf: [32]u8 = undefined;
            var autosave_line_buf: [96]u8 = undefined;
            const autosave_value = if (panel.autosave.len == 0) persistence.default_autosave_interval_seconds else panel.autosave[panel.autosave_index];
            const autosave_text: []const u8 = if (panel.autosave.len == 0)
                "N/A"
            else if (autosave_value == 0)
                "OFF"
            else
                std.fmt.bufPrint(&autosave_value_buf, "{d}s", .{autosave_value}) catch "ERR";
            const autosave_line = std.fmt.bufPrint(&autosave_line_buf, "{s} AUTOSAVE: {s}", .{ if (panel.selection == 0) ">" else " ", autosave_text }) catch "AUTOSAVE";
            settings_width = @max(settings_width, line_text.textWidth(autosave_line, text_scale));
            settings_lines += 1;

            var backup_line_buf: [96]u8 = undefined;
            const backup_value = if (panel.backup.len == 0) persistence.default_region_backup_retention else panel.backup[panel.backup_index];
            const backup_line = std.fmt.bufPrint(&backup_line_buf, "{s} BACKUPS: KEEP {d}", .{ if (panel.selection == 1) ">" else " ", backup_value }) catch "BACKUPS";
            settings_width = @max(settings_width, line_text.textWidth(backup_line, text_scale));
            settings_lines += 1;

            const settings_hint = "UP/DOWN select field";
            const settings_hint2 = "LEFT/RIGHT change  ESC/F6 close";
            settings_width = @max(settings_width, line_text.textWidth(settings_hint, text_scale));
            settings_width = @max(settings_width, line_text.textWidth(settings_hint2, text_scale));
            settings_lines += 2;

            const settings_panel_width = settings_width + padding * 2.0;
            const settings_panel_height = @as(f32, @floatFromInt(settings_lines)) * line_height + padding * 2.0;
            const offset = math.Vec2.init(main_panel_width + 32.0, 0.0);
            const settings_origin = origin_px.add(offset);

            try line_text.appendQuad(
                &builder,
                allocator,
                settings_origin,
                settings_origin.add(math.Vec2.init(settings_panel_width, settings_panel_height)),
                screen_size,
                [4]f32{ 0.08, 0.1, 0.16, 0.92 },
            );

            var settings_cursor = settings_origin.add(math.Vec2.init(padding, padding));
            try line_text.appendText(&builder, allocator, "SAVE SETTINGS", settings_cursor, text_scale, screen_size, [4]f32{ 0.88, 0.94, 1.0, 1.0 });
            settings_cursor.y += line_height;

            const autosave_color = if (panel.selection == 0) [4]f32{ 1.0, 0.92, 0.62, 1.0 } else [4]f32{ 0.7, 0.86, 1.0, 1.0 };
            try line_text.appendText(&builder, allocator, autosave_line, settings_cursor, text_scale, screen_size, autosave_color);
            settings_cursor.y += line_height;

            const backup_color = if (panel.selection == 1) [4]f32{ 0.8, 1.0, 0.75, 1.0 } else [4]f32{ 0.68, 0.9, 0.78, 1.0 };
            try line_text.appendText(&builder, allocator, backup_line, settings_cursor, text_scale, screen_size, backup_color);
            settings_cursor.y += line_height;

            try line_text.appendText(&builder, allocator, settings_hint, settings_cursor, text_scale, screen_size, [4]f32{ 0.62, 0.82, 0.98, 1.0 });
            settings_cursor.y += line_height;
            try line_text.appendText(&builder, allocator, settings_hint2, settings_cursor, text_scale, screen_size, [4]f32{ 0.62, 0.82, 0.98, 1.0 });
        }
    }

    if (builder.items.len == 0) {
        try metal_ctx.setUIMesh(&[_]u8{}, @sizeOf(line_text.UIVertex));
    } else {
        const bytes = std.mem.sliceAsBytes(builder.items);
        try metal_ctx.setUIMesh(bytes, @sizeOf(line_text.UIVertex));
    }

    try metal_ctx.draw(.{ 0.05, 0.08, 0.12, 1.0 });
}

const MeshDetail = streaming.ChunkDetail;

const CachedMesh = struct {
    vertices: []metal_renderer.Vertex,
    indices: []u32,
    in_use: bool,
    selected: bool,
    detail: MeshDetail,
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
    full_chunks: usize,
    medium_chunks: usize,
    far_chunks: usize,
    regenerations: usize,
};

const max_render_chunks: usize = 192;
const max_vertex_budget: usize = 18_000_000;
const max_index_budget: usize = max_vertex_budget * 3;
const medium_start_distance: f32 = 24.0;
const far_start_distance: f32 = 64.0;
const medium_distance_sq: f32 = medium_start_distance * medium_start_distance;
const far_distance_sq: f32 = far_start_distance * far_start_distance;
const medium_cell_size: usize = 2;
const far_cell_size: usize = 4;
const default_meshes_per_frame: usize = 3;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return math.lerp(a, b, t);
}

fn resolveTargetDetail(previous: MeshDetail, dist2: f32) MeshDetail {
    var target = previous;
    switch (previous) {
        .full => {
            if (dist2 > far_distance_sq + far_distance_sq * 0.1) {
                target = .surfaceFar;
            } else if (dist2 > medium_distance_sq + medium_distance_sq * 0.1) {
                target = .surfaceMedium;
            }
        },
        .surfaceMedium => {
            if (dist2 > far_distance_sq + far_distance_sq * 0.1) {
                target = .surfaceFar;
            } else if (dist2 < medium_distance_sq * 0.85) {
                target = .full;
            }
        },
        .surfaceFar => {
            if (dist2 < medium_distance_sq * 0.85) {
                target = .full;
            } else if (dist2 < far_distance_sq * 0.8) {
                target = .surfaceMedium;
            }
        },
    }
    return target;
}

test "resolveTargetDetail degrades at distance thresholds" {
    const medium_sq = medium_distance_sq;
    const far_sq = far_distance_sq;

    try std.testing.expect(resolveTargetDetail(.full, medium_sq * 1.05) == .full);
    try std.testing.expect(resolveTargetDetail(.full, medium_sq * 1.12) == .surfaceMedium);
    try std.testing.expect(resolveTargetDetail(.full, far_sq * 1.15) == .surfaceFar);
}

test "resolveTargetDetail upgrades with hysteresis" {
    const medium_sq = medium_distance_sq;
    const far_sq = far_distance_sq;

    try std.testing.expect(resolveTargetDetail(.surfaceFar, far_sq * 0.95) == .surfaceFar);
    try std.testing.expect(resolveTargetDetail(.surfaceFar, far_sq * 0.75) == .surfaceMedium);
    try std.testing.expect(resolveTargetDetail(.surfaceMedium, medium_sq * 0.9) == .surfaceMedium);
    try std.testing.expect(resolveTargetDetail(.surfaceMedium, medium_sq * 0.8) == .full);
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
    const outline_color = [4]f32{ 2.5, 2.5, 2.5, 1.0 };
    const normal = [3]f32{ 0.0, 0.0, 0.0 };
    const uv = [2]f32{ 0.0, 0.0 };

    var vertices = try allocator.alloc(metal_renderer.Vertex, 24);

    // Bottom edges
    vertices[0] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[1] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[2] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[3] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[4] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[5] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[6] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[7] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = outline_color };

    // Top edges
    vertices[8] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[9] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[10] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[11] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[12] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[13] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[14] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[15] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = outline_color };

    // Vertical edges
    vertices[16] = .{ .position = corners[0], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[17] = .{ .position = corners[4], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[18] = .{ .position = corners[1], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[19] = .{ .position = corners[5], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[20] = .{ .position = corners[2], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[21] = .{ .position = corners[6], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[22] = .{ .position = corners[3], .normal = normal, .tex_coord = uv, .color = outline_color };
    vertices[23] = .{ .position = corners[7], .normal = normal, .tex_coord = uv, .color = outline_color };

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
    max_meshes_per_frame: usize,
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
        .full_chunks = 0,
        .medium_chunks = 0,
        .far_chunks = 0,
        .regenerations = 0,
    };
    const atlas_tile_size = 1.0 / @as(f32, @floatFromInt(textures.tiles_per_row));

    // Limit mesh generation per frame to avoid stuttering
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
        const chunk_pos = streaming.ChunkPos.init(chunk_ptr.x, chunk_ptr.z);

        const current_detail = chunk_manager.getChunkDetail(chunk_pos) orelse .full;
        const previous_desired = chunk_manager.getDesiredDetail(chunk_pos) orelse current_detail;
        const dist2 = candidate.distance2;
        const target_detail = resolveTargetDetail(previous_desired, dist2);
        chunk_manager.setDesiredDetail(chunk_pos, target_detail);

        var cache_entry_ptr_opt = mesh_cache.getPtr(key);
        if (cache_entry_ptr_opt == null) {
            try mesh_cache.put(key, .{
                .vertices = &[_]metal_renderer.Vertex{},
                .indices = &[_]u32{},
                .in_use = false,
                .selected = false,
                .detail = .full,
            });
            cache_entry_ptr_opt = mesh_cache.getPtr(key);
            stats.changed = true;
        }

        const cache_entry_ptr = cache_entry_ptr_opt.?;
        var cache_entry = cache_entry_ptr.*;
        const was_selected = cache_entry.selected;

        cache_entry.selected = false;
        cache_entry.in_use = true;

        const needs_regen = chunk_ptr.modified or cache_entry.vertices.len == 0 or cache_entry.detail != target_detail;
        var regenerated = false;
        if (needs_regen) {
            if (meshes_generated_this_frame < max_meshes_per_frame) {
                if (cache_entry.vertices.len > 0) allocator.free(cache_entry.vertices);
                if (cache_entry.indices.len > 0) allocator.free(cache_entry.indices);

                var chunk_mesh = switch (target_detail) {
                    .full => try mesher.generateMesh(chunk_ptr),
                    .surfaceMedium => try mesher.generateSurfaceMesh(chunk_ptr, medium_cell_size, false),
                    .surfaceFar => try mesher.generateSurfaceMesh(chunk_ptr, far_cell_size, true),
                };
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
                cache_entry.detail = target_detail;
                stats.changed = true;
                regenerated = true;
                stats.regenerations += 1;
            } else {
                cache_entry_ptr.* = cache_entry;
                continue;
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
            chunk_manager.setChunkDetail(chunk_pos, current_detail);
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

        chunk_manager.setChunkDetail(chunk_pos, cache_entry.detail);
        switch (cache_entry.detail) {
            .full => stats.full_chunks += 1,
            .surfaceMedium => stats.medium_chunks += 1,
            .surfaceFar => stats.far_chunks += 1,
        }
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

pub fn runHeadlessProfile(allocator: std.mem.Allocator, options: DemoOptions) !void {
    const log_path = options.profile_log orelse {
        std.debug.print("Headless profile requires --profile-log <file>\n", .{});
        return;
    };
    if (std.fs.path.dirname(log_path)) |dir| {
        if (dir.len > 0) {
            std.fs.cwd().makePath(dir) catch |err| {
                std.debug.print("Failed to create profile directory '{s}': {any}\n", .{ dir, err });
                return err;
            };
        }
    }

    var file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        "frame,frame_ms,loaded_chunks,visible_chunks,rendered_chunks,culled_chunks,budget_skipped,total_vertices,total_indices,lod_full,lod_medium,lod_far,regenerations,stream_last_ms,stream_avg_ms,stream_max_ms,queued_candidates,queued_generations,completed_async,immediate_loaded,unloaded,pending_generations\n",
    );

    const difficulty = options.world_difficulty orelse .normal;
    const seed = options.world_seed orelse 0x4F4B4CF5ACED1234;
    const view_distance = viewDistanceForDifficulty(difficulty);

    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, seed, view_distance);
    defer chunk_manager.deinit();
    chunk_manager.max_chunks_per_frame = chunkBudgetForDifficulty(difficulty);
    try chunk_manager.startAsyncGeneration();

    const spawn_pos = math.Vec3.init(8.0, 75.0, 8.0);
    var player_physics = player.PlayerPhysics.init(spawn_pos);
    player_physics.is_flying = true;

    var main_camera = camera.Camera.init(player_physics.getEyePosition(), 16.0 / 9.0);
    main_camera.setMode(.free_cam);
    main_camera.pitch = -0.3;
    main_camera.updateVectors();

    var mesher = mesh.GreedyMesher.init(allocator);
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

    const expected_spawn_chunks = @as(u32, @intCast((view_distance * 2 + 1) * (view_distance * 2 + 1)));
    const original_budget = chunk_manager.max_chunks_per_frame;
    chunk_manager.max_chunks_per_frame = @max(original_budget, expected_spawn_chunks);
    var warmup: usize = 0;
    while (warmup < 240) : (warmup += 1) {
        try chunk_manager.update(player_physics.position, main_camera.front);
        std.Thread.sleep(std.time.ns_per_ms);
        if (chunk_manager.getLoadedCount() >= expected_spawn_chunks) break;
    }
    chunk_manager.max_chunks_per_frame = original_budget;

    // Prime mesh cache before recording frames
    _ = try updateGpuMeshes(
        allocator,
        &chunk_manager,
        &mesh_cache,
        &mesher,
        &combined_vertices,
        &combined_indices,
        main_camera.getFrustum(),
        main_camera.getPosition(),
        default_meshes_per_frame,
    );

    const profile_frames = if (options.profile_frames == 0) 600 else options.profile_frames;
    std.debug.print("Headless profile writing {d} frames to {s}\n", .{ profile_frames, log_path });

    var frame: u32 = 0;
    while (frame < profile_frames) : (frame += 1) {
        const frame_start = std.time.nanoTimestamp();
        try chunk_manager.update(player_physics.position, main_camera.front);
        std.Thread.sleep(std.time.ns_per_ms);
        const mesh_stats = try updateGpuMeshes(
            allocator,
            &chunk_manager,
            &mesh_cache,
            &mesher,
            &combined_vertices,
            &combined_indices,
            main_camera.getFrustum(),
            main_camera.getPosition(),
            default_meshes_per_frame,
        );
        const frame_end = std.time.nanoTimestamp();

        const frame_ms = @as(f64, @floatFromInt(frame_end - frame_start)) / 1_000_000.0;
        const streaming_stats = chunk_manager.profilingStats();
        const last_ms = @as(f64, @floatFromInt(streaming_stats.last_update_ns)) / 1_000_000.0;
        const avg_ms = streaming_stats.average_update_ns / 1_000_000.0;
        const max_ms = @as(f64, @floatFromInt(streaming_stats.max_update_ns)) / 1_000_000.0;

        var line_buffer: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "{d},{d:.3},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d},{d}\n",
            .{
                frame,
                frame_ms,
                chunk_manager.getLoadedCount(),
                mesh_stats.visible_chunks,
                mesh_stats.rendered_chunks,
                mesh_stats.culled_chunks,
                mesh_stats.budget_skipped,
                mesh_stats.total_vertices,
                mesh_stats.total_indices,
                mesh_stats.full_chunks,
                mesh_stats.medium_chunks,
                mesh_stats.far_chunks,
                mesh_stats.regenerations,
                last_ms,
                avg_ms,
                max_ms,
                streaming_stats.queued_candidates,
                streaming_stats.queued_generations,
                streaming_stats.completed_async,
                streaming_stats.immediate_loaded,
                streaming_stats.unloaded,
                streaming_stats.pending_generations,
            },
        );
        try file.writeAll(line);
    }

    var summary_buf: [64]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buf, "# completed {d} frames\n", .{profile_frames});
    try file.writeAll(summary);
    std.debug.print("Headless profile complete: {s}\n", .{log_path});
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

    // Warm up streaming so chunks load around the spawn before control is handed off.
    var warmup: usize = 0;
    while (warmup < 90) : (warmup += 1) {
        try chunk_manager.update(player_physics.position, main_camera.front);
        if (chunk_manager.getLoadedCount() >= @as(u32, @intCast((view_distance * 2 + 1) * (view_distance * 2 + 1)))) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
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
        if (summary.maintenance_enqueued) {
            const cooldown = chunk_manager.backupCooldownSecondsRemaining();
            std.debug.print(
                "[Maintenance] Queue total {d} regions (+{d}, ~{d}s cooldown)\n",
                .{ summary.queued_regions_total, summary.queued_regions_added, cooldown },
            );
            _ = chunk_manager.takeScheduledBackupNotice();
            if (chunk_manager.takeScheduledMaintenanceIntervalChange()) |seconds| {
                const minutes = if (seconds == 0)
                    0
                else
                    @divFloor(seconds + 59, 60);
                std.debug.print(
                    "[Maintenance] Cadence tuned to {d}s (~{d}m).\n",
                    .{ seconds, minutes },
                );
            }
        }
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
            if (summary.maintenance_enqueued) {
                const cooldown = chunk_manager.backupCooldownSecondsRemaining();
                std.debug.print(
                    "[Maintenance] Queue total {d} regions (+{d}, ~{d}s cooldown)\n",
                    .{ summary.queued_regions_total, summary.queued_regions_added, cooldown },
                );
                _ = chunk_manager.takeScheduledBackupNotice();
            }
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
    var requested_difficulty: ?persistence.Difficulty = options.world_difficulty;

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
            requested_difficulty = selection.difficulty;
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
        .description = options.world_description,
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

    if (requested_difficulty) |diff_override| {
        if (world_persistence.difficulty != diff_override) {
            world_persistence.setDifficulty(diff_override);
        }
    }

    const world_difficulty = world_persistence.difficulty;
    const difficulty_label = persistence.difficultyLabel(world_difficulty);
    std.debug.print("Loaded world '{s}' (seed {d}) | Difficulty: {s}\n", .{ world_name_slice, world_persistence.seed(), difficulty_label });
    const world_description = world_persistence.description();
    if (world_description.len > 0) {
        std.debug.print("Description: {s}\n", .{world_description});
    }

    const view_distance: i32 = viewDistanceForDifficulty(world_difficulty);
    std.debug.print("Chunk view distance set to {d} chunks for {s} difficulty.\n", .{ view_distance, difficulty_label });

    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, world_persistence.seed(), view_distance);
    defer chunk_manager.deinit();

    // Connect persistence to chunk manager
    chunk_manager.world_persistence = &world_persistence;
    chunk_manager.syncPersistenceSettings();
    chunk_manager.resetAutosaveTimer();

    const default_autosave_interval = autosaveIntervalForDifficulty(world_difficulty);
    chunk_manager.setAutosaveIntervalSeconds(default_autosave_interval);
    chunk_manager.max_chunks_per_frame = chunkBudgetForDifficulty(world_difficulty);

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
    var hud_notifications = std.ArrayListUnmanaged(HudNotification){};
    defer hud_notifications.deinit(allocator);
    var hud_message_buffer: [128]u8 = undefined;

    std.debug.print("Controls:\n", .{});
    std.debug.print("  Movement: WASD, Space/Ctrl (fly up/down), Shift (sprint), F (toggle fly)\n", .{});
    std.debug.print("  Blocks: Left Click (break), Right Click (place)\n", .{});
    std.debug.print("  Debug: F4 (toggle wireframe)\n", .{});
    std.debug.print("  Autosave: F5 (cycle interval), F6 (manual save)\n", .{});
    std.debug.print("  Backups: F7 (increase retention), F8 (decrease retention)\n", .{});
    std.debug.print("  ESC (unlock cursor), ESC again (quit)\n", .{});

    try chunk_manager.update(player_physics.position, main_camera.front);
    const expected_spawn_chunks = @as(u32, @intCast((view_distance * 2 + 1) * (view_distance * 2 + 1)));
    const original_chunk_budget = chunk_manager.max_chunks_per_frame;
    chunk_manager.max_chunks_per_frame = @max(original_chunk_budget, expected_spawn_chunks);
    var initial_warmup: usize = 0;
    while (initial_warmup < 240) : (initial_warmup += 1) {
        try chunk_manager.update(player_physics.position, main_camera.front);
        if (chunk_manager.getLoadedCount() >= expected_spawn_chunks) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    chunk_manager.max_chunks_per_frame = original_chunk_budget;

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
    var frame_time_avg_ms: f32 = 6.0;
    var mesh_regen_budget: usize = default_meshes_per_frame;
    const mesh_regen_medium_ms: f32 = 8.0;
    const mesh_regen_high_ms: f32 = 10.0;

    if (options.scenario != .none) {
        try runScenario(allocator, options, &metal_ctx, &chunk_manager, &player_physics, &main_camera, model_matrix, &mesher, &mesh_cache, &combined_vertices, &combined_indices);
        return;
    }

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
                std.fmt.bufPrint(&hud_message_buffer, "Autosave: every {d}s", .{chunk_manager.autosaveIntervalSeconds()}) catch "Autosave interval set";
            pushHudNotification(&hud_notifications, allocator, msg, 4.0);
        }

        if (input_state.wasKeyPressed(.f6)) {
            if (chunk_manager.forceAutosave()) |summary| {
                const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;
                std.debug.print(
                    "[Autosave] Manual save: saved {d} chunks ({d} errors) in {d:.2} ms\n",
                    .{ summary.saved_chunks, summary.errors, duration_ms },
                );
                const msg = std.fmt.bufPrint(&hud_message_buffer, "Manual save: {d} chunks ({d} errors)", .{ summary.saved_chunks, summary.errors }) catch "Manual save";
                pushHudNotification(&hud_notifications, allocator, msg, 4.0);
            } else {
                std.debug.print("[Autosave] Manual save: no modified chunks\n", .{});
                pushHudNotification(&hud_notifications, allocator, "Manual save: no changes", 4.0);
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
                const msg = std.fmt.bufPrint(&hud_message_buffer, "Backups: keep {d}", .{retention}) catch "Backups retention set";
                pushHudNotification(&hud_notifications, allocator, msg, 4.0);
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
                const msg = std.fmt.bufPrint(&hud_message_buffer, "Backups: keep {d}", .{retention}) catch "Backups retention set";
                pushHudNotification(&hud_notifications, allocator, msg, 4.0);
            }
        } else if (input_state.wasKeyPressed(.f11)) {
            const queued = chunk_manager.queueLoadedRegionBackups();
            if (queued) {
                pushHudNotification(&hud_notifications, allocator, "Backups: queued region compaction", 4.0);
            } else {
                const remaining = chunk_manager.backupCooldownSecondsRemaining();
                var cooldown_buf: [96]u8 = undefined;
                const msg = if (remaining > 0)
                    std.fmt.bufPrint(&cooldown_buf, "Backups cooling ~{d}s", .{remaining}) catch "Backups cooling"
                else
                    "Backups: no regions";
                pushHudNotification(&hud_notifications, allocator, msg, 3.0);
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
        const delta_seconds_f32: f32 = @as(f32, @floatCast(delta_seconds));
        autosave_elapsed += delta_seconds_f32;
        updateHudNotifications(&hud_notifications, delta_seconds_f32);

        const frame_ms = delta_seconds_f32 * 1000.0;
        frame_time_avg_ms = frame_time_avg_ms * 0.85 + frame_ms * 0.15;
        if (frame_ms > mesh_regen_high_ms or frame_time_avg_ms > mesh_regen_high_ms) {
            mesh_regen_budget = 1;
        } else if (frame_ms > mesh_regen_medium_ms or frame_time_avg_ms > mesh_regen_medium_ms) {
            mesh_regen_budget = 2;
        } else {
            mesh_regen_budget = default_meshes_per_frame;
        }

        time_of_day += delta_seconds_f32 / day_length_seconds;
        if (time_of_day >= 1.0) time_of_day -= 1.0;

        if (window.height != 0) {
            const aspect = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(window.height));
            main_camera.setAspectRatio(aspect);
        }

        if (window.cursor_locked) {
            main_camera.processMouseMovement(input_state.mouse_delta.x, input_state.mouse_delta.y);
        } else {
            input_state.mouse_delta = math.Vec2.zero();
            if (input_state.wasMousePressed(.left) or input_state.wasMousePressed(.right)) {
                window.setCursorLocked(true);
                input_state.mouse_delta = math.Vec2.zero();
            }
        }

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
            var consumed_maintenance_notice = false;
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
                const msg = std.fmt.bufPrint(&hud_message_buffer, "Autosave: {d} chunks ({d} errors)", .{ summary.saved_chunks, summary.errors }) catch "Autosave complete";
                pushHudNotification(&hud_notifications, allocator, msg, 4.0);
                autosave_elapsed = 0;
                if (summary.maintenance_enqueued) {
                    const cooldown = chunk_manager.backupCooldownSecondsRemaining();
                    const maintenance_msg = if (summary.queued_regions_added > 0)
                        std.fmt.bufPrint(&hud_message_buffer, "Maintenance: +{d} (total {d}, ~{d}s)", .{ summary.queued_regions_added, summary.queued_regions_total, cooldown }) catch "Maintenance queued"
                    else if (summary.queued_regions_total > 0)
                        std.fmt.bufPrint(&hud_message_buffer, "Maintenance: total {d} (~{d}s)", .{ summary.queued_regions_total, cooldown }) catch "Maintenance queued"
                    else
                        "Maintenance queued";
                    pushHudNotification(&hud_notifications, allocator, maintenance_msg, 4.0);
                    std.debug.print(
                        "[Maintenance] Queue total {d} regions (+{d}) from autosave (cooldown ~{d}s).\n",
                        .{ summary.queued_regions_total, summary.queued_regions_added, cooldown },
                    );
                    consumed_maintenance_notice = chunk_manager.takeScheduledBackupNotice();
                }
            }

            if (!consumed_maintenance_notice and chunk_manager.takeScheduledBackupNotice()) {
                const cooldown = chunk_manager.backupCooldownSecondsRemaining();
                const notice = if (cooldown > 0)
                    std.fmt.bufPrint(&hud_message_buffer, "Maintenance queued (~{d}s cooldown)", .{cooldown}) catch "Maintenance queued"
                else
                    "Maintenance queued";
                pushHudNotification(&hud_notifications, allocator, notice, 4.0);
                std.debug.print("[Maintenance] Queued region compaction batch (cooldown ~{d}s).\n", .{cooldown});
            }

            if (chunk_manager.takeScheduledMaintenanceIntervalChange()) |seconds| {
                const minutes = if (seconds == 0)
                    0
                else
                    @divFloor(seconds + 59, 60);
                const cadence_notice = if (minutes == 0)
                    "Maintenance cadence paused"
                else
                    std.fmt.bufPrint(&hud_message_buffer, "Maintenance cadence ~{d}m", .{minutes}) catch "Maintenance cadence";
                pushHudNotification(&hud_notifications, allocator, cadence_notice, 4.0);
                std.debug.print("[Maintenance] Cadence tuned to {d}s (~{d}m).\n", .{ seconds, minutes });
            }

            accumulator -= fixed_dt_seconds;
        }

        // Create frustum for culling
        const view = main_camera.getViewMatrix();
        const projection = main_camera.getProjectionMatrix();
        const view_proj = projection.multiply(view);
        const frustum = math.Frustum.fromMatrix(view_proj);

        const camera_pos = main_camera.getPosition();
        const mesh_stats = try updateGpuMeshes(allocator, &chunk_manager, &mesh_cache, &mesher, &combined_vertices, &combined_indices, frustum, camera_pos, mesh_regen_budget);
        const has_mesh = combined_vertices.items.len > 0;

        if (selected_block) |sel| {
            const outline_vertices = try generateCubeOutlineVertices(allocator, sel.block_pos, 0.02);
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
            var hud_texts: [16][]const u8 = .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
            var hud_count: usize = 0;
            var max_width: f32 = 0;
            const base_hud_scale: f32 = 2.0;
            const height_factor: f32 = if (window.height > 0)
                std.math.clamp(@as(f32, @floatFromInt(window.height)) / 720.0, 0.75, 1.5)
            else
                1.0;
            const hud_scale: f32 = base_hud_scale * height_factor;
            const hud_line_height = line_text.lineHeightPx(hud_scale);
            const hud_padding = 8.0 + hud_scale * 2.0;

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

            var chunk_buf: [96]u8 = undefined;
            const chunk_line = std.fmt.bufPrint(
                &chunk_buf,
                "Chunks {d}/{d} | Culled {d} | Budget {d}",
                .{ mesh_stats.rendered_chunks, mesh_stats.total_chunks, mesh_stats.culled_chunks, mesh_stats.budget_skipped },
            ) catch "Chunk stats";
            hud_texts[hud_count] = chunk_line;
            hud_count += 1;
            max_width = @max(max_width, line_text.textWidth(chunk_line, hud_scale));

            var geom_buf: [96]u8 = undefined;
            const geom_line = std.fmt.bufPrint(
                &geom_buf,
                "Verts {d} | Tris {d}",
                .{ mesh_stats.total_vertices, mesh_stats.total_indices / 3 },
            ) catch "Geometry stats";
            hud_texts[hud_count] = geom_line;
            hud_count += 1;
            max_width = @max(max_width, line_text.textWidth(geom_line, hud_scale));

            var lod_buf: [96]u8 = undefined;
            const lod_line = std.fmt.bufPrint(
                &lod_buf,
                "LOD full {d} mid {d} far {d} regen {d}",
                .{ mesh_stats.full_chunks, mesh_stats.medium_chunks, mesh_stats.far_chunks, mesh_stats.regenerations },
            ) catch "LOD stats";
            hud_texts[hud_count] = lod_line;
            hud_count += 1;
            max_width = @max(max_width, line_text.textWidth(lod_line, hud_scale));

            const streaming_stats = chunk_manager.profilingStats();
            const last_ms = @as(f32, @floatFromInt(streaming_stats.last_update_ns)) / 1_000_000.0;
            const avg_ms = @as(f32, @floatCast(streaming_stats.average_update_ns / 1_000_000.0));
            const max_ms = @as(f32, @floatFromInt(streaming_stats.max_update_ns)) / 1_000_000.0;

            var stream_time_buf: [128]u8 = undefined;
            const stream_time_line = std.fmt.bufPrint(
                &stream_time_buf,
                "Stream {d:.2}ms avg {d:.2} max {d:.2} | pending {d}",
                .{ last_ms, avg_ms, max_ms, streaming_stats.pending_generations },
            ) catch "Stream timing";
            hud_texts[hud_count] = stream_time_line;
            hud_count += 1;
            max_width = @max(max_width, line_text.textWidth(stream_time_line, hud_scale));

            var stream_queue_buf: [128]u8 = undefined;
            const stream_queue_line = std.fmt.bufPrint(
                &stream_queue_buf,
                "Queue {d} gen {d} async {d} load {d} unld {d}",
                .{
                    streaming_stats.queued_candidates,
                    streaming_stats.queued_generations,
                    streaming_stats.completed_async,
                    streaming_stats.immediate_loaded,
                    streaming_stats.unloaded,
                },
            ) catch "Stream queue";
            hud_texts[hud_count] = stream_queue_line;
            hud_count += 1;
            max_width = @max(max_width, line_text.textWidth(stream_queue_line, hud_scale));

            for (hud_notifications.items) |notif| {
                if (hud_count >= hud_texts.len) break;
                if (notif.len == 0) continue;
                const notif_text = notif.text[0..notif.len];
                hud_texts[hud_count] = notif_text;
                hud_count += 1;
                max_width = @max(max_width, line_text.textWidth(notif_text, hud_scale));
            }

            if (chunk_manager.world_persistence) |wp| {
                const metrics = wp.getMaintenanceMetrics();
                const cadence_seconds = metrics.schedule_interval_seconds;
                const cadence_minutes = if (cadence_seconds == 0)
                    0
                else
                    @divFloor(cadence_seconds + 59, 60);
                const cooldown = chunk_manager.backupCooldownSecondsRemaining();

                var maint_buf: [128]u8 = undefined;
                const maint_line = if (cadence_seconds == 0)
                    std.fmt.bufPrint(&maint_buf, "Maintenance: paused | queued {d}", .{metrics.queued_regions}) catch "Maintenance cadence"
                else
                    std.fmt.bufPrint(&maint_buf, "Maintenance: ~{d}m | queued {d} (~{d}s)", .{ cadence_minutes, metrics.queued_regions, cooldown }) catch "Maintenance cadence";
                hud_texts[hud_count] = maint_line;
                hud_count += 1;
                max_width = @max(max_width, line_text.textWidth(maint_line, hud_scale));

                var activity_buf: [96]u8 = undefined;
                const activity_line = std.fmt.bufPrint(&activity_buf, "Maintenance activity {d:.1}", .{metrics.recent_activity_score}) catch "Maintenance activity";
                hud_texts[hud_count] = activity_line;
                hud_count += 1;
                max_width = @max(max_width, line_text.textWidth(activity_line, hud_scale));

                const backup_status = wp.backupStatus();
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
            if (hud_notifications.items.len > 0) {
                const latest = hud_notifications.items[hud_notifications.items.len - 1];
                if (latest.len > 0) {
                    std.debug.print("HUD notice: {s}\n", .{latest.text[0..latest.len]});
                }
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
