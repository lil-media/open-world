const std = @import("std");
const terrain = @import("terrain/terrain.zig");
const generator = @import("terrain/generator.zig");
const streaming = @import("terrain/streaming.zig");
const camera = @import("rendering/camera.zig");
const mesh = @import("rendering/mesh.zig");
const player = @import("physics/player.zig");
const math = @import("utils/math.zig");
const viz = @import("utils/visualization.zig");

/// Enhanced interactive demo
pub fn runInteractiveDemo(allocator: std.mem.Allocator) !void {
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
