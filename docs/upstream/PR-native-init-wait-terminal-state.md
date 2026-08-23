# Pull request 138: synchronize native init wait completion

## Summary

Native init-process waits now complete only after the authoritative container
lifecycle state has reached a terminal snapshot. Direct runtime waits remain in
place for exec processes.

## Review focus

- The lifecycle waiter is cancellation-aware and does not poll.
- The response preserves the committed terminal status and exit timestamp.
- Container deletion can safely follow a successful init-process wait without
  racing the exit monitor.

## Focused evidence

- `dockerContainerWaitUsesNativeLifecycleStateAndRemoval` passes.
- The matched Container Compose lifecycle-hooks parity contract passes the
  short-lived helper execution and normal deletion sequence that exposed the
  race.

Closes [#137](https://github.com/stephenlclarke/container/issues/137).
Tracks [#138](https://github.com/stephenlclarke/container/pull/138).
