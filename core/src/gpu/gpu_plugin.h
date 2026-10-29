// C ABI between the core and the NVIDIA/AMD backend, which is built as its own shared library (scl_gpu.dll,
// libscl_gpu.so) by the GPU toolchain (ROCm clang or nvcc). The core loads it at startup from its own folder when
// it is there: the app starts without any GPU runtime installed, and the core keeps the platform's usual compiler.
// Only plain C types cross the boundary; the host checks the shared struct sizes before using the backend.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define SCL_GPU_PLUGIN_ABI 1

#if defined(_WIN32)
#define SCL_GPU_EXPORT extern "C" __declspec(dllexport)
#else
#define SCL_GPU_EXPORT extern "C" __attribute__((visibility("default")))
#endif

struct SclGpuDevice {
    char name[256];
    int32_t computeUnits;
    uint64_t memoryBytes;
};

/// Initial particles and parameters, as the host built them.
struct SclGpuInit {
    const void* params;            // SimParams
    const void* materials;         // MatP[3]
    const uint32_t* state;         // S_COUNT initial state words
    size_t capacity, used;
    const float* pos;              // capacity × (x, y, z, h)
    const float* vel;              // capacity × (vx, vy, vz, mass)
    const float* detonationTime;   // capacity
    const uint32_t* flags;         // capacity
};

struct SclGpuState {
    float time, dt, linerZ, penZ, coreTipZ, tipV, footprintMaxVz;
    uint32_t awake;
    uint64_t used;
};

struct SclGpuPlugin {
    uint32_t abi;
    uint32_t simParamsSize, materialSize, frameParticleSize, stateWords;   // must match the host
    const char* toolchain;                                                  // "HIP" or "CUDA"
    int (*deviceCount)(void);
    int (*device)(int index, SclGpuDevice* out);                            // 0 on success
    void* (*create)(const SclGpuInit* init, int deviceIndex);               // null on failure (reason on stderr)
    void (*destroy)(void* solver);
    double (*step)(void* solver, int steps);                                // milliseconds per step
    void (*state)(void* solver, SclGpuState* out);
    void (*pack)(void* solver, void* out);                                  // capacity frame particles
    size_t (*liner)(void* solver, float* out);                              // ≤ capacity × (x, y, z, vz, mass); count
};

/// Entry point the host looks up.
SCL_GPU_EXPORT const SclGpuPlugin* scl_gpu_plugin(void);
