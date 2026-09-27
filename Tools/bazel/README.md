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
| `make bazel-final` | Tool checks, all 91 normal test suites, optimized builds and runtime comparison |
| `make bazel-tools-test` | Launcher, runner and retained-report checks |
| `make bazel-check` | Tool checks, complete build, container unit tests |
| `make bazel-host-test LAYER=container-api` | Explicit host checks; requires the relevant host services |
| `make bazel-integration-build` | Compile the runtime integration harness without running it |
| `make bazel-integration-test CONTAINER_CLI_PATH=/absolute/path/to/container` | Run integration against an already prepared test installation |

`LAYER` defaults to `container`. Pick individual layer names from [layers.bzl](layers.bzl). Build and test commands reuse the same outputs. Host and runtime integration runs deliberately disable result caching because their external state can change.

The separate runtime integration suite requires a matching prepared installation, running services, kernel/images, permissions and network access. Its tests can create and remove runtime resources. Ordinary build/test commands do not start these prerequisites. The explicit runtime benchmark stages and starts its own signed installations, restores inactive default registrations afterward, and fails if an active default installation would be displaced. Compilation alone is not a runtime pass.

## Available layers

[`layers.bzl`](layers.bzl) declares each layer's package, build targets, executable tests and compile-only checks. It is the authoritative list of available layer names; a layer under qualification can be present before its tests pass. Each build requests its dependency libraries and C archives, including archives hidden behind provider-only package groups.

Each executable test gets a private source directory presenting only its declared runfiles, with both package-relative and Bazel external-package paths. This supports upstream fixture lookup without writing into a checkout. `zstd` has no upstream Swift test target and is a build-only layer; its consumers provide later integration coverage.

Additional dependencies are admitted only after the preceding layer passes. Runtime integration has a separate explicit target; dependency and unit tests do not install or launch container services. Compose, devcontainer, Kubernetes repositories and family release automation are outside this workflow.

## Storage and evidence

`Tools/bazel/run.sh` checks the enrolled external SSD and the SHA-256 of Bazel 8.8.0 before running. Scratch and compiler outputs live in `/Volumes/SSD/cf/container-only`. Each invocation saves its source status, toolchain version and raw output, Bazel events and copied JUnit/test logs under `~/Library/Application Support/ContainerFamily/retained/container-only`. There is no timer, automatic cleanup, package installer or release step.

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
