// Backend registry (internal). Each compiled-in GPU backend contributes devices and a run factory.
#pragma once
#include <vector>
#include "scl/api.hpp"

namespace scl {
std::vector<Device> gpuDevices();
}
