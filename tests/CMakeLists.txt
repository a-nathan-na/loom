# Unit tests must not require Redis, a model, or a network. Anything that does
# belongs in tests/integration and is labelled "integration" so CI can run the
# two sets separately.

add_executable(loom_unit_tests
  unit/build_info_test.cpp
  ${LOOM_SANITIZER_HOOKS})

target_link_libraries(loom_unit_tests PRIVATE
  loom_common
  GTest::gtest_main)

gtest_discover_tests(loom_unit_tests
  PROPERTIES LABELS "unit"
  DISCOVERY_MODE PRE_TEST)

# Negative control for the LeakSanitizer suppression.
#
# lsan_suppressions.txt silences a real ~176-byte leak inside ONNX Runtime that
# we cannot fix. A suppression that is too broad would silently disable leak
# detection for Loom's own code, and nothing would ever tell us. This canary
# leaks deliberately and is expected to FAIL under ASan -- if it ever starts
# passing, the suppression has grown too broad and the ASan job is worthless.
if(LOOM_SANITIZER STREQUAL "address")
  add_executable(loom_leak_canary leak_canary.cpp ${LOOM_SANITIZER_HOOKS})
  target_link_libraries(loom_leak_canary PRIVATE loom_common)
  # -O0 and -fno-builtin keep the optimiser from deleting the deliberate
  # allocation. A canary that gets optimised away would pass, and a passing
  # canary is exactly the failure this test exists to catch.
  target_compile_options(loom_leak_canary PRIVATE -O0 -fno-builtin)

  add_test(NAME LeakCanary.IsStillDetected COMMAND loom_leak_canary)
  set_tests_properties(LeakCanary.IsStillDetected PROPERTIES
    WILL_FAIL TRUE
    LABELS "sanitizer")
endif()
