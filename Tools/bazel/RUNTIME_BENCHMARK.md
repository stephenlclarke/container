<!-- markdownlint-disable MD013 -->

# Apple versus fork runtime speed

`make bazel-final` now finishes qualification with real runtime benchmarks. It checks the build tools, runs the 91 normal test suites, builds optimized Apple and fork executables, stages private signed installations, executes the same workloads and retains a comparison report. Ordinary per-layer tests remain separate and cached. Use `make bazel-runtime-benchmark` for the optimized runtime comparison alone.

## Follow-up: corrected timing and diagnosis

The benchmark now waits for child exit without the old timeout polling, which could add roughly 50 ms to short commands. The unchanged optimized binaries were remeasured over seven trials per lane, with nine reverse-order trials for startup/import. Startup/exit remained 174-219 ms slower and warm import 32-38 ms slower. Uncached builds, cached builds and image saving were close in the corrected run. The original table below remains historical; its short-command percentages are superseded. See [the full diagnosis](PERFORMANCE_DIAGNOSIS.md) for corrected results, the small-write import bottleneck, debug archive overhead, startup wait probes and build critical paths. Both corrected runtime checks and all 20 tool tests passed.

## Historical results: 27 September 2026, before timing correction

The refreshed runtime comparison passed after the upstream synchronization. The 91 normal suites and 17 focused tool tests also passed separately. Each number below is the median of three trials on an Apple M5 Pro with 24 GiB RAM, connected to power, running macOS 27.0 build 26A428. Lower times are better.

| Workload | Stock Apple | Fork | Fork / Apple |
| --- | ---: | ---: | ---: |
| Create, boot, run `true`, exit and remove container | 0.613 s | 0.738 s | 1.20x |
| Execute a command in a running container | 0.092 s | 0.094 s | 1.03x |
| SHA-256 of 128 MiB | 0.532 s | 0.472 s | 0.89x |
| Write and sync 64 MiB | 0.248 s | 0.248 s | 1.00x |
| Save image archive | 0.143 s | 0.092 s | 0.64x |
| Load an already present image | 0.081 s | 0.138 s | 1.71x |
| Image build without instruction cache | 0.716 s | 0.881 s | 1.23x |
| Cached image build | 0.198 s | 0.146 s | 0.74x |

In this run the fork's startup/exit took about 20% longer, uncached image builds 23% longer, and warm image import 71% longer. Cached image builds took about 26% less time and image saving 36% less. These observations do not establish repeatable improvements or regressions: workloads are short, there are three samples per lane, the fork runs before Apple, and host/image caches are warm. The development host is shared, without confidence intervals or thermal isolation. Retain the individual samples before drawing performance conclusions.

All workload commands succeeded; SHA-256, byte-count, warm-command and built-image contents were checked. The timing gate fails for any incomplete workload, nonzero exit, timeout, cleanup/restoration failure, or a corresponding trial taking at least ten times as long as Apple. Passing this gate does not mean equal performance.

## What is compared

The fork uses Bazel source checkpoint `6c23cd2e11b2f8c63312d38deea1d944c3e4e4f0`, including container main `193be5b77294d79c4120aa486603840508ded794`, containerization `f58053cc72dc5dfae419bfc1667220b35b61a1a1`, its matching retained vminit archive, and builder shim `016040197215684db474181b444767eb58797cfa`. Apple uses container `4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c`, its native containerization 0.47 revision `bc994b88df46207fad7775b0eabc51947e315881`, Apple vminit 0.47 and builder 0.13.1. Immutable OCI digests and signed executable hashes are in the fingerprints. These are pinned source comparisons. A subsequent containerization commit only migrates two integration-test pods to the new sizing API and updates documentation; it does not change the measured library or guest sources.

Both host stacks use optimized Bazel builds with the same build environment. Both use the same kernel from the source-recommended Kata 3.32.0 archive, the same immutable Alpine 3.22 image, one vCPU and 512 MiB for application containers, and two vCPUs with 2 GiB for builders. Application workloads have networking disabled. The kernel is the recommended debug variant in both lanes; host binaries are release builds.

Images are prepared before timing. Every startup trial creates a fresh VM with warm host/image caches. Image-load measures repeated import, not first import. Uncached builds disable instruction caching but retain the downloaded base image. The Dockerfile copies a deterministic payload and hashes it; every built image is run afterward to check the result. Registry downloads and setup are retained as operations but excluded from the speed table.

These runtime results compare complete stacks. They do not identify which repository causes a difference. [Individual fork/component comparisons](FORK_BENCHMARK.md) separately cover all five container-related forks: container, containerization, builder shim, Swift NIO SSL and gRPC NIO transport. Engine API has no stock Apple counterpart. The container-name and TLS-alert assertion differences in that separate report remain visible failures and are not waived by this runtime pass.

## Reproduction and safeguards

Run from this checkout:

```sh
make bazel-final
```

Evidence defaults to a fresh timestamped directory under `~/Library/Application Support/ContainerFamily/retained/container-only/runtime-benchmark`. `BENCHMARK_RUN` can select another unused name. Existing results are never overwritten. The source-revision stamp is explicitly inherited by the package importer and checked against the built CLI; benchmark data is recreated before staging a different build so old provider identities cannot be reused accidentally. Compiler caches are retained.

Before this upstream refresh, an unchanged optimized-build repeat completed in 1.513 seconds inside Bazel with 2,015 cached actions and one internal action; it performed no compilation.

The harness is specific to this enrolled Mac: it requires the enrolled SSD, pinned Bazel, the configured Steve Clarke signing identity, the retained matching fork guest archive, registry access and existing macOS authorization. It validates pins and checksums and does not automate consent. Stable installation paths and signing identifiers avoid creating a new executable identity for every trial.

Only marker-owned benchmark data is replaced. Apple hardcodes its service namespace, so the harness temporarily unloads inactive default registrations, preserves their plists, runs against a private application-data directory and restores the registrations afterward. It refuses to displace an active default service. Concurrent benchmark runs are locked out. No existing user containers or images are removed, and no release is installed or published.

## Retained evidence and limits

The current successful run is `20260927-upstream-refresh` under the evidence root. Its `acceptance.json` is true with no failures; `results.json`, `operations.json`, `matrix.json`, `matrix.md` and `timings.xml` retain measurements and validation. `source-inputs.json`, `assets.json`, `host.json` and both fingerprint files retain sources, dependencies, images and host details. `service-restoration.json` confirms restoration of all four original registrations. No benchmark service remained registered after completion.

Earlier evidence is preserved, including the previous successful `20260927-final3` baseline: `20260927` contains valid paired measurements but a cleanup check that ran before asynchronous unregistration finished; `20260927-final` stopped while replacing a read-only staged helper; `20260927-final2` records a startup timeout after a missing revision stamp changed the fork's provider identity. Those failures remain failures. The harness now waits for bounded unregistration, replaces read-only artifacts atomically, inherits/checks revision stamps and stages fresh benchmark data. An initial preflight also required an explicit application-root option; its correction record is retained in `20260927/preflight-correction.json`.

Seventeen focused tool tests plus the real end-to-end run verify the workflow. No Python coverage percentage or cloud Sonar result is claimed; signing, launchd and VM lifecycle paths are verified through the retained integration run. Journald/GELF sidecar archives, the separate full runtime-integration suite, published release packages and the pre-existing Homebrew installation are outside this benchmark's claims.

The matching optimized fork guest archive is retained at `retained/release/authorities/f58053cc72dc5dfae419bfc1667220b35b61a1a1/container-vminit-f58053cc72dc5dfae419bfc1667220b35b61a1a1-arm64.oci.tar`, SHA-256 `b9979eaa9af20f48390ec1765b07758e45360a0a693c769f4d65c6016760f235`. This local archive was exercised by the successful runtime benchmark. Publication to the matching GHCR tag was denied because the available credentials cannot write packages; no successful publication is claimed. The Linux guest binaries cross-compiled in debug and release, but their unit tests cannot compile because the installed musl SDK lacks Swift Testing. This runtime pass does not replace those missing guest unit tests.
