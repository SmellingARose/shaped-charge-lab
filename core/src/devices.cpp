#include <thread>
#include "backends.hpp"
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

namespace scl {

namespace {
Device cpuDevice() {
    Device d;
    d.backend = Backend::CPU;
    d.computeUnits = int(std::max(1u, std::thread::hardware_concurrency()));
#if defined(__APPLE__)
    char brand[256] = {0};
    size_t len = sizeof(brand);
    if (sysctlbyname("machdep.cpu.brand_string", brand, &len, nullptr, 0) == 0) d.name = brand;
    int p = 0; len = sizeof(p);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &p, &len, nullptr, 0) == 0) d.performanceCores = p;
    uint64_t mem = 0; len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, nullptr, 0) == 0) d.memoryBytes = mem;
#endif
    if (d.name.empty()) d.name = "CPU";
    d.name += " (" + std::to_string(d.computeUnits) + " threads)";
    return d;
}
}  // namespace

std::vector<Device> listDevices() {
    std::vector<Device> out = gpuDevices();   // fastest first, from compiled-in backends
    out.push_back(cpuDevice());
    return out;
}

}  // namespace scl
