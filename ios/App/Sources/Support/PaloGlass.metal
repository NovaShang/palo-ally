// The assistant's face: one drop of tinted liquid glass, ray-marched and lit
// like a small studio render. Used from SwiftUI via `ShaderLibrary.paloGlass`
// (a color effect over a square). The offline kernel at the bottom renders
// the same function into a texture, so the look can be tuned without a
// simulator.
//
// Lighting, in order:
//  - a soft studio: a bright ceiling fading to a darker floor, a round-cornered
//    softbox upper left and a thin strip light on the right. The glass
//    reflects it (Fresnel-weighted);
//  - transmission: the view ray bends into the drop, crosses it with
//    Beer–Lambert absorption in the tint (thick = deep and saturated, thin
//    rims = light), and leaves bent further, so the studio shows through
//    upside down — the cue that reads as glass rather than plastic;
//  - the key light focused through the drop, glowing in its lower part, and
//    a little scattering in the body so the color stays alive in the core;
//  - one soft and one sharp highlight from the softbox;
//  - a soft contact shadow with a tinted caustic in it.

#include <metal_stdlib>
using namespace metal;

namespace paloglass {

constant float3 kKey = float3(-0.55, 0.62, 0.56);   // the softbox, upper left (normalized below)

inline float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
inline float3 toGamma(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
inline float sat(float x) { return clamp(x, 0.0, 1.0); }

// Low-frequency, smooth deformation. The slow part always runs; the lively
// part fades in with `activity`, so changing activity never jumps the phase.
inline float wobble(float3 p, float t, float activity) {
    float ts = t * 0.30;
    float slow = sin(p.x * 1.55 + ts * 1.1) * sin(p.y * 1.35 - ts * 0.9) * sin(p.z * 1.45 + ts * 0.7);
    float tb = t * 1.05;
    float lively = sin(p.x * 2.4 - tb * 1.3 + p.z * 1.2) * sin(p.y * 2.1 + tb * 1.1)
                 + 0.55 * sin(p.y * 3.1 + p.x * 1.7 + tb * 1.7) * sin(p.z * 2.6 - tb * 0.8);
    return slow * 0.035 + lively * 0.042 * activity;
}

// `deform` is the owner's input, spring-smoothed on the CPU: x swells the
// drop (voice level), y squashes it (> 0 flatter and wider, < 0 taller and
// narrower; the base stays on the ground), z adds wobble (a jiggle).
inline float sceneSDF(float3 p, float t, float activity, float3 deform) {
    float breathe = 0.012 * sin(t * 0.85) + 0.010 * activity * sin(t * 2.1);
    float sq = deform.y;
    float3 q = p;
    q.y += sq * 0.92;                              // keep the base where it rests
    q.y *= 1.08 * (1.0 + sq);                      // a soft drop, slightly settled
    q.xz *= 1.0 - 0.5 * sq;
    q.y += 0.055 * (q.x * q.x + q.z * q.z) - 0.02; // flatter underneath, rounder on top
    return length(q) - (1.0 + breathe + deform.x) - wobble(p, t, activity + deform.z);
}

inline float3 normalAt(float3 p, float t, float activity, float3 deform) {
    const float2 k = float2(1, -1);
    const float h = 0.002;
    return normalize(k.xyy * sceneSDF(p + k.xyy * h, t, activity, deform) +
                     k.yyx * sceneSDF(p + k.yyx * h, t, activity, deform) +
                     k.yxy * sceneSDF(p + k.yxy * h, t, activity, deform) +
                     k.xxx * sceneSDF(p + k.xxx * h, t, activity, deform));
}

// A rounded-rectangle light panel seen as a direction; brighter toward its top.
inline float softbox(float3 d) {
    float3 k = normalize(kKey);
    float kd = dot(d, k);
    if (kd <= 0.0) return 0.0;
    float3 right = normalize(cross(float3(0, 1, 0), k));
    float3 up = cross(k, right);
    float2 q = float2(dot(d, right), dot(d, up)) / kd;
    float2 e = abs(q) - float2(0.56, 0.34) + 0.18;
    float sdf = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - 0.18;
    float panel = 1.0 - smoothstep(-0.10, 0.20, sdf);
    return panel * (0.6 + 0.4 * smoothstep(-0.34, 0.34, q.y));
}

// What the surface reflects: a smooth room (no hard horizon — a sharp line
// across a small round thing reads as a seam), the softbox, a strip on the right.
inline float3 environment(float3 d, float dark) {
    float3 floorC = mix(float3(0.30, 0.31, 0.34), float3(0.05, 0.05, 0.06), dark);
    float3 ceilC = mix(float3(0.90, 0.90, 0.94), float3(0.42, 0.43, 0.47), dark);
    float3 c = mix(floorC, ceilC, smoothstep(-0.55, 0.65, d.y));
    c += softbox(d) * mix(3.4, 3.0, dark);
    float strip = smoothstep(0.90, 0.95, d.x) * (1.0 - smoothstep(0.25, 0.65, abs(d.y - 0.05)));
    c += strip * mix(1.6, 1.8, dark);
    return c;
}

// What shows through the drop: the room behind it — dark below, bright
// above, and a soft light up behind it on the left. Seen through the drop
// it's all upside down: the top of the drop is deep, the bottom glows, and
// that light lands low on the right as a caustic.
constant float3 kBack = float3(-0.30, 0.80, -0.52);

inline float3 backdrop(float3 d, float dark) {
    float3 lo = mix(float3(0.13, 0.13, 0.15), float3(0.03, 0.03, 0.04), dark);
    float3 hi = mix(float3(1.10, 1.10, 1.14), float3(0.55, 0.55, 0.60), dark);
    float3 c = mix(lo, hi, smoothstep(-0.6, 0.6, d.y));
    // a wide window of light up behind it: through the drop, a bright arc low down
    float band = exp(-pow((d.y - 0.50) / 0.16, 2.0)) * smoothstep(-0.2, 0.3, -d.z);
    c += band * mix(1.1, 1.3, dark);
    float b = sat(dot(d, normalize(kBack)));
    c += (pow(b, 28.0) * 2.2 + pow(b, 6.0) * 0.35) * mix(1.0, 1.3, dark);
    return c;
}

// Distance a ray travels inside the unit sphere from a point on its surface;
// close enough for absorption in a soft drop.
inline float chord(float3 o, float3 dir) {
    float b = dot(o, dir);
    float c = dot(o, o) - 1.0;
    float h = b * b - c;
    if (h < 0.0) return 0.0;
    return max(0.0, -b + sqrt(h));
}

// Premultiplied, display-encoded color + alpha.
// `position` and `size` in points; `scale` = pixels per point (antialiasing
// and dither work in pixels).
inline float4 shade(float2 position, float2 size, float t, float3 tintSRGB, float activity, float dark, float scale, float3 deform) {
    float s = min(size.x, size.y);
    float2 uv = (position - size * 0.5) / (s * 0.5);
    uv.y = -uv.y;
    uv.y -= 0.07;   // lift the drop a little; its shadow sits below

    float3 base = toLinear(tintSRGB);
    float3 ro = float3(0.0, 0.0, 4.2);
    float3 rd = normalize(float3(uv, -3.05));

    // Bounding sphere first: most pixels miss it.
    float tHit = -1.0;
    float minD = 1e9;
    float3 closest = float3(0);
    {
        float b = dot(ro, rd);
        float c = dot(ro, ro) - 1.3 * 1.3;
        float h = b * b - c;
        if (h > 0.0) {
            float tt = -b - sqrt(h);
            float tEnd = -b + sqrt(h);
            for (int i = 0; i < 48; i++) {
                float3 p = ro + rd * tt;
                float d = sceneSDF(p, t, activity, deform);
                if (d < minD) { minD = d; closest = p; }
                if (d < 0.0015) {
                    // settle exactly onto the surface, or the shading steps in rows
                    tt += d;
                    tt += sceneSDF(ro + rd * tt, t, activity, deform);
                    tHit = tt;
                    break;
                }
                tt += d * 0.8;
                if (tt > tEnd) break;
            }
        }
    }

    // ~1.2 pixels of antialiasing, in world units at the drop's depth
    float aa = (2.4 / (s * scale)) * (4.2 / 3.05);
    float coverage = tHit > 0.0 ? 1.0 : (minD < 1e8 ? 1.0 - smoothstep(0.0, aa, minD) : 0.0);

    float3 col = float3(0);
    if (coverage > 0.0) {
        float3 p = tHit > 0.0 ? ro + rd * tHit : closest;
        float3 n = normalAt(p, t, activity, deform);
        float3 V = -rd;
        float ndv = sat(dot(n, V));
        float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        float3 Lk = normalize(kKey);

        // reflection
        float3 refl = environment(reflect(rd, n), dark);

        // transmission: in, across (absorbing), out — bent further on the way
        // out, which flips the studio upside down inside the drop
        float3 rIn = refract(rd, n, 1.0 / 1.45);
        float L = chord(p, rIn);
        // a little dispersion: each channel bends a touch differently, which
        // fringes the bright parts with color the way real glass does
        float3 rR = refract(rd, n, 1.0 / 1.43), rB = refract(rd, n, 1.0 / 1.48);
        float3 seen = float3(backdrop(normalize(rR + (rR - rd) * 1.6), dark).r,
                             backdrop(normalize(rIn + (rIn - rd) * 1.6), dark).g,
                             backdrop(normalize(rB + (rB - rd) * 1.6), dark).b);
        float flow = 0.5 + 0.5 * sin(dot(p, float3(2.1, 1.7, 1.3)) + t * (0.22 + 0.9 * activity));
        float density = 1.9 * (0.9 + 0.2 * flow * (0.3 + 0.7 * activity));
        float3 sigma = (1.0 - base) * density + 0.05;
        float3 T = exp(-sigma * L);
        float3 trans = seen * T;

        // light from the softbox focused through the drop: a glow low in the
        // body, strongest on the side away from the light
        float away = sat(dot(n, -Lk) * 0.5 + 0.5);
        float low = sat(-n.y * 0.6 + 0.45);
        float3 lumen = base * 2.2 + 0.10 * (1.0 - base);
        float3 glow = lumen * (pow(away, 3.0) * 0.50 + pow(low, 2.5) * 0.45) * (0.35 + 0.65 * (1.0 - ndv * 0.6));
        glow *= mix(1.0, 1.4, dark);
        // scattering in the body keeps the core colored, never black
        float3 rich = pow(base, 1.25);   // a little deeper and more saturated than the tint itself
        float3 body = rich * (0.34 + 0.12 * activity * flow) * (0.5 + 0.5 * ndv) * mix(1.0, 1.25, dark);
        // the thin rim is lighter: little glass to color it
        float3 rim = mix(base, float3(1.0), 0.25) * pow(1.0 - ndv, 4.0) * mix(0.30, 0.45, dark);
        // the very edge catches light: a thin bright line just inside the silhouette
        float edge = smoothstep(0.22, 0.04, ndv) * (0.55 + 0.45 * sat(n.y + 0.6));
        rim += mix(base, float3(1.0), 0.55) * edge * mix(0.35, 0.55, dark);

        // highlights: a broad soft one and a small sharp glint, both from the softbox
        float3 H = normalize(Lk + V);
        float nh = sat(dot(n, H));
        float spec = pow(nh, 900.0) * 2.6 + pow(nh, 80.0) * 0.05;

        col = (trans + glow + body + rim) * (1.0 - fres) + refl * fres + spec;
        // a filmic shoulder on the brightest channel, so bright color stays
        // saturated instead of washing out to white
        float m = max(max(col.r, col.g), col.b);
        col *= (1.0 - exp(-m * 1.1)) / max(m, 1e-4);
        col *= coverage;
    }

    // contact shadow, with a tinted caustic in its middle
    float2 sp = float2(uv.x / 0.58, (uv.y + 0.80) / 0.09);
    float r2 = dot(sp, sp);
    float shadowA = exp(-r2 * 1.7) * mix(0.30, 0.0, dark);
    float causticA = exp(-r2 * 4.0) * mix(0.18, 0.32, dark);
    float3 caustic = 1.0 - exp(-base * 2.4);

    float under = shadowA + causticA * (1.0 - shadowA);
    float3 underCol = caustic * causticA;   // premultiplied (the shadow is black)
    float alpha = coverage + under * (1.0 - coverage);
    float3 outCol = col + underCol * (1.0 - coverage);

    // encode for display: un-premultiply, gamma, re-premultiply; then a
    // touch of dither so the smooth gradients don't band in 8 bits
    if (alpha > 1e-4) outCol = toGamma(outCol / alpha) * alpha;
    float dither = fract(sin(dot(floor(position * scale), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    outCol += dither * (1.5 / 255.0) * alpha;
    return float4(outCol, alpha);
}

} // namespace paloglass

#ifdef PALOGLASS_OFFLINE
// Offline preview: one avatar per call, over the app's light or dark background.
kernel void paloGlassPreview(texture2d<float, access::write> out [[texture(0)]],
                             constant float4 *params [[buffer(0)]],   // x: cell size, y: time, z: activity, w: dark
                             constant float4 *tint [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    float cell = params[0].x;
    float2 pos = float2(gid) + 0.5;
    float2 local = fmod(pos, cell);
    float4 c = paloglass::shade(local, float2(cell), params[0].y, tint[0].rgb, params[0].z, params[0].w, 1.0, float3(0));
    float3 bg = params[0].w > 0.5 ? float3(0.0) : float3(1.0);
    out.write(float4(c.rgb + bg * (1.0 - c.a), 1.0), gid);
}
#else
#include <SwiftUI/SwiftUI_Metal.h>

[[ stitchable ]] half4 paloGlass(float2 position, half4 color, float2 size, float time,
                                 half4 tint, float activity, float dark, float scale, float3 deform) {
    return half4(paloglass::shade(position, size, time, float3(tint.rgb), activity, dark, scale, deform));
}
#endif
