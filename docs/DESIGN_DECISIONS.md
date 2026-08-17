# Design decisions

The reasoning behind Loom's architecture, including the alternatives that were
considered and rejected. The [README](../README.md) has the summary; this is the
long form.

## Gateway / worker split

Three process types, all speaking to Redis. The gateway terminates HTTP and
never runs inference; workers run inference and never terminate HTTP.

This split is what makes the multi-node claim real rather than cosmetic — a
worker container on another host is the same binary with a different
`REDIS_URL`, with no code path that behaves differently. A monolith with an
in-process queue would have been simpler, but it would have made the
distributed behaviour a simulation rather than a property.

## Where batching happens: worker-side

Requests are enqueued individually and the *worker* assembles batches, rather
than the gateway grouping requests before enqueueing them.

| | Gateway-side | Worker-side (chosen) |
|---|---|---|
| Coalescing | Per-gateway only | Global across all gateways |
| Load balancing | Needs a separate component | The consumer group *is* the balancer |
| Payload | Gateway serialises a large batch blob | Individual entries |

`XREADGROUP COUNT=max_batch BLOCK=t` also gives graceful degradation almost for
free: it returns as soon as at least one entry exists, so a trickle of traffic
produces batches of one immediately, with no special-casing.

### The drain loop

`BLOCK` alone under-batches at medium load — it returns on the first available
entry rather than waiting for a full batch. So the scheduling core is a
**deadline-aware drain loop**: after a first non-empty read of `k < max_batch`,
keep issuing short `BLOCK drain_slice_ms` reads until either the batch is full
or `max_wait_ms` has elapsed.

This lives in `src/batch/` and is unit-tested against a fake queue with no Redis
in the loop, so the timing behaviour is deterministic in tests.

**Deadline awareness.** Each request carries an absolute deadline. A worker
drops already-expired requests — responding 504 — *before* spending compute on
them. This is real inference-server behaviour and it keeps p99 honest under
overload: without it, a backlog spends its entire capacity computing answers
nobody is still waiting for.

## Queue primitive: Redis Streams

| Option | Verdict |
|---|---|
| **Streams + consumer groups** | **Chosen.** Per-consumer PEL, `XAUTOCLAIM` crash recovery, `XINFO GROUPS`→`lag` as a queue-depth signal. |
| `BLMOVE` reliable-list pattern | Rejected — would mean hand-rolling the pending list, the reaper, and the depth metric. |
| Pub/Sub | Rejected — no durability; drops requests on worker restart. |

The autoscaler needs a queue-depth signal and the fault-tolerance story needs
crash recovery. Streams provide both directly, which is most of the reason to
accept their extra API surface.

## Delivery is at-least-once

`XACK` happens *after* the response is published, so a worker that dies
mid-batch leaves its entries recoverable in the pending list. A reaper thread
runs `XAUTOCLAIM` on a min-idle-time to reclaim them.

The consequence is that a reclaimed request may be inferred twice. Inference is
idempotent, so this is safe — but it is a real property of the system and is
documented as at-least-once rather than described as exactly-once, which it is
not.

## Worker pool: hand-rolled

Not a case of reinventing basics. The queue lives in Redis, so this is not a
task-queue pool at all — it is N long-lived loop threads with *dynamic
membership*, because the pool autoscales.

`BS::thread_pool::reset()` tears down and recreates the entire pool, which would
drop in-flight batches on every scaling decision. Hand-rolling buys cooperative
scale-down: a retiring thread finishes its current batch, acks it, and only then
exits. It also allows retiring a consumer only once its pending list is empty —
calling `XGROUP DELCONSUMER` earlier would orphan pending entries.

## ONNX Runtime threading

One shared `Ort::Session` per process, with `intra_op_num_threads=1` and
`inter_op_num_threads=1`. Parallelism lives at the batch level.

ONNX Runtime explicitly supports concurrent `Run()` calls on a single session,
and its docs advise against per-thread sessions, which multiply memory for no
gain. Leaving intra-op threading at its default would compound with the worker
threads: K worker threads each spawning T intra-op threads oversubscribes the
CPU K×T ways and degrades throughput under load.

## Wire payload: uint8, not float32

Clients send a uint8 `[3,224,224]` tensor (~150 KB) and the worker normalises to
float32, rather than sending float32 directly (~600 KB). Four times less Redis
bandwidth per request, and worker-side preprocessing is both realistic and
measurable.

This matters for the benchmark: at 150 KB/request and 200 rps, Redis is moving
~30 MB/s. That is fine locally, but the benchmark report has to state the
payload-bandwidth ceiling separately, or it is not clear whether the numbers
measure the batcher or the network.

## Sanitizer strategy

ASan + UBSan and TSan both run clean in CI on every push. Getting there required
handling two problems caused by third-party code we do not compile.

### TSan excludes ONNX Runtime

The `tsan` preset sets `LOOM_FAKE_INFERENCE=ON`, which stubs inference out so
ONNX Runtime is never linked into the binary at all.

Prebuilt ORT is not compiled with `-fsanitize=thread`. TSan cannot see its
internal synchronisation, so it reports races inside ORT's own thread pool that
are neither real nor fixable from here. Rebuilding ORT from source under TSan
would cost hours of build time and tell us nothing about Loom's correctness.

Excluding it means TSan reports on exactly the code we wrote — batcher, worker
pool, autoscaler, metrics — which is where a race would be our bug. Two things
keep the exclusion honest:

- An `ldd` check confirms `libonnxruntime` really is absent from the TSan binary.
- A unit test asserts the stubbing flag matches the build configuration, so the
  arrangement cannot silently invert.

For the case where you *do* want TSan over real inference,
[`tsan_suppressions.txt`](../tsan_suppressions.txt) scopes the noise.

### ASan, and a leak inside ORT

The same class of problem appeared one layer down. LeakSanitizer reports a
genuine leak of 176 bytes × 2 — process-global state that ONNX Runtime allocates
per `Ort::Env`, never frees, and holds no pointer to at exit. It is a fixed
one-time allocation, not per-request, and callers cannot release it.
[`lsan_suppressions.txt`](../lsan_suppressions.txt) scopes it to
`libonnxruntime` only.

### Suppressions are compiled into the binary

Both suppression lists are generated at configure time into
`__lsan_default_suppressions` / `__tsan_default_suppressions` hooks rather than
passed through `LSAN_OPTIONS`/`TSAN_OPTIONS`. Two reasons:

1. Those variables are parsed as `key=value:key=value` and **cannot express a
   path containing a space**. This repository lives under
   `.../Computer Science/loom`, which made the env-var approach a hard parse
   error with no escaping mechanism available.
2. Nobody has to remember to export anything. CI, Docker, and a developer
   running the binary by hand all behave identically.

Explicit env vars still override the built-in defaults for one-off
investigations.

One implementation note worth recording: these hooks must be compiled into every
*executable*, not into a static library. The sanitizer runtime resolves them as
weak symbols, so nothing ever references them — from inside a static archive the
linker simply never pulls the member in, and the suppressions are silently
ignored while appearing to be configured correctly.

### The leak canary

A suppression is only as good as its scope. One that matched too broadly would
switch off leak detection for Loom's own code, and every ASan run would go green
for the wrong reason with nothing to indicate it.

So `tests/leak_canary.cpp` leaks 4321 bytes on purpose, from a binary carrying
the same embedded suppressions the real binaries use. CTest marks it `WILL_FAIL`
— a *passing* canary is the failure condition.

```
Direct leak of 4321 byte(s) in 1 object(s)
Suppressions used:
      count      bytes template
          2        352 libonnxruntime.so
SUMMARY: AddressSanitizer: 4321 byte(s) leaked in 1 allocation(s).
```

ORT's 352 bytes suppressed, our 4321 caught.

Making it leak *honestly* took three attempts, each a real failure mode:

1. LSan classified the block as reachable, because the pointer was still live in
   a stack slot when the process exited.
2. After obfuscating the pointer, clang deleted the `malloc` outright at `-O2` —
   the address never escaped the function, so the allocation was dead code.
3. It now stores through a `volatile` global to force the escape, XORs the
   address, scrubs the stack, and compiles at `-O0 -fno-builtin`.

## Build layout

Loom targets Linux. On Windows the supported path is WSL2, **not** MSVC: MSVC
ships AddressSanitizer but has no ThreadSanitizer, and the sanitizer runs are a
first-class deliverable here. A Windows-native build would have silently cost a
headline correctness claim.

Every preset has a `wsl-` twin that is identical except that build output moves
to `$HOME/loom-build/` on the Linux filesystem. This is not a style preference.
Measured on the development machine:

| Operation | ext4 (native) | `/mnt/c` (9p) | Penalty |
|---|---|---|---|
| 500 small file writes | 0.029s | 3.371s | **116×** |
| `git clone` (nlohmann/json) | 1.385s | 30.76s | **22×** |

A CMake build with FetchContent is precisely that workload — five dependency
clones plus thousands of object writes. Source stays on `/mnt/c` so Windows-side
git and editors keep working; only build output moves.

## Dependencies

CMake FetchContent rather than vcpkg: no bootstrap step in CI, one file to read,
and every version visibly pinned in one place. hiredis is the exception and
comes from apt, because building it under redis-plus-plus through FetchContent
is the known friction point in this dependency set.

ONNX Runtime is a SHA256-pinned prebuilt tarball. Building it from source, or
through the vcpkg port which also builds from source, would take hours and
consume a large fraction of the project's time budget for no added signal.

`prometheus-cpp` is built with `ENABLE_PULL=OFF`. Its pull mode embeds civetweb,
an entire second HTTP server; since cpp-httplib is already in the process,
`/metrics` is served from there and prometheus-cpp is used purely as a registry
plus `TextSerializer`.

### A redis-plus-plus packaging bug

`redis-plus-plus` configure-generates `sw/redis++/hiredis_features.h` into its
build tree, but the interface include directories it exports point only at the
source tree and a not-yet-existent install prefix. Consumers therefore fail to
compile with `hiredis_features.h: file not found`.

`cmake/Dependencies.cmake` adds the generated header's directory back, wrapped
in `$<BUILD_INTERFACE:...>` — required because the target is exported, and CMake
rejects a bare build-directory path in an exported target's includes.
