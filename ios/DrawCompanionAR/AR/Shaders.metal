#include <metal_stdlib>
using namespace metal;

// Camera image: a full-viewport quad sampling a crop of the camera's
// Y and CbCr planes. crop = (u0, v0, u1, v1) in normalized image coords.
struct CameraOut {
    float4 position [[position]];
    float2 uv;
};

vertex CameraOut cameraVertex(uint vid [[vertex_id]], constant float4 &crop [[buffer(0)]]) {
    const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uv[4] = { float2(crop.x, crop.w), float2(crop.z, crop.w), float2(crop.x, crop.y), float2(crop.z, crop.y) };
    CameraOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uv[vid];
    return out;
}

fragment float4 cameraFragment(CameraOut in [[stage_in]],
                               texture2d<float, access::sample> textureY [[texture(0)]],
                               texture2d<float, access::sample> textureCbCr [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float4x4 ycbcrToRGB = float4x4(float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
                                         float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
                                         float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
                                         float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    float4 ycbcr = float4(textureY.sample(s, in.uv).r, textureCbCr.sample(s, in.uv).rg, 1.0);
    return ycbcrToRGB * ycbcr;
}

// Outline strokes: pre-built triangles in clip space with per-vertex color.
struct LineVertex {
    float2 position;
    float4 color;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut lineVertex(uint vid [[vertex_id]], const device LineVertex *vertices [[buffer(0)]]) {
    LineOut out;
    out.position = float4(vertices[vid].position, 0, 1);
    out.color = vertices[vid].color;
    return out;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return in.color;
}
