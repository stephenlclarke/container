# Pull request: retire completed exit tasks before callbacks

## Summary

- Tokenise `ExitMonitor` running tasks.
- Retire a naturally completed task before invoking its callback.
- Keep explicit cancellation and identifier-reuse safety.
- Add an exact self-cleanup regression.

## Apple-shaped boundary

This is a generic process-lifecycle correction in `apple/container`. It does
not introduce Compose or logging-driver policy into `ExitMonitor`; it restores
the expected contract that cleanup after a natural exit cannot cancel the
callback performing that cleanup.

## Code map

- `Sources/Services/Runtime/RuntimeClient/ExitMonitor.swift`
  - stores tokenised tasks and removes the matching completed task before the
    callback runs.
- `Tests/ContainerAPIServiceTests/ExitMonitorTests.swift`
  - proves callback cleanup does not self-cancel.
- `docs/upstream/ISSUE-exit-monitor-self-cancellation.md`
  - records the bug, behavior, and reproduction.

## Validation

```sh
swift test \
  --filter ExitMonitorTests/completedCallbackCanStopTrackingWithoutCancellingItself
```

The exact regression passes on this Apple-silicon Mac. Broad validation remains
batched with the accumulated logging lifecycle slices.

Signed local implementation checkpoint:
`5a9802499bc720994d50d055a63a1710a75795d5`.

## Publication state

This handoff is local to `upstream/logging-driver-parity`. Do not publish it to
Apple until all programme development is complete and the user explicitly
authorises upstream publication.
