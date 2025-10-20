const std = @import("std");
const terrain = @import("terrain.zig");
const noise = @import("../utils/noise.zig");
const math = @import("../utils/math.zig");

/// Biome types for different terrain regions
pub const BiomeType = enum {
    ocean,
    beach,
    plains,
    forest,
    desert,
    mountains,
    tundra,
    savanna,

    pub fn fromTemperatureAndMoisture(temperature: f32, moisture: f32) BiomeType {
        // Temperature: -1 (cold) to 1 (hot)
        // Moisture: -1 (dry) to 1 (wet)

        if (temperature < -0.3) {
            return .tundra;
        } else if (temperature > 0.5 and moisture < -0.2) {
            return .desert;
        } else if (temperature > 0.3 and moisture < 0.0) {
            return .savanna;
        } else if (moisture > 0.3) {
            return .forest;
        } else {
            return .plains;
        }
    }
};

/// Biome configuration
pub const Biome = struct {
    type: BiomeType,
    base_height: f32,
    height_variation: f32,
    temperature: f32,
    moisture: f32,

    pub fn init(biome_type: BiomeType, temp: f32, moist: f32) Biome {
        return switch (biome_type) {
            .ocean => .{
                .type = biome_type,
                .base_height = 50,
                .height_variation = 10,
                .temperature = temp,
                .moisture = moist,
            },
            .beach => .{
                .type = biome_type,
                .base_height = 64,
                .height_variation = 3,
                .temperature = temp,
                .moisture = moist,
            },
            .plains => .{
                .type = biome_type,
                .base_height = 68,
                .height_variation = 8,
                .temperature = temp,
                .moisture = moist,
            },
            .forest => .{
                .type = biome_type,
                .base_height = 70,
                .height_variation = 12,
                .temperature = temp,
                .moisture = moist,
            },
            .desert => .{
                .type = biome_type,
                .base_height = 65,
                .height_variation = 15,
                .temperature = temp,
                .moisture = moist,
            },
            .mountains => .{
                .type = biome_type,
                .base_height = 80,
                .height_variation = 60,
                .temperature = temp,
                .moisture = moist,
            },
            .tundra => .{
                .type = biome_type,
                .base_height = 66,
                .height_variation = 6,
                .temperature = temp,
                .moisture = moist,
            },
            .savanna => .{
                .type = biome_type,
                .base_height = 67,
                .height_variation = 10,
                .temperature = temp,
                .moisture = moist,
            },
        };
    }
};

/// Advanced terrain generator with biomes and 3D features
pub const TerrainGenerator = struct {
    seed: u64,

    // Noise generators
    continent_noise: noise.FBM, // Large-scale landmasses
    erosion_noise: noise.FBM, // Erosion and detail
    temperature_noise: noise.FBM, // Temperature map
    moisture_noise: noise.FBM, // Moisture map
    cave_noise: noise.SimplexNoise, // 3D cave systems
    detail_noise: noise.SimplexNoise, // Fine detail

    // Terrain parameters
    sea_level: i32,
    cave_threshold: f32,

    pub fn init(seed: u64) TerrainGenerator {
        return .{
            .seed = seed,
            .continent_noise = noise.FBM.init(seed, 5, 2.0, 0.5),
            .erosion_noise = noise.FBM.init(seed +% 1000, 4, 2.5, 0.6),
            .temperature_noise = noise.FBM.init(seed +% 2000, 3, 2.0, 0.5),
            .moisture_noise = noise.FBM.init(seed +% 3000, 3, 2.0, 0.5),
            .cave_noise = noise.SimplexNoise.init(seed +% 4000),
            .detail_noise = noise.SimplexNoise.init(seed +% 5000),
            .sea_level = 62,
            .cave_threshold = 0.6,
        };
    }

    /// Get the biome at a given 2D world position
    pub fn getBiomeAt(self: *const TerrainGenerator, world_x: i32, world_z: i32) Biome {
        const x: f32 = @floatFromInt(world_x);
        const z: f32 = @floatFromInt(world_z);

        // Sample temperature and moisture
        const temp = self.temperature_noise.sample2D(x * 0.0008, z * 0.0008);
        const moist = self.moisture_noise.sample2D(x * 0.0008 + 1000, z * 0.0008 + 1000);

        // Determine biome type
        const biome_type = BiomeType.fromTemperatureAndMoisture(temp, moist);

        return Biome.init(biome_type, temp, moist);
    }

    /// Get terrain height at a 2D position (for heightmap-based generation)
    pub fn getHeightAt(self: *const TerrainGenerator, world_x: i32, world_z: i32) i32 {
        const x: f32 = @floatFromInt(world_x);
        const z: f32 = @floatFromInt(world_z);

        // Get biome
        const biome = self.getBiomeAt(world_x, world_z);

        // Continental noise for large features
        const continent = self.continent_noise.sample2D(x * 0.0005, z * 0.0005);

        // Erosion for detail
        const erosion = self.erosion_noise.sample2D(x * 0.002, z * 0.002);

        // Fine detail
        const detail = self.detail_noise.sample2D(x * 0.01, z * 0.01) * 2.0;

        // Combine noise layers
        var height = biome.base_height;
        height += continent * biome.height_variation * 0.8;
        height += erosion * biome.height_variation * 0.3;
        height += detail;

        // Mountains get extra height boost
        if (biome.type == .mountains) {
            const mountain_boost = @max(0, continent) * 40.0;
            height += mountain_boost;
        }

        return @intFromFloat(height);
    }

    /// Get 3D density at a position (for caves and overhangs)
    /// Returns true if the position should be solid
    pub fn getDensityAt(self: *const TerrainGenerator, world_x: i32, world_y: i32, world_z: i32) bool {
        const x: f32 = @floatFromInt(world_x);
        const y: f32 = @floatFromInt(world_y);
        const z: f32 = @floatFromInt(world_z);

        // Get surface height
        const surface_height = self.getHeightAt(world_x, world_z);

        // Below surface check
        if (world_y > surface_height) {
            return false; // Air above surface
        }

        // Cave carving (only below y=55)
        if (world_y < 55) {
            const cave_value = self.cave_noise.sample3D(x * 0.02, y * 0.02, z * 0.02);

            // Gradient to reduce caves near surface
            const surface_distance = @as(f32, @floatFromInt(surface_height - world_y));
            const cave_chance = math.clamp(surface_distance / 10.0, 0.0, 1.0);

            if (cave_value > self.cave_threshold * (1.0 + cave_chance * 0.5)) {
                return false; // Cave
            }
        }

        return true; // Solid
    }

    /// Get the appropriate block type for a position
    pub fn getBlockAt(self: *const TerrainGenerator, world_x: i32, world_y: i32, world_z: i32) terrain.BlockType {
        const height = self.getHeightAt(world_x, world_z);
        const biome = self.getBiomeAt(world_x, world_z);

        // Water level
        if (world_y < self.sea_level and world_y >= height) {
            return .water;
        }

        // Air above terrain
        if (world_y > height) {
            return .air;
        }

        // Surface block based on biome
        if (world_y == height) {
            return switch (biome.type) {
                .ocean, .beach => .sand,
                .desert => .sand,
                .tundra => .stone, // Snow would go here
                .mountains => if (world_y > 100) .stone else .grass,
                else => .grass,
            };
        }

        // Subsurface layers
        const depth = height - world_y;

        if (depth <= 3) {
            // Dirt layer
            return .dirt;
        } else {
            // Stone
            return .stone;
        }
    }

    /// Generate a full chunk
    pub fn generateChunk(self: *const TerrainGenerator, chunk: *terrain.Chunk) void {
        const chunk_world_x = chunk.x * terrain.Chunk.CHUNK_SIZE;
        const chunk_world_z = chunk.z * terrain.Chunk.CHUNK_SIZE;

        for (0..terrain.Chunk.CHUNK_SIZE) |cx| {
            for (0..terrain.Chunk.CHUNK_SIZE) |cz| {
                const world_x = chunk_world_x + @as(i32, @intCast(cx));
                const world_z = chunk_world_z + @as(i32, @intCast(cz));

                for (0..terrain.Chunk.CHUNK_HEIGHT) |cy| {
                    const world_y: i32 = @intCast(cy);

                    // Use density function for more interesting terrain
                    const is_solid = self.getDensityAt(world_x, world_y, world_z);

                    if (is_solid) {
                        const block_type = self.getBlockAt(world_x, world_y, world_z);
                        chunk.blocks[cx][cz][cy] = terrain.Block.init(block_type);
                    } else {
                        // Check if underwater
                        if (world_y < self.sea_level) {
                            chunk.blocks[cx][cz][cy] = terrain.Block.init(.water);
                        } else {
                            chunk.blocks[cx][cz][cy] = terrain.Block.init(.air);
                        }
                    }
                }
            }
        }

        chunk.modified = true;
    }
};

test "terrain generator initialization" {
    const gen = TerrainGenerator.init(12345);
    _ = gen;
}

test "biome generation" {
    const gen = TerrainGenerator.init(12345);
    const biome = gen.getBiomeAt(0, 0);
    _ = biome;
}

test "height generation" {
    const gen = TerrainGenerator.init(12345);
    const height = gen.getHeightAt(0, 0);
    try std.testing.expect(height >= 0 and height < 256);
}
