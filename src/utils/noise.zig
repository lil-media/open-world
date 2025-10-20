const std = @import("std");
const math = @import("math.zig");

/// 3D Simplex Noise implementation
/// Faster than Perlin noise with fewer directional artifacts
/// Optimized for Apple Silicon SIMD operations
pub const SimplexNoise = struct {
    perm: [512]u8,
    perm_mod12: [512]u8,

    // Simplex noise constants
    const F3: f32 = 1.0 / 3.0;
    const G3: f32 = 1.0 / 6.0;

    // Gradient vectors for 3D
    const grad3 = [_][3]i8{
        [_]i8{ 1, 1, 0 },  [_]i8{ -1, 1, 0 },  [_]i8{ 1, -1, 0 },  [_]i8{ -1, -1, 0 },
        [_]i8{ 1, 0, 1 },  [_]i8{ -1, 0, 1 },  [_]i8{ 1, 0, -1 },  [_]i8{ -1, 0, -1 },
        [_]i8{ 0, 1, 1 },  [_]i8{ 0, -1, 1 },  [_]i8{ 0, 1, -1 },  [_]i8{ 0, -1, -1 },
    };

    pub fn init(seed: u64) SimplexNoise {
        var noise = SimplexNoise{
            .perm = undefined,
            .perm_mod12 = undefined,
        };

        // Initialize permutation table
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        // Create base permutation
        var p: [256]u8 = undefined;
        for (0..256) |i| {
            p[i] = @intCast(i);
        }

        // Fisher-Yates shuffle
        var i: usize = 255;
        while (i > 0) : (i -= 1) {
            const j = random.uintLessThan(usize, i + 1);
            const temp = p[i];
            p[i] = p[j];
            p[j] = temp;
        }

        // Duplicate for overflow handling
        for (0..256) |idx| {
            noise.perm[idx] = p[idx];
            noise.perm[idx + 256] = p[idx];
            noise.perm_mod12[idx] = @mod(p[idx], 12);
            noise.perm_mod12[idx + 256] = @mod(p[idx], 12);
        }

        return noise;
    }

    fn fastFloor(x: f32) i32 {
        const xi: i32 = @intFromFloat(x);
        return if (x < @as(f32, @floatFromInt(xi))) xi - 1 else xi;
    }

    fn dot3(g: [3]i8, x: f32, y: f32, z: f32) f32 {
        return @as(f32, @floatFromInt(g[0])) * x +
               @as(f32, @floatFromInt(g[1])) * y +
               @as(f32, @floatFromInt(g[2])) * z;
    }

    /// Generate 3D simplex noise at the given coordinates
    /// Returns a value in the range [-1, 1]
    pub fn sample3D(self: *const SimplexNoise, x: f32, y: f32, z: f32) f32 {
        // Skew the input space to determine which simplex cell we're in
        const s = (x + y + z) * F3;
        const i = fastFloor(x + s);
        const j = fastFloor(y + s);
        const k = fastFloor(z + s);

        const t = @as(f32, @floatFromInt(i + j + k)) * G3;
        const X0 = @as(f32, @floatFromInt(i)) - t;
        const Y0 = @as(f32, @floatFromInt(j)) - t;
        const Z0 = @as(f32, @floatFromInt(k)) - t;

        const x0 = x - X0;
        const y0 = y - Y0;
        const z0 = z - Z0;

        // Determine which simplex we are in
        var offset1_i: i32 = 0;
        var offset1_j: i32 = 0;
        var offset1_k: i32 = 0;
        var offset2_i: i32 = 0;
        var offset2_j: i32 = 0;
        var offset2_k: i32 = 0;

        if (x0 >= y0) {
            if (y0 >= z0) {
                offset1_i = 1;
                offset1_j = 0;
                offset1_k = 0;
                offset2_i = 1;
                offset2_j = 1;
                offset2_k = 0;
            } else if (x0 >= z0) {
                offset1_i = 1;
                offset1_j = 0;
                offset1_k = 0;
                offset2_i = 1;
                offset2_j = 0;
                offset2_k = 1;
            } else {
                offset1_i = 0;
                offset1_j = 0;
                offset1_k = 1;
                offset2_i = 1;
                offset2_j = 0;
                offset2_k = 1;
            }
        } else {
            if (y0 < z0) {
                offset1_i = 0;
                offset1_j = 0;
                offset1_k = 1;
                offset2_i = 0;
                offset2_j = 1;
                offset2_k = 1;
            } else if (x0 < z0) {
                offset1_i = 0;
                offset1_j = 1;
                offset1_k = 0;
                offset2_i = 0;
                offset2_j = 1;
                offset2_k = 1;
            } else {
                offset1_i = 0;
                offset1_j = 1;
                offset1_k = 0;
                offset2_i = 1;
                offset2_j = 1;
                offset2_k = 0;
            }
        }

        const x1 = x0 - @as(f32, @floatFromInt(offset1_i)) + G3;
        const y1 = y0 - @as(f32, @floatFromInt(offset1_j)) + G3;
        const z1 = z0 - @as(f32, @floatFromInt(offset1_k)) + G3;
        const x2 = x0 - @as(f32, @floatFromInt(offset2_i)) + 2.0 * G3;
        const y2 = y0 - @as(f32, @floatFromInt(offset2_j)) + 2.0 * G3;
        const z2 = z0 - @as(f32, @floatFromInt(offset2_k)) + 2.0 * G3;
        const x3 = x0 - 1.0 + 3.0 * G3;
        const y3 = y0 - 1.0 + 3.0 * G3;
        const z3 = z0 - 1.0 + 3.0 * G3;

        // Work out the hashed gradient indices
        const ii = @as(usize, @intCast(@mod(i, 256)));
        const jj = @as(usize, @intCast(@mod(j, 256)));
        const kk = @as(usize, @intCast(@mod(k, 256)));

        const gi0 = self.perm_mod12[ii + self.perm[jj + self.perm[kk]]];
        const gi1 = self.perm_mod12[ii + @as(usize, @intCast(offset1_i)) + self.perm[jj + @as(usize, @intCast(offset1_j)) + self.perm[kk + @as(usize, @intCast(offset1_k))]]];
        const gi2 = self.perm_mod12[ii + @as(usize, @intCast(offset2_i)) + self.perm[jj + @as(usize, @intCast(offset2_j)) + self.perm[kk + @as(usize, @intCast(offset2_k))]]];
        const gi3 = self.perm_mod12[ii + 1 + self.perm[jj + 1 + self.perm[kk + 1]]];

        // Calculate the contribution from the four corners
        var n0: f32 = 0.0;
        var t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
        if (t0 > 0) {
            t0 *= t0;
            n0 = t0 * t0 * dot3(grad3[gi0], x0, y0, z0);
        }

        var n1: f32 = 0.0;
        var t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
        if (t1 > 0) {
            t1 *= t1;
            n1 = t1 * t1 * dot3(grad3[gi1], x1, y1, z1);
        }

        var n2: f32 = 0.0;
        var t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
        if (t2 > 0) {
            t2 *= t2;
            n2 = t2 * t2 * dot3(grad3[gi2], x2, y2, z2);
        }

        var n3: f32 = 0.0;
        var t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
        if (t3 > 0) {
            t3 *= t3;
            n3 = t3 * t3 * dot3(grad3[gi3], x3, y3, z3);
        }

        // Add contributions from each corner and scale to [-1, 1]
        return 32.0 * (n0 + n1 + n2 + n3);
    }

    /// Generate 2D simplex noise (useful for heightmaps)
    pub fn sample2D(self: *const SimplexNoise, x: f32, y: f32) f32 {
        return self.sample3D(x, y, 0.0);
    }
};

/// Fractional Brownian Motion - layered noise for realistic terrain
pub const FBM = struct {
    noise: SimplexNoise,
    octaves: u32,
    lacunarity: f32, // Frequency multiplier per octave (typically 2.0)
    persistence: f32, // Amplitude multiplier per octave (typically 0.5)

    pub fn init(seed: u64, octaves: u32, lacunarity: f32, persistence: f32) FBM {
        return .{
            .noise = SimplexNoise.init(seed),
            .octaves = octaves,
            .lacunarity = lacunarity,
            .persistence = persistence,
        };
    }

    /// Sample 3D FBM noise
    pub fn sample3D(self: *const FBM, x: f32, y: f32, z: f32) f32 {
        var total: f32 = 0.0;
        var frequency: f32 = 1.0;
        var amplitude: f32 = 1.0;
        var max_value: f32 = 0.0;

        for (0..self.octaves) |_| {
            total += self.noise.sample3D(x * frequency, y * frequency, z * frequency) * amplitude;
            max_value += amplitude;
            amplitude *= self.persistence;
            frequency *= self.lacunarity;
        }

        return total / max_value;
    }

    /// Sample 2D FBM noise
    pub fn sample2D(self: *const FBM, x: f32, y: f32) f32 {
        return self.sample3D(x, y, 0.0);
    }
};

/// Domain warping for more organic terrain features
pub const DomainWarp = struct {
    noise1: SimplexNoise,
    noise2: SimplexNoise,
    warp_strength: f32,

    pub fn init(seed: u64, warp_strength: f32) DomainWarp {
        return .{
            .noise1 = SimplexNoise.init(seed),
            .noise2 = SimplexNoise.init(seed +% 12345),
            .warp_strength = warp_strength,
        };
    }

    pub fn sample3D(self: *const DomainWarp, x: f32, y: f32, z: f32) f32 {
        const warp_x = self.noise1.sample3D(x, y, z) * self.warp_strength;
        const warp_y = self.noise2.sample3D(x + 100, y + 100, z + 100) * self.warp_strength;
        const warp_z = self.noise1.sample3D(x - 100, y - 100, z - 100) * self.warp_strength;

        return self.noise2.sample3D(x + warp_x, y + warp_y, z + warp_z);
    }
};

test "simplex noise generates values in range" {
    const noise = SimplexNoise.init(12345);

    for (0..100) |i| {
        const x: f32 = @floatFromInt(i);
        const value = noise.sample3D(x * 0.1, x * 0.1, x * 0.1);
        try std.testing.expect(value >= -1.0 and value <= 1.0);
    }
}

test "FBM noise generation" {
    const fbm = FBM.init(12345, 4, 2.0, 0.5);

    const value = fbm.sample2D(10.0, 20.0);
    try std.testing.expect(value >= -1.0 and value <= 1.0);
}
