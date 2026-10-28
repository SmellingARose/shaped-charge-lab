// Initial particle set for a full 3D run, shared by every backend.
#pragma once
#include <array>
#include <vector>
#include "materials.hpp"
#include "physics/sph.h"   // flag bits shared with the kernels
#include "scl/api.hpp"

namespace scl {

struct Geometry3D {
    Config config;
    // charge and target
    float CD, R, L, zApex, zFace, zBack, RT, alpha;
    float dpFine, dpCoarse;
    // simulation box (particles leaving it are vented)
    float boxRadius, zMin, zMax;
    std::array<MaterialParams, 3> materials;   // 0 explosive, 1 liner, 2 target

    // initial particles (`used` real ones followed by `spare` empty slots for refinement)
    size_t used = 0, capacity = 0;
    std::vector<std::array<float, 4>> pos;     // x, y, z, smoothing length h
    std::vector<std::array<float, 4>> vel;     // vx, vy, vz, mass
    std::vector<float> detonationTime;         // explosive only
    std::vector<uint32_t> flags;               // material | F_*

    SceneInfo scene() const;
};

Geometry3D buildGeometry(const Config&);

/// Particle count before building (for estimates).
size_t estimateParticles(const Config&);

}  // namespace scl
