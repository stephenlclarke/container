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

The complete provider/runtime path is implemented locally. It includes the
exact Moby field/configuration codec, authority lifecycle fencing, native
reads, a versioned and bounded replay-safe Swift/Go wire, a restart-safe
backend, a concrete go-systemd adapter, and a pinned Linux/arm64 OCI workload.

The production API server now verifies the installed archive and manifest,
loads only the recorded platform digest, materializes a read-only service with
separate protected protocol-state and persistent-journal mounts, and
supervises it through the common Engine Linux sandbox. Service connections are
bound to the exact sandbox ID/generation, workload ID/process generation, and
vsock port. Terminal exit immediately withdraws the running receipt, exact
rematerialization is supported, and the catalog probes the live service so
`journald` disappears whenever readiness cannot be authenticated.

Protocol version two adds authority-ordered terminal writer/reader
reclamation. The lifecycle ledger commits terminal state before provider
reclamation and protected-effect deletion, and startup recovery repeats any
interrupted removal idempotently. Same-generation service restarts preserve
exact replay; a validated sandbox-generation advance atomically retires old
protocol sessions while retaining the persistent system journal.

Local evidence includes warnings-as-errors Swift tests, Thread Sanitizer for
the shared-sandbox runtime, Go race tests, deterministic OCI builds, integrity
verification, release staging, and a Swift-to-packaged-Linux round trip against
real systemd-journald. The signed production supervision/reclamation commit is
`84d160671f3ba6c265a02b49b2ff4309f6584d30`.

The remaining programme-level blockers are release-signature trust
publication, synchronization of Container's dependency pin with the matched
Containerization protected-workload API, paired Docker CLI/Compose behavior
and performance certification, and the separate isolated Docker
logging-plugin service plane. Final install/upgrade/rollback and whole-stack
shutdown evidence must be recorded under the synchronized signed dependency
set.

## Scope and non-goals

This change does not add Compose parsing, the public Docker REST/socket
gateway, or Docker logging-plugin hosting. Journald's production runtime path
is locally implemented, but programme-wide parity is not claimed until the
remaining release-trust, dependency, external-client, and performance evidence
is complete.

## Upstream publication

The implementation is retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete parity programme is ready for its coordinated
upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
