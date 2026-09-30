#include <metal_stdlib>
using namespace metal;

// The presence: filament heart, rings of data blocks, drifting motes, a radiant core.
// Everything is generated from small instance buffers plus per-frame uniforms, drawn additively
// into an HDR target, then bloomed and tone-mapped onto black (PresenceRenderer.swift).
//
// Uniforms are float4 slots (PresenceEngine.uniforms):
//  0 viewport.w, viewport.h, radius px, time        1 center.x, center.y, pixel scale, energy
//  2 voice, mic, assembly, breakup                   3 thinking, listening, speaking, ignition
//  4..6 rotation rows                                7 ring phases 0..3
//  8 ring phase 4, flash, room light, formed         9..13 ring state: lit, kind, pulse, focus
//  14 bands 0..3                                     15 bands 4..7
//  16..19 palette: glow, light, alert, ember (xyz)   20 absorb, 0, 0, 0
// Ring state z: the tasks ring's running wave (0..1), plus 1 + its done flash (1..2).

// The agent's palette (AgentPalette), blended by the engine when it changes. Every shader that
// uses a colour has the uniforms in scope as `U`.
#define GLOW (U[16].xyz)
#define LIGHT (U[17].xyz)
#define ALERT (U[18].xyz)
#define EMBER (U[19].xyz)
constant float TAU = 6.2831853;

struct VOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

struct EdgeInst { float4 a; float4 b; };      // xyz + seed
struct BlockInst { float4 a; float4 b; };     // ring, index, angle0, span | seed, blocks in ring, 0, 0
struct RingInst { float4 a; float4 b; };      // radius, tiltX, tiltZ, height | blocks, fill, 0, 0

static float ease(float x) { x = saturate(x); return x * x * (3 - 2 * x); }

static float hash(float n) { return fract(sin(n * 12.9898 + 78.233) * 43758.5453); }

/// 0 when an element is in place; grows while scattered (assembling) or flying off (breaking apart).
static float spread(float seed, float assembly, float breakup) {
    float arrived = ease((assembly - seed * 0.45) / 0.55);
    return (1 - arrived) * (1.4 + seed * 1.8) + breakup * breakup * (1 + seed * 2.2);
}

static float3 scatter(float3 p, float seed, constant float4 *U) {
    float amount = spread(seed, U[2].z, U[2].w);
    if (amount < 0.001) return p;
    float twist = amount * (0.6 + seed);
    float s = sin(twist), c = cos(twist);
    return float3(p.x * c - p.z * s, p.y, p.x * s + p.z * c) * (1 + amount);
}

/// World (unit sphere) → pixels (top-left origin) and depth (+ toward the viewer).
static float3 toScreen(float3 p, constant float4 *U) {
    float3 r = float3(dot(U[4].xyz, p), dot(U[5].xyz, p), dot(U[6].xyz, p));
    float persp = 3.2 / (3.2 - r.z * 0.6);
    float2 screen = U[1].xy + float2(r.x, -r.y) * U[0].z * persp;
    return float3(screen, r.z);
}

static float4 toClip(float2 screen, constant float4 *U) {
    float2 ndc = screen / U[0].xy * 2 - 1;
    return float4(ndc.x, -ndc.y, 0, 1);
}

static float3 ringPoint(RingInst ring, float angle, float radius) {
    float3 p = float3(cos(angle), 0, sin(angle)) * radius;
    float tx = ring.a.y, tz = ring.a.z;
    p = float3(p.x, p.y * cos(tx) - p.z * sin(tx), p.y * sin(tx) + p.z * cos(tx));
    return float3(p.x * cos(tz) - p.y * sin(tz), p.x * sin(tz) + p.y * cos(tz), p.z);
}

static float ringPhase(int ring, constant float4 *U) {
    return ring < 4 ? U[7][ring] : U[8].x;
}

static float band(int index, constant float4 *U) {
    index = index % 8;
    return index < 4 ? U[14][index] : U[15][index - 4];
}

// MARK: filaments and ring tracks (anti-aliased line quads)

vertex VOut edgeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant EdgeInst *edges [[buffer(0)]], constant float4 *U [[buffer(1)]],
                       constant float &mode [[buffer(2)]]) {
    EdgeInst e = edges[iid];
    float t = U[0].w, voice = U[2].x, formed = U[8].w;
    float3 pa = e.a.xyz, pb = e.b.xyz;
    bool track = mode > 0.5;
    if (!track) {
        pa *= 1 + voice * 0.12 * sin(t * 9 + e.a.w * TAU) + 0.02 * sin(t * 1.3 + e.a.w * TAU);
        pb *= 1 + voice * 0.12 * sin(t * 9 + e.b.w * TAU) + 0.02 * sin(t * 1.3 + e.b.w * TAU);
        pa = scatter(pa, e.a.w, U);
        pb = scatter(pb, e.b.w, U);
    }
    float3 sa = toScreen(pa, U), sb = toScreen(pb, U);
    float2 d = sb.xy - sa.xy;
    float2 dir = length(d) > 1e-4 ? normalize(d) : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    float side = (vid % 2 == 0) ? -1.0 : 1.0;
    float width = (track ? 0.4 : 0.42) * U[1].z;
    float2 base = vid < 2 ? sa.xy : sb.xy;
    VOut out;
    out.position = toClip(base + normal * side * (width + U[1].z), U);
    out.uv = float2(side, (width + U[1].z) / U[1].z);  // edge ±1; y: outer width in feather pixels

    float depth = (sa.z + sb.z) * 0.5;
    float3 color;
    float alpha;
    if (track) {
        float settled = ease((U[2].z - 0.6) / 0.4) * (1 - U[2].w);
        color = depth > 0 ? GLOW : EMBER;
        alpha = (depth > 0 ? 0.35 : 0.25) * settled;
    } else {
        float near = saturate(depth * 0.5 + 0.5);
        color = mix(ALERT * 0.6, GLOW, near);
        alpha = mix(0.05, 0.8, near * near * near) * (0.6 + voice * 0.4) * formed;
        // Thinking: signals travel through the network.
        float signal = pow(saturate(1 - abs(fract(t * 0.55 + e.b.w * 3.7) - 0.5) * 7), 3.0) * U[3].x;
        color = mix(color, LIGHT, signal);
        alpha += signal * 0.9 * formed;
    }
    out.color = float4(color * alpha, 1);
    return out;
}

fragment float4 lineFragment(VOut in [[stage_in]]) {
    float coverage = saturate((1 - abs(in.uv.x)) * in.uv.y);
    return float4(in.color.rgb * coverage, 0);
}

// MARK: ring blocks

vertex VOut blockVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant BlockInst *blocks [[buffer(0)]], constant float4 *U [[buffer(1)]],
                        constant RingInst *rings [[buffer(3)]]) {
    BlockInst b = blocks[iid];
    int ringIndex = int(b.a.x);
    RingInst ring = rings[ringIndex];
    float index = b.a.y, seed = b.b.x, count = b.b.y;
    float t = U[0].w, voice = U[2].x;
    float4 state = U[9 + ringIndex];

    // The voice runs around each ring as a wave: neighbours move together, each block lifted by its neighbours' level.
    float level = band(int(index / count * 8), U);
    float travel = 0.5 + 0.5 * sin(index * 0.45 - t * 7 + ringIndex * 1.7);
    float wave = saturate(level * 2.2) * travel * voice;
    float breathe = 0.12 * (0.5 + 0.5 * sin(t * 0.8 + index * 0.21));
    float lit = index < state.x ? 1.0 : 0.0;
    float lift = ring.a.w * (0.35 + 0.65 * hash(seed * 91 + ringIndex) + 2.4 * wave + breathe + lit * 0.9);

    float a0 = b.a.z + ringPhase(ringIndex, U);
    float a1 = a0 + b.a.w * ring.b.y;
    float angle = (vid == 0 || vid == 2) ? a0 : a1;
    float radius = ring.a.x + (vid >= 2 ? lift : 0);
    float3 p = scatter(ringPoint(ring, angle, radius), seed, U);
    float3 s = toScreen(p, U);

    VOut out;
    out.position = toClip(s.xy, U);
    out.uv = float2(0);
    float3 mid = toScreen(ringPoint(ring, (a0 + a1) * 0.5, ring.a.x), U);
    float depth = mid.z;
    float3 color = depth < -0.1 ? EMBER * 0.55 : (wave > 0.55 ? LIGHT : GLOW * 0.85);
    if (lit > 0) {
        float kind = state.y;
        if (kind < 1.5) {
            color = LIGHT * 1.7;                                               // messages
        } else if (kind < 2.5) {
            color = ALERT * (1.4 + 0.9 * sin(t * 5));                          // requests
        } else if (kind < 3.5) {
            color = GLOW * (1.9 + 0.4 * sin(t * 2 + index));                   // results
        } else {
            // tasks: progress fills the ring; a bright pulse runs along the filled part while working
            float running = saturate(state.z);
            float head = fract(t * 0.6) * max(state.x, 1.0);
            float pulse = exp(-pow((index - head) / 3.0, 2.0)) * running;
            color = mix(GLOW * 1.5, LIGHT * 2.2, pulse);
        }
    }
    if (state.y > 3.5 && state.z > 1.0) {
        color = mix(color, float3(2.4), state.z - 1.0);                        // tasks done: white flash
    }
    color *= 1 + state.w * 0.8;  // focused ring (VoiceOver / touch)
    out.color = float4(color * U[8].w, 1);
    return out;
}

fragment float4 flatFragment(VOut in [[stage_in]]) {
    return float4(in.color.rgb, 0);
}

// MARK: filament nodes and motes (soft round points)

vertex VOut nodeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant float4 *nodes [[buffer(0)]], constant float4 *U [[buffer(1)]]) {
    float4 n = nodes[iid];
    float t = U[0].w, voice = U[2].x;
    float3 p = n.xyz * (1 + voice * 0.12 * sin(t * 9 + n.w * TAU) + 0.02 * sin(t * 1.3 + n.w * TAU));
    float3 s = toScreen(scatter(p, n.w, U), U);
    float near = saturate(s.z * 0.5 + 0.5);
    float size = (1.0 + 1.6 * near) * U[1].z;
    float2 corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    VOut out;
    out.position = toClip(s.xy + corner * size, U);
    out.uv = corner;
    out.color = float4(LIGHT * (0.35 + 0.6 * near) * U[8].w, 1);
    return out;
}

vertex VOut moteVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4 *U [[buffer(1)]]) {
    float id = float(iid);
    float h1 = hash(id * 1.37), h2 = hash(id * 2.71 + 3), h3 = hash(id * 5.11 + 7);
    float t = U[0].w, voice = U[2].x, thinking = U[3].x, assembly = U[2].z, breakup = U[2].w;
    float shell = 1.08 + h1 * h1 * 0.6;
    // Thinking: motes spiral inward and are reborn outside.
    float inward = fract(t * 0.18 + h1);
    float r = mix(shell, mix(shell, 0.25, inward), thinking);
    // Assembling: they stream in from far away; breaking apart: they fly off.
    r = mix(7 + h1 * 5, r, ease(assembly * 1.25 - h1 * 0.25));
    r *= 1 + breakup * breakup * (3 + h2 * 4);
    // Absorbing (a photo shown to the agent): motes fall into the heart.
    float absorb = U[20].x;
    float fall = fract(t * 0.9 + h2);
    r = mix(r, mix(r, 0.08, fall * fall), absorb);
    float speed = (0.04 + 0.12 * h3) * (1 + voice * 2.5 + thinking * 2 + absorb * 3);
    float theta = h2 * TAU + t * speed * (h1 > 0.5 ? 1 : -1);
    float phi = acos(2 * h3 - 1);
    float3 p = float3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)) * r;
    float3 s = toScreen(p, U);
    float near = saturate(s.z * 0.3 + 0.5);
    float size = (0.7 + 1.1 * h2) * U[1].z;
    float2 corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    // Near the sphere at rest; everywhere while streaming in or flying off.
    float fade = max(saturate(1.9 - r), saturate((1 - assembly) * 1.5 + breakup * (1 - breakup) * 3))
        * (1 - thinking * inward * inward);
    VOut out;
    out.position = toClip(s.xy + corner * size, U);
    out.uv = corner;
    fade = max(fade, absorb * (1 - fall * fall * 0.6));
    float brightness = (0.1 + 0.3 * near + voice * 0.35 + thinking * 0.2 + absorb * 0.5) * fade * (0.5 + 0.5 * U[1].w);
    out.color = float4(mix(GLOW, LIGHT, h3) * brightness, 1);
    return out;
}

fragment float4 pointFragment(VOut in [[stage_in]]) {
    float falloff = saturate(1 - dot(in.uv, in.uv));
    return float4(in.color.rgb * falloff * falloff, 0);
}

// MARK: the heart's core (a quad around the center)

vertex VOut coreVertex(uint vid [[vertex_id]], constant float4 *U [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    float extent = U[0].z * 0.9;
    VOut out;
    out.position = toClip(U[1].xy + corner * extent, U);
    out.uv = corner * 0.9;  // in sphere radii
    out.color = float4(0);
    return out;
}

fragment float4 coreFragment(VOut in [[stage_in]], constant float4 *U [[buffer(1)]]) {
    float t = U[0].w, voice = U[2].x, thinking = U[3].x, listening = U[3].y;
    float heat = U[3].w * (1 - listening * 0.35) * (0.45 + 0.55 * U[1].w) * max(0.0, 1 - U[2].w * 1.4);
    float pulse = (1 + mix(0.06 * sin(t * 3), 0.16 * sin(t * 1.6), thinking) + voice * 0.4) * (1 + U[8].y * 1.5);
    float d = length(in.uv) / pulse;
    float bloom = exp(-d * d / 0.012) * 1.6 + exp(-d * d / 0.06) * 0.5;
    float ringLine = exp(-pow((d - 0.07) / 0.006, 2.0)) * 0.9;
    float hot = exp(-d * d / 0.0009) * 3.0;
    float3 color = GLOW * bloom + LIGHT * ringLine + float3(1) * hot;
    return float4(color * heat, 0);
}

// MARK: post: bloom chain and composite

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    QuadOut out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = uv;
    return out;
}

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

/// Half-resolution 4-tap box; the first level also cuts everything below `threshold`.
fragment float4 downsampleFragment(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                   constant float &threshold [[buffer(0)]]) {
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 c = source.sample(linearClamp, in.uv + texel * float2(-1, -1)).rgb
             + source.sample(linearClamp, in.uv + texel * float2(1, -1)).rgb
             + source.sample(linearClamp, in.uv + texel * float2(-1, 1)).rgb
             + source.sample(linearClamp, in.uv + texel * float2(1, 1)).rgb;
    c *= 0.25;
    return float4(max(c - threshold, 0.0), 1);
}

/// 3×3 tent, added onto the next larger level.
fragment float4 upsampleFragment(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 c = source.sample(linearClamp, in.uv).rgb * 4;
    c += (source.sample(linearClamp, in.uv + texel * float2(1, 0)).rgb + source.sample(linearClamp, in.uv - texel * float2(1, 0)).rgb
        + source.sample(linearClamp, in.uv + texel * float2(0, 1)).rgb + source.sample(linearClamp, in.uv - texel * float2(0, 1)).rgb) * 2;
    c += source.sample(linearClamp, in.uv + texel).rgb + source.sample(linearClamp, in.uv - texel).rgb
       + source.sample(linearClamp, in.uv + texel * float2(1, -1)).rgb + source.sample(linearClamp, in.uv + texel * float2(-1, 1)).rgb;
    return float4(c / 16, 1);
}

/// Scene + bloom + the room's warm light on black, tone-mapped.
fragment float4 compositeFragment(QuadOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]], constant float4 *U [[buffer(1)]]) {
    float3 c = scene.sample(linearClamp, in.uv).rgb + bloom.sample(linearClamp, in.uv).rgb * 1.2;
    float2 pixel = in.uv * U[0].xy;
    float d = length(pixel - U[1].xy) / (U[0].z * 2.6);
    float room = U[8].z * (0.10 + 0.06 * U[2].x) * exp(-d * d * 1.4);
    c += GLOW * room + EMBER * room * 0.8;
    c = 1 - exp(-c * 1.15);
    return float4(c, 1);
}
