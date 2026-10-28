// Smoke test for the core API: lists devices, ranges, and runs a short job.
#include <cstdio>
#include <thread>
#include "scl/api.hpp"

int main() {
    for (const auto& d : scl::listDevices()) std::printf("device: %s\n", d.name.c_str());
    std::printf("%zu parameter ranges\n", scl::parameterRanges().size());
    scl::Config cfg;
    auto est = scl::estimateRun(cfg, scl::listDevices().front());
    std::printf("estimate: %zu particles, %.1f min\n", est.particles, est.minutes);
    auto run = scl::startRun(cfg, {}, nullptr, [](float p, bool ok) { std::printf("done: %.1f mm (%s)\n", p, ok ? "completed" : "cancelled"); });
    while (run->running()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    scl::Frame f;
    run->frame(run->frameCount() - 1, f);
    std::printf("%zu frames, %zu particles in last frame\n", run->frameCount(), f.particles.size());
}
