const std = @import("std");
const math = @import("../utils/math.zig");

/// Camera mode
pub const CameraMode = enum {
    first_person, // FPS-style camera
    free_cam, // Noclip flying camera
    third_person, // Over-shoulder camera (future)
};

/// Camera for rendering the world
pub const Camera = struct {
    // Position and orientation
    position: math.Vec3,
    front: math.Vec3,
    up: math.Vec3,
    right: math.Vec3,
    world_up: math.Vec3,

    // Euler angles (in radians)
    yaw: f32, // Rotation around Y axis
    pitch: f32, // Rotation around X axis

    // Camera settings
    fov: f32, // Field of view in radians
    aspect_ratio: f32,
    near_plane: f32,
    far_plane: f32,

    // Movement settings
    movement_speed: f32,
    sprint_multiplier: f32,
    mouse_sensitivity: f32,
    mode: CameraMode,

    pub fn init(position: math.Vec3, aspect_ratio: f32) Camera {
        var camera = Camera{
            .position = position,
            .front = math.Vec3.init(0, 0, -1),
            .up = math.Vec3.init(0, 1, 0),
            .right = math.Vec3.init(1, 0, 0),
            .world_up = math.Vec3.init(0, 1, 0),
            .yaw = -std.math.pi / 2.0, // -90 degrees (facing -Z)
            .pitch = 0,
            .fov = math.toRadians(75.0),
            .aspect_ratio = aspect_ratio,
            .near_plane = 0.1,
            .far_plane = 1000.0,
            .movement_speed = 10.0,
            .sprint_multiplier = 2.0,
            .mouse_sensitivity = 0.002,
            .mode = .first_person,
        };
        camera.updateVectors();
        return camera;
    }

    /// Update camera vectors based on Euler angles
    fn updateVectors(self: *Camera) void {
        // Calculate front vector
        const cos_pitch = @cos(self.pitch);
        const sin_pitch = @sin(self.pitch);
        const cos_yaw = @cos(self.yaw);
        const sin_yaw = @sin(self.yaw);

        self.front = math.Vec3.init(
            cos_pitch * cos_yaw,
            sin_pitch,
            cos_pitch * sin_yaw,
        ).normalize();

        // Calculate right and up vectors
        self.right = self.front.cross(self.world_up).normalize();
        self.up = self.right.cross(self.front).normalize();
    }

    /// Get view matrix (lookAt)
    pub fn getViewMatrix(self: *const Camera) math.Mat4 {
        const target = self.position.add(self.front);
        return math.Mat4.lookAt(self.position, target, self.up);
    }

    /// Get projection matrix (perspective)
    pub fn getProjectionMatrix(self: *const Camera) math.Mat4 {
        return math.Mat4.perspective(self.fov, self.aspect_ratio, self.near_plane, self.far_plane);
    }

    /// Get combined view-projection matrix
    pub fn getViewProjectionMatrix(self: *const Camera) math.Mat4 {
        const view = self.getViewMatrix();
        const projection = self.getProjectionMatrix();
        return projection.multiply(view);
    }

    /// Get frustum for culling
    pub fn getFrustum(self: *const Camera) math.Frustum {
        const vp = self.getViewProjectionMatrix();
        return math.Frustum.fromMatrix(vp);
    }

    /// Handle mouse movement
    pub fn processMouseMovement(self: *Camera, delta_x: f32, delta_y: f32) void {
        self.yaw += delta_x * self.mouse_sensitivity;
        self.pitch -= delta_y * self.mouse_sensitivity;

        // Constrain pitch to prevent gimbal lock
        const max_pitch = std.math.pi / 2.0 - 0.01; // 89.99 degrees
        self.pitch = math.clamp(self.pitch, -max_pitch, max_pitch);

        self.updateVectors();
    }

    /// Handle keyboard movement
    pub fn processMovement(self: *Camera, direction: MovementDirection, dt: f32, sprint: bool) void {
        const velocity = self.movement_speed * (if (sprint) self.sprint_multiplier else 1.0) * dt;

        switch (direction) {
            .forward => {
                const move_dir = if (self.mode == .first_person)
                    // Don't move up/down in first person
                    math.Vec3.init(self.front.x, 0, self.front.z).normalize()
                else
                    self.front;
                self.position = self.position.add(move_dir.mul(velocity));
            },
            .backward => {
                const move_dir = if (self.mode == .first_person)
                    math.Vec3.init(self.front.x, 0, self.front.z).normalize()
                else
                    self.front;
                self.position = self.position.sub(move_dir.mul(velocity));
            },
            .left => {
                self.position = self.position.sub(self.right.mul(velocity));
            },
            .right => {
                self.position = self.position.add(self.right.mul(velocity));
            },
            .up => {
                self.position = self.position.add(self.world_up.mul(velocity));
            },
            .down => {
                self.position = self.position.sub(self.world_up.mul(velocity));
            },
        }
    }

    /// Set camera mode
    pub fn setMode(self: *Camera, mode: CameraMode) void {
        self.mode = mode;
    }

    /// Set aspect ratio (call when window is resized)
    pub fn setAspectRatio(self: *Camera, aspect_ratio: f32) void {
        self.aspect_ratio = aspect_ratio;
    }

    /// Set field of view
    pub fn setFOV(self: *Camera, fov_degrees: f32) void {
        self.fov = math.toRadians(fov_degrees);
    }

    /// Teleport to position
    pub fn setPosition(self: *Camera, position: math.Vec3) void {
        self.position = position;
    }

    /// Set rotation (in radians)
    pub fn setRotation(self: *Camera, yaw: f32, pitch: f32) void {
        self.yaw = yaw;
        self.pitch = pitch;
        self.updateVectors();
    }

    /// Get position
    pub fn getPosition(self: *const Camera) math.Vec3 {
        return self.position;
    }

    /// Get forward direction
    pub fn getFront(self: *const Camera) math.Vec3 {
        return self.front;
    }

    /// Get right direction
    pub fn getRight(self: *const Camera) math.Vec3 {
        return self.right;
    }

    /// Get up direction
    pub fn getUp(self: *const Camera) math.Vec3 {
        return self.up;
    }
};

/// Movement directions
pub const MovementDirection = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
};

/// Smooth camera controller for interpolated movement
pub const SmoothCamera = struct {
    camera: Camera,
    target_position: math.Vec3,
    target_yaw: f32,
    target_pitch: f32,
    smoothing: f32, // 0 = instant, 1 = very smooth

    pub fn init(position: math.Vec3, aspect_ratio: f32) SmoothCamera {
        return .{
            .camera = Camera.init(position, aspect_ratio),
            .target_position = position,
            .target_yaw = -std.math.pi / 2.0,
            .target_pitch = 0,
            .smoothing = 0.15,
        };
    }

    /// Update camera with smoothing
    pub fn update(self: *SmoothCamera, dt: f32) void {
        // Smooth position
        const pos_diff = self.target_position.sub(self.camera.position);
        self.camera.position = self.camera.position.add(pos_diff.mul(self.smoothing * dt * 60.0));

        // Smooth rotation
        const yaw_diff = self.target_yaw - self.camera.yaw;
        const pitch_diff = self.target_pitch - self.camera.pitch;

        self.camera.yaw += yaw_diff * self.smoothing * dt * 60.0;
        self.camera.pitch += pitch_diff * self.smoothing * dt * 60.0;

        self.camera.updateVectors();
    }

    /// Set target position
    pub fn setTargetPosition(self: *SmoothCamera, position: math.Vec3) void {
        self.target_position = position;
    }

    /// Set target rotation
    pub fn setTargetRotation(self: *SmoothCamera, yaw: f32, pitch: f32) void {
        self.target_yaw = yaw;
        self.target_pitch = pitch;
    }

    /// Process mouse movement (affects targets)
    pub fn processMouseMovement(self: *SmoothCamera, delta_x: f32, delta_y: f32) void {
        self.target_yaw += delta_x * self.camera.mouse_sensitivity;
        self.target_pitch -= delta_y * self.camera.mouse_sensitivity;

        const max_pitch = std.math.pi / 2.0 - 0.01;
        self.target_pitch = math.clamp(self.target_pitch, -max_pitch, max_pitch);
    }

    /// Process movement (affects target position)
    pub fn processMovement(self: *SmoothCamera, direction: MovementDirection, dt: f32, sprint: bool) void {
        const velocity = self.camera.movement_speed * (if (sprint) self.camera.sprint_multiplier else 1.0) * dt;

        switch (direction) {
            .forward => {
                const move_dir = if (self.camera.mode == .first_person)
                    math.Vec3.init(self.camera.front.x, 0, self.camera.front.z).normalize()
                else
                    self.camera.front;
                self.target_position = self.target_position.add(move_dir.mul(velocity));
            },
            .backward => {
                const move_dir = if (self.camera.mode == .first_person)
                    math.Vec3.init(self.camera.front.x, 0, self.camera.front.z).normalize()
                else
                    self.camera.front;
                self.target_position = self.target_position.sub(move_dir.mul(velocity));
            },
            .left => {
                self.target_position = self.target_position.sub(self.camera.right.mul(velocity));
            },
            .right => {
                self.target_position = self.target_position.add(self.camera.right.mul(velocity));
            },
            .up => {
                self.target_position = self.target_position.add(self.camera.world_up.mul(velocity));
            },
            .down => {
                self.target_position = self.target_position.sub(self.camera.world_up.mul(velocity));
            },
        }
    }
};

test "camera initialization" {
    const camera = Camera.init(math.Vec3.init(0, 70, 0), 16.0 / 9.0);

    try std.testing.expectEqual(@as(f32, 0), camera.position.x);
    try std.testing.expectEqual(@as(f32, 70), camera.position.y);
    try std.testing.expectEqual(@as(f32, 0), camera.position.z);
}

test "camera view matrix" {
    var camera = Camera.init(math.Vec3.init(0, 70, 0), 16.0 / 9.0);
    const view = camera.getViewMatrix();
    _ = view;
}

test "camera movement" {
    var camera = Camera.init(math.Vec3.init(0, 70, 0), 16.0 / 9.0);
    const initial_pos = camera.position;

    camera.processMovement(.forward, 0.016, false);

    try std.testing.expect(camera.position.z != initial_pos.z);
}

test "smooth camera" {
    var smooth_camera = SmoothCamera.init(math.Vec3.init(0, 70, 0), 16.0 / 9.0);

    smooth_camera.setTargetPosition(math.Vec3.init(10, 70, 10));
    smooth_camera.update(0.016);

    // Position should move toward target
    try std.testing.expect(smooth_camera.camera.position.x > 0);
    try std.testing.expect(smooth_camera.camera.position.z > 0);
}
