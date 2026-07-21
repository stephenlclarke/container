# Pull request: add Docker-shaped terminal container events

## Summary

- Add generic `kill`, `die`, and `destroy` event actions while retaining the
  existing `stop` and `delete` actions for generic clients.
- Attach `process` and canonical signal information to `kill`; attach
  `exitCode` to `die` when known.
- Report SIGKILL (`137`) consistently for forced deletion and a SIGKILL sent to
  a container's init process.
- Preserve a clear lifecycle ordering: terminal `die` precedes generic `stop`,
  and generic `delete` precedes Docker-shaped `destroy`.

## Apple-shaped boundary

- `apple/containerization`: no change. OCI defines process exit state but not a
  Docker event stream.
- `apple/container`: generic event projection only. Existing process,
  exit-monitor, and cleanup boundaries emit the additional lifecycle records.
- `container-compose`: a separate minimal adapter renders Docker-shaped actions
  and suppresses the retained generic `delete` record to avoid a duplicate
  removal event.

The runtime API remains useful independently of Compose. No Compose type,
protocol, or Docker Engine behavior enters the fork.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  centralizes terminal, removal, and kill event construction beside the
  existing lifecycle coordinator.
- `Tests/ContainerAPIServiceTests/ContainerEventBroadcasterTests.swift` covers
  the new action ordering and attributes without requiring a live VM.
- The downstream Compose handoff owns the adapter, Docker Compose V2 fixture,
  parity script, and consumer validation.

## Validation

Completed locally on macOS:

```sh
swift test --disable-automatic-resolution \
  --filter ContainerEventBroadcasterTests --no-parallel
make check
make coverage-unit
git diff --check
```

The focused suite passed all 9 event-broadcaster tests. The full unit coverage
run completed successfully and reports 38.03% line coverage for the existing
wide runtime test graph; the new terminal projection paths are directly
exercised by focused unit tests. The repository's standard formatting, license,
and Hawkeye checks passed.

The downstream checked-in fixture is validated with Docker Compose V2 5.3.1
and asserts `create`, `start`, `kill`, `die`, and `destroy` action presence for
a selected service.

## Compatibility and risks

Existing `container events` consumers retain `stop` and `delete`. Consumers
that want Docker semantics can select the new action names without losing the
older stream. `die` carries an exit code only when the runtime observed one,
which prevents fabricated process results for externally interrupted runtime
services. This PR deliberately does not claim complete Docker event parity.

## Commit tracking

- Generic runtime implementation and tests:
  [`7ed57b18a7dbadddea21007d0a2c17d0ae399fa0`](https://github.com/stephenlclarke/container/commit/7ed57b18a7dbadddea21007d0a2c17d0ae399fa0),
  `feat(runtime): add Docker terminal lifecycle events`.
- The Compose consumer handoff will reference its companion adapter commit,
  package pin, parity fixture, and status-ledger update.

## Non-goals

- Docker daemon/API/socket emulation.
- Linux OOM action reporting or Windows event behavior.
- Automatic-restart, rename, resize, update, attach/detach, or exec event
  actions.
