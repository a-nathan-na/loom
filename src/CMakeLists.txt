configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/common/version.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/loom/version.h"
  @ONLY)

add_library(loom_common STATIC
  common/build_info.cpp)

target_include_directories(loom_common PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/generated")

target_link_libraries(loom_common PUBLIC
  loom_base
  httplib::httplib
  nlohmann_json::nlohmann_json
  prometheus-cpp::core
  ${LOOM_REDIS_TARGET})

# ONNX Runtime is linked only for real-inference builds. The TSan preset sets
# LOOM_FAKE_INFERENCE=ON so the uninstrumented ORT shared object is not in the
# process at all -- see cmake/Sanitizers.cmake.
if(NOT LOOM_FAKE_INFERENCE)
  target_link_libraries(loom_common PUBLIC onnxruntime::onnxruntime)
endif()

# LOOM_SANITIZER_HOOKS is empty for non-sanitizer builds. See cmake/Sanitizers.cmake
# for why it is compiled per-executable instead of into loom_common.
add_executable(loom-gateway bin/loom_gateway_main.cpp ${LOOM_SANITIZER_HOOKS})
target_link_libraries(loom-gateway PRIVATE loom_common)

add_executable(loom-worker bin/loom_worker_main.cpp ${LOOM_SANITIZER_HOOKS})
target_link_libraries(loom-worker PRIVATE loom_common)
