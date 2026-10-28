#include "scl/api.hpp"

namespace scl {

// "Realistic" bands describe real hardware and practice, not the simulator's default.
// Detonation velocities: TNT ≈ 6.9, Comp B ≈ 7.9, Octol ≈ 8.5, LX-14 ≈ 8.8 km/s (Dobratz & Crawford,
// LLNL Explosives Handbook). Liner geometry and standoff: Walters & Zukas, "Fundamentals of Shaped Charges".
// Resolution and refinement bands come from this project's own convergence study (ARCHITECTURE.md).
const std::vector<ParameterRange>& parameterRanges() {
    static const std::vector<ParameterRange> ranges = {
        {"detonationVelocity", 5.5f, 9.5f, 7.5f, 8.8f, 8.0f,
         "Military high explosives detonate at 7.5–8.8 km/s (Comp B ≈ 7.9, Octol ≈ 8.5)."},
        {"coneAngleDeg", 30, 120, 40, 60, 42,
         "Precision anti-armor liners are 40–60°; 42° is a classic choice."},
        {"linerThicknessFrac", 0.015f, 0.05f, 0.02f, 0.03f, 0.025f,
         "Copper liners are typically 2–3% of the charge diameter."},
        {"headHeightCD", 0.3f, 1.0f, 0.4f, 0.7f, 0.5f,
         "Explosive behind the apex; more adds little once the wave has flattened."},
        {"standoffCD", 0.25f, 10, 2, 8, 3,
         "Fielded warheads sit at 2–4 CD for packaging; laboratory charges peak around 3–8 CD."},
        {"approachSpeed", 0, 1000, 0, 300, 150,
         "Rockets and missiles hit at 100–300 m/s; gun-fired HEAT rounds near 1000 m/s."},
        {"targetThicknessCD", 2, 10, 6, 10, 7,
         "Thick enough that the jet stops inside it, so the depth is not cut short."},
        {"breakupStretch", 2, 12, 5, 10, 6,
         "Copper jets elongate about 5–10× before particulating."},
        {"layers", 2, 4, 3, 4, 3,
         "Particles across the liner wall. Penetration stops changing from about 3 across."},
        {"jetRefinement", 0, 5, 3, 5, 3,
         "Split levels for stretched jet material. 3 or more resolves the thinning jet."},
        {"initiationOffsetMM", 0, 4, 0, 0.3f, 0.1f,
         "Precision charges hold the detonator within a few tenths of a millimetre of the axis."},
        {"wallVariation", 0, 0.1f, 0, 0.02f, 0.01f,
         "Machined liners vary by about 1–2% in wall thickness around the circumference."},
        {"driftSpeed", 0, 60, 10, 30, 20,
         "Sideways speed of broken jet beads, in m/s (used by the 1D model only)."},
    };
    return ranges;
}

}  // namespace scl
