// loom-gateway: terminates HTTP, enqueues inference requests onto Redis, and
// waits for a worker to publish the result. It never runs inference itself --
// that split is what lets a worker run on a different host with nothing changed
// but REDIS_URL.
//
// M0 scope: argument handling and the dependency link self-test. The HTTP
// surface arrives in M1 and the Redis path in M2.

#include "common/build_info.h"

#include <cstring>
#include <iostream>

namespace {

int print_usage(std::ostream& os, int exit_code) {
  os << "loom-gateway -- HTTP front end for the Loom inference engine\n"
        "\n"
        "Usage:\n"
        "  loom-gateway [options]\n"
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
      std::cout << "loom-gateway link self-test\n" << report;
      std::cout << (ok ? "all dependencies ok\n" : "SELF-TEST FAILED\n");
      return ok ? 0 : 1;
    }
    if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
      return print_usage(std::cout, 0);
    }
    std::cerr << "loom-gateway: unrecognised argument '" << argv[i] << "'\n\n";
    return print_usage(std::cerr, 2);
  }

  std::cerr << "loom-gateway: the serving path is not implemented yet (arrives in M1).\n"
               "Try --selftest or --version.\n";
  return 1;
}
