@echo off
rem Builds the Qt app (CPU backend, Direct3D UI) with MSVC, as CI does, and deploys it to build-app\deploy.
rem Qt: set QT_DIR to the msvc2022_64 folder (default: %USERPROFILE%\Qt\6.10.3\msvc2022_64, the aqtinstall layout).
rem Requires Visual Studio 2022 C++ build tools (or Community), CMake and Ninja.
setlocal
if not defined QT_DIR set "QT_DIR=%USERPROFILE%\Qt\6.10.3\msvc2022_64"
set "VSDEV=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VSDEV%" set "VSDEV=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
call "%VSDEV%" >nul || exit /b 1
set "QTDIR_FWD=%QT_DIR:\=/%"
cmake -S . -B build-app -G Ninja -DCMAKE_BUILD_TYPE=Release -DSCL_GPU=OFF ^
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_PREFIX_PATH="%QTDIR_FWD%" || exit /b 1
cmake --build build-app || exit /b 1
cmake --build build-app --target scl_deploy || exit /b 1
echo BUILD OK
