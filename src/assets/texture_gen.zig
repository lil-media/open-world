const std = @import("std");

pub const tile_size: usize = 32;
pub const tiles_per_row: u32 = 4;
pub const tiles_per_column: u32 = 4;
pub const channels: usize = 4;

pub const BlockTexture = enum {
    grass,
    dirt,
    stone,
    sand,
    water,
    air,
};

pub const Spec = struct {
    kind: BlockTexture,
    tile: [2]u32,
};

pub const Atlas = struct {
    data: []u8,
    width: usize,
    height: usize,
    channels: usize,

    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = Atlas{
            .data = &[_]u8{},
            .width = 0,
            .height = 0,
            .channels = channels,
        };
    }
};

pub fn defaultSpecs() []const Spec {
    return &[_]Spec{
        .{ .kind = .grass, .tile = .{ 0, 0 } },
        .{ .kind = .dirt, .tile = .{ 1, 0 } },
        .{ .kind = .stone, .tile = .{ 2, 0 } },
        .{ .kind = .sand, .tile = .{ 3, 0 } },
        .{ .kind = .water, .tile = .{ 0, 1 } },
        .{ .kind = .air, .tile = .{ 1, 1 } },
    };
}

pub fn tileCoord(kind: BlockTexture) [2]u32 {
    return switch (kind) {
        .grass => .{ 0, 0 },
        .dirt => .{ 1, 0 },
        .stone => .{ 2, 0 },
        .sand => .{ 3, 0 },
        .water => .{ 0, 1 },
        .air => .{ 1, 1 },
    };
}

pub fn fillBlockBuffer(kind: BlockTexture, buffer: []u8, width: usize, height: usize, out_channels: usize) void {
    const stride = width * out_channels;
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * stride + x * out_channels;
            const color = colorPixel(kind, x, y, width, height);
            buffer[idx + 0] = color[0];
            if (out_channels > 1) buffer[idx + 1] = color[1];
            if (out_channels > 2) buffer[idx + 2] = color[2];
            if (out_channels > 3) buffer[idx + 3] = color[3];
        }
    }
}

fn paintTile(kind: BlockTexture, data: []u8, atlas_width: usize, dest_x: usize, dest_y: usize) void {
    const stride = atlas_width * channels;
    for (0..tile_size) |y| {
        for (0..tile_size) |x| {
            const idx = (dest_y + y) * stride + (dest_x + x) * channels;
            const color = colorPixel(kind, x, y, tile_size, tile_size);
            data[idx + 0] = color[0];
            data[idx + 1] = color[1];
            data[idx + 2] = color[2];
            data[idx + 3] = color[3];
        }
    }
}

fn colorPixel(kind: BlockTexture, x: usize, y: usize, _: usize, height: usize) [4]u8 {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    const hf = @as(f32, @floatFromInt(height));

    var r: f32 = 1.0;
    var g: f32 = 1.0;
    var b: f32 = 1.0;
    var a: f32 = 1.0;

    switch (kind) {
        .grass => {
            var base: f32 = 0.5;
            if (yf < hf / 3.0) base = 0.65;
            if (yf > (hf * 2.0) / 3.0) base = 0.35;
            const noise = 0.1 * std.math.sin((xf + 3.0 * yf) * 0.3);
            const g_val = std.math.clamp(base + noise, 0.0, 1.0);
            r = 0.2;
            g = g_val;
            b = 0.15;
        },
        .dirt => {
            const base = 0.35 + 0.12 * std.math.sin((xf * yf + yf) * 0.15);
            r = base;
            g = base * 0.7;
            b = base * 0.45;
        },
        .stone => {
            const shade = 0.55 + 0.04 * std.math.sin((xf + yf) * 0.6);
            r = shade;
            g = shade;
            b = shade;
        },
        .sand => {
            const base = 0.85 + 0.05 * std.math.sin((xf + yf * 2.0) * 0.4);
            r = base;
            g = std.math.clamp(base - 0.05, 0.0, 1.0);
            b = std.math.clamp(base - 0.10, 0.0, 1.0);
        },
        .water => {
            const waves = 0.3 + 0.2 * std.math.sin(xf * 0.4);
            r = waves * 0.5;
            g = waves * 0.7;
            b = 0.8;
            a = 0.78;
        },
        .air => {
            r = 1.0;
            g = 1.0;
            b = 1.0;
            a = 0.0;
        },
    }

    return .{
        toByte(r),
        toByte(g),
        toByte(b),
        toByte(a),
    };
}

fn toByte(val: f32) u8 {
    return @as(u8, @intFromFloat(std.math.clamp(val, 0.0, 1.0) * 255.0));
}

pub fn generateAtlas(allocator: std.mem.Allocator) !Atlas {
    return generateAtlasWithSpecs(allocator, defaultSpecs());
}

pub fn generateAtlasWithSpecs(allocator: std.mem.Allocator, specs: []const Spec) !Atlas {
    const atlas_width = @as(usize, tiles_per_row) * tile_size;
    const atlas_height = @as(usize, tiles_per_column) * tile_size;
    const size = atlas_width * atlas_height * channels;
    const data = try allocator.alloc(u8, size);
    @memset(data, 0);

    for (specs) |spec| {
        const dest_x = @as(usize, spec.tile[0]) * tile_size;
        const dest_y = @as(usize, spec.tile[1]) * tile_size;
        paintTile(spec.kind, data, atlas_width, dest_x, dest_y);
    }

    return Atlas{
        .data = data,
        .width = atlas_width,
        .height = atlas_height,
        .channels = channels,
    };
}
