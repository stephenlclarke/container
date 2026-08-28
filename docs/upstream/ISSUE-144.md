<!-- markdownlint-disable MD013 -->

# [Parity] Bound concurrent VM bootstrap pressure

## Problem

Pull request 143 removed host-wide bootstrap serialization and allowed independent container IDs to enter VM bootstrap concurrently. A retained 50-service diagnostic at main commit `47f81e0c` shows all 50 starts reaching runtime bootstrap within 275 ms, but only the first 15 complete interface setup in 2.9 to 4.8 seconds. Later VM boots spend roughly 17 to 25 seconds inside Virtualization.framework and guest setup, making runtime bootstrap essentially the entire remaining startup P95.

## Required behavior

- Preserve parallel VM starts below the measured contention threshold.
- Bound only the expensive runtime bootstrap phase; lifecycle capture, logging preparation, launchd registration, runtime-client creation, and atomic state publication remain independently concurrent.
- Admit queued bootstraps in FIFO order.
- Return capacity after success, failure, or cancellation, including cancellation racing with permit transfer; an admitted cancellation retains capacity until its runtime helper is confirmed inactive.
- Record admission wait separately from actual runtime bootstrap time.

## Acceptance evidence

- [x] A focused diagnostic attributes the remaining 50-service tail to runtime bootstrap rather than Compose, logging, launchd, XPC client creation, or state publication.
- [x] Deterministic focused tests cover the concurrency ceiling, failure release, and queued cancellation.
- [ ] The final diff passes focused review with no unresolved finding.
- [x] One controlled release comparison retains functional parity and reports 1, 10, and 50-service median/P95 against the existing baseline and Docker oracle.
- [ ] The exact reviewed pull-request head is merged.

The seven-repetition release comparison passed functional parity and every 10x median/P95 guard. Against the retained post-PR-143 result, 50-service startup median fell from 16.411 to 8.542 seconds (47.9 percent) and P95 fell from 22.674 to 12.944 seconds (42.9 percent). Docker-normalized median improved 45.9 percent. One-service median improved 1.8 percent, while ten-service median changed by 1.0 percent.

## Scope

This slice controls host pressure while retaining the dedicated-VM isolation model. It does not introduce VM pre-warming or shared-VM isolation and does not claim completion of the parent performance contract.

## Pull-request provenance

The implementation and benchmark evidence were merged in
[`stephenlclarke/container#145`](https://github.com/stephenlclarke/container/pull/145).
As of 28 August 2026, no Apple upstream pull request contains the bounded
bootstrap-admission optimization.

Tracking issue: [`stephenlclarke/container#144`](https://github.com/stephenlclarke/container/issues/144).

Parent contract: [`stephenlclarke/container-compose#278`](https://github.com/stephenlclarke/container-compose/issues/278).

<!-- markdownlint-enable MD013 -->
