// 1D modified-Bernoulli penetration of a measured jet (DPE model).
#include <cmath>
#include "materials.hpp"
#include "scl/api.hpp"

namespace scl {

namespace {
float penetrationVelocity(float v, float rj, float rt, float Rt) {
    if (rj * v * v <= 2 * Rt) return 0;
    const float a = rj - rt;
    if (std::fabs(a) < 1e-3f) return (rj * v * v - 2 * Rt) / (2 * rj * v);
    const float disc = rj * rj * v * v - a * (rj * v * v - 2 * Rt);
    return std::fmax((rj * v - std::sqrt(disc)) / a, 0.0f);
}
}  // namespace

std::vector<CurvePoint> penetrationCurve(const JetProfile& jet, const Config& cfg, float drift, float maxCD, float stepCD) {
    const MaterialParams t = targetMaterial(cfg.target);
    const float tb = jet.tVirtualOrigin + cfg.breakupStretch * (jet.tMeasured - jet.tVirtualOrigin);
    const float holeR = 0.13f * jet.chargeDiameter;
    std::vector<CurvePoint> out;
    for (float sCD = 0.25f; sCD <= maxCD + 1e-4f; sCD += stepCD) {
        const float zf = jet.chargeLength + sCD * jet.chargeDiameter;
        float zc = zf, tcur = 0;
        const float dv = 0.02f;
        for (float v = jet.vTip; v - dv >= jet.vTail; v -= dv) {
            const float vm = v - 0.5f * dv;
            const float tArr = std::fmax(tcur, jet.tVirtualOrigin + (zc - jet.zVirtualOrigin) / v);
            float len = dv * std::fmax(std::fmin(tArr, tb) - jet.tVirtualOrigin, 0.0f);
            if (tArr > tb) {
                const float lateral = drift * (tArr - tb);
                len *= std::exp(-(lateral / holeR) * (lateral / holeR));
            }
            const float u = penetrationVelocity(vm, jet.rhoJet, t.rho0, t.bernoulliR);
            if (u > 0 && len > 0) {
                const float tau = len / (vm - u);
                zc += u * tau;
                tcur = tArr + tau;
            } else {
                tcur = tArr;
            }
        }
        out.push_back({sCD, (zc - zf) / jet.chargeDiameter});
    }
    return out;
}

}  // namespace scl
