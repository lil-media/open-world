# Metal Integration Plan

## Overview

This document outlines the strategy for integrating Metal graphics rendering into the open world game, optimized for macOS and Apple Silicon.

## Options Evaluated

### Option 1: Direct Metal Bindings (zig-metal)
**Pros:**
- Direct access to Metal API
- Maximum performance potential
- Apple Silicon specific optimizations
- No abstraction overhead

**Cons:**
- macOS only
- More boilerplate code
- Objective-C interop complexity
- Manual cross-platform handling

### Option 2: Mach Engine (WebGPU via sysgpu)
**Pros:**
- Cross-platform (Metal, Vulkan, D3D12, OpenGL)
- Modern WebGPU-based API
- Active development (v0.4 latest)
- Good documentation and examples
- Zero system dependencies (bundles everything)

**Cons:**
- Abstraction layer overhead (minimal)
- Less direct Metal control
- Newer, evolving API

### Option 3: zig-gamedev zgpu
**Pros:**
- WebGPU via Dawn
- Cross-platform
- Part of mature gamedev ecosystem
- Good examples

**Cons:**
- Dawn dependency
- Less Zig-native than Mach

## **Decision: Hybrid Approach**

**Phase 1 (Current):** Start with **Mach Engine** for rapid prototyping
- Get rendering working quickly
- Cross-platform from day one
- Learn the rendering pipeline

**Phase 2 (Optimization):** Add **direct Metal path** for Apple Silicon
- Keep Mach for other platforms
- Add Metal-specific optimizations
- Use Metal 4 features directly

This gives us the best of both worlds: rapid development + maximum performance.

---

## Implementation Plan

### Step 1: Add Mach Dependency

Update `build.zig.zon`:
```zig
.{
    .name = "open-world",
    .version = "0.1.0",
    .dependencies = .{
        .mach = .{
            .url = "https://pkg.machengine.org/mach/LATEST.tar.gz",
        },
    },
}
```

### Step 2: Window & Context Setup

Create `src/platform/window.zig`:
```zig
const mach = @import("mach");

pub const Window = struct {
    core: *mach.Core,

    pub fn init() !Window {
        var core = try mach.Core.init(.{});
        return .{ .core = core };
    }

    pub fn deinit(self: *Window) void {
        self.core.deinit();
    }
};
```

### Step 3: Rendering Pipeline

Create `src/rendering/pipeline.zig`:
```zig
const gpu = @import("mach").gpu;

pub const RenderPipeline = struct {
    pipeline: *gpu.RenderPipeline,
    bind_group_layout: *gpu.BindGroupLayout,

    pub fn init(device: *gpu.Device) !RenderPipeline {
        // Create shader module
        const shader = device.createShaderModule(&.{
            .label = "terrain_shader",
            .code = .{ .wgsl = @embedFile("shaders/terrain.wgsl") },
        });

        // Create pipeline
        const pipeline = device.createRenderPipeline(&.{
            .vertex = .{
                .module = shader,
                .entry_point = "vertex_main",
                .buffers = &[_]gpu.VertexBufferLayout{
                    .{
                        .array_stride = @sizeOf(Vertex),
                        .attributes = &[_]gpu.VertexAttribute{
                            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
                            .{ .format = .float32x2, .offset = 24, .shader_location = 2 },
                        },
                    },
                },
            },
            .fragment = &.{
                .module = shader,
                .entry_point = "fragment_main",
                .targets = &[_]gpu.ColorTargetState{
                    .{ .format = .bgra8_unorm },
                },
            },
        });

        return .{ .pipeline = pipeline };
    }
};
```

### Step 4: Chunk Renderer

Create `src/rendering/chunk_renderer.zig`:
```zig
pub const ChunkRenderer = struct {
    device: *gpu.Device,
    pipeline: RenderPipeline,
    vertex_buffers: std.AutoHashMap(ChunkPos, *gpu.Buffer),
    index_buffers: std.AutoHashMap(ChunkPos, *gpu.Buffer),

    pub fn uploadChunkMesh(self: *ChunkRenderer, pos: ChunkPos, mesh: *ChunkMesh) !void {
        // Create vertex buffer
        const vertex_buffer = self.device.createBuffer(&.{
            .size = mesh.vertices.items.len * @sizeOf(Vertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });

        // Upload data
        self.device.getQueue().writeBuffer(
            vertex_buffer,
            0,
            mesh.vertices.items,
        );

        try self.vertex_buffers.put(pos, vertex_buffer);
    }

    pub fn renderChunk(
        self: *ChunkRenderer,
        pass: *gpu.RenderPassEncoder,
        pos: ChunkPos,
        view_proj: Mat4,
    ) void {
        const vertex_buffer = self.vertex_buffers.get(pos) orelse return;

        pass.setPipeline(self.pipeline.pipeline);
        pass.setVertexBuffer(0, vertex_buffer, 0, gpu.whole_size);
        pass.draw(vertex_count, 1, 0, 0);
    }
};
```

### Step 5: Main Render Loop

Update `src/main.zig`:
```zig
pub fn main() !void {
    // ... existing initialization ...

    var window = try Window.init();
    defer window.deinit();

    var chunk_renderer = try ChunkRenderer.init(window.device);
    defer chunk_renderer.deinit();

    while (!window.shouldClose()) {
        // Update
        try chunk_manager.update(player_physics.position, main_camera.front);

        // Render
        const encoder = window.device.createCommandEncoder(null);
        const back_buffer = window.core.swap_chain.getCurrentTextureView();

        const render_pass = encoder.beginRenderPass(&.{
            .color_attachments = &[_]gpu.RenderPassColorAttachment{
                .{
                    .view = back_buffer,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0.53, .g = 0.81, .b = 0.92, .a = 1.0 },
                },
            },
        });

        // Render chunks
        const view_proj = main_camera.getViewProjectionMatrix();
        for (chunk_manager.chunks.values()) |chunk| {
            chunk_renderer.renderChunk(render_pass, chunk.pos, view_proj);
        }

        render_pass.end();

        const command_buffer = encoder.finish(null);
        window.device.getQueue().submit(&[_]*gpu.CommandBuffer{command_buffer});
        window.core.swap_chain.present();
        window.pollEvents(null);
    }
}
```

---

## Shader Development

### Vertex Shader (terrain.wgsl)

```wgsl
struct Uniforms {
    view_proj: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) tex_coord: vec2<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) tex_coord: vec2<f32>,
    @location(2) world_pos: vec3<f32>,
}

@vertex
fn vertex_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;

    let world_pos = vec4<f32>(input.position, 1.0);
    output.position = uniforms.view_proj * world_pos;
    output.normal = input.normal;
    output.tex_coord = input.tex_coord;
    output.world_pos = input.position;

    return output;
}

@fragment
fn fragment_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Simple directional light
    let light_dir = normalize(vec3<f32>(0.5, 1.0, 0.3));
    let diffuse = max(dot(input.normal, light_dir), 0.0);

    // Base color based on block type (can be texture later)
    var base_color = vec3<f32>(0.4, 0.6, 0.3); // Grass green

    // Apply lighting
    let ambient = 0.3;
    let color = base_color * (ambient + diffuse * 0.7);

    return vec4<f32>(color, 1.0);
}
```

---

## Metal-Specific Optimizations (Phase 2)

Once basic rendering works, add Metal-specific paths:

### 1. Indirect Draw Calls
```zig
// Use Metal's indirect command buffers for GPU-driven rendering
const indirect_buffer = device.makeIndirectCommandBuffer(
    descriptor,
    maxCommandCount: chunk_count,
);
```

### 2. Unified Memory
```zig
// Zero-copy buffers on Apple Silicon
const buffer = device.makeBuffer(
    .{ .storageMode = .shared }  // CPU and GPU share memory
);
```

### 3. Async Compute
```zig
// Run chunk meshing on compute shaders during rendering
const compute_encoder = commandBuffer.makeComputeCommandEncoder();
compute_encoder.setComputePipelineState(meshPipeline);
compute_encoder.dispatchThreads(...);
```

### 4. MetalFX Upscaling
```zig
// Use MetalFX for spatial or temporal upscaling
const upscaler = try MetalFXSpatialScaler.init(device);
```

---

## Performance Targets

| Feature | Mach (Phase 1) | Metal Direct (Phase 2) |
|---------|----------------|------------------------|
| FPS @ 1080p | 60 FPS | 90-120 FPS |
| Chunk rendering | Standard | GPU-driven indirect |
| Memory | Standard buffers | Unified memory |
| Upscaling | None | MetalFX |
| Draw calls | Per-chunk | Batched/indirect |

---

## Timeline

### Week 3: Basic Rendering
- [ ] Add Mach dependency to build.zig
- [ ] Create window and Metal context
- [ ] Render a single colored triangle
- [ ] Render a test cube with simple shader

### Week 4: Chunk Rendering
- [ ] Upload chunk meshes to GPU
- [ ] Implement camera controls
- [ ] Render multiple chunks
- [ ] Add basic lighting

### Week 5: Optimization
- [ ] Frustum culling integration
- [ ] LOD system
- [ ] Performance profiling
- [ ] Reach 60 FPS target

### Week 6+: Advanced Features
- [ ] Lighting system
- [ ] Day/night cycle
- [ ] Water rendering
- [ ] Particle effects

---

## Resources

- **Mach Docs:** https://machengine.org/
- **WebGPU Spec:** https://www.w3.org/TR/webgpu/
- **Metal Best Practices:** https://developer.apple.com/metal/
- **Zig Gamedev:** https://github.com/zig-gamedev

---

## Next Steps

1. Create `build.zig.zon` with Mach dependency
2. Implement basic window in `src/platform/window.zig`
3. Create simple shader in `src/rendering/shaders/terrain.wgsl`
4. Render first triangle to validate pipeline
5. Integrate with existing chunk system

The hybrid approach gives us rapid development with Mach while keeping the door open for Metal-specific optimizations later!
