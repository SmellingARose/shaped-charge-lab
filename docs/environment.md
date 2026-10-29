# Build machines and installed software

Everything installed for this project is logged here, so a machine can be rebuilt or cleaned up.

## Mac (development), Apple M4, 10 cores (4P + 6E), macOS 26.6

| Software | Version | Source | Why |
|---|---|---|---|
| Xcode Command Line Tools | Swift 6.4 / Apple clang | preinstalled | C++/Objective-C++, Metal runtime compile |
| CMake | Homebrew | preinstalled | build |
| Qt | 6.12.0 (Homebrew) | preinstalled | app (day-to-day builds; not for packaging, its plug-ins link Homebrew) |
| aqtinstall (Python venv) | 3.3.0 | PyPI, `~/Qt-official/venv` (installed 2026-10-28) | installs the official Qt CI uses |
| Qt (official binaries) | 6.10.3, `qtbase` + `qtdeclarative` + `qtshadertools`, debug symbols deleted (1.2 GB) | `aqt install-qt mac desktop 6.10.3 clang_64 --archives qtbase qtdeclarative -m qtshadertools -O ~/Qt-official` (2026-10-28) | local check of the CI packaging (`.dmg`) |

## `eric` (Windows test machine, reached over Tailscale as `ecitt@eric`)

Hardware: Intel Core i7-14700KF (28 threads), 32 GB RAM, AMD Radeon RX 6700 XT (RDNA2, gfx1031), Windows 11 Pro.

Already present before this project: CMake (`C:\Program Files\CMake`), Git, Python 3.12, GitHub CLI,
MinGW-w64 GCC 16.2 + Ninja (WinLibs via winget), Visual Studio Build Tools 18 with MSVC 14.51 and Windows SDK 10.0.26100,
and Visual Studio 2022 Build Tools (17.14) without the C++ compiler.

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

Proper setup (one elevated PowerShell on `eric`). The first command adds only the MSVC v143 compiler and libraries to the
existing VS 2022 Build Tools (the newest toolset HIP's clang supports). The second keeps the gaming driver, whose HIP 6
runtime matches HIP SDK 6.4:

```powershell
Start-Process "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" -Wait -ArgumentList 'modify', '--installPath', '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '--quiet', '--norestart'
Start-Process msiexec -Wait -ArgumentList '/i', "$env:USERPROFILE\Downloads\hipsdk64\Packages\Apps\ROCmSDKPackages\SDKCore\ROCm_SDK_Core.msi", '/qn', '/L*v', "$env:USERPROFILE\hip-sdk-install.log"
Remove-Item -Recurse -Force "$env:USERPROFILE\rocm", "$env:USERPROFILE\rocm64", "$env:USERPROFILE\Downloads\hipsdk", "$env:USERPROFILE\Downloads\AMD-Software-PRO-Edition-26.Q3-Win11-For-HIP.exe"
```

(HIP SDK 7.2 would instead need AMD's PRO display driver, which replaces the Adrenalin gaming driver.)

Installed for this project:

| Date | Software | Version | Source | Why |
|---|---|---|---|---|
| 2026-10-28 | Visual Studio 2022 Build Tools: C++ workload (`Microsoft.VisualStudio.Workload.VCTools`, recommended components), MSVC 14.44 (v143) | 17.14 | winget (`Microsoft.VisualStudio.2022.BuildTools`, modify of the existing install) | host toolchain supported by the HIP SDK |
| 2026-10-28 | AMD HIP SDK core (ROCm 6.4, from AMD's 25.Q3 package, `ROCm_SDK_Core.msi` only; display driver untouched) | 6.4 | download.amd.com | HIP backend; runtime comes from the Adrenalin driver (`amdhip64_6.dll`) |
| 2026-10-28 | Removed the temporary 7.2/6.4 extracts and the 26.Q3 installer | | | cleanup |
| 2026-10-28 | aqtinstall | 3.3.0 | `pip install --user aqtinstall` | installs the official Qt CI uses |
| 2026-10-28 | Qt (official binaries, MSVC 2022 x64) + Qt Shader Tools | 6.10.3 | `python -m aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -m qtshadertools -O %USERPROFILE%\Qt` | app build and `.msi` packaging |
| 2026-10-28 | .NET SDK (per user, `%LOCALAPPDATA%\Microsoft\dotnet`) | 8.0.427 | `dotnet-install.ps1 -Channel 8.0` | runs the WiX tool |
| 2026-10-28 | WiX Toolset (dotnet global tool, `%USERPROFILE%\.dotnet\tools`) | 5.0.2 | `dotnet tool install --global wix --version 5.0.2` | builds the `.msi`; needs `DOTNET_ROOT=%LOCALAPPDATA%\Microsoft\dotnet` |

Result: `tools\windows\build-hip.bat` builds `build-hip\core\scl_gpu.dll` (RDNA2–4 targets); the HIP backend runs on
the RX 6700 XT, loaded by the MSVC-built app and `scl_smoke`.
`tools\windows\build-app.bat` builds and deploys the app as CI does; the `.msi` from `packaging/windows/make_msi.sh`
(run with Git Bash) installs, launches and uninstalls silently from the SSH session.

Working copies on `eric`: `C:\Users\ecitt\scl-src` (source synced from the Mac by `git archive`).

Notes:
- The RX 6700 XT (gfx1031) is listed by AMD as runtime-supported but not "HIP SDK supported". That only concerns AMD's
  prebuilt math libraries (rocBLAS etc.), which this project does not use; our kernels are compiled for gfx1031 directly.
- Intel CPUs need flush-to-zero for denormals (done in `core/src/cpu/thread_pool.hpp`); without it the CPU backend was
  4–5× slower after detonation.

## Checking the installers locally (what CI does)

Qt version: 6.10.3 on both. Qt 6.8 cannot link on the macOS 26 SDK (its CMake still adds the removed AGL
framework), and aqtinstall 3.3.0 cannot read the per-architecture Windows repository layout Qt uses from 6.11.

Mac:

```bash
cmake -S . -B build-ci -G Ninja -DCMAKE_BUILD_TYPE=Release -DSCL_GPU=OFF -DCMAKE_PREFIX_PATH=$HOME/Qt-official/6.10.3/macos
cmake --build build-ci
packaging/macos/make_dmg.sh build-ci build-ci/dist
```

`eric` (from the source folder; WiX needs the .NET location):

```bat
tools\windows\build-hip.bat
tools\windows\build-app.bat
set "DOTNET_ROOT=%LOCALAPPDATA%\Microsoft\dotnet"
set "PATH=%USERPROFILE%\.dotnet\tools;%PATH%"
"C:\Program Files\Git\bin\bash.exe" packaging/windows/make_msi.sh build-app dist
```

Results on 2026-10-28: the `.dmg` (57 MB) and the `.msi` (30 MB) both install and launch, and the bundled `scl_smoke` runs.
The installed `.msi` picks the RX 6700 XT on its own (`scl_gpu.dll` uses the HIP runtime of the Radeon driver).

CI installs only the HIP SDK core MSI (extracted from AMD's 25.Q3 package, cached) on the Windows runner to build
`scl_gpu.dll`; the runner has no AMD GPU, so its smoke tests exercise the CPU fallback.
