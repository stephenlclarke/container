# Feature request: add a Docker-compatible journald logging provider

## Feature or enhancement request details

The macOS container runtime has an authority-owned logging plane, but it does
not yet provide Docker's `journald` driver. A valid Compose request can
therefore be normalized and persisted without a production Linux service able
to publish it to, or read it from, the system journal.

Add a native provider pinned to the Moby 29.2.1 journald contract. The API
authority must own configuration and provider selection, while a signed,
generation-fenced Linux service owns journal publication, persistence, and
queries.

Expected behavior:

- Accept Docker's `env`, `env-regex`, `labels`, `labels-regex`, `tag`, `mode`,
  and `max-buffer-size` options with Docker template and RE2 behavior.
- Emit Moby-compatible container, image, tag, syslog, priority, timestamp,
  partial-message, epoch, ordinal, and sanitized attribute fields.
- Preserve binary-safe messages and Docker's stdout/stderr priorities.
- Provide native `logs` reads with stdout/stderr, follow, tail, since, until,
  timestamps, and details filtering against journal receipt order.
- Make writer and reader opens idempotent and bind every operation to the
  container lease, provider generation, process generation, sandbox
  generation, and protected effect token.
- Fence stale writers before a replacement workload can publish under the same
  container identity and reconcile response loss without duplicating epochs or
  reader streams.
- Advertise `journald` only while the concrete signed Linux service is
  available and its active sandbox generation can be authenticated.

## Current local implementation boundary

The provider contract, exact Moby field/configuration codec, lifecycle fencing,
native-reader boundary, optional catalog registration, authority configuration,
and focused tests are implemented locally. The shared Linux sandbox now also
has an exact-generation XPC/vsock file-descriptor transport for protected
services. The journald-specific transport now adds an explicit versioned JSON
envelope, one-MiB length-prefixed frames, binary-safe validated projections,
stable operation IDs for response-loss replay, ordered reader-next ordinals,
socket reconnect, `SIGPIPE` suppression, and cancellation that interrupts a
blocked read. The matching server protocol engine now joins identical in-flight
operations, rejects operation-ID conflicts before effects, retains completed
outcomes under count and complete retained-byte limits, maps stable failures,
and serves persistent framed connections. A restart-safe backend now persists bounded
writer and reader state in an atomic private snapshot, reconciles the journal
append crash window by session/epoch/ordinal identity, fences every close
before flushing, resumes readers at their durable sequence and bounded opaque
native-journal checkpoint, rejects stale active-reader generations, and fails
closed if a record does not advance that checkpoint or an end event does. The
local Linux/arm64 workload now binds the production AF_VSOCK listener to that
backend and runs a dedicated systemd-journald process. Its concrete go-systemd
adapter provides digest-checked append reconciliation, query-visible
acknowledgement, receipt-ordered static/follow reads, Docker stream/filter/detail
projection, and restartable opaque checkpoints. Pinned OCI builds record source,
test, archive, and platform-manifest digests and emit BuildKit provenance; a
packaged Swift client round trip against real systemd-journald passes locally.
The provider is intentionally not advertised by the production API server
because authority supervision, release signing and workload installation,
production writer/reader routing, readiness withdrawal, terminal-state
reclamation, migration, and recovery remain to be implemented. The Container
head also currently requires the matched local
Containerization worktree for `WorkloadNetworkEndpoint`; its published
dependency pin predates that protected-workload API and must be synchronized in
the final coordinated wave.

## Scope and non-goals

This change does not add Compose parsing, the public Docker REST/socket
gateway, or Docker logging-plugin hosting. It does not claim journald support
until the production service and external-client evidence are complete.

## Upstream publication

The implementation is retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete parity programme is ready for its coordinated
upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
