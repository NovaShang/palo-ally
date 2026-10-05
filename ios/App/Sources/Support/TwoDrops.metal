// The assistant's face, second form: two drops of colored liquid glass.
// The big one is 「它」 (the theme color), the small one is 「你」 (the owner,
// the partner color). How they sit together — fused by a liquid bridge,
// orbiting apart, reaching, splashing back into one — is the expression;
// TwoDropsState.swift drives every number here with springs.
//
// Used from SwiftUI as a color effect over a square:
//   .colorEffect(ShaderLibrary.twoDrops(.floatArray(state.uniforms(...))))
// The offline kernel at the bottom renders the same function into a texture
// so the look and the motion can be reviewed without a simulator.
//
// Material: transparent colored glass. A ray refracts in, crosses the glass
// absorbing by thickness (Beer–Lambert — thin edges pale, thick parts deep),
// may cross the other drop on the way (their colors multiply into a third,
// e.g. magenta × violet → purple), and leaves bent, so a small studio shows
// through upside down. Fresnel reflections of that studio, two highlights, a
// soft tinted shadow. At most one internal bounce; no traced caustics.

#include <metal_stdlib>
using namespace metal;

namespace twodrops {

constant float IOR = 1.47;
constant float3 kKey = float3(-0.55, 0.62, 0.56);    // the softbox, upper left
constant float3 kBack = float3(-0.30, 0.80, -0.52);  // a light up behind, seen through the glass
constant float kDensity = 1.35;                      // absorption per unit length, per unit of -log(tint)

inline float sat(float x) { return clamp(x, 0.0, 1.0); }
inline float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
inline float3 toGamma(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
inline float smin(float a, float b, float k) {
    k = max(k, 1e-4);
    float h = sat(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// The frame, unpacked from the uniform array (layout: TwoDropsState.uniforms).
struct Params {
    float t, dark, scale, zoom;
    float3 colA, colB;          // linear, saturation applied
    float3 colA2, colB2;        // the colors spreading in from fillC (fillR > 0)
    float sat, bright;
    float3 cA; float rA;
    float3 cB; float rB;
    float3 axis; float reach;   // A stretches toward B along axis
    float sqA, sqB, k, wobA, wobB;
    float wobPhase, flow, flowPhase, frost;
    float3 rippleC; float rippleAmp, ripplePhase;
    float glowB, shiver, shiverPhase, floorY;
    float3 cC; float rC;        // a droplet A spits out (rC = 0: none)
    float3 fillC; float fillR;
    float clarity;              // 0 normal, 1 thin pale glass (quiet hours)
    float overlay, overlayOpacity; // overlay: drawn over system Liquid Glass (see shade)
};

inline float3 saturate3(float3 c, float s) { return mix(float3(luma(c)), c, s); }

template <typename Ptr>
inline Params load(Ptr P) {
    Params s;
    s.t = P[0]; s.dark = P[1]; s.scale = P[2]; s.zoom = P[3];
    s.sat = P[7]; s.bright = P[11];
    s.colA = saturate3(toLinear(float3(P[4], P[5], P[6])), s.sat);
    s.colB = saturate3(toLinear(float3(P[8], P[9], P[10])), s.sat);
    s.cA = float3(P[12], P[13], P[14]); s.rA = P[15];
    s.cB = float3(P[16], P[17], P[18]); s.rB = P[19];
    s.axis = float3(P[20], P[21], P[22]); s.reach = P[23];
    s.sqA = P[24]; s.sqB = P[25]; s.k = P[26]; s.wobA = P[27];
    s.wobPhase = P[28]; s.flow = P[29]; s.flowPhase = P[30]; s.frost = P[31];
    s.rippleC = float3(P[32], P[33], P[34]); s.rippleAmp = P[35];
    s.ripplePhase = P[36]; s.glowB = P[37]; s.shiver = P[38]; s.floorY = P[39];
    s.cC = float3(P[40], P[41], P[42]); s.rC = P[43];
    s.colA2 = saturate3(toLinear(float3(P[44], P[45], P[46])), s.sat); s.fillR = P[47];
    s.colB2 = saturate3(toLinear(float3(P[48], P[49], P[50])), s.sat); s.shiverPhase = P[51];
    s.fillC = float3(P[52], P[53], P[54]); s.wobB = P[55];
    s.clarity = P[56];
    s.overlay = P[57]; s.overlayOpacity = P[58];
    float al = length(s.axis);
    s.axis = al > 1e-4 ? s.axis / al : float3(1, 0, 0);
    return s;
}

// ---- shape ------------------------------------------------------------------

// Volume-preserving stretch by `s` along unit `u`; `m` collects the factor
// that keeps the distance a safe lower bound.
inline float3 stretch(float3 q, float3 u, float s, thread float &m) {
    float a = dot(q, u);
    float3 perp = q - u * a;
    m *= min(s, rsqrt(s));
    return u * (a / s) + perp * sqrt(s);
}

// Slow, smooth surface motion in a drop's own unit coordinates.
inline float wobble(float3 l, float ph) {
    return sin(l.x * 2.1 + ph * 1.3) * sin(l.y * 1.9 - ph * 1.1) * sin(l.z * 2.3 + ph * 0.9)
         + 0.55 * sin(l.x * 3.6 - l.z * 2.2 + ph * 1.9) * sin(l.y * 3.2 + ph * 1.6);
}

// Reaching, A leans its body toward B and pushes out a rounded arm of liquid;
// a negative reach pulls it back (squeezed along the axis).
inline float dropA(float3 p, Params s) {
    float m = 1.0;
    float reach = s.reach;
    float sr = max(1.0 + (reach > 0.0 ? 0.35 * reach : reach), 0.55);
    float3 c = s.cA + s.axis * (s.rA * (sr - 1.0) * 0.55);
    float3 q = p - c;
    q = stretch(q, float3(0, 1, 0), exp(-s.sqA), m);
    q = stretch(q, s.axis, sr, m);
    float d = (length(q) - s.rA) * m;
    if (reach > 0.01) {
        float3 armC = s.cA + s.axis * s.rA * (0.25 + 1.25 * reach);
        float armR = s.rA * (0.46 + 0.10 * min(reach, 1.0));
        d = smin(d, length(p - armC) - armR, 0.30 * s.rA);
    }
    float3 l = (p - s.cA) / s.rA;
    d -= s.rA * 0.06 * s.wobA * wobble(l, s.wobPhase);
    d -= s.rA * 0.012 * s.shiver * sin(l.x * 4.0 + s.shiverPhase * 37.0) * sin(l.y * 3.5 - s.shiverPhase * 29.0);
    return d;
}

inline float dropB(float3 p, Params s) {
    float m = 1.0;
    float3 q = p - s.cB;
    q = stretch(q, float3(0, 1, 0), exp(-s.sqB), m);
    float d = (length(q) - s.rB) * m;
    float3 l = (p - s.cB) / s.rB;
    d -= s.rB * 0.07 * s.wobB * wobble(l * 1.15, s.wobPhase * 1.6 + 1.7);
    return d;
}

// The whole liquid: A and B joined by a smooth union (the bridge), the spat
// droplet, and a ripple running out from an impact.
inline float scene(float3 p, Params s, thread float &dA, thread float &dB) {
    dA = dropA(p, s);
    dB = dropB(p, s);
    float d = smin(dA, dB, s.k);
    if (s.rC > 0.001) d = smin(d, length(p - s.cC) - s.rC, 0.16);
    if (s.rippleAmp > 1e-4) {
        float r = length(p - s.rippleC);
        d -= s.rippleAmp * sin(r * 26.0 - s.ripplePhase) * exp(-r * 4.0);
    }
    return d;
}

inline float sdf(float3 p, Params s) { float a, b; return scene(p, s, a, b); }

inline float3 normalAt(float3 p, Params s) {
    const float2 k = float2(1, -1);
    const float h = 0.0015;
    return normalize(k.xyy * sdf(p + k.xyy * h, s) + k.yyx * sdf(p + k.yyx * h, s) +
                     k.yxy * sdf(p + k.yxy * h, s) + k.xxx * sdf(p + k.xxx * h, s));
}

// ---- color ------------------------------------------------------------------

// A color changing spreads outward from fillC.
inline void colorsAt(float3 p, Params s, thread float3 &a, thread float3 &b) {
    a = s.colA; b = s.colB;
    if (s.fillR > 0.0) {
        float f = 1.0 - smoothstep(s.fillR - 0.22, s.fillR, length(p - s.fillC));
        a = mix(a, s.colA2, f);
        b = mix(b, s.colB2, f);
    }
}

inline float3 sigmaOf(float3 c) { return -log(max(c, float3(0.02))) * kDensity; }

// How much of A's and of B's color is at p. Where the drops have merged the
// liquid mixes (half and half: in absorption that's the geometric mean, e.g.
// magenta + violet → purple) rather than stacking two layers, which would go
// muddy and dark; in the bridge it blends by nearness. Two separate drops one
// behind the other still multiply, as stacked glass does.
inline void weights(float dA, float dB, float k, thread float &wa, thread float &wb) {
    float a = 1.0 - smoothstep(-0.03, 0.03, dA);
    float b = 1.0 - smoothstep(-0.03, 0.03, dB);
    float rest = max(0.0, 1.0 - a - b);
    float nearB = sat(0.5 + 0.5 * (dA - dB) / max(k, 0.08));
    float sum = max(a + b, 1.0);
    wa = (a + rest * (1.0 - nearB)) / sum;
    wb = (b + rest * nearB) / sum;
}

// The glass's own tint at a surface point (for rim, glow and the shadow).
inline float3 surfaceTint(float3 p, Params s, float dA, float dB) {
    float3 ca, cb; colorsAt(p, s, ca, cb);
    float wa = sat(0.5 - 0.5 * (dA - dB) / max(s.k + 0.06, 0.1));
    return mix(cb, ca, wa);
}

// A slow light turning inside A (background work, thinking).
inline float swirl(float3 p, Params s) {
    if (s.flow <= 0.001) return 0.0;
    float3 l = (p - s.cA) / s.rA;
    float ang = atan2(l.z, l.x);
    float band = 0.5 + 0.5 * sin(ang * 2.0 + l.y * 2.6 - s.flowPhase);
    return pow(band, 6.0) * smoothstep(1.05, 0.25, length(l)) * s.flow;
}

// ---- light --------------------------------------------------------------------

inline float softbox(float3 d) {
    float3 k = normalize(kKey);
    float kd = dot(d, k);
    if (kd <= 0.0) return 0.0;
    float3 right = normalize(cross(float3(0, 1, 0), k));
    float3 up = cross(k, right);
    float2 q = float2(dot(d, right), dot(d, up)) / kd;
    float2 e = abs(q) - float2(0.56, 0.34) + 0.18;
    float sdfv = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - 0.18;
    float panel = 1.0 - smoothstep(-0.10, 0.20, sdfv);
    return panel * (0.6 + 0.4 * smoothstep(-0.34, 0.34, q.y));
}

// What the surface reflects: a smooth room, the softbox, a strip on the right.
inline float3 environment(float3 d, float dark) {
    float3 floorC = mix(float3(0.30, 0.31, 0.34), float3(0.05, 0.05, 0.06), dark);
    float3 ceilC = mix(float3(0.90, 0.90, 0.94), float3(0.40, 0.41, 0.45), dark);
    float3 c = mix(floorC, ceilC, smoothstep(-0.55, 0.65, d.y));
    c += softbox(d) * mix(3.2, 3.0, dark);
    float strip = smoothstep(0.90, 0.95, d.x) * (1.0 - smoothstep(0.25, 0.65, abs(d.y - 0.05)));
    c += strip * mix(1.5, 1.8, dark);
    return c;
}

// What shows through: the room behind, dark below and bright above, a wide
// window of light up behind — through a drop all of it lands upside down.
inline float3 backdrop(float3 d, float dark) {
    float3 lo = mix(float3(0.16, 0.16, 0.18), float3(0.025, 0.025, 0.03), dark);
    float3 hi = mix(float3(1.10, 1.10, 1.14), float3(0.50, 0.50, 0.55), dark);
    float3 c = mix(lo, hi, smoothstep(-0.6, 0.6, d.y));
    float band = exp(-pow((d.y - 0.50) / 0.16, 2.0)) * smoothstep(-0.2, 0.3, -d.z);
    c += band * mix(1.0, 1.25, dark);
    float b = sat(dot(d, normalize(kBack)));
    c += (pow(b, 28.0) * 2.0 + pow(b, 6.0) * 0.3) * mix(1.0, 1.3, dark);
    // two tall soft windows behind: through the glass they bend into bright
    // arcs, the cue that it's clear
    float behind = smoothstep(0.1, 0.6, -d.z);
    float win = exp(-pow((d.x - 0.42) / 0.15, 2.0)) + 0.7 * exp(-pow((d.x + 0.55) / 0.11, 2.0));
    c += win * behind * smoothstep(-0.7, -0.2, d.y) * (1.0 - smoothstep(0.5, 0.9, d.y)) * mix(0.38, 0.45, dark);
    return c;
}

inline float fresnelR(float cosi) {
    float r0 = (IOR - 1.0) / (IOR + 1.0); r0 *= r0;
    return r0 + (1.0 - r0) * pow(1.0 - sat(cosi), 5.0);
}

// What a view ray sees through the glass after entering at p: it crosses the
// glass absorbing (and picking up A's inner light), leaves, maybe crosses the
// other drop too, and lands on the backdrop. Leaving, part of the light
// reflects back inside — all of it past the critical angle; that part is
// estimated (the backdrop in the mirrored direction, dimmed by more glass)
// rather than traced, so total internal reflection never draws a hard seam.
inline float3 backdropSeen(float3 d, float3 rd, Params s) {
    // Over system glass the real background shows through (the glass bends
    // it); here an even light only lets the thickness color the drop.
    if (s.overlay > 0.5) return mix(float3(0.96), float3(0.60), s.dark) * (1.0 - s.frost * 0.3);
    float3 bend = d - rd;
    float3 c = float3(backdrop(normalize(d + bend * 0.05), s.dark).r,
                      backdrop(d, s.dark).g,
                      backdrop(normalize(d - bend * 0.05), s.dark).b);
    return mix(c, mix(float3(0.72), float3(0.22), s.dark), s.frost * 0.8);
}

struct Glass { float3 sigA, sigB, glowCol; float r0; };

// Crosses one stretch of glass from q (just inside) along d: absorbs, gathers
// A's inner light, and on the way out adds the part that reflects back inside
// (all of it past the critical angle — estimated as the backdrop in the
// mirrored direction, dimmed by more glass, rather than traced, so total
// internal reflection never draws a hard seam). Returns false when nothing
// gets out; otherwise `exitP` and `dout` are where and which way it leaves.
inline bool crossGlass(float3 q, float3 d, float3 rd, Params s, Glass g,
                       thread float3 &T, thread float3 &acc, thread float3 &exitP, thread float3 &dout) {
    float t = 0.0, tPrev = 0.0;
    float3 sigLast = g.sigA;
    for (int i = 0; i < 36; i++) {
        float3 x = q + d * t;
        float dA, dB;
        float dd = scene(x, s, dA, dB);
        if (dd > 0.0) break;
        float dt = clamp(-dd * 0.9, 0.022, 0.22);
        float wa, wb; weights(dA, dB, s.k, wa, wb);
        sigLast = g.sigA * wa + g.sigB * wb;
        acc += T * g.glowCol * swirl(x, s) * wa * dt;
        T *= exp(-sigLast * dt);
        tPrev = t;
        t += dt;
    }
    float lo = tPrev, hi = t;
    for (int i = 0; i < 4; i++) {
        float m = 0.5 * (lo + hi);
        if (sdf(q + d * m, s) > 0.0) hi = m; else lo = m;
    }
    float3 e = q + d * hi;
    float3 ne = normalAt(e, s);
    // Fresnel from the transmitted angle, so it reaches 1 at the critical angle
    float ci = sat(dot(d, ne));
    float st2 = IOR * IOR * (1.0 - ci * ci);
    float F = st2 >= 1.0 ? 1.0 : g.r0 + (1.0 - g.r0) * pow(1.0 - sqrt(1.0 - st2), 5.0);
    acc += T * F * backdropSeen(reflect(d, ne), rd, s) * exp(-sigLast * s.rA * 0.4);
    if (F >= 0.999) return false;
    T *= 1.0 - F;
    dout = normalize(refract(d, -ne, IOR));
    exitP = e + ne * 0.004;
    return true;
}

// What a view ray sees through the glass after entering at p (normal n):
// across, out, and possibly through the other drop on the way. `aa` is about
// a pixel in world units: where the ray only just misses the other drop, the
// two outcomes blend, so that drop's outline seen through the first stays
// smooth instead of stair-stepped.
inline float3 transmit(float3 p, float3 rd, float3 n, Params s, float aa) {
    float3 acc = float3(0), T = float3(1);
    float3 d = refract(rd, n, 1.0 / IOR);
    if (dot(d, d) < 0.5) return backdropSeen(rd, rd, s);
    T *= 1.0 - fresnelR(dot(-rd, n));
    float3 ca0, cb0; colorsAt(p, s, ca0, cb0);
    Glass g;
    float thin = 1.0 - 0.62 * s.clarity;
    g.sigA = sigmaOf(ca0) * thin; g.sigB = sigmaOf(cb0) * thin;
    g.glowCol = mix(ca0, float3(1.0), 0.45) * 2.4;
    g.r0 = (IOR - 1.0) / (IOR + 1.0); g.r0 *= g.r0;
    float3 e, dout;
    if (!crossGlass(p - n * 0.004, d, rd, s, g, T, acc, e, dout)) return acc;
    // outside: does it run into the other drop?
    float3 o = e + dout * 0.002;
    float tt = 0.0, minDD = 1e9, tClose = 0.0;
    bool hit = false;
    for (int j = 0; j < 26; j++) {
        float dd = sdf(o + dout * tt, s);
        if (dd < minDD) { minDD = dd; tClose = tt; }
        if (dd < 0.0015) { hit = true; break; }
        tt += max(dd, 0.004);
        if (tt > 2.6) break;
    }
    float3 miss = T * backdropSeen(dout, rd, s);
    // the other drop seen through this one is kept soft — a crisp ring there
    // reads as an eye
    float w = max(aa * 4.0, 0.03);
    if (!hit && minDD > w) return acc + miss;
    float cov = hit ? 1.0 : 1.0 - smoothstep(0.0, w, minDD);
    // the second drop: its surface reflects, the rest goes in. At its outline
    // nearly everything reflects and runs on almost unbent, so it sees what a
    // ray that just missed sees — no dark seam
    float3 p2 = o + dout * (hit ? tt : tClose);
    float3 n2 = normalAt(p2, s);
    float F2 = fresnelR(abs(dot(-dout, n2)));
    float3 T2 = T, acc2 = T * F2 * 0.35 * backdropSeen(reflect(dout, n2), rd, s);
    T2 *= 1.0 - F2;
    float3 d2 = refract(dout, n2, 1.0 / IOR);
    if (dot(d2, d2) > 0.5) {
        float3 e2, dout2;
        if (crossGlass(p2 - n2 * 0.004, d2, rd, s, g, T2, acc2, e2, dout2)) acc2 += T2 * backdropSeen(dout2, rd, s);
    }
    return acc + mix(miss, acc2, cov);
}

// Premultiplied, display-encoded color + alpha. `position`/`size` in points;
// `scale` = pixels per point (antialiasing and dither work in pixels).
inline float4 shade(float2 position, float2 size, Params s) {
    float sz = min(size.x, size.y);
    float2 uv = (position - size * 0.5) / (sz * 0.5);
    uv.y = -uv.y;
    float3 ro = float3(0.0, 0.0, 4.2);
    float3 rd = normalize(float3(uv * s.zoom, -3.05));

    // a bounding sphere around everything; most pixels miss it
    float R = max(length(s.cA) + s.rA * (1.0 + max(s.reach, 0.0)) * 1.3,
                  length(s.cB) + s.rB * 1.3);
    if (s.rC > 0.001) R = max(R, length(s.cC) + s.rC * 1.3);
    R += 0.12 + s.rippleAmp * 2.0;

    float tHit = -1.0, minD = 1e9;
    float3 closest = float3(0);
    {
        float b = dot(ro, rd), c = dot(ro, ro) - R * R, h = b * b - c;
        if (h > 0.0) {
            float tt = max(-b - sqrt(h), 0.0), tEnd = -b + sqrt(h);
            for (int i = 0; i < 64; i++) {
                float3 p = ro + rd * tt;
                float d = sdf(p, s);
                if (d < minD) { minD = d; closest = p; }
                if (d < 0.0012) {
                    tt += d;
                    tt += sdf(ro + rd * tt, s);
                    tHit = tt;
                    break;
                }
                tt += d * 0.8;
                if (tt > tEnd) break;
            }
        }
    }

    // ~1.2 px of antialiasing, in world units at the drops' depth
    float aa = (2.4 / max(sz * s.scale, 1.0)) * (4.2 / 3.05) * s.zoom;
    float coverage = tHit > 0.0 ? 1.0 : (minD < 1e8 ? 1.0 - smoothstep(0.0, aa, minD) : 0.0);

    float3 col = float3(0);
    // The glass's own opacity: part of what's really behind shows through.
    float glassA = coverage;
    if (coverage > 0.0) {
        float3 p = tHit > 0.0 ? ro + rd * tHit : closest;
        float dA, dB;
        scene(p, s, dA, dB);
        float3 n = normalAt(p, s);
        float3 V = -rd;
        float ndv = sat(dot(n, V));
        float fres = fresnelR(ndv);
        float3 tint = surfaceTint(p, s, dA, dB);
        float3 Lk = normalize(kKey);

        // reflection; frost (offline) blurs it toward the room's average
        float3 refl = environment(reflect(rd, n), s.dark);
        float3 reflAvg = mix(float3(0.62, 0.62, 0.66), float3(0.20, 0.20, 0.23), s.dark);
        refl = mix(refl, reflAvg, s.frost * 0.85);

        // transmission
        float3 trans = transmit(p, rd, n, s, aa);

        // light focused through the glass glows low on the far side; a little
        // scattering keeps the color alive where it's thick
        float away = sat(dot(n, -Lk) * 0.5 + 0.5);
        float low = sat(-n.y * 0.6 + 0.45);
        float3 glow = (tint * 1.8 + 0.08) * (pow(away, 3.0) * 0.30 + pow(low, 2.5) * 0.28) * (1.0 - ndv * 0.5);
        glow *= mix(1.0, 1.35, s.dark) * (1.0 - s.frost * 0.7);
        float3 body = pow(tint, float3(1.2)) * 0.16 * (0.5 + 0.5 * ndv) * mix(1.0, 1.3, s.dark) * (1.0 - 0.5 * s.clarity);
        glow *= 1.0 - 0.4 * s.clarity;
        // the small drop lights up a little when it's the one speaking / asked
        float onB = sat(0.5 + 0.5 * (dA - dB) / max(s.k + 0.06, 0.1));
        body += tint * s.glowB * onB * 0.35;
        // thin rim: little glass to color it; a bright line right at the edge
        float3 rim = mix(tint, float3(1.0), 0.35) * pow(1.0 - ndv, 4.0) * mix(0.28, 0.42, s.dark);
        float edge = smoothstep(0.22, 0.04, ndv) * (0.55 + 0.45 * sat(n.y + 0.6));
        // over system glass its own edge light draws the outline
        if (s.overlay < 0.5) rim += mix(tint, float3(1.0), 0.6) * edge * mix(0.30, 0.50, s.dark);

        // highlights: a sharp glint and a soft sheen from the softbox
        float3 H = normalize(Lk + V);
        float nh = sat(dot(n, H));
        float spec = (pow(nh, 900.0) * 2.6 + pow(nh, 70.0) * 0.06) * (1.0 - s.frost * 0.9);

        col = (trans + glow + body + rim) * (1.0 - fres) + refl * fres + spec;
        // what of that is the (procedural) room seen through the glass
        float3 seen = trans * (1.0 - fres);
        // frosted glass turns a little milky
        col = mix(col, mix(float3(0.80), float3(0.30), s.dark) * mix(float3(1.0), tint * 2.0 + 0.3, 0.15), s.frost * 0.35);
        seen *= 1.0 - s.frost * 0.35;
        float m = max(max(col.r, col.g), col.b);
        float shoulder = (1.0 - exp(-m * 1.1)) / max(m, 1e-4);   // filmic shoulder: bright color stays colored
        col *= shoulder * s.bright * coverage;
        seen *= shoulder * s.bright * coverage;

        // See-through: the real background shows through the glass — about
        // 30% at the thin rims, 10% through the thick core (a little less at
        // small sizes, where too much would wash the color out; frosted
        // glass, offline, stays nearly opaque). That share of the room seen
        // through is taken out, so the drop gets neither brighter nor muddier.
        // Its own light — glints, rim lines, the glow — stays opaque: where it
        // outshines the glass's opacity, the alpha rises to carry it.
        float big = smoothstep(80.0, 180.0, sz);
        float aThin = mix(0.80, 0.70, big), aThick = mix(0.92, 0.88, big);
        if (s.overlay > 0.5) {
            // Over system glass: only the color depth (thick = deep) and the
            // light on it; the glass underneath does the bending, the edge
            // and the merge, so the overlay fades out toward the silhouette
            // instead of drawing an outline of its own.
            aThin = 0.18; aThick = mix(0.80, 0.74, big);
        }
        float aG = mix(aThin, aThick, smoothstep(0.08, 0.80, ndv));
        aG = mix(aG, 0.97, s.frost * (1.0 - 0.4 * s.overlay));
        col = max(col - seen * (1.0 - aG), 0.0);
        glassA = min(coverage, max(coverage * aG, max(max(col.r, col.g), col.b)));
        if (s.overlay > 0.5) {
            float fade = smoothstep(0.0, 0.30, ndv);
            col *= fade; glassA *= fade;
        }
    }

    // soft shadows under each drop, with a little colored light in them
    float shadowA = 0.0, causticA = 0.0;
    float3 causticCol = float3(0);
    for (int i = 0; i < (s.overlay > 0.5 ? 0 : 3); i++) {
        float3 c = i == 0 ? s.cA : (i == 1 ? s.cB : s.cC);
        float r = i == 0 ? s.rA : (i == 1 ? s.rB : s.rC);
        if (r < 0.002) continue;
        float3 ca, cb; colorsAt(c, s, ca, cb);
        float3 tintC = i == 1 ? cb : ca;
        float hgt = max(c.y - r - s.floorY, 0.0);
        float depth = max(4.2 - c.z, 1.0);
        float2 g = float2(c.x, s.floorY) / depth * 3.05 / s.zoom;
        float w = r * (1.2 + 0.8 * hgt) * 3.05 / depth / s.zoom;
        float2 q = (uv - g) / float2(w, w * 0.22);
        float r2 = dot(q, q);
        float fade = exp(-hgt * 1.3);
        float sh = exp(-r2 * 1.6) * mix(0.24, 0.0, s.dark) * fade * (1.0 - s.frost * 0.3);
        float cs = exp(-r2 * 3.5) * mix(0.12, 0.26, s.dark) * fade * (1.0 - s.frost * 0.8);
        shadowA = 1.0 - (1.0 - shadowA) * (1.0 - sh);
        causticA = 1.0 - (1.0 - causticA) * (1.0 - cs);
        causticCol += (1.0 - exp(-tintC * 2.4)) * cs * s.bright;
    }
    float under = shadowA + causticA * (1.0 - shadowA);
    float alpha = glassA + under * (1.0 - coverage);
    float3 outCol = col + causticCol * (1.0 - shadowA) * (1.0 - coverage);

    if (s.overlay > 0.5) { alpha *= s.overlayOpacity; outCol *= s.overlayOpacity; }
    if (alpha > 1e-4) outCol = toGamma(outCol / alpha) * alpha;
    float dither = fract(sin(dot(floor(position * s.scale), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    outCol += dither * (1.5 / 255.0) * alpha;
    return float4(outCol, alpha);
}

} // namespace twodrops

#ifdef TWODROPS_OFFLINE
// Offline: one square image over a background.
// cfg.x: size in px, cfg.y: background (0 white, 1 black, 2 icon light, 3 icon dark),
// cfg.z: samples per axis, cfg.w: first row (the image renders in bands).
kernel void twoDropsOffline(texture2d<float, access::write> out [[texture(0)]],
                            constant float *P [[buffer(0)]],
                            constant float4 &cfg [[buffer(1)]],
                            uint2 gid0 [[thread_position_in_grid]]) {
    float size = cfg.x;
    uint2 gid = uint2(gid0.x, gid0.y + uint(cfg.w));
    if (float(gid.y) >= size || float(gid.x) >= size) return;
    twodrops::Params s = twodrops::load(P);
    s.scale = 1.0;
    int n = max(1, int(cfg.z + 0.5));
    float2 f = (float2(gid) + 0.5) / size;
    float3 bg;
    if (cfg.y < 0.5) bg = float3(1.0);
    else if (cfg.y < 1.5) bg = float3(0.0);
    else if (cfg.y < 2.5) {
        float3 tint = float3(P[4], P[5], P[6]);
        bg = mix(mix(tint, float3(1.0), 0.94), mix(tint, float3(1.0), 0.84), smoothstep(0.1, 0.95, f.y));
    } else {
        float3 tint = float3(P[4], P[5], P[6]);
        bg = mix(float3(0.075, 0.07, 0.085), float3(0.02, 0.02, 0.025), smoothstep(0.1, 1.0, f.y));
        bg += tint * 0.10 * (1.0 - smoothstep(0.0, 0.6, length((f - float2(0.5, 0.45)) * float2(1.0, 1.15))));
    }
    float3 acc = float3(0);
    for (int j = 0; j < n; j++) for (int i = 0; i < n; i++) {
        float2 pos = float2(gid) + (float2(i, j) + 0.5) / float(n);
        float4 c = twodrops::shade(pos, float2(size), s);
        acc += c.rgb + bg * (1.0 - c.a);   // display-encoded, premultiplied over the background
    }
    out.write(float4(acc / float(n * n), 1.0), gid);
}
#else
#include <SwiftUI/SwiftUI_Metal.h>

[[ stitchable ]] half4 twoDrops(float2 position, half4 color, float2 size, device const float *P, int count) {
    if (count < 60) return half4(0);
    twodrops::Params s = twodrops::load(P);
    return half4(twodrops::shade(position, size, s));
}
#endif
