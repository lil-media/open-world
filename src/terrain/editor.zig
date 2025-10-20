const std = @import("std");
const terrain = @import("terrain.zig");

/// Tools available for terrain manipulation
pub const Tool = enum {
    dig, // Remove blocks
    place, // Place blocks
    flatten, // Flatten terrain
    raise, // Raise terrain
    lower, // Lower terrain
};

/// Terrain editing operations
pub const TerrainEditor = struct {
    world: *terrain.World,
    current_tool: Tool,
    current_block: terrain.BlockType,
    brush_size: u32,

    pub fn init(world: *terrain.World) TerrainEditor {
        return .{
            .world = world,
            .current_tool = .dig,
            .current_block = .dirt,
            .brush_size = 1,
        };
    }

    /// Dig/remove blocks at the specified location
    pub fn dig(self: *TerrainEditor, x: i32, z: i32, y: i32) void {
        self.applyBrush(x, z, y, terrain.Block.init(.air));
    }

    /// Place a block at the specified location
    pub fn place(self: *TerrainEditor, x: i32, z: i32, y: i32) void {
        self.applyBrush(x, z, y, terrain.Block.init(self.current_block));
    }

    /// Flatten terrain around a point to a specific height
    pub fn flatten(self: *TerrainEditor, center_x: i32, center_z: i32, target_y: i32) void {
        const radius = @as(i32, @intCast(self.brush_size));

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                const x = center_x + dx;
                const z = center_z + dz;

                // Check if within circular brush
                const dist_sq = dx * dx + dz * dz;
                if (dist_sq > radius * radius) continue;

                // Remove blocks above target height
                var y = target_y + 1;
                while (y < terrain.Chunk.CHUNK_HEIGHT) : (y += 1) {
                    _ = self.world.setBlockWorld(x, z, y, terrain.Block.init(.air));
                }

                // Fill blocks up to target height
                y = 0;
                while (y <= target_y) : (y += 1) {
                    if (self.world.getBlockWorld(x, z, y)) |block| {
                        if (block.block_type == .air) {
                            _ = self.world.setBlockWorld(x, z, y, terrain.Block.init(.dirt));
                        }
                    }
                }
            }
        }
    }

    /// Raise terrain at a location
    pub fn raise(self: *TerrainEditor, x: i32, z: i32, y: i32) void {
        const radius = @as(i32, @intCast(self.brush_size));

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                const px = x + dx;
                const pz = z + dz;

                const dist_sq = dx * dx + dz * dz;
                if (dist_sq > radius * radius) continue;

                // Add blocks upward
                var py = y;
                while (py < y + 2 and py < terrain.Chunk.CHUNK_HEIGHT) : (py += 1) {
                    if (self.world.getBlockWorld(px, pz, py)) |block| {
                        if (block.block_type == .air) {
                            _ = self.world.setBlockWorld(px, pz, py, terrain.Block.init(self.current_block));
                            break;
                        }
                    }
                }
            }
        }
    }

    /// Lower terrain at a location
    pub fn lower(self: *TerrainEditor, x: i32, z: i32, y: i32) void {
        const radius = @as(i32, @intCast(self.brush_size));

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                const px = x + dx;
                const pz = z + dz;

                const dist_sq = dx * dx + dz * dz;
                if (dist_sq > radius * radius) continue;

                // Remove top solid block
                var py = y;
                while (py >= 0) : (py -= 1) {
                    if (self.world.getBlockWorld(px, pz, py)) |block| {
                        if (block.isSolid()) {
                            _ = self.world.setBlockWorld(px, pz, py, terrain.Block.init(.air));
                            break;
                        }
                    }
                    if (py == 0) break;
                }
            }
        }
    }

    /// Apply the current tool at the specified location
    pub fn useTool(self: *TerrainEditor, x: i32, z: i32, y: i32) void {
        switch (self.current_tool) {
            .dig => self.dig(x, z, y),
            .place => self.place(x, z, y),
            .flatten => self.flatten(x, z, y),
            .raise => self.raise(x, z, y),
            .lower => self.lower(x, z, y),
        }
    }

    /// Apply a brush pattern at the specified location
    fn applyBrush(self: *TerrainEditor, center_x: i32, center_z: i32, center_y: i32, block: terrain.Block) void {
        const radius = @as(i32, @intCast(self.brush_size));

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                var dy: i32 = -radius;
                while (dy <= radius) : (dy += 1) {
                    const x = center_x + dx;
                    const z = center_z + dz;
                    const y = center_y + dy;

                    // Check if within spherical brush
                    const dist_sq = dx * dx + dz * dz + dy * dy;
                    if (dist_sq > radius * radius) continue;

                    _ = self.world.setBlockWorld(x, z, y, block);
                }
            }
        }
    }

    /// Set the active tool
    pub fn setTool(self: *TerrainEditor, tool: Tool) void {
        self.current_tool = tool;
    }

    /// Set the block type to place
    pub fn setBlockType(self: *TerrainEditor, block_type: terrain.BlockType) void {
        self.current_block = block_type;
    }

    /// Set the brush size
    pub fn setBrushSize(self: *TerrainEditor, size: u32) void {
        self.brush_size = std.math.clamp(size, 1, 10);
    }
};

test "terrain editor basic operations" {
    const allocator = std.testing.allocator;
    var world = try terrain.World.init(allocator, 256, 256);
    defer world.deinit();

    var editor = TerrainEditor.init(&world);

    // Test digging
    editor.dig(5, 5, 65);
    const block = world.getBlockWorld(5, 5, 65);
    try std.testing.expect(block != null);
    try std.testing.expectEqual(terrain.BlockType.air, block.?.block_type);

    // Test placing
    editor.setBlockType(.stone);
    editor.place(5, 5, 66);
    const placed_block = world.getBlockWorld(5, 5, 66);
    try std.testing.expect(placed_block != null);
    try std.testing.expectEqual(terrain.BlockType.stone, placed_block.?.block_type);
}
