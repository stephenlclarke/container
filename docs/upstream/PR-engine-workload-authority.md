# Pull request handoff: add durable sandbox and workload authority

## Summary

- Add a bounded, persistent ledger for sandbox and workload lifecycle
  operations.
- Add a protocol-driven shared Linux sandbox manager that persists intent,
  validates exact receipts, and reconciles lost boot or shutdown responses.
- Preserve typed lease/effect identity across start, compensation, stop,
  remove, crash recovery, and idempotent replay.

## Type of change

- [x] Generic runtime API
- [x] Crash-recovery and lifecycle behavior
- [x] Security-sensitive persistence validation
- [x] Unit tests
- [ ] Docker or Compose parsing
- [ ] Engine REST or socket API

## Runtime contract

`EngineWorkloadLedgerV1` is the single writer for workload transition state.
Every mutation binds an idempotency key and request digest to a monotonically
increasing operation generation. Start reserves a candidate process generation
without advancing the committed generation; commit occurs only after all
effects and process creation have succeeded. Failed start and remove work is
compensated in reverse reservation order.

An uncertain effect moves the workload to `recoveryRequired`. Reload also
converts every interrupted operation to recovery-required while retaining the
active process generation, sandbox generation, operation generation, and exact
lease/effect references. New mutations remain fenced until a later
reconciliation slice resolves that evidence.

`EngineLinuxSandboxManagerV1` owns only sandbox boot and shutdown coordination.
Its runtime protocol makes side effects substitutable and testable. The manager
persists the request before the runtime call, validates the complete receipt
tuple before commit, and observes an interrupted operation before deciding
whether an exact retry is safe. Completed shutdowns remain replayable, and the
next boot advances the sandbox generation.

A later signed integration commit makes completed ready state observable too:
after an API-service restart the manager compares the complete live runtime
identity before accepting the durable record. The API-service composition and
its remaining cutover boundary are documented in
`PR-engine-linux-sandbox-api-authority.md`.

## Persistence and validation

- Snapshots are versioned, size-bounded, deterministically encoded, and
  atomically replaced.
- Authority, identifiers, digests, generations, state tuples, operation kinds,
  effect counts, and effect uniqueness are validated on construction and load.
- Unknown top-level snapshot fields fail closed.
- File-backed ledgers reject symbolic links and use mode `0600`.
- A persistence failure fences the in-memory authority from later mutations.

## Code map

- `Sources/ContainerResource/Container/EngineWorkloadLedger.swift` contains
  the durable models, persistence boundary, validation, transaction ledger,
  compensation ordering, and restart recovery.
- `Sources/ContainerResource/Container/EngineLinuxSandboxManager.swift`
  contains the runtime protocol, exact request/receipt types, reconciliation,
  and sandbox lifecycle manager.
- `Tests/ContainerResourceTests/EngineWorkloadLedgerTests.swift` covers the
  focused lifecycle and failure matrix.

## Apple-shaped boundary

The change is reusable Container lifecycle infrastructure. It deliberately
does not parse Docker or Compose values, select compatibility providers, expose
an Engine API, or implement controller-specific network, volume, logging,
security, device, or model-routing effects.

No Apple issue, branch, pull request, or push has been created. This handoff is
held locally until all parity development is complete and the programme is
ready for upstream publication.

## Validation

```console
swift test --filter EngineWorkloadLedgerTests
make check
make test
git diff --check
```

Results on the development MacBook Pro:

- focused authority suite: 7 tests in 1 suite passed;
- full unit gate: 1,775 tests in 204 suites passed;
- pinned semantic helper tests and script gates passed;
- formatting, license, and whitespace checks passed;
- implementation commit is signed.

## Review checklist

- [x] External effects are preceded by durable intent.
- [x] Candidate process generations cannot activate after failed preparation.
- [x] Exact retries replay and conflicts fail closed.
- [x] Compensation order is deterministic.
- [x] Interrupted effects retain sufficient reconciliation evidence.
- [x] The sandbox manager cannot shut down with an active workload.
- [x] Persistence is bounded, atomic, private, and symlink-safe.
- [x] The change introduces no Docker-specific policy.
