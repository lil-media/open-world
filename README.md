# Open World Game

A high-performance voxel-based open world building game built with Zig, optimized for macOS and Apple Silicon with Metal graphics, and multiplayer support.

## Features

### Current (Phase 1 - ⚡ 70% Complete)

**✅ Rendering & Graphics**
- Metal 4 graphics pipeline (SDL2 + Objective-C bridge)
- Greedy meshing algorithm with GPU upload
- Texture atlas system (procedural generation)
- Vertex/index buffer management with caching
- Frustum culling (90% chunk reduction)
- Day/night cycle with dynamic lighting
- Fog and atmospheric effects
- Real-time shader-based rendering

**✅ Terrain Generation**
- 3D Simplex noise with Fractional Brownian Motion
- 8 distinct biomes (plains, forest, desert, mountains, ocean, beach, tundra, savanna)
- 3D cave systems using density-based generation
- Realistic terrain features with domain warping
- Chunk-based world (16x16x256 blocks)
- Priority-based chunk streaming

**✅ Player & Camera**
- First-person and free-cam modes
- Mouse/keyboard input handling (SDL2)
- Player physics (AABB collision, gravity, movement)
- Smooth camera controls with yaw/pitch
- Sprint, jump, fly modes

**✅ Debug & Tools**
- F3-style debug overlay (FPS, position, chunks, triangles)
- Terrain editing (dig, place, flatten, raise/lower)
- Performance metrics display

**📊 Performance (M3 Pro)**
- 114 FPS @ 1280x720 (exceeds 60 FPS target)
- 10/110 chunks rendered (90% frustum culling)
- 444K triangles/frame (77% reduction from culling)

### Planned (Next Up)
- Asynchronous chunk generation (fix startup stutter)
- Metal Performance HUD integration
- Block interaction (ray casting, breaking/placing)
- Save/Load system for world persistence
- Advanced lighting (block lights, smooth lighting)
- Inventory and crafting systems
- Weather simulation and temperature
- Multiplayer support (client-server)

📖 See [ROADMAP.md](ROADMAP.md) for detailed development plan and current status.
🤖 See [AGENTS.md](AGENTS.md) for AI agent workflow and maintenance guidelines.

## Project Structure

```
open-world/
├── build.zig                      # Build configuration
├── src/
│   ├── main.zig                   # Entry point and game loop
│   ├── terrain/
│   │   ├── terrain.zig            # Chunk & block system
│   │   ├── generator.zig          # Procedural terrain generation
│   │   └── editor.zig             # Terrain manipulation tools
│   ├── utils/
│   │   ├── math.zig               # Math utilities (Vec3, Mat4, AABB)
│   │   └── noise.zig              # Simplex noise, FBM, domain warping
│   ├── platform/                  # (Planned) macOS/Metal integration
│   ├── rendering/                 # (Planned) Rendering pipeline
│   ├── physics/                   # (Planned) Collision & player physics
│   ├── game/                      # (Planned) Inventory, crafting, entities
│   └── network/                   # (Planned) Multiplayer networking
├── README.md                      # This file
└── ROADMAP.md                     # Development roadmap
```

## Requirements

- **Zig 0.15.0+** (tested on 0.15.1)
- **macOS 12.0+** (for Metal support)
- **Apple Silicon** (M1/M2/M3) recommended
  - Intel Macs with Metal support also work but not optimized

## Building

```bash
zig build
```

## Running

```bash
zig build run
```

## Testing

```bash
zig build test
```

## Architecture

### Terrain System

- **Block**: Individual voxel with a type (air, dirt, grass, stone, water, sand)
- **Chunk**: 16x16x256 collection of blocks representing a section of the world
- **World**: Collection of chunks with methods for accessing and modifying terrain
- **TerrainGenerator**: Advanced procedural generation with biomes and caves
  - Uses 3D Simplex noise for realistic terrain
  - Supports 8 biomes with distinct characteristics
  - Generates caves using density-based 3D carving

### Terrain Editor

The terrain editor provides various tools for manipulating the world:

- **dig()**: Remove blocks in a spherical brush pattern
- **place()**: Add blocks in a spherical brush pattern
- **flatten()**: Smooth terrain to a target height in a circular area
- **raise()**: Elevate terrain by adding blocks
- **lower()**: Depress terrain by removing top blocks

All tools support configurable brush sizes (1-10 blocks).

### Math Utilities

- **Vec3/Vec3i**: 3D vectors for positions and directions
- **AABB**: Axis-aligned bounding boxes for collision detection
- **Mat4**: 4x4 matrices for transformations and projections
- **Frustum**: View frustum for efficient culling

### Noise Generation

- **SimplexNoise**: Fast 3D noise with fewer artifacts than Perlin
- **FBM**: Fractional Brownian Motion for layered detail
- **DomainWarp**: Creates organic, flowing terrain features

## Performance Targets

- **60 FPS** @ 1080p with 16 chunk view distance (M1)
- **120 FPS** @ 1080p with 16 chunk view distance (M3+)
- **<4GB RAM** for typical gameplay
- **<100ms** chunk generation time

## Development Status

**Current Phase:** Phase 1 - Foundation (40% complete)

✅ Completed:
- Project structure and module organization
- Math utilities (vectors, matrices, collision)
- Simplex noise and FBM terrain generation
- Biome system with 8 biomes
- Basic terrain editor

🏗️ In Progress:
- Greedy meshing algorithm
- Metal rendering integration

📋 Next:
- Camera system
- Asynchronous chunk streaming
- Player physics

See [ROADMAP.md](ROADMAP.md) for complete development plan.

## Contributing

This is currently a solo development project, but contributions are welcome once the core architecture is stable.

## License

MIT
