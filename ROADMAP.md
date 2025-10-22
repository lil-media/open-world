# Open World Game - Development Roadmap

## Project Vision
A high-performance voxel-based open world building game optimized for macOS and Apple Silicon, with support for multiplayer gameplay.

## Current Status (Phase 1 - Foundation)

### ✅ Completed
- [x] Project structure with modular organization
- [x] Math utilities (Vec3, AABB, Mat4, Frustum, Plane)
- [x] Simplex noise implementation with FBM support
- [x] Advanced terrain generator with biomes
- [x] Chunk-based world system (16x16x256)
- [x] Basic terrain editor tools
- [x] Unit tests for core systems
- [x] Greedy meshing algorithm (CPU-side generation)
- [x] Priority-based chunk streaming manager (synchronous implementation)
- [x] Camera system core (first-person + free-cam with smoothing)
- [x] Player physics foundation (AABB collision, movement, flying)
- [x] SDL2 + Metal bridge integration (Objective-C bridge working)
- [x] Metal render pipeline with shaders (vertex/fragment)
- [x] Texture atlas system (procedural generation)
- [x] GPU mesh upload and rendering (vertex/index buffers)
- [x] Chunk mesh caching with dirty flag tracking
- [x] Real-time input handling (keyboard/mouse via SDL)
- [x] Day/night cycle with dynamic lighting
- [x] Fog rendering and atmospheric effects
- [x] Frustum culling (90% chunk culling efficiency)
- [x] Debug UI (F3-style: FPS, position, chunk stats, culling info)
- [x] Ray casting system (DDA algorithm for block selection)
- [x] Block breaking/placing with mouse input (left/right click)
- [x] Collision checking for block placement
- [x] Visual block selection outline (white wireframe cube)
- [x] Async chunk generation (dedicated worker thread, 120 FPS during load)
- [x] Metal Performance HUD integration (enable via `MTL_HUD_ENABLED=1` before launch)
- [x] Fix segfault during async chunk cleanup (race condition resolved)
- [x] Debug visualization modes (F4 to cycle: Normal/Wireframe)
- [x] Cursor lock/unlock (ESC to toggle, ESC again to quit)
- [x] Incremental mesh generation (3 chunks/frame, eliminates startup stutter)

### 🏗️ In Progress
- [ ] Performance profiling and optimization

### 📋 Next Up
- [ ] Multi-block selection and copy/paste tools
- [ ] Save/Load system for world persistence
- [ ] Environmental simulation design pass (weather, fluids, temperature)

## Phase Breakdown

### Phase 1: Graphics & Rendering Foundation (Weeks 1-4)

#### Week 1-2: Core Rendering ✅ COMPLETE
- [x] **Metal Integration**
  - [x] Decide on approach (SDL2 window + custom Metal bridge)
  - [x] Create basic window with event loop
  - [x] Present clear-only frame via Metal command buffer
  - [x] Compile and load Metal shader library from Zig build
  - [x] Create render pipeline and depth stencil state
  - [x] Implement swap chain and frame synchronization hooks

- [x] **Voxel Rendering Pipeline**
  - [x] Implement greedy meshing algorithm (CPU-side)
  - [x] Upload chunk meshes to Metal vertex/index buffers
  - [x] Implement mesh cache with dirty flag tracking
  - [x] Wire up shader pipeline (`shaders/chunk.metal`) for world rendering
  - [x] Implement texture atlas sampling (per-block UVs)

#### Week 3-4: Camera & Optimization ⚡ IN PROGRESS
- [x] **Camera System**
  - [x] First-person camera math with yaw/pitch controls
  - [x] Free-cam mode for creative building
  - [x] Smooth interpolation helper (SmoothCamera)
  - [x] Integrate mouse/keyboard input events (SDL)
  - [x] Hook camera updates to player physics step

- [ ] **Rendering Optimization**
  - [x] Frustum culling implementation (90% efficiency)
  - [x] Chunk mesh caching
  - [x] Dynamic lighting and sky colour pipeline
  - [ ] Async mesh generation (background threading)
  - [ ] GPU-driven indirect rendering
  - [ ] 4-tier LOD system (0-64m, 64-128m, 128-256m, 256m+)

**Performance Target:** 60 FPS @ 1080p, 8-chunk render distance
**Current Performance:** ✅ 114 FPS @ 1280x720 on M3 Pro (exceeds target!)

**Recent Optimizations (2025-10-21):**
- **CRITICAL FIX:** Corrected Mat4 column-major multiplication in math.zig
  - Bug was treating matrices as row-major, causing incorrect transformations
  - All geometry was being placed outside viewport despite correct world positions
  - Fix enables proper rendering with full lighting and texture support
- **CRITICAL FIX:** Corrected east/west face vertex generation in mesh.zig
  - Bug: East/west faces used `height` parameter for both Y and Z expansion, ignoring `width`
  - This caused rectangular greedy-meshed quads to render as incorrect squares
  - Symptom: "some blocks will render sides but the block beside it doesn't"
  - Fix: Changed vertex calculations to use `width` for Z expansion, `height` for Y expansion
  - Result: All faces now render correctly with proper greedy meshing optimization
- Frustum culling: 90% chunk reduction (110 → 10 chunks rendered)
- Triangle count: 77% reduction (1.9M → 444K triangles/frame)
- FPS improvement: +15% (100 → 114 FPS)
- Terrain now fully visible with procedural generation, lighting, and fog effects

**Known Issues:**
- None! All major issues resolved.
  - ~~Async chunk cleanup segfault~~ - FIXED (2025-10-21)
  - ~~Thread.Pool CPU starvation~~ - RESOLVED (switched to dedicated worker thread)

**Recent Fixes (2025-10-21):**
- **Segfault during cleanup**: Fixed race condition where `unloadAll()` freed chunks while worker thread was still generating
  - Solution: `unloadAll()` now stops worker thread first before freeing any chunks
  - Verified stable across 10+ consecutive runs with various frame counts

---

### Phase 2: Advanced Terrain (Weeks 5-7) ✅ Core Systems Complete

#### Week 5: Noise & Generation ✅
- [x] 3D Simplex noise implementation
- [x] Fractional Brownian Motion (FBM)
- [x] Domain warping for organic features
- [x] Biome system (8 biomes)

#### Week 6: Terrain Features
- [ ] **Cave Systems**
  - [x] 3D cave generation using density functions
  - [ ] Stalactites and stalagmites
  - [ ] Underground lakes and lava pools

- [ ] **Ore Distribution**
  - [ ] Clustered ore generation
  - [ ] Different ores at different depths
  - [ ] Vein patterns using 3D noise

#### Week 7: Vegetation & Water
- [ ] **Vegetation**
  - [ ] Tree generation (multiple types per biome)
  - [ ] Grass and flower placement
  - [ ] Poisson disk sampling for natural distribution

- [ ] **Water Simulation**
  - [ ] Water block flow mechanics with pressure-based spreading
  - [ ] Source and flowing water states (rivers, waterfalls)
  - [ ] Water-terrain interaction (erosion, saturation)
  - [ ] Block state transitions: liquid ↔ ice based on temperature

---

### Phase 3: Chunk Streaming & World Management (Weeks 8-10)

#### Week 8: Asynchronous Loading
- [ ] **Thread Pool System**
  - [ ] Utilize all Apple Silicon CPU cores
  - [ ] Background chunk generation queue
  - [x] Priority-based loading with synchronous work queue

- [ ] **Streaming Architecture**
  - [ ] Ring buffer chunk loading (16x16 chunks)
  - [ ] Async mesh generation
  - [ ] Smooth unloading with hysteresis
  - [x] Memory pooling and chunk reuse

#### Week 9-10: Persistence
- [ ] **Save/Load System**
  - Chunk serialization format (compressed, versioned)
  - Region files (group 32x32 chunks)
  - Modified block tracking
  - Incremental saves

- [ ] **World Management**
  - World seed system
  - World metadata (name, creation date, etc.)
  - Multiple world support
  - World backup system

**Memory Target:** <4GB RAM for 32x32 loaded chunks

---

### Phase 4: Game Mechanics & Physics (Weeks 11-14)

#### Week 11: Player Controller
- [ ] **Physics System**
  - [x] AABB collision detection
  - [x] Gravity and velocity integration
  - [x] Walk, sprint, jump, crouch controls
  - [x] Fly mode (creative)
  - [ ] Step assist for single blocks

#### Week 12: Block Interaction ⚡ IN PROGRESS
- [x] **Ray Casting**
  - [x] DDA algorithm implementation
  - [x] Block selection (5 blocks reach distance)
  - [x] Accurate face detection with face normals

- [ ] **Block Breaking/Placing**
  - [x] Instant block breaking (left click)
  - [x] Block placement with collision check (right click)
  - [x] Visual selection outline (white wireframe cube, 0.01 offset)
  - [ ] Break animation with progress
  - [ ] Tool effectiveness system
  - [ ] Item drop system

#### Week 13: Inventory
- [ ] **Inventory System**
  - Hotbar (9 slots)
  - Full inventory (36 slots)
  - Stack management (64 per slot)
  - Drag & drop UI

- [ ] **Crafting System**
  - 3x3 crafting grid
  - Recipe system (JSON-based)
  - Shapeless crafting support
  - Crafting GUI

#### Week 14: Building Tools
- [ ] **Advanced Building**
  - 100+ block types
  - Directional blocks (stairs, logs)
  - Copy/paste regions
  - Symmetry tools
  - Blueprint save/load

---

### Phase 5: Advanced Features (Weeks 15-18)

#### Week 15: Lighting
- [ ] **Light Propagation**
  - Sunlight (15 levels, vertical descent)
  - Block light (torches, lava, glowstone)
  - Dynamic updates on block changes
  - Smooth lighting with ambient occlusion

#### Week 16: Day/Night & Weather
- [ ] **Atmosphere**
  - 20-minute day/night cycle
  - Sun, moon, and stars
  - Sky color gradients
  - Fog rendering for atmosphere
  - Atmospheric scattering presets per biome

- [ ] **Weather System**
  - Rain and snow (biome-dependent)
  - Particle effects
  - Weather sounds
  - Cloud layer with parallax
  - Dynamic humidity & precipitation cycles tied to biome climate
  - Storm fronts with lightning and wind gust events

- [ ] **Temperature Simulation**
  - Ambient temperature field influenced by biome, elevation, time-of-day
  - Seasonal variation + random cold fronts and heatwaves
  - Heat exchange with blocks (cooling/heating surfaces, lava/snow interactions)
  - Temperature-driven block states (water ↔ ice, snow accumulation/melt)

#### Week 17: Entity System
- [ ] **ECS Architecture**
  - Entity Component System design
  - Component types (Position, Velocity, Render, AI)
  - System implementations

- [ ] **Basic Entities**
  - Dropped items
  - Projectiles (arrows, snowballs)
  - Particles
  - Animals (passive mobs)

#### Week 18: Performance & Polish
- [ ] **Optimization**
  - Metal Performance HUD integration
  - Profiling and bottleneck identification
  - Shader compilation caching
  - Automatic quality settings

- [ ] **Polish**
  - Sound effects
  - UI improvements
  - Settings menu
  - Key bindings configuration

**Target:** 60 FPS on M1, 120 FPS on M3+

---

### Phase 6: Multiplayer Foundation (Weeks 19-22)

#### Week 19: Network Architecture
- [ ] **Protocol Design**
  - Client-server model (authoritative server)
  - UDP with reliability layer
  - Packet structure and serialization
  - Network compression

#### Week 20: Server Implementation
- [ ] **Dedicated Server**
  - Headless server mode
  - Multi-threaded chunk generation
  - World state management
  - Player authentication

#### Week 21: Client Sync
- [ ] **Synchronization**
  - Entity interpolation
  - Chunk streaming protocol
  - Block update batching
  - Player prediction and reconciliation

#### Week 22: Multiplayer Features
- [ ] **Player Interaction**
  - Player name tags
  - Chat system
  - Player list
  - Server commands

- [ ] **Anti-Cheat**
  - Server-side validation
  - Movement checks
  - Inventory verification

**Network Target:** <100ms latency, 50+ players

---

### Phase 7: Modding & Extensibility (Weeks 23-26)

#### Week 23: Scripting Runtime Evaluation
- [ ] **Runtime Feasibility Study**
  - Assess embedding options for JavaScript/TypeScript runtimes (Bun, QuickJS, WASM-based JS engines)
  - Prototype lightweight host interface (init, evaluate, shutdown) with sandbox hooks
  - Measure baseline footprint (target <200MB resident, <100ms cold start)

- [ ] **Plugin API Surface**
  - Define world/entity events exposed to scripts (chunk load, tick, block updates)
  - Draft permission model (read-only vs mutating hooks, rate limits)
  - Outline hot-reload workflow for developer iteration

#### Week 24-25: Prototype Integration
- [ ] **Runtime Prototype**
  - Implement minimal scripting host using selected runtime
  - Expose logging, math helpers, read-only world queries
  - Add validation tests for deterministic behavior

- [ ] **Addon Packaging**
  - Define addon manifest (metadata, versions, dependencies)
  - CLI tooling for packaging/signing mods
  - Sandbox filesystem and network access

#### Week 26: Stabilization & Roadmap
- [ ] **Performance Validation**
  - Stress-test scripted mods in single-player and multiplayer sessions
  - Profiling under heavy addon load (CPU/GPU impact)

- [ ] **Design Review**
  - Finalize public API for mod authors
  - Draft documentation and example mods
  - Plan long-term community distribution (workshop/registry)

**Decision Point:** Select final scripting runtime (Bun if embeddable & stable, alternative JS engine otherwise)

---

## Architecture Overview

```
open-world/
├── src/
│   ├── main.zig                   # Entry point (runs interactive console demo)
│   ├── demo.zig                   # Text-mode systems showcase
│   ├── render_demo.zig            # SDL2 + Metal clear demo
│   ├── rendering/
│   │   ├── camera.zig             # Camera math + smoothing
│   │   ├── mesh.zig               # Greedy meshing + chunk mesh data
│   │   ├── metal_renderer.zig     # WIP Metal pipeline wrapper
│   │   ├── metal.zig              # SDL Metal bridge helpers
│   │   ├── sdl_window.zig         # SDL2 window + input polling
│   │   ├── window.zig             # Native macOS window prototype
│   │   └── shaders/               # Metal shader sources
│   ├── terrain/
│   │   ├── terrain.zig            # Chunk & block system ✅
│   │   ├── generator.zig          # Procedural generation ✅
│   │   ├── streaming.zig          # Priority-based chunk streaming manager
│   │   └── editor.zig             # Terrain editing tools ✅
│   ├── physics/
│   │   └── player.zig             # Player controller + collision
│   ├── utils/
│       ├── math.zig               # Vec3, Mat4, AABB, Frustum ✅
│       ├── noise.zig              # Simplex noise, FBM ✅
│       └── visualization.zig      # Text-mode diagnostics
│   ├── game/                      # (planned) inventory/crafting systems
│   ├── network/                   # (planned) multiplayer stack
│   └── platform/                  # (planned) platform abstractions
├── assets/
│   ├── textures/                  # Block textures (atlas)
│   ├── shaders/                   # Metal shader source
│   ├── sounds/                    # Sound effects
│   └── recipes/                   # Crafting recipes (JSON)
├── build.zig                      # Build configuration ✅
├── README.md                      # Project overview ✅
├── ROADMAP.md                     # This file
└── NEXT_STEPS.md                  # Tactical short-term plan
```

## Performance Targets

### Rendering
- **60 FPS** sustained @ 1080p, 16 chunk view distance (M1)
- **120 FPS** @ 1080p, 16 chunk view distance (M3+)
- **<16ms** frame time budget
- **<100ms** chunk generation time
- **<10ms** chunk mesh generation

### Memory
- **<4GB RAM** for typical gameplay (32x32 loaded chunks)
- **<8GB RAM** for maximum settings (64x64 loaded chunks)
- **<500MB VRAM** for textures and meshes

### Storage
- **<1MB per region** (compressed chunks)
- **<1s** world save time
- **<3s** world load time

### Network (Multiplayer)
- **<100ms** latency tolerance
- **<100KB/s** per client bandwidth
- **50+ concurrent players** supported

## Apple Silicon Optimizations

### Metal 4 Features
- Unified command encoder for lower overhead
- Indirect command buffers for GPU-driven rendering
- Neural rendering for upscaling (MetalFX)
- Tile-based deferred rendering optimization
- MetalFX Frame Interpolation for higher FPS
- Ray tracing denoiser (future enhancement)

### Unified Memory Architecture
- Share buffers between CPU/GPU (zero-copy)
- Reduce memory footprint
- Faster data transfers

### SIMD Optimizations
- Zig SIMD vectors for math operations
- Vectorized noise generation
- Parallel chunk processing

### Multi-Threading
- Utilize all efficiency + performance cores
- Thread pool for chunk generation
- Async I/O for world loading
- Parallel mesh generation

## Testing Strategy

### Unit Tests
- [x] Math utilities (Vec3, Mat4, AABB)
- [x] Noise generation (Simplex, FBM)
- [x] Terrain generation (biome + cave sampling)
- [ ] Chunk serialization
- [ ] Collision detection
- [ ] Inventory management

### Integration Tests
- [ ] Chunk loading/unloading
- [ ] World save/load
- [ ] Network protocol
- [ ] Entity synchronization

### Performance Benchmarks
- [ ] FPS tracking over time
- [ ] Memory usage profiling
- [ ] Chunk generation speed
- [ ] Network latency

### Profiling Tools
- Xcode Instruments (Time Profiler, Allocations)
- Metal Performance HUD (in-game)
- Custom debug UI (F3 screen)

## Development Tools

### Debug Features
- [ ] F3 debug screen (coordinates, FPS, chunk info)
- [ ] Developer console with commands
- [ ] Wireframe rendering mode
- [ ] Chunk border visualization
- [ ] Profiling overlays

### Content Tools
- [ ] Texture atlas generator
- [ ] Recipe editor
- [ ] World inspector
- [ ] Blueprint converter

## Milestones

### M1: Prototype (Week 7)
- Basic rendering with Metal
- Procedural terrain generation
- Camera controls
- Block placement/breaking

### M2: Alpha (Week 14)
- Full inventory and crafting
- Physics and collision
- World save/load
- 60 FPS target met

### M3: Beta (Week 18)
- Lighting system
- Weather and day/night
- Entity system
- Performance optimizations

### M4: Release Candidate (Week 22)
- Multiplayer support
- Server implementation
- Anti-cheat system
- Full feature set

### M5: Version 1.0 (Week 24+)
- Bug fixes and polish
- Performance tuning
- Documentation
- Public release

## Risk Mitigation

### Technical Risks
1. **Metal Integration Complexity**
   - Mitigation: Use Mach engine for abstraction
   - Fallback: zig-gamedev Metal bindings

2. **Performance on Older Macs**
   - Mitigation: LOD system and quality settings
   - Minimum spec: M1 chip, 8GB RAM

3. **Network Latency Issues**
   - Mitigation: Client prediction and interpolation
   - Dedicated server infrastructure

### Schedule Risks
1. **Feature Creep**
   - Mitigation: Strict phase adherence
   - MVP-focused development

2. **Third-Party Dependencies**
   - Mitigation: Evaluate Mach engine stability
   - Backup plan: Custom Metal implementation

## Success Criteria

### Technical
- ✅ Builds on Zig 0.15+
- ✅ All tests pass
- [ ] 60 FPS @ 1080p on M1
- [ ] <4GB RAM usage
- [ ] Multiplayer 50+ players
- [ ] Dynamic weather simulation stable within 2ms/frame budget

### Gameplay
- [ ] Infinite procedural world
- [ ] Smooth terrain editing
- [ ] Full crafting system
- [ ] Multiplayer collaboration
- [ ] Weather and temperature affect terrain (snow, ice, crop growth)

### Quality
- [ ] No crashes during normal gameplay
- [ ] <1s world save/load
- [ ] Intuitive controls
- [ ] Professional UI/UX

---

**Last Updated:** 2025-10-21
**Version:** 1.0
**Status:** Phase 1 - Foundation in Progress
