# Runtime gap: durable sandbox and workload operation authority

## Problem

Container has durable logging-specific lifecycle state, but it does not expose
a generic authority for coordinating one shared Linux sandbox with independent
workload lifecycles. A higher-level controller therefore cannot safely prove
whether a sandbox boot, process start, namespace attachment, network lease,
volume attachment, resource update, or cleanup effect completed after its
caller loses the response.

The missing authority leaves four generic runtime risks:

- a retry can repeat a host or guest side effect;
- an interrupted start can incorrectly commit its candidate process
  generation;
- cleanup can run out of dependency order or lose the lease identity it must
  compensate;
- a controller restart can resume mutations before uncertain effects have been
  reconciled.

## Required runtime behavior

- Persist sandbox and workload operation intent before invoking an external
  effect.
- Separate immutable workload identity, operation generation, candidate
  process generation, committed process generation, sandbox generation, and
  specialized lease generation.
- Make identical operation retries replayable and reject conflicting or stale
  requests.
- Commit a candidate process generation only after every reserved start effect
  and the process-start receipt are acknowledged.
- Compensate failed starts and removals in reverse reservation order.
- Convert interrupted or inconclusive work to an explicit recovery-required
  state while retaining the exact effect evidence.
- Reconcile a lost sandbox boot or shutdown response without repeating a
  confirmed effect.
- Bound and validate the persisted snapshot, reject symbolic-link targets, and
  restrict the file to mode `0600`.

## Apple-shaped boundary

This is generic Container runtime authority. It contains no Docker or Compose
syntax, policy, REST route, or compatibility fallback. Specialized network,
storage, resource, logging, security, and engine-socket controllers retain
ownership of their own leases; the authority only records and orders their
typed effect references.

The implementation is being retained locally for a later Apple upstream
handoff. It must not be published to an Apple repository until the complete
parity programme is ready for upstream submission.

## Acceptance evidence

- [x] Atomic sandbox boot and shutdown reservations with terminal replay.
- [x] Durable create/start/pause/resume/stop/remove workload transitions.
- [x] Candidate/committed process-generation separation.
- [x] Reverse-order effect compensation and unknown-effect recovery fencing.
- [x] Restart recovery preserves an active process/sandbox tuple.
- [x] Protocol-driven sandbox runtime with exact receipt validation.
- [x] Bounded, schema-versioned, private file persistence.
- [x] Focused crash, replay, compensation, lifecycle, and filesystem tests.
- [x] Full macOS unit gate passes under warnings-as-errors.

## Commit tracking

- Implementation:
  `0075c3557357b02374f90e17ab59973c10f4b032`
  (`feat(runtime): add durable workload authority`).

## Follow-on integration

The generic transaction resolver is now implemented in
`ISSUE-workload-plan-resolver.md`. Production adoption remains gated on the
shared-sandbox materialization path: the current API service still launches
one runtime VM per container, so attaching shared-sandbox authority to it would
record ownership the runtime does not enforce. Once that runtime path exists,
each specialized controller can adopt the resolver in dependency order.
