# Runtime gap: enhanced Engine logging authority adapter

## Problem

The runtime-neutral `container-engine-api` logging controller and private
provider session existed, but the enhanced Container authority did not provide
a production backend or register a stable provider identity. Docker Engine log
requests therefore could not read the same catalog, resolved configuration,
protected options, canonical stores, or active logging generation as native
Container clients.

The existing active-runtime compatibility stream also projected records onto
the older `ContainerLogRecord` shape. That intentionally retained native API
compatibility but lost driver attributes and converted the exact timestamp
through `Date`, so it was not a sufficient source for Docker `logs --details`
or nanosecond timestamp presentation.

## Required behavior

- Pin the runtime-neutral `container-engine-api` package at exact release
  `0.3.5`.
- Project `/info` logging fields, inspect `LogConfig`/`LogPath`/TTY, and
  container logs from the existing `ContainersService` authority.
- Project the authority-owned advertised driver catalog for every info request
  without activating a lazy provider or materialising its sandbox.
- Authenticate protected logging options against the durable container-bound
  reference before exposing the authorized Docker inspect projection.
- Read stopped containers from the canonical driver-neutral reader and active
  follow requests from the exact retained runtime logging generation.
- Preserve stream identity, payload, attributes, and seconds/nanoseconds
  without routing through the older compatibility record.
- Bound and version the new runtime wire representation and close/cancel its
  file descriptor deterministically.
- Start one private provider-session server with a restart-stable state-root
  identity and an enhanced Container authority fingerprint.
- Advertise only complete generated Engine operations. Shared `/info` and
  inspect routes use one complete authority document and a fail-closed logging
  overlay; a partial fragment cannot replace either whole route. Attach is
  advertised only after replay/live handoff, stdin/TTY and detach-key handling,
  bounded hijack and WebSocket transports, resize, and canonical attach/detach
  events are one authority-owned path.

## Acceptance evidence

- [x] Exact `container-engine-api` 0.3.5 dependency and resolved pin.
- [x] Authority-backed default driver and registered-driver projection.
- [x] Authority-backed resolved inspect options, public json-file path, and TTY.
- [x] Protected option values are authenticated at the authorized Engine
  inspect boundary and remain absent from diagnostics and error messages.
- [x] Static reads retain stream, payload, attributes, and nanoseconds.
- [x] Active follow has a separate bounded `ContainerLogReadRecordWireV1`
  runtime route and does not change the older native compatibility route.
- [x] EOF, close, cancel, partial record, and record-size handling are bounded.
- [x] The APIServer starts one private provider session under a stable
  provider-owned state-root UUID.
- [x] Docker attach replays readable history and follows the retained active
  generation without a replay/live gap; unreadable drivers fall back to the
  exact process streams only when `stream=1`, without fabricating history or
  turning finite `logs=1&stream=0` requests into live attachments.
- [x] Runtime stdin/stdout/stderr use exact-process attachment, TTY output is
  merged only onto requested stdout while TTY stderr-only requests stay empty,
  Docker detach keys are consumed server-side, and slow hijack clients cannot
  create an unbounded allocation or silently lose buffered frames.
- [x] Detach sequences split across client frames remain atomic, consume no
  guest input bytes, leave the process running, and permit an independent
  re-attach session.
- [x] Attach session setup, EOF, input close, cancellation, reader failure, and
  failed runtime attachment close every local handle and reader exactly once.
- [x] Canonical `attach` and `detach` events use the existing service event
  broadcaster and immutable authority snapshot.
- [x] WebSocket attach uses the same authority-owned canonical session as
  hijack attach and preserves the same stream and lifecycle semantics.
- [x] Terminal resize maps exact Docker dimensions to the init process and
  accepts the full Docker `UInt32` domain before using the PTY's low 16-bit
  representation; overflow, missing-container, and stopped-container errors
  remain Docker compatible.
- [x] Successful Engine resize publishes one canonical `resize` event with the
  original 32-bit `height` and `width`; failed resize publishes none.
- [x] The provider fingerprint declares `engine.route.ContainerAttach`,
  `engine.route.ContainerAttachWebsocket`, `engine.route.ContainerResize`, and
  `engine.route.ContainerLogs`.
- [x] The same authority supplies complete Docker `SystemInfo` and
  `ContainerInspect` documents, the shared controller verifies Moby's
  non-optional top-level contract, and only logging-owned fields are overlaid.
- [x] The provider fingerprint declares `engine.route.SystemInfo` and
  `engine.route.ContainerInspect` only in complete-response mode.
- [x] The common gateway owns Docker `GET /_ping` and `HEAD /_ping`
  negotiation independently of provider capability and is released in
  `container-engine-api` 0.3.5.
- [x] `container system start` installs and supervises the signed common
  gateway at `/tmp/container-engine-<uid>/docker.sock`; status reports its
  launch and health state, and stop deregisters it before the authority.
- [x] Docker `/info` catalogue discovery is side-effect free and does not
  activate the journald sandbox. Concrete create/start validation still checks
  provider readiness and fails closed.
- [x] The enhanced provider declaration reports the exact Engine API release
  compiled from the same authoritative package constant.
- [x] Focused controller/backend, protected-option, active-wire, runtime-stream,
  and provider-session tests pass on the development MacBook Pro.
- [x] The complete matched suite passes on the development MacBook Pro: 1,835
  Swift Testing tests in 213 suites plus 94 XCTest tests, with zero failures.
- [x] An isolated signed package passes `system start`, JSON `system status`,
  Docker CLI unversioned and `/v1.53/info`, `/_ping`, and exact shutdown/socket
  cleanup on the development MacBook Pro.

## Remaining Engine logging work

- Certify real-runtime TTY resize and detach/re-attach behavior. Attach wait
  currently reports the runtime process exit where it is needed to keep an
  input-only session alive; the Docker hijack protocol itself does not expose
  that code to the HTTP client.
- Direct isolated-provider `ReadLogs` sessions now route through the authority
  in signed local commit `08677dc8b5a677533de80cf634fee1d14f4da069`.
  Complete installed third-party plugin certification, staged provider
  generation upgrades, devcontainer logging handoff,
  migration/security/performance evidence, and the remaining Docker
  Compose/Testcontainers/devcontainer external-client certification.
- Complete the typed guest socket grant, remaining Docker REST handlers, and
  authority handoff before claiming `use_api_socket` closure. Public gateway
  installation and Docker CLI info negotiation are now live-proven locally.
- Publish or land the matched Containerization sandbox/workload APIs. The
  canonical public `77f06d4` pin cannot compile this existing branch; the
  signed local `864455b` dependency passes the complete matched suite and must
  remain local until the coordinated Apple-bound wave is ready.

## Apple-shaped boundary

The runtime wire and enhanced authority adapter are retained on the local
`upstream/logging-driver-parity` branch. They include no Compose parsing and do
not publish to Apple. The handoff is held for coordinated upstream submission
only after the complete parity programme is finished.

## Commit tracking

- `2d7512c54cfe2fc01d506e08c0300d6f432fd437` — signed authority
  backend, exact active-record wire, provider composition, and focused tests.
- `72a76ab596e95fa775593bc3bcbef67135c384e4` — signed bounded Docker
  attach/hijack, exact-process I/O, detach keys, lifecycle events, route
  advertisement, and focused tests.
- `9e23d41fc18dde5ae926e0cbdd1f35d8c86fc512` — signed complete `SystemInfo`
  and `ContainerInspect` authority projection, fail-closed logging composition,
  exact Engine API 0.2.3 pin, route advertisement, and provider-session tests.
- `6a668b2b5d42246efcad3316374f6d0e0d2eaf14` — signed WebSocket attach and
  terminal-resize implementation, Docker-compatible resize errors, exact
  Engine API 0.3.4 pin, route advertisement, and provider-session tests.
- `ac1803ec555960ce49fcec1d6a5b718d781629e0` — signed Engine API 0.3.5
  service packaging and lifecycle, side-effect-free info discovery, exact
  provider provenance, focused regressions, matched full suite, and isolated
  Docker CLI validation.
- This slice — keep finite unreadable-driver attach requests finite
  while retaining live exact-process output and matching Docker's TTY stream
  selection and resize domain.
