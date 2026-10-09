<!-- markdownlint-disable MD013 -->

# Container-related forks versus upstream

Updated locally on 27 September 2026 after synchronizing the five relevant forks. Containerization archive tests still take about 2.05 times as long in the fork. Container source recompilation takes about twice as long; unchanged builds remain below a third of a second in the measured medians. No paired timing reached the 10-times regression threshold.

Two functional differences remain explicit failures when running identical upstream tests: the container fork accepts longer names, and the SSL fork reports a different TLS alert for three rejected-certificate cases. These failed suites are excluded from passing-workload speed claims. The comparison command returns nonzero and retains both failures; the normal fork-specific validation separately passed.

## Interpretation correction

The follow-up [performance diagnosis](PERFORMANCE_DIAGNOSIS.md) found that one deep-nesting test dominates the debug archive suite. That test takes only 29 ms for Apple and 46 ms for the fork when optimized. The seconds-long suite timings below must not be used as general production archive throughput. The forced compilation comparison deliberately changes every component Swift file; ordinary incremental builds have a smaller scope. Short command timings also include the original timeout-polling delay, now fixed in the harness. Original measurements remain below for traceability; corrected runtime results and causal experiments are in the diagnosis.

## Source revisions

| Repository | Fork | Upstream main |
| --- | --- | --- |
| container | `193be5b77294d79c4120aa486603840508ded794` | `4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c` |
| containerization | `f58053cc72dc5dfae419bfc1667220b35b61a1a1` | `bc994b88df46207fad7775b0eabc51947e315881` |
| container-builder-shim | `016040197215684db474181b444767eb58797cfa` | `5dc4286e5adbeb7dac189b22b7d5aab336942fe2` |
| swift-nio-ssl | `17ab11cd2dac5cfc4760a37cb2e0f955d7629439` | `322f3c2a4a21df31c84ca416bf65ee5e9059e440` |
| grpc-swift-nio-transport | `bb91b124b6f20cf82edec4b379bdcf8838f98343` | `ff4420d7c33cc998a590b0761630d67f76bc291e` |

The first four upstream repositories belong to Apple; gRPC transport is maintained under the gRPC organization. These are fixed, verified upstream main commits. The table records measured revisions. Containerization main subsequently received an integration-test-only API migration and documentation update; its production library and guest sources remain identical to the measured commit. The original container-engine-api project has no upstream fork relationship. Other family applications are outside this comparison.

## Build timings

| Component | Upstream recompile (s) | Fork recompile (s) | Fork/upstream | Upstream cached (s) | Fork cached (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| container | 13.707 | 27.397 | 2.00x | 0.185 | 0.242 |
| containerization | 11.631 | 13.031 | 1.12x | 0.143 | 0.147 |
| swift-nio-ssl | 3.327 | 2.848 | 0.86x | 0.184 | 0.186 |
| grpc-swift-nio-transport | 4.510 | 6.521 | 1.45x | 0.186 | 0.181 |
| container-builder-shim (unchanged inputs) | 0.754 | 0.740 | 0.98x | 0.187 | 0.185 |

Recompiles are single observations after adding distinct harmless comments to production Swift sources (Go sources for the builder). Dependencies and C libraries stay warm; original bytes are restored afterward. These are component compilation timings, not clean builds. Cached values are medians of three alternating, serial trials and exclude the normal launcher's evidence/storage preflight. Initial imports/builds are retained but excluded from performance ratios. Small single-sample differences do not establish a repeatable optimization.

The builder revisions and fixtures did not change, so its earlier same-day measurements are retained rather than rebuilt unnecessarily.

## Identical upstream test workloads

| Component / fixture | Upstream (s) | Fork (s) | Fork/upstream | Result |
| --- | ---: | ---: | ---: | --- |
| container / ContainerBuildTests | 1.200 | 1.322 | 1.10x | Pass |
| container / ContainerNetworkServerTests | 1.046 | 1.152 | 1.10x | Pass |
| container / ContainerOSTests | 2.230 | 2.288 | 1.03x | Pass |
| container / ContainerPersistenceTests | 1.149 | 1.258 | 1.10x | Pass |
| container / ContainerResourceTests | 1.154 | 1.694 | Not a passing comparison | Name-length contract differs |
| container / DNSServerTests | 0.621 | 0.672 | 1.08x | Pass |
| container / SocketForwarderTests | 0.512 | 0.614 | 1.20x | Pass |
| container / TerminalProgressTests | 1.415 | 1.433 | 1.01x | Pass |
| containerization / ContainerizationArchiveTests | 18.356 | 37.705 | 2.05x | Pass |
| containerization / ContainerizationEXT4Tests | 1.761 | 1.734 | 0.98x | Pass |
| containerization / ContainerizationExtrasTests | 2.192 | 2.152 | 0.98x | Pass |
| containerization / ContainerizationOCITests | 1.282 | 1.200 | 0.94x | Pass |
| grpc-swift-nio-transport / GRPCNIOTransportCoreTests | 5.516 | 5.526 | 1.00x | Pass |
| grpc-swift-nio-transport / GRPCNIOTransportHTTP2Tests | 2.494 | 2.484 | 1.00x | Pass |
| swift-nio-ssl / NIOSSLTests | 18.609 | 19.117 | Not a passing comparison | Three TLS alert assertions differ |

Passing suites ran three times per lane. A failed lane/fixture was not retried; its single failure remains visible. The source audit confirms byte-identical test fixtures in both lanes: 41 containerization files, 38 container files, 20 SSL files, and 67 gRPC files. All temporary production-source changes were restored.

SSL's own suite explicitly accepts the fork's `BAD_CERTIFICATE` alert; the unmodified upstream suite expects `UNKNOWN_CA` or `CERTIFICATE_UNKNOWN`. Both reject the peer certificate. In this captured run, the container fork's 255-byte name limit differed from Apple's 63-character assertion. Neither difference was changed to obtain a green comparison.

- Resolution after this captured run: restore the 63-byte native ID limit because IDs are used as DNS hostname labels.
- The focused `ContainerResourceTests` suite passes with the 63/64 boundary regression.
- The historical failure record remains unchanged; rerun the comparison before claiming compatibility.

The archive difference remains concentrated in the deep-nesting extraction test. The fork's second traversal to restore directory attributes is a plausible contributor, not a profiler-proven attribution. These timings measure the stated test workloads, not general TLS, RPC, or archive throughput.

## Commands and unchanged builder workloads

- `cli-run-help`: upstream 0.078s, fork 0.133s (1.69x), median of eleven launches.
- `cli-version`: upstream 0.041s, fork 0.041s (1.02x), median of eleven launches.

The unchanged builder benchmark performs 1,024 reads of 4 KiB against the same 10 MiB reader, using seed 42 for random access and a two-millisecond backing delay. Median microseconds/read, upstream/fork: direct 2494.09/2495.86; direct random 2494.46/2494.52; prefetch random 5058.92/5037.42; prefetch sequential 93.78/96.45. These show similar host-side prefetch performance and do not represent registry transfer or full image-build throughput.

## Method and evidence

Apple M5 Pro, 24 GiB RAM, macOS 27.0 build 26A428; Bazel 8.8.0, Swift debug configuration, six compiler jobs, one test process at a time. Monotonic wall-clock durations, commands, source/fixture hashes, dependency pins, JUnit, failures and raw logs are retained. Library comparisons hold third-party pins constant. Container pairs use their corresponding containerization revisions; its whole-product timings therefore include that dependency pairing. Builder uses each source revision's vendored lockfiles and the same Go 1.25.9 compiler.

Fresh four-component evidence: `~/Library/Application Support/ContainerFamily/retained/container-only/upstream-sync/20260927T123656Z/paired-results`. Fixture/source verification: adjacent `paired-source-audit.json`. Unchanged builder evidence: `retained/container-only/fork-comparison/20260927-builder` and `20260927-builder-fixed`. The previous report is preserved in Git history and adjacent `previous-FORK_BENCHMARK.md`.

Use `make bazel-fork-benchmark` for a complete paired run or `BENCHMARK_ARGS="--component swift-nio-ssl"` for one component. To execute fresh fork measurements for all five components while reusing the published Apple stock measurements, pass `BENCHMARK_ARGS="--reuse-reference --measure-all-candidates"`. This validates all historical source, workload, toolchain and host inputs, allowing only the exact host-test patch/native verifier transitions and the two recorded lane-selection AST revisions. It prepares and executes only fork lanes, retains historical stock rows separately, and records all five components and admission digests in the measurement provenance. To continue a partial candidate run, repeat `--candidate-component` for the selected forks with `--reuse-reference`; the report names and measures only those selections. The default `--reuse-reference` mode measures only source revisions that differ from the authenticated reference. The known shared-test contract differences intentionally keep the all-five command nonzero. Normal layer tests remain separate. [Runtime benchmarks](RUNTIME_BENCHMARK.md) cover optimized VM/container operations with exact stack fingerprints.
