// NVIDIA/AMD backend, loaded at runtime from the scl_gpu shared library (internal).
#pragma once
#include <memory>
#include <vector>
#include "../solver.hpp"

namespace scl {

/// GPUs the scl_gpu library reports; empty when the library or a GPU runtime is missing.
std::vector<Device> gpuPluginDevices();
/// Solver on the given device (index into gpuPluginDevices()); null if it cannot start.
std::unique_ptr<Solver> makeGpuPluginSolver(const Geometry3D&, int deviceIndex);

}  // namespace scl
