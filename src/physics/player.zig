const std = @import("std");
const math = @import("../utils/math.zig");
const terrain = @import("../terrain/terrain.zig");

/// Player physics state
pub const PlayerPhysics = struct {
    // Position and movement
    position: math.Vec3,
    velocity: math.Vec3,
    acceleration: math.Vec3,

    // Collision box
    aabb: math.AABB,
    width: f32, // 0.6 blocks
    height: f32, // 1.8 blocks
    eye_height: f32, // 1.62 blocks

    // Physics parameters
    gravity: f32,
    jump_velocity: f32,
    ground_friction: f32,
    air_friction: f32,

    // Movement speeds
    walk_speed: f32,
    sprint_speed: f32,
    sneak_speed: f32,
    fly_speed: f32,

    // State
    on_ground: bool,
    in_water: bool,
    is_flying: bool,
    is_sprinting: bool,
    is_sneaking: bool,

    pub fn init(spawn_position: math.Vec3) PlayerPhysics {
        const width = 0.6;
        const height = 1.8;

        return .{
            .position = spawn_position,
            .velocity = math.Vec3.zero(),
            .acceleration = math.Vec3.zero(),
            .aabb = math.AABB.fromCenter(spawn_position, math.Vec3.init(width / 2.0, height / 2.0, width / 2.0)),
            .width = width,
            .height = height,
            .eye_height = 1.62,
            .gravity = 32.0, // blocks per second²
            .jump_velocity = 10.0,
            .ground_friction = 0.91,
            .air_friction = 0.98,
            .walk_speed = 4.3,
            .sprint_speed = 5.6,
            .sneak_speed = 1.3,
            .fly_speed = 10.8,
            .on_ground = false,
            .in_water = false,
            .is_flying = false,
            .is_sprinting = false,
            .is_sneaking = false,
        };
    }

    /// Update physics (call with fixed timestep, e.g., 60 Hz)
    pub fn update(self: *PlayerPhysics, world: *terrain.World, dt: f32) void {
        // Update AABB position
        self.updateAABB();

        // Apply gravity (unless flying)
        if (!self.is_flying) {
            self.velocity.y -= self.gravity * dt;
        }

        // Apply friction
        const friction = if (self.on_ground) self.ground_friction else self.air_friction;
        self.velocity.x *= friction;
        self.velocity.z *= friction;

        if (self.is_flying) {
            self.velocity.y *= 0.91; // Damping in flight
        }

        // Integrate velocity
        const movement = self.velocity.mul(dt);

        // Collision detection and response
        self.moveAndCollide(world, movement);

        // Update state
        self.updateAABB();
        self.checkGround(world);
        self.checkWater(world);
    }

    /// Move with collision detection
    fn moveAndCollide(self: *PlayerPhysics, world: *terrain.World, movement: math.Vec3) void {
        // Try to move in each axis separately for better collision response
        // X axis
        self.position.x += movement.x;
        self.updateAABB();
        if (self.checkCollision(world)) {
            self.position.x -= movement.x;
            self.velocity.x = 0;
        }

        // Y axis
        self.position.y += movement.y;
        self.updateAABB();
        if (self.checkCollision(world)) {
            self.position.y -= movement.y;
            self.velocity.y = 0;
        }

        // Z axis
        self.position.z += movement.z;
        self.updateAABB();
        if (self.checkCollision(world)) {
            self.position.z -= movement.z;
            self.velocity.z = 0;
        }
    }

    /// Check for collision with terrain
    fn checkCollision(self: *PlayerPhysics, world: *terrain.World) bool {
        const min = math.Vec3i.fromVec3(self.aabb.min);
        const max = math.Vec3i.fromVec3(self.aabb.max);

        // Check all blocks that might intersect the player AABB
        var x = min.x;
        while (x <= max.x) : (x += 1) {
            var y = min.y;
            while (y <= max.y) : (y += 1) {
                var z = min.z;
                while (z <= max.z) : (z += 1) {
                    const block = world.getBlockWorld(x, z, y) orelse continue;

                    if (block.isSolid()) {
                        const block_aabb = math.AABB.init(
                            math.Vec3.init(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z)),
                            math.Vec3.init(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(z + 1)),
                        );

                        if (self.aabb.intersects(block_aabb)) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Check if player is on the ground
    fn checkGround(self: *PlayerPhysics, world: *terrain.World) void {
        // Extend AABB slightly downward
        var ground_check = self.aabb;
        ground_check.min.y -= 0.1;

        const min = math.Vec3i.fromVec3(ground_check.min);
        const max = math.Vec3i.fromVec3(ground_check.max);

        var x = min.x;
        while (x <= max.x) : (x += 1) {
            var z = min.z;
            while (z <= max.z) : (z += 1) {
                const y = min.y;
                const block = world.getBlockWorld(x, z, y) orelse continue;

                if (block.isSolid()) {
                    self.on_ground = true;
                    return;
                }
            }
        }

        self.on_ground = false;
    }

    /// Check if player is in water
    fn checkWater(self: *PlayerPhysics, world: *terrain.World) void {
        const center = self.aabb.center();
        const center_block = math.Vec3i.fromVec3(center);

        const block = world.getBlockWorld(center_block.x, center_block.z, center_block.y) orelse {
            self.in_water = false;
            return;
        };

        self.in_water = block.block_type == .water;
    }

    /// Update AABB based on position
    fn updateAABB(self: *PlayerPhysics) void {
        self.aabb = math.AABB.fromCenter(
            self.position,
            math.Vec3.init(self.width / 2.0, self.height / 2.0, self.width / 2.0),
        );
    }

    /// Apply movement input
    pub fn applyMovementInput(self: *PlayerPhysics, forward: f32, strafe: f32, direction: math.Vec3, dt: f32) void {
        const speed = if (self.is_flying)
            self.fly_speed
        else if (self.is_sprinting)
            self.sprint_speed
        else if (self.is_sneaking)
            self.sneak_speed
        else
            self.walk_speed;

        // Calculate movement direction
        const right = direction.cross(math.Vec3.init(0, 1, 0)).normalize();
        const move_forward = if (self.is_flying) direction else math.Vec3.init(direction.x, 0, direction.z).normalize();

        const move_dir = move_forward.mul(forward).add(right.mul(strafe));

        if (move_dir.lengthSquared() > 0.001) {
            const normalized = move_dir.normalize();
            const acceleration = normalized.mul(speed * 20.0); // High acceleration

            if (self.is_flying) {
                // Direct velocity control in fly mode
                self.velocity.x = normalized.x * speed;
                self.velocity.z = normalized.z * speed;
            } else {
                // Acceleration-based on ground
                self.velocity.x += acceleration.x * dt;
                self.velocity.z += acceleration.z * dt;

                // Cap horizontal speed
                const horizontal_speed = @sqrt(self.velocity.x * self.velocity.x + self.velocity.z * self.velocity.z);
                if (horizontal_speed > speed) {
                    const scale = speed / horizontal_speed;
                    self.velocity.x *= scale;
                    self.velocity.z *= scale;
                }
            }
        }
    }

    /// Jump (if on ground or in water)
    pub fn jump(self: *PlayerPhysics) void {
        if (self.on_ground) {
            self.velocity.y = self.jump_velocity;
            self.on_ground = false;
        } else if (self.in_water) {
            self.velocity.y = self.jump_velocity * 0.5;
        }
    }

    /// Fly up (creative mode)
    pub fn flyUp(self: *PlayerPhysics) void {
        if (self.is_flying) {
            self.velocity.y = self.fly_speed;
        }
    }

    /// Fly down (creative mode)
    pub fn flyDown(self: *PlayerPhysics) void {
        if (self.is_flying) {
            self.velocity.y = -self.fly_speed;
        }
    }

    /// Toggle flying mode
    pub fn toggleFlying(self: *PlayerPhysics) void {
        self.is_flying = !self.is_flying;
        if (self.is_flying) {
            self.velocity.y = 0;
        }
    }

    /// Set sprinting
    pub fn setSprinting(self: *PlayerPhysics, sprinting: bool) void {
        self.is_sprinting = sprinting and !self.is_sneaking;
    }

    /// Set sneaking
    pub fn setSneaking(self: *PlayerPhysics, sneaking: bool) void {
        self.is_sneaking = sneaking;
        if (sneaking) {
            self.is_sprinting = false;
        }
    }

    /// Get eye position (for camera)
    pub fn getEyePosition(self: *const PlayerPhysics) math.Vec3 {
        return math.Vec3.init(
            self.position.x,
            self.position.y + self.eye_height,
            self.position.z,
        );
    }

    /// Get feet position
    pub fn getFeetPosition(self: *const PlayerPhysics) math.Vec3 {
        return self.position;
    }

    /// Teleport to position
    pub fn teleport(self: *PlayerPhysics, position: math.Vec3) void {
        self.position = position;
        self.velocity = math.Vec3.zero();
        self.updateAABB();
    }
};

/// Step assist - automatically climb single blocks
pub fn canStepUp(player: *PlayerPhysics, world: *terrain.World) bool {
    _ = player;
    _ = world;
    // TODO: Implement step-up detection
    return false;
}

test "player physics initialization" {
    const player = PlayerPhysics.init(math.Vec3.init(0, 70, 0));

    try std.testing.expectEqual(@as(f32, 0), player.position.x);
    try std.testing.expectEqual(@as(f32, 70), player.position.y);
    try std.testing.expectEqual(@as(f32, 0), player.position.z);
    try std.testing.expect(!player.on_ground);
}

test "player jump" {
    var player = PlayerPhysics.init(math.Vec3.init(0, 70, 0));
    player.on_ground = true;

    player.jump();

    try std.testing.expect(player.velocity.y > 0);
    try std.testing.expect(!player.on_ground);
}

test "player flying" {
    var player = PlayerPhysics.init(math.Vec3.init(0, 70, 0));

    try std.testing.expect(!player.is_flying);

    player.toggleFlying();
    try std.testing.expect(player.is_flying);

    player.toggleFlying();
    try std.testing.expect(!player.is_flying);
}
