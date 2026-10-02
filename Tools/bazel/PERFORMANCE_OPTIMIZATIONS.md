# Container performance optimization results

Follow-up: [startup investigation, smaller guest helper and final measurements](STARTUP_OPTIMIZATIONS.md).

27 September 2026. Source changes are committed to the Stephen-owned container and containerization forks. Existing full preservation snapshots remain intact; this iteration also retains incremental Git recovery bundles.

## Outcome

Warm image import fell from 82 ms in the earlier corrected benchmark to 52 ms in the final run. Apple measured 50 ms. The deep archive debug regression fell from 36.035 seconds to 0.863 seconds (about 42 times faster). Most runtime workloads are now close to Apple in these fixtures; startup remains substantially slower. Docker startup and uncached builds remain faster.

## Final measurements

Seven trials per lane; medians in milliseconds, lower is better. Setup, downloads and first-use warmup are excluded. These are local workload results, not universal performance guarantees.

| Workload | Earlier fork | Final fork | Apple | Docker/Colima |
| --- | ---: | ---: | ---: | ---: |
| Start, run true and remove | 726 | 723 | 541 | 122 |
| Execute in a running container | 85 | 87 | 100 | 34 |
| Import an already loaded image | 82 | 52 | 50 | 282 |
| Save image | 106 | 101 | 109 | 235 |
| SHA-256 of 128 MiB | 474 | 475 | 469 | 419 |
| Write and sync 64 MiB | 209 | 199 | 193 | 190 |
| Build without cache | 871 | 720 | 737 | 304 |
| Cached build | 140 | 137 | 137 | 170 |

The earlier-fork column is a previous run on the same host, not a contemporaneous randomized control. Changes of a few percent are not evidence of a reliable speedup. Uncached builds varied considerably between runs; do not attribute their difference to the archive changes.

The additional nine-trial reverse-order comparison at the same production code measured startup at 728 ms for the fork versus 539 ms for Apple. Imports were 76 versus 76 ms. It confirms import parity and the remaining startup gap. A first reverse-order attempt encountered a temporarily active restored Homebrew service and failed closed; its incomplete results are excluded. The retry held original registrations aside until both lanes finished and restored them afterward.

## Retained changes and iterations

1. Archive input blocks grow from 4 KiB to the existing 4 MiB buffer size. Sparse-aware writes, ownership, hard links, permissions and stream errors are preserved. The Alpine extraction fixture now makes 65 writes instead of 7,318. Expanded regression coverage crosses two input-block boundaries, including a partial final block, with compressed and uncompressed archives.
2. Secure directory traversal parses components once and walks array slices. Descriptor lifetimes and no-symlink traversal remain unchanged. The deep archive debug test fell from 36.035 to 5.368 seconds; all affected archive and OS tests passed.
3. Directory metadata sorting caches depth once per entry. The same test fell again to 0.863 seconds. Deferred metadata and deepest-first ordering remain intact.
4. Launchctl output queries use termination events and drain stdout before waiting. Tests cover large output, nonzero status and launch failure. Full-stack measurements do not establish a reliable startup improvement from this change. Profiling shows registration now taking roughly 10–20 ms and runtime bootstrap taking roughly 580–688 ms in the diagnostic runs.
5. Main-branch CI builds publication guests in release mode. It previously selected debug mode before publishing the source-SHA image. Pull-request guests retain debug diagnostics; host unit-test configuration is unchanged.

A matched nine-trial optimized extraction comparison measured Apple at 12.30 ms and the final fork at 8.69 ms. This isolates extraction work; it is not a VM-start benchmark.

Rejected experiment: leaving reserved virtiofs shares unallocated until use preserved VM boot but did not materially close the startup gap (about 710 ms versus 730 ms in adjacent runs). It was reverted. All 16 runtime device slots, live-attachment behavior, security checks and durable lifecycle writes remain as before. The remaining startup gap is inside VM/bootstrap work; this experiment did not establish a single cause.

## Validation and source identity

- All 91 normal host suites passed at the final production Swift implementation. The 22 benchmark-tool tests passed, including cleanup races and precise subprocess timing. Workflow validation with actionlint passed.
- The subsequent publication-policy commit changes only workflow/documentation files in containerization; the corresponding container changes only its dependency pin/documentation. Saved source-equivalence checks show no Swift source or test changes after the 91-suite gate. The exact final pinned stack was rebuilt and exercised in the seven-trial runtime comparison above.
- Both Linux guest executables were built with the Swift 6.3 static aarch64 musl SDK in release mode. Every final runtime command, workload hash, build output and cleanup acceptance check passed. The SDK still lacks Swift Testing for executing the full Linux guest unit suite; host tests and runtime workloads do not substitute for that suite.
- Benchmark passes mean validated outputs and cleanup, not Apple/Docker speed parity. Startup parity has not been achieved.
- Source and benchmark commits are signed. No Apple/grpc upstream repository was pushed. Remote CI/image publication remains separate from local validation; source pushes alone are not proof that the exact guest image is downloadable.

Final source pins:

- `container`: `8e74e094ff6c2c369d2b0f089f0731bb7a7b2e74`
- `containerization`: `9d6324ad5ba4d6487677bd6236f4d92eb0ad9eb8`

Exact host binaries, guest archive, kernel, dependency revisions and workload image are recorded in `runtime-release-policy/*-fingerprint.json` and `assets.json`. The matching local guest archive is retained in `ContainerFamily/retained/release/authorities/9d6324ad5ba4d6487677bd6236f4d92eb0ad9eb8/`.

## Comparison limits

Host: Apple M5 Pro, 24 GiB RAM, macOS 27.0, on AC power. Apple and fork use optimized builds, the same pinned ARM64 Alpine image and kernel, 1 CPU/512 MiB workloads, and 2 CPU/2 GiB builders. Each startup launches a fresh dedicated VM. Docker uses client 29.8.1, Engine 29.2.1 and Colima 0.10.3 with a warm shared 4 CPU/8 GiB VM; workload limits are also 1 CPU/512 MiB, but its default builder shares the VM. Filesystem formats, kernels and storage implementations differ. Docker figures therefore compare practical product latency, not a common isolation architecture. CPU/disk workloads are much closer than startup.

Docker and Colima were already installed. Colima was initially stopped, started without changing the selected context or saved configuration, and stopped afterward. The unique benchmark container/result image were removed; downloaded base images and reusable build caches remain. Original container service registrations were preserved and restored. Task-only build servers are stopped after measurement; the normal Bazel cache is retained.

## Reproduce and evidence

Use `make bazel-test-all` for the host gate and `make bazel-runtime-benchmark` for the optimized Apple/fork comparison. Runtime Makefile targets now default to seven trials (`BENCHMARK_TRIALS`). With an idle running Colima engine, `make bazel-docker-benchmark DOCKER_CONTEXT=colima` runs the Docker reference. Use a fresh `BENCHMARK_RUN` for each invocation.

Raw evidence and recovery bundles: `/Users/sclarke/Library/Application Support/ContainerFamily/retained/container-only/optimizations/20260927T140031Z`.

Key folders: `runtime-release-policy` (final exact pins), `runtime-final` (same production code before the CI policy update), `runtime-reverse-final-retry` (order check), `archive-final` (focused extraction), `docker` (reference), `startup-profile` and `startup-phases` (diagnostics). Intermediate failures and the reverted candidate remain preserved; they are not counted as accepted results.
