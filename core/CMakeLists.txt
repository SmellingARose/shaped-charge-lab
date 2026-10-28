add_library(scl_core STATIC
  src/ranges.cpp
  src/analysis.cpp
  src/geometry.cpp
  src/devices.cpp
  src/stub.cpp
)
target_include_directories(scl_core PUBLIC include PRIVATE src)
find_package(Threads REQUIRED)
target_link_libraries(scl_core PUBLIC Threads::Threads)

add_executable(scl_smoke ${PROJECT_SOURCE_DIR}/tools/smoke.cpp)
target_link_libraries(scl_smoke PRIVATE scl_core)
