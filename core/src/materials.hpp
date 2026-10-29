// Material models (internal to the core). Units: mm, µs, mg → km/s, g/cm³, GPa, MJ/kg.
#pragma once
#include <cmath>
#include "scl/api.hpp"

namespace scl {

enum class MaterialKind : uint32_t { Explosive = 0, Solid = 1 };

/// Layout is shared with the GPU kernels (20 × 4 bytes). Do not reorder.
struct MaterialParams {
    float rho0, c0, s, grun, G, yA, yB, yN, yMax, cv, meltE, spall, failStrain, detVel, gammaGas, e0;
    uint32_t kind;
    float tbSigma0, tbK, bernoulliR;
};
static_assert(sizeof(MaterialParams) == 80, "MaterialParams is shared with GPU code");

/// Tuler–Butcher spall: σ0 = ⅔·spall, K = (spall/3)²·1 µs, so a 1 µs pulse fails at the spall strength.
inline MaterialParams withTulerButcher(MaterialParams m) {
    m.tbSigma0 = m.spall * 2.0f / 3.0f;
    m.tbK = (m.spall / 3.0f) * (m.spall / 3.0f);
    return m;
}

/// Generic explosive: γ-law products with energy consistent with a CJ state, Q = D²/(2(γ²−1)).
inline MaterialParams explosive(float D) {
    const float g = 3.0f;
    MaterialParams m{1.70f, 2.5f, 0, 0, 0, 0, 0, 1, 0, 1e-3f, 1, 0, 0, D, g, D * D / (2 * (g * g - 1)),
                     uint32_t(MaterialKind::Explosive), 0, 0, 0};
    return m;
}

inline MaterialParams linerMaterial(LinerMaterial l, float breakupStretch) {
    MaterialParams m{};
    switch (l) {
    case LinerMaterial::Copper:
        m = {8.93f, 3.94f, 1.49f, 2.0f, 46, 0.09f, 0.29f, 0.31f, 0.6f, 0.383e-3f, 0.40f, 1.5f, 0, 0, 0, 0, 1, 0, 0, 0};
        break;
    case LinerMaterial::Tantalum:
        m = {16.65f, 3.41f, 1.20f, 1.67f, 69, 0.35f, 0.30f, 0.28f, 1.0f, 0.14e-3f, 0.42f, 3.0f, 0, 0, 0, 0, 1, 0, 0, 0};
        break;
    case LinerMaterial::Aluminum:
        m = {2.70f, 5.35f, 1.34f, 2.0f, 26, 0.32f, 0.11f, 0.42f, 0.5f, 0.89e-3f, 0.56f, 1.2f, 0, 0, 0, 0, 1, 0, 0, 0};
        break;
    }
    m.failStrain = std::log(std::fmax(breakupStretch, 1.05f));
    return withTulerButcher(m);
}

inline MaterialParams targetMaterial(TargetMaterial t) {
    MaterialParams m{};
    switch (t) {
    case TargetMaterial::ArmorSteel:
        m = {7.85f, 4.57f, 1.49f, 1.93f, 81.8f, 0.79f, 0.51f, 0.26f, 1.8f, 0.477e-3f, 0.71f, 3.0f, 1.0f, 0, 0, 0, 1, 0, 0, 6.0f};
        break;
    case TargetMaterial::Aluminum6061:
        m = {2.70f, 5.35f, 1.34f, 2.0f, 26, 0.32f, 0.11f, 0.42f, 0.5f, 0.89e-3f, 0.56f, 1.2f, 1.0f, 0, 0, 0, 1, 0, 0, 2.0f};
        break;
    }
    return withTulerButcher(m);
}

}  // namespace scl
