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

CurvePoint bestStandoff(const std::vector<CurvePoint>& c) {
    if (c.empty()) return {-1, -1};
    size_t k = 0;
    for (size_t i = 1; i < c.size(); i++) if (c[i].penetrationCD > c[k].penetrationCD) k = i;
    if (k == 0 || k + 1 == c.size()) return c[k];
    const float y0 = c[k - 1].penetrationCD, y1 = c[k].penetrationCD, y2 = c[k + 1].penetrationCD;
    const float den = y0 - 2 * y1 + y2;
    if (den >= 0) return c[k];
    const float off = 0.5f * (y0 - y2) / den;   // in samples, within ±0.5
    const float h = c[k + 1].standoffCD - c[k].standoffCD;
    return {c[k].standoffCD + off * h, y1 - 0.25f * (y0 - y2) * off};
}

JetProfile atApproachSpeed(const JetProfile& jet, float measuredAtMS, float approachMS) {
    const float dv = (approachMS - measuredAtMS) / 1000;   // km/s = mm/µs
    JetProfile j = jet;
    j.vTip += dv;
    j.vTail += dv;
    j.zVirtualOrigin += dv * jet.tVirtualOrigin;
    return j;
}

std::vector<OptimumPoint> optimumVsApproach(const JetProfile& jet, const Config& cfg, float drift, float measuredAtMS,
                                            float maxMS, float stepMS) {
    std::vector<OptimumPoint> out;
    for (float v = 0; v <= maxMS + 1e-3f; v += stepMS) {
        const CurvePoint b = bestStandoff(penetrationCurve(atApproachSpeed(jet, measuredAtMS, v), cfg, drift, 10, 0.1f));
        out.push_back({v, b.standoffCD, b.penetrationCD});
    }
    return out;
}

}  // namespace scl
