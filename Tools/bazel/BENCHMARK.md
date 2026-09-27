<!-- markdownlint-disable MD013 -->

# Container build benchmark - 27 September 2026

Measured commit: `b94769f09fc0440cfb8c781ecf498e13f9d6377c`. These are build and test-workflow timings on this Mac. They do not measure container startup, VM throughput or release performance.

## Results

| Scenario | Trials | Median wall time | Observed range |
| --- | --- | --- | --- |
| Complete build, unchanged inputs | 5 | 1.04 s | 1.02-1.04 s |
| 25 container/helper suites, cached | 5 | 1.06 s | 1.05-1.11 s |
| 91 container/dependency suites, cached | 5 | 1.10 s | 1.10-1.11 s |
| CLI code edit, complete build requested | 3 | 3.31 s | 3.14-3.62 s |
| One unit-test code edit, all 25 container suites requested | 3 | 3.33 s | 3.29-3.48 s |
| Execute all 25 container/helper suites, cached results disabled | 3 | 26.94 s | 26.38-29.15 s |

All trials succeeded. Warm runs performed only Bazel bookkeeping: no compilation, linking or generation. A CLI code edit compiled and linked only the CLI. A unit-test code edit compiled and linked only ContainerVersionTests and ran that one suite; the other 24 suites were cached. No external Swift, C or Go dependency libraries recompiled in any benchmark trial.

## Shared-library changes

Adding a new internal function to ContainerVersion took **22.51 seconds**: 22 Swift compile actions and seven links were required across its container dependents. The next two trials changed only that function's returned value and took **4.76 and 4.72 seconds**. These are different invalidation cases and should not be combined into a single comparable median. External dependencies and the Go helper were reused.

Necessary dependent rebuilds still occur when a shared module changes. The improvement demonstrated here is isolation of unrelated dependencies and tests, not elimination of all dependent work.

## Method

- Apple M5 Pro, 24 GiB memory, macOS 27.0 (26A428); exact Swift/Xcode fingerprints are retained in metadata.json.
- Bazel 8.8.0, debug configuration, macOS 15 deployment target, six build jobs and two concurrent tests.
- Existing persistent SSD output and disk caches; Bazel server already running. No cache cleaning, service installation or container launch.
- Five measured repetitions for each unchanged-input scenario; three repetitions for each source/test edit and for uncached container tests.
- Wall time uses a monotonic clock and includes launcher checks, hashing, Bazel execution, logging and copying test reports.
- Temporary code changes added a private CLI marker, an internal library function, or an always-passing test assertion. Each source file was restored byte-for-byte afterward.
- Separate comment-only experiments took medians of 2.61 s for CLI input changes, 2.44 s for library input changes and 2.65 s for test input changes. Each recompiled one module; identical resulting output allowed downstream work and test results to remain cached.
- Final verification after restoration passed all 91 suites from cache, and the working tree was clean before this report was added.

These are local warm/incremental measurements, not cold-build results or a comparison with the previous build system. Background load and thermal state were not controlled. Host-dependent, runtime integration and upstream skipped checks retain the limits described in [QUALIFICATION.md](QUALIFICATION.md).

## Reproduction and evidence

Retained directory:

`/Users/sclarke/Library/Application Support/ContainerFamily/retained/container-only/benchmarks/20260927T104404Z`

The directory contains benchmark.py and code_benchmark.py, raw results.json, summary.json, metadata.json, per-command logs, original source copies and timings.xml. Every result links to the existing durable Bazel events and test reports. The scripts require a clean checkout and restore their temporary source changes in finally blocks. Copy both scripts to a new evidence directory before rerunning, and run benchmark.py before code_benchmark.py. Identical code variants may hit the disk cache on a later rerun; choose new marker/function values when measuring fresh compilation rather than cache replay.

The measured commands use Tools/bazel/run.sh with the same targets as `make bazel-build`, `make bazel-test` and `make bazel-test-all`. The uncached execution case adds `--nocache_test_results`; it preserves compiled artifacts.
