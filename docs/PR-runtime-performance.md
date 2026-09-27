# perf: remove service query polling and adopt faster archive traversal

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

Complete short launchctl queries through termination events, preserving installation ownership checks and domain selection. Drain output before waiting so large output cannot block. Update the containerization pin to the tested archive batching and directory traversal improvements.

## Testing

- [x] Tested locally: ContainerPluginTests passes.
- [x] Added tests for output exceeding pipe capacity, nonzero exit status and launch failure.
- [x] Updated documentation.

Archive and OS tests pass at the pinned dependency. Full-stack performance results, guest artifact fingerprints and final acceptance belong to Tools/bazel/PERFORMANCE_OPTIMIZATIONS.md in the container-only Bazel checkout. No compatibility policy or durable lifecycle state behavior is removed. The query still has the same unbounded child-lifetime behavior as before. See [the issue](ISSUE-runtime-performance.md).
