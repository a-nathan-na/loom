# Loom

A model-serving inference engine in C++20 — real ONNX Runtime inference behind a
dynamic batcher, a Redis-backed queue spanning processes and hosts, an
autoscaling worker pool, and Prometheus metrics.

Built along the lines of Triton's serving layer, where the hard problems are not
in the model but around it: queueing, batching under a latency budget, spreading
work across workers, and surviving a worker that dies mid-batch.

> **Status: M0 of 6.** Build system, dependencies, sanitizers, and CI are green.
> The serving path lands in M1–M3 — see [Roadmap](#roadmap).

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
never terminate HTTP. A worker on another host is the same binary with a
different `REDIS_URL`.

## Design decisions

- **Batching is worker-side** — requests coalesce globally across every gateway,
  and the Redis consumer group *is* the load balancer rather than a component to
  write. The scheduling core is a deadline-aware drain loop.
- **Redis Streams over a `BLMOVE` list queue** — `XAUTOCLAIM` gives crash
  recovery and `XINFO GROUPS`→`lag` feeds the autoscaler; a list would mean
  hand-rolling both.
- **Delivery is at-least-once**, stated rather than papered over. Inference is
  idempotent, so a reclaimed duplicate is safe.
- **The worker pool is hand-rolled** because it autoscales — resetting an
  off-the-shelf pool would drop in-flight batches.
- **One shared `Ort::Session`, `intra_op_num_threads=1`** — parallelism lives at
  the batch level instead of oversubscribing the CPU K×T ways.

Full rationale, including rejected alternatives:
[docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md).

## Quick start

Linux, or WSL2 on Windows — **not** MSVC, which has no ThreadSanitizer.

```bash
sudo apt-get install -y clang-18 cmake ninja-build libhiredis-dev libssl-dev zlib1g-dev
./scripts/fetch_onnxruntime.sh     # SHA256-pinned prebuilt ORT

cmake --preset release
cmake --build --preset release
ctest --preset release
./build/release/src/loom-gateway --selftest
```

Presets: `release` (warnings-as-errors), `debug`, `asan` (+UBSan), `tsan`. Each
has a `wsl-` twin that moves build output off `/mnt/c`, measured ~116× faster
for small-file writes.

## Correctness

ASan + UBSan and TSan both run clean in CI on every push.

TSan excludes ONNX Runtime deliberately — the prebuilt library is uninstrumented,
so it reports races that are neither real nor fixable. A unit test and an `ldd`
check keep that exclusion honest. ASan's one suppression covers a genuine leak
*inside* ORT, and a deliberately-leaking canary test proves that suppression is
still narrow enough to catch Loom's own leaks.
[Details](docs/DESIGN_DECISIONS.md#sanitizer-strategy).

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
