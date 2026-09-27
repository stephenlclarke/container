<!-- markdownlint-disable MD013 -->

# Apple versus fork runtime speed

`make bazel-final` now finishes qualification with real runtime benchmarks. It checks the build tools, runs the 91 normal test suites, builds optimized Apple and fork executables, stages private signed installations, executes the same workloads and retains a comparison report. Ordinary per-layer tests remain separate and cached. Use `make bazel-runtime-benchmark` for the optimized runtime comparison alone.

## Results: 27 September 2026

The complete final run passed. Each number below is the median of three trials on an Apple M5 Pro with 24 GiB RAM, connected to power, running macOS 27.0 build 26A428. Lower times are better.

| Workload | Stock Apple | Fork | Fork / Apple |
| --- | ---: | ---: | ---: |
| Create, boot, run `true`, exit and remove container | 0.594 s | 0.803 s | 1.35x |
| Execute a command in a running container | 0.092 s | 0.095 s | 1.04x |
| SHA-256 of 128 MiB | 0.487 s | 0.476 s | 0.98x |
| Write and sync 64 MiB | 0.250 s | 0.253 s | 1.01x |
| Save image archive | 0.140 s | 0.092 s | 0.66x |
| Load an already present image | 0.090 s | 0.091 s | 1.02x |
| Image build without instruction cache | 0.707 s | 0.736 s | 1.04x |
| Cached image build | 0.192 s | 0.176 s | 0.92x |

Startup/exit is the clearest slowdown: approximately 35% in the final run and 45% in the first measurement. The other small differences should not be treated as established speed improvements or regressions. Image-save timings varied from 0.082 to 0.144 seconds in the fork. These are short workloads, three samples per lane, serial lane order and a shared development host, without confidence intervals or thermal isolation.

All workload commands succeeded; SHA-256, byte-count, warm-command and built-image contents were checked. The timing gate fails for any incomplete workload, nonzero exit, timeout, cleanup/restoration failure, or a corresponding trial taking at least ten times as long as Apple. Passing this gate does not mean equal performance.

## What is compared

The fork uses source checkpoint `d2644555c05a8862506c57727ae32e6f7f555d67`, containerization `51bf8a10e2036861f87ccdf2fd881a8726c534d2`, its matching retained vminit archive, and builder shim `016040197215684db474181b444767eb58797cfa`. Apple uses container `57f0b9392bbee1998e6c7f3f25db222fe1dcdd12`, its native containerization 0.45.0 revision `9eacc197d7c3663eb29cbab6d51244ede6d1cd7d`, Apple vminit 0.45.0 and builder 0.13.1. Immutable OCI digests and all signed executable hashes are in the fingerprints. These are pinned source comparisons, not a claim to track mutable latest releases.

Both host stacks use optimized Bazel builds with the same build environment. Both use the same kernel from the source-recommended Kata 3.32.0 archive, the same immutable Alpine 3.22 image, one vCPU and 512 MiB for application containers, and two vCPUs with 2 GiB for builders. Application workloads have networking disabled. The kernel is the recommended debug variant in both lanes; host binaries are release builds.

Images are prepared before timing. Every startup trial creates a fresh VM with warm host/image caches. Image-load measures repeated import, not first import. Uncached builds disable instruction caching but retain the downloaded base image. The Dockerfile copies a deterministic payload and hashes it; every built image is run afterward to check the result. Registry downloads and setup are retained as operations but excluded from the speed table.

These runtime results compare complete stacks. They do not identify which repository causes a difference. [Individual fork/component comparisons](FORK_BENCHMARK.md) separately cover container, containerization and builder-shim compilation and common workloads. Engine API has no stock Apple counterpart. The known Apple/fork container-name policy difference in that separate report remains visible and is not waived by this runtime pass.

## Reproduction and safeguards

Run from this checkout:

```sh
make bazel-final
```

Evidence defaults to a fresh timestamped directory under `~/Library/Application Support/ContainerFamily/retained/container-only/runtime-benchmark`. `BENCHMARK_RUN` can select another unused name. Existing results are never overwritten. The source-revision stamp is explicitly inherited by the package importer and checked against the built CLI; benchmark data is recreated before staging a different build so old provider identities cannot be reused accidentally. Compiler caches are retained.

An unchanged optimized-build repeat completed in 1.513 seconds inside Bazel with 2,015 cached actions and one internal action; it performed no compilation.

The harness is specific to this enrolled Mac: it requires the enrolled SSD, pinned Bazel, the configured Steve Clarke signing identity, the retained matching fork guest archive, registry access and existing macOS authorization. It validates pins and checksums and does not automate consent. Stable installation paths and signing identifiers avoid creating a new executable identity for every trial.

Only marker-owned benchmark data is replaced. Apple hardcodes its service namespace, so the harness temporarily unloads inactive default registrations, preserves their plists, runs against a private application-data directory and restores the registrations afterward. It refuses to displace an active default service. Concurrent benchmark runs are locked out. No existing user containers or images are removed, and no release is installed or published.

## Retained evidence and limits

The final successful run is `20260927-final3` under the evidence root. Its `acceptance.json` is true with no failures; `results.json`, `operations.json`, `matrix.json`, `matrix.md` and `timings.xml` retain measurements and validation. `source-inputs.json`, `assets.json`, `host.json` and both fingerprint files retain sources, dependencies, images and host details. `service-restoration.json` confirms restoration of all four original registrations. No benchmark service remained registered after completion.

Earlier evidence is preserved: `20260927` contains valid paired measurements but a cleanup check that ran before asynchronous unregistration finished; `20260927-final` stopped while replacing a read-only staged helper; `20260927-final2` records a startup timeout after a missing revision stamp changed the fork's provider identity. Those failures remain failures. The harness now waits for bounded unregistration, replaces read-only artifacts atomically, inherits/checks revision stamps and stages fresh benchmark data. An initial preflight also required an explicit application-root option; its correction record is retained in `20260927/preflight-correction.json`.

Seventeen focused tool tests plus the real end-to-end run verify the workflow. No Python coverage percentage or cloud Sonar result is claimed; signing, launchd and VM lifecycle paths are verified through the retained integration run. Journald/GELF sidecar archives, the separate full runtime-integration suite, published release packages and the pre-existing Homebrew installation are outside this benchmark's claims.
