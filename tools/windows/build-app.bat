@echo off
rem Builds the Qt app with MSVC (Direct3D UI; CPU backend, plus the GPU backend if built) and deploys it to build-app\deploy.
rem Qt: set QT_DIR to the msvc2022_64 folder (default: %USERPROFILE%\Qt\6.10.3\msvc2022_64, the aqtinstall layout).
rem GPU backend: run tools\windows\build-hip.bat first; its build-hip\core\scl_gpu.dll is deployed when present.
rem Requires Visual Studio 2022 C++ build tools (or Community), CMake and Ninja.
setlocal
if not defined QT_DIR set "QT_DIR=%USERPROFILE%\Qt\6.10.3\msvc2022_64"
rem Visual Studio 2022 (any edition, with the C++ tools), found by vswhere
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -version [17.0^,18.0^) -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo Visual Studio 2022 with the C++ build tools is required & exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set "QTDIR_FWD=%QT_DIR:\=/%"
set "GPU_ARG="
if exist build-hip\core\scl_gpu.dll set "GPU_ARG=-DSCL_GPU_PLUGIN=%CD:\=/%/build-hip/core/scl_gpu.dll"
cmake -S . -B build-app -G Ninja -DCMAKE_BUILD_TYPE=Release -DSCL_GPU=OFF ^
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_PREFIX_PATH="%QTDIR_FWD%" %GPU_ARG% || exit /b 1
cmake --build build-app || exit /b 1
cmake --build build-app --target scl_deploy || exit /b 1
echo BUILD OK
