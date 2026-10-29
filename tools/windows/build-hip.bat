@echo off
rem Builds the AMD GPU backend (scl_gpu.dll, loaded by the app at runtime) on Windows: ROCm clang for all code (CMake requires one compiler
rem family for C, C++ and HIP), MSVC headers, libraries and linker from the Build Tools environment.
rem HIP SDK location: the installer sets HIP_PATH; default is the standard install folder.
rem Requires the toolchain AMD supports for the HIP SDK: Visual Studio 2022 C++ build tools (MSVC v143).
rem Use the HIP SDK whose runtime matches the display driver (Adrenalin ships amdhip64_6.dll -> HIP SDK 6.4).
rem Newer MSVC (14.5x, VS 18) declares <cmath> comparisons constexpr, which clashes with the HIP headers.
rem GPU targets: set SCL_HIP_ARCH (default: every RDNA2-4 Radeon, gfx1030-1032 RX 6000, gfx1100-1102 RX 7000,
rem gfx1200-1201 RX 9000). Output: build-hip\core\scl_gpu.dll; pass it to the app build as -DSCL_GPU_PLUGIN=<path>.
setlocal
if not defined HIP_PATH set "HIP_PATH=C:\Program Files\AMD\ROCm\6.4\"
rem CMake gets forward-slash paths without a trailing slash (a trailing \ would escape the closing quote)
set "HIPDIR=%HIP_PATH:\=/%"
if "%HIPDIR:~-1%"=="/" set "HIPDIR=%HIPDIR:~0,-1%"
if not defined SCL_HIP_ARCH set "SCL_HIP_ARCH=gfx1030;gfx1031;gfx1032;gfx1100;gfx1101;gfx1102;gfx1200;gfx1201"
rem Visual Studio 2022 (any edition, with the C++ tools), found by vswhere
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -version [17.0^,18.0^) -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo Visual Studio 2022 with the C++ build tools is required & exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set "PATH=%HIP_PATH%bin;%PATH%"
cmake -S . -B build-hip -G Ninja -DCMAKE_BUILD_TYPE=Release -DSCL_BUILD_APP=OFF ^
  -DCMAKE_C_COMPILER="%HIPDIR%/bin/clang.exe" -DCMAKE_CXX_COMPILER="%HIPDIR%/bin/clang++.exe" ^
  -DCMAKE_HIP_COMPILER="%HIPDIR%/bin/clang++.exe" -DCMAKE_HIP_PLATFORM=amd ^
  -DCMAKE_HIP_ARCHITECTURES="%SCL_HIP_ARCH%" -DCMAKE_PREFIX_PATH="%HIPDIR%" -DSCL_GPU=HIP || exit /b 1
cmake --build build-hip --target scl_gpu scl_smoke || exit /b 1
echo BUILD OK
