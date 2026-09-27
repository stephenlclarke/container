<!-- markdownlint-disable MD013 -->

# build: introduce a container-only Bazel workflow

## Type of Change

- Build workflow simplification and documentation.

## Motivation and Context

See [ISSUE-container-only-bazel.md](ISSUE-container-only-bazel.md). The existing family work is preserved before creating this isolated branch. Package.resolved remains the source of dependency pins.

## Implementation

Use native Bazel package targets, one macOS configuration and explicit upstream tests per dependency layer. The active graph includes container and 39 pinned Swift dependencies. The same-repository semantic helper uses its existing pinned Go SDK and module lockfiles. Its compiled source/oracle digests and manifest are validated by Go and Swift tests.

Limit the AWS SDK to CloudWatch Logs plus required internal libraries. Represent the pinned Smithy generator as a Bazel action with declared settings, models, header and five Swift outputs. Select CRT offline test sources without changing their assertions; Smithy's empty placeholder test is not counted as coverage.

Import the local container source with selected tests and fixtures. Preserve native non-CI behavior while separating seven Keychain-backed API checks in CI. Make the executable-path assertion independent of the test runner name and rename the engine command's @main source file to avoid top-level entry-point interpretation; its contents are unchanged.

Expose container, dependency, per-layer, host and runtime-integration Makefile commands. Keep a short launcher that verifies the SSD and Bazel executable, uses persistent scratch and retains raw evidence. No scheduler or release controller is added.

## Testing

Qualification is proceeding from leaf dependencies upward. Swift System passed 75 tests; Atomics passed 1,972; the selected Collections suites passed 349. Argument Parser's 238 unit tests now run with declared snapshots and the example executable in Bazel runfiles. Reports for each suite, including initial failures, are retained separately on internal storage. Repeat runs reuse passing results; the measured System repeat took 0.047 seconds inside Bazel.

The launcher passes shell syntax, help and shellcheck checks. Six regression tests verify report preservation, attempt isolation, paths with spaces/Unicode, missing-evidence failures, fixture lookup for main/external packages, argument forwarding and child exit status. Markdown lint passes on touched documents. Narrow Makefile targets bypass legacy configuration evaluation; the initial tools check dropped from approximately five seconds to 0.3 seconds; the expanded six-test check takes about 1.4 seconds.

Networking, configuration and cryptography layers have also been added. The launcher can run host networking checks separately. Four upstream checks depend on macOS DNS events, TCP backlog behavior or path accounting; their observed failures are retained, and normal runs report explicit skips while the host command enables their unchanged assertions.

Containerization now has separate OS/utilities, archive, EXT4, OCI and main-library layers. Live registries and login-Keychain checks are explicit host integration checks. Archive permission tests run locally because the sandbox strips set-ID bits; the original assertions pass. A private standalone test executable fixes strict code-signature validation without re-signing or installing products. Engine API core, transports, sessions, gateway and service checks are split into separate layers.

All eight container executables and the same-repository Go semantic helper now build. The CLI passes version/help smoke checks. The runtime integration harness compiles separately; it has not been executed against a live installation.

The container unit suites and AWS runtime suites pass individually with cached repeats. The combined run passes all 91 suites; a warm repeat caches all 91 with no compilation. See [the qualification report](Tools/bazel/QUALIFICATION.md) for wall times, exact evidence and skipped-test accounting. No coverage percentage or cloud Sonar quality-gate result is claimed; local shell checks, Swift formatting and the actual native builds/tests supply this branch's evidence.

## Compatibility and Remaining Risks

This does not change the existing SwiftPM build or install system. Generated dependency tests need all test-only dependencies pinned. Native runtime integration and release qualification are separate work and are not implied by library tests. No GitHub issue or PR has been published yet.
