<!-- markdownlint-disable MD013 -->

# perf(copy): update eligible stopped images without guest startup

## Type of Change

- Performance improvement with maintained helper and packaging changes.

## Motivation and Context

Cold regular-file copy-in still incurs about 621 ms and exceeds both corresponding retained Docker timing thresholds. The service now clones an eligible private stopped rootfs under its lifecycle mutation fence, transfers through a separate filesystem helper, independently verifies bytes and requested metadata, and atomically replaces the original. Unsupported operations discard staging and use the guest path. Postcommit durability errors propagate rather than performing a duplicate guest transfer.

The helper uses authenticated e2fsprogs 1.47.4 sources with static, system-only linkage. Because the linked source closure includes GPL code, it remains a separate GPL-2.0-or-later executable with the complete original source archive, notices and exact helper build sources. No library code is linked into the Swift service or SDK. Its deny-default sandbox is established before parsing guest-controlled metadata; the deprecated sandbox API is an explicit dependency. CPU, wall-time and parent memory-watchdog bounds reap the child before releasing lifecycle ownership. The sandbox does not prove integrity of unrelated staged-image entries if the parser is exploited.

Native and Bazel builds produce the helper, manifest and corresponding-source archive. Product inventory v4 retains all three and signing updates only the executable hash. Historical inventories and baseline results retain their original identity.

## Testing

- Focused component evidence: 15 helper cases, independent e2fsck/debugfs checks, sandbox denial tests, four Swift commit transactions and six noncommit checks pass in transaction-v6.
- Explicit mode 0600 is verified with source mode 0640 and ownership preservation enabled.
- Process tests cover launch errors, exit status, deadline, memory exhaustion, child reaping and caller descriptor lifetime.
- The maintained Make target passes with explicit fixture/oracle inputs; the standalone helper also builds through the actual Bazel Darwin sandbox.
- The exact three-file Container-only recipe transition passes 21 policy tests, rejects partial/reverse/unrelated changes, and admits all four published lower artifact groups without rebuilding them.
- `make test-offline-ext4-helper` runs the maintained source-authentication, sandbox, process and filesystem checks with explicit test-only fixture/oracle inputs.
- Independent read-only review found no remaining transaction or release-wiring blocker after corrections; full service compilation, matched runtime parity/performance, coverage and distribution qualification remain pending.

The retained evidence root is `performance-parity-20261011T150042Z/candidate-container-startup-timings/offline-dependency`. Earlier failed attempts remain intact. No unchanged baseline was rebuilt or rerun. There is no measured product speedup claim until the full candidate runs against authenticated retained references.

## Compatibility and remaining gates

Regular files, overwrites, existing destination directories and optional parent creation use the fast path when eligible. Directory/archive transfers, path-dependent symlinks, journaled/recovery images, inherited ACLs, special inode flags and unsupported spellings use the guest path. Shared and live images are excluded. Source licensing, stable signed identity, full runtime correctness and performance must qualify before publication.

Related handoff: ISSUE-stopped-copy-offline-write.md. No Apple issue, PR or comment is published by this change.
