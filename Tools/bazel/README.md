<!-- markdownlint-disable MD013 -->

# Container-only Bazel build

This workspace qualifies `container` and its required dependencies in order. It uses the exact revisions in `Package.resolved`, one macOS configuration and native Bazel compilation. SwiftPM supplies package descriptions only; it does not run a second build engine.

See [QUALIFICATION.md](QUALIFICATION.md) for validation and explicit limits, and [BENCHMARK.md](BENCHMARK.md) for repeated warm and incremental timings.

[FORK_BENCHMARK.md](FORK_BENCHMARK.md) compares the active forks with matching Apple revisions, including identical test workloads and explicit behavior differences.

[RUNTIME_BENCHMARK.md](RUNTIME_BENCHMARK.md) compares actual container startup, execution, CPU/disk workloads, image transfers and image builds using optimized Apple and fork stacks. It is part of the final build qualification.

## Commands

Run these in the container checkout:

| Command | Scope |
| --- | --- |
| `make bazel-build` | Eight container executables and the semantic helper |
| `make bazel-test` | Container unit suites and the helper's Go tests |
| `make bazel-build LAYER=system` | One dependency layer and its prerequisites |
| `make bazel-test LAYER=system` | One layer's tests |
| `make bazel-dependency-test` | Selected tests for all admitted dependencies |
| `make bazel-test-all` | Container and dependency tests together |
| `make bazel-fork-benchmark` | Isolated fork/Apple component comparisons; retains mismatches and timings |
| `make bazel-runtime-benchmark` | Build optimized Apple/fork stacks and run repeated runtime speed benchmarks |
| `make bazel-final` | Tool checks, all 101 normal test targets, optimized builds and runtime comparison |
| `make bazel-preflight PREFLIGHT_PROFILE=release` | Check noninteractive signing, package access, Sonar authentication and the configured notarization profile |
| `make bazel-repository-test` | Six original packaging/install script checks as independent cached targets |
| `make bazel-guest-build` | Cross-compile the exact pinned Linux guest and retain a verified OCI archive |
| `make bazel-linux-test` | Guest core/netlink and vmexec Linux tests, with separate build caches and coverage |
| `make bazel-builder-build` | Production-toolchain formatting, vet, race tests and coverage, then a pinned builder OCI archive |
| `make bazel-unattended-artifacts` | Preflight, tool checks, guest/Linux/builder qualification and one live Apple/fork smoke trial; restore a Colima VM started by this run |
| `make bazel-unattended` | Run the full qualification pipeline from a clean committed checkpoint, with release preflight and Colima restoration |
| `make bazel-service-artifacts` | Original journald/GELF race, coverage and reproducibility checks, with reusable verified OCI outputs |
| `make bazel-service-integration` | Original Swift-to-journald protocol test against the packaged Linux service, compiled by Bazel |
| `make bazel-maintenance` | Original format/license checks and isolated protobuf regeneration/diff |
| `make bazel-coverage` | Instrumented container host tests, retained LCOV and Sonar XML bound to source hashes |
| `make bazel-docs` | Original 15 API modules, extracted through Bazel and merged with DocC |
| `make bazel-codeql` | Pinned CodeQL Swift analysis with a separate traced Bazel build and retained SARIF |
| `make bazel-quality` | Enforce Previous version policy and scan a clean exact commit with verified coverage and matching pushed PR |
| `make bazel-release-artifact PREPARED_RUNTIME=... SERVICE_ARTIFACTS=... RELEASE_ARGS=--notarize` | Sign and validate the original archive payload, then retain Apple's notarization result |
| `make bazel-release-install` | Validate and exercise the signed archive in the private runtime location, then restore its predecessor |
| `make bazel-tools-test` | Launcher, runner and retained-report checks |
| `make bazel-check` | Tool checks, complete build, container unit tests |
| `make bazel-host-test LAYER=container-api` | Explicit host checks; requires the relevant host services |
| `make bazel-integration-build` | Compile the runtime integration harness without running it |
| `make bazel-integration-test CONTAINER_CLI_PATH=/absolute/path/to/container` | Run integration against an already prepared test installation |
| `make bazel-runtime-integration PREPARED_RUNTIME=/absolute/evidence/path` | Reset owned runtime data and run original CLI suites by layer; select one with `INTEGRATION_ARGS='--layer System'` |

`LAYER` defaults to `container`. Pick individual layer names from [layers.bzl](layers.bzl). Build and test commands reuse the same outputs. Host and runtime integration runs deliberately disable result caching because their external state can change.

The separate runtime integration suite requires a matching prepared installation, running services, kernel/images, permissions and network access. Its tests can create and remove runtime resources. Ordinary build/test commands do not start these prerequisites. The explicit runtime benchmark stages and starts its own signed installations, restores inactive default registrations afterward, and fails if an active default installation would be displaced. Compilation alone is not a runtime pass.

## Available layers

[`layers.bzl`](layers.bzl) declares each layer's package, build targets, executable tests and compile-only checks. It is the authoritative list of available layer names; a layer under qualification can be present before its tests pass. Each build requests its dependency libraries and C archives, including archives hidden behind provider-only package groups.

Each executable test gets a private source directory presenting only its declared runfiles, with both package-relative and Bazel external-package paths. This supports upstream fixture lookup without writing into a checkout. `zstd` has no upstream Swift test target and is a build-only layer; its consumers provide later integration coverage.

Additional dependencies are admitted only after the preceding layer passes. Runtime integration has a separate explicit target; dependency and unit tests do not install or launch container services. Compose, devcontainer, Kubernetes repositories and family release automation are outside this workflow.

## Storage and evidence

`Tools/bazel/run.sh` checks the enrolled external SSD and the SHA-256 of Bazel 8.8.0 before running. Scratch and compiler outputs live in `/Volumes/SSD/cf/container-only`. Each invocation saves its source status, toolchain version and raw output, Bazel events and copied JUnit/test logs under `~/Library/Application Support/ContainerFamily/retained/container-only`. Commands run immediately, without a scheduler. The unattended artifact check stops only its own temporary workloads and restores Colima when it started it; it does not clear compiler caches or install a system package.

## Unattended artifact checkpoint

The host graph remains native Bazel. The Linux guest uses the repository's Swift 6.3 static SDK build, and Linux-only tests use a digest-pinned Swift 6.3 glibc container because the installed musl SDK omits Swift Testing. These specialized lanes have independent persistent build directories; they do not rebuild the macOS SwiftPM graph. The builder uses its repository's digest-pinned production Go/BuildKit images and vendored dependencies.

Artifact receipts bind source revisions, toolchains, helper inputs and archive hashes. The runtime harness verifies the guest against `Package.resolved` and the builder against the container manifest, imports those exact local archives, and checks their hashes again before starting. Verified guest and builder archives are reused; Linux tests run again against the current VM and retain their instrumented coverage files. Ordinary host targets now also cover Netlink, CloudHypervisor, cctl, the macOS portion of VminitdCore, and six original repository script checks.

`make bazel-unattended-artifacts` requires the enrolled SSD, stable Developer ID signing identity, and an existing default arm64 Docker Colima profile. If that profile is stopped, the command starts it with a temporary SSD mount and restores its stopped state afterward. It preserves the selected Docker context and saved Colima configuration. Existing containers cause an admission failure. An already running Colima instance is retained; it must already expose the SSD. Every invocation needs a new `QUALIFICATION_EVIDENCE` directory; failures remain in the previous one.

For later release admission, store a notarization profile in Keychain and put only its name in `~/Library/Application Support/ContainerFamily/config/unattended.json`, for example `{"notary_profile":"container-only-release"}`. The preflight also verifies signing with a disposable probe, GitHub keyring package scopes, Sonar authentication and the matching pushed PR. Topic branches must have exactly one open Stephen-owned PR targeting main at the same commit; the scanner uses PR analysis and verifies that the PR head/base remain unchanged. The pinned Intel CodeQL Swift extractor requires Apple Rosetta, checked before any build. CodeQL uses indirect tracing across Bazel compiler actions because the macOS tracer cannot relocate Bazel’s self-extracting launcher. It does not certify all privacy permissions or claim a successful release. Credentials and passwords never belong in this repository.

The first unattended artifact checkpoint passed, including 69 Linux tests, builder race tests, and eight live workloads on both Apple and fork stacks. Its target took 83.96 seconds with reused guest/builder archives; the wrapper also started and stopped Colima. Subsequent checkpoints passed original service reproducibility tests, the Swift/journald wire test, original maintenance checks, and CLI layers for containers, run, volumes, network, images, build, system, registry and machines. The first Build run encountered a public Alpine repository fetch failure; a recorded rerun passed all 61 tests. Existing TCP-forwarding known issues remain visible in Run results.

Apple accepted pilot notarization submission `aa97fc82-3cd8-45f8-b9d2-48157926eb4b` using Keychain profile `container-only-release`. That pilot is not the final source checkpoint and has not been published. Host unit line coverage is 63.38% and builder statement coverage is 49.2%, both below the 90% aim. Coverage export rejects empty reports and retains the original raw profile evidence. A final full run, final archive installation, authoritative Sonar result and final benchmarks remain pending; intermediate green checkpoints do not certify them.

Kubernetes integration exposed a regular-file stdin EOF defect: Darwin's readability callback delivered contents but never completed the stream, leaving `kubectl apply -f -` waiting. A focused empty/large-file regression failed before the fix and passes afterward. Regular files now use bounded pull reads; pipes retain event-driven reads. All nine Kubernetes cases subsequently passed across the recorded full/focused runs after correcting private kubeconfig lookup and restart readiness. A final combined run remains required.

## Complete unattended run

`make bazel-unattended` requires a clean committed checkout. It runs tools, dependency/container/repository tests, maintenance, host checks, guest and Linux tests, builder and service qualification, lower-level VM and CLI integration, coverage, Sonar, component and Apple/Docker benchmarks, signed/notarized packaging and an archive installation smoke test. Each stage has a deadline and a separate result. Failed prerequisites block dependent work; independent checks continue. The command exits nonzero for failed or incomplete qualification and retains `QUALIFICATION.md`, `qualification.json`, `BENCHMARK.md`, raw measurements and cleanup records.

The optional manually dispatched `container-only-bazel.yml` workflow uses the same command on a self-hosted runner labelled `container-only`. Enroll only the designated MacBook Pro; the file does not register or start a runner. Existing upstream workflows are preserved. There is no scheduled task. The full command creates release candidates but does not publish a release or replace a user's installed runtime. The signed tar installation test supplies the exact guest/builder artifacts explicitly; it does not claim that unpublished default registry references are available.

The separately runnable four NIO host behavior checks remain known failures on this macOS version. Identical upstream benchmark fixtures also expose intentional container-name and TLS-alert differences; their raw failed assertions remain visible and receive no qualified performance claim. Exit status 2 means only these exact reviewed differences remain; the full workflow records `reviewed-differences`. Any extra failure, timeout, or tenfold timing remains a failed gate. API documentation now builds all 15 original modules through Bazel/DocC. The optimized release configuration emits nonempty dSYMs with verified binary UUIDs. The original unsigned installer recipe and an exact-commit CodeQL 2.27.1 scan are included; their final qualification remains pending. An Installer certificate is not configured, so only the archive distribution is signed/notarized; the native PKG remains explicitly unsigned.

Keep the same build directory between runs. Repeating the same target should reuse compiled outputs and passing test results. An edit invalidates its affected actions and dependents; separating layers limits which tests are requested, but does not prevent necessary dependent rebuilds. Do not clean the cache to diagnose an ordinary source error.

## Imported package tests

The package importer normally omits tests because package locks can omit test-only dependencies. A small patch enables an explicit list of upstream test targets. Add any required test dependencies at reviewed immutable revisions before enabling another test. The patch also preserves the consumer's deployment target when a dependency declares a lower minimum; this gives the container graph one macOS 15 configuration and supports the Bazel test runner.

Standalone Swift tests also need their plain resource bundles materialized as declared Bazel inputs. The importer creates these from the manifest's resource entries, preserves copied directory layouts, and rejects duplicate destinations or resources that need an Apple asset compiler. The generated bundle accessor adds a lookup used only inside Bazel tests.

Argument Parser also declares its checked-in snapshots and example executable as test inputs. A test-helper patch locates the example in Bazel runfiles; snapshot comparisons and assertions remain unchanged.

The certificate suite also has a test-only patch removing an unsupported XCTest activity-reporting wrapper; its key generation and every assertion still run.

The zstd importer exposes only its public headers to Swift. This supports upstream containerization's streaming zstd reader without importing private compression implementation headers as a Swift module.

Additional retained compatibility patches cover rules_license provider fields and Swift test output/coverage handling. They do not change container product behavior.

## Preservation and recovery

The pre-change snapshot is recorded in `/Users/sclarke/Documents/devcontainer/CURRENT-PRESERVATION.txt`. It contains all repository refs and metadata, tracked and nonignored worktree files, earlier retained artifacts/evidence and workspace notes. Ignored compiler caches remain in place. Work continues on `build/container-only-bazel` in a separate checkout; the original working trees have not been replaced.

## Host-dependent validation

The `nio-transport-services` library builds successfully. Its upstream suite is kept in a separate explicit host-test target: on this macOS installation, `NIOTSConnectionChannelTests.testConnectingInvolvesWaiting` waited indefinitely for a DNS/connectivity event concerning `example.invalid`. The qualification run was interrupted after 94 seconds and its raw log retained; that host-dependent check is not claimed as passing. The HTTP client timeout test also fails because this host resets a full TCP backlog instead of timing out. The platform network accounting test also returns zero path reports where upstream expects one. Two test-only patches mark these four checks (including both HTTP client timeout variants) as explicit `XCTSkip` in normal runs. `make bazel-host-test LAYER=nio-transport-services` or `LAYER=async-http-client` enables the original checks with `CONTAINER_HOST_TESTS=1`; every assertion is retained. None of these four host checks is claimed as passing. Other tests in those suites remain in the normal layer.

Normal tests set `CI=1`, respecting upstream opt-outs for interactive host services. Containerization uses this to skip its two login-Keychain checks; the initial sandbox run returned Keychain status 100001. The explicit host-test command clears `CI` and includes those checks. Skipped cases remain visible in retained test logs; XCTest also records its skips in JUnit XML.

Archive permission tests run with the `no-sandbox` execution requirement because the macOS sandbox strips set-ID bits. A focused comparison failed in the sandbox and passed locally. This preserves the complete permission assertions; compilation remains sandboxed and test outputs/results are still cached normally.

OCI tests that contact public registries also require the explicit host-test command (`LAYER=containerization-oci`). The initial Docker Hub ping timed out. A test-only trait gates live-registry methods while keeping local registry stubs, authentication validation, parsing and metadata checks in normal runs. Existing upstream credential requirements and disabled push tests remain unchanged.

Engine API key-store tests require the explicit host command (`LAYER=engine-core`, `LAYER=engine-session`, or `LAYER=engine-service`): eleven cases need an accessible Keychain, which returned status 100001 in the sandbox. Ordinary cache, protocol, cryptographic, signing-identity and routing tests remain enabled. The test runner uses a private standalone copy of the executable because the incomplete `.xctest` layout emitted by rules_swift fails strict code-signature validation (status -67056). No existing product is re-signed or installed by the test runner. Explicit host runs execute locally and still require an accessible Keychain; they are not part of normal qualification.

## Container source and semantic helper

The local container package is imported from this checkout with the same selected-test mechanism. Its tests declare their manifest, lockfile and helper fixtures. The executable-path test uses the invoked test binary name, which works with SwiftPM and Bazel.

The same-repository semantic helper builds natively with rules_go, its existing Go 1.25.6 pin and go.mod/go.sum. Bazel generates the source/oracle digest constants used by the native helper, then signs the new output and generates its manifest using the existing manifest routine. The helper's Go tests and Swift attestation tests exercise the resulting payload. Unrelated Swift edits reuse this output.

Seven API logging-handoff tests require Keychain access. In CI they are explicit skips unless CONTAINER_HOST_TESTS=1; native non-CI behavior is unchanged. Use the container-api host-test layer to request their original checks.

## AWS dependency scope

The AWS SDK import retains its exact lockfile revision and selects only the CloudWatch Logs service through that revision's native batch mechanism. Its internal authentication/runtime libraries remain available. A manifest patch keeps runtime unit tests available in this selected batch.

The CRT import initializes its pinned recursive C submodules. A manifest-only patch selects upstream offline tests for cryptography, checksums, encoding, configuration, signing and local I/O. Network, MQTT, metadata-service and credential-provider integration suites are outside this normal target; their sources and assertions are untouched.

Smithy's main-package test is an empty placeholder. Its real tests require generated SDK subprojects and a Java code generator, so this reduced workflow treats Smithy as build-only and exercises it through AWS and container consumers. It does not report the placeholder as meaningful test coverage.

The Smithy source-generation plugin is represented by a native Bazel action. It builds the pinned Swift generator, reads each selected service's settings/model and declares all five generated Swift files. A narrow resource patch passes the generator's existing header file as a declared input. This avoids nested SwiftPM builds and allows generation results to be cached.

## Build boundaries

The active graph contains this repository and 39 pinned Swift package dependencies, plus the same-repository Go helper's pinned module dependencies. The two DocC-only lockfile packages are not imported. The internal K8s module belongs to this container repository; no separate Kubernetes repository is admitted.

Normal builds produce debug artifacts. `bazel-final` also builds optimized binaries, signs the private benchmark installations and runs VMs. Packaging, publishing and family-wide release gates remain outside this check. The engine command's source file is named after its type instead of `main.swift`, avoiding Swift's top-level entry-point interpretation when using `@main`; its contents are unchanged.

## Performance interpretation

See [the performance diagnosis](PERFORMANCE_DIAGNOSIS.md) before comparing fork and upstream timings. Component rebuilds deliberately invalidate every component Swift file, and archive suite timings use debug builds. Runtime measurements use optimized binaries. The benchmark waits directly for child exit with a separate timeout watchdog, avoiding up to roughly 50 ms of parent polling delay on short commands. Exact fingerprints and earlier results remain retained.

## Docker/Colima reference

After the Apple/fork runtime comparison, use `make bazel-docker-benchmark`
with an already running, idle Colima Docker engine. Set `DOCKER_CONTEXT` for
another explicit context. Seven trials use the same immutable ARM64 Alpine
image, workload resources, hashes and build payload. The command saves raw
timings, engine information, validation results and cleanup results.
It removes only its uniquely named container and result image; downloaded
base images and build cache remain available. It does not start or stop an engine.

Docker uses a warm shared VM; Apple/fork startup includes a fresh dedicated
VM. Docker's default builder shares the Colima resources recorded in engine
information, whereas Apple/fork builders use 2 CPUs and 2 GiB. Import/save
formats and storage implementations differ. These are product-level latency
comparisons, not controlled measurements of a common kernel or storage engine.

Runtime Makefile targets use seven trials by default; override `BENCHMARK_TRIALS`
for an explicitly shorter smoke run. The final optimization report is
[PERFORMANCE_OPTIMIZATIONS.md](PERFORMANCE_OPTIMIZATIONS.md).

The lower-level VM suite exposed retained original VSOCK descriptors that prevented silent close from reaching the guest. Closing the original descriptors after duplication restored all 100 parallel relay rounds. The complete native suite then passed 191 tests with 22 platform skips and verified cleanup. The focused owner-lifetime unit selection also exposed an existing gRPC/NIO teardown assertion after both assertions passed; the complete containerization unit target passed, and both outcomes remain retained.

## Qualification follow-up

The second clean checkpoint passed the cached dependency/container layers, 15 documentation modules, service checks, 69 Linux tests and 191 VM tests (22 platform skips), but correctly failed qualification. The Unix-socket CLI test depended on a live Alpine package-server download; it now uses a digest-pinned Python image warmed before testing, preserving its guest-user and socket-permission assertions. Socket suite stress also reproduced echo failures in both Apple and fork (2/10 and 4/10 runs); serial execution of the unchanged cases passed 10/10 per lane. The runner now isolates these cases while preserving their internal 100/500-connection workloads. Diagnostic runs and original failures remain retained. These follow-up fixes still require the next clean qualification checkpoint.
