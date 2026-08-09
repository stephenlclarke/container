# Completed exit callbacks can cancel themselves during cleanup

## Impact

`ExitMonitor` retained the tracking task while invoking its exit callback. A
callback that performs the normal `stopTracking(id:)` cleanup therefore
cancels the task that is currently executing the callback. Downstream async
work observes `Task.isCancelled`, and cancellation can escape as a misleading
lifecycle failure even though the monitored process exited normally.

The problem is generic to machine, container, and runtime process monitoring;
logging recovery made it consistently observable but does not own the faulty
primitive.

## Required behavior

- Remove a naturally completed tracking task before invoking its callback.
- Preserve explicit cancellation when `stopTracking` is called while the wait
  handler is still active.
- Prevent an older completed task from removing a newer task registered for
  the same identifier.
- Log callback failures without converting a successful wait into
  self-cancellation.

## Apple-shaped implementation

Associate each running task with a unique token. After its wait handler
finishes, remove the task and callback only when the stored token still matches,
then invoke the captured callback after cleanup. `stopTracking` continues to
cancel a task that is genuinely still tracked.

## Focused regression

```sh
swift test \
  --filter ExitMonitorTests/completedCallbackCanStopTrackingWithoutCancellingItself
```

The callback calls `stopTracking` for its own completed identifier and records
`Task.isCancelled`; the exact regression passes with `false`.

## Publication state

No Apple issue or pull request has been published. The local Apple-shaped
handoff remains gated on completion of all programme work and explicit user
authorisation.
