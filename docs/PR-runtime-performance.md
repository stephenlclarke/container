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

The final dependency pin is `47ded59ac35d4a71d712cd41cb3382f3a3e9c4f6`.
A later lazy-share experiment was reverted in the dependency main branch;
production sources there match this pin. Retain existing filesystem attachment
behavior because the experiment did not materially improve startup.

The final release-policy pin is `9d6324ad5ba4d6487677bd6236f4d92eb0ad9eb8`: production Swift sources
are identical to `47ded59`, and main-branch CI now publishes an optimized guest
for that source rather than a debug guest. The local matching archive is retained
with its build fingerprint; remote publication is not assumed from a source push.

## Smaller guest helper

The containerization pin now includes the vmexec dependency cleanup: the helper links the existing OS, Netlink and cgroup contracts without the complete guest server. Its optimized ARM64 binary is 16.3% smaller. Alternating trials found no material startup or exec speed change, so this is a footprint and incremental-build improvement. Kernel probing, runtime mount capacity and guest memory thresholds are unchanged.
