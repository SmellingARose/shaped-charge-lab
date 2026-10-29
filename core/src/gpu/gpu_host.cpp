// Loads the NVIDIA/AMD backend (scl_gpu shared library, see gpu_plugin.h) from the core's own folder and wraps it
// as a Solver. A missing library, or a GPU runtime the library cannot find, simply means no such devices.
#include "gpu_host.hpp"
#include "gpu_plugin.h"
#include "../physics/sph.h"

#include <cstdio>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace scl {

namespace {

static_assert(sizeof(LinerPoint) == 5 * sizeof(float), "liner points cross the plug-in boundary as 5 floats");
static_assert(sizeof(Particle3D) == sizeof(FrameP), "frame particles cross the plug-in boundary as FrameP");

using EntryFn = const SclGpuPlugin* (*)();

#if defined(_WIN32)
EntryFn loadEntry() {
    // The library sits next to the module that contains the core (the app or scl_smoke executable).
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&loadEntry), &self);
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n == MAX_PATH) return nullptr;
    std::wstring dir(path, n);
    dir.resize(dir.find_last_of(L"\\/") + 1);
    // Search the library's own folder for its dependencies, then the system folders (where the display driver puts
    // the HIP or CUDA runtime).
    HMODULE lib = LoadLibraryExW((dir + L"scl_gpu.dll").c_str(), nullptr,
                                 LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!lib) return nullptr;
    return reinterpret_cast<EntryFn>(reinterpret_cast<void*>(GetProcAddress(lib, "scl_gpu_plugin")));
}
#else
EntryFn loadEntry() {
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void*>(&loadEntry), &info) || !info.dli_fname) return nullptr;
    std::string dir(info.dli_fname);
    dir.resize(dir.find_last_of('/') + 1);
    void* lib = dlopen((dir + "libscl_gpu.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    return reinterpret_cast<EntryFn>(dlsym(lib, "scl_gpu_plugin"));
}
#endif

const SclGpuPlugin* plugin() {
    static const SclGpuPlugin* p = [] () -> const SclGpuPlugin* {
        EntryFn entry = loadEntry();
        const SclGpuPlugin* api = entry ? entry() : nullptr;
        if (!api) return nullptr;
        if (api->abi != SCL_GPU_PLUGIN_ABI || api->simParamsSize != sizeof(SimParams) || api->materialSize != sizeof(MatP) ||
            api->frameParticleSize != sizeof(FrameP) || api->stateWords != S_COUNT) {
            std::fprintf(stderr, "scl_gpu: built for a different core version, ignored\n");
            return nullptr;
        }
        return api;
    }();
    return p;
}

class PluginSolver final : public Solver {
public:
    PluginSolver(const SclGpuPlugin* api, void* s, size_t capacity, Device d)
        : api_(api), s_(s), capacity_(capacity), dev_(std::move(d)) {}
    ~PluginSolver() override { api_->destroy(s_); }

    double step(int steps) override { return api_->step(s_, steps); }

    SolverState state() override {
        SclGpuState g{};
        api_->state(s_, &g);
        SolverState o;
        o.time = g.time; o.dt = g.dt;
        o.linerZ = g.linerZ; o.penZ = g.penZ; o.coreTipZ = g.coreTipZ;
        o.tipV = g.tipV; o.footprintMaxVz = g.footprintMaxVz;
        o.awake = g.awake != 0;
        o.used = size_t(g.used);
        return o;
    }

    void pack(std::vector<Particle3D>& out) override {
        out.resize(capacity_);
        api_->pack(s_, out.data());
    }

    void liner(std::vector<LinerPoint>& out) override {
        out.resize(capacity_);
        out.resize(api_->liner(s_, reinterpret_cast<float*>(out.data())));
    }

    Device device() const override { return dev_; }

private:
    const SclGpuPlugin* api_;
    void* s_;
    size_t capacity_;
    Device dev_;
};

Device toDevice(const SclGpuDevice& g) {
    Device d;
    d.backend = Backend::HIP;
    d.name = g.name;
    d.computeUnits = g.computeUnits;
    d.memoryBytes = g.memoryBytes;
    return d;
}

}  // namespace

std::vector<Device> gpuPluginDevices() {
    std::vector<Device> out;
    const SclGpuPlugin* api = plugin();
    if (!api) return out;
    for (int k = 0, n = api->deviceCount(); k < n; k++) {
        SclGpuDevice g{};
        if (api->device(k, &g) == 0) out.push_back(toDevice(g));
    }
    return out;
}

std::unique_ptr<Solver> makeGpuPluginSolver(const Geometry3D& g, int deviceIndex) {
    const SclGpuPlugin* api = plugin();
    if (!api) return nullptr;
    SclGpuDevice info{};
    if (api->device(deviceIndex, &info) != 0) return nullptr;
    SimParams P = makeSimParams(g);
    u32 state[S_COUNT];
    initState(state, g.used);
    SclGpuInit init{};
    init.params = &P;
    init.materials = g.materials.data();
    init.state = state;
    init.capacity = g.capacity;
    init.used = g.used;
    init.pos = g.pos.data()->data();
    init.vel = g.vel.data()->data();
    init.detonationTime = g.detonationTime.data();
    init.flags = g.flags.data();
    void* s = api->create(&init, deviceIndex);
    if (!s) return nullptr;
    return std::make_unique<PluginSolver>(api, s, g.capacity, toDevice(info));
}

}  // namespace scl
