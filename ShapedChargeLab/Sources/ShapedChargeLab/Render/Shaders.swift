// Metal source compiled at runtime (no Xcode metal toolchain needed).
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

#define INST_CAP 3000000u
#define GAS_CAP 1200000u

struct RP { float x; float z; float radius; float temp; float speed; float pressure; float strain; float aux; uint matFlags; };
struct Inst { float4 posR; uint color; uint params; };

struct U {
    float4x4 view;
    float4x4 proj;
    float4x4 invView;
    float4 a;   // viewport w, h, time, mm→world
    float4 b;   // cutCenter, cutHalf, extrude(mm), groundY(world)
    uint4  c;   // colorMode, axi, showGas, count
    float4 d;   // speedMax, chargeR, chargeL, zFace
    float4 e;   // targetR, zBack, CD, tipZ
    float4 f;   // linerKind, targetKind, pressureMax, strainMax
    float4 g;   // 3D frame quantisation origin xyz, xy span
    float4 h;   // z span, fine spacing, coarse spacing, visibility bits (1 explosive, 2 target)
};

// ---------- colour helpers ----------
float3 turbo(float t) {
    t = saturate(t);
    const float4 kR = float4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const float4 kG = float4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const float4 kB = float4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const float2 kR2 = float2(-152.94239396, 59.28637943);
    const float2 kG2 = float2(4.27729857, 2.82956604);
    const float2 kB2 = float2(-89.90310912, 27.34824973);
    float4 v4 = float4(1.0, t, t * t, t * t * t);
    float2 v2 = v4.zw * v4.z;
    return float3(dot(v4, kR) + dot(v2, kR2), dot(v4, kG) + dot(v2, kG2), dot(v4, kB) + dot(v2, kB2));
}

float3 blackbody(float T) {
    // compact approximation, normalised colour
    float t = clamp((T - 800.0) / 2800.0, 0.0, 1.0);
    float3 c = mix(float3(1.0, 0.18, 0.02), float3(1.0, 0.55, 0.15), smoothstep(0.0, 0.45, t));
    c = mix(c, float3(1.0, 0.93, 0.78), smoothstep(0.45, 1.0, t));
    return c;
}

// ---------- instance expansion ----------
kernel void resetArgs(device uint* args [[buffer(0)]], device uint* gargs [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id == 0) { args[0] = 4; args[1] = 0; args[2] = 0; args[3] = 0; gargs[0] = 4; gargs[1] = 0; gargs[2] = 0; gargs[3] = 0; }
}

kernel void clampArgs(device uint* args [[buffer(0)]], device uint* gargs [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id == 0) { args[1] = min(args[1], INST_CAP); gargs[1] = min(gargs[1], GAS_CAP); }
}

kernel void expand(device const RP* P [[buffer(0)]],
                   device Inst* I [[buffer(1)]],
                   device atomic_uint* args [[buffer(2)]],
                   device Inst* G [[buffer(3)]],
                   device atomic_uint* gargs [[buffer(4)]],
                   constant U& u [[buffer(5)]],
                   uint id [[thread_position_in_grid]]) {
    if (id >= u.c.w) return;
    RP p = P[id];
    uint mat = p.matFlags & 0xffu;
    uint fl = p.matFlags >> 8;
    bool gas = (fl & 2u) != 0u;
    bool surf = (fl & 1u) != 0u;
    bool damaged = (fl & 4u) != 0u;
    if (gas && u.c.z == 0u) return;

    float s = u.a.w;
    float wx = (p.z - u.d.z) * s;
    float r = p.x * s;
    float rad = p.radius * s;

    float3 alb; float metal = 0.0; float rough = 0.6; float emis = 0.0;
    uint mode = u.c.x;
    if (gas) {
        float t = saturate((p.temp - 400.0) / 3400.0);
        alb = blackbody(400.0 + t * 3400.0);
        emis = t;
    } else {
        if (mat == 0u) { alb = float3(0.46, 0.43, 0.33); metal = 0.0; rough = 0.8; }
        else if (mat == 1u) {
            float k = u.f.x;
            alb = k < 0.5 ? float3(0.96, 0.58, 0.40) : (k < 1.5 ? float3(0.60, 0.62, 0.70) : float3(0.88, 0.89, 0.91));
            metal = 1.0; rough = 0.24;
        } else {
            alb = u.f.y < 0.5 ? float3(0.50, 0.52, 0.55) : float3(0.82, 0.84, 0.87);
            metal = 1.0; rough = 0.42;
        }
        if (damaged) { rough = min(rough + 0.25, 1.0); alb *= 0.82; }
        if (mode == 1u) { alb = turbo(p.speed / max(u.d.x, 0.1)); metal = 0.15; rough = 0.45; }
        else if (mode == 2u) { alb = turbo(log2(1.0 + max(p.pressure, 0.0)) / log2(1.0 + u.f.z)); metal = 0.15; rough = 0.45; }
        else if (mode == 3u) { alb = turbo((p.temp - 300.0) / 1300.0); metal = 0.15; rough = 0.45; }
        else if (mode == 4u) { alb = turbo(p.strain / max(u.f.w, 0.1)); metal = 0.15; rough = 0.45; }
        if (mat != 0u) {
            float glow = saturate((p.temp - 1000.0) / 1200.0);
            emis = glow * glow * 0.35;
        }
    }
    uint col = pack_float_to_unorm4x8(float4(saturate(alb), 1.0));

    if (u.c.y == 1u && (uint(u.h.w) & 4u) != 0u) {
        // slice only: draw the computed r–z plane, facing the camera, and nothing revolved
        uint par = pack_float_to_unorm4x8(float4(metal, rough, emis, 1.0 / 255.0));
        device atomic_uint* ctr = gas ? &gargs[1] : &args[1];
        uint base = atomic_fetch_add_explicit(ctr, 2u, memory_order_relaxed);
        if (base + 2u > (gas ? GAS_CAP : INST_CAP)) return;
        for (uint k = 0; k < 2u; k++) {
            float th = u.b.x + (k == 0u ? 1.5707963 : -1.5707963);
            float4 pr = float4(wx, r * cos(th), r * sin(th), rad);
            if (gas) { G[base + k].posR = pr; G[base + k].color = col; G[base + k].params = par; }
            else { I[base + k].posR = pr; I[base + k].color = col; I[base + k].params = par; }
        }
        return;
    }
    if (u.c.y == 1u) {
        float cutHalf = u.b.y;
        float span = 6.2831853 - 2.0 * cutHalf;
        float th0 = u.b.x + cutHalf;
        uint n;
        if (gas) n = clamp(uint(ceil(span * r / max(rad * 2.6, 1e-5))), 1u, 20u);
        else if (surf) n = clamp(uint(ceil(span * r / max(rad * 1.25, 1e-5))) + 1u, 2u, 700u);
        else n = 2u;
        uint kind = surf ? 0u : 1u;
        uint par = pack_float_to_unorm4x8(float4(metal, rough, emis, float(kind) / 255.0));
        if (gas) {
            uint base = atomic_fetch_add_explicit(&gargs[1], n, memory_order_relaxed);
            if (base + n > GAS_CAP) return;
            for (uint k = 0; k < n; k++) {
                float t = (float(k) + 0.5) / float(n);
                float th = th0 + t * span;
                G[base + k].posR = float4(wx, r * cos(th), r * sin(th), rad);
                G[base + k].color = col; G[base + k].params = par;
            }
        } else {
            uint base = atomic_fetch_add_explicit(&args[1], n, memory_order_relaxed);
            if (base + n > INST_CAP) return;
            for (uint k = 0; k < n; k++) {
                float t = float(k) / float(n - 1u);
                float th = th0 + t * span;
                I[base + k].posR = float4(wx, r * cos(th), r * sin(th), rad);
                I[base + k].color = col; I[base + k].params = par;
            }
        }
    } else {
        // linear charge: extrude along world z, mirror across the symmetry plane
        float E = u.b.z * s;
        uint n;
        if (gas) n = clamp(uint(ceil(E / max(rad * 3.0, 1e-5))), 1u, 16u);
        else if (surf) n = clamp(uint(ceil(E / max(rad * 1.25, 1e-5))) + 1u, 2u, 500u);
        else n = 1u;
        uint sides = (p.x < p.radius * 0.6) ? 1u : 2u;
        uint kind = surf ? 0u : 1u;
        uint par = pack_float_to_unorm4x8(float4(metal, rough, emis, float(kind) / 255.0));
        uint tot = n * sides;
        if (gas) {
            uint base = atomic_fetch_add_explicit(&gargs[1], tot, memory_order_relaxed);
            if (base + tot > GAS_CAP) return;
            for (uint sd = 0; sd < sides; sd++) for (uint k = 0; k < n; k++) {
                float t = (float(k) + 0.5) / float(n);
                uint q = base + sd * n + k;
                G[q].posR = float4(wx, sd == 0u ? r : -r, (t - 0.5) * E, rad);
                G[q].color = col; G[q].params = par;
            }
        } else {
            uint base = atomic_fetch_add_explicit(&args[1], tot, memory_order_relaxed);
            if (base + tot > INST_CAP) return;
            for (uint sd = 0; sd < sides; sd++) for (uint k = 0; k < n; k++) {
                float t = n == 1u ? 1.0 : float(k) / float(n - 1u);
                uint q = base + sd * n + k;
                I[q].posR = float4(wx, sd == 0u ? r : -r, (t - 0.5) * E, rad);
                I[q].color = col; I[q].params = par;
            }
        }
    }
}

// ---------- recorded 3D frames ----------
struct FP { ushort x, y, z; uchar speed, temp, pres, strain, mat, fl; };

kernel void expand3D(device const FP* P [[buffer(0)]],
                     device Inst* I [[buffer(1)]],
                     device atomic_uint* args [[buffer(2)]],
                     device Inst* G [[buffer(3)]],
                     device atomic_uint* gargs [[buffer(4)]],
                     constant U& u [[buffer(5)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= u.c.w) return;
    FP p = P[id];
    if ((p.fl & 1u) == 0u) return;
    bool gas = (p.fl & 2u) != 0u;
    bool damaged = (p.fl & 4u) != 0u;
    bool coarse = (p.fl & 8u) != 0u;
    uint mat = p.mat;
    uint vis = uint(u.h.w);
    if (gas && u.c.z == 0u) return;
    if (mat == 0u && !gas && (vis & 1u) == 0u) return;
    if (mat == 2u && (vis & 2u) == 0u) return;

    float3 q = float3(float(p.x), float(p.y), float(p.z)) / 65535.0;
    float x = u.g.x + q.x * u.g.w, y = u.g.y + q.y * u.g.w, z = u.g.z + q.z * u.h.x;
    float s = u.a.w;
    float dp = coarse ? u.h.z : u.h.y;
    // real cut: hide the wedge facing the camera (nothing is revolved — every particle is simulated)
    float r = sqrt(x * x + y * y);
    float th = atan2(y, x);
    float dth = abs(fmod(th - u.b.x + 3.0 * M_PI_F, 2.0 * M_PI_F) - M_PI_F);
    if (dth < u.b.y && r > 0.6 * u.h.y) return;

    float speed = float(p.speed) / 255.0 * 10.0;
    float temp = 300.0 + float(p.temp) / 255.0 * 4000.0;
    float pres = exp2(float(p.pres) / 255.0 * log2(201.0)) - 1.0;
    float strain = float(p.strain) / 255.0 * 4.0;

    float3 alb; float metal = 0.0; float rough = 0.6; float emis = 0.0;
    uint mode = u.c.x;
    if (gas) {
        float t = saturate((temp - 400.0) / 3400.0);
        alb = blackbody(400.0 + t * 3400.0);
        emis = t * 0.55;   // every gas particle is drawn in 3D, so far more sprites overlap than in the revolved view
    } else {
        if (mat == 0u) { alb = float3(0.46, 0.43, 0.33); rough = 0.8; }
        else if (mat == 1u) {
            float k = u.f.x;
            alb = k < 0.5 ? float3(0.96, 0.58, 0.40) : (k < 1.5 ? float3(0.60, 0.62, 0.70) : float3(0.88, 0.89, 0.91));
            metal = 1.0; rough = 0.24;
        } else {
            alb = u.f.y < 0.5 ? float3(0.50, 0.52, 0.55) : float3(0.82, 0.84, 0.87);
            metal = 1.0; rough = 0.42;
        }
        if (damaged) { rough = min(rough + 0.25, 1.0); alb *= 0.82; }
        if (mode == 1u) { alb = turbo(speed / max(u.d.x, 0.1)); metal = 0.15; rough = 0.45; }
        else if (mode == 2u) { alb = turbo(log2(1.0 + max(pres, 0.0)) / log2(1.0 + u.f.z)); metal = 0.15; rough = 0.45; }
        else if (mode == 3u) { alb = turbo((temp - 300.0) / 1300.0); metal = 0.15; rough = 0.45; }
        else if (mode == 4u) { alb = turbo(strain / max(u.f.w, 0.1)); metal = 0.15; rough = 0.45; }
        if (mat != 0u) { float glow = saturate((temp - 1000.0) / 1200.0); emis = glow * glow * 0.35; }
    }
    uint col = pack_float_to_unorm4x8(float4(saturate(alb), 1.0));
    bool onCut = abs(dth - u.b.y) < 1.5 * dp / max(r, dp);
    uint par = pack_float_to_unorm4x8(float4(metal, rough, emis, onCut ? 1.0 / 255.0 : 0.0));
    float3 w = float3((z - u.d.z) * s, x * s, y * s);
    if (gas) {
        uint b = atomic_fetch_add_explicit(&gargs[1], 1u, memory_order_relaxed);
        if (b >= GAS_CAP) return;
        G[b].posR = float4(w, 1.1 * dp * s); G[b].color = col; G[b].params = par;
    } else {
        uint b = atomic_fetch_add_explicit(&args[1], 1u, memory_order_relaxed);
        if (b >= INST_CAP) return;
        float genScale = pow(0.7937, float((p.fl >> 4) & 7u));
        I[b].posR = float4(w, 0.62 * dp * genScale * s); I[b].color = col; I[b].params = par;
    }
}

// ---------- environment ----------
float3 skyColor(float3 d) {
    float3 top = float3(0.42, 0.47, 0.56);
    float3 hor = float3(0.16, 0.17, 0.20);
    float3 gnd = float3(0.035, 0.036, 0.04);
    float3 c = d.y > 0.0 ? mix(hor, top, pow(saturate(d.y), 0.6)) : mix(hor, gnd, pow(saturate(-d.y), 0.35));
    c += float3(3.2, 3.1, 2.9) * smoothstep(0.93, 0.985, dot(d, normalize(float3(-0.35, 0.85, 0.45))));
    c += float3(1.2, 1.5, 2.0) * smoothstep(0.95, 0.995, dot(d, normalize(float3(0.85, 0.25, -0.45))));
    return c;
}

struct FSOut { float4 pos [[position]]; float2 uv; };

vertex FSOut fullscreenV(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
}

fragment float4 backgroundF(FSOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 q = in.uv;
    float3 c = mix(float3(0.075, 0.08, 0.095), float3(0.018, 0.019, 0.024), q.y);
    float v = length(q - float2(0.5, 0.42));
    c *= 1.0 - 0.45 * smoothstep(0.3, 0.95, v);
    return float4(c, 1.0);
}

// ---------- ground with CD scale ----------
struct GOut { float4 pos [[position]]; float3 world; };

vertex GOut groundV(uint vid [[vertex_id]], constant U& u [[buffer(0)]]) {
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0) * 40.0;
    GOut o;
    o.world = float3(c.x, u.b.w, c.y);
    o.pos = u.proj * u.view * float4(o.world, 1.0);
    return o;
}

fragment float4 groundF(GOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float s = u.a.w;
    float cd = u.e.z;
    float zmm = in.world.x / s + u.d.z;    // axial position, mm
    float lat = in.world.z / s;            // lateral, mm
    float3 base = float3(0.055, 0.058, 0.066);
    // fine grid every 10 mm, bold every charge diameter measured from the charge face
    float2 g1 = float2(zmm, lat) / 10.0;
    float2 w1 = fwidth(g1);
    float2 l1 = 1.0 - smoothstep(0.0, w1 * 1.2, abs(fract(g1 - 0.5) - 0.5));
    float minor = max(l1.x, l1.y) * 0.10;
    float fromFace = (zmm - u.d.z) / cd;
    float w2 = fwidth(fromFace);
    float major = (1.0 - smoothstep(0.0, w2 * 1.6, abs(fract(fromFace - 0.5) - 0.5))) * step(-0.01, fromFace);
    float3 c = base + minor * float3(0.30, 0.33, 0.38) + major * 0.22 * float3(0.75, 0.80, 0.90);
    // standoff band between the charge face and the target face
    float inStand = step(u.d.z, zmm) * step(zmm, u.d.w);
    float band = inStand * (1.0 - smoothstep(0.0, 1.5, abs(lat) / (0.5 * cd)));
    c += band * float3(0.16, 0.085, 0.02);
    float edge = inStand * (1.0 - smoothstep(0.0, fwidth(lat) * 2.0, abs(abs(lat) - 0.5 * cd)));
    c += edge * float3(0.55, 0.30, 0.08);
    // soft contact shadow under charge and target
    float chargeSpan = smoothstep(-2.0, 2.0, zmm) * (1.0 - smoothstep(u.d.z - 2.0, u.d.z + 2.0, zmm));
    float targetSpan = smoothstep(u.d.w - 2.0, u.d.w + 2.0, zmm) * (1.0 - smoothstep(u.e.y - 2.0, u.e.y + 2.0, zmm));
    float sh = chargeSpan * exp(-pow(lat / (u.d.y * 1.3), 2.0)) + targetSpan * exp(-pow(lat / (u.e.x * 1.3), 2.0));
    c *= 1.0 - 0.65 * saturate(sh);
    // fade into the backdrop
    float dist = length(in.world.xz - float2(u.e.w, 0.0));
    float fade = 1.0 - smoothstep(6.0, 22.0, dist);
    return float4(c * fade + float3(0.02, 0.021, 0.026) * (1.0 - fade), 1.0);
}

// ---------- sphere impostors ----------
struct SOut {
    float4 pos [[position]];
    float3 centerV;
    float radius;
    float2 uv;
    uint color [[flat]];
    uint params [[flat]];
};

vertex SOut sphereV(uint vid [[vertex_id]], uint iid [[instance_id]],
                    device const Inst* I [[buffer(0)]], constant U& u [[buffer(1)]]) {
    Inst it = I[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float3 cV = (u.view * float4(it.posR.xyz, 1.0)).xyz;
    float r = it.posR.w;
    float3 pV = cV + float3(corner * r * 1.15, r);
    SOut o;
    o.pos = u.proj * float4(pV, 1.0);
    o.centerV = cV; o.radius = r; o.uv = corner * 1.15;
    o.color = it.color; o.params = it.params;
    return o;
}

struct SFrag { float4 color [[color(0)]]; float depth [[depth(any)]]; };

fragment SFrag sphereF(SOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float d2 = dot(in.uv, in.uv);
    if (d2 > 1.0) discard_fragment();
    float4 par = unpack_unorm4x8_to_float(in.params);
    float3 alb = unpack_unorm4x8_to_float(in.color).rgb;
    float metal = par.x, rough = max(par.y, 0.05), emis = par.z;
    bool cutFace = par.w > 0.002;
    float3 n = float3(in.uv, sqrt(1.0 - d2));
    if (cutFace) n = normalize(mix(n, float3(0, 0, 1), 0.55));   // sectioned faces read flatter
    float3 pV = in.centerV + float3(in.uv, sqrt(1.0 - d2)) * in.radius;
    float4 clip = u.proj * float4(pV, 1.0);
    SFrag o;
    o.depth = clip.z / clip.w;

    float3 v = normalize(-pV);
    float3 Lw = normalize(float3(-0.35, 0.85, 0.45));
    float3 L = normalize((u.view * float4(Lw, 0.0)).xyz);
    float3 L2 = normalize((u.view * float4(0.85, 0.25, -0.45, 0.0)).xyz);
    float3 nW = normalize((u.invView * float4(n, 0.0)).xyz);
    float3 R = normalize((u.invView * float4(reflect(-v, n), 0.0)).xyz);

    float3 F0 = mix(float3(0.04), alb, metal);
    float NdV = max(dot(n, v), 1e-3);
    float3 F = F0 + (1.0 - F0) * pow(1.0 - NdV, 5.0) * (1.0 - rough);
    float shin = mix(600.0, 10.0, rough);
    float3 h1 = normalize(L + v), h2 = normalize(L2 + v);
    float spec = pow(max(dot(n, h1), 0.0), shin) * (shin + 8.0) / 40.0;
    float spec2 = pow(max(dot(n, h2), 0.0), shin) * (shin + 8.0) / 160.0;
    float3 key = float3(1.75, 1.68, 1.58), fill = float3(0.40, 0.48, 0.62);
    float3 diff = alb * (1.0 - metal) * (key * max(dot(n, L), 0.0) + fill * max(dot(n, L2), 0.0) + skyColor(nW) * 0.55);
    float3 env = mix(skyColor(R), skyColor(normalize(nW + float3(0, 0.5, 0))) * 0.8, rough * rough) * F;
    float3 c = diff + (key * spec + fill * spec2) * F + env;
    // ambient occlusion-ish darkening toward the silhouette
    c *= mix(0.65, 1.0, NdV);
    c += alb * emis * 4.0;
    o.color = float4(c, 1.0);
    return o;
}

// ---------- explosive gas sprites (additive) ----------
struct GasOut { float4 pos [[position]]; float2 uv; float3 col; float emis; };

vertex GasOut gasV(uint vid [[vertex_id]], uint iid [[instance_id]],
                   device const Inst* I [[buffer(0)]], constant U& u [[buffer(1)]]) {
    Inst it = I[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float3 cV = (u.view * float4(it.posR.xyz, 1.0)).xyz;
    float r = it.posR.w * 2.2;
    GasOut o;
    o.pos = u.proj * float4(cV + float3(corner * r, 0.0), 1.0);
    o.uv = corner;
    o.col = unpack_unorm4x8_to_float(it.color).rgb;
    o.emis = unpack_unorm4x8_to_float(it.params).z;
    return o;
}

fragment float4 gasF(GasOut in [[stage_in]]) {
    float d2 = dot(in.uv, in.uv);
    if (d2 > 1.0) discard_fragment();
    float a = exp(-d2 * 3.5) * (0.002 + 0.045 * in.emis * in.emis * in.emis);
    float3 smoke = float3(0.05, 0.045, 0.04) * (1.0 - in.emis);
    return float4(in.col * a * 2.0 + smoke * exp(-d2 * 2.0) * 0.03, 1.0);
}

// ---------- bloom + tonemap ----------
fragment float4 bloomPrefilter(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float2 ts = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = 0;
    c += src.sample(ls, in.uv + ts * float2(-1, -1)).rgb;
    c += src.sample(ls, in.uv + ts * float2( 1, -1)).rgb;
    c += src.sample(ls, in.uv + ts * float2(-1,  1)).rgb;
    c += src.sample(ls, in.uv + ts * float2( 1,  1)).rgb;
    c *= 0.25;
    float br = max(c.r, max(c.g, c.b));
    float knee = 0.6, thr = 2.2;
    float soft = clamp(br - thr + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float w = max(soft, br - thr) / max(br, 1e-4);
    return float4(c * w, 1.0);
}

fragment float4 bloomDown(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float2 ts = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(ls, in.uv).rgb * 0.5;
    c += src.sample(ls, in.uv + ts * float2(-1, -1)).rgb * 0.125;
    c += src.sample(ls, in.uv + ts * float2( 1, -1)).rgb * 0.125;
    c += src.sample(ls, in.uv + ts * float2(-1,  1)).rgb * 0.125;
    c += src.sample(ls, in.uv + ts * float2( 1,  1)).rgb * 0.125;
    return float4(c, 1.0);
}

fragment float4 bloomUp(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float2 ts = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = 0;
    c += src.sample(ls, in.uv + ts * float2(-1, -1)).rgb;
    c += src.sample(ls, in.uv + ts * float2( 0, -1)).rgb * 2.0;
    c += src.sample(ls, in.uv + ts * float2( 1, -1)).rgb;
    c += src.sample(ls, in.uv + ts * float2(-1,  0)).rgb * 2.0;
    c += src.sample(ls, in.uv).rgb * 4.0;
    c += src.sample(ls, in.uv + ts * float2( 1,  0)).rgb * 2.0;
    c += src.sample(ls, in.uv + ts * float2(-1,  1)).rgb;
    c += src.sample(ls, in.uv + ts * float2( 0,  1)).rgb * 2.0;
    c += src.sample(ls, in.uv + ts * float2( 1,  1)).rgb;
    return float4(c / 16.0, 1.0);
}

float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

fragment float4 compositeF(FSOut in [[stage_in]], texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float3 c = hdr.sample(ls, in.uv).rgb;
    c += bloom.sample(ls, in.uv).rgb * 0.4;
    c = aces(c * 0.95);
    float v = length(in.uv - 0.5);
    c *= 1.0 - 0.25 * smoothstep(0.45, 0.85, v);
    return float4(c, 1.0);
}
"""#
