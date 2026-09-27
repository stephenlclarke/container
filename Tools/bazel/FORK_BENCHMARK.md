<!-- markdownlint-disable MD013 -->

# Container forks compared with Apple

Measured locally on 27 September 2026. The largest repeatable runtime difference was archive extraction: the fork took 2.06 times as long on the same Apple archive tests. Forced compilation of the seven shared container executables took 13.52 seconds for Apple and 39.69 seconds for the fork. Cached builds remained below 0.3 seconds in both lanes, excluding the normal launcher's evidence-collection overhead.

The comparison completed with one known functional mismatch: the fork intentionally accepts container names up to 255 bytes, while an Apple test requires rejection beyond 63 characters. That test remains failed in the evidence and the benchmark command returns a nonzero result. No measured paired performance fixture reached the 10-times slowdown threshold.

## Revisions and scope

| Repository | Fork revision | Apple comparison | Treatment |
| --- | --- | --- | --- |
| container | `2b4255631681e8e41cdc243f8f61c40348e18cc1` | `57f0b9392bbee1998e6c7f3f25db222fe1dcdd12` | Seven common executables; eight identical Apple test suites |
| containerization | `51bf8a10e2036861f87ccdf2fd881a8726c534d2` | `b44e17e1a4c135bc0168e615bf6a8e3798d070c0` | macOS libraries; four identical Apple test suites |
| container-builder-shim | `016040197215684db474181b444767eb58797cfa` | `5dc4286e5adbeb7dac189b22b7d5aab336942fe2` | Linux arm64 cross-build; shared prefetch tests and benchmarks |
| container-engine-api | `48e44d74d738ca3d24351ba02c4869be1a3e6998` | No Apple counterpart | Original project; no invented comparison |
| swift-nio-ssl | `322f3c2a4a21df31c84ca416bf65ee5e9059e440` | Same Apple commit | Active build already uses Apple code |

The Apple comparisons are each fork's matching Apple ancestor. They are not a moving latest-release baseline. Other Swift dependencies in the reduced graph are already upstream packages. The same-repository Go semantic helper and fork-only engine executable have no Apple counterpart and are excluded from paired product timing. Compose, devcontainer and other family repositories remain outside this scope.

The standalone containerization comparison holds all dependency pins constant. Container's Apple source cannot build against the forked containerization API: `CIDRv4` became optional. The complete container comparison therefore uses Apple's declared containerization `0.45.0` commit `9eacc197d7c3663eb29cbab6d51244ede6d1cd7d` on the Apple side and the pinned fork on the fork side. All other Swift pins match. Container timings consequently include that dependency pairing; the separate containerization results isolate the lower layer. Builder Linux builds retain each revision's own vendored dependency lockfiles; its prefetch benchmarks use the same Go standard library and test sources.

## Build and command timings

| Fixture | Apple seconds | Fork seconds | Fork / Apple |
| --- | ---: | ---: | ---: |
| Container source recompile | 13.520 | 39.689 | 2.94x |
| Container cached build | 0.150 | 0.259 | 1.73x |
| Containerization source recompile | 11.783 | 13.544 | 1.15x |
| Containerization cached build | 0.181 | 0.146 | 0.80x |
| Builder source recompile | 0.754 | 0.740 | 0.98x |
| Builder cached Linux build | 0.187 | 0.185 | 0.99x |
| CLI run --help | 0.089 | 0.143 | 1.60x |
| CLI --version | 0.047 | 0.049 | 1.04x |

Recompiles are single observations after adding a unique, harmless comment to every production Swift/Go source in the component. Original bytes are restored and verified afterward. Dependencies stay warm. These measure component compilation, not a clean build, semantic edit, or complete relink. The final containerization sample uses distinct markers per lane to prevent cross-lane disk-cache reuse; both lanes executed all ten Swift compilation actions. Container executed 32 Apple and 36 fork Swift compilation actions. Its additional code and features increase compilation cost.

Cached build and test values are medians of three sequential trials, alternating lane order. CLI values are medians of eleven process launches. The first fork help invocation took 0.963 seconds; the full sample is retained. Build timings invoke pinned Bazel directly and exclude the normal launcher's storage/provenance preflight, so they must not be compared directly with the earlier end-to-end launcher benchmark. Initial repository import, downloads and cache preparation are retained separately and excluded from speed ratios.

## Identical test workloads

| Layer | Apple seconds | Fork seconds | Fork / Apple | Result |
| --- | ---: | ---: | ---: | --- |
| ContainerizationArchiveTests | 18.236 | 37.619 | 2.06x | Pass |
| ContainerizationEXT4Tests | 1.794 | 1.688 | 0.94x | Pass |
| ContainerizationExtrasTests | 2.178 | 2.119 | 0.97x | Pass |
| ContainerizationOCITests | 1.264 | 1.232 | 0.97x | Pass |
| ContainerBuildTests | 1.164 | 1.326 | 1.14x | Pass |
| ContainerNetworkServerTests | 1.164 | 1.160 | 1.00x | Pass |
| ContainerOSTests | 2.236 | 2.276 | 1.02x | Pass |
| ContainerPersistenceTests | 1.133 | 1.236 | 1.09x | Pass |
| ContainerResourceTests | 1.137 | 1.601 | Not a passing-workload comparison | Name-length contract mismatch; one fork sample only |
| DNSServerTests | 0.672 | 0.645 | 0.96x | Pass |
| SocketForwarderTests | 0.551 | 0.557 | 1.01x | Pass |
| TerminalProgressTests | 1.503 | 1.398 | 0.93x | Pass |
| Builder prefetch tests | 22.277 | 22.028 | 0.99x | Pass |

Both containerization versions passed the same 450 tests per run. Both container versions were given the same 406 Apple tests: Apple passed all; the fork passed 405 and failed the documented naming-contract assertion. The failed fork suite was not retried. Other container suites were measured three times. Fixture files, including resources, match byte-for-byte: 41 containerization files, 38 container files and six builder test files. The earlier qualification of the fork's own test suites remains separate.

The archive difference is concentrated in `ArchiveReaderTests.extractDeepNesting()`. The fork adds a second directory traversal to restore directory attributes after extraction; this is a plausible contributor, not a profiler-proven attribution. The full archive suite measured 17.56-18.44 seconds for Apple and 37.25-37.88 seconds for the fork. No optimization or product-source changes were made during this comparison.

## Fixed-work builder performance

Each trial performs exactly 1,024 reads of 4 KiB against the same 10 MiB synthetic reader with a two-millisecond backing-read delay. Random access uses seed 42. Results are medians of three trials with the same Go 1.25.9 compiler. These are host-side component benchmarks, not complete image-build throughput.

| Operation | Apple microseconds / read | Fork microseconds / read | Fork / Apple |
| --- | ---: | ---: | ---: |
| DirectReaderAt | 2494.09 | 2495.86 | 1.001x |
| DirectReaderAtRandom | 2494.46 | 2494.52 | 1.000x |
| PrefetcherRandom | 5058.92 | 5037.42 | 0.996x |
| PrefetcherSequential | 93.78 | 96.45 | 1.029x |

The fixed-work results show broadly similar prefetch performance. An earlier adaptive Go run selected different iteration counts and produced an apparent sequential advantage; it is retained as exploratory evidence and is not used for the conclusion. This short sequential workload does not exercise repeated full-buffer wraparound or real registry/network conditions.

## Environment and limitations

Apple M5 Pro, 18 CPU cores, 24 GiB RAM, macOS 27.0 build 26A428. Bazel 8.8.0, Swift debug configuration, macOS 15 deployment target, six compilation jobs and one test process at a time. Exact compiler strings, binary hashes, source/fixture hashes and dependency pins are retained in the metadata. Measurements run sequentially on the local machine using monotonic wall time. JUnit and JSON retain every completed fixture, failure and timeout. A timeout, failed fixture, or any paired trial at least ten times slower produces a failure; ordinary smaller slowdowns remain informational.

Apple's top-level `container --help` queries the installed service and exceeded the ten-second limit six times before the exploratory loop was stopped. Those failures remain in `20260927-container-matched`; command-specific `container run --help` is the independent, service-free comparison above. The initial incompatible dependency experiment remains in `20260927-container-run`. Neither failure has been converted into a pass.

No installed daemon, VM, kernel/init image or builder image was replaced or launched. VM startup, actual container execution, registry transfers, full image builds, Linux guest execution, release-mode performance and memory usage were not benchmarked. This is component/build evidence, not end-to-end runtime qualification.

## Reproduce and evidence

```sh
make bazel-fork-benchmark
# Or select one repository:
make bazel-fork-benchmark BENCHMARK_ARGS="--component containerization"
```

The standalone script also exposes `--help`. A fresh run creates source archives under the enrolled SSD, checks the pinned Bazel executable, uses identical Apple fixtures and retains logs on internal storage. It never edits the original repository checkouts. Unique compile markers prevent previous benchmark results from satisfying forced compilation through the disk cache. Temporary sources are restored, and task-owned Bazel servers are shut down.

Evidence root: `~/Library/Application Support/ContainerFamily/retained/container-only/fork-comparison`.

- `20260927-containerization`: repeated library tests and cached builds.
- `20260927-containerization-recompile`: final compilation sample with no cross-lane source cache hits.
- `20260927-container-local`: seven-product build, local CLI timings and identical Apple tests.
- `20260927-builder`: Linux builds, shared prefetch tests and exploratory adaptive measurements.
- `20260927-builder-fixed`: final equal-operation prefetch comparison.
- `source-audit.json`: fixture equality and restored source verification.
- Each directory retains its executed script, metadata, logs, monotonic durations, JSON matrix and JUnit. Source archives and reusable compiler outputs remain on the SSD for reproduction; they are owned by this benchmark, not installed products.
