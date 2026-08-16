// loom-worker: pulls requests from the Redis stream, assembles them into
// batches under a latency deadline, runs inference on a shared ONNX Runtime
// session, and publishes results back. Scaling this process out -- locally via
// docker compose, or across hosts -- is the whole point of the Redis hop.
//
// M0 scope: argument handling and the dependency link self-test. The batching
// loop arrives in M2 and the thread pool in M3.

#include "common/build_info.h"

#include <cstring>
#include <iostream>

namespace {

int print_usage(std::ostream& os, int exit_code) {
  os << "loom-worker -- inference worker for the Loom inference engine\n"
        "\n"
        "Usage:\n"
        "  loom-worker [options]\n"
        "\n"
        "Options:\n"
        "  --version     Print version and linked dependency versions\n"
        "  --selftest    Verify every third-party dependency is linked and working\n"
        "  --help        Show this message\n";
  return exit_code;
}

}  // namespace

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--version") == 0) {
      std::cout << loom::version_banner();
      return 0;
    }
    if (std::strcmp(argv[i], "--selftest") == 0) {
      std::string report;
      const bool ok = loom::link_selftest(report);
      std::cout << "loom-worker link self-test\n" << report;
      std::cout << (ok ? "all dependencies ok\n" : "SELF-TEST FAILED\n");
      return ok ? 0 : 1;
    }
    if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
      return print_usage(std::cout, 0);
    }
    std::cerr << "loom-worker: unrecognised argument '" << argv[i] << "'\n\n";
    return print_usage(std::cerr, 2);
  }

  std::cerr << "loom-worker: the inference loop is not implemented yet (arrives in M2).\n"
               "Try --selftest or --version.\n";
  return 1;
}
