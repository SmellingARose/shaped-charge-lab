# Build machines and installed software

Everything installed for this project is logged here, so a machine can be rebuilt or cleaned up.

## Mac (development), Apple M4, 10 cores (4P + 6E), macOS 26.6

| Software | Version | Source | Why |
|---|---|---|---|
| Xcode Command Line Tools | Swift 6.4 / Apple clang | preinstalled | C++/Objective-C++, Metal runtime compile |
| CMake | Homebrew | preinstalled | build |
| Qt | 6.12.0 (Homebrew) | preinstalled | app |

## `eric` (Windows test machine, reached over Tailscale as `ecitt@eric`)

Hardware: Intel Core i7-14700KF (28 threads), 32 GB RAM, AMD Radeon RX 6700 XT (RDNA2, gfx1031), Windows 11 Pro.

Already present before this project: CMake (`C:\Program Files\CMake`), Git, Python 3.12, GitHub CLI,
MinGW-w64 GCC 16.2 + Ninja (WinLibs via winget), Visual Studio Build Tools 18 with MSVC 14.51 and Windows SDK 10.0.26100.

Installed for this project:

| Date | Software | Version | Source | Why |
|---|---|---|---|---|
| 2026-10-28 | AMD HIP SDK for Windows (AMD Software PRO Edition for HIP) | 26.Q3 | download.amd.com (official AMD installer; AMD licence accepted at the owner's instruction) | compile and run the HIP backend on the RX 6700 XT |

Working copies on `eric`: `C:\Users\ecitt\scl-src` (source synced from the Mac by `git archive`).

Notes:
- The RX 6700 XT (gfx1031) is listed by AMD as runtime-supported but not "HIP SDK supported". That only concerns AMD's
  prebuilt math libraries (rocBLAS etc.), which this project does not use; our kernels are compiled for gfx1031 directly.
- Intel CPUs need flush-to-zero for denormals (done in `core/src/cpu/thread_pool.hpp`); without it the CPU backend was
  4–5× slower after detonation.
