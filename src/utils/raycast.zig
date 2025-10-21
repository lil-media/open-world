const std = @import("std");
const math = @import("math.zig");
const terrain = @import("../terrain/terrain.zig");

/// Result of a ray cast against the voxel world
pub const RaycastHit = struct {
    hit: bool,
    block_pos: math.Vec3i, // Position of the hit block
    face_normal: math.Vec3i, // Which face was hit (-1, 0, or 1 for each axis)
    distance: f32,

    pub fn init() RaycastHit {
        return .{
            .hit = false,
            .block_pos = math.Vec3i.init(0, 0, 0),
            .face_normal = math.Vec3i.init(0, 0, 0),
            .distance = 0.0,
        };
    }
};

/// Cast a ray through the voxel world using DDA algorithm
/// Returns information about the first solid block hit
pub fn raycast(
    origin: math.Vec3,
    direction: math.Vec3,
    max_distance: f32,
    context: anytype,
    get_block_fn: *const fn (@TypeOf(context), i32, i32, i32) ?terrain.BlockType,
) RaycastHit {
    var result = RaycastHit.init();

    // Normalize direction
    const dir = direction.normalize();

    // Current position in world space
    const pos = origin;

    // Current voxel position
    var voxel_x = @as(i32, @intFromFloat(@floor(pos.x)));
    var voxel_y = @as(i32, @intFromFloat(@floor(pos.y)));
    var voxel_z = @as(i32, @intFromFloat(@floor(pos.z)));

    // Step direction (+1 or -1) for each axis
    const step_x: i32 = if (dir.x >= 0) 1 else -1;
    const step_y: i32 = if (dir.y >= 0) 1 else -1;
    const step_z: i32 = if (dir.z >= 0) 1 else -1;

    // tDelta: how far along the ray we must move to cross a voxel boundary
    const t_delta_x = if (@abs(dir.x) > 0.0001) @abs(1.0 / dir.x) else std.math.inf(f32);
    const t_delta_y = if (@abs(dir.y) > 0.0001) @abs(1.0 / dir.y) else std.math.inf(f32);
    const t_delta_z = if (@abs(dir.z) > 0.0001) @abs(1.0 / dir.z) else std.math.inf(f32);

    // tMax: distance along ray to next voxel boundary
    var t_max_x: f32 = undefined;
    var t_max_y: f32 = undefined;
    var t_max_z: f32 = undefined;

    // Calculate initial tMax values
    if (dir.x > 0) {
        t_max_x = (@as(f32, @floatFromInt(voxel_x + 1)) - pos.x) / dir.x;
    } else {
        t_max_x = (@as(f32, @floatFromInt(voxel_x)) - pos.x) / dir.x;
    }

    if (dir.y > 0) {
        t_max_y = (@as(f32, @floatFromInt(voxel_y + 1)) - pos.y) / dir.y;
    } else {
        t_max_y = (@as(f32, @floatFromInt(voxel_y)) - pos.y) / dir.y;
    }

    if (dir.z > 0) {
        t_max_z = (@as(f32, @floatFromInt(voxel_z + 1)) - pos.z) / dir.z;
    } else {
        t_max_z = (@as(f32, @floatFromInt(voxel_z)) - pos.z) / dir.z;
    }

    // Track which face we hit
    var face_normal = math.Vec3i.init(0, 0, 0);

    // DDA traversal
    var distance: f32 = 0.0;
    const max_steps: u32 = @intFromFloat(max_distance * 2.0); // Reasonable upper bound

    var step: u32 = 0;
    while (step < max_steps and distance < max_distance) : (step += 1) {
        // Check current voxel
        if (get_block_fn(context, voxel_x, voxel_y, voxel_z)) |block_type| {
            if (block_type != .air) {
                // Hit a solid block
                result.hit = true;
                result.block_pos = math.Vec3i.init(voxel_x, voxel_y, voxel_z);
                result.face_normal = face_normal;
                result.distance = distance;
                return result;
            }
        }

        // Move to next voxel
        if (t_max_x < t_max_y) {
            if (t_max_x < t_max_z) {
                voxel_x += step_x;
                distance = t_max_x;
                t_max_x += t_delta_x;
                face_normal = math.Vec3i.init(-step_x, 0, 0);
            } else {
                voxel_z += step_z;
                distance = t_max_z;
                t_max_z += t_delta_z;
                face_normal = math.Vec3i.init(0, 0, -step_z);
            }
        } else {
            if (t_max_y < t_max_z) {
                voxel_y += step_y;
                distance = t_max_y;
                t_max_y += t_delta_y;
                face_normal = math.Vec3i.init(0, -step_y, 0);
            } else {
                voxel_z += step_z;
                distance = t_max_z;
                t_max_z += t_delta_z;
                face_normal = math.Vec3i.init(0, 0, -step_z);
            }
        }
    }

    return result;
}

test "raycast basic" {
    const Vec3 = math.Vec3;

    const TestContext = struct {};
    const test_ctx = TestContext{};

    // Simple test function that returns stone at (5, 5, 5)
    const testGetBlock = struct {
        fn get(ctx: TestContext, x: i32, y: i32, z: i32) ?terrain.BlockType {
            _ = ctx;
            if (x == 5 and y == 5 and z == 5) {
                return .stone;
            }
            return .air;
        }
    }.get;

    // Cast a ray that should hit the block
    const origin = Vec3.init(0, 5, 5);
    const direction = Vec3.init(1, 0, 0);
    const hit = raycast(origin, direction, 10.0, test_ctx, testGetBlock);

    try std.testing.expect(hit.hit);
    try std.testing.expectEqual(@as(i32, 5), hit.block_pos.x);
    try std.testing.expectEqual(@as(i32, 5), hit.block_pos.y);
    try std.testing.expectEqual(@as(i32, 5), hit.block_pos.z);
}
