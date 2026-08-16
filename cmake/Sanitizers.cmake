# Sanitizer configuration.
#
# LOOM_SANITIZER selects a build-wide sanitizer. Address and Undefined are
# combined because they are compatible and cheap together; Thread must be built
# alone (TSan and ASan cannot coexist in one binary).
#
# See docs/DESIGN_DECISIONS.md for why the thread preset also forces
# LOOM_FAKE_INFERENCE: prebuilt ONNX Runtime is not instrumented, so TSan
# reports unactionable races inside ORT's own thread pool.

set(LOOM_SANITIZER "none" CACHE STRING "Sanitizer: none|address|thread|undefined")
set_property(CACHE LOOM_SANITIZER PROPERTY STRINGS none address thread undefined)

add_library(loom_sanitizers INTERFACE)

if(LOOM_SANITIZER STREQUAL "none")
  # nothing to do
elseif(LOOM_SANITIZER STREQUAL "address")
  target_compile_options(loom_sanitizers INTERFACE
    -fsanitize=address,undefined
    -fno-omit-frame-pointer
    -fno-sanitize-recover=all
    -g)
  target_link_options(loom_sanitizers INTERFACE -fsanitize=address,undefined)
elseif(LOOM_SANITIZER STREQUAL "thread")
  target_compile_options(loom_sanitizers INTERFACE
    -fsanitize=thread
    -fno-omit-frame-pointer
    -g)
  target_link_options(loom_sanitizers INTERFACE -fsanitize=thread)
elseif(LOOM_SANITIZER STREQUAL "undefined")
  target_compile_options(loom_sanitizers INTERFACE
    -fsanitize=undefined
    -fno-omit-frame-pointer
    -fno-sanitize-recover=all
    -g)
  target_link_options(loom_sanitizers INTERFACE -fsanitize=undefined)
else()
  message(FATAL_ERROR "Unknown LOOM_SANITIZER='${LOOM_SANITIZER}' (none|address|thread|undefined)")
endif()

if(NOT LOOM_SANITIZER STREQUAL "none")
  message(STATUS "loom: sanitizer enabled -> ${LOOM_SANITIZER}")
endif()

# Reads a suppressions file, drops comments and blank lines, and returns the
# rules as a single C string literal body. Keeps the .txt files the one source
# of truth rather than duplicating the rules into code.
function(loom_read_suppressions infile outvar)
  set(_acc "")
  if(EXISTS "${infile}")
    file(STRINGS "${infile}" _lines)
    foreach(_line IN LISTS _lines)
      string(STRIP "${_line}" _stripped)
      if(_stripped STREQUAL "" OR _stripped MATCHES "^#")
        continue()
      endif()
      string(APPEND _acc "${_stripped}\\n")
    endforeach()
  endif()
  set(${outvar} "${_acc}" PARENT_SCOPE)
endfunction()

loom_read_suppressions("${CMAKE_SOURCE_DIR}/lsan_suppressions.txt" LOOM_LSAN_SUPPRESSIONS)
loom_read_suppressions("${CMAKE_SOURCE_DIR}/tsan_suppressions.txt" LOOM_TSAN_SUPPRESSIONS)

# LOOM_SANITIZER_HOOKS must be added to the sources of every *executable*, not
# to a static library. The sanitizer runtime resolves __lsan_default_suppressions
# as a weak symbol, so nothing ever references it; from inside a static archive
# the linker would simply never pull the member in and the suppressions would be
# silently ignored. Compiling it into each executable is the reliable form.
set(LOOM_SANITIZER_HOOKS "")
if(NOT LOOM_SANITIZER STREQUAL "none")
  configure_file(
    "${CMAKE_SOURCE_DIR}/src/common/sanitizer_suppressions.cpp.in"
    "${CMAKE_BINARY_DIR}/generated/sanitizer_suppressions.cpp"
    @ONLY)
  set(LOOM_SANITIZER_HOOKS "${CMAKE_BINARY_DIR}/generated/sanitizer_suppressions.cpp")
endif()

# Guard rail for the documented TSan strategy. Linking uninstrumented ORT under
# TSan produces noise that is not ours and cannot be fixed; the supported
# configuration stubs inference out entirely so TSan covers only Loom's own
# concurrency (batcher, worker pool, autoscaler, metrics).
if(LOOM_SANITIZER STREQUAL "thread" AND NOT LOOM_FAKE_INFERENCE)
  message(WARNING
    "TSan build is linking real ONNX Runtime. Prebuilt ORT is uninstrumented and "
    "will report races inside its own thread pool that you did not cause and "
    "cannot fix. Prefer -DLOOM_FAKE_INFERENCE=ON (the 'tsan' preset does this). "
    "If you need real inference under TSan, export "
    "TSAN_OPTIONS=suppressions=<repo>/tsan_suppressions.txt")
endif()
