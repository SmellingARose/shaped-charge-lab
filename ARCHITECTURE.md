# Shaped Charge Lab — architecture

A native app for macOS, Windows and Linux that simulates shaped-charge jet formation and penetration
(SPH hydrocode) and renders it in 3D. One UI codebase, one physics codebase, native GPU speed on every platform.

## Layout

```
core/                     simulation library (C++20), no UI
  include/scl/api.hpp     THE contract between core and app — change both sides together
  src/physics/*.h         physics written once as plain functions + kernel bodies (see "One kernel source")
  src/cpu/                CPU backend: std::thread pool + auto-vectorised loops (any x86/ARM CPU)
  src/metal/              Metal backend (macOS): kernels compiled from the shared physics headers
  src/hip/                HIP backend: same kernels → CUDA (NVIDIA) or ROCm/HIP SDK (AMD)
  src/ranges.cpp          parameter ranges + "realistic" bands with sources
app/                      Qt 6 Quick (QML) app — the only UI, on all three OSes
  qml/                    screens and controls
  render/                 3D view: QQuickRhiItem + QRhi (Metal / D3D12 / Vulkan)
ShapedChargeLab/          legacy SwiftUI prototype (reference only; delete once the Qt app reaches parity)
```

Build: CMake ≥ 3.25. `SCL_WITH_METAL` (default on Apple), CPU always. `SCL_GPU` (AUTO/HIP/CUDA/OFF) builds the
NVIDIA/AMD backend as its own shared library, `scl_gpu` (C ABI in `core/src/gpu/gpu_plugin.h`), which the core loads
at runtime from its executable's folder: the app needs no GPU runtime to start, and on Windows the backend can be built
by the HIP SDK's clang while the app and core use MSVC.

## Platform matrix

| Platform | UI / rendering | Compute backends |
|---|---|---|
| macOS (Apple Silicon) | Qt Quick on Metal | Metal, CPU |
| Windows | Qt Quick on D3D12 | HIP (NVIDIA via CUDA, AMD via HIP SDK), CPU |
| Linux | Qt Quick on Vulkan | HIP (NVIDIA via CUDA, AMD via ROCm), CPU |

`listDevices()` reports what is usable; `Backend::Auto` picks the fastest.

## One kernel source

Physics lives in `core/src/physics/` as headers of `SCL_FN` functions over plain structs
(`eos`, `kernelW`, `rates`, `forces`, `integrate`, `split`, …). Each backend includes them:

- **Metal**: the headers are concatenated into MSL source at build time (MSL is C++14-based);
  `SCL_FN` → `inline`, `SCL_DEVICE` → `device`.
- **HIP**: `SCL_FN` → `__device__ __forceinline__`; kernels launched with HIP. The same `.hip` files build with
  `hipcc` for AMD and with `hipcc --platform nvidia` / `nvcc -x cu` for NVIDIA.
- **CPU**: `SCL_FN` → `inline`; loops over particles parallelised on a thread pool, laid out SoA so they vectorise.

So the three backends cannot drift apart: a physics fix is one edit.

## Physics model

- SPH, cubic-spline kernel, Monaghan artificial viscosity, Monaghan artificial stress against tensile instability.
- Metals: Mie–Grüneisen EOS, J2 plasticity with Johnson–Cook-style hardening and thermal softening.
- Failure: Tuler–Butcher cumulative spall damage; ductile failure on tensile plastic strain (jet breakup stretch).
- Explosive: γ-law products, programmed burn from the detonator.
- Refinement: per-particle deformation gradient F (dF/dt = L·F); split at principal stretch 2 along that direction,
  mass- and momentum-conserving, F halved along the split.
- Full 3D only (no symmetry): uniform grid, counting sort, particle data reordered into cell order every step.
  Liner at fine spacing, explosive and target at 2× spacing.
- Runs record frames as they go: the app watches the newest frame live and can scrub/play back at any time.
- Run ends when no liner material over the target exceeds the cutoff speed √(2R_target/ρ_jet).

## Work split

1. **Core** (simulation agent): port the Swift/MSL prototype into `core/` behind `api.hpp`; CPU first, then Metal,
   then HIP. Ships a stub (`core/src/stub.cpp`, generated geometry, no physics) immediately and the CPU
   backend early so the app can run against real data.
2. **App** (UI agent): Qt 6 Quick app in `app/` against `api.hpp` only. Must not include anything from `core/src`.

## Validation targets

- Default charge (40 mm, 60° copper cone, 2.5% wall, 8 km/s explosive, 3 CD standoff into armor steel):
  jet tip ≈ 6–7 km/s, jet ≈ 13–14% of liner mass, crater ≈ 2 CD (the 2D prototype's 3–4-across result).
- Resolution study: results must change by < 5% between the two finest resolutions offered before a value is
  marked "realistic"/converged in the UI.
