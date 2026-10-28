// Full 3D SPH solver, Metal compute. Same physics as the 2D solver (Mie–Grüneisen metals with
// J2 plasticity and failure, gamma-law explosive with programmed burn), but in Cartesian 3D with
// no symmetry assumption. Everything stays on the GPU between steps.
let solver3DSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Mat {
    float rho0, c0, s, grun, G, yA, yB, yN, yMax, cv, meltE, spall, failStrain, detVel, gammaGas, e0;
    uint kind; float tbSigma0, tbK, pad2;
};

struct P3 {
    float4 gmin;   // grid origin xyz, cell size
    uint4  gdim;   // nx, ny, nz, ncells
    float4 box;    // lateral box radius, zMin, zMax, zFace
    float4 misc;   // target radius, fine spacing, wake margin, radius counted for penetration
    uint4  cnt;    // slot capacity, max split generations
    float4 quant;  // frame quantisation origin xyz, xy span
    float4 quant2; // z span, core radius for the jet tip, -, -
};

// state words (uint indices)
#define S_TIME 0
#define S_DT 1
#define S_DTMIN 2
#define S_LINERZ 3
#define S_PENZ 4
#define S_AWAKE 5
#define S_TIPV 6
#define S_CORETIPZ 7
#define S_USED 8
#define S_FOOTVZ 9

#define F_ACTIVE 256u
#define F_FIXED 512u
#define F_DAMAGED 1024u
#define F_SLEEP 2048u
#define F_VENTED 4096u
#define F_COARSE 8192u

constant float ZOFF = 1000.0;

inline float kW(float r, float h) {
    float q = r / h; float sig = 1.0 / (M_PI_F * h * h * h);
    if (q < 1.0) return sig * (1.0 - 1.5 * q * q + 0.75 * q * q * q);
    if (q < 2.0) { float t = 2.0 - q; return sig * 0.25 * t * t * t; }
    return 0.0;
}
inline float kDW(float r, float h) {
    float q = r / h; float sig = 1.0 / (M_PI_F * h * h * h * h);
    if (q < 1.0) return sig * (-3.0 * q + 2.25 * q * q);
    if (q < 2.0) { float t = 2.0 - q; return -sig * 0.75 * t * t; }
    return 0.0;
}

inline int3 cellCoord(float3 p, constant P3& P) { return int3(floor((p - P.gmin.xyz) / P.gmin.w)); }
inline bool inGrid(int3 c, constant P3& P) {
    return all(c >= 0) && c.x < int(P.gdim.x) && c.y < int(P.gdim.y) && c.z < int(P.gdim.z);
}
inline uint cellIndex(int3 c, constant P3& P) { return (uint(c.z) * P.gdim.y + uint(c.y)) * P.gdim.x + uint(c.x); }

// ---------------- grid (counting sort) ----------------
kernel void gClear(device uint* cnt [[buffer(0)]], constant P3& P [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    if (i <= P.gdim.w) cnt[i] = 0;
}

kernel void gAssign(device float4* pos [[buffer(0)]], device uint* flags [[buffer(1)]],
                    device uint* cellOf [[buffer(2)]], device uint* rank [[buffer(3)]],
                    device atomic_uint* cnt [[buffer(4)]], constant P3& P [[buffer(5)]],
                    uint i [[thread_position_in_grid]]) {
    if (i >= P.cnt.x) return;
    uint f = flags[i];
    uint ci = P.gdim.w;
    if ((f & F_ACTIVE) != 0u) {
        int3 c = cellCoord(pos[i].xyz, P);
        if (inGrid(c, P)) ci = cellIndex(c, P);
        else flags[i] = (f & ~F_ACTIVE) | F_VENTED;
    }
    cellOf[i] = ci;
    rank[i] = atomic_fetch_add_explicit(&cnt[ci], 1u, memory_order_relaxed);
}

// exclusive scan in blocks of 1024
kernel void gScan(device const uint* inp [[buffer(0)]], device uint* outp [[buffer(1)]], device uint* sums [[buffer(2)]],
                  constant uint& len [[buffer(3)]],
                  uint gid [[thread_position_in_grid]], uint tid [[thread_position_in_threadgroup]],
                  uint bid [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                  uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint part[32];
    uint v = gid < len ? inp[gid] : 0u;
    uint ex = simd_prefix_exclusive_sum(v);
    uint tot = simd_sum(v);
    if (lane == 0) part[sg] = tot;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sg == 0) {
        uint pv = lane < 32 ? part[lane] : 0u;
        uint pex = simd_prefix_exclusive_sum(pv);
        part[lane] = pex;
        if (lane == 31) sums[bid] = pex + pv;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (gid < len) outp[gid] = ex + part[sg];
}

kernel void gAddSums(device uint* outp [[buffer(0)]], device const uint* sums [[buffer(1)]], constant uint& len [[buffer(2)]],
                     uint gid [[thread_position_in_grid]], uint bid [[threadgroup_position_in_grid]]) {
    if (gid < len) outp[gid] += sums[bid];
}

kernel void gScatter(device const uint* cellOf [[buffer(0)]], device const uint* rank [[buffer(1)]],
                     device const uint* start [[buffer(2)]], device uint* sorted [[buffer(3)]],
                     constant P3& P [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.cnt.x) return;
    sorted[start[cellOf[i]] + rank[i]] = i;
}

// Reorder persistent particle data into cell order so neighbour reads are coherent.
kernel void kPermute(device const uint* sorted [[buffer(0)]],
                     device const float4* pa [[buffer(1)]], device float4* pb [[buffer(2)]],
                     device const float4* va [[buffer(3)]], device float4* vb [[buffer(4)]],
                     device const float4* sa [[buffer(5)]], device float4* sb [[buffer(6)]],
                     device const float4* a0 [[buffer(7)]], device float4* b0 [[buffer(8)]],
                     device const float4* a1 [[buffer(9)]], device float4* b1 [[buffer(10)]],
                     device const float4* xa [[buffer(11)]], device float4* xb [[buffer(12)]],
                     device const uint* fa [[buffer(13)]], device uint* fb [[buffer(14)]],
                     device const float4* g0a [[buffer(15)]], device float4* g0b [[buffer(16)]],
                     device const float4* g1a [[buffer(17)]], device float4* g1b [[buffer(18)]],
                     device const float4* g2a [[buffer(19)]], device float4* g2b [[buffer(20)]],
                     constant P3& P [[buffer(21)]],
                     uint k [[thread_position_in_grid]]) {
    if (k >= P.cnt.x) return;
    uint j = sorted[k];
    pb[k] = pa[j]; vb[k] = va[j]; sb[k] = sa[j]; b0[k] = a0[j]; b1[k] = a1[j]; xb[k] = xa[j]; fb[k] = fa[j];
    g0b[k] = g0a[j]; g1b[k] = g1a[j]; g2b[k] = g2a[j];
}

// ---------------- physics ----------------
float2 eos(Mat m, float rho, float e, float burn, bool damaged) {
    if (m.kind == 0u) {
        float g = m.gammaGas;
        float pg = (g - 1.0) * rho * max(e, 0.0);
        float mu = rho / m.rho0 - 1.0;
        float un = 1.0 - burn;
        float pu = un * m.rho0 * m.c0 * m.c0 * max(mu, 0.0);
        float c2 = g * pg / rho + un * m.c0 * m.c0;
        return float2(pg + pu, sqrt(max(c2, 0.01)));
    }
    float mu = rho / m.rho0 - 1.0;
    float pr, c2;
    if (mu > 0.0) {
        float den = max(1.0 - (m.s - 1.0) * mu, 0.4);
        pr = m.rho0 * m.c0 * m.c0 * mu * (1.0 + (1.0 - m.grun / 2.0) * mu) / (den * den) + m.grun * m.rho0 * e;
        c2 = m.c0 * m.c0 * (1.0 + 2.0 * (m.s - 1.0) * mu) / (den * den);
    } else {
        pr = m.rho0 * m.c0 * m.c0 * mu + m.grun * m.rho0 * e;
        c2 = m.c0 * m.c0;
    }
    if (damaged) pr = max(pr, 0.0); else c2 += 4.0 * m.G / (3.0 * rho);
    return float2(pr, sqrt(max(c2, 0.25 * m.c0 * m.c0)));
}

kernel void kEOS(device float4* st [[buffer(0)]], device const float4* aux [[buffer(1)]], device const uint* flags [[buffer(2)]],
                 constant Mat* mats [[buffer(3)]], constant P3& P [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= P.cnt.x) return;
    uint f = flags[i];
    if ((f & F_ACTIVE) == 0u) return;
    float4 s = st[i];
    float2 pc = eos(mats[f & 255u], max(s.x, 1e-5), s.y, aux[i].x, (f & F_DAMAGED) != 0u);
    st[i] = float4(s.x, s.y, pc.x, pc.y);
}

#define NEIGHBOURS_BEGIN \
    int3 cBase = cellCoord(pi, P); \
    for (int dz = -1; dz <= 1; dz++) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { \
        int3 cc = cBase + int3(dx, dy, dz); \
        if (!inGrid(cc, P)) continue; \
        uint cell = cellIndex(cc, P); \
        uint q0 = start[cell], q1 = start[cell + 1]; \
        for (uint q = q0; q < q1; q++) { \
            uint j = q; \
            if (j == i) continue; \
            float4 pj4 = pos[j]; \
            float3 d = pi - pj4.xyz; \
            float r2 = dot(d, d); \
            float sup = hi + pj4.w; \
            if (r2 >= sup * sup) continue; \
            float r = max(sqrt(r2), 1e-7); \
            float hij = 0.5 * (hi + pj4.w); \
            float3 gw = kDW(r, hij) * d / r;
#define NEIGHBOURS_END }}

kernel void kRates(device const float4* pos [[buffer(0)]], device const float4* vel [[buffer(1)]], device const float4* st [[buffer(2)]],
                   device const float4* S0 [[buffer(3)]], device const float4* S1 [[buffer(4)]], device const uint* flags [[buffer(5)]],
                   device float4* r0 [[buffer(6)]], device float4* dS0 [[buffer(7)]], device float4* dS1 [[buffer(8)]],
                   device const uint* start [[buffer(9)]], device const uint* sorted [[buffer(10)]],
                   constant Mat* mats [[buffer(11)]],
                   device float4* L0 [[buffer(12)]], device float4* L1 [[buffer(13)]], device float4* L2 [[buffer(14)]],
                   constant P3& P [[buffer(15)]], uint i [[thread_position_in_grid]]) {
    if (i >= start[P.gdim.w]) return;
    uint f = flags[i];
    if ((f & F_ACTIVE) == 0u || (f & F_FIXED) != 0u) { r0[i] = 0; dS0[i] = 0; dS1[i] = 0; L0[i] = 0; L1[i] = 0; L2[i] = 0; return; }
    float4 p4 = pos[i]; float3 pi = p4.xyz; float hi = p4.w;
    float3 vi = vel[i].xyz;
    float3x3 L = float3x3(0.0);
    NEIGHBOURS_BEGIN
        float Vj = vel[j].w / st[j].x;
        float3 dv = vel[j].xyz - vi;
        // L[col][row]: column b = ∂/∂x_b, row a = v_a
        L[0] += Vj * dv * gw.x;
        L[1] += Vj * dv * gw.y;
        L[2] += Vj * dv * gw.z;
    NEIGHBOURS_END
    // rows: L_a = (∂v_a/∂x, ∂v_a/∂y, ∂v_a/∂z)
    L0[i] = float4(L[0].x, L[1].x, L[2].x, 0);
    L1[i] = float4(L[0].y, L[1].y, L[2].y, 0);
    L2[i] = float4(L[0].z, L[1].z, L[2].z, 0);
    float exx = L[0].x, eyy = L[1].y, ezz = L[2].z;
    float exy = 0.5 * (L[1].x + L[0].y), exz = 0.5 * (L[2].x + L[0].z), eyz = 0.5 * (L[2].y + L[1].z);
    float wxy = 0.5 * (L[1].x - L[0].y), wxz = 0.5 * (L[2].x - L[0].z), wyz = 0.5 * (L[2].y - L[1].z);
    float div = exx + eyy + ezz;
    float4 s = st[i];
    float rho = s.x, pr = s.z;
    Mat m = mats[f & 255u];
    float4 a = S0[i]; float4 b = S1[i];
    float sxx = a.x, syy = a.y, szz = a.z, sxy = a.w, sxz = b.x, syz = b.y;
    float de;
    if (m.kind == 1u && (f & F_DAMAGED) == 0u) {
        float g2 = 2.0 * m.G, d3 = div / 3.0;
        // Jaumann rotation: W·S − S·W
        float3x3 S = float3x3(float3(sxx, sxy, sxz), float3(sxy, syy, syz), float3(sxz, syz, szz));
        float3x3 W = float3x3(float3(0, -wxy, -wxz), float3(wxy, 0, -wyz), float3(wxz, wyz, 0));
        float3x3 R = W * S - S * W;
        dS0[i] = float4(g2 * (exx - d3) + R[0].x, g2 * (eyy - d3) + R[1].y, g2 * (ezz - d3) + R[2].z, g2 * exy + R[1].x);
        dS1[i] = float4(g2 * exz + R[2].x, g2 * eyz + R[2].y, 0, 0);
        de = (-pr * div + sxx * exx + syy * eyy + szz * ezz + 2.0 * (sxy * exy + sxz * exz + syz * eyz)) / rho;
    } else {
        dS0[i] = 0; dS1[i] = 0;
        de = -pr * div / rho;
    }
    r0[i] = float4(-rho * div, de, 0, 0);
}

kernel void kForces(device const float4* pos [[buffer(0)]], device const float4* vel [[buffer(1)]], device const float4* st [[buffer(2)]],
                    device const float4* S0 [[buffer(3)]], device const float4* S1 [[buffer(4)]], device const uint* flags [[buffer(5)]],
                    device float4* acc [[buffer(6)]],
                    device const uint* start [[buffer(7)]], device const uint* sorted [[buffer(8)]],
                    device atomic_uint* state [[buffer(9)]], constant P3& P [[buffer(10)]], uint i [[thread_position_in_grid]]) {
    if (i >= start[P.gdim.w]) return;
    uint f = flags[i];
    if ((f & F_ACTIVE) == 0u || (f & F_FIXED) != 0u) { acc[i] = 0; return; }
    float4 p4 = pos[i]; float3 pi = p4.xyz; float hi = p4.w;
    float3 vi = vel[i].xyz;
    float4 si = st[i];
    float ri = si.x, pri = si.z, ci = si.w;
    float ri2 = 1.0 / (ri * ri);
    float4 a0 = S0[i], b0 = S1[i];
    float3x3 Ti = float3x3(float3(a0.x - pri, a0.w, b0.x), float3(a0.w, a0.y - pri, b0.y), float3(b0.x, b0.y, a0.z - pri)) * ri2;
    bool solidI = (f & 255u) != 0u;
    float Ri = (solidI && pri < 0.0) ? 0.3 * (-pri) * ri2 : 0.0;
    float3 ai = 0; float heat = 0; float mumax = 0;
    NEIGHBOURS_BEGIN
        uint fj = flags[j];
        float4 sj = st[j];
        float rj = sj.x, prj = sj.z;
        float rj2 = 1.0 / (rj * rj);
        float4 a1 = S0[j], b1 = S1[j];
        float3x3 T = Ti + float3x3(float3(a1.x - prj, a1.w, b1.x), float3(a1.w, a1.y - prj, b1.y), float3(b1.x, b1.y, a1.z - prj)) * rj2;
        float3 dv = vi - vel[j].xyz;
        float vr = dot(dv, d);
        float extra = 0.0;
        if (vr < 0.0) {
            float mu = hij * vr / (r2 + 0.01 * hij * hij);
            float cb = 0.5 * (ci + sj.w), rb = 0.5 * (ri + rj);
            float piv = (-1.0 * cb * mu + 2.0 * mu * mu) / rb;
            extra += piv;
            heat += 0.5 * vel[j].w * piv * dot(dv, gw);
            mumax = max(mumax, -mu);
        }
        float Rj = ((fj & 255u) != 0u && prj < 0.0) ? 0.3 * (-prj) * rj2 : 0.0;
        if (Ri + Rj > 0.0) {
            float fw = kW(r, hij) / kW(hij / 1.3, hij);
            float f2 = fw * fw;
            extra += (Ri + Rj) * f2 * f2;
        }
        float mj = vel[j].w;
        ai += mj * (T * gw - extra * gw);
    NEIGHBOURS_END
    acc[i] = float4(ai, heat);
    float am = length(ai);
    float d1 = hi / (ci + 1.2 * (ci + 2.0 * mumax));
    float d2 = am > 0.0 ? sqrt(hi / am) : 1e9;
    float dtl = min(0.3 * d1, 0.25 * d2);
    atomic_fetch_min_explicit(&state[S_DTMIN], as_type<uint>(dtl), memory_order_relaxed);
}

kernel void kFinalizeDt(device uint* state [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if (i != 0) return;
    float prev = as_type<float>(state[S_DT]);
    float m = as_type<float>(state[S_DTMIN]);
    float dt = clamp(min(m, prev * 1.25), 1e-6, 0.05);
    state[S_DT] = as_type<uint>(dt);
    state[S_DTMIN] = as_type<uint>(0.05f);
    state[S_LINERZ] = 0; state[S_PENZ] = 0; state[S_TIPV] = 0; state[S_CORETIPZ] = 0; state[S_FOOTVZ] = 0;
}

kernel void kIntegrate(device float4* pos [[buffer(0)]], device float4* vel [[buffer(1)]], device float4* st [[buffer(2)]],
                       device float4* S0 [[buffer(3)]], device float4* S1 [[buffer(4)]], device uint* flags [[buffer(5)]],
                       device float4* aux [[buffer(6)]], device const float4* acc [[buffer(7)]], device const float4* r0 [[buffer(8)]],
                       device const float4* dS0 [[buffer(9)]], device const float4* dS1 [[buffer(10)]],
                       device atomic_uint* state [[buffer(11)]], constant Mat* mats [[buffer(12)]],
                       device const float4* L0 [[buffer(13)]], device const float4* L1 [[buffer(14)]], device const float4* L2 [[buffer(15)]],
                       device float4* G0 [[buffer(16)]], device float4* G1 [[buffer(17)]], device float4* G2 [[buffer(18)]],
                       constant P3& P [[buffer(19)]],
                       uint i [[thread_position_in_grid]]) {
    if (i >= P.cnt.x) return;
    uint f = flags[i];
    uint awake = atomic_load_explicit(&state[S_AWAKE], memory_order_relaxed);
    if ((f & F_SLEEP) != 0u) {
        if (awake != 0u) { f = (f & ~F_SLEEP) | F_ACTIVE; flags[i] = f; }
        return;
    }
    if ((f & F_ACTIVE) == 0u || (f & F_FIXED) != 0u) return;
    float dt = as_type<float>(atomic_load_explicit(&state[S_DT], memory_order_relaxed));
    float tnew = as_type<float>(atomic_load_explicit(&state[S_TIME], memory_order_relaxed)) + dt;
    uint mi = f & 255u;
    Mat m = mats[mi];
    float4 v4 = vel[i];
    float4 a4 = acc[i];
    float3 v = v4.xyz + a4.xyz * dt;
    float4 p4 = pos[i];
    float3 p = p4.xyz + v * dt;
    pos[i] = float4(p, p4.w);
    vel[i] = float4(v, v4.w);
    float4 s = st[i];
    float4 rr = r0[i];
    float rate = clamp(rr.x / max(s.x, 1e-6) * dt, -0.05, 0.05);
    float lo = m.kind == 0u ? 1e-3 : 0.5 * m.rho0;
    float hi = m.kind == 0u ? 4.0 * m.rho0 : 2.2 * m.rho0;
    float rho = clamp(s.x * exp(rate), lo, hi);
    float e = s.y + (rr.y + a4.w) * dt;
    float4 ax = aux[i];
    bool outBox = length(p.xy) > P.box.x || p.z < P.box.y || p.z > P.box.z;
    if (m.kind == 0u) {
        if (ax.x < 1.0) {
            float fb = clamp((tnew - ax.y) * m.detVel / (2.6 * p4.w), 0.0, 1.0);
            if (fb > ax.x) { e += (fb - ax.x) * m.e0; ax.x = fb; aux[i] = ax; }
        }
        e = max(e, 0.0);
        if ((ax.x >= 1.0 && rho < 0.01 * m.rho0) || outBox) f = (f & ~F_ACTIVE) | F_VENTED;
    } else {
        // deformation gradient: dF/dt = L·F (rows of F stored in G0..G2)
        float3 g0 = G0[i].xyz, g1 = G1[i].xyz, g2 = G2[i].xyz;
        float3 l0 = L0[i].xyz, l1 = L1[i].xyz, l2 = L2[i].xyz;
        G0[i] = float4(g0 + (l0.x * g0 + l0.y * g1 + l0.z * g2) * dt, 0);
        G1[i] = float4(g1 + (l1.x * g0 + l1.y * g1 + l1.z * g2) * dt, 0);
        G2[i] = float4(g2 + (l2.x * g0 + l2.y * g1 + l2.z * g2) * dt, 0);
        float4 a = S0[i], b = S1[i];
        if ((f & F_DAMAGED) == 0u) {
            float4 da = dS0[i], db = dS1[i];
            a += da * dt; b.xy += db.xy * dt;
            float j2 = 0.5 * (a.x * a.x + a.y * a.y + a.z * a.z) + a.w * a.w + b.x * b.x + b.y * b.y;
            float seq = sqrt(3.0 * j2);
            float soft = max(0.0, 1.0 - max(e, 0.0) / m.meltE);
            float y = min(m.yA + m.yB * pow(max(b.z, 1e-6), m.yN), m.yMax) * soft;
            if (seq > y) {
                float sc = seq > 1e-9 ? y / seq : 0.0;
                float dep = (seq - y) / (3.0 * m.G);
                a *= sc; b.xy *= sc;
                b.z += dep;
                if (s.z < 0.0) b.w += dep;
            }
            // Tuler–Butcher cumulative spall damage, kept in aux.z
            float tension = -s.z;
            if (tension > m.tbSigma0) { ax.z += (tension - m.tbSigma0) * (tension - m.tbSigma0) * dt; aux[i] = ax; }
            if (ax.z >= m.tbK || b.w > m.failStrain) { f |= F_DAMAGED; a = 0; b.xy = 0; }
            S0[i] = a; S1[i] = b;
        }
        if (outBox) f = (f & ~F_ACTIVE) | F_VENTED;
        if (mi == 1u && (f & F_ACTIVE) != 0u) {
            uint zb = as_type<uint>(p.z + ZOFF);
            atomic_fetch_max_explicit(&state[S_LINERZ], zb, memory_order_relaxed);
            float rr2 = length(p.xy);
            if (rr2 < P.misc.w) {
                atomic_fetch_max_explicit(&state[S_PENZ], zb, memory_order_relaxed);
                if (v.z > 0.0) atomic_fetch_max_explicit(&state[S_FOOTVZ], as_type<uint>(v.z), memory_order_relaxed);
            }
            if (rr2 < P.quant2.y) {
                atomic_fetch_max_explicit(&state[S_CORETIPZ], zb, memory_order_relaxed);
                if (v.z > 0.0) atomic_fetch_max_explicit(&state[S_TIPV], as_type<uint>(v.z), memory_order_relaxed);
            }
        }
    }
    st[i] = float4(rho, e, s.z, s.w);
    flags[i] = f;
}

// Adaptive refinement from the deformation gradient. The largest principal stretch of the material
// element is √λ of B = F·Fᵀ, along eigenvector n. At a stretch of 2 the element is split into its two
// halves: children at ±¼ of the stretched length along n, half the mass each, velocities from the local
// velocity gradient (momentum conserved), smoothing length scaled by 2^(−1/3), and F's stretch along n halved.
kernel void kSplit(device float4* pos [[buffer(0)]], device float4* vel [[buffer(1)]], device float4* st [[buffer(2)]],
                   device float4* S0 [[buffer(3)]], device float4* S1 [[buffer(4)]], device float4* aux [[buffer(5)]],
                   device uint* flags [[buffer(6)]],
                   device const float4* L0 [[buffer(7)]], device const float4* L1 [[buffer(8)]], device const float4* L2 [[buffer(9)]],
                   device float4* G0 [[buffer(10)]], device float4* G1 [[buffer(11)]], device float4* G2 [[buffer(12)]],
                   device atomic_uint* state [[buffer(13)]], constant P3& P [[buffer(14)]], uint i [[thread_position_in_grid]]) {
    uint used = atomic_load_explicit(&state[S_USED], memory_order_relaxed);
    if (i >= used) return;
    uint f = flags[i];
    if ((f & 255u) != 1u || (f & F_ACTIVE) == 0u) return;
    uint gen = (f >> 16) & 7u;
    if (gen >= P.cnt.y) return;
    float3 g0 = G0[i].xyz, g1 = G1[i].xyz, g2 = G2[i].xyz;
    float3x3 B = float3x3(float3(dot(g0, g0), dot(g1, g0), dot(g2, g0)),
                          float3(dot(g0, g1), dot(g1, g1), dot(g2, g1)),
                          float3(dot(g0, g2), dot(g1, g2), dot(g2, g2)));
    // power iteration for the dominant eigenvector of the symmetric B
    float3 nv = normalize(B * float3(0.577, 0.577, 0.577) + float3(1e-6, 2e-6, 3e-6));
    for (int it = 0; it < 16; it++) nv = normalize(B * nv + float3(1e-9));
    float lam = dot(nv, B * nv);
    float stretch = sqrt(max(lam, 0.0));
    if (stretch < 2.0) return;
    uint slot = atomic_fetch_add_explicit(&state[S_USED], 1u, memory_order_relaxed);
    if (slot >= P.cnt.x) return;
    float delta = 0.25 * stretch * P.misc.y;
    float4 p = pos[i], v = vel[i];
    float3 dv = float3(dot(L0[i].xyz, nv), dot(L1[i].xyz, nv), dot(L2[i].xyz, nv)) * delta;
    float hNew = p.w * 0.7937005;
    pos[i] = float4(p.xyz - nv * delta, hNew);
    pos[slot] = float4(p.xyz + nv * delta, hNew);
    vel[i] = float4(v.xyz - dv, 0.5 * v.w);
    vel[slot] = float4(v.xyz + dv, 0.5 * v.w);
    st[slot] = st[i]; S0[slot] = S0[i]; S1[slot] = S1[i]; aux[slot] = aux[i];
    // F ← F − ½ n (nᵀF): row a gets −½ n_a (nᵀF)
    float3 nF = nv.x * g0 + nv.y * g1 + nv.z * g2;
    float4 r0n = float4(g0 - 0.5 * nv.x * nF, 0), r1n = float4(g1 - 0.5 * nv.y * nF, 0), r2n = float4(g2 - 0.5 * nv.z * nF, 0);
    G0[i] = r0n; G1[i] = r1n; G2[i] = r2n;
    G0[slot] = r0n; G1[slot] = r1n; G2[slot] = r2n;
    uint fNew = (f & ~(7u << 16)) | ((gen + 1u) << 16);
    flags[i] = fNew; flags[slot] = fNew;
}

kernel void kAdvance(device uint* state [[buffer(0)]], constant P3& P [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    if (i != 0) return;
    float t = as_type<float>(state[S_TIME]) + as_type<float>(state[S_DT]);
    state[S_TIME] = as_type<uint>(t);
    float lz = as_type<float>(state[S_LINERZ]) - ZOFF;
    if (state[S_AWAKE] == 0u && state[S_LINERZ] != 0u && lz > P.box.w - P.misc.z) state[S_AWAKE] = 1u;
}

// ---------------- frame packing for playback ----------------
struct FrameP { ushort x, y, z; uchar speed, temp, pres, strain, mat, fl; };

kernel void kPack(device const float4* pos [[buffer(0)]], device const float4* vel [[buffer(1)]], device const float4* st [[buffer(2)]],
                  device const float4* S1 [[buffer(3)]], device const float4* aux [[buffer(4)]], device const uint* flags [[buffer(5)]],
                  device FrameP* out [[buffer(6)]], constant Mat* mats [[buffer(7)]], constant P3& P [[buffer(8)]],
                  uint i [[thread_position_in_grid]]) {
    if (i >= P.cnt.x) return;
    uint f = flags[i];
    float3 p = pos[i].xyz;
    float3 q = clamp((p - P.quant.xyz) / float3(P.quant.w, P.quant.w, P.quant2.x), 0.0, 1.0) * 65535.0;
    FrameP o;
    o.x = ushort(q.x); o.y = ushort(q.y); o.z = ushort(q.z);
    uint mi = f & 255u;
    Mat m = mats[mi];
    float4 s = st[i];
    float sp = length(vel[i].xyz);
    float T = mi == 0u ? 300.0 + max(s.y, 0.0) * 900.0 : 300.0 + max(s.y, 0.0) / m.cv;
    o.speed = uchar(clamp(sp / 10.0, 0.0, 1.0) * 255.0);
    o.temp = uchar(clamp((T - 300.0) / 4000.0, 0.0, 1.0) * 255.0);
    o.pres = uchar(clamp(log2(1.0 + max(s.z, 0.0)) / log2(201.0), 0.0, 1.0) * 255.0);
    o.strain = uchar(clamp(S1[i].z / 4.0, 0.0, 1.0) * 255.0);
    o.mat = uchar(mi);
    uint fl = 0u;
    bool live = (f & (F_ACTIVE | F_SLEEP)) != 0u && (f & F_VENTED) == 0u;
    if (live) fl |= 1u;
    if (mi == 0u && aux[i].x > 0.5) fl |= 2u;
    if ((f & F_DAMAGED) != 0u) fl |= 4u;
    if ((f & F_COARSE) != 0u) fl |= 8u;
    fl |= ((f >> 16) & 7u) << 4;
    o.fl = uchar(fl);
    out[i] = o;
}
"""#
