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

# ---- Metal backend (macOS): physics headers + entry points spliced into one MSL source string
if(APPLE)
  option(SCL_WITH_METAL "Build the Metal backend" ON)
endif()
if(SCL_WITH_METAL)
  enable_language(OBJCXX)
  set(_phys ${CMAKE_CURRENT_SOURCE_DIR}/src/physics)
  set(_metal_in ${CMAKE_CURRENT_SOURCE_DIR}/src/metal/kernels.metal.in)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${_phys}/portable.h ${_phys}/sph.h ${_metal_in})
  file(READ ${_phys}/portable.h _a)
  file(READ ${_phys}/sph.h _b)
  file(READ ${_metal_in} _c)
  set(_src "${_a}\n${_b}\n${_c}")
  string(REPLACE "#pragma once" "" _src "${_src}")
  string(REPLACE "#include \"portable.h\"" "" _src "${_src}")
  file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/gen/metal_source.inc "R\"SCLMETAL(${_src})SCLMETAL\"\n")
  target_sources(scl_core PRIVATE src/metal/metal_solver.mm)
  target_include_directories(scl_core PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/gen)
  set_source_files_properties(src/metal/metal_solver.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_compile_definitions(scl_core PUBLIC SCL_WITH_METAL=1)
  target_link_libraries(scl_core PUBLIC "-framework Metal" "-framework Foundation")
endif()

add_executable(scl_smoke ${PROJECT_SOURCE_DIR}/tools/smoke.cpp)
target_link_libraries(scl_smoke PRIVATE scl_core)
