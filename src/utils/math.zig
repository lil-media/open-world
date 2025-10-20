const std = @import("std");

/// 3D Vector for positions, directions, and normals
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return init(0, 0, 0);
    }

    pub fn one() Vec3 {
        return init(1, 1, 1);
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return init(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return init(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub fn mul(self: Vec3, scalar: f32) Vec3 {
        return init(self.x * scalar, self.y * scalar, self.z * scalar);
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return init(
            self.y * other.z - self.z * other.y,
            self.z * other.x - self.x * other.z,
            self.x * other.y - self.y * other.x,
        );
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.dot(self));
    }

    pub fn lengthSquared(self: Vec3) f32 {
        return self.dot(self);
    }

    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return self;
        return self.mul(1.0 / len);
    }

    pub fn distance(self: Vec3, other: Vec3) f32 {
        return self.sub(other).length();
    }

    pub fn lerp(self: Vec3, other: Vec3, t: f32) Vec3 {
        return self.add(other.sub(self).mul(t));
    }
};

/// 3D Integer Vector for block positions
pub const Vec3i = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn init(x: i32, y: i32, z: i32) Vec3i {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3i {
        return init(0, 0, 0);
    }

    pub fn add(self: Vec3i, other: Vec3i) Vec3i {
        return init(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub fn sub(self: Vec3i, other: Vec3i) Vec3i {
        return init(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub fn toVec3(self: Vec3i) Vec3 {
        return Vec3.init(@floatFromInt(self.x), @floatFromInt(self.y), @floatFromInt(self.z));
    }

    pub fn fromVec3(v: Vec3) Vec3i {
        return init(@intFromFloat(@floor(v.x)), @intFromFloat(@floor(v.y)), @intFromFloat(@floor(v.z)));
    }
};

/// Axis-Aligned Bounding Box for collision detection
pub const AABB = struct {
    min: Vec3,
    max: Vec3,

    pub fn init(min: Vec3, max: Vec3) AABB {
        return .{ .min = min, .max = max };
    }

    pub fn fromCenter(center_pos: Vec3, half_extents: Vec3) AABB {
        return .{
            .min = center_pos.sub(half_extents),
            .max = center_pos.add(half_extents),
        };
    }

    pub fn intersects(self: AABB, other: AABB) bool {
        return self.min.x <= other.max.x and self.max.x >= other.min.x and
            self.min.y <= other.max.y and self.max.y >= other.min.y and
            self.min.z <= other.max.z and self.max.z >= other.min.z;
    }

    pub fn contains(self: AABB, point: Vec3) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y and
            point.z >= self.min.z and point.z <= self.max.z;
    }

    pub fn expand(self: AABB, amount: Vec3) AABB {
        return .{
            .min = self.min.sub(amount),
            .max = self.max.add(amount),
        };
    }

    pub fn center(self: AABB) Vec3 {
        return self.min.add(self.max).mul(0.5);
    }

    pub fn size(self: AABB) Vec3 {
        return self.max.sub(self.min);
    }
};

/// 4x4 Matrix for transformations
pub const Mat4 = struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        return .{
            .data = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
        };
    }

    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = @tan(fov / 2.0);
        var result = Mat4{ .data = [_]f32{0} ** 16 };

        result.data[0] = 1.0 / (aspect * tan_half_fov);
        result.data[5] = 1.0 / tan_half_fov;
        result.data[10] = -(far + near) / (far - near);
        result.data[11] = -1.0;
        result.data[14] = -(2.0 * far * near) / (far - near);

        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);

        var result = identity();
        result.data[0] = s.x;
        result.data[4] = s.y;
        result.data[8] = s.z;
        result.data[1] = u.x;
        result.data[5] = u.y;
        result.data[9] = u.z;
        result.data[2] = -f.x;
        result.data[6] = -f.y;
        result.data[10] = -f.z;
        result.data[12] = -s.dot(eye);
        result.data[13] = -u.dot(eye);
        result.data[14] = f.dot(eye);

        return result;
    }

    pub fn translate(pos: Vec3) Mat4 {
        var result = identity();
        result.data[12] = pos.x;
        result.data[13] = pos.y;
        result.data[14] = pos.z;
        return result;
    }

    pub fn scale(s: Vec3) Mat4 {
        var result = identity();
        result.data[0] = s.x;
        result.data[5] = s.y;
        result.data[10] = s.z;
        return result;
    }

    pub fn multiply(self: Mat4, other: Mat4) Mat4 {
        var result = Mat4{ .data = [_]f32{0} ** 16 };
        for (0..4) |i| {
            for (0..4) |j| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += self.data[i * 4 + k] * other.data[k * 4 + j];
                }
                result.data[i * 4 + j] = sum;
            }
        }
        return result;
    }
};

/// Frustum for culling
pub const Frustum = struct {
    planes: [6]Plane,

    pub const Plane = struct {
        normal: Vec3,
        distance: f32,

        pub fn init(normal: Vec3, distance: f32) Plane {
            return .{ .normal = normal.normalize(), .distance = distance };
        }

        pub fn distanceToPoint(self: Plane, point: Vec3) f32 {
            return self.normal.dot(point) + self.distance;
        }
    };

    pub fn fromMatrix(vp: Mat4) Frustum {
        var frustum: Frustum = undefined;

        // Left plane
        frustum.planes[0] = Plane.init(
            Vec3.init(vp.data[3] + vp.data[0], vp.data[7] + vp.data[4], vp.data[11] + vp.data[8]),
            vp.data[15] + vp.data[12],
        );

        // Right plane
        frustum.planes[1] = Plane.init(
            Vec3.init(vp.data[3] - vp.data[0], vp.data[7] - vp.data[4], vp.data[11] - vp.data[8]),
            vp.data[15] - vp.data[12],
        );

        // Bottom plane
        frustum.planes[2] = Plane.init(
            Vec3.init(vp.data[3] + vp.data[1], vp.data[7] + vp.data[5], vp.data[11] + vp.data[9]),
            vp.data[15] + vp.data[13],
        );

        // Top plane
        frustum.planes[3] = Plane.init(
            Vec3.init(vp.data[3] - vp.data[1], vp.data[7] - vp.data[5], vp.data[11] - vp.data[9]),
            vp.data[15] - vp.data[13],
        );

        // Near plane
        frustum.planes[4] = Plane.init(
            Vec3.init(vp.data[3] + vp.data[2], vp.data[7] + vp.data[6], vp.data[11] + vp.data[10]),
            vp.data[15] + vp.data[14],
        );

        // Far plane
        frustum.planes[5] = Plane.init(
            Vec3.init(vp.data[3] - vp.data[2], vp.data[7] - vp.data[6], vp.data[11] - vp.data[10]),
            vp.data[15] - vp.data[14],
        );

        return frustum;
    }

    pub fn containsAABB(self: Frustum, aabb: AABB) bool {
        for (self.planes) |plane| {
            // Get the positive vertex
            var p = aabb.min;
            if (plane.normal.x >= 0) p.x = aabb.max.x;
            if (plane.normal.y >= 0) p.y = aabb.max.y;
            if (plane.normal.z >= 0) p.z = aabb.max.z;

            if (plane.distanceToPoint(p) < 0) {
                return false;
            }
        }
        return true;
    }
};

/// Utility math functions
pub fn clamp(value: f32, min_val: f32, max_val: f32) f32 {
    return @max(min_val, @min(max_val, value));
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn toRadians(degrees_val: f32) f32 {
    return degrees_val * std.math.pi / 180.0;
}

pub fn toDegrees(radians_val: f32) f32 {
    return radians_val * 180.0 / std.math.pi;
}

test "Vec3 operations" {
    const v1 = Vec3.init(1, 2, 3);
    const v2 = Vec3.init(4, 5, 6);

    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f32, 5), sum.x);
    try std.testing.expectEqual(@as(f32, 7), sum.y);
    try std.testing.expectEqual(@as(f32, 9), sum.z);

    const dot_product = v1.dot(v2);
    try std.testing.expectEqual(@as(f32, 32), dot_product);
}

test "AABB collision" {
    const aabb1 = AABB.init(Vec3.init(0, 0, 0), Vec3.init(2, 2, 2));
    const aabb2 = AABB.init(Vec3.init(1, 1, 1), Vec3.init(3, 3, 3));
    const aabb3 = AABB.init(Vec3.init(5, 5, 5), Vec3.init(7, 7, 7));

    try std.testing.expect(aabb1.intersects(aabb2));
    try std.testing.expect(!aabb1.intersects(aabb3));
}
