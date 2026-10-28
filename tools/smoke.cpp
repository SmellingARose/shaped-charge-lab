// Core smoke test / benchmark.
//   scl_smoke [seconds] [layers] [backend: auto|cpu|metal|hip]
// Runs the default charge, prints progress, and stops after `seconds` (0 = run to completion).
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include "scl/api.hpp"

int main(int argc, char** argv) {
    const double seconds = argc > 1 ? std::atof(argv[1]) : 20;
    scl::Config cfg;
    if (argc > 2) cfg.layers = std::atoi(argv[2]);
    scl::RunOptions opt;
    if (argc > 3) {
        std::string b = argv[3];
        opt.backend = b == "cpu" ? scl::Backend::CPU : b == "metal" ? scl::Backend::Metal : b == "hip" ? scl::Backend::HIP : scl::Backend::Auto;
    }
    for (const auto& d : scl::listDevices()) std::printf("device: %s\n", d.name.c_str());
    auto est = scl::estimateRun(cfg, scl::listDevices().front());
    std::printf("estimate: %zu particles, %.1f min\n", est.particles, est.minutes);
    auto t0 = std::chrono::steady_clock::now();
    auto run = scl::startRun(cfg, opt, nullptr, nullptr);
    std::printf("running on %s\n", run->device().name.c_str());
    double nextPrint = 0;
    while (run->running()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        auto p = run->progress();
        if (el >= nextPrint) {
            nextPrint += 2;
            std::printf("wall %5.1fs  t %6.2f us  tip %5.2f km/s travel %6.1f mm  pen %6.1f mm  %6.2f ms/step  %d particles%s\n",
                        el, p.time, p.tipSpeed, p.tipTravel, p.penetration, p.msPerStep, p.particles,
                        p.refinementExhausted ? "  [refinement exhausted]" : "");
        }
        if (seconds > 0 && el > seconds) run->cancel();
    }
    scl::JetProfile jet;
    if (run->jetProfile(jet)) std::printf("jet: tip %.2f tail %.2f km/s, %.1f%% of liner\n", jet.vTip, jet.vTail, jet.jetMassFraction * 100);
    auto p = run->progress();
    std::printf("final: t %.1f us, penetration %.1f mm (%.2f CD), %zu frames\n", p.time, p.penetration, p.penetration / cfg.chargeDiameter, run->frameCount());
}
