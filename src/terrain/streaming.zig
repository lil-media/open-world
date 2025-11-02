const std = @import("std");
const terrain = @import("terrain.zig");
const generator = @import("generator.zig");
const persistence = @import("persistence.zig");
const math = @import("../utils/math.zig");

const SelectionPoint = struct {
    x: i32,
    z: i32,
    y: i32,

    fn init(x: i32, z: i32, y: i32) SelectionPoint {
        return .{ .x = x, .z = z, .y = y };
    }
};

pub const SelectionBounds = struct {
    min_x: i32,
    max_x: i32,
    min_z: i32,
    max_z: i32,
    min_y: i32,
    max_y: i32,

    pub fn width(self: SelectionBounds) usize {
        return @as(usize, @intCast(self.max_x - self.min_x + 1));
    }

    pub fn depth(self: SelectionBounds) usize {
        return @as(usize, @intCast(self.max_z - self.min_z + 1));
    }

    pub fn height(self: SelectionBounds) usize {
        return @as(usize, @intCast(self.max_y - self.min_y + 1));
    }
};

const SelectionState = struct {
    active: bool = false,
    anchor: SelectionPoint = SelectionPoint.init(0, 0, 0),
    cursor: SelectionPoint = SelectionPoint.init(0, 0, 0),

    fn begin(self: *SelectionState, x: i32, z: i32, y: i32) void {
        self.active = true;
        self.anchor = SelectionPoint.init(x, z, y);
        self.cursor = self.anchor;
    }

    fn update(self: *SelectionState, x: i32, z: i32, y: i32) void {
        if (!self.active) return;
        self.cursor = SelectionPoint.init(x, z, y);
    }

    fn clear(self: *SelectionState) void {
        self.active = false;
        self.anchor = SelectionPoint.init(0, 0, 0);
        self.cursor = SelectionPoint.init(0, 0, 0);
    }

    fn bounds(self: SelectionState) ?SelectionBounds {
        if (!self.active) return null;

        var min_x = self.anchor.x;
        var max_x = self.anchor.x;
        if (self.cursor.x < min_x) {
            min_x = self.cursor.x;
        } else if (self.cursor.x > max_x) {
            max_x = self.cursor.x;
        }

        var min_z = self.anchor.z;
        var max_z = self.anchor.z;
        if (self.cursor.z < min_z) {
            min_z = self.cursor.z;
        } else if (self.cursor.z > max_z) {
            max_z = self.cursor.z;
        }

        var min_y = self.anchor.y;
        var max_y = self.anchor.y;
        if (self.cursor.y < min_y) {
            min_y = self.cursor.y;
        } else if (self.cursor.y > max_y) {
            max_y = self.cursor.y;
        }

        return SelectionBounds{
            .min_x = min_x,
            .max_x = max_x,
            .min_z = min_z,
            .max_z = max_z,
            .min_y = min_y,
            .max_y = max_y,
        };
    }
};

pub const ClipboardDimensions = struct {
    width: usize,
    depth: usize,
    height: usize,
};

const BlockClipboard = struct {
    width: usize = 0,
    depth: usize = 0,
    height: usize = 0,
    blocks: std.ArrayListUnmanaged(terrain.Block) = .{},

    fn clear(self: *BlockClipboard) void {
        self.blocks.clearRetainingCapacity();
        self.width = 0;
        self.depth = 0;
        self.height = 0;
    }

    fn deinit(self: *BlockClipboard, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        self.clear();
    }

    fn isEmpty(self: BlockClipboard) bool {
        return self.blocks.items.len == 0;
    }

    fn dimensions(self: BlockClipboard) ?ClipboardDimensions {
        if (self.isEmpty()) return null;
        return ClipboardDimensions{
            .width = self.width,
            .depth = self.depth,
            .height = self.height,
        };
    }
};

/// Chunk position (x, z coordinates)
pub const ChunkPos = struct {
    x: i32,
    z: i32,

    pub fn init(x: i32, z: i32) ChunkPos {
        return .{ .x = x, .z = z };
    }

    pub fn fromWorldPos(world_x: i32, world_z: i32) ChunkPos {
        return init(
            @divFloor(world_x, terrain.Chunk.CHUNK_SIZE),
            @divFloor(world_z, terrain.Chunk.CHUNK_SIZE),
        );
    }

    pub fn distance(self: ChunkPos, other: ChunkPos) f32 {
        const dx = @as(f32, @floatFromInt(self.x - other.x));
        const dz = @as(f32, @floatFromInt(self.z - other.z));
        return @sqrt(dx * dx + dz * dz);
    }

    pub fn eql(self: ChunkPos, other: ChunkPos) bool {
        return self.x == other.x and self.z == other.z;
    }

    pub fn hash(self: ChunkPos) u64 {
        // Simple hash combining x and z coordinates
        const x_hash = @as(u64, @bitCast(@as(i64, self.x)));
        const z_hash = @as(u64, @bitCast(@as(i64, self.z)));
        return x_hash ^ (z_hash << 32) ^ (z_hash >> 32);
    }
};

/// Priority for chunk loading
pub const ChunkPriority = struct {
    distance: f32,
    direction_alignment: f32,
    modified: bool,

    pub fn calculate(chunk_pos: ChunkPos, player_chunk: ChunkPos, player_forward: math.Vec3) ChunkPriority {
        const dist = chunk_pos.distance(player_chunk);

        // Calculate direction alignment (-1 to 1)
        const dx = @as(f32, @floatFromInt(chunk_pos.x - player_chunk.x));
        const dz = @as(f32, @floatFromInt(chunk_pos.z - player_chunk.z));
        const len = @sqrt(dx * dx + dz * dz);
        const alignment = if (len > 0.001)
            (dx * player_forward.x + dz * player_forward.z) / len
        else
            0.0;

        return .{
            .distance = dist,
            .direction_alignment = alignment,
            .modified = false,
        };
    }

    pub fn score(self: ChunkPriority) f32 {
        // Lower score = higher priority
        const modified_bonus: f32 = if (self.modified) 100.0 else 0.0;
        return self.distance * 0.7 - // Closer is better
            self.direction_alignment * 10.0 - // Forward direction is better
            modified_bonus; // Modified chunks highest priority
    }
};

/// Chunk loading request
pub const ChunkRequest = struct {
    pos: ChunkPos,
    priority: ChunkPriority,

    pub fn lessThan(_: void, a: ChunkRequest, b: ChunkRequest) std.math.Order {
        const a_score = a.priority.score();
        const b_score = b.priority.score();
        if (a_score < b_score) return .lt;
        if (a_score > b_score) return .gt;
        return .eq;
    }
};

/// Chunk state in the streaming system
pub const ChunkState = enum {
    unloaded,
    generating, // Being generated on background thread
    generated, // Generated but not meshed
    meshing, // Being meshed on background thread
    ready, // Ready to render
    unloading, // Being saved and removed
};

pub const ChunkDetail = enum {
    full,
    surfaceMedium,
    surfaceFar,
};

const AutosaveReason = enum {
    timer,
    manual,
};

const AutosaveSummary = struct {
    timestamp_ns: i128,
    saved_chunks: u32,
    errors: u32,
    duration_ns: i128,
    reason: AutosaveReason,
    maintenance_enqueued: bool,
    queued_regions_total: usize,
    queued_regions_added: usize,
};

pub const default_backup_schedule_interval_seconds: u32 = persistence.default_backup_schedule_interval_seconds;
pub const minimum_backup_schedule_interval_seconds: u32 = persistence.minimum_backup_schedule_interval_seconds;
pub const maximum_backup_schedule_interval_seconds: u32 = persistence.maximum_backup_schedule_interval_seconds;

const LoadMetrics = struct {
    queued_candidates: u32 = 0,
    queued_generations: u32 = 0,
    completed_async: u32 = 0,
    immediate_loaded: u32 = 0,
    unloaded: u32 = 0,
};

const StreamingProfiling = struct {
    last_update_ns: i128 = 0,
    average_update_ns: f64 = 0,
    max_update_ns: i128 = 0,
    updates: u64 = 0,
    queued_candidates: u32 = 0,
    queued_generations: u32 = 0,
    completed_async: u32 = 0,
    immediate_loaded: u32 = 0,
    unloaded: u32 = 0,
    pending_generations: usize = 0,
};

/// Chunk streaming manager
pub const ChunkStreamingManager = struct {
    allocator: std.mem.Allocator,

    // Loaded chunks (hash map: ChunkPos -> Chunk)
    chunks: std.AutoHashMap(u64, *terrain.Chunk),
    chunk_states: std.AutoHashMap(u64, ChunkState),
    chunk_detail: std.AutoHashMap(u64, ChunkDetail),
    chunk_desired_detail: std.AutoHashMap(u64, ChunkDetail),

    // Chunk pool for reuse
    chunk_pool: std.ArrayList(*terrain.Chunk),

    // Request queues
    load_queue: std.PriorityQueue(ChunkRequest, void, ChunkRequest.lessThan),
    unload_queue: std.ArrayList(ChunkPos),

    // Terrain generator
    terrain_gen: generator.TerrainGenerator,

    // World persistence
    world_persistence: ?*persistence.WorldPersistence,

    // Async generation - NEW approach using dedicated worker thread
    generation_thread: ?std.Thread,
    generation_mutex: std.Thread.Mutex,
    generation_queue: std.ArrayList(ChunkPos), // Chunks waiting to be generated
    pending_chunks: std.AutoHashMap(u64, *terrain.Chunk), // Chunks being generated
    completed_chunks: std.ArrayList(ChunkPos), // Ready to be moved to main chunks
    should_stop: std.atomic.Value(bool),
    use_async: bool,

    // Persistence/autosave
    autosave_interval_ns: i128,
    last_autosave_ns: i128,
    autosave_interval_seconds: u32,
    last_autosave_summary: ?AutosaveSummary,
    backup_retention: usize,
    scheduled_backup_interval_ns: i128,
    scheduled_backup_elapsed_ns: i128,
    scheduled_backup_notice: bool,
    last_backup_queue_total: usize,
    last_backup_queue_added: usize,
    scheduled_backup_activity_avg: f32,
    scheduled_backup_interval_notice: bool,
    scheduled_backup_interval_notice_seconds: u32,

    // Settings
    view_distance: i32, // In chunks
    unload_distance: i32, // Hysteresis zone
    max_chunks_per_frame: u32,
    allocated_chunks: usize,
    tracked_chunks: std.ArrayListUnmanaged(*terrain.Chunk),
    profiling: StreamingProfiling,
    backup_queue_cooldown_ns: i128,
    last_backup_enqueue_ns: i128,
    selection: SelectionState,
    clipboard: BlockClipboard,

    pub fn init(allocator: std.mem.Allocator, seed: u64, view_distance: i32) !ChunkStreamingManager {
        // Use async by default with new dedicated thread approach
        return try initWithAsync(allocator, seed, view_distance, true);
    }

    /// Start the async worker thread - must be called AFTER init, once the manager is in its final location
    pub fn startAsyncGeneration(self: *ChunkStreamingManager) !void {
        if (self.use_async and self.generation_thread == null) {
            self.generation_thread = try std.Thread.spawn(.{}, generationWorkerThread, .{self});
        }
    }

    pub fn initWithAsync(allocator: std.mem.Allocator, seed: u64, view_distance: i32, use_async: bool) !ChunkStreamingManager {
        const ArrayListChunk = std.ArrayList(*terrain.Chunk);
        const ArrayListChunkPos = std.ArrayList(ChunkPos);

        const manager = ChunkStreamingManager{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, *terrain.Chunk).init(allocator),
            .chunk_states = std.AutoHashMap(u64, ChunkState).init(allocator),
            .chunk_detail = std.AutoHashMap(u64, ChunkDetail).init(allocator),
            .chunk_desired_detail = std.AutoHashMap(u64, ChunkDetail).init(allocator),
            .chunk_pool = ArrayListChunk{},
            .load_queue = std.PriorityQueue(ChunkRequest, void, ChunkRequest.lessThan).init(allocator, {}),
            .unload_queue = ArrayListChunkPos{},
            .terrain_gen = generator.TerrainGenerator.init(seed),
            .world_persistence = null,
            .generation_thread = null,
            .generation_mutex = .{},
            .generation_queue = ArrayListChunkPos{},
            .pending_chunks = std.AutoHashMap(u64, *terrain.Chunk).init(allocator),
            .completed_chunks = ArrayListChunkPos{},
            .should_stop = std.atomic.Value(bool).init(false),
            .use_async = use_async,
            .autosave_interval_ns = 30 * @as(i128, std.time.ns_per_s),
            .last_autosave_ns = std.time.nanoTimestamp(),
            .autosave_interval_seconds = 30,
            .last_autosave_summary = null,
            .backup_retention = persistence.default_region_backup_retention,
            .scheduled_backup_interval_ns = 0,
            .scheduled_backup_elapsed_ns = 0,
            .scheduled_backup_notice = false,
            .last_backup_queue_total = 0,
            .last_backup_queue_added = 0,
            .scheduled_backup_activity_avg = 0,
            .scheduled_backup_interval_notice = false,
            .scheduled_backup_interval_notice_seconds = default_backup_schedule_interval_seconds,
            .view_distance = view_distance,
            .unload_distance = view_distance + 2, // Hysteresis
            .max_chunks_per_frame = 4,
            .allocated_chunks = 0,
            .tracked_chunks = .{},
            .profiling = .{},
            .backup_queue_cooldown_ns = 60 * @as(i128, std.time.ns_per_s),
            .last_backup_enqueue_ns = 0,
            .selection = .{},
            .clipboard = .{},
        };

        // Don't start the thread yet - it will be started after the manager is in its final location
        return manager;
    }

    pub fn deinit(self: *ChunkStreamingManager) void {
        // Signal worker thread to stop and wait for it to finish
        if (self.use_async) {
            self.should_stop.store(true, .seq_cst);

            // Give the worker thread time to see the stop signal and exit cleanly
            // This prevents race conditions where the thread is mid-generation
            std.Thread.sleep(10 * std.time.ns_per_ms);

            if (self.generation_thread) |thread| {
                thread.join();
            }

            // Move any final completed chunks
            self.generation_mutex.lock();
            while (self.completed_chunks.items.len > 0) {
                const pos = self.completed_chunks.pop() orelse break;
                const hash_val = pos.hash();
                if (self.pending_chunks.fetchRemove(hash_val)) |entry| {
                    const chunk = entry.value;
                    self.chunks.put(hash_val, chunk) catch {};
                    self.chunk_states.put(hash_val, .ready) catch {};
                }
            }

            // Clean up any remaining pending chunks that never completed
            // NOTE: We intentionally DO NOT free these chunks to avoid race conditions
            // where the worker thread might still be accessing them during shutdown.
            // Since this is cleanup during program exit, the OS will reclaim the memory anyway.
            self.pending_chunks.clearRetainingCapacity();

            self.generation_mutex.unlock();
        }

        self.clipboard.deinit(self.allocator);
        self.selection.clear();
        self.unloadAll();
        self.chunks.deinit();
        self.chunk_states.deinit();
        self.chunk_detail.deinit();
        self.chunk_desired_detail.deinit();
        self.chunk_pool.deinit(self.allocator);
        self.load_queue.deinit();
        self.unload_queue.deinit(self.allocator);
        self.generation_queue.deinit(self.allocator);
        self.pending_chunks.deinit();
        self.completed_chunks.deinit(self.allocator);
        self.tracked_chunks.deinit(self.allocator);
    }

    pub fn unloadAll(self: *ChunkStreamingManager) void {
        // CRITICAL: Stop async generation BEFORE freeing chunks
        // to prevent worker thread from accessing freed memory
        if (self.use_async and self.generation_thread != null) {
            self.should_stop.store(true, .seq_cst);
            std.Thread.sleep(10 * std.time.ns_per_ms);
            if (self.generation_thread) |thread| {
                thread.join();
                self.generation_thread = null;
            }
        }

        self.chunks.clearRetainingCapacity();
        self.chunk_states.clearRetainingCapacity();
        self.chunk_detail.clearRetainingCapacity();
        self.chunk_desired_detail.clearRetainingCapacity();
        self.chunk_pool.clearRetainingCapacity();

        self.selection.clear();
        self.clipboard.clear();

        while (self.load_queue.removeOrNull()) |_| {}
        self.unload_queue.clearRetainingCapacity();

        for (self.tracked_chunks.items) |chunk_ptr| {
            self.allocator.destroy(chunk_ptr);
        }
        self.tracked_chunks.clearRetainingCapacity();
        self.allocated_chunks = 0;
    }

    /// Update chunk loading based on player position
    pub fn update(self: *ChunkStreamingManager, player_pos: math.Vec3, player_forward: math.Vec3) !void {
        const update_start = std.time.nanoTimestamp();
        const player_chunk = ChunkPos.fromWorldPos(
            @intFromFloat(@floor(player_pos.x)),
            @intFromFloat(@floor(player_pos.z)),
        );

        var metrics = LoadMetrics{};

        // Determine which chunks should be loaded
        try self.updateLoadQueue(player_chunk, player_forward);
        metrics.queued_candidates = @intCast(self.load_queue.items.len);

        // Determine which chunks should be unloaded
        try self.updateUnloadQueue(player_chunk);

        // Process loading (limit per frame)
        try self.processLoading(&metrics);

        // Process unloading
        metrics.unloaded = try self.processUnloading();

        self.autosaveIfDue();
        if (self.world_persistence) |wp| {
            wp.serviceMaintenance(1);
        }

        const update_end = std.time.nanoTimestamp();
        const delta_ns = update_end - update_start;
        if (self.scheduled_backup_interval_ns > 0) {
            self.scheduled_backup_elapsed_ns += delta_ns;
            if (self.scheduled_backup_elapsed_ns >= self.scheduled_backup_interval_ns) {
                if (self.queueLoadedRegionBackups()) {
                    self.scheduled_backup_elapsed_ns = 0;
                } else {
                    const retry_ns = 30 * @as(i128, std.time.ns_per_s);
                    const backoff = if (self.scheduled_backup_interval_ns > retry_ns)
                        self.scheduled_backup_interval_ns - retry_ns
                    else
                        @divTrunc(self.scheduled_backup_interval_ns, @as(i128, 2));
                    self.scheduled_backup_elapsed_ns = @max(backoff, @as(i128, 0));
                }
            }
        }

        var stats = &self.profiling;
        stats.last_update_ns = delta_ns;
        stats.updates += 1;
        const delta_f64 = @as(f64, @floatFromInt(delta_ns));
        if (stats.updates == 1) {
            stats.average_update_ns = delta_f64;
            stats.max_update_ns = delta_ns;
        } else {
            const updates_f64 = @as(f64, @floatFromInt(stats.updates));
            stats.average_update_ns += (delta_f64 - stats.average_update_ns) / updates_f64;
            if (delta_ns > stats.max_update_ns) stats.max_update_ns = delta_ns;
        }
        stats.pending_generations = self.pending_chunks.count();
        stats.queued_candidates = metrics.queued_candidates;
        stats.queued_generations = metrics.queued_generations;
        stats.completed_async = metrics.completed_async;
        stats.immediate_loaded = metrics.immediate_loaded;
        stats.unloaded = metrics.unloaded;

        if (std.debug.runtime_safety and !self.use_async) {
            // Account for chunks in all states: loaded, pooled, and pending (async)
            // Note: Async mode complicates tracking due to race conditions, so skip for now
            const active_chunks = self.chunks.count() + self.chunk_pool.items.len;
            if (self.allocated_chunks != active_chunks) {
                var i: usize = 0;
                while (i < self.tracked_chunks.items.len) : (i += 1) {
                    const ptr = self.tracked_chunks.items[i];
                    if (!self.chunkTrackedInCollections(ptr)) {
                        self.allocator.destroy(ptr);
                        std.debug.assert(self.allocated_chunks > 0);
                        self.allocated_chunks -= 1;
                        _ = self.tracked_chunks.swapRemove(i);
                        break;
                    }
                }
                std.debug.assert(self.allocated_chunks == active_chunks);
            }
        }
    }

    fn updateLoadQueue(self: *ChunkStreamingManager, player_chunk: ChunkPos, player_forward: math.Vec3) !void {
        // Clear old queue
        while (self.load_queue.removeOrNull()) |_| {}

        // Add chunks within view distance
        var dx: i32 = -self.view_distance;
        while (dx <= self.view_distance) : (dx += 1) {
            var dz: i32 = -self.view_distance;
            while (dz <= self.view_distance) : (dz += 1) {
                const chunk_pos = ChunkPos.init(
                    player_chunk.x + dx,
                    player_chunk.z + dz,
                );

                // Check if within circular distance
                const dist = chunk_pos.distance(player_chunk);
                if (dist > @as(f32, @floatFromInt(self.view_distance))) continue;

                // Skip if already loaded or currently generating
                const hash_val = chunk_pos.hash();
                if (self.chunks.contains(hash_val)) continue;
                if (self.pending_chunks.contains(hash_val)) continue;

                // Add to load queue with priority
                const priority = ChunkPriority.calculate(chunk_pos, player_chunk, player_forward);
                try self.load_queue.add(ChunkRequest{
                    .pos = chunk_pos,
                    .priority = priority,
                });
            }
        }
    }

    fn updateUnloadQueue(self: *ChunkStreamingManager, player_chunk: ChunkPos) !void {
        self.unload_queue.clearRetainingCapacity();

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            const chunk_pos = ChunkPos.init(chunk.x, chunk.z);

            const dist = chunk_pos.distance(player_chunk);
            if (dist > @as(f32, @floatFromInt(self.unload_distance))) {
                try self.unload_queue.append(self.allocator, chunk_pos);
            }
        }
    }

    fn processLoading(self: *ChunkStreamingManager, metrics: *LoadMetrics) !void {
        // First, collect completed async chunks (non-blocking)
        if (self.use_async) {
            self.generation_mutex.lock();
            defer self.generation_mutex.unlock();

            while (self.completed_chunks.items.len > 0) {
                const pos = self.completed_chunks.pop() orelse break;
                const hash_val = pos.hash();

                if (self.pending_chunks.fetchRemove(hash_val)) |entry| {
                    const chunk = entry.value;
                    try self.chunks.put(hash_val, chunk);
                    try self.chunk_states.put(hash_val, .ready);
                    metrics.completed_async += 1;
                }
            }
        }

        // Then queue new generation tasks
        var loaded: u32 = 0;
        while (loaded < self.max_chunks_per_frame) {
            const request = self.load_queue.removeOrNull() orelse break;

            if (self.use_async) {
                // Queue for background generation instead of generating synchronously
                try self.queueChunkGeneration(request.pos);
                metrics.queued_generations += 1;
            } else {
                try self.loadChunk(request.pos);
                metrics.immediate_loaded += 1;
            }

            loaded += 1;
        }
    }

    fn queueChunkGeneration(self: *ChunkStreamingManager, pos: ChunkPos) !void {
        const hash_val = pos.hash();

        // Get or create chunk
        const chunk = try self.acquireChunk();
        chunk.x = pos.x;
        chunk.z = pos.z;
        chunk.modified = false;

        // Add to pending chunks
        try self.pending_chunks.put(hash_val, chunk);
        try self.chunk_states.put(hash_val, .generating);

        // Queue position for worker thread
        self.generation_mutex.lock();
        defer self.generation_mutex.unlock();
        try self.generation_queue.append(self.allocator, pos);
    }

    /// Dedicated worker thread that continuously generates chunks
    fn generationWorkerThread(manager: *ChunkStreamingManager) void {
        const terrain_gen = manager.terrain_gen;

        while (!manager.should_stop.load(.seq_cst)) {
            // Check if there's work to do
            manager.generation_mutex.lock();
            const maybe_pos = if (manager.generation_queue.items.len > 0)
                manager.generation_queue.orderedRemove(0)
            else
                null;
            manager.generation_mutex.unlock();

            if (maybe_pos) |pos| {
                const hash_val = pos.hash();

                // Get the chunk from pending - keep it there to prevent unloading
                manager.generation_mutex.lock();
                const maybe_chunk = manager.pending_chunks.get(hash_val);
                manager.generation_mutex.unlock();

                if (maybe_chunk) |chunk| {
                    // Check if we should stop BEFORE starting the slow operation
                    if (manager.should_stop.load(.seq_cst)) {
                        break;
                    }

                    // Generate terrain (this is the slow part)
                    // Do this OUTSIDE the mutex to allow other operations to proceed
                    // The chunk stays in pending_chunks to protect it from being freed
                    terrain_gen.generateChunk(chunk);

                    // Mark as complete - but first check if the chunk is still in pending
                    // (it might have been cancelled/unloaded while we were generating)
                    manager.generation_mutex.lock();
                    if (manager.pending_chunks.contains(hash_val)) {
                        manager.completed_chunks.append(manager.allocator, pos) catch {};
                    }
                    manager.generation_mutex.unlock();
                }
            } else {
                // No work - sleep briefly to avoid busy-waiting
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    fn processUnloading(self: *ChunkStreamingManager) !u32 {
        var unloaded: u32 = 0;
        for (self.unload_queue.items) |chunk_pos| {
            try self.unloadChunk(chunk_pos);
            unloaded += 1;
        }
        self.unload_queue.clearRetainingCapacity();
        return unloaded;
    }

    fn loadChunk(self: *ChunkStreamingManager, pos: ChunkPos) !void {
        const hash_val = pos.hash();

        // Try to load from disk first if persistence is enabled
        var chunk: *terrain.Chunk = undefined;
        var loaded_from_disk = false;

        if (self.world_persistence) |wp| {
            if (try wp.loadChunk(pos.x, pos.z)) |loaded_chunk| {
                chunk = try self.acquireChunk();
                chunk.* = loaded_chunk;
                loaded_from_disk = true;
            }
        }

        // If not loaded from disk, generate new chunk
        if (!loaded_from_disk) {
            chunk = try self.acquireChunk();
            chunk.x = pos.x;
            chunk.z = pos.z;
            chunk.modified = false;

            // Generate terrain
            self.terrain_gen.generateChunk(chunk);
        }

        // Add to loaded chunks
        try self.chunks.put(hash_val, chunk);
        try self.chunk_states.put(hash_val, .ready);
    }

    fn unloadChunk(self: *ChunkStreamingManager, pos: ChunkPos) !void {
        const hash_val = pos.hash();

        // Don't unload chunks that are currently being generated!
        if (self.use_async) {
            self.generation_mutex.lock();
            const is_generating = self.pending_chunks.contains(hash_val);
            self.generation_mutex.unlock();

            if (is_generating) {
                // Skip unloading this chunk - it's still being generated
                return;
            }
        }

        if (self.chunks.fetchRemove(hash_val)) |entry| {
            const chunk = entry.value;

            // Save chunk if modified and persistence is enabled
            if (chunk.modified and self.world_persistence != null) {
                self.world_persistence.?.saveChunk(chunk) catch |err| {
                    std.debug.print("Warning: Failed to save chunk ({d}, {d}): {any}\n", .{ chunk.x, chunk.z, err });
                };
            }

            // Return to pool
            try self.releaseChunk(chunk);
        }

        _ = self.chunk_states.remove(hash_val);
        _ = self.chunk_detail.remove(hash_val);
        _ = self.chunk_desired_detail.remove(hash_val);
    }

    pub fn resetAutosaveTimer(self: *ChunkStreamingManager) void {
        self.last_autosave_ns = std.time.nanoTimestamp();
    }

    pub fn setAutosaveIntervalSeconds(self: *ChunkStreamingManager, seconds: u32) void {
        self.autosave_interval_seconds = seconds;
        if (seconds == 0) {
            self.autosave_interval_ns = 0;
        } else {
            const seconds_i128: i128 = @intCast(seconds);
            self.autosave_interval_ns = seconds_i128 * @as(i128, std.time.ns_per_s);
        }
        if (self.world_persistence) |wp| {
            wp.setAutosaveIntervalSeconds(seconds);
        }
    }

    pub fn autosaveIntervalSeconds(self: *const ChunkStreamingManager) u32 {
        return self.autosave_interval_seconds;
    }

    pub fn setBackupRetention(self: *ChunkStreamingManager, retention: usize) void {
        self.backup_retention = retention;
        if (self.world_persistence) |wp| {
            wp.setRegionBackupRetention(retention);
            self.backup_retention = wp.regionBackupRetention();
        }
    }

    pub fn backupRetention(self: *const ChunkStreamingManager) usize {
        return self.backup_retention;
    }

    pub fn syncPersistenceSettings(self: *ChunkStreamingManager) void {
        if (self.world_persistence) |wp| {
            const interval = wp.autosaveIntervalSeconds();
            self.autosave_interval_seconds = interval;
            if (interval == 0) {
                self.autosave_interval_ns = 0;
            } else {
                const seconds_i128: i128 = @intCast(interval);
                self.autosave_interval_ns = seconds_i128 * @as(i128, std.time.ns_per_s);
            }
            self.backup_retention = wp.regionBackupRetention();
            const metrics = wp.getMaintenanceMetrics();
            var schedule_seconds = metrics.schedule_interval_seconds;
            if (schedule_seconds == 0) {
                schedule_seconds = default_backup_schedule_interval_seconds;
            }
            if (schedule_seconds < minimum_backup_schedule_interval_seconds) {
                schedule_seconds = minimum_backup_schedule_interval_seconds;
            }
            if (schedule_seconds > maximum_backup_schedule_interval_seconds) {
                schedule_seconds = maximum_backup_schedule_interval_seconds;
            }
            self.scheduled_backup_interval_ns = @as(i128, @intCast(schedule_seconds)) * @as(i128, std.time.ns_per_s);
            self.scheduled_backup_elapsed_ns = 0;
            self.scheduled_backup_notice = false;
            self.scheduled_backup_activity_avg = metrics.recent_activity_score;
            self.scheduled_backup_interval_notice_seconds = schedule_seconds;
            self.scheduled_backup_interval_notice = false;
            self.last_backup_queue_total = metrics.queued_regions;
            self.last_backup_queue_added = 0;
            wp.recordMaintenanceSchedule(schedule_seconds, self.scheduled_backup_activity_avg, metrics.queued_regions);
        }
    }

    pub fn takeAutosaveSummary(self: *ChunkStreamingManager) ?AutosaveSummary {
        const result = self.last_autosave_summary;
        self.last_autosave_summary = null;
        return result;
    }

    fn adjustScheduledMaintenanceCadence(self: *ChunkStreamingManager, queued_before: usize, queued_after: usize) void {
        const added = if (queued_after > queued_before) queued_after - queued_before else 0;
        const weighted_sample = added * 4 + queued_after;
        const sample_score = @as(f32, @floatFromInt(weighted_sample));
        const previous = self.scheduled_backup_activity_avg;
        if (previous == 0) {
            self.scheduled_backup_activity_avg = sample_score;
        } else {
            self.scheduled_backup_activity_avg = previous * 0.65 + sample_score * 0.35;
        }

        const activity = self.scheduled_backup_activity_avg;
        var target_seconds: u32 = default_backup_schedule_interval_seconds;
        if (activity >= 64) {
            target_seconds = minimum_backup_schedule_interval_seconds;
        } else if (activity >= 36) {
            target_seconds = 7 * 60;
        } else if (activity >= 20) {
            target_seconds = 8 * 60;
        } else if (activity <= 3 and queued_after == 0) {
            target_seconds = maximum_backup_schedule_interval_seconds;
        } else if (activity <= 6 and queued_after < 3) {
            target_seconds = 12 * 60;
        }

        if (target_seconds < minimum_backup_schedule_interval_seconds) {
            target_seconds = minimum_backup_schedule_interval_seconds;
        }
        if (target_seconds > maximum_backup_schedule_interval_seconds) {
            target_seconds = maximum_backup_schedule_interval_seconds;
        }

        const target_ns = @as(i128, @intCast(target_seconds)) * @as(i128, std.time.ns_per_s);
        const changed = target_ns != self.scheduled_backup_interval_ns;
        self.scheduled_backup_interval_ns = target_ns;
        self.scheduled_backup_interval_notice_seconds = target_seconds;
        if (changed) {
            self.scheduled_backup_interval_notice = true;
            self.scheduled_backup_elapsed_ns = 0;
        }

        if (self.world_persistence) |wp| {
            wp.recordMaintenanceSchedule(target_seconds, self.scheduled_backup_activity_avg, queued_after);
        }
    }

    pub fn forceAutosave(self: *ChunkStreamingManager) ?AutosaveSummary {
        if (self.world_persistence == null) return null;
        const summary = self.performAutosave(.manual);
        if (summary) |info| {
            self.last_autosave_ns = info.timestamp_ns;
        } else {
            self.last_autosave_ns = std.time.nanoTimestamp();
        }
        return summary;
    }

    fn autosaveIfDue(self: *ChunkStreamingManager) void {
        if (self.world_persistence == null) return;
        if (self.autosave_interval_ns == 0) return;

        const now = std.time.nanoTimestamp();
        if (now - self.last_autosave_ns < self.autosave_interval_ns) return;
        self.last_autosave_ns = now;
        if (self.performAutosave(.timer)) |summary| {
            self.last_autosave_summary = summary;
        }
    }

    fn performAutosave(self: *ChunkStreamingManager, reason: AutosaveReason) ?AutosaveSummary {
        if (self.world_persistence == null) return null;

        const start = std.time.nanoTimestamp();
        var saved: u32 = 0;
        var errors: u32 = 0;
        var maintenance_enqueued = false;
        var queued_regions_total: usize = 0;
        var queued_regions_added: usize = 0;

        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr_ptr| {
            const chunk = chunk_ptr_ptr.*;
            if (!chunk.modified) continue;

            self.world_persistence.?.saveChunk(chunk) catch |err| {
                errors += 1;
                std.debug.print("Warning: Autosave failed for chunk ({d}, {d}): {any}\n", .{ chunk.x, chunk.z, err });
                continue;
            };
            saved += 1;
        }

        if (saved == 0 and errors == 0) return null;

        if (saved > 0) {
            if (self.queueLoadedRegionBackups()) {
                maintenance_enqueued = true;
                queued_regions_total = self.last_backup_queue_total;
                queued_regions_added = self.last_backup_queue_added;
            }
        }

        const end = std.time.nanoTimestamp();
        return AutosaveSummary{
            .timestamp_ns = end,
            .saved_chunks = saved,
            .errors = errors,
            .duration_ns = end - start,
            .reason = reason,
            .maintenance_enqueued = maintenance_enqueued,
            .queued_regions_total = queued_regions_total,
            .queued_regions_added = queued_regions_added,
        };
    }

    fn acquireChunk(self: *ChunkStreamingManager) !*terrain.Chunk {
        if (self.chunk_pool.getLastOrNull()) |chunk| {
            _ = self.chunk_pool.pop();
            return chunk;
        }

        // Allocate new chunk
        const chunk = try self.allocator.create(terrain.Chunk);
        chunk.* = terrain.Chunk.init(0, 0);
        self.allocated_chunks += 1;
        self.tracked_chunks.append(self.allocator, chunk) catch {
            self.allocator.destroy(chunk);
            self.allocated_chunks -= 1;
            return error.OutOfMemory;
        };
        return chunk;
    }

    fn releaseChunk(self: *ChunkStreamingManager, chunk: *terrain.Chunk) !void {
        // Reset chunk
        chunk.* = terrain.Chunk.init(0, 0);

        // Add to pool
        try self.chunk_pool.append(self.allocator, chunk);
    }

    fn removeTrackedChunk(self: *ChunkStreamingManager, chunk_ptr: *terrain.Chunk) void {
        var i: usize = 0;
        while (i < self.tracked_chunks.items.len) : (i += 1) {
            if (self.tracked_chunks.items[i] == chunk_ptr) {
                _ = self.tracked_chunks.swapRemove(i);
                return;
            }
        }
    }

    fn chunkTrackedInCollections(self: *ChunkStreamingManager, chunk_ptr: *terrain.Chunk) bool {
        var it = self.chunks.valueIterator();
        while (it.next()) |entry| {
            if (entry.* == chunk_ptr) return true;
        }
        for (self.chunk_pool.items) |pool_chunk| {
            if (pool_chunk == chunk_ptr) return true;
        }
        var pending_it = self.pending_chunks.valueIterator();
        while (pending_it.next()) |entry| {
            if (entry.* == chunk_ptr) return true;
        }
        return false;
    }

    /// Get chunk at position
    pub fn getChunk(self: *ChunkStreamingManager, pos: ChunkPos) ?*terrain.Chunk {
        const hash_val = pos.hash();
        return self.chunks.get(hash_val);
    }

    /// Get chunk state
    pub fn getChunkState(self: *ChunkStreamingManager, pos: ChunkPos) ChunkState {
        const hash_val = pos.hash();
        return self.chunk_states.get(hash_val) orelse .unloaded;
    }

    pub fn getChunkDetail(self: *ChunkStreamingManager, pos: ChunkPos) ?ChunkDetail {
        return self.chunk_detail.get(pos.hash());
    }

    pub fn setChunkDetail(self: *ChunkStreamingManager, pos: ChunkPos, detail: ChunkDetail) void {
        self.chunk_detail.put(pos.hash(), detail) catch {};
    }

    pub fn getDesiredDetail(self: *ChunkStreamingManager, pos: ChunkPos) ?ChunkDetail {
        return self.chunk_desired_detail.get(pos.hash());
    }

    pub fn setDesiredDetail(self: *ChunkStreamingManager, pos: ChunkPos, detail: ChunkDetail) void {
        self.chunk_desired_detail.put(pos.hash(), detail) catch {};
    }

    pub fn profilingStats(self: *const ChunkStreamingManager) StreamingProfiling {
        return self.profiling;
    }

    pub fn queueLoadedRegionBackups(self: *ChunkStreamingManager) bool {
        if (self.world_persistence) |wp| {
            const now = std.time.nanoTimestamp();
            const before_metrics = wp.getMaintenanceMetrics();
            const queued_before = before_metrics.queued_regions;
            self.last_backup_queue_total = queued_before;
            self.last_backup_queue_added = 0;

            if (self.backup_queue_cooldown_ns > 0 and self.last_backup_enqueue_ns != 0) {
                if (now - self.last_backup_enqueue_ns < self.backup_queue_cooldown_ns) {
                    return false;
                }
            }

            var it = self.chunks.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                wp.queueRegionCompactionRequest(chunk.x, chunk.z);
            }

            const after_metrics = wp.getMaintenanceMetrics();
            const queued_after = after_metrics.queued_regions;
            self.last_backup_queue_total = queued_after;
            const added = if (queued_after > queued_before)
                queued_after - queued_before
            else
                0;
            self.last_backup_queue_added = added;

            self.adjustScheduledMaintenanceCadence(queued_before, queued_after);

            if (added > 0) {
                self.last_backup_enqueue_ns = now;
                self.scheduled_backup_elapsed_ns = 0;
                self.scheduled_backup_notice = true;
                return true;
            }
            return false;
        }
        self.last_backup_queue_total = 0;
        self.last_backup_queue_added = 0;
        return false;
    }

    pub fn backupCooldownSecondsRemaining(self: *const ChunkStreamingManager) i64 {
        if (self.backup_queue_cooldown_ns == 0 or self.last_backup_enqueue_ns == 0) return 0;
        const now = std.time.nanoTimestamp();
        const elapsed: i128 = now - self.last_backup_enqueue_ns;
        if (elapsed >= self.backup_queue_cooldown_ns) return 0;
        const remaining = self.backup_queue_cooldown_ns - elapsed;
        return @intCast(@divTrunc(remaining, @as(i128, std.time.ns_per_s)));
    }

    pub fn takeScheduledBackupNotice(self: *ChunkStreamingManager) bool {
        const notice = self.scheduled_backup_notice;
        self.scheduled_backup_notice = false;
        return notice;
    }

    pub fn scheduledMaintenanceIntervalSeconds(self: *const ChunkStreamingManager) u32 {
        if (self.scheduled_backup_interval_ns <= 0) return 0;
        return @intCast(@divTrunc(self.scheduled_backup_interval_ns, @as(i128, std.time.ns_per_s)));
    }

    pub fn takeScheduledMaintenanceIntervalChange(self: *ChunkStreamingManager) ?u32 {
        if (!self.scheduled_backup_interval_notice) return null;
        self.scheduled_backup_interval_notice = false;
        return self.scheduled_backup_interval_notice_seconds;
    }

    /// Get number of loaded chunks
    pub fn getLoadedCount(self: *ChunkStreamingManager) u32 {
        return @intCast(self.chunks.count());
    }

    /// Get block at world position
    pub fn getBlockWorld(self: *ChunkStreamingManager, x: i32, z: i32, y: i32) ?terrain.Block {
        const chunk_pos = ChunkPos.fromWorldPos(x, z);
        const chunk = self.getChunk(chunk_pos) orelse return null;

        const local_x = @mod(x, terrain.Chunk.CHUNK_SIZE);
        const local_z = @mod(z, terrain.Chunk.CHUNK_SIZE);

        return chunk.getBlock(
            @intCast(local_x),
            @intCast(local_z),
            @intCast(y),
        );
    }

    /// Set block at world position
    pub fn setBlockWorld(self: *ChunkStreamingManager, x: i32, z: i32, y: i32, block: terrain.Block) bool {
        const chunk_pos = ChunkPos.fromWorldPos(x, z);
        const chunk = self.getChunk(chunk_pos) orelse return false;

        const local_x = @mod(x, terrain.Chunk.CHUNK_SIZE);
        const local_z = @mod(z, terrain.Chunk.CHUNK_SIZE);

        const result = chunk.setBlock(
            @intCast(local_x),
            @intCast(local_z),
            @intCast(y),
            block,
        );

        // Mark chunk as modified
        if (result) {
            const hash_val = chunk_pos.hash();
            self.chunk_states.put(hash_val, .generated) catch {};
        }

        return result;
    }

    pub fn beginSelection(self: *ChunkStreamingManager, x: i32, z: i32, y: i32) void {
        self.selection.begin(x, z, y);
    }

    pub fn updateSelection(self: *ChunkStreamingManager, x: i32, z: i32, y: i32) void {
        self.selection.update(x, z, y);
    }

    pub fn clearSelection(self: *ChunkStreamingManager) void {
        self.selection.clear();
    }

    pub fn selectionBounds(self: *const ChunkStreamingManager) ?SelectionBounds {
        return self.selection.bounds();
    }

    pub fn selectionActive(self: *const ChunkStreamingManager) bool {
        return self.selection.active;
    }

    pub fn copySelection(self: *ChunkStreamingManager) !SelectionBounds {
        const bounds = self.selection.bounds() orelse return error.NoSelection;
        const max_y: i32 = @intCast(terrain.Chunk.CHUNK_HEIGHT - 1);
        const min_y = std.math.clamp(bounds.min_y, 0, max_y);
        const max_clamped_y = std.math.clamp(bounds.max_y, 0, max_y);
        if (max_clamped_y < min_y) return error.EmptySelection;

        const stored_bounds = SelectionBounds{
            .min_x = bounds.min_x,
            .max_x = bounds.max_x,
            .min_z = bounds.min_z,
            .max_z = bounds.max_z,
            .min_y = min_y,
            .max_y = max_clamped_y,
        };

        const width = stored_bounds.width();
        const depth = stored_bounds.depth();
        const height = stored_bounds.height();
        const width_depth = try std.math.mul(usize, width, depth);
        const total_blocks = try std.math.mul(usize, width_depth, height);

        self.clipboard.clear();
        try self.clipboard.blocks.ensureTotalCapacityPrecise(self.allocator, total_blocks);

        var y_iter = stored_bounds.min_y;
        while (y_iter <= stored_bounds.max_y) : (y_iter += 1) {
            var z_iter = stored_bounds.min_z;
            while (z_iter <= stored_bounds.max_z) : (z_iter += 1) {
                var x_iter = stored_bounds.min_x;
                while (x_iter <= stored_bounds.max_x) : (x_iter += 1) {
                    const block = self.getBlockWorld(x_iter, z_iter, y_iter) orelse terrain.Block.init(.air);
                    try self.clipboard.blocks.append(self.allocator, block);
                }
            }
        }

        self.clipboard.width = width;
        self.clipboard.depth = depth;
        self.clipboard.height = height;

        return stored_bounds;
    }

    pub fn clipboardDimensions(self: *const ChunkStreamingManager) ?ClipboardDimensions {
        return self.clipboard.dimensions();
    }

    pub fn clipboardIsEmpty(self: *const ChunkStreamingManager) bool {
        return self.clipboard.isEmpty();
    }

    pub fn pasteClipboard(self: *ChunkStreamingManager, dest_x: i32, dest_z: i32, dest_y: i32) !void {
        if (self.clipboard.isEmpty()) return error.ClipboardEmpty;
        const dims = self.clipboard.dimensions() orelse return error.ClipboardEmpty;
        const max_y: i32 = @intCast(terrain.Chunk.CHUNK_HEIGHT);

        var idx: usize = 0;
        var y_iter: usize = 0;
        while (y_iter < dims.height) : (y_iter += 1) {
            var z_iter: usize = 0;
            while (z_iter < dims.depth) : (z_iter += 1) {
                var x_iter: usize = 0;
                while (x_iter < dims.width) : (x_iter += 1) {
                    const block = self.clipboard.blocks.items[idx];
                    idx += 1;

                    const world_x = dest_x + @as(i32, @intCast(x_iter));
                    const world_z = dest_z + @as(i32, @intCast(z_iter));
                    const world_y = dest_y + @as(i32, @intCast(y_iter));

                    if (world_y < 0 or world_y >= max_y) continue;

                    _ = self.setBlockWorld(world_x, world_z, world_y, block);
                }
            }
        }
    }
};

test "chunk position" {
    const pos1 = ChunkPos.init(0, 0);
    const pos2 = ChunkPos.init(1, 0);

    try std.testing.expectEqual(@as(f32, 1.0), pos1.distance(pos2));
}

test "chunk position from world" {
    const pos = ChunkPos.fromWorldPos(25, -10);

    try std.testing.expectEqual(@as(i32, 1), pos.x);
    try std.testing.expectEqual(@as(i32, -1), pos.z);
}

test "chunk streaming manager" {
    const allocator = std.testing.allocator;

    var manager = try ChunkStreamingManager.init(allocator, 12345, 4);
    defer manager.deinit();

    // Update around origin
    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));

    // Should have loaded some chunks
    try std.testing.expect(manager.getLoadedCount() > 0);
}

test "scheduled maintenance enqueues region backups after interval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var world = try persistence.WorldPersistence.init(allocator, "sched_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer world.deinit();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
    defer manager.deinit();
    manager.world_persistence = &world;
    manager.syncPersistenceSettings();
    manager.max_chunks_per_frame = 9;

    // Warm up enough chunks so maintenance has work to queue.
    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));

    manager.scheduled_backup_interval_ns = 1 * @as(i128, std.time.ns_per_s);
    manager.scheduled_backup_elapsed_ns = manager.scheduled_backup_interval_ns;
    manager.scheduled_backup_notice = false;
    manager.backup_queue_cooldown_ns = 5 * @as(i128, std.time.ns_per_s);
    manager.last_backup_enqueue_ns = 0;

    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));

    try std.testing.expect(manager.takeScheduledBackupNotice());
    try std.testing.expect(!manager.takeScheduledBackupNotice());
    const interval_change = manager.takeScheduledMaintenanceIntervalChange();
    try std.testing.expect(interval_change != null);

    const metrics = world.getMaintenanceMetrics();
    try std.testing.expect(metrics.queued_regions > 0);
    try std.testing.expect(metrics.schedule_interval_seconds == interval_change.?);
    try std.testing.expect(manager.backupCooldownSecondsRemaining() >= 0);
    try std.testing.expect(manager.scheduled_backup_elapsed_ns == 0);
    try std.testing.expect(manager.last_backup_queue_total > 0);
    try std.testing.expect(manager.last_backup_queue_added > 0);
    try std.testing.expect(manager.scheduledMaintenanceIntervalSeconds() == interval_change.?);
}

test "scheduled maintenance cadence adapts to activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var world = try persistence.WorldPersistence.init(allocator, "cadence_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer world.deinit();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
    defer manager.deinit();
    manager.world_persistence = &world;
    manager.syncPersistenceSettings();

    manager.adjustScheduledMaintenanceCadence(0, 32);
    const shorter_notice = manager.takeScheduledMaintenanceIntervalChange();
    try std.testing.expect(shorter_notice != null);
    const shorter_interval = manager.scheduledMaintenanceIntervalSeconds();
    try std.testing.expect(shorter_interval <= default_backup_schedule_interval_seconds);

    var iteration: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        manager.adjustScheduledMaintenanceCadence(0, 0);
        _ = manager.takeScheduledMaintenanceIntervalChange();
    }

    manager.adjustScheduledMaintenanceCadence(0, 0);
    const relaxed_notice = manager.takeScheduledMaintenanceIntervalChange();
    try std.testing.expect(relaxed_notice != null);
    const relaxed_interval = manager.scheduledMaintenanceIntervalSeconds();
    try std.testing.expect(relaxed_interval >= shorter_interval);

    const metrics = world.getMaintenanceMetrics();
    try std.testing.expect(metrics.schedule_interval_seconds == relaxed_interval);
    try std.testing.expect(metrics.recent_activity_score >= 0);
}

test "autosave queues maintenance and reports summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var world = try persistence.WorldPersistence.init(allocator, "autosave_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer world.deinit();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
    defer manager.deinit();
    manager.world_persistence = &world;
    manager.syncPersistenceSettings();
    manager.max_chunks_per_frame = 9;

    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));

    // Mark a loaded chunk as modified so autosave has work.
    var it = manager.chunks.iterator();
    const first_entry_opt = it.next();
    try std.testing.expect(first_entry_opt != null);
    const chunk_ptr = first_entry_opt.?.value_ptr.*;
    chunk_ptr.modified = true;

    const summary_opt = manager.forceAutosave();
    try std.testing.expect(summary_opt != null);
    const summary = summary_opt.?;
    try std.testing.expect(summary.saved_chunks > 0);
    try std.testing.expect(summary.maintenance_enqueued);
    try std.testing.expect(summary.queued_regions_total > 0);
    try std.testing.expect(summary.queued_regions_added > 0);

    // Autosave consumes modified flag; ensure maintenance notice is available once.
    try std.testing.expect(manager.takeScheduledBackupNotice());
    try std.testing.expect(!manager.takeScheduledBackupNotice());
    try std.testing.expect(manager.last_backup_queue_total >= summary.queued_regions_total);
    try std.testing.expect(manager.last_backup_queue_added >= summary.queued_regions_added);
}

test "autosave persists modified chunk data to disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    const world_name = "autosave_persist_test";
    var chunk_x: i32 = 0;
    var chunk_z: i32 = 0;
    const target_y: usize = 200;

    {
        var world = try persistence.WorldPersistence.init(allocator, world_name, .{
            .worlds_root = worlds_root,
            .force_new = true,
        });
        defer world.deinit();

        var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
        defer manager.deinit();
        manager.world_persistence = &world;
        manager.syncPersistenceSettings();
        manager.max_chunks_per_frame = 9;

        try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));

        var it = manager.chunks.iterator();
        const first_entry_opt = it.next();
        try std.testing.expect(first_entry_opt != null);
        const chunk_ptr = first_entry_opt.?.value_ptr.*;

        chunk_x = chunk_ptr.x;
        chunk_z = chunk_ptr.z;

        const original_type = chunk_ptr.blocks[0][0][target_y].block_type;
        try std.testing.expect(original_type != terrain.BlockType.sand);
        chunk_ptr.blocks[0][0][target_y] = terrain.Block.init(.sand);
        chunk_ptr.modified = true;

        const summary_opt = manager.forceAutosave();
        try std.testing.expect(summary_opt != null);
        const summary = summary_opt.?;
        try std.testing.expect(summary.saved_chunks >= 1);
        try std.testing.expectEqual(@as(u32, 0), summary.errors);
        try std.testing.expect(summary.maintenance_enqueued);
        try std.testing.expect(summary.queued_regions_total > 0);
        try std.testing.expect(summary.queued_regions_added > 0);
        try std.testing.expect(!chunk_ptr.modified);

        const metrics = world.getMaintenanceMetrics();
        try std.testing.expect(metrics.queued_regions >= summary.queued_regions_total);

        try std.testing.expect(world.queuedCompactions() > 0);
        world.serviceMaintenance(4);
        try std.testing.expectEqual(@as(usize, 0), world.queuedCompactions());
    }

    var reopened = try persistence.WorldPersistence.init(allocator, world_name, .{
        .worlds_root = worlds_root,
    });
    defer reopened.deinit();

    const reloaded_opt = try reopened.loadChunk(chunk_x, chunk_z);
    try std.testing.expect(reloaded_opt != null);
    const reloaded = reloaded_opt.?;
    try std.testing.expectEqual(terrain.BlockType.sand, reloaded.blocks[0][0][target_y].block_type);
}

test "timer-driven autosave surfaces summary once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var world = try persistence.WorldPersistence.init(allocator, "autosave_timer_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer world.deinit();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
    defer manager.deinit();
    manager.world_persistence = &world;
    manager.syncPersistenceSettings();
    manager.max_chunks_per_frame = 9;

    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));
    try std.testing.expect(manager.getLoadedCount() > 0);

    var it = manager.chunks.iterator();
    const first_entry_opt = it.next();
    try std.testing.expect(first_entry_opt != null);
    const chunk_ptr = first_entry_opt.?.value_ptr.*;
    chunk_ptr.blocks[0][0][0] = terrain.Block.init(.sand);
    chunk_ptr.modified = true;

    manager.setAutosaveIntervalSeconds(1);
    try std.testing.expectEqual(@as(u32, 1), manager.autosaveIntervalSeconds());
    try std.testing.expect(manager.autosave_interval_ns > 0);
    const now = std.time.nanoTimestamp();
    manager.last_autosave_ns = now - manager.autosave_interval_ns - 1;
    manager.last_autosave_summary = null;

    manager.autosaveIfDue();

    const summary_opt = manager.takeAutosaveSummary();
    try std.testing.expect(summary_opt != null);
    const summary = summary_opt.?;
    try std.testing.expect(summary.saved_chunks >= 1);
    try std.testing.expect(summary.errors == 0);
    try std.testing.expect(summary.maintenance_enqueued);
    try std.testing.expect(summary.queued_regions_total >= summary.queued_regions_added);
    try std.testing.expect(summary.reason == .timer);
    try std.testing.expect(summary.timestamp_ns >= manager.last_autosave_ns);

    try std.testing.expect(manager.takeAutosaveSummary() == null);
    try std.testing.expect(manager.last_autosave_summary == null);
    try std.testing.expect(manager.last_backup_queue_total > 0);
    try std.testing.expect(manager.last_backup_queue_added > 0);
    try std.testing.expect(manager.takeScheduledBackupNotice());
    try std.testing.expect(!manager.takeScheduledBackupNotice());
    try std.testing.expect(manager.backupCooldownSecondsRemaining() >= 0);

    try std.testing.expect(world.queuedCompactions() > 0);
    world.serviceMaintenance(4);
    try std.testing.expectEqual(@as(usize, 0), world.queuedCompactions());
}

test "maintenance cooldown suppresses duplicate queue notices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_root);

    const worlds_root = try std.fs.path.join(allocator, &.{ temp_root, "worlds" });
    defer allocator.free(worlds_root);
    try std.fs.cwd().makePath(worlds_root);

    var world = try persistence.WorldPersistence.init(allocator, "maintenance_cooldown_test", .{
        .worlds_root = worlds_root,
        .force_new = true,
    });
    defer world.deinit();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, world.seed(), 2, false);
    defer manager.deinit();
    manager.world_persistence = &world;
    manager.syncPersistenceSettings();

    manager.backup_queue_cooldown_ns = 5 * @as(i128, std.time.ns_per_s);
    manager.last_backup_enqueue_ns = 0;

    try manager.loadChunk(ChunkPos.init(0, 0));

    const first_run = manager.queueLoadedRegionBackups();
    try std.testing.expect(first_run);
    try std.testing.expect(manager.last_backup_queue_total > 0);
    try std.testing.expect(manager.last_backup_queue_added > 0);
    try std.testing.expect(manager.takeScheduledBackupNotice());
    const total_after_first = manager.last_backup_queue_total;

    const second_run = manager.queueLoadedRegionBackups();
    try std.testing.expect(!second_run);
    try std.testing.expectEqual(total_after_first, manager.last_backup_queue_total);
    try std.testing.expectEqual(@as(usize, 0), manager.last_backup_queue_added);
    try std.testing.expect(!manager.takeScheduledBackupNotice());
}

test "selection copy captures blocks and paste restores volume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, 0xdecaf, 2, false);
    defer manager.deinit();
    manager.max_chunks_per_frame = 9;

    try manager.update(math.Vec3.init(0, 70, 0), math.Vec3.init(0, 0, -1));
    try std.testing.expect(manager.getLoadedCount() > 0);

    const base_x: i32 = 0;
    const base_z: i32 = 0;
    const base_y: i32 = 62;
    const block_cycle = [_]terrain.BlockType{ .dirt, .stone, .grass, .sand };

    var write_index: usize = 0;
    var y = base_y;
    while (y <= base_y + 1) : (y += 1) {
        var z = base_z;
        while (z <= base_z + 1) : (z += 1) {
            var x = base_x;
            while (x <= base_x + 1) : (x += 1) {
                const block_type = block_cycle[write_index % block_cycle.len];
                write_index += 1;
                _ = manager.setBlockWorld(x, z, y, terrain.Block.init(block_type));
            }
        }
    }

    manager.beginSelection(base_x, base_z, base_y);
    manager.updateSelection(base_x + 1, base_z + 1, base_y + 1);

    const bounds = try manager.copySelection();
    try std.testing.expectEqual(@as(usize, 2), bounds.width());
    try std.testing.expectEqual(@as(usize, 2), bounds.depth());
    try std.testing.expectEqual(@as(usize, 2), bounds.height());

    const dims = manager.clipboardDimensions() orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), dims.width);
    try std.testing.expectEqual(@as(usize, 2), dims.depth);
    try std.testing.expectEqual(@as(usize, 2), dims.height);

    y = base_y;
    while (y <= base_y + 1) : (y += 1) {
        var z = base_z;
        while (z <= base_z + 1) : (z += 1) {
            var x = base_x;
            while (x <= base_x + 1) : (x += 1) {
                _ = manager.setBlockWorld(x, z, y, terrain.Block.init(.air));
            }
        }
    }

    const dest_x: i32 = 4;
    const dest_z: i32 = 4;
    const dest_y: i32 = 66;
    try manager.pasteClipboard(dest_x, dest_z, dest_y);

    write_index = 0;
    var y_offset: usize = 0;
    while (y_offset < dims.height) : (y_offset += 1) {
        var z_offset: usize = 0;
        while (z_offset < dims.depth) : (z_offset += 1) {
            var x_offset: usize = 0;
            while (x_offset < dims.width) : (x_offset += 1) {
                const expected_type = block_cycle[write_index % block_cycle.len];
                write_index += 1;
                const block = manager.getBlockWorld(
                    dest_x + @as(i32, @intCast(x_offset)),
                    dest_z + @as(i32, @intCast(z_offset)),
                    dest_y + @as(i32, @intCast(y_offset)),
                );
                try std.testing.expect(block != null);
                try std.testing.expectEqual(expected_type, block.?.block_type);
            }
        }
    }

    y_offset = 0;
    while (y_offset < dims.height) : (y_offset += 1) {
        var z_offset: usize = 0;
        while (z_offset < dims.depth) : (z_offset += 1) {
            var x_offset: usize = 0;
            while (x_offset < dims.width) : (x_offset += 1) {
                const original = manager.getBlockWorld(
                    base_x + @as(i32, @intCast(x_offset)),
                    base_z + @as(i32, @intCast(z_offset)),
                    base_y + @as(i32, @intCast(y_offset)),
                );
                try std.testing.expect(original != null);
                try std.testing.expectEqual(terrain.BlockType.air, original.?.block_type);
            }
        }
    }
}

test "copy selection and paste validate error paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var manager = try ChunkStreamingManager.initWithAsync(allocator, 1234, 2, false);
    defer manager.deinit();

    try std.testing.expectError(error.NoSelection, manager.copySelection());
    try std.testing.expectError(error.ClipboardEmpty, manager.pasteClipboard(0, 0, 0));

    manager.beginSelection(0, 0, 0);
    manager.clearSelection();
    try std.testing.expectError(error.NoSelection, manager.copySelection());
}
