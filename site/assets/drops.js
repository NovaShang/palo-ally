// PaloAlly's mark: two drops of colored liquid glass — the big one is 「它」
// (the assistant), the small one is 「你」 (you). A port of the app's
// TwoDrops.metal (look) and TwoDropsState.swift (motion) to WebGL2: the same
// raymarched glass, the same springs, the same slow noise, so the page moves
// the way the app does.
//
//   const d = new Drops(canvas, { primary: "#D156A7", partner: "#8B6BFF" });
//   d.state.inputs.thinking = true;      // modes
//   d.state.send("done");                // events
//
// Each instance renders only while its canvas is on screen and the page is
// visible; with prefers-reduced-motion it draws still poses.

(function () {
  "use strict";

  // ---------------------------------------------------------------- shader

  const VERT = `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`;

  const FRAG = `#version 300 es
precision highp float;
uniform float P[60];
uniform vec2 uSize;
out vec4 outColor;

const float IOR = 1.47;
const vec3 kKey = vec3(-0.55, 0.62, 0.56);
const vec3 kBack = vec3(-0.30, 0.80, -0.52);
const float kDensity = 1.35;

float sat(float x) { return clamp(x, 0.0, 1.0); }
vec3 toLinear(vec3 c) { return pow(max(c, 0.0), vec3(2.2)); }
vec3 toGamma(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float smin(float a, float b, float k) {
  k = max(k, 1e-4);
  float h = sat(0.5 + 0.5 * (b - a) / k);
  return mix(b, a, h) - k * h * (1.0 - h);
}

struct Params {
  float t, dark, scale, zoom;
  vec3 colA, colB, colA2, colB2;
  float sat, bright;
  vec3 cA; float rA;
  vec3 cB; float rB;
  vec3 axis; float reach;
  float sqA, sqB, k, wobA, wobB;
  float wobPhase, flow, flowPhase, frost;
  vec3 rippleC; float rippleAmp, ripplePhase;
  float glowB, shiver, shiverPhase, floorY;
  vec3 cC; float rC;
  vec3 fillC; float fillR;
  float clarity;
};

vec3 saturate3(vec3 c, float s) { return mix(vec3(luma(c)), c, s); }

Params load() {
  Params s;
  s.t = P[0]; s.dark = P[1]; s.scale = P[2]; s.zoom = P[3];
  s.sat = P[7]; s.bright = P[11];
  s.colA = saturate3(toLinear(vec3(P[4], P[5], P[6])), s.sat);
  s.colB = saturate3(toLinear(vec3(P[8], P[9], P[10])), s.sat);
  s.cA = vec3(P[12], P[13], P[14]); s.rA = P[15];
  s.cB = vec3(P[16], P[17], P[18]); s.rB = P[19];
  s.axis = vec3(P[20], P[21], P[22]); s.reach = P[23];
  s.sqA = P[24]; s.sqB = P[25]; s.k = P[26]; s.wobA = P[27];
  s.wobPhase = P[28]; s.flow = P[29]; s.flowPhase = P[30]; s.frost = P[31];
  s.rippleC = vec3(P[32], P[33], P[34]); s.rippleAmp = P[35];
  s.ripplePhase = P[36]; s.glowB = P[37]; s.shiver = P[38]; s.floorY = P[39];
  s.cC = vec3(P[40], P[41], P[42]); s.rC = P[43];
  s.colA2 = saturate3(toLinear(vec3(P[44], P[45], P[46])), s.sat); s.fillR = P[47];
  s.colB2 = saturate3(toLinear(vec3(P[48], P[49], P[50])), s.sat); s.shiverPhase = P[51];
  s.fillC = vec3(P[52], P[53], P[54]); s.wobB = P[55];
  s.clarity = P[56];
  float al = length(s.axis);
  s.axis = al > 1e-4 ? s.axis / al : vec3(1, 0, 0);
  return s;
}

vec3 stretchV(vec3 q, vec3 u, float s, inout float m) {
  float a = dot(q, u);
  vec3 perp = q - u * a;
  m *= min(s, inversesqrt(s));
  return u * (a / s) + perp * sqrt(s);
}

float wobble(vec3 l, float ph) {
  return sin(l.x * 2.1 + ph * 1.3) * sin(l.y * 1.9 - ph * 1.1) * sin(l.z * 2.3 + ph * 0.9)
       + 0.55 * sin(l.x * 3.6 - l.z * 2.2 + ph * 1.9) * sin(l.y * 3.2 + ph * 1.6);
}

float dropA(vec3 p, Params s) {
  float m = 1.0;
  float reach = s.reach;
  float sr = max(1.0 + (reach > 0.0 ? 0.35 * reach : reach), 0.55);
  vec3 c = s.cA + s.axis * (s.rA * (sr - 1.0) * 0.55);
  vec3 q = p - c;
  q = stretchV(q, vec3(0, 1, 0), exp(-s.sqA), m);
  q = stretchV(q, s.axis, sr, m);
  float d = (length(q) - s.rA) * m;
  if (reach > 0.01) {
    vec3 armC = s.cA + s.axis * s.rA * (0.25 + 1.25 * reach);
    float armR = s.rA * (0.46 + 0.10 * min(reach, 1.0));
    d = smin(d, length(p - armC) - armR, 0.30 * s.rA);
  }
  vec3 l = (p - s.cA) / s.rA;
  d -= s.rA * 0.06 * s.wobA * wobble(l, s.wobPhase);
  d -= s.rA * 0.012 * s.shiver * sin(l.x * 4.0 + s.shiverPhase * 37.0) * sin(l.y * 3.5 - s.shiverPhase * 29.0);
  return d;
}

float dropB(vec3 p, Params s) {
  float m = 1.0;
  vec3 q = p - s.cB;
  q = stretchV(q, vec3(0, 1, 0), exp(-s.sqB), m);
  float d = (length(q) - s.rB) * m;
  vec3 l = (p - s.cB) / s.rB;
  d -= s.rB * 0.07 * s.wobB * wobble(l * 1.15, s.wobPhase * 1.6 + 1.7);
  return d;
}

float scene(vec3 p, Params s, out float dA, out float dB) {
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

float sdf(vec3 p, Params s) { float a, b; return scene(p, s, a, b); }

vec3 normalAt(vec3 p, Params s) {
  const vec2 k = vec2(1, -1);
  const float h = 0.0015;
  return normalize(k.xyy * sdf(p + k.xyy * h, s) + k.yyx * sdf(p + k.yyx * h, s) +
                   k.yxy * sdf(p + k.yxy * h, s) + k.xxx * sdf(p + k.xxx * h, s));
}

void colorsAt(vec3 p, Params s, out vec3 a, out vec3 b) {
  a = s.colA; b = s.colB;
  if (s.fillR > 0.0) {
    float f = 1.0 - smoothstep(s.fillR - 0.22, s.fillR, length(p - s.fillC));
    a = mix(a, s.colA2, f);
    b = mix(b, s.colB2, f);
  }
}

vec3 sigmaOf(vec3 c) { return -log(max(c, vec3(0.02))) * kDensity; }

void weights(float dA, float dB, float k, out float wa, out float wb) {
  float a = 1.0 - smoothstep(-0.03, 0.03, dA);
  float b = 1.0 - smoothstep(-0.03, 0.03, dB);
  float rest = max(0.0, 1.0 - a - b);
  float nearB = sat(0.5 + 0.5 * (dA - dB) / max(k, 0.08));
  float sum = max(a + b, 1.0);
  wa = (a + rest * (1.0 - nearB)) / sum;
  wb = (b + rest * nearB) / sum;
}

vec3 surfaceTint(vec3 p, Params s, float dA, float dB) {
  vec3 ca, cb; colorsAt(p, s, ca, cb);
  float wa = sat(0.5 - 0.5 * (dA - dB) / max(s.k + 0.06, 0.1));
  return mix(cb, ca, wa);
}

float swirl(vec3 p, Params s) {
  if (s.flow <= 0.001) return 0.0;
  vec3 l = (p - s.cA) / s.rA;
  float ang = atan(l.z, l.x);
  float band = 0.5 + 0.5 * sin(ang * 2.0 + l.y * 2.6 - s.flowPhase);
  return pow(band, 6.0) * smoothstep(1.05, 0.25, length(l)) * s.flow;
}

float softbox(vec3 d) {
  vec3 k = normalize(kKey);
  float kd = dot(d, k);
  if (kd <= 0.0) return 0.0;
  vec3 right = normalize(cross(vec3(0, 1, 0), k));
  vec3 up = cross(k, right);
  vec2 q = vec2(dot(d, right), dot(d, up)) / kd;
  vec2 e = abs(q) - vec2(0.56, 0.34) + 0.18;
  float sdfv = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - 0.18;
  float panel = 1.0 - smoothstep(-0.10, 0.20, sdfv);
  return panel * (0.6 + 0.4 * smoothstep(-0.34, 0.34, q.y));
}

vec3 environment(vec3 d, float dark) {
  vec3 floorC = mix(vec3(0.30, 0.31, 0.34), vec3(0.05, 0.05, 0.06), dark);
  vec3 ceilC = mix(vec3(0.90, 0.90, 0.94), vec3(0.40, 0.41, 0.45), dark);
  vec3 c = mix(floorC, ceilC, smoothstep(-0.55, 0.65, d.y));
  c += softbox(d) * mix(3.2, 3.0, dark);
  float strip = smoothstep(0.90, 0.95, d.x) * (1.0 - smoothstep(0.25, 0.65, abs(d.y - 0.05)));
  c += strip * mix(1.5, 1.8, dark);
  return c;
}

vec3 backdrop(vec3 d, float dark) {
  vec3 lo = mix(vec3(0.16, 0.16, 0.18), vec3(0.025, 0.025, 0.03), dark);
  vec3 hi = mix(vec3(1.10, 1.10, 1.14), vec3(0.50, 0.50, 0.55), dark);
  vec3 c = mix(lo, hi, smoothstep(-0.6, 0.6, d.y));
  float band = exp(-pow((d.y - 0.50) / 0.16, 2.0)) * smoothstep(-0.2, 0.3, -d.z);
  c += band * mix(1.0, 1.25, dark);
  float b = sat(dot(d, normalize(kBack)));
  c += (pow(b, 28.0) * 2.0 + pow(b, 6.0) * 0.3) * mix(1.0, 1.3, dark);
  float behind = smoothstep(0.1, 0.6, -d.z);
  float win = exp(-pow((d.x - 0.42) / 0.15, 2.0)) + 0.7 * exp(-pow((d.x + 0.55) / 0.11, 2.0));
  c += win * behind * smoothstep(-0.7, -0.2, d.y) * (1.0 - smoothstep(0.5, 0.9, d.y)) * mix(0.38, 0.45, dark);
  return c;
}

float fresnelR(float cosi) {
  float r0 = (IOR - 1.0) / (IOR + 1.0); r0 *= r0;
  return r0 + (1.0 - r0) * pow(1.0 - sat(cosi), 5.0);
}

vec3 backdropSeen(vec3 d, vec3 rd, Params s) {
  vec3 bend = d - rd;
  vec3 c = vec3(backdrop(normalize(d + bend * 0.05), s.dark).r,
                backdrop(d, s.dark).g,
                backdrop(normalize(d - bend * 0.05), s.dark).b);
  return mix(c, mix(vec3(0.72), vec3(0.22), s.dark), s.frost * 0.8);
}

bool crossGlass(vec3 q, vec3 d, vec3 rd, Params s, vec3 sigA, vec3 sigB, vec3 glowCol, float r0,
                inout vec3 T, inout vec3 acc, out vec3 exitP, out vec3 dout) {
  exitP = q; dout = d;
  float t = 0.0, tPrev = 0.0;
  vec3 sigLast = sigA;
  for (int i = 0; i < 36; i++) {
    vec3 x = q + d * t;
    float dA, dB;
    float dd = scene(x, s, dA, dB);
    if (dd > 0.0) break;
    float dt = clamp(-dd * 0.9, 0.022, 0.22);
    float wa, wb; weights(dA, dB, s.k, wa, wb);
    sigLast = sigA * wa + sigB * wb;
    acc += T * glowCol * swirl(x, s) * wa * dt;
    T *= exp(-sigLast * dt);
    tPrev = t;
    t += dt;
  }
  float lo = tPrev, hi = t;
  for (int i = 0; i < 4; i++) {
    float m = 0.5 * (lo + hi);
    if (sdf(q + d * m, s) > 0.0) hi = m; else lo = m;
  }
  vec3 e = q + d * hi;
  vec3 ne = normalAt(e, s);
  float ci = sat(dot(d, ne));
  float st2 = IOR * IOR * (1.0 - ci * ci);
  float F = st2 >= 1.0 ? 1.0 : r0 + (1.0 - r0) * pow(1.0 - sqrt(1.0 - st2), 5.0);
  acc += T * F * backdropSeen(reflect(d, ne), rd, s) * exp(-sigLast * s.rA * 0.4);
  if (F >= 0.999) return false;
  T *= 1.0 - F;
  dout = normalize(refract(d, -ne, IOR));
  exitP = e + ne * 0.004;
  return true;
}

vec3 transmit(vec3 p, vec3 rd, vec3 n, Params s, float aa) {
  vec3 acc = vec3(0), T = vec3(1);
  vec3 d = refract(rd, n, 1.0 / IOR);
  if (dot(d, d) < 0.5) return backdropSeen(rd, rd, s);
  T *= 1.0 - fresnelR(dot(-rd, n));
  vec3 ca0, cb0; colorsAt(p, s, ca0, cb0);
  float thin = 1.0 - 0.62 * s.clarity;
  vec3 sigA = sigmaOf(ca0) * thin, sigB = sigmaOf(cb0) * thin;
  vec3 glowCol = mix(ca0, vec3(1.0), 0.45) * 2.4;
  float r0 = (IOR - 1.0) / (IOR + 1.0); r0 *= r0;
  vec3 e, dout;
  if (!crossGlass(p - n * 0.004, d, rd, s, sigA, sigB, glowCol, r0, T, acc, e, dout)) return acc;
  vec3 o = e + dout * 0.002;
  float tt = 0.0, minDD = 1e9, tClose = 0.0;
  bool hit = false;
  for (int j = 0; j < 26; j++) {
    float dd = sdf(o + dout * tt, s);
    if (dd < minDD) { minDD = dd; tClose = tt; }
    if (dd < 0.0015) { hit = true; break; }
    tt += max(dd, 0.004);
    if (tt > 2.6) break;
  }
  vec3 miss = T * backdropSeen(dout, rd, s);
  float w = max(aa * 4.0, 0.03);
  if (!hit && minDD > w) return acc + miss;
  float cov = hit ? 1.0 : 1.0 - smoothstep(0.0, w, minDD);
  vec3 p2 = o + dout * (hit ? tt : tClose);
  vec3 n2 = normalAt(p2, s);
  float F2 = fresnelR(abs(dot(-dout, n2)));
  vec3 T2 = T, acc2 = T * F2 * 0.35 * backdropSeen(reflect(dout, n2), rd, s);
  T2 *= 1.0 - F2;
  vec3 d2 = refract(dout, n2, 1.0 / IOR);
  if (dot(d2, d2) > 0.5) {
    vec3 e2, dout2;
    if (crossGlass(p2 - n2 * 0.004, d2, rd, s, sigA, sigB, glowCol, r0, T2, acc2, e2, dout2))
      acc2 += T2 * backdropSeen(dout2, rd, s);
  }
  return acc + mix(miss, acc2, cov);
}

void main() {
  Params s = load();
  vec2 size = uSize;
  vec2 position = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);
  float sz = min(size.x, size.y);
  vec2 uv = (position - size * 0.5) / (sz * 0.5);
  uv.y = -uv.y;
  vec3 ro = vec3(0.0, 0.0, 4.2);
  vec3 rd = normalize(vec3(uv * s.zoom, -3.05));

  float R = max(length(s.cA) + s.rA * (1.0 + max(s.reach, 0.0)) * 1.3, length(s.cB) + s.rB * 1.3);
  if (s.rC > 0.001) R = max(R, length(s.cC) + s.rC * 1.3);
  R += 0.12 + s.rippleAmp * 2.0;

  float tHit = -1.0, minD = 1e9;
  vec3 closest = vec3(0);
  {
    float b = dot(ro, rd), c = dot(ro, ro) - R * R, h = b * b - c;
    if (h > 0.0) {
      float tt = max(-b - sqrt(h), 0.0), tEnd = -b + sqrt(h);
      for (int i = 0; i < 64; i++) {
        vec3 p = ro + rd * tt;
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

  float aa = (2.4 / max(sz, 1.0)) * (4.2 / 3.05) * s.zoom;   // sz is already in pixels
  float coverage = tHit > 0.0 ? 1.0 : (minD < 1e8 ? 1.0 - smoothstep(0.0, aa, minD) : 0.0);

  vec3 col = vec3(0);
  float glassA = coverage;
  if (coverage > 0.0) {
    vec3 p = tHit > 0.0 ? ro + rd * tHit : closest;
    float dA, dB;
    scene(p, s, dA, dB);
    vec3 n = normalAt(p, s);
    vec3 V = -rd;
    float ndv = sat(dot(n, V));
    float fres = fresnelR(ndv);
    vec3 tint = surfaceTint(p, s, dA, dB);
    vec3 Lk = normalize(kKey);

    vec3 refl = environment(reflect(rd, n), s.dark);
    vec3 reflAvg = mix(vec3(0.62, 0.62, 0.66), vec3(0.20, 0.20, 0.23), s.dark);
    refl = mix(refl, reflAvg, s.frost * 0.85);

    vec3 trans = transmit(p, rd, n, s, aa);

    float away = sat(dot(n, -Lk) * 0.5 + 0.5);
    float low = sat(-n.y * 0.6 + 0.45);
    vec3 glow = (tint * 1.8 + 0.08) * (pow(away, 3.0) * 0.30 + pow(low, 2.5) * 0.28) * (1.0 - ndv * 0.5);
    glow *= mix(1.0, 1.35, s.dark) * (1.0 - s.frost * 0.7);
    vec3 body = pow(tint, vec3(1.2)) * 0.16 * (0.5 + 0.5 * ndv) * mix(1.0, 1.3, s.dark) * (1.0 - 0.5 * s.clarity);
    glow *= 1.0 - 0.4 * s.clarity;
    float onB = sat(0.5 + 0.5 * (dA - dB) / max(s.k + 0.06, 0.1));
    body += tint * s.glowB * onB * 0.35;
    vec3 rim = mix(tint, vec3(1.0), 0.35) * pow(1.0 - ndv, 4.0) * mix(0.28, 0.42, s.dark);
    float edge = smoothstep(0.22, 0.04, ndv) * (0.55 + 0.45 * sat(n.y + 0.6));
    rim += mix(tint, vec3(1.0), 0.6) * edge * mix(0.30, 0.50, s.dark);

    vec3 H = normalize(Lk + V);
    float nh = sat(dot(n, H));
    float spec = (pow(nh, 900.0) * 2.6 + pow(nh, 70.0) * 0.06) * (1.0 - s.frost * 0.9);

    col = (trans + glow + body + rim) * (1.0 - fres) + refl * fres + spec;
    vec3 seen = trans * (1.0 - fres);
    col = mix(col, mix(vec3(0.80), vec3(0.30), s.dark) * mix(vec3(1.0), tint * 2.0 + 0.3, 0.15), s.frost * 0.35);
    seen *= 1.0 - s.frost * 0.35;
    float m = max(max(col.r, col.g), col.b);
    float shoulder = (1.0 - exp(-m * 1.1)) / max(m, 1e-4);
    col *= shoulder * s.bright * coverage;
    seen *= shoulder * s.bright * coverage;

    float big = smoothstep(80.0, 180.0, sz / max(s.scale, 1.0));
    float aThin = mix(0.80, 0.70, big), aThick = mix(0.92, 0.88, big);
    float aG = mix(aThin, aThick, smoothstep(0.08, 0.80, ndv));
    aG = mix(aG, 0.97, s.frost);
    col = max(col - seen * (1.0 - aG), 0.0);
    glassA = min(coverage, max(coverage * aG, max(max(col.r, col.g), col.b)));
  }

  float shadowA = 0.0, causticA = 0.0;
  vec3 causticCol = vec3(0);
  for (int i = 0; i < 3; i++) {
    vec3 c = i == 0 ? s.cA : (i == 1 ? s.cB : s.cC);
    float r = i == 0 ? s.rA : (i == 1 ? s.rB : s.rC);
    if (r < 0.002) continue;
    vec3 ca, cb; colorsAt(c, s, ca, cb);
    vec3 tintC = i == 1 ? cb : ca;
    float hgt = max(c.y - r - s.floorY, 0.0);
    float depth = max(4.2 - c.z, 1.0);
    vec2 g = vec2(c.x, s.floorY) / depth * 3.05 / s.zoom;
    float w = r * (1.2 + 0.8 * hgt) * 3.05 / depth / s.zoom;
    vec2 q = (uv - g) / vec2(w, w * 0.22);
    float r2 = dot(q, q);
    float fade = exp(-hgt * 1.3);
    float sh = exp(-r2 * 1.6) * mix(0.24, 0.0, s.dark) * fade * (1.0 - s.frost * 0.3);
    float cs = exp(-r2 * 3.5) * mix(0.12, 0.26, s.dark) * fade * (1.0 - s.frost * 0.8);
    shadowA = 1.0 - (1.0 - shadowA) * (1.0 - sh);
    causticA = 1.0 - (1.0 - causticA) * (1.0 - cs);
    causticCol += (1.0 - exp(-tintC * 2.4)) * cs * s.bright;
  }
  // the floor's shadow fades out before the canvas edge, so it never ends in a line
  vec2 en = abs(position / size * 2.0 - 1.0);
  float edgeFade = (1.0 - smoothstep(0.62, 0.98, en.x)) * (1.0 - smoothstep(0.55, 0.97, en.y));
  shadowA *= edgeFade; causticA *= edgeFade; causticCol *= edgeFade;
  float under = shadowA + causticA * (1.0 - shadowA);
  float alpha = glassA + under * (1.0 - coverage);
  vec3 outCol = col + causticCol * (1.0 - shadowA) * (1.0 - coverage);

  if (alpha > 1e-4) outCol = toGamma(outCol / alpha) * alpha;
  float dither = fract(sin(dot(floor(gl_FragCoord.xy), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
  outCol += dither * (1.5 / 255.0) * alpha;
  outColor = vec4(outCol, alpha);
}`;

  // ---------------------------------------------------------------- motion

  const MODES = ["idle", "quiet", "background", "thinking", "streaming", "typing", "approval", "speaking", "offline"];
  // Parameter order matches TwoDropsState.P
  const PN = ["sep", "el", "azVel", "orbitMix", "anchor", "ratio", "size", "k", "wobA", "wobB", "wobSpeed", "reach",
    "sqA", "sqB", "swellA", "swellB", "sat", "bright", "frost", "flow", "flowSpeed", "glowB", "comY", "zoom", "life", "shiver", "clarity",
    "leanX", "leanY"];
  const I = Object.fromEntries(PN.map((n, i) => [n, i]));
  const FEEL = [
    [60, 0.42], [30, 0.70], [8, 1.0], [10, 1.0], [6, 1.0], [20, 0.8], [50, 0.55], [25, 0.9], [20, 0.8], [60, 0.55],
    [6, 1.0], [70, 0.28], [90, 0.17], [120, 0.20], [80, 0.30], [90, 0.45], [6, 1.0], [8, 1.0], [5, 1.0], [4, 1.0],
    [4, 1.0], [30, 0.8], [40, 0.38], [4, 1.0], [3, 1.0], [6, 1.0], [3, 1.0],
    [9, 0.9], [9, 0.9],
  ];
  const IDLE = (() => {
    const t = new Array(PN.length).fill(0);
    t[I.sep] = 0.62; t[I.el] = 0.45; t[I.azVel] = 0.14;
    t[I.ratio] = 0.55; t[I.size] = 1; t[I.k] = 0.20;
    t[I.wobA] = 0.35; t[I.wobB] = 0.35; t[I.wobSpeed] = 0.55;
    t[I.sat] = 1; t[I.bright] = 1; t[I.flowSpeed] = 0.4;
    t[I.comY] = 0.02; t[I.zoom] = 0.82; t[I.life] = 1;
    return t;
  })();

  const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
  const smoothstep = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  const easeOut = (x) => 1 - Math.pow(1 - x, 3);
  const easeInOut = (x) => x * x * (3 - 2 * x);
  const v3 = (x, y, z) => [x, y, z];
  const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
  const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
  const len = (a) => Math.hypot(a[0], a[1], a[2]);
  const norm = (a) => { const l = len(a); return l > 1e-6 ? mul(a, 1 / l) : [1, 0, 0]; };

  function hexToRGB(hex) {
    const h = hex.replace("#", "");
    return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
  }

  // A few slow sines per channel with seeded, incommensurate frequencies.
  function makeNoise(seed) {
    function hash(n) {
      let h = (n * 374761393 + seed * 668265263) | 0;
      h = Math.imul(h ^ (h >>> 13), 1274126177);
      h ^= h >>> 16;
      return (h >>> 0) / 4294967295;
    }
    const table = [];
    for (let ch = 0; ch < 16; ch++) {
      const o = [];
      for (let k = 0; k < 3; k++) {
        const f = 0.05 + 0.22 * hash(ch * 31 + k) * (k === 0 ? 0.6 : k === 1 ? 1.0 : 1.7);
        o.push([f, 6.2832 * hash(ch * 31 + k + 997), k === 0 ? 1 : k === 1 ? 0.6 : 0.35]);
      }
      table.push(o);
    }
    return (ch, t) => {
      let acc = 0, n = 0;
      for (const [f, ph, a] of table[ch]) { acc += a * Math.sin(t * f * 6.2832 + ph); n += a; }
      return acc / n;
    };
  }

  class DropsState {
    constructor(primary, partner, seed) {
      this.primary = primary; this.partner = partner;
      this.inputs = { offline: false, speaking: false, approval: false, typing: false, streaming: false,
        thinking: false, background: false, quiet: false, voiceLevel: 0, busyness: 0.5 };
      this.reduceMotion = false;
      this.time = 0;
      this.noise = makeNoise(seed || 0x9a10);
      this.springs = PN.map((_, i) => {
        const [k, z] = FEEL[i];
        return { x: IDLE[i], v: 0, target: IDLE[i], k, c: 2 * z * Math.sqrt(k) };
      });
      this.az = 0.6; this.anchorAz = Math.PI / 2;
      this.wobPhase = 0; this.flowPhase = 0; this.shiverPhase = 0; this.noiseT = 0;
      this.knockClock = 0; this.lastKeystroke = -1; this.lastChunk = -1;
      this.cA = [0, 0, 0]; this.cB = [0.5, 0, 0]; this.dir = [1, 0, 0]; this.rA = 0.52; this.rB = 0.3;
      this.ripple = { c: [0, 0, 0], amp: 0, age: 0 };
      this.droplet = { p: [0, 0, 0], v: [0, 0, 0], r: 0 };
      this.shakeX = 0;
      this.fill = { on: false, c: [0, 0, 0], r: 0, fromA: primary, fromB: partner, toA: primary, toB: partner };
      this.running = [];
      this.lean = { x: 0, y: 0 };
      this.frameZoom = 1;
    }

    get mode() {
      const i = this.inputs;
      if (i.offline) return "offline";
      if (i.speaking) return "speaking";
      if (i.approval) return "approval";
      if (i.typing) return "typing";
      if (i.streaming) return "streaming";
      if (i.thinking) return "thinking";
      if (i.background) return "background";
      if (i.quiet) return "quiet";
      return "idle";
    }

    x(n) { return this.springs[I[n]].x; }
    kick(n, dv) { if (!this.reduceMotion) this.springs[I[n]].v += dv; }

    targets(m) {
      const t = IDLE.slice();
      const set = (n, v) => { t[I[n]] = v; };
      const b = clamp(this.inputs.busyness, 0, 1);
      const L = clamp(this.inputs.voiceLevel, 0, 1);
      switch (m) {
        case "quiet":
          set("sep", 0.10); set("ratio", 0.52); set("k", 0.22); set("wobA", 0.08); set("wobB", 0.08);
          set("wobSpeed", 0.14); set("bright", 1.0); set("sat", 0.68); set("clarity", 1); set("azVel", 0.03);
          set("life", 0.32); set("zoom", 0.86); set("comY", -0.02); set("flowSpeed", 0.2);
          break;
        case "background":
          set("flow", 0.75); set("flowSpeed", 0.8);
          break;
        case "thinking":
          set("sep", 1.12 + 0.16 * b); set("orbitMix", 1); set("azVel", 1.2 + 1.8 * b); set("k", 0.30);
          set("wobA", 0.55 + 0.3 * b); set("wobB", 0.5); set("wobSpeed", 1.1 + 0.6 * b);
          set("flow", 0.45); set("flowSpeed", 1.2 + b); set("zoom", 1.16); set("el", 0);
          break;
        case "streaming":
          set("sep", 0.92); set("orbitMix", 1); set("azVel", 0.6); set("k", 0.34);
          set("wobA", 0.45); set("wobB", 0.45); set("flow", 0.3); set("flowSpeed", 0.9); set("zoom", 1.05);
          break;
        case "typing":
          set("anchor", 1); this.anchorAz = Math.PI / 2;
          set("el", -0.6); set("sep", 0.68); set("azVel", 0); set("comY", -0.08); set("k", 0.24);
          set("wobA", 0.3); set("zoom", 0.88);
          break;
        case "speaking":
          set("anchor", 1); this.anchorAz = Math.PI / 2 - 0.45;
          set("el", -0.15); set("azVel", 0); set("sep", 0.70 + 0.34 * L); set("k", 0.24 + 0.18 * L);
          set("swellB", 0.26 * L); set("wobB", 0.4 + 1.2 * L); set("wobSpeed", 0.9 + 1.4 * L);
          set("glowB", 0.5 * L); set("sqA", -0.05); set("zoom", 0.92);
          set("wobA", 0.3 + 0.7 * L); set("swellA", 0.06 * L);
          break;
        case "approval":
          set("anchor", 1); this.anchorAz = 0.45;
          set("el", -0.1); set("azVel", 0); set("sep", 1.02); set("reach", 0.22); set("glowB", 0.3);
          set("k", 0.26); set("wobA", 0.3); set("zoom", 1.0);
          break;
        case "offline":
          set("anchor", 1); this.anchorAz = 0.2;
          set("el", 0.02); set("azVel", 0); set("sep", 1.12); set("wobA", 0); set("wobB", 0); set("life", 0);
          set("frost", 1); set("sat", 0.06); set("bright", 0.8); set("k", 0.18); set("zoom", 1.02); set("comY", 0);
          break;
      }
      if (m !== "typing" && m !== "speaking" && m !== "approval" && m !== "offline") set("anchor", 0);
      set("leanX", this.lean.x); set("leanY", this.lean.y);
      return t;
    }

    send(ev, a, b) {
      if (this.reduceMotion) {
        if (ev === "hostSwitch" || ev === "colorChange") { this.primary = a; this.partner = b; }
        return;
      }
      if (this.mode === "offline" && !["reconnect", "hostSwitch", "colorChange"].includes(ev)) return;
      if (ev === "keystroke") {
        if (this.time - this.lastKeystroke < 0.07) return;
        this.lastKeystroke = this.time;
        const room = Math.max(0, 1 - Math.abs(this.x("sqB")) / 0.3);
        this.kick("sqB", -1.1 * room); this.kick("el", 1.4 * room);
        return;
      }
      if (ev === "chunk") {
        if (this.time - this.lastChunk < 0.12) return;
        this.lastChunk = this.time;
        this.kick("swellA", 0.45); this.kick("wobA", 0.5);
        return;
      }
      this.running = this.running.filter((r) => r.event !== ev);
      this.running.push({ event: ev, age: 0, fired: new Set(), a, b });
    }

    splash(c, amp) { this.ripple = { c, amp, age: 0 }; }

    play(r, t) {
      const a = r.age;
      const set = (n, v) => { t[I[n]] = v; };
      const once = (id, at, fn) => { if (a >= at && !r.fired.has(id)) { r.fired.add(id); fn(); } };
      const S = this.springs;
      switch (r.event) {
        case "send":
          if (a < 0.22) { set("sep", 0.22); set("k", 0.36); }
          once(0, 0, () => this.kick("sqB", -1.6));
          once(1, 0.16, () => { this.kick("swellA", 1.3); this.splash(add(this.cA, mul(this.dir, this.rA * 0.9)), 0.03); });
          return a < 0.9;
        case "done":
          if (a < 0.30) { set("sep", 0.0); set("k", 0.34); } else if (a < 0.95) set("sep", 0.04);
          once(0, 0.26, () => {
            this.kick("sqA", 3.4); this.kick("sqB", 2.0); this.kick("comY", -0.9);
            this.splash(add(this.cA, [0, this.rA, 0]), 0.045);
          });
          once(1, 0.95, () => this.kick("sep", 2.6));
          return a < 1.7;
        case "deliverable":
          once(0, 0, () => {
            this.kick("sqA", -1.6);
            this.droplet = { p: add(this.cA, [this.rA * 0.55, 0.06, 0.04]), v: [1.25, 0.95, 0.25], r: 0.001 };
          });
          once(1, 0.12, () => { this.splash(add(this.cA, [this.rA * 0.9, 0.08, 0]), 0.04); this.kick("swellA", -0.6); });
          this.droplet.r = a < 0.2 ? 0.13 * a / 0.2 : Math.max(0, 0.13 * (1 - (a - 0.2) / 1.1));
          return a < 1.4;
        case "approve":
          if (a < 0.55) set("sep", 0.08);
          once(0, 0.17, () => { this.kick("comY", 1.8); this.kick("sqA", 2.2); this.kick("glowB", 3); });
          once(1, 0.55, () => this.kick("sep", 2.2));
          return a < 1.2;
        case "reject":
          if (a < 0.4) { set("reach", -0.22); t[I.sep] += 0.12; }
          once(0, 0, () => { S[I.shiver].x = 1; });
          once(1, 0.05, () => this.kick("sqA", -1.2));
          return a < 1.1;
        case "error":
          once(0, 0, () => this.kick("sep", 5.0));
          once(1, 0.05, () => { this.kick("sqA", -1.5); this.kick("sqB", -1.5); });
          if (a < 0.9) set("sep", 1.55);
          if (a < 1.3) { set("size", 0.82); set("bright", 0.6); set("sat", 0.75); }
          this.shakeX = a < 2 ? 0.07 * Math.sin(a * 42) * Math.exp(-a * 3.2) : 0;
          return a < 2.0;
        case "reconnect":
          once(0, 0, () => {
            S[I.sat].x = 1; S[I.sat].v = 0;
            const g = (c) => { const l = c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722; return [l * 0.9 + 0.05, l * 0.9 + 0.05, l * 0.9 + 0.05]; };
            this.fill = { on: true, c: this.cA.slice(), r: 0, fromA: g(this.primary), fromB: g(this.partner), toA: this.primary, toB: this.partner };
          });
          this.fill.r = 2.4 * easeOut(Math.min(a / 1.0, 1));
          if (a >= 1.0) this.fill.on = false;
          if (a >= 1.0 && a < 1.35) set("sep", 0.18);
          once(1, 1.35, () => this.kick("sep", 1.5));
          return a < 1.8;
        case "appOpen":
          once(0, 0, () => { S[I.sep].x = 0.1; S[I.bright].x = 0.7; });
          if (a >= 0.12 && a < 1.35) { set("sep", 0.98); set("orbitMix", 1); set("azVel", Math.PI / 1.2); set("anchor", 0); }
          else if (a >= 1.35 && a < 1.75) set("sep", 0.25);
          return a < 2.2;
        case "colorChange":
          once(0, 0, () => {
            this.fill = { on: true, c: add(this.cA, mul(this.dir, this.rA)), r: 0, fromA: this.primary, fromB: this.partner, toA: r.a, toB: r.b };
            this.kick("swellA", 0.6);
          });
          this.fill.r = 1.8 * easeInOut(Math.min(a / 1.1, 1));
          if (a >= 1.25) { this.primary = r.a; this.partner = r.b; this.fill.on = false; }
          return a < 1.25;
      }
      return false;
    }

    advance(dt) {
      dt = clamp(dt, 0, 0.1);
      this.time += dt;
      const m = this.mode;
      const t = this.targets(m);
      const life = this.x("life");
      if (!this.reduceMotion) {
        this.noiseT += dt * life;
        const n = (ch) => this.noise(ch, this.noiseT);
        const free = t[I.anchor] > 0.5 ? 0.25 : 1;
        t[I.sep] += 0.06 * n(0) * life;
        t[I.el] += 0.32 * n(1) * life * free;
        t[I.ratio] += 0.035 * n(2) * life;
        t[I.k] += 0.05 * n(3) * life;
        t[I.wobA] += 0.12 * n(4) * life;
        t[I.comY] += 0.025 * n(5) * life;
        t[I.azVel] += 0.15 * n(6) * life * free;
        t[I.sqA] += 0.035 * n(7) * life;
        t[I.sqB] += 0.05 * n(8) * life;
        t[I.reach] += 0.03 * n(9) * life;
      }
      if (m === "quiet") t[I.swellA] += 0.025 * Math.sin(this.time * 2 * Math.PI * 0.12);

      if (m === "approval" && !this.reduceMotion) {
        const period = 3.0, prev = this.knockClock;
        this.knockClock = (this.knockClock + dt) % period;
        const wrapped = this.knockClock < prev;
        for (const hit of [0.35, 0.59]) {
          const crossed = wrapped ? (prev < hit || this.knockClock >= hit) : (prev < hit && this.knockClock >= hit);
          if (crossed) { this.kick("reach", 2.4); this.kick("glowB", 1.2); }
        }
      } else this.knockClock = 0;

      if (!this.reduceMotion) {
        for (let i = this.running.length - 1; i >= 0; i--) {
          this.running[i].age += dt;
          if (!this.play(this.running[i], t)) this.running.splice(i, 1);
        }
      } else this.running = [];

      for (let i = 0; i < this.springs.length; i++) this.springs[i].target = t[i];
      this.springs[I.shiver].target = 0;
      if (this.reduceMotion) {
        for (const s of this.springs) { s.x = s.target; s.v = 0; }
      } else {
        const steps = Math.max(1, Math.ceil(dt / (1 / 240)));
        const h = dt / steps;
        for (let k = 0; k < steps; k++) for (const s of this.springs) { s.v += (s.k * (s.target - s.x) - s.c * s.v) * h; s.x += s.v * h; }
      }

      const anchor = clamp(this.x("anchor"), 0, 1);
      const drift = (1 - clamp(this.x("orbitMix"), 0, 1)) * (1 - anchor);
      this.az += this.x("azVel") * dt * (1 + drift * (1.6 * Math.abs(Math.sin(this.az)) - 0.45));
      if (anchor > 0) {
        let delta = (this.anchorAz - this.az) % (2 * Math.PI);
        if (delta > Math.PI) delta -= 2 * Math.PI; else if (delta < -Math.PI) delta += 2 * Math.PI;
        this.az += delta * (1 - Math.exp(-3.5 * dt)) * anchor;
      }
      if (this.reduceMotion) this.az = anchor > 0.5 ? this.anchorAz : 0.6;
      this.az %= 2 * Math.PI;

      if (!this.reduceMotion) {
        this.wobPhase += dt * this.x("wobSpeed") * life;
        this.flowPhase += dt * this.x("flowSpeed");
        this.shiverPhase += dt;
        this.ripple.age += dt;
        this.ripple.amp *= Math.exp(-2.4 * dt);
        if (this.droplet.r > 0) {
          this.droplet.p = add(this.droplet.p, mul(this.droplet.v, dt));
          this.droplet.v[1] -= 3.2 * dt;
        }
      } else { this.ripple.amp = 0; this.droplet.r = 0; }
      this.updateGeometry();
    }

    updateGeometry() {
      const size = Math.max(this.x("size"), 0.05);
      this.rA = 0.52 * size * Math.max(1 + this.x("swellA"), 0.6);
      this.rB = 0.52 * size * Math.max(this.x("ratio"), 0.2) * Math.max(1 + this.x("swellB"), 0.6);
      const om = clamp(this.x("orbitMix"), 0, 1);
      const drift = (1 - om) * (1 - clamp(this.x("anchor"), 0, 1));
      const az = this.az;
      const el = this.x("el") + 0.75 * Math.max(0, -Math.sin(az)) * drift;
      const sph = v3(Math.cos(el) * Math.cos(az), Math.sin(el), Math.cos(el) * Math.sin(az));
      const incl = 0.42;
      const orb = v3(Math.cos(az), -Math.sin(az) * Math.sin(incl), Math.sin(az) * Math.cos(incl));
      let d = add(mul(sph, 1 - om), mul(orb, om));
      d = norm(d);
      this.dir = this.offCenter(d);
      const mA = this.rA ** 3, mB = this.rB ** 3;
      const sep = Math.max(this.x("sep"), 0) * size;
      const com = v3(this.shakeX + 0.07 * this.x("leanX"), this.x("comY") + 0.05 * this.x("leanY"), 0);
      this.cA = add(com, mul(this.dir, -sep * mB / (mA + mB)));
      const sh = Math.max(this.x("shiver"), 0);
      this.cA = add(this.cA, [0.028 * Math.sin(this.shiverPhase * 57) * sh, 0.012 * Math.sin(this.shiverPhase * 43) * sh, 0]);
      this.cB = add(com, mul(this.dir, sep * mA / (mA + mB)));
    }

    // Seen from the front, one drop centered over the other reads as an eye;
    // keep the small one out toward an edge when it's in front or behind.
    offCenter(d) {
      const depth = Math.abs(d[2]);
      const need = 0.80 * smoothstep(0.15, 0.6, depth);
      const fl = Math.hypot(d[0], d[1]);
      if (fl >= need) return d;
      let sx, sy;
      if (fl > 1e-3) { sx = d[0] / fl; sy = d[1] / fl; } else { const l = Math.hypot(0.9, 0.45); sx = 0.9 / l; sy = 0.45 / l; }
      const z = Math.sqrt(1 - need * need) * (d[2] >= 0 ? 1 : -1);
      return [sx * need, sy * need, z];
    }

    uniforms(dark, scale, out) {
      const u = out || new Float32Array(60);
      u.fill(0);
      const put = (i, v) => { u[i] = v[0]; u[i + 1] = v[1]; u[i + 2] = v[2]; };
      u[0] = this.time; u[1] = dark ? 1 : 0; u[2] = scale; u[3] = this.x("zoom") * this.frameZoom;
      put(4, this.primary); u[7] = clamp(this.x("sat"), 0, 1.2);
      put(8, this.partner); u[11] = Math.max(this.x("bright"), 0);
      put(12, this.cA); u[15] = this.rA;
      put(16, this.cB); u[19] = this.rB;
      put(20, this.dir); u[23] = this.x("reach");
      const lifeC = clamp(this.x("life"), 0, 1);
      u[24] = this.x("sqA"); u[25] = this.x("sqB"); u[26] = Math.max(this.x("k"), 0.02); u[27] = Math.max(this.x("wobA"), 0) * lifeC;
      u[28] = this.wobPhase; u[29] = Math.max(this.x("flow"), 0); u[30] = this.flowPhase; u[31] = clamp(this.x("frost"), 0, 1);
      put(32, this.ripple.c); u[35] = this.ripple.amp;
      u[36] = this.ripple.age * 14; u[37] = Math.max(this.x("glowB"), 0); u[38] = Math.max(this.x("shiver"), 0); u[39] = -0.98;
      put(40, this.droplet.p); u[43] = this.droplet.r;
      if (this.fill.on) {
        put(4, this.fill.fromA); put(8, this.fill.fromB);
        put(44, this.fill.toA); u[47] = Math.max(this.fill.r, 0.001);
        put(48, this.fill.toB);
      } else { put(44, this.primary); u[47] = 0; put(48, this.partner); }
      u[51] = this.shiverPhase;
      put(52, this.fill.c); u[55] = Math.max(this.x("wobB"), 0) * lifeC;
      u[56] = clamp(this.x("clarity"), 0, 1);
      return u;
    }
  }

  // ---------------------------------------------------------------- renderer

  const HQ = /[?&]hq\b/.test(location.search);   // captures: never trade resolution for speed
  const reduceQuery = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  const all = new Set();

  class Drops {
    constructor(canvas, opts) {
      opts = opts || {};
      this.canvas = canvas;
      this.state = new DropsState(hexToRGB(opts.primary || "#D156A7"), hexToRGB(opts.partner || "#8B6BFF"), opts.seed);
      this.state.frameZoom = opts.frameZoom || 1;
      this.maxPixels = opts.maxPixels || 900;     // cap on the backing store's long side
      this.quality = 1;                            // adapted from frame times
      this.onFrame = opts.onFrame || null;         // (dt, state) → per-frame driving
      this.visible = false;
      this.running = false;
      this.last = 0;
      this.u = new Float32Array(60);
      this.slowFrames = 0;
      this.fastFrames = 0;
      const gl = canvas.getContext("webgl2", { premultipliedAlpha: true, alpha: true, antialias: false, powerPreference: "low-power" });
      this.gl = gl;
      if (!gl) { canvas.classList.add("drops-fallback"); return; }
      const sh = (type, src) => {
        const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
        return s;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
      this.prog = prog;
      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, "aPos");
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      this.uP = gl.getUniformLocation(prog, "P");
      this.uSize = gl.getUniformLocation(prog, "uSize");

      this.io = new IntersectionObserver((es) => {
        for (const e of es) this.visible = e.isIntersecting;
        this.kickLoop();
      }, { rootMargin: "80px" });
      this.io.observe(canvas);
      this.ro = new ResizeObserver(() => this.draw());
      this.ro.observe(canvas);
      all.add(this);
      this.applyMotionPref();
      this.state.advance(0.016);
      this.draw();
    }

    applyMotionPref() {
      this.state.reduceMotion = !!(reduceQuery && reduceQuery.matches);
    }

    get dark() {
      const t = document.documentElement.getAttribute("data-theme");
      if (t === "dark") return true;
      if (t === "light") return false;
      return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
    }

    kickLoop() {
      const shouldRun = this.visible && !document.hidden;
      if (shouldRun && !this.running) {
        this.running = true; this.last = performance.now();
        const tick = (now) => {
          if (!this.running) return;
          const dt = Math.min((now - this.last) / 1000, 0.1);
          this.last = now;
          if (this.onFrame) this.onFrame(dt, this.state);
          this.state.advance(dt);
          this.adapt(dt);
          this.draw();
          if (this.state.reduceMotion) { this.running = false; return; }
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      } else if (!shouldRun) this.running = false;
    }

    // Keep it smooth on slow GPUs: lower the backing resolution when frames
    // run long, raise it back when there's room.
    adapt(dt) {
      if (HQ) return;
      if (dt > 0.026) { this.slowFrames++; this.fastFrames = 0; }
      else if (dt < 0.018) { this.fastFrames++; this.slowFrames = 0; }
      if (this.slowFrames > 20 && this.quality > 0.5) { this.quality = Math.max(0.5, this.quality - 0.15); this.slowFrames = 0; }
      if (this.fastFrames > 240 && this.quality < 1) { this.quality = Math.min(1, this.quality + 0.1); this.fastFrames = 0; }
    }

    draw() {
      const gl = this.gl;
      if (!gl) return;
      const r = this.canvas.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      let w = r.width * dpr, h = r.height * dpr;
      const cap = this.maxPixels / Math.max(w, h);
      const s = Math.min(1, cap) * this.quality;
      w = Math.max(1, Math.round(w * s)); h = Math.max(1, Math.round(h * s));
      if (this.canvas.width !== w || this.canvas.height !== h) { this.canvas.width = w; this.canvas.height = h; }
      gl.viewport(0, 0, w, h);
      gl.useProgram(this.prog);
      const scale = w / r.width;
      this.state.uniforms(this.dark, scale, this.u);
      gl.uniform1fv(this.uP, this.u);
      gl.uniform2f(this.uSize, w, h);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    // One still frame (reduced motion, or a pose change while paused).
    refresh() { if (!this.running) { this.state.advance(0.016); this.draw(); } }
  }

  document.addEventListener("visibilitychange", () => { for (const d of all) d.kickLoop(); });
  if (reduceQuery && reduceQuery.addEventListener) reduceQuery.addEventListener("change", () => { for (const d of all) { d.applyMotionPref(); d.kickLoop(); d.refresh(); } });
  if (window.matchMedia) {
    const dq = window.matchMedia("(prefers-color-scheme: dark)");
    if (dq.addEventListener) dq.addEventListener("change", () => { for (const d of all) d.refresh(); });
  }

  window.Drops = Drops;
  window.Drops.all = all;
})();
