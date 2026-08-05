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
- [x] Suspension-safe writer admission prevents concurrent stdout and stderr
  pumps from assigning one sequence to different Docker frames.
- [x] Accepted mutating operations survive connection HUP and remain
  replayable under the service lifetime; blocking reader-next calls remain
  connection-cancellable.
- [x] Definitive plugin rejection releases a new local claim for safe replay,
  while non-definitive starts remain durably uncertain and cannot repeat the
  plugin effect.
- [x] Service readiness admits the workload once and retries only the exact
  running generation's dial/probe; terminal starts cannot generate a mutation
  loop.
- [x] Real Linux FIFO write, cancellation, stop ordering, and fence ordering.
- [x] Real readable and write-only Unix HTTP plugin conformance, including the
  absence of `ReadLogs` for the write-only case.
- [x] Authority configuration binding carries exact Docker `Info`, all options,
  lease, provider generation, and semantic request digest.
- [x] Direct provider readers are routed through the authority and remain
  separate from live process attachment.
- [x] Repository formatting, licence, Markdown, and whitespace gates pass.
- [x] Distinct generations of one provider can coexist through discovery,
  staging, readiness probing, one-generation publication, exact draining
  selection, rollback, and restart recovery.
- [x] Registry state is a closed, bounded, mode-0600 atomic file containing
  immutable descriptors and staged/active/draining phases; persistence failure
  cannot publish an in-memory transition.
- [x] Restart and failed-readiness tests prove registry recovery performs no
  writer or reader lifecycle effect.
- [x] A durable quiescing phase withdraws generation N from new catalogue and
  session admission while exact-generation recovery remains available.
- [x] Every stopped container configuration and protected option reference is
  revalidated and durably resealed for N+1 before alias cutover.
- [x] Direct-reader history migration uses a replay-stable provider receipt;
  unsupported or mismatched migration cancels quiescence without mutation.
- [x] Cutover proves writer, reader, detached-cleanup, pending-removal, and
  durable-reference terminal state before activating N+1 and reclaiming N.
- [x] The isolated service persists history receipts, rejects reclamation with
  live effects, and stops the exact provider workload with lost-response
  reconciliation before the registry forgets generation N.
- [x] macOS Go race/vet passes at 70.7% statement coverage and the pinned
  Linux/arm64 race gate passes at 74.3% statement coverage.
- [x] The focused cutover/runtime gate passes 63 tests in 9 suites and the
  scoped Container gate passes 1,868 Swift Testing tests in 216 suites plus 94
  XCTest tests under warnings-as-errors.
- [x] The exact rebuilt MBP artifact completed five consecutive genuine
  two-stream workloads: every run reached `stopped`, appended one stdout and
  one stderr Docker frame (76 bytes total), closed its process generation with
  disposition `complete`, and left no active service writer, reader, or pending
  effect removal.
- [x] The installed deterministic readable-plugin bundle is discovered from
  the protected install root; two native create/start/stop cycles produce exact
  FIFO history; independent Docker `info`, `inspect`, and `logs` use the same
  authority; stopped state projects as `exited`; and history remains readable
  after the API service and shared sandbox restart.
- [x] Deleting and recreating the same Docker-compatible container ID no longer
  collides with an immutable protected-effect tombstone. The installed plugin
  completed another start/stop/delete after daemon restart and advanced exact
  history without `integrityMismatch`.

## Remaining programme work

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
- `70f976611bd5e39a9bfeb4965df7c073bbd789ad` — signed durable provider
  generation staging, activation, retained exact routing, rollback, restart
  recovery, discovery collision authority, and failure/security tests.
- `6e462443dd744bda0b605bf26e093833d7818e77` — signed provider-generation
  quiescence, durable configuration/history migration, terminal proof, atomic
  cutover, exact workload stop, and final generation reclamation.
- `5a9802499bc720994d50d055a63a1710a75795d5` — signed installed-fixture,
  two-stream delivery, native read, sandbox-loss recovery, secure runtime,
  deterministic terminalisation, and lifecycle diagnostics checkpoint.
- `0c4738c4a273730ec98bd948d90faa991c25e5b8` — signed single-admission
  protected-service readiness and exact-generation dial/probe retry checkpoint.
- `36ef9c8fbed136641550eed695039440e578de70` — signed installed-system
  certification runner and container-incarnation-bound writer/reader identity,
  preventing recreated IDs from colliding with prior protected tombstones.
- [container#47](https://github.com/stephenlclarke/container/issues/47) records
  the queued connection-lane cancellation defect and is closed with regression
  coverage.
- [container#48](https://github.com/stephenlclarke/container/issues/48) records
  the missing writable runtime paths and is closed with materializer coverage.
- [container#49](https://github.com/stephenlclarke/container/issues/49) records
  the rejected/discarded plugin-generation defect and is closed with durable
  registry and discovery coverage.
- [container#50](https://github.com/stephenlclarke/container/issues/50) through
  [container#59](https://github.com/stephenlclarke/container/issues/59) record
  the staged installation, virtiofs, fixture shutdown, catalog, XPC reply,
  readiness, journald runtime, native read, sandbox recovery, and two-stream
  delivery defects. All are closed with focused regressions, signed local
  checkpoints, and exact MBP runtime evidence.
- [container#61](https://github.com/stephenlclarke/container/issues/61) is
  closed by signed commit `ac77f7a38819c4f96581220bb58d89107b51826a` with
  public Docker create/start/stop/delete certification on the programme MBP.
- [container#62](https://github.com/stephenlclarke/container/issues/62) retains
  the restart/stale-state inspect-projection investigation; a clean installed
  certification currently projects stopped state as `exited`.
- [container#63](https://github.com/stephenlclarke/container/issues/63) records
  the recreated-container protected-effect collision and is closed by
  `36ef9c8f` with focused and installed restart evidence.
- [container-engine-api#14](https://github.com/stephenlclarke/container-engine-api/issues/14)
  is closed by signed Engine API commit
  `fe4094d0d7a2372ad586d177aea3f9b0e299ebcb`, which scopes handoff trust to
  the selected provider root.
