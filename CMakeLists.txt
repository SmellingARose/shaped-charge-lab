cmake_minimum_required(VERSION 3.25)
project(ShapedChargeLab VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(SCL_BUILD_APP "Build the Qt app" ON)

add_subdirectory(core)
if(SCL_BUILD_APP AND EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/app/CMakeLists.txt)
  add_subdirectory(app)
endif()
