# Apple PR Handoff: Client-Side Attach Detach Keys

## Summary

Add a narrow client-side detach path for the generic `container attach` command.
It recognizes Docker-compatible `ctrl-p,ctrl-q` by default (or an explicit
`--detach-keys` override), then disconnects only the local XPC client session.
The running init process and its durable stream relay remain untouched.

## Why this belongs in `apple/container`

The compose plugin can choose a service and forward its detach-key option, but
only the generic container CLI owns terminal raw mode, stdin forwarding, and
the XPC `wait()` session that must be ended safely. A Compose-only escape
parser would leave generic `container attach` incomplete and could not resolve
its outstanding runtime wait.

## Proposed Change

- Add a `DetachKeySequence` parser/matcher in `ContainerAPIClient`.
- Add `ClientProcess.disconnect()` to close the XPC connection that belongs to
  the active client session; it does not kill or stop the process.
- Let `ProcessIO` withhold a possible sequence prefix, forward mismatches
  byte-for-byte, and return zero after a full match.
- Add `container attach --detach-keys string` while keeping the default
  `ctrl-p,ctrl-q` sequence.

## Non-goals

- No API-server route or runtime state transition.
- No Compose-specific service discovery or replica handling.
- No global Docker configuration support in this slice.

## Validation

- Parser tests cover the Docker syntax and invalid input.
- Matcher tests cover prefix buffering, mismatch forwarding, and complete
  detach recognition.
- A runtime smoke should attach, detach, then reattach to the same running TTY
  container and verify it was not stopped.

## Follow-on Consumer

`container compose attach --detach-keys` can forward the value once this fork
revision is published. The Compose layer retains service/index lookup and help
colouring.
