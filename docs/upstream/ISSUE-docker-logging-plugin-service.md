# Runtime gap: isolated Docker logging-plugin service

## Problem

Container had a Docker logging-plugin codec and an in-process adapter, but no
production service that could host an approved Linux plugin inside the shared
Engine sandbox. The macOS actor owned transient FIFO, token, and reader state.
An API-service restart could therefore forget an uncertain plugin effect, and
the authority could neither attach a direct `ReadLogs` reader nor prove that a
retry had not created a duplicate plugin session.

The missing isolation boundary also left no protected installation contract for
the plugin image, private Unix socket, service authentication key, durable
claims, or provider-generation-specific workload.

## Required behavior

- Discover only approved logging plugin bundles with an exact, closed manifest.
- Verify protected regular files, OCI/source digests, Linux/arm64 identity, the
  exact image manifest, provider identity/generation, driver names, aliases,
  capability, AF_VSOCK port, and private Unix socket before advertisement.
- Reject collisions with core and maintained built-in drivers, provider IDs,
  provider generations, and service ports without partial registration.
- Run the plugin and lifecycle service in one pinned OCI workload inside the
  shared Engine Linux sandbox, with a read-only root filesystem and only the
  required private writable runtime paths.
- Authenticate every bounded Swift-to-Go request before durable state, plugin,
  FIFO, or listener initialization.
- Persist writer and reader claims before effects and return stable private
  receipts across response loss.
- Reconcile tokenlessly without a duplicate `StartLogging` or `ReadLogs` call.
- Stream Docker's four-byte big-endian protobuf frames through real Linux FIFOs,
  with kernel backpressure, cancellation, and peer-HUP handling.
- Stop before graceful FIFO removal and revoke before authoritative fencing.
- Provide direct readable-plugin sessions, sequence-stable frame replay, EOF,
  cancellation, terminal digest, and authority-ordered reclamation.
- Keep write-only plugins unreadable and never call their `ReadLogs` endpoint.
- Bound connections, waiters, replay memory, state, frames, sessions, and
  responses.

## Acceptance evidence

- [x] Closed manifest decoding and protected asset verification.
- [x] Exact OCI archive and Linux/arm64 workload-manifest verification.
- [x] Reserved name, provider, generation, and service-port collision rejection.
- [x] Shared-sandbox lazy workload materialization and readiness probing.
- [x] Read-only workload root with private tmpfs `/run` and `/tmp` mounts.
- [x] Private mode-0600 HMAC-SHA256 key loaded before all service bootstrap.
- [x] Bounded authenticated framed JSON transport with persistent connection
  pooling and immediate queued-waiter cancellation.
- [x] Durable writer and reader claims, stable tokens, reconciliation,
  uncertainty, replay, terminal effects, and reclamation.
- [x] Real Linux FIFO write, cancellation, stop ordering, and fence ordering.
- [x] Real readable and write-only Unix HTTP plugin conformance, including the
  absence of `ReadLogs` for the write-only case.
- [x] Authority configuration binding carries exact Docker `Info`, all options,
  lease, provider generation, and semantic request digest.
- [x] Direct provider readers are routed through the authority and remain
  separate from live process attachment.
- [x] macOS Go race tests and vet pass at 70.2% statement coverage.
- [x] Pinned Linux/arm64 Go race tests pass at 74.1% statement coverage.
- [x] Focused Swift plugin/provider/authority suites pass under
  warnings-as-errors.
- [x] The scoped Container gate passes 1,852 Swift Testing tests in 216 suites
  plus 94 XCTest tests.
- [x] Repository formatting, licence, Markdown, and whitespace gates pass.

## Remaining programme work

- Retain generation N while generation N+1 is staged, activated, drained,
  migrated, rolled back, or recovered after restart. The current discovery and
  registry path accepts one provider generation at a time.
- Exercise a distributable third-party OCI plugin bundle through the complete
  installed discovery, materialization, Container create/start/logs/stop/delete,
  and restart path.
- Add release-signature trust and coordinated dependency publication.
- Run the paired Docker Compose behavior and performance matrix, including
  slow/non-draining FIFOs, sustained writes, direct reads, and idle overhead.
- Complete final migration, security, shutdown, rollback, and orphan-resource
  evidence before claiming programme-level logging parity.

## Apple-shaped boundary

The implementation is retained on the local
`upstream/logging-driver-parity` branch. It contains no Compose parsing and no
Apple issue, pull request, branch publication, or push has been created. The
handoff is held until all parity development waves are complete.

## Commit and issue tracking

- `08677dc8b5a677533de80cf634fee1d14f4da069` — signed isolated plugin
  lifecycle service, authenticated transport, materializer, authority routing,
  direct reader, conformance tests, and service documentation.
- [container#47](https://github.com/stephenlclarke/container/issues/47) records
  the queued connection-lane cancellation defect and is closed with regression
  coverage.
- [container#48](https://github.com/stephenlclarke/container/issues/48) records
  the missing writable runtime paths and is closed with materializer coverage.
