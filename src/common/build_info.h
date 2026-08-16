#pragma once

#include <string>

namespace loom {

/// Human-readable version banner for --version.
std::string version_banner();

/// Exercises one real symbol from every third-party dependency and reports what
/// it found. This exists so that a broken toolchain or a mislinked dependency
/// fails loudly at M0 rather than surfacing three milestones later as a strange
/// runtime error. `loom-gateway --selftest` runs it.
///
/// Returns true if every dependency responded as expected.
bool link_selftest(std::string& report);

/// True when built with LOOM_FAKE_INFERENCE=ON, i.e. ONNX Runtime is not linked.
bool inference_is_stubbed();

}  // namespace loom
