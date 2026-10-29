@echo off
rem Builds the core with the AMD HIP backend on Windows: ROCm clang for all code (CMake requires one compiler
rem family for C, C++ and HIP), MSVC headers, libraries and linker from the Build Tools environment.
rem HIP SDK location: the installer sets HIP_PATH; default is the standard install folder.
rem Requires the toolchain AMD supports for the HIP SDK: Visual Studio 2022 C++ build tools (MSVC v143).
rem Use the HIP SDK whose runtime matches the display driver (Adrenalin ships amdhip64_6.dll -> HIP SDK 6.4).
rem Newer MSVC (14.5x, VS 18) declares <cmath> comparisons constexpr, which clashes with the HIP headers.
rem GPU target: set SCL_HIP_ARCH (default gfx1031 = RX 6700 XT; gfx1030 RX 6800/6900, gfx1100 RX 7900, gfx1201 RX 9070).
setlocal
if not defined HIP_PATH set "HIP_PATH=C:\Program Files\AMD\ROCm\6.4\"
rem CMake gets forward-slash paths without a trailing slash (a trailing \ would escape the closing quote)
set "HIPDIR=%HIP_PATH:\=/%"
if "%HIPDIR:~-1%"=="/" set "HIPDIR=%HIPDIR:~0,-1%"
if not defined SCL_HIP_ARCH set SCL_HIP_ARCH=gfx1031
set "VSDEV=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VSDEV%" set "VSDEV=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
call "%VSDEV%" >nul || exit /b 1
set "PATH=%HIP_PATH%bin;%PATH%"
cmake -S . -B build-hip -G Ninja -DCMAKE_BUILD_TYPE=Release -DSCL_BUILD_APP=OFF ^
  -DCMAKE_C_COMPILER="%HIPDIR%/bin/clang.exe" -DCMAKE_CXX_COMPILER="%HIPDIR%/bin/clang++.exe" ^
  -DCMAKE_HIP_COMPILER="%HIPDIR%/bin/clang++.exe" -DCMAKE_HIP_PLATFORM=amd ^
  -DCMAKE_HIP_ARCHITECTURES=%SCL_HIP_ARCH% -DCMAKE_PREFIX_PATH="%HIPDIR%" -DSCL_GPU=HIP || exit /b 1
cmake --build build-hip || exit /b 1
echo BUILD OK
