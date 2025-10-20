const std = @import("std");
const streaming = @import("../terrain/streaming.zig");
const math = @import("math.zig");

/// Render a text-based map of loaded chunks around the player
pub fn renderChunkMap(
    manager: *streaming.ChunkStreamingManager,
    player_pos: math.Vec3,
    radius: i32,
) void {
    const player_chunk = streaming.ChunkPos.fromWorldPos(
        @intFromFloat(@floor(player_pos.x)),
        @intFromFloat(@floor(player_pos.z)),
    );

    std.debug.print("\n┌─ Chunk Map ({}x{}) ─┐\n", .{ radius * 2, radius * 2 });

    var dz: i32 = -radius;
    while (dz < radius) : (dz += 1) {
        std.debug.print("│", .{});

        var dx: i32 = -radius;
        while (dx < radius) : (dx += 1) {
            const pos = streaming.ChunkPos.init(
                player_chunk.x + dx,
                player_chunk.z + dz,
            );

            // Player position
            if (dx == 0 and dz == 0) {
                std.debug.print("\x1b[32m@\x1b[0m", .{}); // Green @ for player
            }
            // Loaded chunk
            else if (manager.getChunk(pos)) |_| {
                const dist = pos.distance(player_chunk);
                if (dist < 4) {
                    std.debug.print("\x1b[36m█\x1b[0m", .{}); // Cyan for close chunks
                } else if (dist < 6) {
                    std.debug.print("\x1b[34m█\x1b[0m", .{}); // Blue for medium chunks
                } else {
                    std.debug.print("\x1b[90m█\x1b[0m", .{}); // Gray for far chunks
                }
            }
            // Unloaded
            else {
                std.debug.print("·", .{});
            }
        }

        std.debug.print("│\n", .{});
    }

    std.debug.print("└", .{});
    var i: i32 = 0;
    while (i < radius * 2) : (i += 1) {
        std.debug.print("─", .{});
    }
    std.debug.print("┘\n", .{});

    std.debug.print("Legend: \x1b[32m@\x1b[0m=Player \x1b[36m█\x1b[0m=Near \x1b[34m█\x1b[0m=Mid \x1b[90m█\x1b[0m=Far ·=Unloaded\n\n", .{});
}

/// Display detailed statistics about loaded chunks
pub fn displayChunkStats(manager: *streaming.ChunkStreamingManager) void {
    std.debug.print("┌─ Chunk Statistics ─────────────────┐\n", .{});
    std.debug.print("│ Loaded chunks:      {d: >5}       │\n", .{manager.getLoadedCount()});
    std.debug.print("│ View distance:      {d: >5} chunks│\n", .{manager.view_distance});
    std.debug.print("│ Unload distance:    {d: >5} chunks│\n", .{manager.unload_distance});
    std.debug.print("│ Max per frame:      {d: >5}       │\n", .{manager.max_chunks_per_frame});
    std.debug.print("│ Pooled chunks:      {d: >5}       │\n", .{manager.chunk_pool.items.len});
    std.debug.print("│ Pending load:       {d: >5}       │\n", .{manager.load_queue.count()});
    std.debug.print("│ Pending unload:     {d: >5}       │\n", .{manager.unload_queue.items.len});
    std.debug.print("└────────────────────────────────────┘\n\n", .{});
}

/// Display player information
pub fn displayPlayerInfo(player_pos: math.Vec3, velocity: math.Vec3, on_ground: bool) void {
    std.debug.print("┌─ Player Info ──────────────────────┐\n", .{});
    std.debug.print("│ Position: ({d: >6.1}, {d: >6.1}, {d: >6.1}) │\n", .{
        player_pos.x,
        player_pos.y,
        player_pos.z,
    });
    std.debug.print("│ Velocity: ({d: >6.2}, {d: >6.2}, {d: >6.2}) │\n", .{
        velocity.x,
        velocity.y,
        velocity.z,
    });
    std.debug.print("│ On ground: {s: <21} │\n", .{if (on_ground) "Yes" else "No"});
    std.debug.print("└────────────────────────────────────┘\n\n", .{});
}

/// Draw a simple progress bar
pub fn drawProgressBar(label: []const u8, current: usize, total: usize, width: usize) void {
    const filled = (current * width) / total;
    const percent = (current * 100) / total;

    std.debug.print("{s: <15} [", .{label});

    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            std.debug.print("█", .{});
        } else {
            std.debug.print("░", .{});
        }
    }

    std.debug.print("] {d: >3}%\n", .{percent});
}

/// Display performance metrics
pub fn displayPerformanceMetrics(
    frame_time_ms: f32,
    update_time_ms: f32,
    chunks_loaded_this_frame: u32,
) void {
    const fps = 1000.0 / frame_time_ms;

    std.debug.print("┌─ Performance ──────────────────────┐\n", .{});
    std.debug.print("│ FPS:                {d: >6.1}       │\n", .{fps});
    std.debug.print("│ Frame time:         {d: >6.2} ms   │\n", .{frame_time_ms});
    std.debug.print("│ Update time:        {d: >6.2} ms   │\n", .{update_time_ms});
    std.debug.print("│ Chunks loaded:      {d: >6}       │\n", .{chunks_loaded_this_frame});
    std.debug.print("└────────────────────────────────────┘\n\n", .{});
}

/// Clear screen (terminal)
pub fn clearScreen() void {
    std.debug.print("\x1b[2J\x1b[H", .{});
}

/// Display a fancy header
pub fn displayHeader(title: []const u8) void {
    const width = 50;
    const padding = (width - title.len) / 2;

    std.debug.print("\n", .{});
    std.debug.print("╔", .{});
    var i: usize = 0;
    while (i < width) : (i += 1) {
        std.debug.print("═", .{});
    }
    std.debug.print("╗\n", .{});

    std.debug.print("║", .{});
    i = 0;
    while (i < padding) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("\x1b[1m{s}\x1b[0m", .{title});
    i = 0;
    while (i < width - title.len - padding) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("║\n", .{});

    std.debug.print("╚", .{});
    i = 0;
    while (i < width) : (i += 1) {
        std.debug.print("═", .{});
    }
    std.debug.print("╝\n", .{});
    std.debug.print("\n", .{});
}
