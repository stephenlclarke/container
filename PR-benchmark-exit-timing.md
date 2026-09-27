<!-- markdownlint-disable MD013 -->

# fix: measure benchmark completion without polling delay

## Motivation and implementation

See [ISSUE-benchmark-exit-timing.md](ISSUE-benchmark-exit-timing.md). Wait directly for child completion and enforce the deadline using a watchdog. Cancel/join the watchdog, kill/reap interrupted children, and preserve exit codes, logs and timeout status 124. Product binaries are unchanged.

## Validation

All 20 tool tests pass. The no-polling regression rejects the previous implementation. Eight runtime fixtures pass over seven trials per lane; startup/import also pass nine trials in reverse lane order. Both runs use the previous source-matched signed binaries and restore services. No full product rebuild was needed for this Python-only change.

## Results and limits

[The investigation](Tools/bazel/PERFORMANCE_DIAGNOSIS.md) explains the real import/startup gaps, debug archive overhead and forced compilation cost. Original measurements remain retained. Timeout thread scheduling and shared-host noise are still possible; no hard real-time timing guarantee is claimed. Diagnostic product modifications were restored and are not shipped fixes. No cloud CI, coverage percentage, product performance fix or publication is claimed.
