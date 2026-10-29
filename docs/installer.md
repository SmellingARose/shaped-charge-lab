# Installer plan

Requirements the platform installers must handle, collected as we bring up each machine.
End users install the app; developers additionally need the toolchains in [environment.md](environment.md).

## Windows

### End-user install (what the installer must ship or run automatically)

| Requirement | How the installer handles it |
|---|---|
| Microsoft Visual C++ runtime (x64) | bundle `vc_redist.x64.exe`, run silently (`/install /quiet /norestart`) if missing |
| Qt 6 runtime (QtQuick, QtGraphs, RHI backends) | bundle the DLLs produced by `windeployqt` next to the executable |
| AMD GPU: HIP runtime | already part of the AMD Adrenalin driver (`amdhip64_6.dll` in System32); the GPU backend is built against the matching HIP SDK major version. If missing, show a link to update the AMD driver; the app falls back to the CPU backend |
| NVIDIA GPU: CUDA runtime | link `cudart` statically (already configured), so only the NVIDIA driver is needed; the app falls back to the CPU backend without it |
| No GPU / unsupported GPU | CPU backend, always available |

The GPU backend should ship as a separate plug-in DLL loaded at runtime, so the main executable starts on any
machine and only the plug-in depends on the AMD/NVIDIA runtime.

### Developer setup (documented, can be scripted with an elevated "setup-dev.ps1")

One elevated PowerShell on a Windows build machine with an AMD GPU (with VS 2022 Build Tools present; otherwise install
them first with `winget install Microsoft.VisualStudio.2022.BuildTools`):

```powershell
Start-Process "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" -Wait -ArgumentList 'modify', '--installPath', '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '--quiet', '--norestart'
# HIP SDK matching the driver's HIP runtime (Adrenalin ships HIP 6 -> HIP SDK 6.4). From AMD's 25.Q3 package:
Start-Process msiexec -Wait -ArgumentList '/i', '<extracted package>\Packages\Apps\ROCmSDKPackages\SDKCore\ROCm_SDK_Core.msi', '/qn', '/L*v', "$env:USERPROFILE\hip-sdk-install.log"
```

Then `tools\windows\build-hip.bat`. NVIDIA build machines install the CUDA toolkit instead.

## macOS

- Ship a signed, notarised `.app` bundle with Qt frameworks via `macdeployqt`. Metal is part of the OS; nothing else to install.

## Linux

- Ship an AppImage (Qt bundled). GPU: ROCm runtime (AMD) or the NVIDIA driver; CPU fallback otherwise.
