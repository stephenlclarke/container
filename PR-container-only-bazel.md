<!-- markdownlint-disable MD013 -->

# build: introduce a container-only Bazel workflow

## Type of Change

- Build workflow simplification and documentation.

## Motivation and Context

See [ISSUE-container-only-bazel.md](ISSUE-container-only-bazel.md). The existing family work is preserved before creating this isolated branch. Package.resolved remains the source of dependency pins.

## Implementation

Use native Bazel package targets, one macOS configuration and explicit upstream tests per dependency layer. Keep a short launcher that verifies the SSD and Bazel executable, uses persistent scratch and retains raw evidence. No scheduler or release controller is added.

## Testing

Qualification is proceeding from leaf dependencies upward. Swift System passed 75 tests; Atomics passed 1,972; the selected Collections suites passed 349. Argument Parser's 238 unit tests now run with declared snapshots and the example executable in Bazel runfiles. Reports for each suite, including initial failures, are retained separately on internal storage. Repeat runs reuse passing results; the measured System repeat took 0.047 seconds inside Bazel.

The launcher passes shell syntax, help and shellcheck checks. Six regression tests verify report preservation, attempt isolation, paths with spaces/Unicode, missing-evidence failures, fixture lookup for main/external packages, argument forwarding and child exit status. Markdown lint passes on touched documents. Narrow Makefile targets bypass legacy configuration evaluation; the initial tools check dropped from approximately five seconds to 0.3 seconds; the expanded six-test check takes about 1.4 seconds.

Networking, configuration and cryptography layers have also been added. The launcher can run host networking checks separately. Four upstream checks depend on macOS DNS events, TCP backlog behavior or path accounting; their observed failures are retained, and normal runs report explicit skips while the host command enables their unchanged assertions.

The full container build is not yet qualified. No coverage percentage is claimed for the imported upstream test suites.

## Compatibility and Remaining Risks

This does not change the existing SwiftPM build or install system. Generated dependency tests need all test-only dependencies pinned. Native runtime integration and release qualification are separate work and are not implied by library tests. No GitHub issue or PR has been published yet.
