#include "geometry.hpp"

#include <algorithm>
#include <cmath>
#include <random>

namespace scl {

namespace {
constexpr float kPi = 3.14159265358979f;   // M_PI is not standard C++ (missing with MSVC headers)
struct P0 { float x, y, z, m; uint32_t f; };

float len3(float x, float y, float z) { return std::sqrt(x * x + y * y + z * z); }
}  // namespace

Geometry3D buildGeometry(const Config& cfg) {
    Geometry3D g;
    g.config = cfg;
    g.CD = cfg.chargeDiameter;
    g.R = g.CD / 2;
    g.alpha = cfg.coneAngleDeg / 2 * kPi / 180;
    const float linerT = cfg.linerThicknessFrac * g.CD;
    g.dpFine = linerT / float(cfg.layers);
    g.dpCoarse = 2 * g.dpFine;
    const float H = g.R / std::tan(g.alpha);
    g.L = H + cfg.headHeightCD * g.CD;
    g.zApex = g.L - H;
    g.zFace = g.L + cfg.standoffCD * g.CD;
    g.RT = cfg.targetRadiusCD * g.CD;
    g.zBack = g.zFace + cfg.targetThicknessCD * g.CD;
    g.boxRadius = 1.5f * g.CD;
    g.zMin = -0.75f * g.CD;
    g.zMax = g.zBack + 0.5f * g.CD;
    g.materials = {explosive(cfg.detonationVelocity), linerMaterial(cfg.liner, cfg.breakupStretch),
                   targetMaterial(cfg.target)};

    const float sa = std::sin(g.alpha), ca = std::cos(g.alpha);
    const float fF = g.dpFine, dC = g.dpCoarse;
    std::mt19937 rng(12345);
    std::uniform_real_distribution<float> uni(0, 1);
    std::vector<P0> liner, pts;

    // liner: rings laid on the cone; wall thickness may vary around the circumference
    const float S = g.R / sa;
    for (int j = 0; j < cfg.layers; j++) {
        for (float s = 0.5f * fF; s <= S; s += fF) {
            const float rMid = s * sa - (j + 0.5f) * fF * ca;
            if (rMid <= 0.3f * fF) continue;
            const int nth = std::max(1, int(std::lround(2 * kPi * rMid / fF)));
            const float phase = uni(rng);
            for (int k = 0; k < nth; k++) {
                const float th = 2 * kPi * (k + phase) / nth;
                const float scale = 1 + cfg.asymmetry.wallVariation * std::cos(th);
                const float d = (j + 0.5f) * fF * scale;
                const float rc = s * sa - d * ca, zc = g.zApex + s * ca + d * sa;
                if (rc < 0.3f * fF || zc > g.L + 0.5f * fF) continue;
                const float m = g.materials[1].rho0 * fF * fF * scale * (2 * kPi * rc / nth);
                liner.push_back({rc * std::cos(th), rc * std::sin(th), zc, m, 1u | F_ACTIVE});
            }
        }
    }
    // solid apex on the axis
    const float zIn = g.zApex + linerT / sa;
    for (float zz = g.zApex; zz < zIn + fF; zz += fF) {
        for (int ix = -2; ix <= 1; ix++) for (int iy = -2; iy <= 1; iy++) {
            const float px = (ix + 0.5f) * fF, py = (iy + 0.5f) * fF;
            const float r = std::hypot(px, py);
            const float dn = (zz - g.zApex) * sa - r * ca;
            if (dn < 0 || dn > linerT) continue;
            bool near = false;
            for (const auto& q : liner)
                if ((q.x - px) * (q.x - px) + (q.y - py) * (q.y - py) + (q.z - zz) * (q.z - zz) < 0.45f * fF * fF) { near = true; break; }
            if (!near) liner.push_back({px, py, zz, g.materials[1].rho0 * fF * fF * fF, 1u | F_ACTIVE});
        }
    }
    // explosive (coarse lattice)
    const int nr = int(g.R / dC) + 1, nzHE = int(g.L / dC);
    for (int k = 0; k < nzHE; k++) {
        const float pz = (k + 0.5f) * dC;
        for (int ix = -nr; ix < nr; ix++) for (int iy = -nr; iy < nr; iy++) {
            const float px = (ix + 0.5f) * dC, py = (iy + 0.5f) * dC;
            const float r = std::hypot(px, py);
            if (r > g.R) continue;
            if ((pz - g.zApex) * sa - r * ca > -0.5f * dC) continue;
            pts.push_back({px, py, pz, g.materials[0].rho0 * dC * dC * dC, 0u | F_ACTIVE | F_COARSE});
        }
    }
    const size_t linerCount = liner.size();
    pts.insert(pts.end(), liner.begin(), liner.end());
    // target (coarse lattice), asleep until the jet arrives; outer shell held fixed
    const int nrt = int(g.RT / dC) + 1, nzT = int(cfg.targetThicknessCD * g.CD / dC);
    for (int k = 0; k < nzT; k++) {
        const float pz = g.zFace + (k + 0.5f) * dC;
        for (int ix = -nrt; ix < nrt; ix++) for (int iy = -nrt; iy < nrt; iy++) {
            const float px = (ix + 0.5f) * dC, py = (iy + 0.5f) * dC;
            const float r = std::hypot(px, py);
            if (r > g.RT) continue;
            uint32_t f = 2u | F_SLEEP | F_COARSE;
            if (r > g.RT - 2 * dC) f |= F_FIXED;
            pts.push_back({px, py, pz, g.materials[2].rho0 * dC * dC * dC, f});
        }
    }

    g.used = pts.size();
    // each liner particle can become 2^levels particles
    const size_t spare = cfg.jetRefinement > 0 ? linerCount * ((size_t(1) << cfg.jetRefinement) - 1) : 0;
    g.capacity = g.used + spare;
    g.pos.assign(g.capacity, {0, 0, -1e4f, 1.3f * fF});
    g.vel.assign(g.capacity, {0, 0, 0, 1e-9f});
    g.detonationTime.assign(g.capacity, 0);
    g.flags.assign(g.capacity, 0);
    const float D = g.materials[0].detVel, v0 = cfg.approachSpeed / 1000;
    const float ox = cfg.asymmetry.initiationOffsetMM;
    for (size_t i = 0; i < g.used; i++) {
        const auto& q = pts[i];
        const uint32_t mat = q.f & 255u;
        const bool fine = (q.f & F_COARSE) == 0;
        g.pos[i] = {q.x, q.y, q.z, 1.3f * (fine ? fF : dC)};
        g.vel[i] = {0, 0, mat == 2 ? 0.0f : v0, q.m};
        g.detonationTime[i] = mat == 0 ? len3(q.x - ox, q.y, q.z) / D : 0;
        g.flags[i] = q.f;
    }
    return g;
}

SceneInfo Geometry3D::scene() const {
    SceneInfo s{};
    s.geometry = config.geometry;
    s.liner = config.liner;
    s.target = config.target;
    s.chargeLength = L;
    s.chargeRadius = R;
    s.chargeDiameter = CD;
    s.zFace = zFace;
    s.zBack = zBack;
    s.targetRadius = RT;
    s.boundsMin[0] = -boxRadius; s.boundsMin[1] = -boxRadius; s.boundsMin[2] = zMin;
    s.boundsSpanXY = 2 * boxRadius;
    s.boundsSpanZ = zMax - zMin;
    s.spacingFine = dpFine;
    s.spacingCoarse = dpCoarse;
    return s;
}

size_t estimateParticles(const Config& c) {
    const float CD = c.chargeDiameter, R = CD / 2;
    const float dpF = c.linerThicknessFrac * CD / float(c.layers), dpC = 2 * dpF;
    const float a = c.coneAngleDeg / 2 * kPi / 180;
    const float H = R / std::tan(a), L = H + c.headHeightCD * CD;
    const float pi = kPi;
    const double he = (pi * R * R * L - pi * R * R * H / 3) / (dpC * dpC * dpC);
    const double liner = pi * R * (R / std::sin(a)) * c.linerThicknessFrac * CD / (dpF * dpF * dpF);
    const float RT = c.targetRadiusCD * CD;
    const double tgt = pi * RT * RT * c.targetThicknessCD * CD / (dpC * dpC * dpC);
    return size_t(he + liner * double(size_t(1) << std::max(c.jetRefinement, 0)) + tgt);
}

}  // namespace scl
