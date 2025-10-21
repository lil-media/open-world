const std = @import("std");
const terrain = @import("../terrain/terrain.zig");
const math = @import("../utils/math.zig");

/// Vertex structure for rendering
pub const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    tex_coords: [2]f32,
    ao: f32, // Ambient occlusion factor
    block_type: terrain.BlockType,

    pub fn init(pos: [3]f32, norm: [3]f32, uv: [2]f32, ambient: f32, block_type: terrain.BlockType) Vertex {
        return .{
            .position = pos,
            .normal = norm,
            .tex_coords = uv,
            .ao = ambient,
            .block_type = block_type,
        };
    }
};

/// Face direction for block faces
pub const FaceDirection = enum(u8) {
    north = 0, // -Z
    south = 1, // +Z
    west = 2, // -X
    east = 3, // +X
    bottom = 4, // -Y
    top = 5, // +Y

    pub fn getNormal(self: FaceDirection) [3]f32 {
        return switch (self) {
            .north => [3]f32{ 0, 0, -1 },
            .south => [3]f32{ 0, 0, 1 },
            .west => [3]f32{ -1, 0, 0 },
            .east => [3]f32{ 1, 0, 0 },
            .bottom => [3]f32{ 0, -1, 0 },
            .top => [3]f32{ 0, 1, 0 },
        };
    }

    pub fn getOffset(self: FaceDirection) [3]i32 {
        return switch (self) {
            .north => [3]i32{ 0, 0, -1 },
            .south => [3]i32{ 0, 0, 1 },
            .west => [3]i32{ -1, 0, 0 },
            .east => [3]i32{ 1, 0, 0 },
            .bottom => [3]i32{ 0, -1, 0 },
            .top => [3]i32{ 0, 1, 0 },
        };
    }
};

/// Mesh data for a chunk
pub const ChunkMesh = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),
    vertex_count: u32,
    triangle_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ChunkMesh {
        const VertexList = std.ArrayList(Vertex);
        const IndexList = std.ArrayList(u32);

        return .{
            .vertices = VertexList{},
            .indices = IndexList{},
            .vertex_count = 0,
            .triangle_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChunkMesh) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    pub fn clear(self: *ChunkMesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.vertex_count = 0;
        self.triangle_count = 0;
    }

    /// Add a quad face to the mesh
    pub fn addQuad(
        self: *ChunkMesh,
        x: f32,
        y: f32,
        z: f32,
        width: f32,
        height: f32,
        dir: FaceDirection,
        ao_values: [4]f32,
        block_type: terrain.BlockType,
    ) !void {
        const normal = dir.getNormal();
        const base_index = @as(u32, @intCast(self.vertices.items.len));

        // Calculate quad vertices based on direction
        const vertices = switch (dir) {
            .top => [4][3]f32{
                [3]f32{ x, y + 1, z }, // 0: back-left
                [3]f32{ x + width, y + 1, z }, // 1: back-right
                [3]f32{ x + width, y + 1, z + height }, // 2: front-right
                [3]f32{ x, y + 1, z + height }, // 3: front-left
            },
            .bottom => [4][3]f32{
                [3]f32{ x, y, z + height },
                [3]f32{ x + width, y, z + height },
                [3]f32{ x + width, y, z },
                [3]f32{ x, y, z },
            },
            .north => [4][3]f32{
                [3]f32{ x, y, z },
                [3]f32{ x + width, y, z },
                [3]f32{ x + width, y + height, z },
                [3]f32{ x, y + height, z },
            },
            .south => [4][3]f32{
                [3]f32{ x + width, y, z + 1 },
                [3]f32{ x, y, z + 1 },
                [3]f32{ x, y + height, z + 1 },
                [3]f32{ x + width, y + height, z + 1 },
            },
            .west => [4][3]f32{
                [3]f32{ x, y, z + height },
                [3]f32{ x, y, z },
                [3]f32{ x, y + height, z },
                [3]f32{ x, y + height, z + height },
            },
            .east => [4][3]f32{
                [3]f32{ x + 1, y, z },
                [3]f32{ x + 1, y, z + height },
                [3]f32{ x + 1, y + height, z + height },
                [3]f32{ x + 1, y + height, z },
            },
        };

        // UV coordinates scale with quad size
        const uvs = [4][2]f32{
            [2]f32{ 0, 0 },
            [2]f32{ width, 0 },
            [2]f32{ width, height },
            [2]f32{ 0, height },
        };

        // Add vertices
        for (vertices, 0..) |vert, i| {
            try self.vertices.append(self.allocator, Vertex.init(vert, normal, uvs[i], ao_values[i], block_type));
        }

        // Add indices (two triangles)
        // Flip winding based on AO to prevent visual artifacts
        if (ao_values[0] + ao_values[2] > ao_values[1] + ao_values[3]) {
            // Standard winding
            try self.indices.append(self.allocator, base_index + 0);
            try self.indices.append(self.allocator, base_index + 1);
            try self.indices.append(self.allocator, base_index + 2);
            try self.indices.append(self.allocator, base_index + 0);
            try self.indices.append(self.allocator, base_index + 2);
            try self.indices.append(self.allocator, base_index + 3);
        } else {
            // Flipped winding
            try self.indices.append(self.allocator, base_index + 0);
            try self.indices.append(self.allocator, base_index + 1);
            try self.indices.append(self.allocator, base_index + 3);
            try self.indices.append(self.allocator, base_index + 1);
            try self.indices.append(self.allocator, base_index + 2);
            try self.indices.append(self.allocator, base_index + 3);
        }

        self.vertex_count += 4;
        self.triangle_count += 2;
    }
};

/// Greedy meshing algorithm for efficient chunk rendering
/// Combines adjacent faces of the same type into larger quads
pub const GreedyMesher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GreedyMesher {
        return .{ .allocator = allocator };
    }

    /// Generate mesh for a chunk using greedy meshing
    pub fn generateMesh(self: *GreedyMesher, chunk: *const terrain.Chunk) !ChunkMesh {
        var mesh = ChunkMesh.init(self.allocator);

        // Process each axis (X, Y, Z)
        // For each axis, we slice the chunk and find rectangular regions
        for (0..3) |axis| {
            try self.meshAxis(chunk, &mesh, axis);
        }

        return mesh;
    }

    fn meshAxis(self: *GreedyMesher, chunk: *const terrain.Chunk, mesh: *ChunkMesh, axis: usize) !void {
        const chunk_size = terrain.Chunk.CHUNK_SIZE;
        const chunk_height = terrain.Chunk.CHUNK_HEIGHT;

        // Dimensions perpendicular to the axis
        const u_dim = (axis + 1) % 3; // U axis
        const v_dim = (axis + 2) % 3; // V axis

        const max_u: usize = if (u_dim == 1) chunk_height else chunk_size;
        const max_v: usize = if (v_dim == 1) chunk_height else chunk_size;
        const max_d: usize = if (axis == 1) chunk_height else chunk_size;

        // Process both positive and negative face directions
        for ([_]bool{ false, true }) |is_positive_direction| {
            try self.meshAxisDirection(chunk, mesh, axis, u_dim, v_dim, max_u, max_v, max_d, is_positive_direction);
        }
    }

    fn meshAxisDirection(
        self: *GreedyMesher,
        chunk: *const terrain.Chunk,
        mesh: *ChunkMesh,
        axis: usize,
        u_dim: usize,
        v_dim: usize,
        max_u: usize,
        max_v: usize,
        max_d: usize,
        is_positive_direction: bool,
    ) !void {
        // Mask for identifying matching faces
        var mask = try self.allocator.alloc(?terrain.BlockType, max_u * max_v);
        defer self.allocator.free(mask);

        // Sweep through each layer along the axis
        var d: usize = 0;
        while (d < max_d) : (d += 1) {
            // Clear mask
            @memset(mask, null);

            // Build mask for this layer
            for (0..max_u) |u| {
                for (0..max_v) |v| {
                    // Get coordinates in chunk space
                    var pos = [3]usize{ 0, 0, 0 };
                    pos[axis] = d;
                    pos[u_dim] = u;
                    pos[v_dim] = v;

                    const block = chunk.getBlock(pos[0], pos[2], pos[1]) orelse continue;

                    // Skip air blocks
                    if (block.block_type == .air) continue;

                    // Check if face should be rendered based on direction
                    const should_render = if (is_positive_direction) blk: {
                        if (d + 1 >= max_d) break :blk true;

                        var neighbor_pos = pos;
                        neighbor_pos[axis] += 1;

                        const neighbor = chunk.getBlock(neighbor_pos[0], neighbor_pos[2], neighbor_pos[1]);
                        break :blk neighbor == null or neighbor.?.block_type == .air or !neighbor.?.isSolid();
                    } else blk: {
                        if (d == 0) break :blk true;

                        var neighbor_pos = pos;
                        neighbor_pos[axis] -= 1;

                        const neighbor = chunk.getBlock(neighbor_pos[0], neighbor_pos[2], neighbor_pos[1]);
                        break :blk neighbor == null or neighbor.?.block_type == .air or !neighbor.?.isSolid();
                    };

                    // Store in mask if face should be rendered
                    if (should_render) {
                        mask[u * max_v + v] = block.block_type;
                    }
                }
            }

            // Generate mesh from mask using greedy algorithm
            var u: usize = 0;
            while (u < max_u) : (u += 1) {
                var v: usize = 0;
                while (v < max_v) {
                    if (mask[u * max_v + v]) |block_type| {
                        // Found a block, now find the width
                        var width: usize = 1;
                        while (v + width < max_v) : (width += 1) {
                            const next = mask[u * max_v + v + width];
                            if (next == null or next.? != block_type) break;
                        }

                        // Find the height
                        var height: usize = 1;
                        var done = false;
                        height_loop: while (u + height < max_u) : (height += 1) {
                            for (0..width) |w| {
                                const check = mask[(u + height) * max_v + v + w];
                                if (check == null or check.? != block_type) {
                                    done = true;
                                    break :height_loop;
                                }
                            }
                            if (done) break;
                        }

                        // Create quad for this region
                        var quad_pos = [3]f32{ 0, 0, 0 };
                        quad_pos[axis] = @floatFromInt(d);
                        quad_pos[u_dim] = @floatFromInt(u);
                        quad_pos[v_dim] = @floatFromInt(v);

                        const quad_width: f32 = @floatFromInt(width);
                        const quad_height: f32 = @floatFromInt(height);

                        // Determine face direction based on which side we're processing
                        const face_dir = getFaceDirection(axis, is_positive_direction);
                        const face_block_type = block_type;

                        // Calculate ambient occlusion (simplified - all 1.0 for now)
                        const ao = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

                        try mesh.addQuad(
                            quad_pos[0],
                            quad_pos[1],
                            quad_pos[2],
                            quad_width,
                            quad_height,
                            face_dir,
                            ao,
                            face_block_type,
                        );

                        // Clear mask for this region
                        for (0..height) |h| {
                            for (0..width) |w| {
                                mask[(u + h) * max_v + v + w] = null;
                            }
                        }

                        v += width;
                    } else {
                        v += 1;
                    }
                }
            }
        }

        return;
    }

    fn getFaceDirection(axis: usize, positive: bool) FaceDirection {
        return switch (axis) {
            0 => if (positive) .east else .west, // X axis
            1 => if (positive) .top else .bottom, // Y axis
            2 => if (positive) .south else .north, // Z axis
            else => unreachable,
        };
    }
};

/// Calculate ambient occlusion for a vertex
/// Checks the 8 surrounding blocks and returns a darkening factor
pub fn calculateAO(
    chunk: *const terrain.Chunk,
    x: i32,
    y: i32,
    z: i32,
    face: FaceDirection,
    corner: u8,
) f32 {
    _ = chunk;
    _ = x;
    _ = y;
    _ = z;
    _ = face;
    _ = corner;

    // TODO: Implement proper AO calculation
    // For now, return full brightness
    return 1.0;
}

test "greedy mesher initialization" {
    const allocator = std.testing.allocator;
    const mesher = GreedyMesher.init(allocator);
    _ = mesher;
}

test "mesh generation" {
    const allocator = std.testing.allocator;
    var mesher = GreedyMesher.init(allocator);

    var chunk = terrain.Chunk.init(0, 0);

    // Fill bottom layer with stone
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.blocks[x][z][0] = terrain.Block.init(.stone);
        }
    }

    var mesh = try mesher.generateMesh(&chunk);
    defer mesh.deinit();

    // Should have generated some vertices
    try std.testing.expect(mesh.vertices.items.len > 0);
    try std.testing.expect(mesh.indices.items.len > 0);
}
