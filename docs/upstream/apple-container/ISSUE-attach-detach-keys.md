# Detach an Interactive Attach Session Without Stopping the Container

## Problem

`container attach` can now reattach the init-process streams of a running
container, but it cannot end a terminal session while leaving the service
running. `ClientProcess.wait()` is an in-flight XPC request and task
cancellation alone does not resolve that wait.

Docker-compatible attach clients reserve `ctrl-p,ctrl-q` by default, with a
per-invocation `--detach-keys` override. The terminal client must consume that
sequence, close only its stream/session resources, and return successfully; it
must not send a signal to the init process.

## Proposed Minimal Primitive

- Keep detach-key parsing and byte matching entirely client-side.
- Add `ClientProcess.disconnect()` to close only the XPC connection that owns
  the caller's outstanding wait request.
- When the key matcher completes, close the attach client's stdin writer,
  resolve the local wait by closing that XPC connection, restore the terminal,
  and return zero.
- Do not add an API-server route, process state, or a server-side detach
  operation. The durable stream relay already owns process lifetime.

## Scope

Included:

- Generic `container attach --detach-keys` and Docker-compatible default
  `ctrl-p,ctrl-q` parsing for TTY sessions.
- A cancellation boundary for the client session that is waiting on a running
  process.
- Unit coverage for valid syntax, invalid syntax, prefix buffering, and a
  complete detach match.

Excluded:

- Compose service/index selection. `container compose attach` should only pass
  the user-provided key sequence to the generic command.
- Server protocol changes, process signals, and exec/run/start behaviour.
- Global Docker `config.json` detach-key settings; only the command override
  and standard default are in scope.

## Acceptance Checks

- Attach to a detached, running TTY container; enter `ctrl-p,ctrl-q`; the CLI
  exits zero and the init process remains running.
- Attach a second time and confirm the same process receives input/output.
- Verify a non-matching prefix is forwarded byte-for-byte to the guest.
- Verify malformed `--detach-keys` values fail before the attach session is
  created.
