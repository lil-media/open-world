const std = @import("std");
const terrain = @import("terrain/terrain.zig");
const generator = @import("terrain/generator.zig");
const streaming = @import("terrain/streaming.zig");
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

pub const DemoOptions = struct {
    max_frames: ?u32 = null,
};

const CachedMesh = struct {
    vertices: []metal_renderer.Vertex,
    indices: []u32,
    in_use: bool,
};

const MeshUpdateStats = struct {
    changed: bool,
    total_chunks: usize,
    rendered_chunks: usize,
    culled_chunks: usize,
    total_vertices: usize,
    total_indices: usize,
};

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
) !MeshUpdateStats {
    var stats = MeshUpdateStats{
        .changed = false,
        .total_chunks = chunk_manager.chunks.count(),
        .rendered_chunks = 0,
        .culled_chunks = 0,
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
    }

    var chunk_it = chunk_manager.chunks.iterator();
    while (chunk_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const chunk_ptr = entry.value_ptr.*;

        // Frustum culling to avoid rendering off-screen chunks
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

        stats.rendered_chunks += 1;

        var cache_entry_ptr_opt = mesh_cache.getPtr(key);
        if (cache_entry_ptr_opt == null) {
            try mesh_cache.put(key, .{
                .vertices = &[_]metal_renderer.Vertex{},
                .indices = &[_]u32{},
                .in_use = false,
            });
            cache_entry_ptr_opt = mesh_cache.getPtr(key);
            stats.changed = true;
        }

        const cache_entry_ptr = cache_entry_ptr_opt.?;
        var cache_entry = cache_entry_ptr.*;

        if (chunk_ptr.modified or cache_entry.vertices.len == 0) {
            // Skip mesh generation if we've hit the per-frame limit
            if (meshes_generated_this_frame >= max_meshes_per_frame) {
                // Keep the chunk in the iteration but don't mesh it this frame
                cache_entry.in_use = true;
                cache_entry_ptr.* = cache_entry;
                continue;
            }

            if (cache_entry.vertices.len > 0) allocator.free(cache_entry.vertices);
            if (cache_entry.indices.len > 0) allocator.free(cache_entry.indices);
            stats.changed = true;

            var chunk_mesh = try mesher.generateMesh(chunk_ptr);
            defer chunk_mesh.deinit();
            meshes_generated_this_frame += 1;

            const vertex_count = chunk_mesh.vertices.items.len;
            const index_count = chunk_mesh.indices.items.len;

            if (vertex_count == 0 or index_count == 0) {
                cache_entry.vertices = &[_]metal_renderer.Vertex{};
                cache_entry.indices = &[_]u32{};
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
            }

            chunk_ptr.modified = false;
        }

        cache_entry.in_use = true;
        cache_entry_ptr.* = cache_entry;

        if (cache_entry.vertices.len == 0 or cache_entry.indices.len == 0) continue;

        const base_vertex = @as(u32, @intCast(combined_vertices.items.len));
        try combined_vertices.appendSlice(allocator, cache_entry.vertices);
        try combined_indices.ensureTotalCapacity(allocator, combined_indices.items.len + cache_entry.indices.len);
        for (cache_entry.indices) |idx| {
            combined_indices.appendAssumeCapacity(base_vertex + idx);
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

    var window = try sdl.SDLWindow.init(1280, 720, "Open World - Interactive Demo");
    defer window.deinit();

    var metal_ctx = try metal.MetalContext.init(window.metal_view);
    defer metal_ctx.deinit();
    std.debug.print("✓ Metal device: {s}\n", .{metal_ctx.getDeviceName()});

    var input_state = input.InputState{};
    var render_mode = metal.RenderMode.normal;

    const world_seed: u64 = 42;
    const view_distance: i32 = 8;
    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, world_seed, view_distance);
    defer chunk_manager.deinit();

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

    std.debug.print("Controls:\n", .{});
    std.debug.print("  Movement: WASD, Space/Ctrl (fly up/down), Shift (sprint), F (toggle fly)\n", .{});
    std.debug.print("  Blocks: Left Click (break), Right Click (place)\n", .{});
    std.debug.print("  Debug: F4 (toggle wireframe)\n", .{});
    std.debug.print("  ESC (unlock cursor), ESC again (quit)\n", .{});

    try chunk_manager.update(player_physics.position, main_camera.front);

    var mesher = mesh.GreedyMesher.init(allocator);

    const shader_source = try std.fs.cwd().readFileAlloc(allocator, "shaders/chunk.metal", 1024 * 1024);
    defer allocator.free(shader_source);

    const vertex_entry: []const u8 = "vertex_main";
    const fragment_entry: []const u8 = "fragment_main";
    try metal_ctx.createPipeline(shader_source, vertex_entry, fragment_entry, @sizeOf(metal_renderer.Vertex));
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

        player_physics.setSprinting(input_state.isKeyDown(.shift_left));
        player_physics.setSneaking(false);

        const current_time = std.time.nanoTimestamp();
        const delta_ns = current_time - last_time;
        last_time = current_time;

        const delta_seconds = @as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0;
        accumulator += delta_seconds;
        fps_timer += delta_seconds;

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

            accumulator -= fixed_dt_seconds;
        }

        // Create frustum for culling
        const view = main_camera.getViewMatrix();
        const projection = main_camera.getProjectionMatrix();
        const view_proj = projection.multiply(view);
        const frustum = math.Frustum.fromMatrix(view_proj);

        const mesh_stats = try updateGpuMeshes(allocator, &chunk_manager, &mesh_cache, &mesher, &combined_vertices, &combined_indices, frustum);

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

        const has_mesh = combined_vertices.items.len > 0;
        if (mesh_stats.changed and has_mesh) {
            try metal_ctx.setMesh(
                std.mem.sliceAsBytes(combined_vertices.items),
                @sizeOf(metal_renderer.Vertex),
                combined_indices.items,
            );
        }

        const camera_pos = main_camera.getPosition();
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

            // Set up line mesh for block selection outline if a block is selected
            if (selected_block) |sel| {
                const outline_vertices = try generateCubeOutlineVertices(allocator, sel.block_pos, 0.01);
                defer allocator.free(outline_vertices);
                try metal_ctx.setLineMesh(
                    std.mem.sliceAsBytes(outline_vertices),
                    @sizeOf(metal_renderer.Vertex),
                );
            } else {
                // Clear line mesh
                try metal_ctx.setLineMesh(&[_]u8{}, @sizeOf(metal_renderer.Vertex));
            }

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
                "FPS ~{d: >3} | Pos ({d:.1}, {d:.1}, {d:.1}) | Chunks {d}/{d} ({d} culled) | Verts {d} Tris {d}\n",
                .{
                    fps_counter,
                    player_physics.position.x,
                    player_physics.position.y,
                    player_physics.position.z,
                    mesh_stats.rendered_chunks,
                    mesh_stats.total_chunks,
                    mesh_stats.culled_chunks,
                    mesh_stats.total_vertices,
                    mesh_stats.total_indices / 3,
                },
            );
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
