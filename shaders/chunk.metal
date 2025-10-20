#include <metal_stdlib>
using namespace metal;

// Vertex input structure
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
    float4 color [[attribute(3)]];
};

// Vertex output / fragment input structure
struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float2 texCoord;
    float4 color;
    float3 worldPos;
};

// Uniform buffer structure
struct Uniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float4x4 view;
    float4x4 projection;
};

// Vertex shader
vertex VertexOut vertex_main(
    VertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    VertexOut out;

    // Transform position
    float4 worldPos = uniforms.model * float4(in.position, 1.0);
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
    out.worldPos = worldPos.xyz;

    // Transform normal (use inverse transpose for non-uniform scaling)
    out.worldNormal = normalize((uniforms.model * float4(in.normal, 0.0)).xyz);

    // Pass through texture coordinates and color
    out.texCoord = in.texCoord;
    out.color = in.color;

    return out;
}

// Fragment shader
fragment float4 fragment_main(
    VertexOut in [[stage_in]]
) {
    // Simple directional lighting
    float3 lightDir = normalize(float3(0.5, 1.0, 0.3));
    float3 normal = normalize(in.worldNormal);

    // Ambient + diffuse lighting
    float ambient = 0.3;
    float diffuse = max(dot(normal, lightDir), 0.0);
    float lighting = ambient + diffuse * 0.7;

    // Apply lighting to vertex color
    float3 finalColor = in.color.rgb * lighting;

    return float4(finalColor, in.color.a);
}

// Simple shader for testing - just output a color
fragment float4 fragment_simple(
    VertexOut in [[stage_in]]
) {
    return in.color;
}
