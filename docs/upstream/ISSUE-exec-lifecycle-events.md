# Feature request: Docker-compatible exec lifecycle events

## Feature or enhancement request details

`container events` reports generic container lifecycle activity but did not
report the three Docker actions emitted for a user-created exec process:
`exec_create`, `exec_start`, and `exec_die`. That prevented downstream Docker
Compose-compatible clients from observing the command lifecycle or its terminal
exit code without reconstructing it above the runtime.

Docker Engine emits `exec_create: COMMAND`, `exec_start: COMMAND`, and
`exec_die`, attaching an `execID` to each record and the terminal `exitCode`
to `exec_die`. Automatic container restart is unrelated: Docker represents it
as a container `die` event followed by `start`, rather than a `restart` action.

The existing `ContainersService` already owns process creation, start, exit
observation, container cleanup, and event publication. Add a small generic
event tracker that records only user-created non-init processes, uses the
existing process configuration to render Docker's readable action suffix,
publishes the start and terminal records, and cancels or forgets observers when
the container is removed.

This macOS runtime change does not add a Docker daemon, Docker socket,
Linux-only OOM telemetry, Windows behavior, Compose imports, or a new
`containerization` protocol. Generic clients retain their existing container
lifecycle actions. A downstream Compose adapter can transparently pass the new
generic records after removing its private labels.

Acceptance checks:

- Emit `exec_create: COMMAND` after successful creation of a non-init process.
- Emit `exec_start: COMMAND` after the runtime starts that process.
- Emit one `exec_die` with `execID` and `exitCode` when it exits, including
  detached processes and concurrent caller waits.
- Do not add lifecycle-only `status` metadata to exec records.
- Cancel detached-process observers and clear their transient metadata during
  container cleanup.
- Cover event spelling, metadata, absent or duplicate terminal paths, and
  cleanup in focused unit tests; validate the downstream checked-in Docker
  Compose V2 fixture separately.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
