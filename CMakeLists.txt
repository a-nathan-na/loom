cmake_minimum_required(VERSION 3.22)
project(loom
  VERSION 0.1.0
  DESCRIPTION "A model-serving inference engine with dynamic batching"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

option(LOOM_BUILD_TESTS "Build unit and integration tests" ON)
option(LOOM_WERROR "Treat warnings in Loom's own code as errors" OFF)
option(LOOM_FAKE_INFERENCE
  "Stub out ONNX Runtime so sanitizers see only Loom's own concurrency" OFF)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

include(cmake/Sanitizers.cmake)
include(cmake/Dependencies.cmake)
include(cmake/ONNXRuntime.cmake)

# Warnings-as-errors on our own code only. Third-party targets built through
# FetchContent are untouched by this.
add_library(loom_warnings INTERFACE)
target_compile_options(loom_warnings INTERFACE
  -Wall -Wextra -Wpedantic -Wshadow -Wnon-virtual-dtor
  -Wold-style-cast -Wcast-align -Wunused -Woverloaded-virtual
  -Wconversion -Wsign-conversion -Wdouble-promotion -Wformat=2
  $<$<BOOL:${LOOM_WERROR}>:-Werror>)

# Every Loom target links this: warnings, sanitizers, and threads in one place.
add_library(loom_base INTERFACE)
find_package(Threads REQUIRED)
target_link_libraries(loom_base INTERFACE
  loom_warnings
  loom_sanitizers
  Threads::Threads)
target_compile_definitions(loom_base INTERFACE
  $<$<BOOL:${LOOM_FAKE_INFERENCE}>:LOOM_FAKE_INFERENCE=1>)

add_subdirectory(src)

if(LOOM_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()

message(STATUS "")
message(STATUS "loom ${PROJECT_VERSION} configuration")
message(STATUS "  build type      : ${CMAKE_BUILD_TYPE}")
message(STATUS "  compiler        : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "  sanitizer       : ${LOOM_SANITIZER}")
message(STATUS "  fake inference  : ${LOOM_FAKE_INFERENCE}")
message(STATUS "  tests           : ${LOOM_BUILD_TESTS}")
message(STATUS "")
