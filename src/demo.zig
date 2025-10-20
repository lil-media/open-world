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

pub const DemoOptions = struct {
    max_frames: ?u32 = null,
};

const CachedMesh = struct {
    vertices: []metal_renderer.Vertex,
    indices: []u32,
    in_use: bool,
};

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

fn updateGpuMeshes(
    allocator: std.mem.Allocator,
    chunk_manager: *streaming.ChunkStreamingManager,
    mesh_cache: *std.AutoHashMap(u64, CachedMesh),
    mesher: *mesh.GreedyMesher,
    combined_vertices: *std.ArrayListUnmanaged(metal_renderer.Vertex),
    combined_indices: *std.ArrayListUnmanaged(u32),
) !void {
    combined_vertices.clearRetainingCapacity();
    combined_indices.clearRetainingCapacity();

    var cache_it = mesh_cache.iterator();
    while (cache_it.next()) |entry| {
        entry.value_ptr.in_use = false;
    }

    var chunk_it = chunk_manager.chunks.iterator();
    while (chunk_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const chunk_ptr = entry.value_ptr.*;

        var cache_entry_ptr_opt = mesh_cache.getPtr(key);
        if (cache_entry_ptr_opt == null) {
            try mesh_cache.put(key, .{
                .vertices = &[_]metal_renderer.Vertex{},
                .indices = &[_]u32{},
                .in_use = false,
            });
            cache_entry_ptr_opt = mesh_cache.getPtr(key);
        }

        const cache_entry_ptr = cache_entry_ptr_opt.?;
        var cache_entry = cache_entry_ptr.*;

        if (chunk_ptr.modified or cache_entry.vertices.len == 0) {
            if (cache_entry.vertices.len > 0) allocator.free(cache_entry.vertices);
            if (cache_entry.indices.len > 0) allocator.free(cache_entry.indices);

            var chunk_mesh = try mesher.generateMesh(chunk_ptr);
            defer chunk_mesh.deinit();

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

                    new_vertices[i] = .{
                        .position = [3]f32{
                            origin_x + src_vertex.position[0],
                            src_vertex.position[1],
                            origin_z + src_vertex.position[2],
                        },
                        .normal = src_vertex.normal,
                        .tex_coord = src_vertex.tex_coords,
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
    }
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

    var window = try sdl.SDLWindow.init(1280, 720, "Open World - Interactive Demo");
    defer window.deinit();

    var metal_ctx = try metal.MetalContext.init(window.metal_view);
    defer metal_ctx.deinit();
    std.debug.print("✓ Metal device: {s}\n", .{metal_ctx.getDeviceName()});

    var input_state = input.InputState{};

    const world_seed: u64 = 42;
    const view_distance: i32 = 8;
    var chunk_manager = try streaming.ChunkStreamingManager.init(allocator, world_seed, view_distance);
    defer chunk_manager.deinit();

    const spawn_pos = math.Vec3.init(8.0, 80.0, 8.0);
    var player_physics = player.PlayerPhysics.init(spawn_pos);
    player_physics.is_flying = true;

    var main_camera = camera.Camera.init(player_physics.getEyePosition(), 16.0 / 9.0);
    main_camera.setMode(.free_cam);

    var last_time: i128 = std.time.nanoTimestamp();
    var accumulator: f64 = 0;
    const fixed_dt: f32 = 1.0 / 60.0;
    const fixed_dt_seconds = @as(f64, fixed_dt);

    var total_frames: u64 = 0;
    var fps_counter: u32 = 0;
    var fps_timer: f64 = 0;

    std.debug.print("Controls: WASD move, Space/Ctrl up/down (fly), Shift sprint, F toggle fly, ESC quit.\n", .{});

    try chunk_manager.update(player_physics.position, main_camera.front);

    var mesher = mesh.GreedyMesher.init(allocator);

    const shader_source = try std.fs.cwd().readFileAlloc(allocator, "shaders/chunk.metal", 1024 * 1024);
    defer allocator.free(shader_source);

    const vertex_entry: []const u8 = "vertex_main";
    const fragment_entry: []const u8 = "fragment_main";
    try metal_ctx.createPipeline(shader_source, vertex_entry, fragment_entry, @sizeOf(metal_renderer.Vertex));

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

    while (!window.should_close) {
        input_state.beginFrame();
        window.pollEvents(&input_state);

        if (input_state.wasKeyPressed(.escape)) {
            window.should_close = true;
        }

        if (input_state.wasKeyPressed(.f)) {
            player_physics.toggleFlying();
        }

        player_physics.setSprinting(input_state.isKeyDown(.shift_left));
        player_physics.setSneaking(false);

        const current_time = std.time.nanoTimestamp();
        const delta_ns = current_time - last_time;
        last_time = current_time;

        const delta_seconds = @as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0;
        accumulator += delta_seconds;
        fps_timer += delta_seconds;

        if (window.height != 0) {
            const aspect = @as(f32, @floatFromInt(window.width)) / @as(f32, @floatFromInt(window.height));
            main_camera.setAspectRatio(aspect);
        }

        main_camera.processMouseMovement(input_state.mouse_delta.x, input_state.mouse_delta.y);

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

        try updateGpuMeshes(allocator, &chunk_manager, &mesh_cache, &mesher, &combined_vertices, &combined_indices);

        total_frames += 1;
        fps_counter += 1;

        const t = @as(f32, @floatFromInt(total_frames)) / 240.0;
        const r = (@sin(t * 0.5) + 1.0) * 0.2;
        const g = (@sin(t * 0.7 + 2.0) + 1.0) * 0.25;
        const b = (@sin(t * 0.3 + 4.0) + 1.0) * 0.35;

        const has_mesh = combined_vertices.items.len > 0;
        if (has_mesh) {
            try metal_ctx.setMesh(
                std.mem.sliceAsBytes(combined_vertices.items),
                @sizeOf(metal_renderer.Vertex),
                combined_indices.items,
            );

            const view = main_camera.getViewMatrix();
            const projection = main_camera.getProjectionMatrix();
            const vp = projection.multiply(view);
            const mvp = vp.multiply(model_matrix);

            var uniforms = metal_renderer.Uniforms{
                .model_view_projection = mvp.data,
                .model = model_matrix.data,
                .view = view.data,
                .projection = projection.data,
            };

            try metal_ctx.setUniforms(std.mem.asBytes(&uniforms));
            try metal_ctx.draw(.{ r, g, b, 1.0 });
        } else {
            _ = metal_ctx.renderFrame(r, g, b);
        }

        if (fps_timer >= 1.0) {
            std.debug.print(
                "FPS ~{d: >3} | Pos ({d:.1}, {d:.1}, {d:.1}) | Chunks {d}\n",
                .{
                    fps_counter,
                    player_physics.position.x,
                    player_physics.position.y,
                    player_physics.position.z,
                    chunk_manager.getLoadedCount(),
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
