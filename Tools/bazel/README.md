<!-- markdownlint-disable MD013 -->

# Container-only Bazel build

This workspace qualifies `container` and its required dependencies in order. It uses the exact revisions in `Package.resolved`, one macOS configuration and native Bazel compilation. SwiftPM supplies package descriptions only; it does not run a second build engine.

## Commands

- `make bazel-tools-test`: validate the launcher and report preservation.
- `make bazel-build LAYER=system`: build one layer and any compile-only checks.
- `make bazel-test LAYER=system`: run that layer's executable tests.
- Replace `system` with an admitted name in `layers.bzl`, such as `atomics` or `collections`.

## Current layers

The admitted layer names are declared in [`layers.bzl`](layers.bzl):

`system`, `atomics`, `collections`, `logging`, `service-context`, `numerics`, `asn1`, `argument-parser`, `http-types`, `metrics`, `algorithms`, `tracing`, `toml`, `protobuf`.

Additional dependencies are admitted only after the preceding layer passes. Runtime integration will have a separate explicit target; dependency and unit tests do not install or launch container services. Compose, devcontainer, Kubernetes repositories and family release automation are outside this workflow.

## Storage and evidence

`Tools/bazel/run.sh` checks the enrolled external SSD and the SHA-256 of Bazel 8.8.0 before running. Scratch and compiler outputs live in `/Volumes/SSD/cf/container-only`. Each invocation saves its source status, toolchain version and raw output, Bazel events and copied JUnit/test logs under `~/Library/Application Support/ContainerFamily/retained/container-only`. There is no timer, automatic cleanup, package installer or release step.

Keep the same build directory between runs. Repeating the same target should reuse compiled outputs and passing test results. An edit invalidates its affected actions and dependents; separating layers limits which tests are requested, but does not prevent necessary dependent rebuilds. Do not clean the cache to diagnose an ordinary source error.

## Imported package tests

The package importer normally omits tests because package locks can omit test-only dependencies. A small patch enables an explicit list of upstream test targets. Add any required test dependencies at reviewed immutable revisions before enabling another test. The patch also preserves the consumer's deployment target when a dependency declares a lower minimum; this gives the container graph one macOS 15 configuration and supports the Bazel test runner.

Argument Parser also declares its checked-in snapshots and example executable as test inputs. A test-helper patch locates the example in Bazel runfiles; snapshot comparisons and assertions remain unchanged.

The other two patches are retained compatibility fixes for rules_license provider fields and Swift test output/coverage handling. They do not change container product behavior.

## Preservation and recovery

The pre-change snapshot is recorded in `/Users/sclarke/Documents/devcontainer/CURRENT-PRESERVATION.txt`. It contains all repository refs and metadata, tracked and nonignored worktree files, earlier retained artifacts/evidence and workspace notes. Ignored compiler caches remain in place. Work continues on `build/container-only-bazel` in a separate checkout; the original working trees have not been replaced.
