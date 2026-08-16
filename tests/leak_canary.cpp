// Negative control for the LeakSanitizer suppression list.
//
// lsan_suppressions.txt silences a genuine ~176-byte leak inside ONNX Runtime
// that Loom cannot fix. The danger with any suppression is that it quietly does
// more than intended -- a rule matching too broadly would switch off leak
// detection for our own code, and every ASan run would go green for the wrong
// reason.
//
// So: leak on purpose, from a Loom binary carrying the same embedded
// suppressions the real binaries use. CTest marks this test WILL_FAIL, meaning
// a *passing* process here is the failure condition. If this ever starts
// passing, the suppression has grown too broad and the ASan job is worthless.
//
// Built only when LOOM_SANITIZER=address.

#include "common/build_info.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <string>

namespace {

constexpr std::size_t kCanaryBytes = 4321;
constexpr std::uintptr_t kMask = 0xA5A5A5A5A5A5A5A5ULL;

// Holds the allocation address in obfuscated form. LeakSanitizer decides what
// is still reachable by scanning memory for plain pointer values, so simply
// dropping a local is not enough -- the compiler may leave a copy in a live
// stack slot and LSan would classify the block as reachable rather than leaked.
// XOR-ing means no recognisable pointer to the block survives anywhere.
std::uintptr_t g_hidden = 0;

// Volatile, so storing the pointer here counts as an escape. Without it, LLVM
// sees an allocation whose address never leaves the function, and simply
// deletes the malloc outright -- there is then no leak to detect and this
// control silently stops controlling anything.
void* volatile g_escape = nullptr;

// noinline so the allocation cannot be folded into main's frame.
__attribute__((noinline)) void allocate_and_orphan() {
  void* block = std::malloc(kCanaryBytes);
  if (block == nullptr) {
    std::abort();
  }
  // Write to it so the allocation cannot be optimised away entirely.
  static_cast<unsigned char*>(block)[0] = 0xAB;

  g_escape = block;  // volatile store: the allocation now escapes
  g_hidden = reinterpret_cast<std::uintptr_t>(block) ^ kMask;
  g_escape = nullptr;  // drop the last plain pointer to it
}

// Overwrite the stack region allocate_and_orphan just used, clearing any
// residual copy of the pointer left behind in a dead slot.
__attribute__((noinline)) void scrub_stack() {
  volatile unsigned char scratch[8192];
  for (std::size_t i = 0; i < sizeof(scratch); ++i) {
    scratch[i] = 0;
  }
}

}  // namespace

int main() {
  // Touch real Loom code first, so this process links and initialises exactly
  // like the binaries it is a control for -- including the ONNX Runtime
  // allocation that the suppression is supposed to hide.
  std::string report;
  (void)loom::link_selftest(report);

  allocate_and_orphan();
  scrub_stack();

  // Expected outcome: LeakSanitizer reports exactly one 4321-byte leak (ORT's
  // 352 bytes stay suppressed) and the process exits non-zero.
  return 0;
}
