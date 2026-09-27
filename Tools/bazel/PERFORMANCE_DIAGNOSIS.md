<!-- markdownlint-disable MD013 -->

# Why the container fork is slower

Investigation on 27 September 2026, using the same signed optimized binaries and guest images as the upstream-refresh comparison. The repeatable whole-stack regressions are container startup/exit and warm image import. The earlier large archive-suite number mainly measures unoptimized path handling, and the forced compilation comparison rebuilds a much larger fork. Ordinary cached builds remain fast.

## Measurements corrected

The old benchmark used Python `subprocess.run(timeout=...)`. Its POSIX wait implementation sleeps while polling for child completion, reaching 50-millisecond intervals. The timer therefore measured child execution plus up to roughly 50 milliseconds of detection delay. This is material for short commands. The harness now blocks on child exit and uses a separate deadline watchdog; timeout enforcement and failure retention remain intact. A regression test fails with the original implementation and passes with the correction. All 20 tool tests pass.

The old results remain preserved. New evidence uses seven trials per lane for all eight runtime workloads, followed by nine more trials for startup/import with the lane order reversed. Both runs passed their workload and cleanup checks and restored the original inactive services. No product binary changed between measurements. The whole-stack runs are unprofiled; sampling runs are separate because profiling adds overhead.

| Workload | Apple median | Fork median | Difference |
| --- | ---: | ---: | ---: |
| Startup/exit, fork measured first | 508 ms | 726 ms | +219 ms / +43% |
| Startup/exit, Apple measured first | 543 ms | 717 ms | +174 ms / +32% |
| Warm import, fork measured first | 50 ms | 82 ms | +32 ms / +63% |
| Warm import, Apple measured first | 79 ms | 117 ms | +38 ms / +48% |
| Uncached image build, seven trials | 870 ms | 871 ms | Approximately equal |
| Cached image build, seven trials | 137 ms | 140 ms | +3 ms |
| Image save, seven trials | 106 ms | 106 ms | Approximately equal |

Warm exec, SHA-256 and write/sync medians differed by roughly 2%, 3% and 6% respectively. The previous uncached-build slowdown and cached-build speedup did not reproduce with corrected timing. Shared-host and cache variation remain visible; do not replace them with claims of universal parity or a single definitive percentage.

## Confirmed: thousands of small writes during image import

The fork changed archive extraction to use `archive_read_data_block` plus `pwrite`, preserving sparse-file offsets. The archive reader still opens its input with a 4 KiB block size. Consequently, extraction issues a write for each small returned block. Apple's copy path gathers data into its existing 4 MiB buffer before writing.

A live profile of the fork image service showed extraction spending substantial sampled time in `copyEntryDataToFd` and `pwrite`. A focused optimized experiment then extracted the identical retained Alpine OCI archive nine times per variant on the internal disk, keeping the fork's extraction behavior and assertions:

| Variant | Median extraction | Writes per extraction |
| --- | ---: | ---: |
| Apple | 18.2 ms | Not instrumented |
| Current fork | 37.5 ms | 7,318 |
| Fork diagnostic: existing 4 MiB read-buffer size | 13.7 ms | 65 |

Changing only the three archive-open block-size arguments, while retaining sparse-aware writes and metadata handling, removed about 24 ms from this fixture. This is direct causal evidence for an avoidable import cost, and consistent with the 32-38 ms whole-command gap. It does not prove every millisecond of that gap has the same cause.

The diagnostic modification was made only in disposable source fixtures and restored byte-for-byte. It is not a shipped fix. Before landing it, run the fork's sparse-file, hard-link, truncated-input, streaming and ownership regression tests and repeat the whole-command import comparison. Relevant source: `containerization/Sources/ContainerizationArchive/ArchiveReader.swift`, archive-open calls and `copyEntryDataToFd`.

## Confirmed: debug path processing dominates the archive suite

One 50-level nesting test dominates the previous 53-test archive suite: about 17.5 seconds in Apple and 36.7-37.1 seconds in the fork. The fork deliberately restores directory metadata after extracting children, in deepest-first order, so restrictive parent permissions do not block extraction and directory timestamps remain correct.

Temporary phase timing measured 17.05 seconds for initial extraction and 19.40 seconds for that metadata pass in debug mode. Sampling showed repeated `FilePath.ComponentView` reconstruction, normalization, invariant checks and generic collection work inside recursive directory traversal. Both implementations repeatedly rebuild the remaining path components; the fork traverses the directories a second time.

With optimization enabled, the original nesting test took 29 ms for Apple and 46 ms for the fork. An instrumented optimized fork measured about 21 ms for extraction plus 22 ms for metadata restoration. Thus the second traversal is real overhead, but the seconds-long result is dominated by debug code and a pathological nesting fixture. It is not a representative image extraction or VM benchmark.

A future optimization should reuse parsed path components or traverse by an index/slice while preserving descriptor-based, no-symlink traversal and deferred metadata semantics. Removing metadata restoration would drop required behavior. The initial optimized test attempt failed because `@testable` imports were disabled; rerunning with the supported `swift.enable_testing` feature succeeded. All original evidence is retained.

## Startup: expensive service waits and additional lifecycle work

The live API-server profile repeatedly entered `ServiceManager.getLaunchdSessionType` and the fork-added `ServiceManager.loadedPlistPath`, waiting in Foundation `Process.waitUntilExit`. The latter invokes `launchctl print` to avoid accidentally reusing another installation's service. That ownership check is necessary, but its wait mechanism is expensive here.

A focused optimized probe reproduced the same read-output-then-wait pattern over 12 alternating trials:

| Read-only launchctl query | Foundation run-loop wait | Termination-handler event wait |
| --- | ---: | ---: |
| `managername` | 75.6 ms | 6.6 ms |
| `print` of an absent service | 76.8 ms | 6.7 ms |

The first query exists in Apple too; the extra registration query is a fork cost. These measurements identify an avoidable wait of roughly 70 ms per affected call on this Mac. They do not establish that replacing it recovers all of the 174-219 ms end-to-end gap. The fork already uses event-driven completion in another launchctl helper, so a consistent implementation is a narrow candidate fix. Ownership checks must remain.

Source inspection also found extra synchronous lifecycle work: Docker state, lifecycle-v1 and lifecycle-v2 persistence; file and parent-directory `fsync`; post-start state/process RPCs; and an OOM-statistics request before `startProcess`. That request reaches a `statistics()` method requiring a started container and produces the observed invalid-state error on fresh starts. The profile contains durable writes, but does not show them as the dominant sampled delay. Do not attribute the full gap to disk flushing or logging without a controlled product-level comparison.

Relevant source: [service registration](../../Sources/ContainerPlugin/ServiceManager.swift), [start/lifecycle path](../../Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift), and [durable writes](../../Sources/ContainerResource/Container/Bundle.swift). No startup behavior was changed during this investigation.

## Compilation: a much larger dependency chain

The forced-component benchmark adds a harmless comment to every production Swift source, deliberately invalidating all component modules. It is not an ordinary one-file incremental build. The source inventory grew from 342 files / 1.79 MB in Apple to 514 files / 5.70 MB in the fork.

The retained build profiles show the critical path growing from 12.54 to 25.83 seconds. The largest fork contributions are API service compilation (10.32 s), resource compilation (5.72 s), and the new logging-storage module (3.60 s). The resource module alone grew from roughly 101 KB to 718 KB; API-server source grew from 127 KB to 1.46 MB. Logging providers add another 844 KB. Additional engine, lifecycle and logging functionality explains the source growth.

The fork executed 36 Swift compilation actions versus Apple's 32. Its 554 cache hits show that external dependencies were largely reused; this was not a wholesale cache miss. Splitting optional logging/provider dependencies out of common API/resource modules is a promising way to shorten the critical path, but requires design and measurement. Keep per-layer tests and targeted builds, which already avoid this forced invalidation in normal work.

## Priority and preservation

1. Increase archive input blocks while retaining sparse-aware output, then validate focused correctness and runtime import performance.
2. Remove avoidable process-wait latency from service registration without weakening ownership checks; measure the full startup path afterward.
3. Eliminate or relocate the pre-start statistics RPC and consolidate durable lifecycle updates only where crash-recovery guarantees permit it.
4. Optimize debug path traversal and split the largest common build modules as separate focused changes.

Only the benchmark's completion timing was fixed in maintained code. Product experiments were restored, optimized test fixtures were isolated, private services were stopped and original registrations restored. No remote publication or new automation was performed.

Evidence: `~/Library/Application Support/ContainerFamily/retained/container-only/performance-investigation/20260927`. It contains corrected and reverse-order runtime results, exact old product fingerprints, process samples, phase logs, causal probe sources/results, source restoration hashes, source-size inventory and original build critical paths. All successful, failed and instrumented runs retain their distinct interpretation.
