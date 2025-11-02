const std = @import("std");
const terrain = @import("terrain.zig");

pub const default_worlds_root = "worlds";
pub const default_autosave_interval_seconds: u32 = 30;
pub const default_backup_schedule_interval_seconds: u32 = 10 * 60;
pub const minimum_backup_schedule_interval_seconds: u32 = 5 * 60;
pub const maximum_backup_schedule_interval_seconds: u32 = 20 * 60;
pub const default_world_difficulty: Difficulty = .normal;
const region_span = 32;
const region_entry_count = region_span * region_span;
const region_free_capacity = 256;
const chunk_data_version: u16 = 2;
const total_blocks: usize = terrain.Chunk.CHUNK_SIZE * terrain.Chunk.CHUNK_SIZE * terrain.Chunk.CHUNK_HEIGHT;
const max_rle_run: usize = std.math.maxInt(u16);
const region_compact_free_ratio_percent: usize = 35;
const region_compact_min_savings: usize = 128 * 1024;
const region_magic: u32 = 0x57524731; // "WRG1"
const region_version: u16 = 1;
pub const default_region_backup_retention: usize = 3;

pub const Difficulty = enum(u8) {
    peaceful,
    easy,
    normal,
    hard,
};

pub fn difficultyLabel(d: Difficulty) []const u8 {
    return switch (d) {
        .peaceful => "Peaceful",
        .easy => "Easy",
        .normal => "Normal",
        .hard => "Hard",
    };
}

pub const InitOptions = struct {
    seed: ?u64 = null,
    force_new: bool = false,
    worlds_root: []const u8 = default_worlds_root,
    description: ?[]const u8 = null,
};

pub const WorldInfo = struct {
    name: []const u8,
    seed: u64,
    last_played_timestamp: i64,
    difficulty: Difficulty,
    description: []const u8,

    pub fn deinit(self: WorldInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const WorldSettingsSummary = struct {
    autosave_interval_seconds: u32,
    backup_retention: usize,
    last_backup_timestamp: i64,
    difficulty: Difficulty,
    maintenance_last_timestamp: i64,
    maintenance_queued: usize,
    maintenance_interval_seconds: u32,
    maintenance_activity_score: f32,
};

pub fn loadWorldSettingsSummary(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
) !WorldSettingsSummary {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();

    const backup = wp.backupStatus();
    const maintenance = wp.getMaintenanceMetrics();
    return .{
        .autosave_interval_seconds = wp.autosaveIntervalSeconds(),
        .backup_retention = wp.regionBackupRetention(),
        .last_backup_timestamp = backup.last_backup_timestamp,
        .difficulty = wp.difficulty,
        .maintenance_last_timestamp = maintenance.last_compaction_timestamp,
        .maintenance_queued = maintenance.queued_regions,
        .maintenance_interval_seconds = maintenance.schedule_interval_seconds,
        .maintenance_activity_score = maintenance.recent_activity_score,
    };
}

pub fn setWorldAutosaveInterval(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
    seconds: u32,
) !void {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();
    wp.setAutosaveIntervalSeconds(seconds);
}

pub fn setWorldBackupRetention(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
    retention: usize,
) !void {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();
    wp.setRegionBackupRetention(retention);
}

pub fn setWorldDifficulty(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
    difficulty: Difficulty,
) !void {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();
    wp.setDifficulty(difficulty);
}

pub fn resetWorldSettings(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
) !void {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();
    wp.setAutosaveIntervalSeconds(default_autosave_interval_seconds);
    wp.setRegionBackupRetention(default_region_backup_retention);
    wp.setDifficulty(default_world_difficulty);
}

pub fn setWorldDescription(
    allocator: std.mem.Allocator,
    worlds_root: []const u8,
    world_name: []const u8,
    description: []const u8,
) !void {
    var wp = try WorldPersistence.init(allocator, world_name, .{ .worlds_root = worlds_root });
    defer wp.deinit();
    wp.setDescription(description);
}

pub const Compression = enum(u8) {
    raw = 0,
    rle = 1,
};

const RegionHeader = packed struct {
    magic: u32 = region_magic,
    version: u16 = region_version,
    entry_count: u16 = region_entry_count,
    free_count: u16 = 0,
    reserved: u16 = 0,
};

const ChunkEntry = packed struct {
    offset: u64 = 0,
    size: u32 = 0, // bytes stored for chunk payload (header + compressed data)
    uncompressed_size: u32 = 0,
    version: u16 = chunk_data_version,
    compression: u8 = @intFromEnum(Compression.rle),
    reserved: u8 = 0,
};

const FreeEntry = packed struct {
    offset: u64 = 0,
    length: u32 = 0,
    reserved: u32 = 0,
};

const ChunkDataHeader = packed struct {
    version: u16,
    chunk_x: i32,
    chunk_z: i32,
    compression: u8,
    reserved: u8 = 0,
    compressed_size: u32,
    uncompressed_size: u32,
};

const region_header_size = @sizeOf(RegionHeader);
const chunk_entry_size = @sizeOf(ChunkEntry);
const free_entry_size = @sizeOf(FreeEntry);
const chunk_table_offset = region_header_size;
const free_table_offset = chunk_table_offset + region_entry_count * chunk_entry_size;
const region_data_offset = free_table_offset + region_free_capacity * free_entry_size;

const RegionCoord = struct {
    x: i32,
    z: i32,
};

fn regionKey(x: i32, z: i32) u64 {
    const ux32: u32 = @bitCast(x);
    const uz32: u32 = @bitCast(z);
    const ux = @as(u64, ux32);
    const uz = @as(u64, uz32);
    return (ux << 32) | uz;
}

pub const MaintenanceMetrics = struct {
    total_compactions: u64 = 0,
    total_failures: u64 = 0,
    last_compaction_timestamp: i64 = 0,
    last_compaction_duration_ns: i128 = 0,
    queued_regions: usize = 0,
    schedule_interval_seconds: u32 = default_backup_schedule_interval_seconds,
    recent_activity_score: f32 = 0.0,
};

/// World metadata stored in world.meta file
pub const WorldMetadata = struct {
    name: []const u8,
    seed: u64,
    creation_timestamp: i64,
    last_played_timestamp: i64,
    version: u32,
    difficulty: Difficulty = default_world_difficulty,
    description: []const u8 = "",

    pub fn save(self: WorldMetadata, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
        defer allocator.free(json_bytes);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(json_bytes);
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !WorldMetadata {
        const json_data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(json_data);

        const Parsed = struct {
            name: []const u8,
            seed: u64,
            creation_timestamp: i64,
            last_played_timestamp: i64,
            version: u32,
            difficulty: ?Difficulty = null,
            description: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(Parsed, allocator, json_data, .{});
        defer parsed.deinit();

        const name_copy = try allocator.dupe(u8, parsed.value.name);

        const description_copy = if (parsed.value.description) |desc|
            allocator.dupe(u8, desc) catch allocator.alloc(u8, 0) catch unreachable
        else
            allocator.alloc(u8, 0) catch unreachable;

        return WorldMetadata{
            .name = name_copy,
            .seed = parsed.value.seed,
            .creation_timestamp = parsed.value.creation_timestamp,
            .last_played_timestamp = parsed.value.last_played_timestamp,
            .version = parsed.value.version,
            .difficulty = parsed.value.difficulty orelse default_world_difficulty,
            .description = description_copy,
        };
    }

    pub fn deinit(self: *WorldMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

const RegionData = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    file: std.fs.File,
    header: RegionHeader,
    chunk_entries: []ChunkEntry,
    free_entries: []FreeEntry,
    free_count: usize,
    file_size: u64,
    region_x: i32,
    region_z: i32,

    fn deinit(self: *RegionData) void {
        self.file.close();
        self.allocator.free(self.chunk_entries);
        self.allocator.free(self.free_entries);
        self.allocator.free(self.path);
    }

    fn flush(self: *RegionData) !void {
        self.header.free_count = @as(u16, @intCast(self.free_count));
        try self.file.seekTo(0);
        try self.file.writeAll(std.mem.asBytes(&self.header));
        try self.file.writeAll(std.mem.sliceAsBytes(self.chunk_entries));
        try self.file.writeAll(std.mem.sliceAsBytes(self.free_entries));
        // Ensure file cursor is positioned at end-of-metadata to avoid truncating data accidentally
        try self.file.seekTo(self.file_size);
        try self.file.sync();
    }

    fn allocateSpace(self: *RegionData, size: usize) u64 {
        var i: usize = 0;
        while (i < self.free_count) {
            const entry = self.free_entries[i];
            const entry_len = @as(usize, entry.length);
            if (entry_len >= size) {
                const offset = entry.offset;
                if (entry_len == size) {
                    self.free_count -= 1;
                    self.free_entries[i] = self.free_entries[self.free_count];
                    self.free_entries[self.free_count] = FreeEntry{};
                } else {
                    self.free_entries[i].offset = entry.offset + @as(u64, size);
                    self.free_entries[i].length = @as(u32, @intCast(entry_len - size));
                }
                return offset;
            }
            i += 1;
        }

        const offset = self.file_size;
        self.file_size = offset + @as(u64, size);
        return offset;
    }

    fn addFreeSpace(self: *RegionData, offset: u64, length: usize) void {
        if (length == 0) return;

        const new_start = offset;
        const new_end = offset + @as(u64, length);

        // Attempt to merge with existing entries
        var i: usize = 0;
        while (i < self.free_count) {
            const entry_start = self.free_entries[i].offset;
            const entry_end = self.free_entries[i].offset + @as(u64, self.free_entries[i].length);
            if (entry_end == new_start) {
                self.free_entries[i].length += @as(u32, @intCast(length));
                self.free_entries[i].offset = entry_start;
                self.mergeFreeEntries(i);
                return;
            } else if (new_end == entry_start) {
                self.free_entries[i].offset = new_start;
                self.free_entries[i].length += @as(u32, @intCast(length));
                self.mergeFreeEntries(i);
                return;
            }
            i += 1;
        }

        if (self.free_count < region_free_capacity) {
            self.free_entries[self.free_count] = FreeEntry{
                .offset = offset,
                .length = @as(u32, @intCast(length)),
                .reserved = 0,
            };
            self.free_count += 1;
        }
    }

    fn totalFreeBytes(self: *const RegionData) usize {
        var sum: usize = 0;
        var i: usize = 0;
        while (i < self.free_count) : (i += 1) {
            sum += self.free_entries[i].length;
        }
        return sum;
    }

    fn shouldCompact(self: *const RegionData) bool {
        const free_bytes = self.totalFreeBytes();
        if (free_bytes < region_compact_min_savings) return false;
        const used_bytes = if (self.file_size > region_data_offset)
            self.file_size - region_data_offset
        else
            0;
        if (used_bytes == 0) return false;
        if (free_bytes * 100 >= used_bytes * region_compact_free_ratio_percent) return true;
        return self.free_count >= region_free_capacity;
    }

    fn mergeFreeEntries(self: *RegionData, index: usize) void {
        const target_start = self.free_entries[index].offset;
        const target_end = target_start + @as(u64, self.free_entries[index].length);

        var i: usize = 0;
        while (i < self.free_count) : (i += 1) {
            if (i == index) continue;
            const entry_start = self.free_entries[i].offset;
            const entry_end = entry_start + @as(u64, self.free_entries[i].length);

            if (entry_end == target_start) {
                self.free_entries[index].offset = entry_start;
                self.free_entries[index].length += self.free_entries[i].length;
                self.removeFreeEntry(i);
                return self.mergeFreeEntries(index);
            } else if (target_end == entry_start) {
                self.free_entries[index].length += self.free_entries[i].length;
                self.removeFreeEntry(i);
                return self.mergeFreeEntries(index);
            }
        }
    }

    fn removeFreeEntry(self: *RegionData, index: usize) void {
        if (index >= self.free_count) return;
        self.free_count -= 1;
        self.free_entries[index] = self.free_entries[self.free_count];
        self.free_entries[self.free_count] = FreeEntry{};
    }
};

pub const WorldPersistence = struct {
    allocator: std.mem.Allocator,
    world_dir: []const u8,
    metadata: WorldMetadata,
    backup_root: []const u8,
    region_backup_retention: usize,
    retained_backups: u32,
    last_backup_timestamp: i64,
    autosave_interval_seconds: u32,
    pending_compactions: std.ArrayListUnmanaged(RegionCoord),
    pending_compaction_set: std.AutoHashMap(u64, void),
    maintenance_metrics: MaintenanceMetrics,
    difficulty: Difficulty,

    pub const Error = error{
        SeedMismatch,
        WorldAlreadyExists,
        UnsupportedCompression,
        InvalidChunkFile,
        ChunkCoordinateMismatch,
        UnexpectedEndOfFile,
        InvalidCompressedChunk,
        LinkQuotaExceeded,
        ReadOnlyFileSystem,
        OutOfMemory,
        InvalidWorldMetadata,
    } || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.fs.File.SeekError || std.fs.File.StatError;

    pub fn init(allocator: std.mem.Allocator, world_name: []const u8, options: InitOptions) Error!WorldPersistence {
        // Ensure worlds root exists
        std.fs.cwd().makeDir(options.worlds_root) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const world_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.worlds_root, world_name });
        errdefer allocator.free(world_dir);

        const world_exists = blk: {
            var dir = std.fs.cwd().openDir(world_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            dir.close();
            break :blk true;
        };

        if (world_exists and options.force_new) {
            return error.WorldAlreadyExists;
        }

        const regions_dir = try std.fmt.allocPrint(allocator, "{s}/regions", .{world_dir});
        defer allocator.free(regions_dir);
        const backup_root = try std.fmt.allocPrint(allocator, "{s}/backups", .{world_dir});
        errdefer allocator.free(backup_root);

        var metadata = if (world_exists) blk: {
            const meta_path = try std.fmt.allocPrint(allocator, "{s}/world.meta", .{world_dir});
            defer allocator.free(meta_path);

            var loaded = WorldMetadata.load(allocator, meta_path) catch {
                return error.InvalidWorldMetadata;
            };
            errdefer loaded.deinit(allocator);

            if (options.seed) |desired_seed| {
                if (loaded.seed != desired_seed) {
                    loaded.deinit(allocator);
                    return error.SeedMismatch;
                }
            }

            break :blk loaded;
        } else blk: {
            const now = std.time.timestamp();
            const name_copy = try allocator.dupe(u8, world_name);
            const seed_value = options.seed orelse defaultSeed();

            std.fs.cwd().makeDir(world_dir) catch |err| switch (err) {
                error.PathAlreadyExists => return error.WorldAlreadyExists,
                else => return err,
            };

            std.fs.cwd().makeDir(regions_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };

            var fresh = WorldMetadata{
                .name = name_copy,
                .seed = seed_value,
                .creation_timestamp = now,
                .last_played_timestamp = now,
                .version = 1,
                .difficulty = default_world_difficulty,
                .description = if (options.description) |desc|
                    try allocator.dupe(u8, desc)
                else
                    try allocator.alloc(u8, 0),
            };

            const meta_path = try std.fmt.allocPrint(allocator, "{s}/world.meta", .{world_dir});
            defer allocator.free(meta_path);
            try fresh.save(allocator, meta_path);

            break :blk fresh;
        };
        errdefer metadata.deinit(allocator);

        // Ensure regions directory exists when loading existing worlds
        std.fs.cwd().makeDir(regions_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        std.fs.cwd().makeDir(backup_root) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var persistence = WorldPersistence{
            .allocator = allocator,
            .world_dir = world_dir,
            .metadata = metadata,
            .backup_root = backup_root,
            .region_backup_retention = default_region_backup_retention,
            .retained_backups = 0,
            .last_backup_timestamp = 0,
            .autosave_interval_seconds = default_autosave_interval_seconds,
            .pending_compactions = .{},
            .pending_compaction_set = std.AutoHashMap(u64, void).init(allocator),
            .maintenance_metrics = .{},
            .difficulty = metadata.difficulty,
        };

        persistence.loadSettings();
        if (options.description) |desc| {
            persistence.setDescription(desc);
        }
        return persistence;
    }

    pub fn deinit(self: *WorldPersistence) void {
        self.allocator.free(self.world_dir);
        self.allocator.free(self.backup_root);
        self.metadata.deinit(self.allocator);
        self.pending_compactions.deinit(self.allocator);
        self.pending_compaction_set.deinit();
    }

    pub fn seed(self: *const WorldPersistence) u64 {
        return self.metadata.seed;
    }

    pub fn description(self: *const WorldPersistence) []const u8 {
        return self.metadata.description;
    }

    /// Save world metadata
    pub fn saveMetadata(self: *WorldPersistence) !void {
        self.metadata.last_played_timestamp = std.time.timestamp();

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/world.meta", .{self.world_dir});
        defer self.allocator.free(meta_path);

        try self.metadata.save(self.allocator, meta_path);
    }

    pub fn setAutosaveIntervalSeconds(self: *WorldPersistence, seconds: u32) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/autosave.cfg", .{self.world_dir}) catch return;
        defer self.allocator.free(path);

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();

        var buf: [32]u8 = undefined;
        const contents = std.fmt.bufPrint(&buf, "interval={d}\n", .{seconds}) catch return;
        _ = file.write(contents) catch {};
        self.autosave_interval_seconds = seconds;
    }

    pub const BackupStatus = struct {
        retained: u32,
        retention_limit: u32,
        last_backup_timestamp: i64,
    };

    pub fn backupStatus(self: *const WorldPersistence) BackupStatus {
        return .{
            .retained = self.retained_backups,
            .retention_limit = @intCast(self.region_backup_retention),
            .last_backup_timestamp = self.last_backup_timestamp,
        };
    }

    pub fn autosaveIntervalSeconds(self: *const WorldPersistence) u32 {
        return self.autosave_interval_seconds;
    }

    pub fn regionBackupRetention(self: *const WorldPersistence) usize {
        return self.region_backup_retention;
    }

    pub fn setRegionBackupRetention(self: *WorldPersistence, retention: usize) void {
        const clamped = if (retention > 32) 32 else retention;
        const effective = if (clamped == 0) 1 else clamped;
        self.region_backup_retention = effective;

        self.writeBackupConfig(effective);
        self.enforceAllRegionBackups();
    }

    pub fn setDescription(self: *WorldPersistence, desc: []const u8) void {
        const copy = self.allocator.dupe(u8, desc) catch self.allocator.alloc(u8, 0) catch return;
        self.allocator.free(self.metadata.description);
        self.metadata.description = copy;
        self.saveMetadata() catch {};
    }

    pub fn queueRegionCompactionRequest(self: *WorldPersistence, region_x: i32, region_z: i32) void {
        self.queueRegionCompaction(region_x, region_z) catch {};
    }

    pub fn queuedCompactions(self: *const WorldPersistence) usize {
        return self.maintenance_metrics.queued_regions;
    }

    pub fn recordMaintenanceSchedule(
        self: *WorldPersistence,
        interval_seconds: u32,
        activity_score: f32,
        queued_regions: usize,
    ) void {
        self.maintenance_metrics.schedule_interval_seconds = interval_seconds;
        self.maintenance_metrics.recent_activity_score = activity_score;
        self.maintenance_metrics.queued_regions = queued_regions;
    }

    pub fn setDifficulty(self: *WorldPersistence, difficulty: Difficulty) void {
        self.difficulty = difficulty;
        self.metadata.difficulty = difficulty;
        self.saveMetadata() catch {};
    }

    pub fn difficultyLevel(self: *const WorldPersistence) Difficulty {
        return self.difficulty;
    }

    fn writeBackupConfig(self: *WorldPersistence, retention: usize) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/backups.cfg", .{self.world_dir}) catch return;
        defer self.allocator.free(path);

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();

        var buf: [32]u8 = undefined;
        const contents = std.fmt.bufPrint(&buf, "retention={d}\n", .{retention}) catch return;
        _ = file.write(contents) catch {};
    }

    fn enforceAllRegionBackups(self: *WorldPersistence) void {
        var dir = std.fs.cwd().openDir(self.backup_root, .{ .iterate = true }) catch {
            self.retained_backups = 0;
            self.last_backup_timestamp = 0;
            return;
        };
        defer dir.close();

        var total_retained: usize = 0;
        var latest_ts: i64 = 0;

        var it = dir.iterate();
        while (true) {
            const entry_opt = it.next() catch break;
            if (entry_opt == null) break;
            const entry = entry_opt.?;
            if (entry.kind != .directory) continue;
            const sub_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.backup_root, entry.name }) catch continue;
            defer self.allocator.free(sub_path);
            const stats = self.enforceRegionBackupRetention(sub_path);
            total_retained += stats.retained;
            if (stats.latest > latest_ts) {
                latest_ts = stats.latest;
            }
        }

        if (total_retained > std.math.maxInt(u32)) {
            self.retained_backups = std.math.maxInt(u32);
        } else {
            self.retained_backups = @intCast(total_retained);
        }
        self.last_backup_timestamp = latest_ts;
    }

    /// Load world metadata from disk for a given world
    pub fn loadMetadata(allocator: std.mem.Allocator, worlds_root: []const u8, world_name: []const u8) !WorldMetadata {
        const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, world_name });
        defer allocator.free(meta_path);
        return try WorldMetadata.load(allocator, meta_path);
    }

    fn loadSettings(self: *WorldPersistence) void {
        self.autosave_interval_seconds = default_autosave_interval_seconds;
        self.region_backup_retention = default_region_backup_retention;
        self.maintenance_metrics.schedule_interval_seconds = default_backup_schedule_interval_seconds;
        self.maintenance_metrics.recent_activity_score = 0;
        self.loadAutosaveConfig();
        self.loadBackupConfig();
        self.enforceAllRegionBackups();
    }

    fn loadAutosaveConfig(self: *WorldPersistence) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/autosave.cfg", .{self.world_dir}) catch return;
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, 256) catch return;
        defer self.allocator.free(data);

        var it = std.mem.tokenizeAny(u8, data, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "interval=")) {
                const value_str = line["interval=".len..];
                const parsed = std.fmt.parseUnsigned(u32, value_str, 10) catch continue;
                self.autosave_interval_seconds = parsed;
                break;
            }
        }
    }

    fn loadBackupConfig(self: *WorldPersistence) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/backups.cfg", .{self.world_dir}) catch return;
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, 256) catch return;
        defer self.allocator.free(data);

        var it = std.mem.tokenizeAny(u8, data, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "retention=")) {
                const value_str = line["retention=".len..];
                const parsed = std.fmt.parseUnsigned(usize, value_str, 10) catch continue;
                const clamped = if (parsed == 0) 1 else if (parsed > 32) 32 else parsed;
                self.region_backup_retention = clamped;
                break;
            }
        }
    }

    /// List available worlds (directories containing world.meta)
    pub fn listWorlds(allocator: std.mem.Allocator, worlds_root: []const u8) ![]WorldInfo {
        var dir = std.fs.cwd().openDir(worlds_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(WorldInfo, 0),
            else => return err,
        };
        defer dir.close();

        var infos = std.ArrayListUnmanaged(WorldInfo){};
        errdefer {
            for (infos.items) |info| {
                info.deinit(allocator);
            }
            infos.deinit(allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;

            const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/world.meta", .{ worlds_root, entry.name });
            defer allocator.free(meta_path);

            var metadata = WorldMetadata.load(allocator, meta_path) catch {
                continue; // Skip directories without valid metadata
            };
            defer metadata.deinit(allocator);

            const name_copy = try allocator.dupe(u8, entry.name);
            const desc_copy = try allocator.dupe(u8, metadata.description);
            try infos.append(allocator, .{
                .name = name_copy,
                .seed = metadata.seed,
                .last_played_timestamp = metadata.last_played_timestamp,
                .difficulty = metadata.difficulty,
                .description = desc_copy,
            });
        }

        return infos.toOwnedSlice(allocator);
    }

    pub fn freeWorldInfoList(allocator: std.mem.Allocator, infos: []WorldInfo) void {
        for (infos) |info| {
            info.deinit(allocator);
        }
        allocator.free(infos);
    }

    /// Check if a world directory already exists
    pub fn worldExists(allocator: std.mem.Allocator, worlds_root: []const u8, world_name: []const u8) !bool {
        const world_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worlds_root, world_name });
        defer allocator.free(world_dir);

        var dir = std.fs.cwd().openDir(world_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        dir.close();
        return true;
    }

    /// Save a chunk to disk (compressed, only if modified)
    pub fn saveChunk(self: *WorldPersistence, chunk: *terrain.Chunk) !void {
        if (!chunk.modified) return;

        const coords = chunkRegionCoords(chunk.x, chunk.z);

        var region = try self.openRegionForWrite(coords.region_x, coords.region_z);
        defer region.deinit();

        const compressed = try compressChunk(self.allocator, chunk);
        defer self.allocator.free(compressed);

        const payload_size: usize = @sizeOf(ChunkDataHeader) + compressed.len;
        const idx = chunkIndexFromLocal(coords.local_x, coords.local_z);
        const entry = &region.chunk_entries[idx];

        if (entry.offset != 0 and entry.size != 0) {
            region.addFreeSpace(entry.offset, @as(usize, entry.size));
        }

        const offset = region.allocateSpace(payload_size);
        try region.file.seekTo(offset);

        const header = ChunkDataHeader{
            .version = chunk_data_version,
            .chunk_x = chunk.x,
            .chunk_z = chunk.z,
            .compression = @intFromEnum(Compression.rle),
            .compressed_size = @intCast(compressed.len),
            .uncompressed_size = @intCast(total_blocks),
        };

        try region.file.writeAll(std.mem.asBytes(&header));
        try region.file.writeAll(compressed);

        entry.* = ChunkEntry{
            .offset = offset,
            .size = @intCast(payload_size),
            .uncompressed_size = @intCast(total_blocks),
            .version = chunk_data_version,
            .compression = header.compression,
            .reserved = 0,
        };

        region.file_size = @max(region.file_size, offset + @as(u64, payload_size));

        try region.flush();
        if (region.shouldCompact()) {
            self.queueRegionCompaction(coords.region_x, coords.region_z) catch |err| {
                std.debug.print(
                    "Warning: failed to queue region compaction ({d}, {d}): {any}\n",
                    .{ coords.region_x, coords.region_z, err },
                );
            };
        }

        chunk.modified = false;
    }

    /// Load a chunk from disk (returns null if not saved yet)
    pub fn loadChunk(self: *WorldPersistence, chunk_x: i32, chunk_z: i32) !?terrain.Chunk {
        const coords = chunkRegionCoords(chunk_x, chunk_z);
        const path = try self.regionFilePath(coords.region_x, coords.region_z);
        defer self.allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        var header: RegionHeader = undefined;
        if (try file.readAll(std.mem.asBytes(&header)) != region_header_size) {
            return error.InvalidChunkFile;
        }
        if (header.magic != region_magic or header.version != region_version or header.entry_count != region_entry_count) {
            return error.InvalidChunkFile;
        }

        const idx = chunkIndexFromLocal(coords.local_x, coords.local_z);
        const entry_offset = chunk_table_offset + idx * chunk_entry_size;
        try file.seekTo(entry_offset);

        var entry: ChunkEntry = undefined;
        if (try file.readAll(std.mem.asBytes(&entry)) != chunk_entry_size) {
            return error.InvalidChunkFile;
        }

        if (entry.offset == 0 or entry.size == 0) return null;
        if (entry.version != chunk_data_version) return error.UnsupportedCompression;
        if (entry.uncompressed_size != @as(u32, @intCast(total_blocks))) return error.InvalidChunkFile;

        const compression = std.meta.intToEnum(Compression, entry.compression) catch return error.UnsupportedCompression;
        const payload_size: usize = @intCast(entry.size);

        if (payload_size < @sizeOf(ChunkDataHeader)) return error.InvalidChunkFile;
        const buffer = try self.allocator.alloc(u8, payload_size);
        defer self.allocator.free(buffer);

        try file.seekTo(entry.offset);
        if (try file.readAll(buffer) != payload_size) {
            return error.UnexpectedEndOfFile;
        }

        const header_slice = buffer[0..@sizeOf(ChunkDataHeader)];
        const chunk_header = std.mem.bytesAsValue(ChunkDataHeader, header_slice).*;

        if (chunk_header.version != chunk_data_version) return error.UnsupportedCompression;
        if (chunk_header.chunk_x != chunk_x or chunk_header.chunk_z != chunk_z) {
            return error.ChunkCoordinateMismatch;
        }
        if (chunk_header.uncompressed_size != @as(u32, @intCast(total_blocks))) return error.InvalidChunkFile;
        if (chunk_header.compressed_size + @sizeOf(ChunkDataHeader) != payload_size) return error.InvalidChunkFile;

        const compressed_slice = buffer[@sizeOf(ChunkDataHeader)..];
        if (compressed_slice.len != chunk_header.compressed_size) return error.InvalidChunkFile;

        var chunk = terrain.Chunk.init(chunk_x, chunk_z);

        switch (compression) {
            .raw => {
                if (compressed_slice.len != total_blocks) return error.InvalidChunkFile;
                try writeChunkBlocksFromRaw(&chunk, compressed_slice);
            },
            .rle => {
                try writeChunkBlocksFromCompressed(&chunk, compressed_slice, total_blocks);
            },
        }

        chunk.modified = false;
        return chunk;
    }

    fn chunkRegionCoords(chunk_x: i32, chunk_z: i32) struct {
        region_x: i32,
        region_z: i32,
        local_x: i32,
        local_z: i32,
    } {
        const region_x = @divFloor(chunk_x, region_span);
        const region_z = @divFloor(chunk_z, region_span);
        const local_x = chunk_x - region_x * region_span;
        const local_z = chunk_z - region_z * region_span;
        return .{
            .region_x = region_x,
            .region_z = region_z,
            .local_x = local_x,
            .local_z = local_z,
        };
    }

    fn chunkIndexFromLocal(local_x: i32, local_z: i32) usize {
        const lx = @as(usize, @intCast(local_x));
        const lz = @as(usize, @intCast(local_z));
        return lz * region_span + lx;
    }

    fn regionFilePath(self: *WorldPersistence, region_x: i32, region_z: i32) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/regions/r.{d}.{d}.region", .{ self.world_dir, region_x, region_z });
    }

    fn ensureRegionBackupDir(self: *WorldPersistence, region_x: i32, region_z: i32) ![]u8 {
        std.fs.cwd().makeDir(self.backup_root) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/r.{d}.{d}", .{ self.backup_root, region_x, region_z });
        errdefer self.allocator.free(dir_path);

        std.fs.cwd().makeDir(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return dir_path;
    }

    const BackupDirStats = struct {
        retained: usize,
        latest: i64,
    };

    fn enforceRegionBackupRetention(self: *WorldPersistence, backup_dir: []const u8) BackupDirStats {
        var dir = std.fs.cwd().openDir(backup_dir, .{ .iterate = true }) catch {
            return .{ .retained = 0, .latest = 0 };
        };
        defer dir.close();

        const BackupInfo = struct {
            name: []u8,
            timestamp: i64,
        };

        var entries = std.ArrayListUnmanaged(BackupInfo){};
        defer {
            for (entries.items) |entry| {
                self.allocator.free(entry.name);
            }
            entries.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (true) {
            const entry_opt = it.next() catch break;
            if (entry_opt == null) break;
            const entry = entry_opt.?;
            if (entry.kind != .file) continue;

            const name_copy = self.allocator.dupe(u8, entry.name) catch continue;
            const stat = dir.statFile(entry.name) catch {
                self.allocator.free(name_copy);
                continue;
            };

            if (stat.mtime > std.math.maxInt(i64) or stat.mtime < std.math.minInt(i64)) {
                self.allocator.free(name_copy);
                continue;
            }

            const timestamp: i64 = @intCast(stat.mtime);
            entries.append(self.allocator, .{ .name = name_copy, .timestamp = timestamp }) catch {
                self.allocator.free(name_copy);
            };
        }

        if (entries.items.len == 0) {
            return .{ .retained = 0, .latest = 0 };
        }

        std.sort.heap(BackupInfo, entries.items, {}, struct {
            fn lessThan(_: void, lhs: BackupInfo, rhs: BackupInfo) bool {
                return lhs.timestamp < rhs.timestamp;
            }
        }.lessThan);

        const retention = self.region_backup_retention;
        const keep: usize = if (retention == 0) 0 else @min(entries.items.len, retention);
        const delete_count = if (entries.items.len > keep) entries.items.len - keep else 0;

        var i: usize = 0;
        while (i < delete_count) : (i += 1) {
            const entry = entries.items[i];
            const delete_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ backup_dir, entry.name }) catch continue;
            defer self.allocator.free(delete_path);
            std.fs.cwd().deleteFile(delete_path) catch {};
        }

        var dir_check = std.fs.cwd().openDir(backup_dir, .{ .iterate = true }) catch {
            return .{ .retained = 0, .latest = 0 };
        };
        defer dir_check.close();

        var latest: i64 = 0;
        var count: usize = 0;
        var it_check = dir_check.iterate();
        while (true) {
            const entry_opt = it_check.next() catch break;
            if (entry_opt == null) break;
            const entry = entry_opt.?;
            if (entry.kind != .file) continue;
            const stat = dir_check.statFile(entry.name) catch continue;
            if (stat.mtime > std.math.maxInt(i64) or stat.mtime < std.math.minInt(i64)) continue;
            const ts: i64 = @intCast(stat.mtime);
            if (count == 0 or ts > latest) {
                latest = ts;
            }
            count += 1;
        }

        return .{ .retained = count, .latest = if (count > 0) latest else 0 };
    }

    fn compactRegionInternal(self: *WorldPersistence, region: *RegionData) !void {
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{region.path});
        defer self.allocator.free(temp_path);

        const backup_dir = try self.ensureRegionBackupDir(region.region_x, region.region_z);
        defer self.allocator.free(backup_dir);

        const timestamp = std.time.timestamp();
        const backup_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/r.{d}.{d}.{d}.bak",
            .{ backup_dir, region.region_x, region.region_z, timestamp },
        );
        defer self.allocator.free(backup_path);

        var temp_file = try std.fs.cwd().createFile(temp_path, .{});
        defer temp_file.close();

        const new_entries = try self.allocator.alloc(ChunkEntry, region_entry_count);
        @memset(new_entries, ChunkEntry{});

        const new_free_entries = try self.allocator.alloc(FreeEntry, region_free_capacity);
        @memset(new_free_entries, FreeEntry{});

        var header = RegionHeader{
            .magic = region_magic,
            .version = region_version,
            .entry_count = region_entry_count,
            .free_count = 0,
            .reserved = 0,
        };

        try temp_file.writeAll(std.mem.asBytes(&header));
        try temp_file.writeAll(std.mem.sliceAsBytes(new_entries));
        try temp_file.writeAll(std.mem.sliceAsBytes(new_free_entries));

        var cursor: u64 = region_data_offset;

        for (region.chunk_entries, 0..) |entry, idx| {
            if (entry.offset == 0 or entry.size == 0) continue;

            const payload = try self.allocator.alloc(u8, entry.size);
            defer self.allocator.free(payload);

            try region.file.seekTo(entry.offset);
            if (try region.file.readAll(payload) != entry.size) return error.UnexpectedEndOfFile;

            try temp_file.seekTo(cursor);
            try temp_file.writeAll(payload);

            new_entries[idx] = ChunkEntry{
                .offset = cursor,
                .size = entry.size,
                .uncompressed_size = entry.uncompressed_size,
                .version = entry.version,
                .compression = entry.compression,
                .reserved = 0,
            };

            cursor += entry.size;
        }

        header.free_count = 0;

        try temp_file.seekTo(0);
        try temp_file.writeAll(std.mem.asBytes(&header));
        try temp_file.writeAll(std.mem.sliceAsBytes(new_entries));
        try temp_file.writeAll(std.mem.sliceAsBytes(new_free_entries));
        try temp_file.sync();

        region.file.close();

        std.fs.cwd().rename(region.path, backup_path) catch {};

        std.fs.cwd().rename(temp_path, region.path) catch |err| {
            // Attempt to restore backup on failure
            std.fs.cwd().rename(backup_path, region.path) catch {};
            return err;
        };

        region.file = try std.fs.cwd().openFile(region.path, .{ .mode = .read_write });

        const old_entries = region.chunk_entries;
        const old_free = region.free_entries;

        region.chunk_entries = new_entries;
        region.free_entries = new_free_entries;
        region.free_count = 0;
        region.header = header;
        region.file_size = if (cursor < region_data_offset) region_data_offset else cursor;

        self.allocator.free(old_entries);
        self.allocator.free(old_free);

        self.enforceAllRegionBackups();
    }

    fn openRegionForWrite(self: *WorldPersistence, region_x: i32, region_z: i32) !RegionData {
        const path = try self.regionFilePath(region_x, region_z);
        errdefer self.allocator.free(path);

        var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                try self.initializeRegionFile(path);
                break :blk try std.fs.cwd().openFile(path, .{ .mode = .read_write });
            },
            else => return err,
        };

        var header: RegionHeader = undefined;
        if (try file.readAll(std.mem.asBytes(&header)) != region_header_size) {
            file.close();
            return error.InvalidChunkFile;
        }
        if (header.magic != region_magic or header.version != region_version or header.entry_count != region_entry_count) {
            file.close();
            return error.InvalidChunkFile;
        }

        const chunk_entries = try self.allocator.alloc(ChunkEntry, region_entry_count);
        errdefer self.allocator.free(chunk_entries);
        @memset(chunk_entries, ChunkEntry{});

        try file.seekTo(chunk_table_offset);
        const chunk_bytes = std.mem.sliceAsBytes(chunk_entries);
        if (try file.readAll(chunk_bytes) != chunk_bytes.len) {
            file.close();
            return error.InvalidChunkFile;
        }

        const free_entries = try self.allocator.alloc(FreeEntry, region_free_capacity);
        errdefer self.allocator.free(free_entries);
        @memset(free_entries, FreeEntry{});

        try file.seekTo(free_table_offset);
        const free_bytes = std.mem.sliceAsBytes(free_entries);
        if (try file.readAll(free_bytes) != free_bytes.len) {
            file.close();
            return error.InvalidChunkFile;
        }

        const file_size = try file.getEndPos();

        return RegionData{
            .allocator = self.allocator,
            .path = path,
            .file = file,
            .header = header,
            .chunk_entries = chunk_entries,
            .free_entries = free_entries,
            .free_count = @min(@as(usize, header.free_count), region_free_capacity),
            .file_size = if (file_size < region_data_offset) region_data_offset else file_size,
            .region_x = region_x,
            .region_z = region_z,
        };
    }

    fn initializeRegionFile(self: *WorldPersistence, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var header = RegionHeader{};
        try file.writeAll(std.mem.asBytes(&header));

        const chunk_table_bytes = region_entry_count * chunk_entry_size;
        const free_table_bytes = region_free_capacity * free_entry_size;

        const zero_chunk = try self.allocator.alloc(u8, chunk_table_bytes);
        defer self.allocator.free(zero_chunk);
        @memset(zero_chunk, 0);
        try file.writeAll(zero_chunk);

        const zero_free = try self.allocator.alloc(u8, free_table_bytes);
        defer self.allocator.free(zero_free);
        @memset(zero_free, 0);
        try file.writeAll(zero_free);
    }

    fn queueRegionCompaction(self: *WorldPersistence, region_x: i32, region_z: i32) !void {
        const key = regionKey(region_x, region_z);
        if (self.pending_compaction_set.contains(key)) return;
        try self.pending_compaction_set.put(key, {});
        try self.pending_compactions.append(self.allocator, .{ .x = region_x, .z = region_z });
        self.maintenance_metrics.queued_regions = self.pending_compactions.items.len;
    }

    fn processCompactionJob(self: *WorldPersistence, coord: RegionCoord) !void {
        var region = try self.openRegionForWrite(coord.x, coord.z);
        defer region.deinit();
        if (!region.shouldCompact()) return;
        try self.compactRegionInternal(&region);
    }

    pub fn serviceMaintenance(self: *WorldPersistence, max_jobs: usize) void {
        var jobs: usize = 0;
        while (jobs < max_jobs and self.pending_compactions.items.len > 0) : (jobs += 1) {
            const coord = self.pending_compactions.orderedRemove(0);
            const key = regionKey(coord.x, coord.z);
            _ = self.pending_compaction_set.remove(key);

            const start = std.time.nanoTimestamp();
            self.processCompactionJob(coord) catch |err| {
                self.maintenance_metrics.total_failures += 1;
                std.debug.print("Region compaction failed ({d}, {d}): {any}\n", .{ coord.x, coord.z, err });
                continue;
            };
            const end = std.time.nanoTimestamp();
            self.maintenance_metrics.total_compactions += 1;
            self.maintenance_metrics.last_compaction_duration_ns = end - start;
            const seconds = @divTrunc(end, @as(i128, std.time.ns_per_s));
            self.maintenance_metrics.last_compaction_timestamp = @intCast(seconds);
        }
        self.maintenance_metrics.queued_regions = self.pending_compactions.items.len;
    }

    pub fn getMaintenanceMetrics(self: *const WorldPersistence) MaintenanceMetrics {
        var metrics = self.maintenance_metrics;
        metrics.queued_regions = self.pending_compactions.items.len;
        return metrics;
    }
};

fn defaultSeed() u64 {
    const ts = std.time.nanoTimestamp();
    const abs_ts_u128: u128 = if (ts < 0) @intCast(-ts) else @intCast(ts);
    const seed: u64 = @truncate(abs_ts_u128);
    var prng = std.Random.DefaultPrng.init(seed);
    return prng.random().int(u64);
}

fn compressChunk(allocator: std.mem.Allocator, chunk: *const terrain.Chunk) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var current_type: terrain.BlockType = undefined;
    var run: usize = 0;
    var first = true;

    const flush = struct {
        fn flushInner(list: *std.ArrayList(u8), alloc: std.mem.Allocator, block_type: terrain.BlockType, run_len: usize) !void {
            try list.append(alloc, @intFromEnum(block_type));
            var remaining = run_len;
            while (remaining > 0) {
                const chunk_size = @min(remaining, max_rle_run);
                var buf: [2]u8 = undefined;
                const chunk_len: u16 = @intCast(chunk_size);
                std.mem.writeInt(u16, &buf, chunk_len, .little);
                try list.appendSlice(alloc, &buf);
                remaining -= chunk_size;
                if (remaining > 0) {
                    try list.append(alloc, @intFromEnum(block_type));
                }
            }
        }
    }.flushInner;

    for (0..terrain.Chunk.CHUNK_SIZE) |x| {
        for (0..terrain.Chunk.CHUNK_SIZE) |z| {
            for (0..terrain.Chunk.CHUNK_HEIGHT) |y| {
                const block_type = chunk.blocks[x][z][y].block_type;
                if (first) {
                    current_type = block_type;
                    run = 1;
                    first = false;
                    continue;
                }

                if (block_type == current_type and run < max_rle_run) {
                    run += 1;
                } else {
                    try flush(&buffer, allocator, current_type, run);
                    current_type = block_type;
                    run = 1;
                }
            }
        }
    }

    if (!first and run > 0) {
        try flush(&buffer, allocator, current_type, run);
    }

    return buffer.toOwnedSlice(allocator);
}

fn writeChunkBlocksFromRaw(chunk: *terrain.Chunk, data: []const u8) !void {
    if (data.len != total_blocks) return error.InvalidChunkFile;

    var index: usize = 0;
    for (0..terrain.Chunk.CHUNK_SIZE) |x| {
        for (0..terrain.Chunk.CHUNK_SIZE) |z| {
            for (0..terrain.Chunk.CHUNK_HEIGHT) |y| {
                const block_type: terrain.BlockType = @enumFromInt(data[index]);
                chunk.blocks[x][z][y] = terrain.Block.init(block_type);
                index += 1;
            }
        }
    }
}

fn writeChunkBlocksFromCompressed(chunk: *terrain.Chunk, data: []const u8, expected_blocks: usize) !void {
    if (expected_blocks != total_blocks) return error.InvalidChunkFile;
    if (data.len % 3 != 0) return error.InvalidCompressedChunk;

    var index: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) : (offset += 3) {
        const block_type: terrain.BlockType = @enumFromInt(data[offset]);
        const lo = data[offset + 1];
        const hi = data[offset + 2];
        const run_len = @as(u16, lo) | (@as(u16, hi) << 8);
        if (run_len == 0) return error.InvalidCompressedChunk;

        const run: usize = @intCast(run_len);
        if (index + run > expected_blocks) return error.InvalidCompressedChunk;

        var remaining = run;
        while (remaining > 0) : (remaining -= 1) {
            const column_index = index / terrain.Chunk.CHUNK_HEIGHT;
            const x = column_index / terrain.Chunk.CHUNK_SIZE;
            const z = column_index % terrain.Chunk.CHUNK_SIZE;
            const y = index % terrain.Chunk.CHUNK_HEIGHT;
            chunk.blocks[x][z][y] = terrain.Block.init(block_type);
            index += 1;
        }
    }

    if (index != expected_blocks) {
        return error.InvalidCompressedChunk;
    }
}

test "world metadata round-trip with seed validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const worlds_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/worlds", .{tmp_path});
    defer std.testing.allocator.free(worlds_root);

    var wp = try WorldPersistence.init(std.testing.allocator, "test_world", .{
        .seed = 12345,
        .worlds_root = worlds_root,
    });
    defer wp.deinit();

    try std.testing.expectEqual(@as(u64, 12345), wp.seed());

    const orig_last_played = wp.metadata.last_played_timestamp;
    try wp.saveMetadata();
    try std.testing.expect(wp.metadata.last_played_timestamp >= orig_last_played);

    wp.deinit();

    var reopened = try WorldPersistence.init(std.testing.allocator, "test_world", .{
        .seed = 12345,
        .worlds_root = worlds_root,
    });
    defer reopened.deinit();

    try std.testing.expectEqual(@as(u64, 12345), reopened.seed());

    const mismatch = WorldPersistence.init(std.testing.allocator, "test_world", .{
        .seed = 999,
        .worlds_root = worlds_root,
    });
    try std.testing.expectError(error.SeedMismatch, mismatch);
}

test "chunk save/load with compression round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const worlds_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/worlds", .{tmp_path});
    defer std.testing.allocator.free(worlds_root);

    var wp = try WorldPersistence.init(std.testing.allocator, "chunk_test", .{
        .seed = 1,
        .worlds_root = worlds_root,
    });
    defer wp.deinit();

    var chunk = terrain.Chunk.init(0, 0);
    chunk.modified = true;

    // Set a few blocks to ensure compression stores data
    chunk.blocks[0][0][0] = terrain.Block.init(.stone);
    chunk.blocks[0][0][1] = terrain.Block.init(.dirt);
    chunk.blocks[10][10][128] = terrain.Block.init(.sand);
    chunk.modified = true;

    try wp.saveChunk(&chunk);
    try std.testing.expect(!chunk.modified);

    const maybe_loaded = try wp.loadChunk(0, 0);
    try std.testing.expect(maybe_loaded != null);
    const loaded = maybe_loaded.?;
    try std.testing.expectEqual(@intFromEnum(terrain.BlockType.stone), @intFromEnum(loaded.blocks[0][0][0].block_type));
    try std.testing.expectEqual(@intFromEnum(terrain.BlockType.dirt), @intFromEnum(loaded.blocks[0][0][1].block_type));
    try std.testing.expectEqual(@intFromEnum(terrain.BlockType.sand), @intFromEnum(loaded.blocks[10][10][128].block_type));

    try std.testing.expect((try wp.loadChunk(5, 5)) == null);
}

test "world settings summary reflects updates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const worlds_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/worlds", .{tmp_path});
    defer std.testing.allocator.free(worlds_root);

    var wp = try WorldPersistence.init(std.testing.allocator, "settings_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer wp.deinit();

    wp.setAutosaveIntervalSeconds(45);
    wp.setRegionBackupRetention(5);
    wp.setDifficulty(.hard);

    const summary = try loadWorldSettingsSummary(std.testing.allocator, worlds_root, "settings_test");
    try std.testing.expectEqual(@as(u32, 45), summary.autosave_interval_seconds);
    try std.testing.expectEqual(@as(usize, 5), summary.backup_retention);
    try std.testing.expectEqual(Difficulty.hard, summary.difficulty);
    try std.testing.expectEqual(@as(i64, 0), summary.maintenance_last_timestamp);
    try std.testing.expectEqual(@as(usize, 0), summary.maintenance_queued);
    try std.testing.expectEqual(default_backup_schedule_interval_seconds, summary.maintenance_interval_seconds);
    try std.testing.expect(summary.maintenance_activity_score == 0);

    wp.queueRegionCompactionRequest(0, 0);
    const metrics = wp.getMaintenanceMetrics();
    try std.testing.expect(metrics.queued_regions > 0);
}

test "service maintenance processes queued compactions and updates metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const worlds_root = try std.fs.path.join(allocator, &.{ tmp_path, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var wp = try WorldPersistence.init(allocator, "maintenance_service_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer wp.deinit();

    var chunk = terrain.Chunk.init(0, 0);
    chunk.generate();
    try wp.saveChunk(&chunk);

    var region = try wp.openRegionForWrite(0, 0);
    const coords = chunkRegionCoords(0, 0);
    const chunk_idx = chunkIndexFromLocal(coords.local_x, coords.local_z);
    const entry = region.chunk_entries[chunk_idx];
    try std.testing.expect(entry.size > 0);

    var free_offset = entry.offset + entry.size;
    const stride: u64 = 64;

    var i: usize = 0;
    while (i < region_free_capacity) : (i += 1) {
        region.free_entries[i] = FreeEntry{
            .offset = free_offset + @as(u64, i) * stride,
            .length = 1,
            .reserved = 0,
        };
    }

    region.free_count = region_free_capacity;
    region.header.free_count = @as(u16, @intCast(region_free_capacity));
    region.file_size = free_offset + @as(u64, region_free_capacity) * stride;

    try region.flush();
    region.deinit();

    wp.queueRegionCompactionRequest(coords.region_x, coords.region_z);
    const before = wp.getMaintenanceMetrics();
    try std.testing.expectEqual(@as(usize, 1), before.queued_regions);

    wp.serviceMaintenance(4);

    const after = wp.getMaintenanceMetrics();
    try std.testing.expectEqual(@as(usize, 0), after.queued_regions);
    try std.testing.expect(after.total_compactions >= before.total_compactions + 1);
    try std.testing.expect(after.last_compaction_duration_ns > 0);
    try std.testing.expect(after.last_compaction_timestamp >= before.last_compaction_timestamp);
    try std.testing.expectEqual(before.total_failures, after.total_failures);

    const backup_status = wp.backupStatus();
    try std.testing.expect(backup_status.retained > 0);
    try std.testing.expect(backup_status.last_backup_timestamp >= after.last_compaction_timestamp);
}
