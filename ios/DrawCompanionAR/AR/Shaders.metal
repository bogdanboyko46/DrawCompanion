#include <metal_stdlib>
using namespace metal;

// Camera image: a full-viewport quad sampling a crop of the camera's
// Y and CbCr planes. crop = (u0, v0, u1, v1) in normalized image coords;
// it can reach past the image (headset zoomed out), which shows black.
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
    if (any(in.uv < 0.0) || any(in.uv > 1.0)) return float4(0, 0, 0, 1);
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float4x4 ycbcrToRGB = float4x4(float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
                                         float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
                                         float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
                                         float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    float4 ycbcr = float4(textureY.sample(s, in.uv).r, textureCbCr.sample(s, in.uv).rg, 1.0);
    return ycbcrToRGB * ycbcr;
}

// Outline strokes: each piece of a stroke is a round-capped capsule from a
// to b, drawn as one instanced quad. Coverage is computed exactly at each
// MSAA sample, so lines are smooth at any width and caps and joins are
// round. A per-stroke stencil value makes each sample take a stroke's color
// once, so overlapping pieces of a translucent stroke don't darken.
struct Capsule {
    float4 ends;   // a.xy, b.xy in render-target pixels (y down)
    float4 color;  // rgb, alpha (not premultiplied)
    float4 params; // x = radius in pixels
};

struct StrokeUniforms {
    float4 target;     // width, height (pixels), hasMask, unused
    float4 crop;       // camera-image crop shown in the target (u0, v0, u1, v1)
    float4 samples[2]; // MSAA sample positions in the pixel: s0, s1 | s2, s3
};

struct CapsuleOut {
    float4 position [[position]];
    float2 a [[flat]];
    float2 b [[flat]];
    float radius [[flat]];
    float4 color [[flat]];
};

vertex CapsuleOut capsuleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device Capsule *capsules [[buffer(0)]],
                                constant StrokeUniforms &u [[buffer(1)]]) {
    Capsule c = capsules[iid];
    float2 a = c.ends.xy, b = c.ends.zw;
    float r = c.params.x;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1, 0);
    float2 n = float2(-dir.y, dir.x);
    float pad = r + 1.0; // cover the caps plus a pixel
    float2 p = ((vid & 1u) != 0 ? b + dir * pad : a - dir * pad) + n * ((vid & 2u) != 0 ? pad : -pad);
    CapsuleOut out;
    out.position = float4(p.x / u.target.x * 2 - 1, 1 - p.y / u.target.y * 2, 0, 1);
    out.a = a;
    out.b = b;
    out.radius = r;
    out.color = c.color;
    return out;
}

struct CapsuleFragment {
    float4 color [[color(0)]];
    uint mask [[sample_mask]];
};

// Which of the pixel's 4 MSAA samples lie inside the capsule (0 = none).
static uint capsuleCoverage(float2 position, float2 a, float2 b, float radius, constant StrokeUniforms &u) {
    float2 pixel = floor(position);
    float2 ab = b - a;
    float denom = max(dot(ab, ab), 1e-6);
    float r2 = radius * radius;
    uint mask = 0;
    for (uint i = 0; i < 4; i++) {
        float4 pair = u.samples[i / 2];
        float2 s = pixel + ((i & 1u) != 0 ? pair.zw : pair.xy);
        float2 ap = s - a;
        float t = clamp(dot(ap, ab) / denom, 0.0, 1.0);
        float2 q = ap - ab * t;
        if (dot(q, q) <= r2) mask |= 1u << i;
    }
    return mask;
}

// Lines fade almost out where ARKit sees a person (your hand and pen), so the
// outline looks like it's on the paper, under your hand, not floating on top.
static float handFade(float2 position, constant StrokeUniforms &u, texture2d<float, access::sample> personMask) {
    if (u.target.z < 0.5) return 1.0;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = mix(u.crop.xy, u.crop.zw, position / u.target.xy);
    float person = personMask.sample(s, uv).r;
    return 1.0 - 0.85 * smoothstep(0.3, 0.7, person);
}

// Ordinary blending: color = ink color, alpha = opacity.
fragment CapsuleFragment capsuleFragment(CapsuleOut in [[stage_in]],
                                         constant StrokeUniforms &u [[buffer(0)]],
                                         texture2d<float, access::sample> personMask [[texture(0)]]) {
    uint mask = capsuleCoverage(in.position.xy, in.a, in.b, in.radius, u);
    if (mask == 0) discard_fragment();
    CapsuleFragment out;
    out.color = float4(in.color.rgb, in.color.a * handFade(in.position.xy, u, personMask));
    out.mask = mask;
    return out;
}

// Printed ink: multiplied into the camera image (blend = src * dst), so the
// paper's lighting and texture show through. color = the ink's
// transmittance, alpha = opacity.
fragment CapsuleFragment capsuleFragmentMultiply(CapsuleOut in [[stage_in]],
                                                 constant StrokeUniforms &u [[buffer(0)]],
                                                 texture2d<float, access::sample> personMask [[texture(0)]]) {
    uint mask = capsuleCoverage(in.position.xy, in.a, in.b, in.radius, u);
    if (mask == 0) discard_fragment();
    float a = in.color.a * handFade(in.position.xy, u, personMask);
    CapsuleFragment out;
    out.color = float4(mix(float3(1.0), in.color.rgb, a), 1.0);
    out.mask = mask;
    return out;
}

// Headset: each eye's half of the screen shows the eye texture (the scene,
// covering ±fieldTan around the lens axis) pre-bent with barrel distortion,
// so the viewer's lenses bend it back and straight lines look straight.
struct DistortUniforms {
    float4 lens; // center x, y (screen pixels), pixels per tan, fieldTan
    float4 k;    // k1, k2, edge softness (tan units), unused
};

struct DistortOut {
    float4 position [[position]];
};

vertex DistortOut distortVertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    DistortOut out;
    out.position = float4(pos[vid], 0, 1);
    return out;
}

fragment float4 distortFragment(DistortOut in [[stage_in]],
                                constant DistortUniforms &u [[buffer(0)]],
                                texture2d<float, access::sample> eye [[texture(0)]]) {
    float2 t = (in.position.xy - u.lens.xy) / u.lens.z; // screen tan from the lens axis
    float r2 = dot(t, t);
    float2 e = t * (1 + u.k.x * r2 + u.k.y * r2 * r2);   // where the eye sees this pixel
    float field = u.lens.w;
    float inside = field - max(abs(e.x), abs(e.y));
    if (inside <= 0) return float4(0, 0, 0, 1);
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    float3 color = eye.sample(s, e / (2 * field) + 0.5).rgb;
    return float4(color * smoothstep(0.0, u.k.z, inside), 1);
}
