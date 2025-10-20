const std = @import("std");

/// Block types that can exist in the world
pub const BlockType = enum(u8) {
    air = 0,
    dirt = 1,
    grass = 2,
    stone = 3,
    water = 4,
    sand = 5,
};

/// A single block in the world
pub const Block = struct {
    block_type: BlockType,

    pub fn init(block_type: BlockType) Block {
        return .{ .block_type = block_type };
    }

    pub fn isSolid(self: Block) bool {
        return self.block_type != .air and self.block_type != .water;
    }
};

/// A chunk of terrain (16x16x256 blocks)
pub const Chunk = struct {
    const CHUNK_SIZE = 16;
    const CHUNK_HEIGHT = 256;

    blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_HEIGHT]Block,
    x: i32,
    z: i32,
    modified: bool,

    pub fn init(x: i32, z: i32) Chunk {
        var chunk = Chunk{
            .blocks = undefined,
            .x = x,
            .z = z,
            .modified = false,
        };

        // Initialize all blocks as air
        for (0..CHUNK_SIZE) |cx| {
            for (0..CHUNK_SIZE) |cz| {
                for (0..CHUNK_HEIGHT) |cy| {
                    chunk.blocks[cx][cz][cy] = Block.init(.air);
                }
            }
        }

        return chunk;
    }

    /// Generate terrain for this chunk using simple height-based generation
    pub fn generate(self: *Chunk) void {
        const x64 = @as(u64, @intCast(self.x));
        const z64 = @as(u64, @intCast(self.z));
        const seed = x64 *% 374761393 +% z64 *% 668265263;
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        for (0..CHUNK_SIZE) |cx| {
            for (0..CHUNK_SIZE) |cz| {
                // Simple height map generation (will be replaced with proper noise)
                const base_height = 64;
                const variation = random.intRangeAtMost(i32, -8, 8);
                const height = @as(usize, @intCast(base_height + variation));

                // Fill terrain
                for (0..CHUNK_HEIGHT) |cy| {
                    if (cy < height - 4) {
                        self.blocks[cx][cz][cy] = Block.init(.stone);
                    } else if (cy < height - 1) {
                        self.blocks[cx][cz][cy] = Block.init(.dirt);
                    } else if (cy < height) {
                        self.blocks[cx][cz][cy] = Block.init(.grass);
                    } else if (cy < 63) {
                        self.blocks[cx][cz][cy] = Block.init(.water);
                    }
                }
            }
        }

        self.modified = true;
    }

    /// Get a block at the given local coordinates
    pub fn getBlock(self: *const Chunk, x: usize, z: usize, y: usize) ?Block {
        if (x >= CHUNK_SIZE or z >= CHUNK_SIZE or y >= CHUNK_HEIGHT) {
            return null;
        }
        return self.blocks[x][z][y];
    }

    /// Set a block at the given local coordinates
    pub fn setBlock(self: *Chunk, x: usize, z: usize, y: usize, block: Block) bool {
        if (x >= CHUNK_SIZE or z >= CHUNK_SIZE or y >= CHUNK_HEIGHT) {
            return false;
        }
        self.blocks[x][z][y] = block;
        self.modified = true;
        return true;
    }
};

/// The game world containing all chunks
pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    width: usize,
    height: usize,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !World {
        var world = World{
            .allocator = allocator,
            .chunks = std.ArrayList(Chunk){},
            .width = width,
            .height = height,
        };

        // Generate initial chunks
        try world.generateChunks();

        return world;
    }

    pub fn deinit(self: *World) void {
        self.chunks.deinit(self.allocator);
    }

    fn generateChunks(self: *World) !void {
        const chunks_wide = 4; // Start with a 4x4 chunk area
        const chunks_deep = 4;

        for (0..chunks_wide) |cx| {
            for (0..chunks_deep) |cz| {
                var chunk = Chunk.init(@intCast(cx), @intCast(cz));
                chunk.generate();
                try self.chunks.append(self.allocator, chunk);
            }
        }

        std.debug.print("Generated {} chunks\n", .{self.chunks.items.len});
    }

    pub fn update(self: *World) !void {
        // Update world state (physics, entities, etc.)
        _ = self;
    }

    /// Get a chunk by its coordinates
    pub fn getChunk(self: *World, x: i32, z: i32) ?*Chunk {
        for (self.chunks.items) |*chunk| {
            if (chunk.x == x and chunk.z == z) {
                return chunk;
            }
        }
        return null;
    }

    /// Modify terrain at world coordinates
    pub fn setBlockWorld(self: *World, x: i32, z: i32, y: i32, block: Block) bool {
        if (y < 0 or y >= Chunk.CHUNK_HEIGHT) {
            return false;
        }

        const chunk_x = @divFloor(x, Chunk.CHUNK_SIZE);
        const chunk_z = @divFloor(z, Chunk.CHUNK_SIZE);
        const local_x = @mod(x, Chunk.CHUNK_SIZE);
        const local_z = @mod(z, Chunk.CHUNK_SIZE);

        if (self.getChunk(chunk_x, chunk_z)) |chunk| {
            return chunk.setBlock(@intCast(local_x), @intCast(local_z), @intCast(y), block);
        }

        return false;
    }

    /// Get a block at world coordinates
    pub fn getBlockWorld(self: *World, x: i32, z: i32, y: i32) ?Block {
        if (y < 0 or y >= Chunk.CHUNK_HEIGHT) {
            return null;
        }

        const chunk_x = @divFloor(x, Chunk.CHUNK_SIZE);
        const chunk_z = @divFloor(z, Chunk.CHUNK_SIZE);
        const local_x = @mod(x, Chunk.CHUNK_SIZE);
        const local_z = @mod(z, Chunk.CHUNK_SIZE);

        if (self.getChunk(chunk_x, chunk_z)) |chunk| {
            return chunk.getBlock(@intCast(local_x), @intCast(local_z), @intCast(y));
        }

        return null;
    }
};

test "block creation" {
    const block = Block.init(.stone);
    try std.testing.expectEqual(BlockType.stone, block.block_type);
    try std.testing.expect(block.isSolid());
}

test "chunk initialization" {
    var chunk = Chunk.init(0, 0);
    const block = chunk.getBlock(0, 0, 0).?;
    try std.testing.expectEqual(BlockType.air, block.block_type);
}

test "world creation" {
    const allocator = std.testing.allocator;
    var world = try World.init(allocator, 256, 256);
    defer world.deinit();

    try std.testing.expect(world.chunks.items.len > 0);
}
