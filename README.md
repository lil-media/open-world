# Open World Game

A Zig-based open world game with terrain building and manipulation capabilities.

## Features

- Chunk-based terrain system (16x16x256 blocks per chunk)
- Multiple block types (air, dirt, grass, stone, water, sand)
- Terrain generation with height-based world generation
- Terrain manipulation tools:
  - Dig: Remove blocks
  - Place: Add blocks
  - Flatten: Smooth terrain to a specific height
  - Raise: Elevate terrain
  - Lower: Depress terrain
- Configurable brush sizes for terrain editing

## Project Structure

```
open-world/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig          # Entry point and game loop
│   ├── terrain.zig       # Terrain system (blocks, chunks, world)
│   └── terrain_editor.zig # Terrain manipulation tools
└── README.md
```

## Requirements

- Zig 0.15.0 or later

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

### Terrain Editor

The terrain editor provides various tools for manipulating the world:

- **dig()**: Remove blocks in a spherical brush pattern
- **place()**: Add blocks in a spherical brush pattern
- **flatten()**: Smooth terrain to a target height in a circular area
- **raise()**: Elevate terrain by adding blocks
- **lower()**: Depress terrain by removing top blocks

All tools support configurable brush sizes (1-10 blocks).

## Next Steps

- [ ] Add window and rendering system (raylib, SDL, or custom OpenGL)
- [ ] Implement camera controls for world navigation
- [ ] Add Perlin/Simplex noise for better terrain generation
- [ ] Implement mesh generation for efficient rendering
- [ ] Add player physics and collision detection
- [ ] Implement saving/loading world data
- [ ] Add biomes and more diverse terrain features
- [ ] Optimize chunk loading/unloading based on player position

## License

MIT
