<!-- markdownlint-disable MD013 -->

# Container-only Bazel build

This workspace qualifies `container` and its required dependencies in order. It uses the exact revisions in `Package.resolved`, one macOS configuration and native Bazel compilation. SwiftPM supplies package descriptions only; it does not run a second build engine.

## Commands

- `make bazel-tools-test`: validate the launcher and report preservation.
- `make bazel-build LAYER=system`: build one layer and any compile-only checks.
- `make bazel-test LAYER=system`: run that layer's executable tests.
- `make bazel-host-test LAYER=nio-transport-services`: explicitly run host networking tests with a 120-second bound.
- Replace `system` with a layer name in `layers.bzl`, such as `atomics` or `collections`.

## Available layers

[`layers.bzl`](layers.bzl) declares each layer's package, build targets, executable tests and compile-only checks. It is the authoritative list of available layer names; a layer under qualification can be present before its tests pass. Each build requests its dependency libraries and C archives, including archives hidden behind provider-only package groups.

Each executable test gets a private source directory presenting only its declared runfiles, with both package-relative and Bazel external-package paths. This supports upstream fixture lookup without writing into a checkout. `zstd` has no upstream Swift test target and is a build-only layer; its consumers provide later integration coverage.

Additional dependencies are admitted only after the preceding layer passes. Runtime integration will have a separate explicit target; dependency and unit tests do not install or launch container services. Compose, devcontainer, Kubernetes repositories and family release automation are outside this workflow.

## Storage and evidence

`Tools/bazel/run.sh` checks the enrolled external SSD and the SHA-256 of Bazel 8.8.0 before running. Scratch and compiler outputs live in `/Volumes/SSD/cf/container-only`. Each invocation saves its source status, toolchain version and raw output, Bazel events and copied JUnit/test logs under `~/Library/Application Support/ContainerFamily/retained/container-only`. There is no timer, automatic cleanup, package installer or release step.

Keep the same build directory between runs. Repeating the same target should reuse compiled outputs and passing test results. An edit invalidates its affected actions and dependents; separating layers limits which tests are requested, but does not prevent necessary dependent rebuilds. Do not clean the cache to diagnose an ordinary source error.

## Imported package tests

The package importer normally omits tests because package locks can omit test-only dependencies. A small patch enables an explicit list of upstream test targets. Add any required test dependencies at reviewed immutable revisions before enabling another test. The patch also preserves the consumer's deployment target when a dependency declares a lower minimum; this gives the container graph one macOS 15 configuration and supports the Bazel test runner.

Standalone Swift tests also need their plain resource bundles materialized as declared Bazel inputs. The importer creates these from the manifest's resource entries, preserves copied directory layouts, and rejects duplicate destinations or resources that need an Apple asset compiler. The generated bundle accessor adds a lookup used only inside Bazel tests.

Argument Parser also declares its checked-in snapshots and example executable as test inputs. A test-helper patch locates the example in Bazel runfiles; snapshot comparisons and assertions remain unchanged.

The certificate suite also has a test-only patch removing an unsupported XCTest activity-reporting wrapper; its key generation and every assertion still run.

The other two patches are retained compatibility fixes for rules_license provider fields and Swift test output/coverage handling. They do not change container product behavior.

## Preservation and recovery

The pre-change snapshot is recorded in `/Users/sclarke/Documents/devcontainer/CURRENT-PRESERVATION.txt`. It contains all repository refs and metadata, tracked and nonignored worktree files, earlier retained artifacts/evidence and workspace notes. Ignored compiler caches remain in place. Work continues on `build/container-only-bazel` in a separate checkout; the original working trees have not been replaced.

## Host-dependent validation

The `nio-transport-services` library builds successfully. Its upstream suite is kept in a separate explicit host-test target: on this macOS installation, `NIOTSConnectionChannelTests.testConnectingInvolvesWaiting` waited indefinitely for a DNS/connectivity event concerning `example.invalid`. The qualification run was interrupted after 94 seconds and its raw log retained; this suite is not claimed as passing. The HTTP client timeout test also fails because this host resets a full TCP backlog instead of timing out. The platform network accounting test also returns zero path reports where upstream expects one. Two test-only patches mark these four checks (including both HTTP client timeout variants) as explicit `XCTSkip` in normal runs. `make bazel-host-test LAYER=nio-transport-services` or `LAYER=async-http-client` enables the original checks with `CONTAINER_HOST_TESTS=1`; every assertion is retained. None of these four host checks is claimed as passing. Other tests in those suites remain in the normal layer.

Normal tests set `CI=1`, respecting upstream opt-outs for interactive host services. Containerization uses this to skip its two login-Keychain checks; the initial sandbox run returned Keychain status 100001. The explicit host-test command clears `CI` and includes those checks. Skipped cases remain visible in retained JUnit reports.

Archive permission tests run with the `no-sandbox` execution requirement because the macOS sandbox strips set-ID bits. A focused comparison failed in the sandbox and passed locally. This preserves the complete permission assertions; compilation remains sandboxed and test outputs/results are still cached normally.

OCI tests that contact public registries also require the explicit host-test command (`LAYER=containerization-oci`). The initial Docker Hub ping timed out. A test-only trait gates live-registry methods while keeping local registry stubs, authentication validation, parsing and metadata checks in normal runs. Existing upstream credential requirements and disabled push tests remain unchanged.

Engine API key-store tests require the explicit host command (`LAYER=engine-core`, `LAYER=engine-session`, or `LAYER=engine-service`): eleven cases need an accessible Keychain, which returned status 100001 in the sandbox. Ordinary cache, protocol, cryptographic, signing-identity and routing tests remain enabled. The test runner uses a private standalone copy of the executable because the incomplete `.xctest` layout emitted by rules_swift fails strict code-signature validation (status -67056). No product is re-signed or installed. Explicit host runs execute locally and still require an accessible Keychain; they are not part of normal qualification.
