# Next Steps: Metal Rendering Integration

## Current Status ✅

**Phase 1 Foundation: 60% Complete**

All core systems are working:
- ✅ Terrain generation (8 biomes, caves)
- ✅ Chunk streaming (76 chunks in demo)
- ✅ Player physics (movement, collision)
- ✅ Camera system (first-person, free-cam)
- ✅ Greedy meshing (optimized rendering)
- ✅ Math utilities (Vec3, AABB, Mat4, Frustum)

**Demo Output:**
```bash
$ zig build run
# Loads 76 chunks, simulates 180 frames, shows biome distribution
```

---

## Immediate Next Steps (Week 3)

### Option A: Quick Wins (Recommended Start)

Before diving into Metal, solidify what we have:

#### 1. Enhanced Demo (1-2 days)
- [ ] Add more biome variety to demo output
- [ ] Show chunk mesh statistics (vertices, triangles)
- [ ] Display memory usage tracking
- [ ] Add FPS counter simulation
- [ ] Visualize chunk loading pattern

**Why:** Validates current systems, provides baseline metrics

#### 2. Input System Foundation (1 day)
```zig
// src/platform/input.zig
pub const Input = struct {
    keys: [512]bool,
    mouse_delta: Vec2,
    mouse_buttons: [8]bool,

    pub fn isKeyPressed(self: Input, key: Key) bool;
    pub fn getMouseDelta(self: Input) Vec2;
};
```

**Why:** Needed for player controls regardless of rendering

#### 3. Game State Manager (1 day)
```zig
// src/game/state.zig
pub const GameState = struct {
    world: *ChunkStreamingManager,
    player: *PlayerPhysics,
    camera: *Camera,
    paused: bool,
    debug_mode: bool,
};
```

**Why:** Organizes systems for easier Metal integration

### Option B: Metal Integration (Week 3-4)

**Prerequisites:**
- macOS 12.0+
- Xcode Command Line Tools
- Zig 0.15.1

#### Phase 1: Window & Context (3-4 days)

**Approach 1: SDL2 (Simpler)**
```bash
# Add SDL2 via Homebrew
brew install sdl2

# Or bundle with zig-gamedev
```

Benefits:
- Simple cross-platform windowing
- Metal view creation helper
- Input handling included
- Many examples available

**Approach 2: Mach Engine (More features)**
```bash
# Add to build.zig.zon (uncomment dependencies)
# Mach handles everything: window, input, Metal setup
```

Benefits:
- Integrated solution
- WebGPU abstraction
- Cross-platform from day one
- Active development

**Approach 3: Native macOS (Maximum control)**
```zig
// Direct Cocoa/AppKit integration
// More complex but full Metal access
```

Benefits:
- Zero dependencies
- Full Apple Silicon optimization
- Direct Metal 4 features
- Maximum performance

**Recommendation:** Start with **SDL2** for rapid prototyping, then add **Mach** later for cross-platform.

#### Phase 2: First Triangle (2-3 days)

Goal: Render a single colored triangle

```zig
// Minimal rendering pipeline:
1. Create Metal device
2. Create command queue
3. Compile simple shader
4. Create render pipeline
5. Draw triangle in render loop
```

Success criteria:
- Window opens
- Triangle renders
- 60 FPS achieved
- No memory leaks

#### Phase 3: Camera Integration (2 days)

```zig
// Use existing Camera system
const view_proj = camera.getViewProjectionMatrix();

// Upload to GPU as uniform buffer
device.makeBuffer(bytes: &view_proj, options: .storageModeShared);
```

#### Phase 4: Chunk Rendering (3-4 days)

```zig
// For each loaded chunk:
1. Generate mesh (existing greedy mesher)
2. Upload vertices to GPU buffer
3. Upload indices to GPU buffer
4. Draw with view-projection matrix
```

---

## Metal Integration Checklist

### Week 3: Foundation
- [ ] Choose rendering library (SDL2 vs Mach vs Native)
- [ ] Create window with Metal view
- [ ] Initialize Metal device and command queue
- [ ] Compile and load simple shader
- [ ] Render colored triangle
- [ ] Add FPS counter
- [ ] Profile memory usage

### Week 4: Chunk Rendering
- [ ] Upload chunk mesh to GPU
- [ ] Integrate existing camera matrices
- [ ] Render single chunk
- [ ] Render multiple chunks (4-16)
- [ ] Add simple directional lighting
- [ ] Implement basic frustum culling
- [ ] Reach 60 FPS with 16 chunks

### Week 5: Optimization
- [ ] Implement full frustum culling
- [ ] Add LOD system (4 tiers)
- [ ] Batch chunk rendering
- [ ] Add texture atlas
- [ ] Optimize shader
- [ ] Profile with Instruments
- [ ] Reach 60 FPS with 64+ chunks

---

## Code Structure for Metal Integration

```
src/
├── main.zig                    # Updated with render loop
├── platform/
│   ├── window.zig              # NEW: Window creation
│   ├── input.zig               # NEW: Input handling
│   └── metal_context.zig       # NEW: Metal setup
├── rendering/
│   ├── pipeline.zig            # NEW: Render pipeline
│   ├── chunk_renderer.zig      # NEW: Chunk → GPU
│   ├── camera.zig              # EXISTING: Already done
│   ├── mesh.zig                # EXISTING: Already done
│   └── shaders/
│       ├── terrain.metal       # NEW: Vertex/fragment shaders
│       └── common.metal        # NEW: Shared functions
├── game/
│   ├── state.zig               # NEW: Game state manager
│   └── update.zig              # NEW: Game loop logic
└── ... existing systems ...
```

---

## Alternative: Text-Based Rendering First

**Before Metal, validate with terminal output:**

```zig
// Create ASCII mini-map of loaded chunks
pub fn renderTextMap(manager: *ChunkStreamingManager, player_pos: Vec3) void {
    const player_chunk = ChunkPos.fromWorldPos(
        @intFromFloat(player_pos.x),
        @intFromFloat(player_pos.z),
    );

    // Print 20x20 grid
    for (-10..10) |dz| {
        for (-10..10) |dx| {
            const pos = ChunkPos.init(
                player_chunk.x + @as(i32, @intCast(dx)),
                player_chunk.z + @as(i32, @intCast(dz)),
            );

            if (dx == 0 and dz == 0) {
                print("@", .{}); // Player
            } else if (manager.getChunk(pos) != null) {
                print("█", .{}); // Loaded chunk
            } else {
                print("·", .{}); // Unloaded
            }
        }
        print("\n", .{});
    }
}
```

**Benefits:**
- Visualizes chunk loading immediately
- No graphics dependencies
- Easy to debug
- Can run in CI/tests

---

## Recommended Path Forward

### Week 3: Prepare for Graphics

**Day 1-2: Enhanced Demo**
- Add text-based chunk visualization
- Show mesh statistics
- Memory profiling
- Benchmark terrain generation

**Day 3-4: Input & State**
- Create Input system stub
- Game state manager
- Update loop refactoring

**Day 5-7: Metal Setup**
- Choose library (SDL2 recommended)
- Create window
- First triangle
- FPS counter

### Week 4: First Rendering

**Day 1-3: Single Chunk**
- Upload mesh to GPU
- Camera integration
- Render with lighting

**Day 4-7: Multiple Chunks**
- Render 16 chunks
- Basic culling
- Performance tuning

### Week 5: Production Quality

- LOD system
- Full frustum culling
- 60 FPS with 64+ chunks
- Texture atlas
- Sky rendering

---

## Quick Start Commands

```bash
# Current working demo
zig build run

# Run all tests
zig build test

# Build release (when ready)
zig build -Doptimize=ReleaseFast

# Profile memory (when Metal integrated)
leaks --atExit -- ./zig-out/bin/open-world

# Profile performance (when Metal integrated)
instruments -t "Time Profiler" ./zig-out/bin/open-world
```

---

## Decision Point

**Choose your next step:**

**A. Quick wins first** → Enhanced demo + text visualization
- ✅ Solidifies foundation
- ✅ No new dependencies
- ✅ Immediate results
- ✅ Better metrics before graphics

**B. Graphics now** → SDL2 + Metal integration
- ✅ Visual progress
- ✅ More motivating
- ✅ Start learning Metal
- ⚠️  More complexity

**Hybrid: Both!**
1. Add text visualization (1 day)
2. Start Metal with SDL2 (rest of week)
3. Best of both worlds

---

**My Recommendation:** Hybrid approach
- Spend Day 1 on enhanced text demo
- Days 2-7 on Metal integration
- This gives immediate visual feedback AND validates systems

What would you like to proceed with? 🚀
