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

Done on this machine so far (2026-10-28):

| Action | Details | Status |
|---|---|---|
| Downloaded AMD HIP SDK 26.Q3 (ROCm 7.2) installer | `Downloads\AMD-Software-PRO-Edition-26.Q3-Win11-For-HIP.exe`, 1.67 GB, Authenticode-signed by Advanced Micro Devices; AMD licence accepted at the owner's instruction | kept for the proper install |
| Downloaded AMD HIP SDK 25.Q3 (ROCm 6.4) installer | `Downloads\AMD-Software-PRO-Edition-25.Q3-Win10-Win11-For-HIP.exe` | can be deleted |
| Extracted (not installed) SDK core 7.2 and 6.4 | `%USERPROFILE%\rocm`, `%USERPROFILE%\rocm64`, `Downloads\hipsdk*` via `msiexec /a`; nothing registered system-wide | temporary, to delete after the proper install |
| Source copy | `%USERPROFILE%\scl-src` (synced from the Mac by `git archive`) | working copy |

Findings:
- The installed Adrenalin driver (32.0.21045) ships the HIP 6 runtime (`amdhip64_6.dll`) and sees the RX 6700 XT from SSH.
  The HIP SDK 7.2 runtime (`amdhip64_7.dll`) reports no device with this driver: it needs a newer driver.
- HIP SDK 7.2's clang does not compile against MSVC 14.51 (VS 18) headers (`isgreater` and friends clash);
  AMD supports the VS 2022 toolset (MSVC v143).
- The SSH account is not elevated, so installers that need admin must be run from an elevated prompt on the machine.

Proper setup (needs one elevated PowerShell on `eric`):
1. Update the AMD Adrenalin driver to the release paired with HIP SDK 7.2 (it provides the HIP 7 runtime).
2. Install HIP SDK 7.2 with its installer, deselecting the bundled PRO display driver (GUI) so the gaming driver stays.
3. Install Visual Studio 2022 Build Tools with the C++ workload (MSVC v143) next to the existing VS 18 Build Tools.
4. Delete the temporary extracts above.

Installed for this project:

| Date | Software | Version | Source | Why |
|---|---|---|---|---|
| — | nothing installed system-wide yet | | | |

Working copies on `eric`: `C:\Users\ecitt\scl-src` (source synced from the Mac by `git archive`).

Notes:
- The RX 6700 XT (gfx1031) is listed by AMD as runtime-supported but not "HIP SDK supported". That only concerns AMD's
  prebuilt math libraries (rocBLAS etc.), which this project does not use; our kernels are compiled for gfx1031 directly.
- Intel CPUs need flush-to-zero for denormals (done in `core/src/cpu/thread_pool.hpp`); without it the CPU backend was
  4–5× slower after detonation.
