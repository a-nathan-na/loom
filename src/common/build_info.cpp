#include "common/build_info.h"

#include "loom/version.h"

#include <hiredis/hiredis.h>
#include <httplib.h>
#include <nlohmann/json.hpp>
#include <prometheus/counter.h>
#include <prometheus/registry.h>
#include <sw/redis++/redis++.h>
#include <sw/redis++/redis_uri.h>

#include <sstream>

#if !LOOM_FAKE_INFERENCE
#include <onnxruntime_cxx_api.h>
#endif

namespace loom {
namespace {

std::string ort_version() {
#if LOOM_FAKE_INFERENCE
  return "stubbed (LOOM_FAKE_INFERENCE=ON)";
#else
  return OrtGetApiBase()->GetVersionString();
#endif
}

std::string hiredis_version() {
  std::ostringstream os;
  os << HIREDIS_MAJOR << '.' << HIREDIS_MINOR << '.' << HIREDIS_PATCH;
  return os.str();
}

std::string json_version() {
  std::ostringstream os;
  os << NLOHMANN_JSON_VERSION_MAJOR << '.' << NLOHMANN_JSON_VERSION_MINOR << '.'
     << NLOHMANN_JSON_VERSION_PATCH;
  return os.str();
}

}  // namespace

bool inference_is_stubbed() {
#if LOOM_FAKE_INFERENCE
  return true;
#else
  return false;
#endif
}

std::string version_banner() {
  std::ostringstream os;
  os << "loom " << LOOM_VERSION_STRING << "\n"
     << "  onnxruntime  " << ort_version() << "\n"
     << "  cpp-httplib  " << CPPHTTPLIB_VERSION << "\n"
     << "  nlohmann/json " << json_version() << "\n"
     << "  hiredis      " << hiredis_version() << "\n";
  return os.str();
}

bool link_selftest(std::string& report) {
  std::ostringstream os;
  bool ok = true;

  // nlohmann/json -- round-trip a document.
  {
    auto doc = nlohmann::json::parse(R"({"batch":[1,2,3]})");
    const bool good = doc["batch"].size() == 3 && doc["batch"][2] == 3;
    ok = ok && good;
    os << "  json         " << (good ? "ok" : "FAILED") << " (" << json_version() << ")\n";
  }

  // cpp-httplib -- construct a server and register a route. Not bound to a port;
  // we only need to prove the header-only library compiles and links here.
  {
    httplib::Server server;
    server.Get("/healthz", [](const httplib::Request&, httplib::Response& res) {
      res.set_content("ok", "text/plain");
    });
    const bool good = server.is_valid();
    ok = ok && good;
    os << "  httplib      " << (good ? "ok" : "FAILED") << " (" << CPPHTTPLIB_VERSION << ")\n";
  }

  // prometheus-cpp -- build a registry and collect from it. This is the exact
  // path /metrics will use, minus the serializer.
  {
    prometheus::Registry registry;
    auto& family = prometheus::BuildCounter()
                       .Name("loom_selftest_total")
                       .Help("Counter constructed during link self-test")
                       .Register(registry);
    family.Add({{"stage", "selftest"}}).Increment(2);
    const auto collected = registry.Collect();
    const bool good = collected.size() == 1 && !collected[0].metric.empty() &&
                      collected[0].metric[0].counter.value == 2.0;
    ok = ok && good;
    os << "  prometheus   " << (good ? "ok" : "FAILED") << "\n";
  }

  // redis-plus-plus / hiredis -- parse a connection URI. Uri lives in the
  // compiled static library rather than a header, so this proves real linkage
  // and not merely that the headers were found. Deliberately does not connect:
  // M0 must pass with no Redis running.
  {
    bool good = false;
    try {
      const sw::redis::Uri uri("tcp://127.0.0.1:6379");
      const auto& opts = uri.connection_options();
      good = opts.host == "127.0.0.1" && opts.port == 6379;
    } catch (const std::exception& e) {
      os << "  redis++      threw: " << e.what() << "\n";
    }
    ok = ok && good;
    os << "  redis++      " << (good ? "ok" : "FAILED") << " (hiredis " << hiredis_version()
       << ")\n";
  }

  // ONNX Runtime -- create an Env. This initialises ORT's logging and thread
  // infrastructure, which is the part most likely to fail on a bad install.
#if LOOM_FAKE_INFERENCE
  os << "  onnxruntime  skipped (LOOM_FAKE_INFERENCE=ON)\n";
#else
  {
    bool good = false;
    try {
      Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "loom-selftest");
      good = env != nullptr;
    } catch (const Ort::Exception& e) {
      os << "  onnxruntime  threw: " << e.what() << "\n";
    }
    ok = ok && good;
    os << "  onnxruntime  " << (good ? "ok" : "FAILED") << " (" << ort_version() << ")\n";
  }
#endif

  report = os.str();
  return ok;
}

}  // namespace loom
