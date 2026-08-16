#include "common/build_info.h"

#include <gtest/gtest.h>

#include <string>

namespace {

TEST(BuildInfo, VersionBannerNamesLoomAndItsDependencies) {
  const std::string banner = loom::version_banner();
  EXPECT_NE(banner.find("loom "), std::string::npos);
  EXPECT_NE(banner.find("cpp-httplib"), std::string::npos);
  EXPECT_NE(banner.find("hiredis"), std::string::npos);
}

// The self-test is the M0 exit criterion: every third-party dependency is
// linked and answering. It is a unit test on purpose -- it must pass with no
// Redis running and no model on disk.
TEST(BuildInfo, LinkSelfTestPasses) {
  std::string report;
  const bool ok = loom::link_selftest(report);
  EXPECT_TRUE(ok) << report;
  EXPECT_FALSE(report.empty());
}

// Guards the TSan strategy: the thread preset must not link ONNX Runtime. If
// this ever inverts, TSan starts reporting races inside uninstrumented ORT and
// the sanitizer deliverable quietly becomes worthless.
TEST(BuildInfo, InferenceStubbingMatchesBuildConfiguration) {
#if LOOM_FAKE_INFERENCE
  EXPECT_TRUE(loom::inference_is_stubbed());
#else
  EXPECT_FALSE(loom::inference_is_stubbed());
#endif
}

}  // namespace
