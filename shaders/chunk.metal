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
    float4 sunDirection;
    float4 sunColor;
    float4 ambientColor;
    float4 skyColor;
    float4 cameraPosition;
    float4 fogParams; // x = density, y = start, z = range, w unused
};

// Vertex shader
vertex VertexOut vertex_main(
    VertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    VertexOut out;

    // Transform vertex using MVP matrix
    float4 worldPos = uniforms.model * float4(in.position, 1.0);
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
    out.worldPos = worldPos.xyz;
    out.worldNormal = (uniforms.model * float4(in.normal, 0.0)).xyz;
    out.texCoord = in.texCoord;
    out.color = in.color;

    return out;
}

// Fragment shader
fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]],
    constant Uniforms& uniforms [[buffer(0)]]
) {
    float4 tex_color = atlas.sample(atlas_sampler, in.texCoord);
    
    float3 normal = normalize(in.worldNormal);
    float3 sunDir = normalize(uniforms.sunDirection.xyz);
    float sun_ndotl = max(dot(normal, sunDir), 0.0);
    
    float3 baseColor = tex_color.rgb * in.color.rgb;
    float3 sunColor = uniforms.sunColor.rgb * sun_ndotl;
    float3 ambient = uniforms.ambientColor.rgb;
    float3 litColor = baseColor * (ambient + sunColor);
    
    float distanceToCamera = length(uniforms.cameraPosition.xyz - in.worldPos);
    float fogFactor = clamp((distanceToCamera - uniforms.fogParams.y) / uniforms.fogParams.z, 0.0, 1.0);
    float3 finalColor = mix(litColor, uniforms.skyColor.rgb, fogFactor);
    
    return float4(finalColor, tex_color.a * in.color.a);
}

// Simple shader for testing - just output a color
fragment float4 fragment_simple(
    VertexOut in [[stage_in]]
) {
    return in.color;
}
