# Loom

A model-serving inference engine in C++20 — real ONNX Runtime inference behind a
dynamic batcher, a Redis-backed queue that spans processes and hosts, an
autoscaling worker pool, and Prometheus metrics.

Loom is built along the lines of Triton Inference Server's serving layer: the
interesting problems are not in the model, they are in everything around it —
how requests are queued, how they are grouped into batches without blowing a
latency budget, how work is spread across workers, and what happens when a
worker dies mid-batch.

> **Status: M0 complete.** The build system, dependency graph, sanitizer
> configurations, and CI are in place and green. The serving path itself lands
> in M1–M3. See [Roadmap](#roadmap) for what is and is not implemented.

## Architecture

```
 client ──HTTP──> loom-gateway ──XADD──> Redis Stream `loom:requests`
                       │                        │
                       │                  XREADGROUP (consumer group `loom:workers`)
                       │                        ├──> loom-worker #1  [N inference threads]
                       │                        ├──> loom-worker #2   shared Ort::Session
                       │                        └──> loom-worker #3   + reaper + autoscaler
                       │                                    │
                       └<──BLPOP loom:resp:{id}──── LPUSH ──┘  then XACK
```

The gateway terminates HTTP and never runs inference; workers run inference and
never terminate HTTP. That split is what makes multi-node real rather than
cosmetic — a worker on another host is the same binary with a different
`REDIS_URL`.

### Design decisions worth calling out

**Batching happens worker-side, not gateway-side.** Requests are enqueued
individually and the worker assembles batches. This coalesces requests globally
across every gateway instead of per-gateway, and it means the Redis consumer
group *is* the load balancer — distributing work across workers stops being a
component to write and becomes a property of the queue. `XREADGROUP COUNT=n
BLOCK=t` also degrades gracefully for free: under a trickle it returns a batch
of one immediately.

`BLOCK` alone under-batches at medium load, so the core scheduling logic is a
**deadline-aware drain loop** — after a first partial read, keep issuing short
reads until the batch is full or `max_wait_ms` has elapsed. Each request also
carries an absolute deadline, and a worker drops already-expired requests before
spending compute on them.

**Redis Streams over a `BLMOVE` reliable-list queue.** Streams give a
per-consumer pending list, `XAUTOCLAIM` for reclaiming work stranded by a dead
worker, and `XINFO GROUPS`→`lag` as a ready-made queue-depth signal for the
autoscaler. The list pattern would mean hand-rolling all three.

**Delivery is at-least-once, not exactly-once.** `XACK` happens after the
response is published, so a worker that dies mid-batch leaves its entries
recoverable. A reclaimed request may be inferred twice; inference is idempotent,
so this is safe — but it is a real property of the system, not a detail to
paper over.

**The worker pool is hand-rolled rather than a thread-pool library.** The queue
lives in Redis, so this is not a task-queue pool — it is N long-lived loops with
*dynamic membership*, since the pool autoscales. `BS::thread_pool::reset()`
tears down and recreates the whole pool, which would drop in-flight batches.
Hand-rolling buys cooperative scale-down, where a retiring thread finishes its
batch and acks before exiting.

**One shared `Ort::Session` with `intra_op_num_threads=1`.** ORT explicitly
supports concurrent `Run()` calls on a single session, and per-thread sessions
would multiply memory for no gain. Parallelism lives at the batch level; letting
ORT also parallelise inside each operator would oversubscribe the CPU K×T ways.

## Building

Loom targets Linux. On Windows, use WSL2 — **not** MSVC: MSVC ships
AddressSanitizer but has no ThreadSanitizer, and the sanitizer runs are a
first-class deliverable here.

```bash
sudo apt-get install -y clang-18 cmake ninja-build libhiredis-dev libssl-dev zlib1g-dev
./scripts/fetch_onnxruntime.sh          # SHA256-pinned prebuilt ORT into third_party/

cmake --preset release
cmake --build --preset release
ctest --preset release
./build/release/src/loom-gateway --selftest
```

### Presets

| Preset | Purpose |
|---|---|
| `release` | RelWithDebInfo, warnings-as-errors, real inference |
| `debug` | Debug symbols, no sanitizer |
| `asan` | AddressSanitizer + UBSan, real inference |
| `tsan` | ThreadSanitizer; inference stubbed (see below) |

Each has a `wsl-` twin (`wsl-release`, `wsl-tsan`, …) that is identical except
the build directory moves to `$HOME/loom-build/` on the Linux filesystem. This
is not a style preference. Measured on the development machine, `/mnt/c` over
9p is **~116× slower for small-file writes** and **~22× slower for `git clone`** —
and a CMake build with FetchContent is precisely that workload. Source stays on
`/mnt/c` so Windows-side git and editors keep working; only build output moves.

### Sanitizers

`ctest --preset asan` and `ctest --preset tsan` both run clean.

The TSan preset sets `LOOM_FAKE_INFERENCE=ON`, which stubs inference out so
ONNX Runtime is never linked into the binary. This is deliberate: prebuilt ORT
is not compiled with `-fsanitize=thread`, so TSan cannot see its internal
synchronisation and reports races inside ORT's own thread pool that are neither
real nor fixable from here. Excluding it means TSan reports on exactly the code
we wrote — batcher, worker pool, autoscaler, metrics — where a race would be our
bug. For the case where you *do* want TSan over real inference,
[`tsan_suppressions.txt`](tsan_suppressions.txt) scopes the noise.

`ldd` on the TSan binary is checked to confirm `libonnxruntime` really is absent,
and a unit test asserts the stubbing flag matches the build configuration — so
this cannot silently regress.

The ASan preset hit the same class of problem one layer down: LeakSanitizer
reports a genuine leak of 176 bytes × 2 of process-global state that ONNX
Runtime allocates per `Ort::Env` and never frees.
[`lsan_suppressions.txt`](lsan_suppressions.txt) scopes that to
`libonnxruntime` only.

Suppressions are **compiled into the binary** through
`__lsan_default_suppressions` / `__tsan_default_suppressions`, generated from
those two `.txt` files at configure time, rather than passed via
`LSAN_OPTIONS`/`TSAN_OPTIONS`. Two reasons: those variables are parsed as
`key=value:key=value` and cannot express a path containing a space (this repo
lives under `.../Computer Science/loom`), and nobody has to remember to export
anything for CI, Docker, and local runs to behave identically. Explicit env vars
still override them.

A suppression is only as good as its scope, so scope is tested. `loom_leak_canary`
leaks 4321 bytes on purpose from a binary carrying the same embedded
suppressions, and CTest marks it `WILL_FAIL` — a *passing* canary is the failure
condition. It currently reports:

```
Direct leak of 4321 byte(s) in 1 object(s)
Suppressions used:
      count      bytes template
          2        352 libonnxruntime.so
SUMMARY: AddressSanitizer: 4321 byte(s) leaked in 1 allocation(s).
```

ORT's leak suppressed, ours caught. If the suppression ever grows broad enough
to hide Loom's own leaks, that test goes green and CI fails.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M0 | Scaffolding, CMake, pinned deps, sanitizer presets, CI | done |
| M1 | ONNX model prep + single-threaded real inference over HTTP | next |
| M2 | Redis Streams queue + deadline-aware dynamic batching | |
| M3 | Worker thread pool, crash recovery, docker compose | |
| M4 | Autoscaling on queue lag and latency | |
| M5 | Prometheus metrics + Grafana dashboard | |
| M6 | Load-test harness, benchmark report, sanitizer runs | |

## License

MIT
