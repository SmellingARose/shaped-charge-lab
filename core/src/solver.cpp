#include "solver.hpp"
#include <cmath>

namespace scl {

SimParams makeSimParams(const Geometry3D& g) {
    float cs = 2 * 1.3f * g.dpCoarse;
    int nx = 0, nz = 0;
    for (;;) {
        nx = int(2 * g.boxRadius / cs) + 1;
        nz = int((g.zMax - g.zMin) / cs) + 1;
        if (size_t(nx) * nx * nz + 1 <= size_t(1024) * 1024) break;   // GPU scan handles up to 1024² cells
        cs *= 1.08f;
    }
    SimParams P{};
    P.gmin = mk4(-g.boxRadius, -g.boxRadius, g.zMin, cs);
    P.gdim = {u32(nx), u32(nx), u32(nz), u32(nx * nx * nz)};
    P.box = mk4(g.boxRadius - 0.5f * cs, g.zMin + 0.5f * cs, g.zMax - 0.5f * cs, g.zFace);
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
