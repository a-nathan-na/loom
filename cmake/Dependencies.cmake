# Third-party dependencies.
#
# FetchContent rather than vcpkg: no bootstrap step in CI, one file to read, and
# every version is visibly pinned right here. hiredis is the exception -- it comes
# from apt (libhiredis-dev), because building it under redis-plus-plus via
# FetchContent is the known friction point in this dependency set.
#
# Versions are conservative known-good pins. Bump deliberately, not casually:
# a failed configure is cheap, a subtly different ORT ABI is not.

include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

# ---- cpp-httplib: HTTP server for the gateway and the /metrics route ----------
FetchContent_Declare(httplib
  GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
  GIT_TAG        v0.18.1
  GIT_SHALLOW    TRUE)
set(HTTPLIB_COMPILE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_REQUIRE_OPENSSL OFF CACHE BOOL "" FORCE)

# ---- nlohmann/json: request/response codec and config files ------------------
FetchContent_Declare(nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG        v3.11.3
  GIT_SHALLOW    TRUE)
set(JSON_BuildTests OFF CACHE INTERNAL "")

# ---- redis-plus-plus: Redis Streams client -----------------------------------
FetchContent_Declare(redis_plus_plus
  GIT_REPOSITORY https://github.com/sewenew/redis-plus-plus.git
  GIT_TAG        1.3.13
  GIT_SHALLOW    TRUE)
set(REDIS_PLUS_PLUS_BUILD_TEST   OFF CACHE BOOL "" FORCE)
set(REDIS_PLUS_PLUS_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(REDIS_PLUS_PLUS_BUILD_STATIC ON  CACHE BOOL "" FORCE)
set(REDIS_PLUS_PLUS_CXX_STANDARD 17  CACHE STRING "" FORCE)

# ---- prometheus-cpp: metrics registry ----------------------------------------
# ENABLE_PULL=OFF is deliberate: prometheus-cpp's pull mode embeds civetweb, a
# whole second HTTP server. We already run cpp-httplib, so we serve /metrics from
# it and use prometheus-cpp purely as a registry + TextSerializer.
FetchContent_Declare(prometheus_cpp
  GIT_REPOSITORY https://github.com/jupp0r/prometheus-cpp.git
  GIT_TAG        v1.3.0
  GIT_SHALLOW    TRUE)
set(ENABLE_PUSH        OFF CACHE BOOL "" FORCE)
set(ENABLE_PULL        OFF CACHE BOOL "" FORCE)
set(ENABLE_COMPRESSION OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING     OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(httplib nlohmann_json redis_plus_plus prometheus_cpp)

# redis-plus-plus exports a different target name depending on static vs shared.
if(TARGET redis++::redis++_static)
  set(LOOM_REDIS_TARGET redis++::redis++_static)
elseif(TARGET redis++::redis++)
  set(LOOM_REDIS_TARGET redis++::redis++)
else()
  message(FATAL_ERROR "redis-plus-plus did not export an expected target")
endif()
message(STATUS "loom: redis-plus-plus target -> ${LOOM_REDIS_TARGET}")

# redis-plus-plus configure-generates sw/redis++/hiredis_features.h into its own
# build tree, but the interface include directories it exports point only at the
# source tree and a not-yet-existent install prefix. Consumers therefore fail
# with "sw/redis++/hiredis_features.h: file not found". Add the generated
# header's include root back. Uses the concrete target, not the :: alias, since
# alias targets reject target_include_directories.
foreach(_rpp redis++_static redis++)
  if(TARGET ${_rpp})
    # BUILD_INTERFACE is required: redis++ installs/exports this target, and CMake
    # rejects a bare build-directory path in an exported target's includes.
    target_include_directories(${_rpp} INTERFACE
      "$<BUILD_INTERFACE:${redis_plus_plus_BINARY_DIR}/src>")
  endif()
endforeach()

# Treat third-party headers as system headers. Loom builds with -Wconversion,
# -Wold-style-cast and friends, which these libraries do not aim to satisfy;
# without this, -Werror in the release preset fails on code we do not own.
foreach(_dep httplib nlohmann_json redis++_static redis++ prometheus-cpp-core)
  if(TARGET ${_dep})
    set_target_properties(${_dep} PROPERTIES SYSTEM TRUE)
  endif()
endforeach()

# ---- GoogleTest --------------------------------------------------------------
if(LOOM_BUILD_TESTS)
  FetchContent_Declare(googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.15.2
    GIT_SHALLOW    TRUE)
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
  include(GoogleTest)
endif()
