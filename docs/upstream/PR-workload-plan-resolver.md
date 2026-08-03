# Pull request handoff: add transactional workload plan resolution

## Summary

- Add a generic resolver that orders specialized workload effects around one
  candidate process start.
- Persist effect reservations before apply, validate exact receipts, and
  reconcile thrown responses through controller observation.
- Compensate known failures in reverse order and fence every inconclusive
  outcome with durable recovery evidence.

## Type of change

- [x] Generic runtime API
- [x] Crash-recovery and lifecycle behavior
- [x] Unit tests
- [ ] Docker or Compose parsing
- [ ] Engine REST or socket API
- [ ] Production API-service wiring

## Transaction contract

`WorkloadPlanResolverV1` receives controllers in dependency order. Each
controller owns one effect domain and first returns a deterministic,
side-effect-free reservation. The resolver persists the reservation in
`EngineWorkloadLedgerV1` before calling `apply`.

Every successful controller response must match the reserved domain, lease ID,
lease generation, effect ID, and integrity digest. Every successful process
response must match the container, operation generation, candidate process
generation, sandbox generation, and request digest. A mismatched receipt is an
unknown outcome and fails closed.

When an external call throws, the resolver observes the exact operation:

- confirmed applied or started work continues without another apply;
- confirmed absence starts reverse compensation and returns a typed failure;
- an unknown observation durably fences the workload for reconciliation.

After all effects are acknowledged, the resolver starts the candidate process
and commits the workload only after its exact receipt is confirmed. Known
process failure compensates all applied effects in reverse order. Unknown
process outcome leaves those effects recorded and fences the workload instead
of guessing.

## Replay behavior

- Duplicate controller domains fail before a ledger mutation.
- A replayed start regenerates the same reservation tuple.
- The ledger accepts that tuple even after its persisted effect state advanced.
- Already applied effects are skipped.
- A committed request returns its running record without calling controllers
  or the process starter.

## Code map

- `Sources/ContainerResource/Container/WorkloadPlanResolver.swift` contains
  the controller and process contracts, exact receipt types, resolver, outcome
  observation, compensation, and recovery fencing.
- `Sources/ContainerResource/Container/EngineWorkloadLedger.swift` adds
  reservation-identity replay and operation-level recovery fencing.
- `Tests/ContainerResourceTests/WorkloadPlanResolverTests.swift` covers ordered
  success, known and unknown failures, lost responses, reverse compensation,
  interrupted replay, and committed replay.

## Integration boundary

The resolver is deliberately not wired into `ContainersService` in this
change. That service currently gives each container its own runtime VM, while
the durable authority and resolver model independent workloads in a shared
Linux sandbox. The shared-sandbox materialization path must become production
runtime truth before specialized adapters adopt this transaction API.

No Apple issue, branch, pull request, or push has been created. This handoff is
held locally until all parity development is complete and the programme is
ready for upstream publication.

## Validation

```console
swift test --filter WorkloadPlanResolverTests
make check
make test
git diff --check
```

Results on the development MacBook Pro:

- focused resolver suite: 8 tests in 1 suite passed;
- full unit gate: 1,783 tests in 205 suites passed;
- pinned semantic helper tests and script gates passed;
- formatting, license, and whitespace checks passed;
- implementation commit is signed.

## Review checklist

- [x] Effect intent is durable before apply.
- [x] Full receipt tuples are checked.
- [x] Lost responses do not cause duplicate confirmed work.
- [x] Compensation is deterministic and reverse ordered.
- [x] Unknown outcomes fail closed with durable evidence.
- [x] Interrupted and committed retries are idempotent.
- [x] The transaction API contains no Docker-specific policy.
