# Technical Architecture

## Overview

This document describes the technical architecture of the open world game, focusing on high-performance design for macOS/Apple Silicon and multiplayer networking.

## Core Principles

1. **Performance First**: Target 60 FPS on M1 Macs at 1080p
2. **Memory Efficiency**: Keep RAM usage under 4GB for typical gameplay
3. **Modularity**: Clear separation of concerns between systems
4. **Testability**: All core systems have unit tests
5. **Apple Silicon Optimization**: Leverage Metal 4, unified memory, SIMD

## System Architecture

### 1. Rendering Pipeline (Metal 4)

#### Graphics Stack
```
Application Layer (Zig)
    ↓
Metal Abstraction (Mach Engine or custom)
    ↓
Metal 4 API
    ↓
Apple Silicon GPU
```

#### Rendering Flow
1. **Culling Phase**
   - Frustum culling of chunks outside view
   - LOD selection based on distance
   - Occlusion culling (future)

2. **Mesh Generation**
   - Greedy meshing to reduce vertex count
   - Face culling (don't render internal faces)
   - Mesh caching for unmodified chunks
   - Async generation on background threads

3. **Rendering Phase**
   - Indirect draw calls (GPU-driven)
   - Instanced rendering for similar blocks
   - Tile-based deferred rendering
   - Forward+ for transparency (water)

4. **Post-Processing**
   - MetalFX upscaling for performance
   - Bloom for bright blocks
   - FXAA or SMAA anti-aliasing
   - Color grading for atmosphere

#### Metal 4 Optimizations

**Unified Command Encoder**
```zig
// Single command encoder for all work
const encoder = commandBuffer.makeComputeCommandEncoder();
encoder.setComputePipelineState(chunkMeshPipeline);
encoder.dispatchThreads(threadgroups, threadsPerGroup);
encoder.setRenderPipelineState(terrainPipeline);
encoder.drawIndexedPrimitives(...);
encoder.end();
```

**GPU-Driven Rendering**
```zig
// Indirect draw buffer on GPU
struct DrawCommand {
    indexCount: u32,
    instanceCount: u32,
    firstIndex: u32,
    baseVertex: i32,
    baseInstance: u32,
}

// GPU culling shader populates draw commands
// CPU never touches individual draw calls
```

**Unified Memory Architecture**
```zig
// Zero-copy between CPU and GPU on Apple Silicon
const buffer = device.makeBuffer(
    .{ .storageMode = .shared } // CPU and GPU share
);
// Modify on CPU, use immediately on GPU
```

### 2. Terrain System

#### Chunk Architecture

**Chunk Structure**
```zig
pub const Chunk = struct {
    // Block data (16 x 16 x 256 = 65,536 blocks)
    blocks: [16][16][256]Block,

    // Metadata
    x: i32,              // Chunk X coordinate
    z: i32,              // Chunk Z coordinate
    modified: bool,      // Needs remeshing?

    // Cached mesh data
    mesh: ?ChunkMesh,
    lod_meshes: [4]?ChunkMesh, // LOD levels

    // Memory: ~65KB per chunk
};
```

**LOD System**
- LOD 0 (0-64m): Full detail, all blocks rendered
- LOD 1 (64-128m): 2x reduction, merge similar blocks
- LOD 2 (128-256m): 4x reduction, simplified geometry
- LOD 3 (256m+): Impostor (single quad per chunk)

#### Terrain Generation Pipeline

```
1. Request Chunk (x, z)
        ↓
2. Check Cache
        ↓ (miss)
3. Background Thread Pool
        ↓
4. Generate Terrain
   - Sample biome noise
   - Generate 3D density
   - Place blocks
        ↓
5. Post-Processing
   - Add vegetation
   - Place ores
   - Carve caves
        ↓
6. Return to Main Thread
        ↓
7. Generate Mesh
        ↓
8. Upload to GPU
        ↓
9. Ready to Render
```

**Noise Sampling Strategy**
```zig
// Multi-octave sampling for detail
const terrain_height =
    continent_noise.sample2D(x * 0.0005, z * 0.0005) * 80.0 +  // Large features
    erosion_noise.sample2D(x * 0.002, z * 0.002) * 20.0 +       // Medium detail
    detail_noise.sample2D(x * 0.01, z * 0.01) * 2.0 +           // Fine detail
    biome.base_height;
```

### 3. Chunk Streaming

#### Ring Buffer Design

```
Player Position: (0, 0)
View Distance: 8 chunks

[Load Zone: 8 chunk radius]
[Keep Zone: 10 chunk radius]  (hysteresis)
[Unload Zone: 12+ chunk radius]

As player moves:
- Load chunks entering Load Zone
- Keep chunks in Keep Zone (even if outside Load)
- Unload chunks beyond Unload Zone
```

#### Priority Queue

```zig
pub const ChunkPriority = struct {
    distance: f32,          // Distance from player
    direction: f32,         // Alignment with player facing
    modified: bool,         // Has unsaved changes?

    fn priority(self: ChunkPriority) f32 {
        return self.distance * 0.7 +
               self.direction * 0.2 +
               (if (self.modified) -100 else 0); // High priority if modified
    }
};
```

**Thread Pool Architecture**
```
Main Thread
    ↓
Chunk Manager
    ↓
[Thread Pool: N Workers]
    Worker 1: Generate Chunk
    Worker 2: Generate Mesh
    Worker 3: Compress for Save
    Worker 4: Load from Disk
    ...
    ↓
Results Queue → Main Thread
```

### 4. Physics & Collision

#### AABB Collision Detection

```zig
// Player AABB (0.6 x 1.8 x 0.6 blocks)
const player_aabb = AABB.fromCenter(
    player.position,
    Vec3.init(0.3, 0.9, 0.3)
);

// Check collision with nearby blocks
const min_block = Vec3i.fromVec3(player_aabb.min);
const max_block = Vec3i.fromVec3(player_aabb.max);

for (min_block.x..max_block.x) |bx| {
    for (min_block.y..max_block.y) |by| {
        for (min_block.z..max_block.z) |bz| {
            const block = world.getBlock(bx, by, bz);
            if (block.isSolid()) {
                const block_aabb = AABB.init(
                    Vec3.init(bx, by, bz),
                    Vec3.init(bx + 1, by + 1, bz + 1)
                );

                if (player_aabb.intersects(block_aabb)) {
                    // Resolve collision
                    resolveCollision(&player, block_aabb);
                }
            }
        }
    }
}
```

#### Physics Integration

```zig
// Fixed timestep (60 Hz)
const FIXED_DT: f32 = 1.0 / 60.0;

pub fn update(dt: f32) void {
    accumulator += dt;

    while (accumulator >= FIXED_DT) {
        // Apply forces
        player.velocity.y -= GRAVITY * FIXED_DT;

        // Integrate position
        player.position = player.position.add(
            player.velocity.mul(FIXED_DT)
        );

        // Collision detection & response
        resolveTerrainCollision(&player);

        accumulator -= FIXED_DT;
    }

    // Interpolation for smooth rendering
    const alpha = accumulator / FIXED_DT;
    render_position = lerp(prev_position, player.position, alpha);
}
```

### 5. Lighting System

#### Light Propagation

**Sunlight (Top-Down)**
```zig
// Sunlight value: 0 (dark) to 15 (full)
pub fn propagateSunlight(chunk: *Chunk) void {
    for (0..16) |x| {
        for (0..16) |z| {
            var light: u8 = 15; // Start at top with full sunlight

            for (0..256) |y_down| {
                const y = 255 - y_down;
                const block = chunk.getBlock(x, z, y);

                if (block.isSolid()) {
                    light = 0; // Blocked
                } else {
                    chunk.setSunlight(x, z, y, light);
                }

                // Attenuate through transparent blocks
                if (block.type == .water) {
                    light = @max(0, light - 2);
                }
            }
        }
    }
}
```

**Block Light (Flood Fill)**
```zig
// BFS for light propagation from sources
pub fn propagateBlockLight(world: *World, source: Vec3i, intensity: u8) void {
    var queue = Queue(LightNode).init(allocator);
    defer queue.deinit();

    queue.push(.{ .pos = source, .light = intensity });

    while (queue.pop()) |node| {
        if (node.light == 0) continue;

        const current = world.getLight(node.pos);
        if (current >= node.light) continue;

        world.setLight(node.pos, node.light);

        // Propagate to neighbors with attenuation
        for (directions) |dir| {
            const neighbor = node.pos.add(dir);
            if (!world.getBlock(neighbor).isSolid()) {
                queue.push(.{
                    .pos = neighbor,
                    .light = node.light - 1
                });
            }
        }
    }
}
```

#### Smooth Lighting

```zig
// Average light from surrounding blocks for smooth gradients
pub fn getSmoothLight(world: *World, pos: Vec3, normal: Vec3) f32 {
    var total: f32 = 0;
    var count: u32 = 0;

    // Sample 3x3 grid on face
    for (-1..2) |dx| {
        for (-1..2) |dy| {
            const sample_pos = pos.add(
                tangent.mul(dx).add(bitangent.mul(dy))
            );
            const light = world.getLight(Vec3i.fromVec3(sample_pos));
            total += @as(f32, @floatFromInt(light)) / 15.0;
            count += 1;
        }
    }

    return total / @as(f32, @floatFromInt(count));
}
```

### 6. Network Architecture (Multiplayer)

#### Client-Server Model

```
[Client 1] ←→ [Server] ←→ [Client 2]
              ↓
         [World State]
         [Entity Manager]
         [Chunk Manager]
```

#### Protocol Design

**Packet Structure**
```zig
pub const Packet = struct {
    header: PacketHeader,
    payload: []const u8,
};

pub const PacketHeader = struct {
    packet_id: u32,        // Sequence number
    ack: u32,              // Last received packet
    ack_bits: u32,         // Received packet history (32 bits)
    packet_type: u8,       // Type of packet
    payload_size: u16,     // Size of payload
};
```

**Packet Types**
1. **Player Update** (60 Hz)
   - Position, velocity, rotation
   - Input state (WASD, jump, etc.)
   - Compressed with delta encoding

2. **Block Update** (on change)
   - Block position (24 bits: 8-8-8)
   - Block type (8 bits)
   - Batched updates (up to 256 per packet)

3. **Chunk Data** (on request)
   - Compressed chunk (zstd)
   - RLE encoding for repeated blocks
   - ~10-50 KB per chunk

4. **Entity Update** (30 Hz)
   - Entity ID, type, position
   - Interpolation data

#### Client Prediction & Reconciliation

```zig
// Client side
pub fn clientUpdate(input: Input, dt: f32) void {
    // 1. Store input with sequence number
    input_history.push(.{ .seq = next_seq, .input = input });
    next_seq += 1;

    // 2. Predict movement locally
    predictMovement(input, dt);

    // 3. Send input to server
    sendInputPacket(input, next_seq);
}

pub fn onServerState(state: PlayerState) void {
    // 4. Server responded with authoritative state
    const last_acked = state.last_processed_input;

    // 5. Rewind to server state
    player.position = state.position;
    player.velocity = state.velocity;

    // 6. Replay unacknowledged inputs
    for (input_history.items) |input| {
        if (input.seq > last_acked) {
            predictMovement(input.input, FIXED_DT);
        }
    }

    // 7. Clean up old inputs
    input_history.removeUpTo(last_acked);
}
```

#### Entity Interpolation

```zig
// Smooth other players' movement
pub fn interpolateEntity(entity: *Entity, dt: f32) void {
    // Buffer incoming states
    if (entity.state_buffer.len >= 2) {
        const t0 = entity.state_buffer[0];
        const t1 = entity.state_buffer[1];

        // Interpolate between t0 and t1
        const render_time = current_time - INTERPOLATION_DELAY;

        if (render_time >= t1.timestamp) {
            // Move to next pair
            entity.state_buffer.removeFirst();
        }

        const alpha = (render_time - t0.timestamp) /
                     (t1.timestamp - t0.timestamp);

        entity.render_position = lerp(t0.position, t1.position, alpha);
        entity.render_rotation = slerp(t0.rotation, t1.rotation, alpha);
    }
}
```

### 7. Memory Management

#### Chunk Memory Pool

```zig
pub const ChunkPool = struct {
    chunks: [MAX_POOLED_CHUNKS]Chunk,
    free_list: std.ArrayList(usize),

    pub fn acquire(self: *ChunkPool) !*Chunk {
        const index = self.free_list.popOrNull() orelse
            return error.OutOfChunks;
        return &self.chunks[index];
    }

    pub fn release(self: *ChunkPool, chunk: *Chunk) void {
        const index = (@intFromPtr(chunk) - @intFromPtr(&self.chunks[0])) /
                     @sizeOf(Chunk);
        chunk.reset();
        self.free_list.append(index);
    }
};
```

#### Mesh Caching

```zig
pub const MeshCache = struct {
    cache: std.HashMap(ChunkPos, ChunkMesh, ...),

    pub fn getOrGenerate(self: *MeshCache, chunk: *Chunk) !ChunkMesh {
        if (self.cache.get(chunk.getPos())) |mesh| {
            if (!chunk.modified) return mesh;
        }

        // Generate new mesh
        const mesh = try generateGreedyMesh(chunk);
        try self.cache.put(chunk.getPos(), mesh);
        chunk.modified = false;

        return mesh;
    }
};
```

### 8. Save/Load System

#### Chunk Serialization

```zig
pub fn serializeChunk(chunk: *Chunk, writer: anytype) !void {
    // 1. Write header
    try writer.writeInt(u32, CHUNK_VERSION, .little);
    try writer.writeInt(i32, chunk.x, .little);
    try writer.writeInt(i32, chunk.z, .little);

    // 2. RLE compress block data
    var count: u16 = 1;
    var current = chunk.blocks[0][0][0];

    for (chunk.blocks) |x_layer| {
        for (x_layer) |z_column| {
            for (z_column) |block| {
                if (block.type == current.type and count < 65535) {
                    count += 1;
                } else {
                    // Write run
                    try writer.writeInt(u8, current.type, .little);
                    try writer.writeInt(u16, count, .little);
                    current = block;
                    count = 1;
                }
            }
        }
    }

    // Write final run
    try writer.writeInt(u8, current.type, .little);
    try writer.writeInt(u16, count, .little);
}
```

#### Region File Format

```
Region File (32x32 chunks)
├── Header (8 KB)
│   ├── Chunk Locations [1024 x 4 bytes]
│   └── Chunk Timestamps [1024 x 4 bytes]
└── Chunk Data (compressed)
    ├── Chunk (0, 0) [compressed]
    ├── Chunk (1, 0) [compressed]
    └── ...
```

## Performance Optimizations

### Apple Silicon Specific

1. **SIMD Vectorization**
```zig
// Use Zig's SIMD for noise generation
const Vec4f = @Vector(4, f32);

pub fn sample4(noise: *SimplexNoise, positions: [4]Vec3) Vec4f {
    const x = Vec4f{ positions[0].x, positions[1].x, positions[2].x, positions[3].x };
    const y = Vec4f{ positions[0].y, positions[1].y, positions[2].y, positions[3].y };
    const z = Vec4f{ positions[0].z, positions[1].z, positions[2].z, positions[3].z };

    // Process 4 samples in parallel
    return sampleSIMD(noise, x, y, z);
}
```

2. **Metal Async Compute**
```swift
// Use async compute for chunk meshing during rendering
let meshEncoder = commandBuffer.makeComputeCommandEncoder();
meshEncoder.setComputePipelineState(chunkMeshPipeline);
meshEncoder.dispatchThreads(...);
meshEncoder.end();

// Rendering can happen concurrently
let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor);
// ...
```

3. **Unified Memory Zero-Copy**
```zig
// Map GPU buffer directly to CPU memory
const shared_buffer = device.makeBuffer(
    bytes: null,
    length: size,
    options: .storageModeShared
);

// CPU writes directly to GPU-visible memory
const ptr = @as([*]Vertex, @ptrCast(shared_buffer.contents()));
generateMeshDirect(chunk, ptr);

// No upload needed - GPU can read immediately
```

### Profiling & Metrics

**Performance Counters**
```zig
pub const PerfCounters = struct {
    frame_time: f32,
    render_time: f32,
    update_time: f32,

    chunks_rendered: u32,
    chunks_meshed: u32,
    chunks_loaded: u32,

    triangles_rendered: u64,
    draw_calls: u32,

    memory_used: u64,
    gpu_memory_used: u64,
};
```

**Debug UI (F3)**
```
FPS: 60 (16.7ms)
Pos: (123.4, 67.0, -45.2)
Chunk: (7, -3)
Biome: Forest

Render: 8.2ms
  - Culling: 0.5ms
  - Meshing: 2.1ms
  - Draw: 5.6ms

Chunks: 256 rendered, 512 loaded
Triangles: 1.2M
Memory: 2.1 GB / 3.8 GB GPU

C: 256 | E: 0 | Ping: 42ms
```

## Testing Strategy

### Unit Tests
- Math operations (Vec3, Mat4, AABB)
- Noise generation (deterministic with fixed seeds)
- Terrain generation (verify biomes, heights)
- Collision detection
- Network packet serialization

### Integration Tests
- Chunk loading/unloading lifecycle
- World save/load round-trip
- Network client-server communication

### Performance Tests
- Chunk generation benchmark (target: <100ms)
- Mesh generation benchmark (target: <10ms)
- FPS stress test (1000+ chunks loaded)
- Memory leak detection

### Continuous Testing
```bash
# Run all tests
zig build test

# Run with leak detection
zig build test -Doptimize=Debug

# Profile performance
zig build test -Doptimize=ReleaseFast

# Generate coverage report
zig build test --enable-coverage
```

## Conclusion

This architecture prioritizes:
- **Performance**: Metal 4, async operations, efficient data structures
- **Scalability**: Chunk streaming, LOD, network-ready design
- **Maintainability**: Modular systems, comprehensive testing
- **Apple Silicon**: Full utilization of unified memory, SIMD, Metal 4

As development progresses, this document will be updated with implementation details and lessons learned.
