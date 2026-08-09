# Stale runtime services can hang stop and deletion indefinitely

## Impact

A container can have a persisted `.stopped` snapshot while its per-container
runtime launchd service remains loaded and unresponsive. `container stop`,
targeted deletion, `delete --all`, and `system stop` can then wait indefinitely
in one of two places:

- `ContainersService.stop` contacts the stale runtime even though the durable
  state already says that the container is stopped.
- `RuntimeClient.stop`, `RuntimeClient.shutdown`, and `launchctl bootout` have
  no response deadline, so an unresponsive XPC peer or launchd job can hold the
  caller forever.

This was reproduced on Apple silicon with a stopped snapshot whose runtime job
remained present in the user launchd domain. Killing that exact runtime job
allowed `bootout` and deletion to complete.

## Required behavior

- Treat stopping an already-stopped snapshot as an idempotent no-op.
- Bound runtime stop and shutdown XPC response waits.
- Bound `launchctl bootout` when deregistering or replacing a service.
- If `bootout` times out, kill only the exact service with `SIGKILL`, then make
  one bounded `bootout` retry.
- Preserve existing status handling for ordinary, non-timeout launchctl
  failures.

## Apple-shaped implementation

Keep the correction in the generic runtime and service-management layers:

- derive the stop response deadline from the requested guest grace period,
  with five seconds of teardown allowance and a ten-second minimum;
- use a five-second shutdown response deadline;
- run service deregistration with a five-second launchctl deadline; and
- terminate only the timed-out launchctl process before applying the exact-job
  launchd recovery sequence.

No Compose-specific policy or broad launchd cleanup belongs in this change.

## Focused regressions

```sh
swift test --filter ServiceManagerTests
swift test --filter ContainerStopDispositionTests
swift test --filter RuntimeClientTimeoutTests
```

The tests cover normal deregistration, timeout kill-and-retry ordering,
ordinary launchctl failure, all runtime snapshot states, and stop/shutdown
deadline policy.

## Local issue

The fork tracks the observed bug as
`stephenlclarke/container#42`. It should be closed with the signed local
checkpoint and focused validation evidence once this handoff is recorded.

## Publication state

No Apple issue or pull request has been published. The local Apple-shaped
handoff remains gated on completion of all programme work and explicit user
authorisation.
