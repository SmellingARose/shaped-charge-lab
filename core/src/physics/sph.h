// SPH physics for the full 3D solver, written once. Included by the CPU, Metal and HIP backends
// (see portable.h). Each *Body function handles one particle; backends supply the loop/launch.
//
// Model: cubic-spline SPH; Monaghan artificial viscosity and artificial stress; Mie–Grüneisen metals with
// J2 plasticity (Johnson–Cook-style hardening, thermal softening); Tuler–Butcher cumulative spall plus ductile
// failure on tensile plastic strain; γ-law explosive with programmed burn; deformation-gradient refinement.
#pragma once
#include "portable.h"

// ---------------------------------------------------------------- shared layouts

/// Same layout as scl::MaterialParams (80 bytes).
struct MatP {
    float rho0, c0, s, grun, G, yA, yB, yN, yMax, cv, meltE, spall, failStrain, detVel, gammaGas, e0;
    u32 kind;
    float tbSigma0, tbK, bernoulliR;
};

struct SimParams {
    v4 gmin;      // grid origin xyz, cell size
    u4 gdim;      // nx, ny, nz, ncells
    v4 box;       // lateral box radius, zMin, zMax, zFace
    v4 misc;      // target radius, fine spacing, wake margin, radius counted for penetration
    u4 cnt;       // slot capacity, max split generations
    v4 quant;     // frame quantisation origin xyz, xy span
    v4 quant2;    // z span, core radius for the jet tip
};

// state words
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
#define S_COUNT 16

// flags (low 8 bits: material; bits 16–18: split generation)
#define F_ACTIVE 256u
#define F_FIXED 512u
#define F_DAMAGED 1024u
#define F_SLEEP 2048u
#define F_VENTED 4096u
#define F_COARSE 8192u

#define ZOFF 1000.0f

/// All particle arrays. v4 layouts:
///   pos (x,y,z,h)  vel (vx,vy,vz,mass)  st (rho,e,p,c)  S0 (sxx,syy,szz,sxy)  S1 (sxz,syz,epsP,epsT)
///   aux (burn, detonation time, spall damage, -)  G0..G2 rows of F  L0..L2 rows of ∇v
///   acc (ax,ay,az,AV heating)  r0 (drho, de, -, -)  dS0/dS1 stress rates
struct Particles {
    SCL_DEV v4* pos; SCL_DEV v4* vel; SCL_DEV v4* st; SCL_DEV v4* S0; SCL_DEV v4* S1; SCL_DEV v4* aux;
    SCL_DEV u32* flags;
    SCL_DEV v4* G0; SCL_DEV v4* G1; SCL_DEV v4* G2;
    SCL_DEV v4* L0; SCL_DEV v4* L1; SCL_DEV v4* L2;
    SCL_DEV v4* acc; SCL_DEV v4* r0; SCL_DEV v4* dS0; SCL_DEV v4* dS1;
};

struct Grid {
    SCL_DEV u32* start;     // ncells + 1 offsets into cell-ordered particles
};

// ---------------------------------------------------------------- kernels

SCL_FN float kW(float r, float h) {
    float q = r / h, sig = 1.0f / (3.14159265f * h * h * h);
    if (q < 1.0f) return sig * (1.0f - 1.5f * q * q + 0.75f * q * q * q);
    if (q < 2.0f) { float t = 2.0f - q; return sig * 0.25f * t * t * t; }
    return 0.0f;
}
SCL_FN float kDW(float r, float h) {
    float q = r / h, sig = 1.0f / (3.14159265f * h * h * h * h);
    if (q < 1.0f) return sig * (-3.0f * q + 2.25f * q * q);
    if (q < 2.0f) { float t = 2.0f - q; return -sig * 0.75f * t * t; }
    return 0.0f;
}

SCL_FN int cellCoord(float v, float o, float cs) { return int(scl_floor((v - o) / cs)); }
SCL_FN bool cellInGrid(int cx, int cy, int cz, SCL_CONST const SimParams& P) {
    return cx >= 0 && cy >= 0 && cz >= 0 && cx < int(P.gdim.x) && cy < int(P.gdim.y) && cz < int(P.gdim.z);
}
SCL_FN u32 cellIndex(int cx, int cy, int cz, SCL_CONST const SimParams& P) {
    return (u32(cz) * P.gdim.y + u32(cy)) * P.gdim.x + u32(cx);
}
/// Cell of a particle, or ncells when it is not live / outside the box (then it is vented).
SCL_FN u32 particleCell(u32 i, Particles b, SCL_CONST const SimParams& P) {
    u32 f = b.flags[i];
    if ((f & F_ACTIVE) == 0u) return P.gdim.w;
    v4 p = b.pos[i];
    int cx = cellCoord(p.x, P.gmin.x, P.gmin.w), cy = cellCoord(p.y, P.gmin.y, P.gmin.w), cz = cellCoord(p.z, P.gmin.z, P.gmin.w);
    if (!cellInGrid(cx, cy, cz, P)) { b.flags[i] = (f & ~F_ACTIVE) | F_VENTED; return P.gdim.w; }
    return cellIndex(cx, cy, cz, P);
}

// Neighbour loop over the 27 surrounding cells (particles are stored in cell order, so j = slot).
#define SCL_NEIGHBOURS_BEGIN \
    int cbx = cellCoord(pi.x, P.gmin.x, P.gmin.w), cby = cellCoord(pi.y, P.gmin.y, P.gmin.w), cbz = cellCoord(pi.z, P.gmin.z, P.gmin.w); \
    for (int dz = -1; dz <= 1; dz++) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { \
        if (!cellInGrid(cbx + dx, cby + dy, cbz + dz, P)) continue; \
        u32 cell = cellIndex(cbx + dx, cby + dy, cbz + dz, P); \
        u32 q1 = g.start[cell + 1]; \
        for (u32 j = g.start[cell]; j < q1; j++) { \
            if (j == i) continue; \
            v4 pj4 = b.pos[j]; \
            v3 d = pi - xyz(pj4); \
            float r2 = dot3(d, d); \
            float sup = hi + pj4.w; \
            if (r2 >= sup * sup) continue; \
            float r = scl_fmax(scl_sqrt(r2), 1e-7f); \
            float hij = 0.5f * (hi + pj4.w); \
            v3 gw = d * (kDW(r, hij) / r);
#define SCL_NEIGHBOURS_END }}

struct PC { float p, c; };

SCL_FN PC eos(MatP m, float rho, float e, float burn, bool damaged) {
    PC o;
    if (m.kind == 0u) {
        float g = m.gammaGas;
        float pg = (g - 1.0f) * rho * scl_fmax(e, 0.0f);
        float mu = rho / m.rho0 - 1.0f;
        float un = 1.0f - burn;
        float pu = un * m.rho0 * m.c0 * m.c0 * scl_fmax(mu, 0.0f);
        float c2 = g * pg / rho + un * m.c0 * m.c0;
        o.p = pg + pu; o.c = scl_sqrt(scl_fmax(c2, 0.01f));
        return o;
    }
    float mu = rho / m.rho0 - 1.0f;
    float pr, c2;
    if (mu > 0.0f) {
        float den = scl_fmax(1.0f - (m.s - 1.0f) * mu, 0.4f);
        pr = m.rho0 * m.c0 * m.c0 * mu * (1.0f + (1.0f - m.grun / 2.0f) * mu) / (den * den) + m.grun * m.rho0 * e;
        c2 = m.c0 * m.c0 * (1.0f + 2.0f * (m.s - 1.0f) * mu) / (den * den);
    } else {
        pr = m.rho0 * m.c0 * m.c0 * mu + m.grun * m.rho0 * e;
        c2 = m.c0 * m.c0;
    }
    if (damaged) pr = scl_fmax(pr, 0.0f); else c2 += 4.0f * m.G / (3.0f * rho);
    o.p = pr; o.c = scl_sqrt(scl_fmax(c2, 0.25f * m.c0 * m.c0));
    return o;
}

SCL_FN void eosBody(u32 i, Particles b, SCL_CONST const MatP* mats, SCL_CONST const SimParams& P) {
    if (i >= P.cnt.x) return;
    u32 f = b.flags[i];
    if ((f & F_ACTIVE) == 0u) return;
    v4 s = b.st[i];
    PC pc = eos(mats[f & 255u], scl_fmax(s.x, 1e-5f), s.y, b.aux[i].x, (f & F_DAMAGED) != 0u);
    b.st[i] = mk4(s.x, s.y, pc.p, pc.c);
}

/// Velocity gradient, continuity, Jaumann stress rate and pdV/deviatoric work.
/// One pass over the neighbours for everything that reads them: the velocity gradient with the stress and energy
/// rates, and the momentum (stress divergence + artificial viscosity + artificial stress) with the local time-step
/// limit. Both halves read only the pre-step state, so they share each neighbour's loads.
SCL_FN void interactBody(u32 i, Particles b, Grid g, SCL_CONST const MatP* mats, SCL_DEV SCL_ATOMIC_U32* state,
                         SCL_CONST const SimParams& P) {
    if (i >= g.start[P.gdim.w]) return;
    u32 f = b.flags[i];
    v4 z4 = mk4(0, 0, 0, 0);
    if ((f & F_ACTIVE) == 0u || (f & F_FIXED) != 0u) {
        b.r0[i] = z4; b.dS0[i] = z4; b.dS1[i] = z4; b.L0[i] = z4; b.L1[i] = z4; b.L2[i] = z4;
        b.acc[i] = z4;
        return;
    }
    v4 p4 = b.pos[i]; v3 pi = xyz(p4); float hi = p4.w;
    v3 vi = xyz(b.vel[i]);
    v4 si = b.st[i];
    float ri = si.x, pri = si.z, ci = si.w;
    float ri2 = 1.0f / (ri * ri);
    v4 a0 = b.S0[i], c0 = b.S1[i];
    // σ/ρ² rows for particle i
    v3 Ti0 = mk3(a0.x - pri, a0.w, c0.x) * ri2, Ti1 = mk3(a0.w, a0.y - pri, c0.y) * ri2, Ti2 = mk3(c0.x, c0.y, a0.z - pri) * ri2;
    bool solidI = (f & 255u) != 0u;
    float Ri = (solidI && pri < 0.0f) ? 0.3f * (-pri) * ri2 : 0.0f;
    // rows: L_a = (∂v_a/∂x, ∂v_a/∂y, ∂v_a/∂z)
    v3 La = mk3(0, 0, 0), Lb = mk3(0, 0, 0), Lc = mk3(0, 0, 0);
    v3 ai = mk3(0, 0, 0); float heat = 0, mumax = 0;
    SCL_NEIGHBOURS_BEGIN
        v4 vj4 = b.vel[j];
        v4 sj = b.st[j];
        float mj = vj4.w;
        float rj = sj.x, prj = sj.z;
        // velocity gradient
        float Vj = mj / rj;
        v3 dvj = xyz(vj4) - vi;
        La = La + gw * (Vj * dvj.x);
        Lb = Lb + gw * (Vj * dvj.y);
        Lc = Lc + gw * (Vj * dvj.z);
        // momentum
        u32 fj = b.flags[j];
        float rj2 = 1.0f / (rj * rj);
        v4 a1 = b.S0[j], c1 = b.S1[j];
        v3 T0 = Ti0 + mk3(a1.x - prj, a1.w, c1.x) * rj2;
        v3 T1 = Ti1 + mk3(a1.w, a1.y - prj, c1.y) * rj2;
        v3 T2 = Ti2 + mk3(c1.x, c1.y, a1.z - prj) * rj2;
        v3 dv = vi - xyz(vj4);
        float vr = dot3(dv, d);
        float extra = 0.0f;
        if (vr < 0.0f) {
            float mu = hij * vr / (r2 + 0.01f * hij * hij);
            float cb = 0.5f * (ci + sj.w), rb = 0.5f * (ri + rj);
            float piv = (-1.0f * cb * mu + 2.0f * mu * mu) / rb;
            extra += piv;
            heat += 0.5f * mj * piv * dot3(dv, gw);
            mumax = scl_fmax(mumax, -mu);
        }
        float Rj = ((fj & 255u) != 0u && prj < 0.0f) ? 0.3f * (-prj) * rj2 : 0.0f;
        if (Ri + Rj > 0.0f) {
            float fw = kW(r, hij) / kW(hij / 1.3f, hij);
            float f2 = fw * fw;
            extra += (Ri + Rj) * f2 * f2;
        }
        ai = ai + mk3(dot3(T0, gw), dot3(T1, gw), dot3(T2, gw)) * mj - gw * (mj * extra);
    SCL_NEIGHBOURS_END

    // ---- rates
    b.L0[i] = mk4(La, 0); b.L1[i] = mk4(Lb, 0); b.L2[i] = mk4(Lc, 0);
    float exx = La.x, eyy = Lb.y, ezz = Lc.z;
    float exy = 0.5f * (La.y + Lb.x), exz = 0.5f * (La.z + Lc.x), eyz = 0.5f * (Lb.z + Lc.y);
    float wxy = 0.5f * (La.y - Lb.x), wxz = 0.5f * (La.z - Lc.x), wyz = 0.5f * (Lb.z - Lc.y);
    float div = exx + eyy + ezz;
    float rho = ri, pr = pri;
    MatP m = mats[f & 255u];
    float sxx = a0.x, syy = a0.y, szz = a0.z, sxy = a0.w, sxz = c0.x, syz = c0.y;
    float de;
    if (m.kind == 1u && (f & F_DAMAGED) == 0u) {
        float g2 = 2.0f * m.G, d3 = div / 3.0f;
        // Jaumann rotation R = W·S − S·W with W antisymmetric (wxy, wxz, wyz)
        float Rxx = 2.0f * (wxy * sxy + wxz * sxz);
        float Ryy = 2.0f * (-wxy * sxy + wyz * syz);
        float Rzz = 2.0f * (-wxz * sxz - wyz * syz);
        float Rxy = wxy * (syy - sxx) + wxz * syz + wyz * sxz;
        float Rxz = wxz * (szz - sxx) + wxy * syz - wyz * sxy;
        float Ryz = wyz * (szz - syy) - wxy * sxz - wxz * sxy;
        b.dS0[i] = mk4(g2 * (exx - d3) + Rxx, g2 * (eyy - d3) + Ryy, g2 * (ezz - d3) + Rzz, g2 * exy + Rxy);
        b.dS1[i] = mk4(g2 * exz + Rxz, g2 * eyz + Ryz, 0, 0);
        de = (-pr * div + sxx * exx + syy * eyy + szz * ezz + 2.0f * (sxy * exy + sxz * exz + syz * eyz)) / rho;
    } else {
        b.dS0[i] = z4; b.dS1[i] = z4;
        de = -pr * div / rho;
    }
    b.r0[i] = mk4(-rho * div, de, 0, 0);

    // ---- momentum and time step
    b.acc[i] = mk4(ai, heat);
    float am = len3(ai);
    float d1 = hi / (ci + 1.2f * (ci + 2.0f * mumax));
    float d2 = am > 0.0f ? scl_sqrt(hi / am) : 1e9f;
    scl_atomic_min(&state[S_DTMIN], scl_as_uint(scl_fmin(0.3f * d1, 0.25f * d2)));
}

/// Single-thread: commit the global time step and reset per-step reductions.
SCL_FN void finalizeDtBody(SCL_DEV u32* state) {
    float prev = scl_as_float(state[S_DT]);
    float m = scl_as_float(state[S_DTMIN]);
    float dt = scl_fmin(scl_fmax(scl_fmin(m, prev * 1.25f), 1e-6f), 0.05f);
    state[S_DT] = scl_as_uint(dt);
    state[S_DTMIN] = scl_as_uint(0.05f);
    state[S_LINERZ] = 0; state[S_PENZ] = 0; state[S_TIPV] = 0; state[S_CORETIPZ] = 0; state[S_FOOTVZ] = 0;
}

SCL_FN void integrateBody(u32 i, Particles b, SCL_DEV SCL_ATOMIC_U32* state, SCL_CONST const MatP* mats, SCL_CONST const SimParams& P) {
    if (i >= P.cnt.x) return;
    u32 f = b.flags[i];
    u32 awake = scl_atomic_load(&state[S_AWAKE]);
    if ((f & F_SLEEP) != 0u) {
        if (awake != 0u) b.flags[i] = (f & ~F_SLEEP) | F_ACTIVE;
        return;
    }
    if ((f & F_ACTIVE) == 0u || (f & F_FIXED) != 0u) return;
    float dt = scl_as_float(scl_atomic_load(&state[S_DT]));
    float tnew = scl_as_float(scl_atomic_load(&state[S_TIME])) + dt;
    u32 mi = f & 255u;
    MatP m = mats[mi];
    v4 v4o = b.vel[i], a4 = b.acc[i];
    v3 v = xyz(v4o) + xyz(a4) * dt;
    v4 p4 = b.pos[i];
    v3 p = xyz(p4) + v * dt;
    b.pos[i] = mk4(p, p4.w);
    b.vel[i] = mk4(v, v4o.w);
    v4 s = b.st[i];
    v4 rr = b.r0[i];
    float rate = scl_fmin(scl_fmax(rr.x / scl_fmax(s.x, 1e-6f) * dt, -0.05f), 0.05f);
    float lo = m.kind == 0u ? 1e-3f : 0.5f * m.rho0;
    float hi = m.kind == 0u ? 4.0f * m.rho0 : 2.2f * m.rho0;
    float rho = scl_fmin(scl_fmax(s.x * scl_exp(rate), lo), hi);
    float e = s.y + (rr.y + a4.w) * dt;
    v4 ax = b.aux[i];
    float rxy = scl_sqrt(p.x * p.x + p.y * p.y);
    bool outBox = rxy > P.box.x || p.z < P.box.y || p.z > P.box.z;
    if (m.kind == 0u) {
        if (ax.x < 1.0f) {
            float fb = scl_fmin(scl_fmax((tnew - ax.y) * m.detVel / (2.6f * p4.w), 0.0f), 1.0f);
            if (fb > ax.x) { e += (fb - ax.x) * m.e0; ax.x = fb; b.aux[i] = ax; }
        }
        e = scl_fmax(e, 0.0f);
        if ((ax.x >= 1.0f && rho < 0.01f * m.rho0) || outBox) f = (f & ~F_ACTIVE) | F_VENTED;
    } else {
        // deformation gradient: dF/dt = L·F (rows of F in G0..G2)
        v3 g0 = xyz(b.G0[i]), g1 = xyz(b.G1[i]), g2 = xyz(b.G2[i]);
        v3 l0 = xyz(b.L0[i]), l1 = xyz(b.L1[i]), l2 = xyz(b.L2[i]);
        b.G0[i] = mk4(g0 + (g0 * l0.x + g1 * l0.y + g2 * l0.z) * dt, 0);
        b.G1[i] = mk4(g1 + (g0 * l1.x + g1 * l1.y + g2 * l1.z) * dt, 0);
        b.G2[i] = mk4(g2 + (g0 * l2.x + g1 * l2.y + g2 * l2.z) * dt, 0);
        v4 a = b.S0[i], c = b.S1[i];
        if ((f & F_DAMAGED) == 0u) {
            v4 da = b.dS0[i], dc = b.dS1[i];
            a = mk4(a.x + da.x * dt, a.y + da.y * dt, a.z + da.z * dt, a.w + da.w * dt);
            c.x += dc.x * dt; c.y += dc.y * dt;
            float j2 = 0.5f * (a.x * a.x + a.y * a.y + a.z * a.z) + a.w * a.w + c.x * c.x + c.y * c.y;
            float seq = scl_sqrt(3.0f * j2);
            float soft = scl_fmax(0.0f, 1.0f - scl_fmax(e, 0.0f) / m.meltE);
            float y = scl_fmin(m.yA + m.yB * scl_pow(scl_fmax(c.z, 1e-6f), m.yN), m.yMax) * soft;
            if (seq > y) {
                float sc = seq > 1e-9f ? y / seq : 0.0f;
                float dep = (seq - y) / (3.0f * m.G);
                a = mk4(a.x * sc, a.y * sc, a.z * sc, a.w * sc);
                c.x *= sc; c.y *= sc;
                c.z += dep;
                if (s.z < 0.0f) c.w += dep;
            }
            // Tuler–Butcher cumulative spall damage
            float tension = -s.z;
            if (tension > m.tbSigma0) { ax.z += (tension - m.tbSigma0) * (tension - m.tbSigma0) * dt; b.aux[i] = ax; }
            if (ax.z >= m.tbK || c.w > m.failStrain) { f |= F_DAMAGED; a = mk4(0, 0, 0, 0); c.x = 0; c.y = 0; }
            b.S0[i] = a; b.S1[i] = c;
        }
        if (outBox) f = (f & ~F_ACTIVE) | F_VENTED;
        if (mi == 1u && (f & F_ACTIVE) != 0u) {
            u32 zb = scl_as_uint(p.z + ZOFF);
            scl_atomic_max(&state[S_LINERZ], zb);
            if (rxy < P.misc.w) {
                scl_atomic_max(&state[S_PENZ], zb);
                if (v.z > 0.0f) scl_atomic_max(&state[S_FOOTVZ], scl_as_uint(v.z));
            }
            if (rxy < P.quant2.y) {
                scl_atomic_max(&state[S_CORETIPZ], zb);
                if (v.z > 0.0f) scl_atomic_max(&state[S_TIPV], scl_as_uint(v.z));
            }
        }
    }
    b.st[i] = mk4(rho, e, s.z, s.w);
    b.flags[i] = f;
}

/// Single-thread: advance time and wake the target when the liner approaches it.
SCL_FN void advanceBody(SCL_DEV u32* state, SCL_CONST const SimParams& P) {
    float t = scl_as_float(state[S_TIME]) + scl_as_float(state[S_DT]);
    state[S_TIME] = scl_as_uint(t);
    float lz = scl_as_float(state[S_LINERZ]) - ZOFF;
    if (state[S_AWAKE] == 0u && state[S_LINERZ] != 0u && lz > P.box.w - P.misc.z) state[S_AWAKE] = 1u;
}

/// Deformation-gradient refinement. The material element's largest principal stretch is √λ of B = F·Fᵀ
/// along eigenvector n. At a stretch of 2 it splits into its two halves: children at ±¼ of the stretched
/// length along n, half the mass each, velocities from the local velocity gradient (momentum conserved),
/// smoothing length × 2^(−1/3), and F's stretch along n halved.
SCL_FN void splitBody(u32 i, Particles b, SCL_DEV SCL_ATOMIC_U32* state, SCL_CONST const SimParams& P) {
    u32 used = scl_atomic_load(&state[S_USED]);
    if (i >= used) return;
    u32 f = b.flags[i];
    if ((f & 255u) != 1u || (f & F_ACTIVE) == 0u) return;
    u32 gen = (f >> 16) & 7u;
    if (gen >= P.cnt.y) return;
    v3 g0 = xyz(b.G0[i]), g1 = xyz(b.G1[i]), g2 = xyz(b.G2[i]);
    m3 B;
    B.r0 = mk3(dot3(g0, g0), dot3(g0, g1), dot3(g0, g2));
    B.r1 = mk3(dot3(g1, g0), dot3(g1, g1), dot3(g1, g2));
    B.r2 = mk3(dot3(g2, g0), dot3(g2, g1), dot3(g2, g2));
    v3 n = norm3(mulv(B, mk3(0.577f, 0.578f, 0.579f)));
    for (int it = 0; it < 16; it++) n = norm3(mulv(B, n));
    float stretch = scl_sqrt(scl_fmax(dot3(n, mulv(B, n)), 0.0f));
    if (stretch < 2.0f) return;
    u32 slot = scl_atomic_add(&state[S_USED], 1u);
    if (slot >= P.cnt.x) return;
    float delta = 0.25f * stretch * P.misc.y;
    v4 p = b.pos[i], v = b.vel[i];
    v3 dv = mk3(dot3(xyz(b.L0[i]), n), dot3(xyz(b.L1[i]), n), dot3(xyz(b.L2[i]), n)) * delta;
    float hNew = p.w * 0.7937005f;
    b.pos[i] = mk4(xyz(p) - n * delta, hNew);
    b.pos[slot] = mk4(xyz(p) + n * delta, hNew);
    b.vel[i] = mk4(xyz(v) - dv, 0.5f * v.w);
    b.vel[slot] = mk4(xyz(v) + dv, 0.5f * v.w);
    b.st[slot] = b.st[i]; b.S0[slot] = b.S0[i]; b.S1[slot] = b.S1[i]; b.aux[slot] = b.aux[i];
    // F ← F − ½ n (nᵀF): row a loses ½ n_a (nᵀF)
    v3 nF = g0 * n.x + g1 * n.y + g2 * n.z;
    v4 r0n = mk4(g0 - nF * (0.5f * n.x), 0), r1n = mk4(g1 - nF * (0.5f * n.y), 0), r2n = mk4(g2 - nF * (0.5f * n.z), 0);
    b.G0[i] = r0n; b.G1[i] = r1n; b.G2[i] = r2n;
    b.G0[slot] = r0n; b.G1[slot] = r1n; b.G2[slot] = r2n;
    u32 fNew = (f & ~(7u << 16)) | ((gen + 1u) << 16);
    b.flags[i] = fNew; b.flags[slot] = fNew;
}

// ---------------------------------------------------------------- frames

/// Same layout as scl::Particle3D (12 bytes).
struct FrameP { unsigned short x, y, z; unsigned char speed, temp, pres, strain, mat, fl; };

SCL_FN void packBody(u32 i, Particles b, SCL_DEV FrameP* out, SCL_CONST const MatP* mats, SCL_CONST const SimParams& P) {
    if (i >= P.cnt.x) return;
    u32 f = b.flags[i];
    v4 p = b.pos[i];
    float qx = scl_fmin(scl_fmax((p.x - P.quant.x) / P.quant.w, 0.0f), 1.0f);
    float qy = scl_fmin(scl_fmax((p.y - P.quant.y) / P.quant.w, 0.0f), 1.0f);
    float qz = scl_fmin(scl_fmax((p.z - P.quant.z) / P.quant2.x, 0.0f), 1.0f);
    FrameP o;
    o.x = (unsigned short)(qx * 65535.0f); o.y = (unsigned short)(qy * 65535.0f); o.z = (unsigned short)(qz * 65535.0f);
    u32 mi = f & 255u;
    MatP m = mats[mi];
    v4 s = b.st[i];
    float sp = len3(xyz(b.vel[i]));
    float T = mi == 0u ? 300.0f + scl_fmax(s.y, 0.0f) * 900.0f : 300.0f + scl_fmax(s.y, 0.0f) / m.cv;
    o.speed = (unsigned char)(scl_fmin(scl_fmax(sp / 10.0f, 0.0f), 1.0f) * 255.0f);
    o.temp = (unsigned char)(scl_fmin(scl_fmax((T - 300.0f) / 4000.0f, 0.0f), 1.0f) * 255.0f);
    o.pres = (unsigned char)(scl_fmin(scl_fmax(scl_log2(1.0f + scl_fmax(s.z, 0.0f)) / scl_log2(201.0f), 0.0f), 1.0f) * 255.0f);
    o.strain = (unsigned char)(scl_fmin(scl_fmax(b.S1[i].z / 4.0f, 0.0f), 1.0f) * 255.0f);
    o.mat = (unsigned char)mi;
    u32 fl = 0u;
    if ((f & (F_ACTIVE | F_SLEEP)) != 0u && (f & F_VENTED) == 0u) fl |= 1u;
    if (mi == 0u && b.aux[i].x > 0.5f) fl |= 2u;
    if ((f & F_DAMAGED) != 0u) fl |= 4u;
    if ((f & F_COARSE) != 0u) fl |= 8u;
    fl |= ((f >> 16) & 7u) << 4;
    o.fl = (unsigned char)fl;
    out[i] = o;
}
