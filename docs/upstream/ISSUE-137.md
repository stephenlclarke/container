# Issue 137: make native init wait observe committed terminal state

## Problem description

The native container wait route could return an init-process exit status before
the exit monitor committed the container snapshot to a terminal state. A caller
that immediately performed normal deletion could therefore receive
`invalidState` because the container still appeared to be `running`.

## Resolution

Init-process waits now use the existing cancellation-aware lifecycle waiter and
return only when the authoritative container state is no longer live.
Exec-process waits retain their direct runtime process semantics.

## Focused evidence

- The native wait regression covers an init container whose committed state is
  already non-running.
- The Container Compose lifecycle-hooks parity contract covers a short-lived
  helper followed immediately by normal deletion.

## Scope

This changes the ordering guarantee for init-process waits. Exec-process wait
behavior is unchanged.

Refs [#137](https://github.com/stephenlclarke/container/issues/137).
