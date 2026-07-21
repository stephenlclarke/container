# Compatibility gap: Docker-shaped terminal container events

## Summary

`container events` previously exposed the generic lifecycle actions `stop` and
`delete`, but did not describe why a process ended or provide the Docker
terminal actions that Compose consumers expect. As a result, a macOS Compose
adapter could not present Docker Compose V2-compatible `kill`, `die`, and
`destroy` records without inventing lifecycle state above the runtime.

## Docker Compose V2 behavior

For a selected service, Docker Compose V2 emits a `kill` action with the
delivered signal, a `die` action when the init process exits, and a `destroy`
action when the container is removed. An exit code is carried with `die` where
the runtime observed one. Generic stop/removal events are not a substitute for
those action names: Compose uses them to distinguish a signal, a terminal
process result, and resource teardown.

## Existing Apple primitive

The `ContainerSnapshot` already stores the terminal exit code and exit date,
and `ContainersService` already owns process signal delivery, exit monitoring,
and cleanup. This change needs no OCI model expansion and no new
`containerization` API. It is a small generic event-projection enhancement in
`apple/container`.

## Required behavior

- Emit `kill` after a successful generic kill request, with `process` and a
  canonical numeric `signal` attribute when the signal is known.
- Emit `die` before the existing generic `stop` event whenever the init process
  becomes stopped; attach `exitCode` when the runtime has observed it.
- Retain `delete` for existing generic event consumers and then emit the
  Docker-shaped matching `destroy` action.
- Make forced deletion report the SIGKILL terminal result (`137`) before its
  removal actions.
- Keep an auto-removed container's terminal and removal records ordered as
  `die`, `stop`, `delete`, `destroy`.

## Scope and non-goals

This is a macOS runtime event vocabulary change. It does not add a Docker
daemon, Docker socket, Linux-only OOM reporting, Windows behavior, or an
Apple-specific Compose protocol. Docker events for OOM, automatic restart,
rename, resize, update, attach/detach, and exec remain independent follow-up
work.

## Acceptance checks

- Unit tests cover action ordering plus `exitCode`, signal, and process
  attributes.
- `container-compose` consumes the generic events through an adapter and
  filters the retained generic `delete` record so Compose reports one Docker
  removal action.
- A checked-in Docker Compose V2 fixture observes `create`, `start`, `kill`,
  `die`, and `destroy` for a real selected service.
