# Imports the prebuilt ONNX Runtime distribution as onnxruntime::onnxruntime.
#
# We deliberately use the upstream prebuilt tarball rather than building ORT from
# source or pulling it through vcpkg: building ORT takes hours and dominates the
# project's entire time budget, and the vcpkg port builds from source too.
# scripts/fetch_onnxruntime.sh downloads and SHA-verifies it into third_party/.
#
# Not linked at all when LOOM_FAKE_INFERENCE=ON -- see cmake/Sanitizers.cmake.

set(LOOM_ORT_VERSION "1.20.1" CACHE STRING "ONNX Runtime version to link against")
set(LOOM_ORT_ROOT "" CACHE PATH "Path to an unpacked ONNX Runtime distribution")

if(LOOM_FAKE_INFERENCE)
  message(STATUS "loom: LOOM_FAKE_INFERENCE=ON -- skipping ONNX Runtime entirely")
  return()
endif()

if(NOT LOOM_ORT_ROOT)
  set(LOOM_ORT_ROOT
      "${CMAKE_SOURCE_DIR}/third_party/onnxruntime-linux-x64-${LOOM_ORT_VERSION}")
endif()

find_path(LOOM_ORT_INCLUDE_DIR
  NAMES onnxruntime_cxx_api.h
  PATHS "${LOOM_ORT_ROOT}/include"
  NO_DEFAULT_PATH)

find_library(LOOM_ORT_LIBRARY
  NAMES onnxruntime
  PATHS "${LOOM_ORT_ROOT}/lib"
  NO_DEFAULT_PATH)

if(NOT LOOM_ORT_INCLUDE_DIR OR NOT LOOM_ORT_LIBRARY)
  message(FATAL_ERROR
    "ONNX Runtime not found under '${LOOM_ORT_ROOT}'.\n"
    "Run: ./scripts/fetch_onnxruntime.sh\n"
    "Or configure with -DLOOM_ORT_ROOT=/path/to/onnxruntime-linux-x64-<ver>")
endif()

add_library(onnxruntime::onnxruntime SHARED IMPORTED GLOBAL)
set_target_properties(onnxruntime::onnxruntime PROPERTIES
  IMPORTED_LOCATION "${LOOM_ORT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${LOOM_ORT_INCLUDE_DIR}")

message(STATUS "loom: ONNX Runtime ${LOOM_ORT_VERSION} -> ${LOOM_ORT_LIBRARY}")
