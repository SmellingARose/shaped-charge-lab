#include "solver.hpp"
#include <cmath>

namespace scl {

// Grid size bound: 2 × 4 bytes per cell (counts and starts) on every backend, 128 MB at the limit.
constexpr size_t kMaxCells = size_t(16) << 20;

SimParams makeSimParams(const Geometry3D& g) {
    // Largest interaction distance: twice the coarse smoothing length (h only shrinks, when particles split)
    float reach = 2 * 1.3f * g.dpCoarse;
    int nx = 0, nz = 0;
    for (;;) {
        const float cs = reach / SCL_CELL_REACH;
        nx = int(2 * g.boxRadius / cs) + 1;
        nz = int((g.zMax - g.zMin) / cs) + 1;
        if (size_t(nx) * nx * nz + 1 <= kMaxCells) break;
        reach *= 1.08f;   // memory bound for the finest resolutions: larger cells, still covering every neighbour
    }
    const float cs = reach / SCL_CELL_REACH;
    SimParams P{};
    P.gmin = mk4(-g.boxRadius, -g.boxRadius, g.zMin, cs);
    P.gdim = {u32(nx), u32(nx), u32(nz), u32(nx * nx * nz)};
    P.box = mk4(g.boxRadius - 0.5f * reach, g.zMin + 0.5f * reach, g.zMax - 0.5f * reach, g.zFace);   // vent margin
    P.misc = mk4(g.RT, g.dpFine, 2 * 2.6f * g.dpCoarse + 2 * g.dpFine, g.RT - 3 * g.dpCoarse);
    P.cnt = {u32(g.capacity), u32(g.config.jetRefinement), 0, 0};
    P.quant = mk4(-g.boxRadius, -g.boxRadius, g.zMin, 2 * g.boxRadius);
    P.quant2 = mk4(g.zMax - g.zMin, 0.15f * g.CD, 0, 0);
    return P;
}

void initState(u32* s, size_t used) {
    for (int k = 0; k < S_COUNT; k++) s[k] = 0;
    s[S_DT] = scl_as_uint(1e-3f);
    s[S_DTMIN] = scl_as_uint(0.05f);
    s[S_USED] = u32(used);
}

}  // namespace scl
