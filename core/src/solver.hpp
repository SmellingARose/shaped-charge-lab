// Internal solver interface implemented by each backend (CPU, Metal, HIP).
#pragma once
#include <memory>
#include <vector>
#include "geometry.hpp"

namespace scl {

struct SolverState {
    float time = 0, dt = 0;
    float linerZ = 0, penZ = 0, coreTipZ = 0;
    float tipV = 0, footprintMaxVz = 0;
    bool awake = false;
    size_t used = 0;
};

struct LinerPoint { float x, y, z, vz, mass; };

class Solver {
public:
    virtual ~Solver() = default;
    /// Advance `steps` solver steps. Returns milliseconds per step.
    virtual double step(int steps) = 0;
    virtual SolverState state() = 0;
    virtual void pack(std::vector<Particle3D>& out) = 0;
    virtual void liner(std::vector<LinerPoint>& out) = 0;
    virtual void setThreads(int) {}
    virtual Device device() const = 0;
};

/// Grid, box and quantisation parameters for a geometry (identical on every backend).
SimParams makeSimParams(const Geometry3D&);
/// Initial state words.
void initState(u32* state, size_t used);

std::unique_ptr<Solver> makeCpuSolver(const Geometry3D&, int threads);
#if defined(SCL_WITH_METAL)
std::unique_ptr<Solver> makeMetalSolver(const Geometry3D&);
std::vector<Device> metalDevices();
#endif

}  // namespace scl
