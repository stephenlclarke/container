# Pull request: add Docker-compatible exec lifecycle events

> [!IMPORTANT]
> All commits in this handoff are signed and verified.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker-compatible event consumers need to distinguish creation, start, and
terminal completion of an exec process. The generic runtime already has the
necessary process and event ownership, so this is a focused event-projection
addition rather than a Docker API emulation layer.

## Implementation

- Add `ContainerExecEventTracker`, a `ContainersService`-internal state holder
  that renders `exec_create: COMMAND`, `exec_start: COMMAND`, and exactly one
  `exec_die` per user-created process.
- Attach Docker-shaped public metadata: image, ordinary user labels, `execID`,
  and terminal `exitCode`; do not reuse container-only `status` metadata.
- Start a lightweight exit observer after a non-init process starts so detached
  execs also produce `exec_die`; a caller's own wait remains supported by the
  runtime's existing wait boundary.
- Cancel observer tasks and discard transient tracker state during container cleanup.
- Keep the change entirely in `apple/container`; no Compose type, label,
  protocol, or Docker Engine behavior enters the fork.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainerExecEventTracker.swift`
  owns the Docker-compatible action spelling, attributes, single-terminal-event
  invariant, and cleanup state.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  integrates the tracker at existing process create, start, wait, and cleanup
  boundaries.
- `Tests/ContainerAPIServiceTests/ContainerEventBroadcasterTests.swift`
  exercises every tracker path: creation, start, terminal exit, duplicate
  suppression, missing state, configuration lookup, and cleanup.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Completed locally on macOS: `swift test --disable-automatic-resolution
--filter ContainerEventBroadcasterTests`, `make check`, `make coverage-unit`,
and `git diff --check`.

The focused suite passed all 10 event-broadcaster tests. The full unit coverage
workflow passed and increased the existing broad runtime graph from 37.99% to
38.00% line coverage; the new tracker paths are directly exercised by its
focused unit test. The standard formatting, license, and Hawkeye checks passed.

The companion `container-compose` handoff pins this commit, verifies transparent
adapter rendering, and uses its checked-in Docker Compose V2 event fixture to
confirm `exec_create`, `exec_start`, `exec_die`, `execID`, and exit code
behavior against Docker Compose V2.

## Compatibility and risks

Existing generic event consumers retain their event stream unchanged. New action
names are additive and use Docker's public metadata conventions. The tracker
deliberately skips the init process, because the existing container `start` and
`die` records describe it. Automatic policy restart remains Docker-compatible
`die` then `start`; explicit restart, OOM, rename, resize, update,
attach/detach, and other unimplemented Docker actions remain outside this
change.

## Commit tracking

- Generic runtime implementation and focused tests:
  [`735e8aaec538a1d043d97525074e4175ae1ac10f`](https://github.com/stephenlclarke/container/commit/735e8aaec538a1d043d97525074e4175ae1ac10f),
  `feat(runtime): add exec lifecycle events`.
- Downstream Compose adapter, dependency pin, help/status update, and Docker
  Compose V2 fixture validation: recorded in the companion `container-compose`
  handoff after its signed commit is available.

## Non-goals

- Docker Engine, socket, or API emulation.
- Windows behavior or Linux-only OOM event telemetry.
- Explicit restart, rename, resize, update, attach/detach, and other Docker
  event actions.
