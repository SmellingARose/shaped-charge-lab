add_library(scl_core STATIC
  src/ranges.cpp
  src/analysis.cpp
  src/geometry.cpp
  src/devices.cpp
  src/solver.cpp
  src/run.cpp
  src/cpu/cpu_solver.cpp
)
target_include_directories(scl_core PUBLIC include PRIVATE src)
find_package(Threads REQUIRED)
target_link_libraries(scl_core PUBLIC Threads::Threads)
if(NOT MSVC)
  target_compile_options(scl_core PRIVATE -O3 -ffast-math -fno-finite-math-only)
  include(CheckCXXCompilerFlag)
  check_cxx_compiler_flag(-march=native SCL_HAS_MARCH_NATIVE)
  if(SCL_HAS_MARCH_NATIVE AND NOT APPLE)
    target_compile_options(scl_core PRIVATE -march=native)
  endif()
else()
  target_compile_options(scl_core PRIVATE /O2 /fp:fast /arch:AVX2)
endif()

add_executable(scl_smoke ${PROJECT_SOURCE_DIR}/tools/smoke.cpp)
target_link_libraries(scl_smoke PRIVATE scl_core)
