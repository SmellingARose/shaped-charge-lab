#include "solver.hpp"
#include <cmath>

namespace scl {

// Dense grid bound: 2 × 4 bytes per bucket (counts and starts) on every backend, 384 MB at the limit.
constexpr size_t kMaxDenseBuckets = size_t(48) << 20;

SimParams makeSimParams(const Geometry3D& g) {
    // Largest interaction distance: twice the coarse smoothing length (h only shrinks, when particles split)
    const float reach = 2 * 1.3f * g.dpCoarse;
    const float h0 = 1.3f * g.dpCoarse * 1.001f;   // level-0 bound, with slack so rounding never crosses a level
    // size levels: the original fine particles are level 1, each 3 splits (h × 0.794 each) one level further
    const float hMin = 1.3f * g.dpFine * std::pow(0.7937005f, float(g.config.jetRefinement));
    u32 levels = 1;
    while (levels < SCL_MAX_LEVELS && hMin <= h0 * std::ldexp(1.0f, -int(levels))) levels++;
    float grow = 1;
    int nx = 0, nz = 0;
    for (;;) {
        const float cs = 2 * h0 * grow / SCL_CELL_REACH;
        nx = int(2 * g.boxRadius / cs) + 1;
        nz = int((g.zMax - g.zMin) / cs) + 1;
        if (size_t(nx) * nx * nz * levels + SCL_EXTRA_BUCKETS <= kMaxDenseBuckets) break;
        grow *= 1.08f;   // memory bound for the finest resolutions: larger cells, still covering every neighbour
    }
    const float cs = 2 * h0 * grow / SCL_CELL_REACH;
    // hash tables: at least one bucket per particle that can be finer than level 0 (the liner and its splits)
    size_t fine = 0;
    for (size_t i = 0; i < g.used; i++) if ((g.flags[i] & F_COARSE) == 0) fine++;
    fine += g.capacity - g.used;
    u32 table = 1024;
    while (table < fine) table <<= 1;
    SimParams P{};
    P.gmin = mk4(-g.boxRadius, -g.boxRadius, g.zMin, cs);
    P.gdim = {u32(nx), u32(nx), u32(nz), u32(nx * nx * nz)};
    P.box = mk4(g.boxRadius - 0.5f * reach * grow, g.zMin + 0.5f * reach * grow, g.zMax - 0.5f * reach * grow, g.zFace);   // vent margin
    P.misc = mk4(g.RT, g.dpFine, 2 * 2.6f * g.dpCoarse + 2 * g.dpFine, g.RT - 3 * g.dpCoarse);
    P.cnt = {u32(g.capacity), u32(g.config.jetRefinement), 0, 0};
    P.quant = mk4(-g.boxRadius, -g.boxRadius, g.zMin, 2 * g.boxRadius);
    P.quant2 = mk4(g.zMax - g.zMin, 0.15f * g.CD, 0, 0);
    P.lev = {levels, table - 1, 0, 0};
    P.lvh = mk4(h0, 0.5f * cs, 0.25f * cs, 0);
    return P;
}

void initState(u32* s, size_t used) {
    for (int k = 0; k < S_COUNT; k++) s[k] = 0;
    s[S_DT] = scl_as_uint(1e-3f);
    s[S_DTMIN] = scl_as_uint(0.05f);
    s[S_USED] = u32(used);
}

}  // namespace scl
