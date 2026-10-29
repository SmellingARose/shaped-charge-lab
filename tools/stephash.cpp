// Determinism check for solver changes that must not alter results.
//   scl_stephash [steps] [layers] [cpu|metal|hip] [split-free]
// Runs the default charge for a fixed number of steps (CPU: one thread, so bit-reproducible), then prints the solver
// state and an FNV-1a hash of every packed particle. Same hash before and after a change = identical physics.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include "geometry.hpp"
#include "solver.hpp"
#if !defined(__APPLE__)
#include "gpu/gpu_host.hpp"
#endif

int main(int argc, char** argv) {
    const int steps = argc > 1 ? std::atoi(argv[1]) : 400;
    scl::Config cfg;
    cfg.layers = argc > 2 ? std::atoi(argv[2]) : 1;
    const std::string backend = argc > 3 ? argv[3] : "cpu";
    if (argc > 4) cfg.jetRefinement = 0;   // no splitting: the only step whose order depends on thread timing
    scl::Geometry3D g = scl::buildGeometry(cfg);
    std::unique_ptr<scl::Solver> s;
#if defined(SCL_WITH_METAL)
    if (backend == "metal") s = scl::makeMetalSolver(g);
#endif
#if !defined(__APPLE__)
    if (backend == "hip") s = scl::makeGpuPluginSolver(g, 0);
#endif
    if (!s) s = scl::makeCpuSolver(g, 1);
    const SimParams P = scl::makeSimParams(g);
    std::printf("%s, %zu particles, %d steps, grid %u×%u×%u cells of %.3f mm\n", s->device().name.c_str(), g.used, steps,
                P.gdim.x, P.gdim.y, P.gdim.z, P.gmin.w);
    double ms = 0;
    for (int k = 0; k < steps; k += 10) ms += s->step(10) * 10;
    scl::SolverState st = s->state();
    std::vector<scl::Particle3D> p;
    s->pack(p);
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : std::string(reinterpret_cast<const char*>(p.data()), p.size() * sizeof(scl::Particle3D)))
        h = (h ^ c) * 1099511628211ull;
    std::printf("t %.6f us  dt %.8f  tipV %.6f  linerZ %.6f  used %zu\n", st.time, st.dt, st.tipV, st.linerZ, st.used);
    std::printf("hash %016llx  (%.2f ms/step)\n", static_cast<unsigned long long>(h), ms / steps);
}
