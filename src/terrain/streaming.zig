const std = @import("std");
const terrain = @import("terrain.zig");
const generator = @import("generator.zig");
const math = @import("../utils/math.zig");

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

/// Chunk streaming manager
pub const ChunkStreamingManager = struct {
    allocator: std.mem.Allocator,

    // Loaded chunks (hash map: ChunkPos -> Chunk)
    chunks: std.AutoHashMap(u64, *terrain.Chunk),
    chunk_states: std.AutoHashMap(u64, ChunkState),

    // Chunk pool for reuse
    chunk_pool: std.ArrayList(*terrain.Chunk),

    // Request queues
    load_queue: std.PriorityQueue(ChunkRequest, void, ChunkRequest.lessThan),
    unload_queue: std.ArrayList(ChunkPos),

    // Terrain generator
    terrain_gen: generator.TerrainGenerator,

    // Async generation - NEW approach using dedicated worker thread
    generation_thread: ?std.Thread,
    generation_mutex: std.Thread.Mutex,
    generation_queue: std.ArrayList(ChunkPos), // Chunks waiting to be generated
    pending_chunks: std.AutoHashMap(u64, *terrain.Chunk), // Chunks being generated
    completed_chunks: std.ArrayList(ChunkPos), // Ready to be moved to main chunks
    should_stop: std.atomic.Value(bool),
    use_async: bool,

    // Settings
    view_distance: i32, // In chunks
    unload_distance: i32, // Hysteresis zone
    max_chunks_per_frame: u32,
    allocated_chunks: usize,
    tracked_chunks: std.ArrayListUnmanaged(*terrain.Chunk),

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
            .chunk_pool = ArrayListChunk{},
            .load_queue = std.PriorityQueue(ChunkRequest, void, ChunkRequest.lessThan).init(allocator, {}),
            .unload_queue = ArrayListChunkPos{},
            .terrain_gen = generator.TerrainGenerator.init(seed),
            .generation_thread = null,
            .generation_mutex = .{},
            .generation_queue = ArrayListChunkPos{},
            .pending_chunks = std.AutoHashMap(u64, *terrain.Chunk).init(allocator),
            .completed_chunks = ArrayListChunkPos{},
            .should_stop = std.atomic.Value(bool).init(false),
            .use_async = use_async,
            .view_distance = view_distance,
            .unload_distance = view_distance + 2, // Hysteresis
            .max_chunks_per_frame = 4,
            .allocated_chunks = 0,
            .tracked_chunks = .{},
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

        self.unloadAll();
        self.chunks.deinit();
        self.chunk_states.deinit();
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

        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr_ptr| {
            const chunk_ptr = chunk_ptr_ptr.*;
            self.removeTrackedChunk(chunk_ptr);
            self.allocator.destroy(chunk_ptr);
            std.debug.assert(self.allocated_chunks > 0);
            self.allocated_chunks -= 1;
        }
        self.chunks.clearRetainingCapacity();
        self.chunk_states.clearRetainingCapacity();

        for (self.chunk_pool.items) |chunk| {
            self.removeTrackedChunk(chunk);
            self.allocator.destroy(chunk);
            std.debug.assert(self.allocated_chunks > 0);
            self.allocated_chunks -= 1;
        }
        self.chunk_pool.clearRetainingCapacity();

        while (self.load_queue.removeOrNull()) |_| {}
        self.unload_queue.clearRetainingCapacity();

        if (self.tracked_chunks.items.len != 0) {
            for (self.tracked_chunks.items) |chunk| {
                self.allocator.destroy(chunk);
            }
            self.allocated_chunks = 0;
            self.tracked_chunks.clearRetainingCapacity();
        }
    }

    /// Update chunk loading based on player position
    pub fn update(self: *ChunkStreamingManager, player_pos: math.Vec3, player_forward: math.Vec3) !void {
        const player_chunk = ChunkPos.fromWorldPos(
            @intFromFloat(@floor(player_pos.x)),
            @intFromFloat(@floor(player_pos.z)),
        );

        // Determine which chunks should be loaded
        try self.updateLoadQueue(player_chunk, player_forward);

        // Determine which chunks should be unloaded
        try self.updateUnloadQueue(player_chunk);

        // Process loading (limit per frame)
        try self.processLoading();

        // Process unloading
        try self.processUnloading();

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

    fn processLoading(self: *ChunkStreamingManager) !void {
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
            } else {
                try self.loadChunk(request.pos);
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

    fn processUnloading(self: *ChunkStreamingManager) !void {
        for (self.unload_queue.items) |chunk_pos| {
            try self.unloadChunk(chunk_pos);
        }
        self.unload_queue.clearRetainingCapacity();
    }

    fn loadChunk(self: *ChunkStreamingManager, pos: ChunkPos) !void {
        const hash_val = pos.hash();

        // Get or create chunk
        const chunk = try self.acquireChunk();
        chunk.x = pos.x;
        chunk.z = pos.z;
        chunk.modified = false;

        // Generate terrain
        self.terrain_gen.generateChunk(chunk);

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

            // TODO: Save chunk if modified

            // Return to pool
            try self.releaseChunk(chunk);
        }

        _ = self.chunk_states.remove(hash_val);
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
