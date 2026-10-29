<div align="center">

<h1>Shaped Charge Lab</h1>

<p><b>Watch an explosive turn a copper cone into a hypersonic jet, in full 3D, and find the standoff that drills deepest.</b></p>

<a href="https://github.com/SmellingARose/shaped-charge-lab/releases/latest/download/ShapedChargeLab-macOS.dmg"><img src="docs/download/macos.svg" alt="Download for macOS" height="56"></a>&nbsp;&nbsp;<a href="https://github.com/SmellingARose/shaped-charge-lab/releases/latest/download/ShapedChargeLab-Windows.msi"><img src="docs/download/windows.svg" alt="Download for Windows" height="56"></a>

<sub>One download, nothing else to install · <a href="https://github.com/SmellingARose/shaped-charge-lab/releases">All releases</a></sub>

<br>

<img src="docs/screens/app.jpg" alt="Shaped Charge Lab: a jet forming and stretching toward the target" width="100%">

</div>

<details>
<summary><b>First launch shows a warning?</b> That is expected; here is the one-time fix.</summary>
<br>

The app is not signed by a paid developer account, so the first time:

- **Mac:** open the .dmg, drag **Shaped Charge Lab** to Applications and open it. When macOS says it cannot check the
  app, open **System Settings → Privacy & Security**, scroll down, press **Open Anyway** and confirm. After that it
  opens normally. Intel Macs are not supported.
- **Windows:** run the .msi. If SmartScreen says "Windows protected your PC", press **More info**, then **Run anyway**.
  Shaped Charge Lab is then in the Start menu.

</details>

## About

A native, GPU-accelerated 3D simulation of shaped-charge jets, for understanding how they form and why there is an
optimal standoff distance between the charge and its target. An explosive drives a conical metal liner inward; it
collapses on the axis into a fast, stretching jet and a slow slug; the jet stretches, breaks into particles and
penetrates the target. Every stage is computed by a full 3D SPH hydrocode (no symmetry assumed).

> Status: early release. The simulation runs on Apple Metal, CPUs (any Mac or PC) and AMD Radeon GPUs (HIP; the
> Windows download includes it and picks the GPU automatically). NVIDIA (CUDA) is written but untested.
> Penetration depth is not yet converged with resolution; see [docs/convergence.md](docs/convergence.md).

## The app

- Live 3D view of the full simulation: a cutaway that always faces you, glowing explosive gas, metal shading, and a
  ground grid in charge diameters with the standoff gap highlighted. Colour by material, speed, pressure,
  temperature or plastic strain.
- Every run records as it goes: scrub or play back any moment while it is still running.
- Every parameter shows its realistic band and value from real hardware; click the tick to snap to it.
- An explainer says what is happening in each phase, next to the jet's velocity profile and the penetration-versus-
  standoff curve computed from the jet the charge actually formed.
- Pick the GPU or the CPU (and its thread count) to run on.

## Physics

- Smoothed-particle hydrodynamics, cubic-spline kernel, Monaghan artificial viscosity and artificial stress.
- Metals (copper, tantalum, aluminum liners; armor steel and aluminum targets): Mie–Grüneisen equation of state,
  J2 plasticity with Johnson–Cook-style hardening and thermal softening.
- Failure: Tuler–Butcher cumulative spall damage, ductile failure on tensile plastic strain (jet breakup).
- Explosive: generic γ-law products with programmed burn, set by detonation velocity.
- Adaptive refinement: each liner particle tracks its deformation gradient and splits along its principal stretch
  when the material it represents has stretched to twice its length (mass and momentum conserved).
- A 1D modified-Bernoulli model applied to the measured jet gives penetration versus standoff.

Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Backends

The physics is written once (`core/src/physics/sph.h`) and compiled for every backend:

| Backend | Hardware | Status |
|---|---|---|
| CPU | any x86-64 / ARM64, multithreaded | working (macOS, Windows) |
| Metal | Apple Silicon | working |
| HIP | AMD Radeon RX 6000 / 7000 / 9000 (ROCm on Linux, HIP SDK on Windows) | working (RX 6700 XT, ~2.9× an M4 GPU); in the Windows download |
| CUDA | NVIDIA | written, untested |

## Build

Requires CMake ≥ 3.25, a C++20 compiler and Qt ≥ 6.8 (Quick, QuickControls2, ShaderTools).

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
open "build/app/Shaped Charge Lab.app"   # macOS; on Windows/Linux run build/app/Shaped Charge Lab
./build/core/scl_smoke 20               # 20-second benchmark run, no UI
```

The app takes `--run` (start immediately), `--quit-after <s>` and `--screenshot <file>` for automated smoke tests.

- **macOS**: Xcode command line tools. The Metal backend is built automatically.
- **Windows**: Visual Studio 2022 C++ tools. The NVIDIA/AMD backend is a separate library, `scl_gpu.dll`, that the
  app loads at startup when it sits next to the exe: build it with `tools\windows\build-hip.bat` (AMD HIP SDK 6.4),
  then the app with `tools\windows\build-app.bat`, which deploys both. See [docs/environment.md](docs/environment.md).
- **Linux**: GCC or Clang. Install ROCm (AMD) or the CUDA toolkit (NVIDIA) for the GPU backend.

`scl_smoke [seconds] [layers] [auto|cpu|metal|hip] [cpu threads]` runs the default charge and prints progress.
Set `SCL_PROFILE=1` for per-phase CPU timings.

## Layout

- `core/`: simulation library behind `core/include/scl/api.hpp`
- `app/`: Qt 6 Quick app (QML UI, QRhi renderer: Metal / Direct3D / Vulkan from one code path)
- `ShapedChargeLab/`: original SwiftUI/Metal prototype (reference)
- `docs/`: convergence study and build-machine setup

## License

MIT, see [LICENSE](LICENSE).
