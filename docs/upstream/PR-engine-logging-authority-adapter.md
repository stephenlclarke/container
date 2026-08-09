# Pull request handoff: connect Engine logs to the Container authority

## Summary

- Add an enhanced Docker logging backend over the existing
  `ContainersService` catalog, durable configuration, protected-option store,
  canonical readers, and active runtime generation.
- Add a separate lossless, bounded runtime read-record stream for Docker
  details and nanosecond presentation without breaking native compatibility.
- Bridge Docker attach to either that canonical replay/follow reader or the
  exact init-process pipes, with Docker detach keys and canonical lifecycle
  events.
- Expose hijack and WebSocket attach through the same canonical session, and
  map Docker terminal resize onto the exact init process with compatible error
  responses.
- Compose complete Docker `SystemInfo` and `ContainerInspect` documents from
  the same authority, then overlay only logging-owned fields through the
  runtime-neutral fail-closed contract.
- Start one restart-stable enhanced provider session and advertise the complete
  `ContainerAttach`, `ContainerAttachWebsocket`, `ContainerResize`,
  `ContainerLogs`, `ContainerInspect`, and `SystemInfo` generated Engine
  operations.
- Package and sign the common `container-engine` executable, supervise it with
  the Container system lifecycle, expose launch/socket/health status, and stop
  it before deregistering the enhanced authority.
- Keep Docker `/info` catalogue discovery side-effect free so it cannot
  materialise journald merely to report supported drivers, while retaining the
  concrete readiness gate at create/start.
- Compile the enhanced provider's Engine API revision from the same exact
  package version used by SwiftPM.

## Type of change

- [x] Generic Container runtime transport
- [x] API-service authority adapter
- [x] Engine private provider session
- [x] Docker logging REST/streaming projection
- [x] Protected-option authentication
- [x] Unit and provider-session integration tests
- [x] Public Engine listener installation
- [x] Complete `/info` and inspect route composition
- [x] Attach/hijack route advertisement
- [x] WebSocket attach and terminal-resize route advertisement
- [ ] Compose parser behavior

## Authority contract

`ContainerDockerLoggingBackend` delegates to the same `ContainersService`
actor used by native clients. System info reads the injected advertised
catalog without activating lazy providers;
inspect reads the immutable resolved driver and safe options, authenticates any
protected object with its container-bound binding, and exposes `LogPath` only
for the canonical public json-file store. No independent catalog, file reader,
or provider state is constructed by the Engine adapter.

Stopped/static reads use `ContainerLogNativeReaderFactory`. Active follow uses
the exact runtime client's retained logging generation. The new
`ContainerLogReadRecordWireV1` is an explicit transport codec rather than a
generic persistence conformance: decode reconstructs and validates the core
record, and the stream enforces a fixed encoded-record bound. Stream, exact
seconds/nanoseconds, binary payload, attributes, sequence, and process
generation cross the XPC file-descriptor boundary losslessly.

Attach uses the same reader with `follow` for readable drivers, so historical
replay and the retained active generation remain one ordered source. Drivers
without a reader, including `none`, fall back to exact-process output only for
`stream=1`; a finite `logs=1&stream=0` request returns no invented history and
does not open a live runtime attachment. Requested live stdin/stdout/stderr are
attached through the existing `ContainersService` runtime path. TTY output is
merged onto stdout when stdout is selected; a TTY stderr-only request remains
empty, and non-TTY output retains Docker stdout/stderr channels.

Docker permits attach before start. The adapter therefore performs one
lock-serialized, never-started-only bootstrap using the attach stdio. A
concurrent attach or start observes the existing runtime client and attaches
normally; a container with a durable `startedDate` can never be bootstrapped
again by this path.

`ContainerDockerAttachSession` exposes a bounded hijack frame stream. A full
buffer retries the same frame and applies backpressure instead of dropping it.
It consumes the Docker default or requested detach sequence, closes readers
and file handles exactly once across success, failure, disconnect, and runtime
attachment failure, and publishes ordered `attach`/`detach` records through
the canonical service event broadcaster.
Runtime pipe reads are readiness-driven and re-arm only after the current
frame is accepted, preserving backpressure without blocking the Swift
cooperative executor. A remote-provider foreground pump duplicates any handle
it retains asynchronously, keeping descriptor ownership independent of the
bootstrap caller.

Before opening the canonical reader or exact-process pipes, the backend rejects
paused containers and containers waiting in restart-policy backoff with Moby's
exact conflicts. Stopped and stopping containers remain eligible for retained
replay. Closing one attach session closes only that session's duplicated pipe
ends: the runtime's persistent logging destination remains active. Sandbox
shutdown is independently generation-fenced, so replaying an older shutdown
receipt cannot stop a newer live logging generation.

The gateway WebSocket transport consumes that same
`ContainerDockerAttachSession`; it does not create a second reader or runtime
attachment. `ContainerDockerLoggingBackend` also implements the narrow
terminal-resize contract by accepting Docker's complete `UInt32` query domain,
mapping its low 16 bits to Containerization's PTY size, and resizing the init
process through `ContainersService`. Values outside the Docker domain plus
missing and stopped containers retain compatible status and message semantics.
Success publishes one canonical `resize` event with the original 32-bit
dimensions; failure publishes no resize event.

## Provider identity and route gating

`container-apiserver` loads or creates one provider-owned state-root UUID,
builds an enhanced `container-authority` declaration from Container and
Containerization revisions plus exact Engine API release 0.3.5, and starts a
private singleton provider socket. Cancellation shuts the provider down. The
separately packaged common gateway selects that private authority, owns the
public Unix socket, and is registered as a user LaunchAgent by `container
system start`.

The fingerprint advertises `engine.route.ContainerAttach`,
`engine.route.ContainerAttachWebsocket`, `engine.route.ContainerResize`,
`engine.route.ContainerLogs`, `engine.route.ContainerInspect`, and
`engine.route.SystemInfo`. Inspect and info use the same selected Container
authority for the complete base document and the logging overlay. The shared
controller rejects a base missing any non-optional Moby top-level response
field, so a logging fragment cannot masquerade as a whole route. The common
gateway owns WebSocket framing and Docker ping negotiation; those concerns do
not create a second provider authority.

Container persists effective runtime state but not every original Docker
request distinction. The response therefore reports the truthful effective
projection and keeps original Entrypoint-versus-Cmd provenance, durable restart
count, complete health history, and unavailable endpoint/path identities as
explicit later lifecycle/API work; it does not invent those values as parity
evidence.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainerDockerLoggingBackend.swift`
  contains the neutral backend, direct and active-wire readers, runtime attach
  bridge, detach filter, and bounded hijack session.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainerDockerSharedResponseBackend.swift`
  constructs the complete authority-owned system and inspect documents.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  exposes the narrow authority projections and exact reader selection.
- `Sources/ContainerResource/Container/ContainerLogReadRecordWireV1.swift`
  defines the explicit lossless runtime codec.
- `Sources/Services/Runtime/RuntimeClient/RuntimeRoutes.swift` and
  `RuntimeClient.swift` expose the distinct active read-record route.
- `Sources/Services/RuntimeLinux/Server/ContainerLogReaderStream.swift` and
  `RuntimeService.swift` encode the exact retained generation.
- `Sources/APIServer/APIServer+Start.swift` composes the stable enhanced
  provider session.
- `Sources/ContainerCommands/System/ContainerEngineServiceConfiguration.swift`
  owns the safe public socket/state paths and atomic LaunchAgent definition.
- `Sources/ContainerCommands/System/SystemStart.swift`, `SystemStatus.swift`,
  and `SystemStop.swift` install, probe, report, and deregister the gateway in
  the same lifecycle as the Container authority.
- `Sources/ContainerEngineServiceCommand/main.swift` is the thin common
  executable entry point supplied by `container-engine-api`.
- Focused tests cover canonical static reads, protected inspect options,
  lossless active wire, stream cancellation, runtime I/O, detach keys,
  finite unreadable-driver attach, live unreadable-driver output, Docker TTY
  stream selection, split detach and independent re-attach, resize-domain
  conversion, over-capacity no-drop behavior, provider hijack forwarding, and
  lifecycle event ordering.

## Dependency handoff

Container pins `container-engine-api` exactly at 0.3.5, signed revision
`78cb4cb5781d6dbe9f0d34a1b925ee8dcaacdc98`. Validation uses the local signed
Containerization shared-sandbox worktree because the coordinated
Containerization upstream wave has not been published. The build embeds the
published Containerization source and revision while compiling that matched
local work. The manifest's `CONTAINERIZATION_PACKAGE_PATH` and
`CONTAINER_ENGINE_API_PACKAGE_PATH` lane preserves package identity without
SwiftPM editable state; source/ref overrides bind compiled provenance to the
signed local head. The published Containerization pin remains unchanged at
`77f06d4c44341e04241941072fb69e2b85a6f5c1`.

No Apple issue, pull request, branch publication, or push has been created.
The complete change remains local until all parity development is complete.

## Validation

```console
swift build --target ContainerAPIService
swift build --target container-apiserver
swift test --filter 'ContainerDockerAttachSessionTests|engineLoggingBackendUsesAuthoritativeInspectionAndExactReader'
swift test --filter 'ContainerLogReaderStreamTests|ContainerLogsTests.engine|ContainerLoggingAuthorityIntegrationTests.engineInspect'
swift test --filter 'ContainerLogsTests|ContainerDockerAttachSessionTests'
swift test --skip-build -c debug \
  -Xswiftc -warnings-as-errors -Xswiftc -enable-testing \
  --no-parallel --skip TestCLI --skip IntegrationTests
make check
git diff --check
```

Current development MacBook Pro evidence:

- Container API service and APIServer targets build against the local signed
  Containerization dependency;
- focused authority/runtime/provider integration: 5 tests in 3 suites passed;
- focused attach/hijack/provider integration: 5 tests in 2 suites passed;
- focused Engine logs, hijack, WebSocket, and resize integration: 38 tests
  passed;
- focused finite-history, TTY selection, resize-domain/event, and split
  detach/re-attach slice: 5 tests in 2 suites passed under warnings-as-errors
  against local Containerization `38d9c695` and Engine API `5e52a0f4`;
- focused attach-state/shutdown slice: 3 tests in 3 suites passed under
  warnings-as-errors, covering paused and restart-backoff conflict selection,
  persistent logging after client disconnect, and stale-generation shutdown
  fencing;
- focused created-attach/output-ownership slice: 3 Engine attach tests, 5
  bounded attach-session tests, and 1 remote foreground test passed; the
  foreground test closes the caller descriptor immediately after bootstrap;
- same-MBP pinned Docker Engine 29.2.1 and signed Container candidate both pass
  the identical terminal-session oracle: pre-start 101 upgrade, 204 start,
  `READY`, 48-by-132 resize observation, `ctrl-x` detach with the workload still
  running, 101 re-attach, `AFTER`, clean zero exit, EOF, and 204/404 cleanup.
  Companion Engine API commit
  `c7973ac641fb6f6e07df1358114f36222bd9ca59` reduces the candidate from
  4.359129 seconds to 1.238173 seconds cold and 0.920554 seconds warm against
  the 0.184992-second Docker fixture;
- pinned Moby 29.2.1 source `6bc6209b` confirms 32-bit resize parsing and exact
  requested stream selection; a same-MBP Docker 29.5.2 black-box check returned
  TTY bytes for stdout/both but none for stderr-only, accepted `UInt32.max`,
  and rejected `UInt32.max + 1`;
- same-MBP Docker 29.5.2 black-box attaches returned 200 plus retained output
  for a stopped container and exact 409 conflicts for paused and restart-policy
  backoff containers;
- complete matched Container validation: 1,835 Swift Testing tests in 213
  suites plus 94 XCTest tests passed with zero failures;
- isolated signed-package lifecycle: `system start`, JSON `system status`,
  `/_ping`, unversioned Docker CLI `info`, `/v1.53/info`, `system stop`, and
  public-socket cleanup passed;
- live `/_ping` completed in 0.000940 seconds and `/info` in 0.004817 seconds;
- live `/info` reported `json-file` as the default and exactly `awslogs`,
  `fluentd`, `gcplogs`, `gelf`, `journald`, `json-file`, `local`, `splunk`, and
  `syslog` as available drivers without materialising journald;
- Homebrew checksum, init-image installation, and Developer ID archive gates
  passed;
- formatting, licence, and whitespace gates passed;
- signed implementation commit:
  `2d7512c54cfe2fc01d506e08c0300d6f432fd437`;
- signed attach/hijack implementation commit:
  `72a76ab596e95fa775593bc3bcbef67135c384e4`;
- signed complete-response implementation commit:
  `9e23d41fc18dde5ae926e0cbdd1f35d8c86fc512`;
- signed WebSocket attach and terminal-resize implementation commit:
  `6a668b2b5d42246efcad3316374f6d0e0d2eaf14`;
- signed public-gateway lifecycle and discovery fix commit:
  `ac1803ec555960ce49fcec1d6a5b718d781629e0`;
- Engine API 0.3.5 dependency resolves to signed commit
  `78cb4cb5781d6dbe9f0d34a1b925ee8dcaacdc98`;
- the enhanced provider-session integration returns the authority identity,
  container/image counts, complete inspect state/config/host configuration,
  resolved logging options, public json-file path, logs, attach frames, and
  attach/detach events in one passing test.
- signed local commit `08677dc8b5a677533de80cf634fee1d14f4da069`
  adds the isolated Docker logging-plugin service and routes its direct
  `ReadLogs` sessions through this same authority.

## Review checklist

- [x] Engine reads the native authority rather than a parallel log source.
- [x] Protected options require authenticated container ownership.
- [x] Active records retain attributes and exact nanoseconds.
- [x] Existing native compatibility streaming is unchanged.
- [x] Wire decoding re-enters bounded core-record validation.
- [x] Provider identity is stable across APIServer restart.
- [x] Only complete generated Engine operations are advertised.
- [x] Attach replay/live, stdin/TTY, detach-key, bounded transport, and
  lifecycle-event semantics use one authority path.
- [x] WebSocket attach reuses the canonical session and resize maps to the
  exact init process with Docker-compatible range, event, and failure behavior.
- [x] Paused and restart-backoff attach failures happen before replay/live side
  effects; disconnect and stale shutdown cannot terminate persistent/newer
  logging generations.
- [x] Created-container attach wins or joins an atomic bootstrap, live output
  is readiness-driven, and the paired Docker/candidate terminal oracle passes.
- [x] Compose whole `/info` and inspect responses before advertising them.
- [x] Install and supervise the public gateway.
- [ ] Complete the remaining external-client route/certification matrix and
  typed guest grant before enabling `use_api_socket`.

## Owned issue tracking

- [container#45](https://github.com/stephenlclarke/container/issues/45)
  records the `/info` journald-activation stall and its side-effect-free
  advertised-catalog regression test.
- [container#46](https://github.com/stephenlclarke/container/issues/46)
  records the stale Engine API revision and its exact resolved-version test.
