# Pull request handoff: exercise logging authority cutover through the gateway

> This handoff remains local on `upstream/logging-driver-parity` until the
> complete parity programme is ready for coordinated Apple publication. No
> Apple issue, pull request, branch publication, or push has been created.

## Summary

Drive the production logging source and destination controllers through the
real `ProviderHandoffGatewayCoordinator` instead of calling the controller
operations directly. The focused transaction proves:

- destination possession of the exact archived payload and lineage keys;
- exact-replay source export and source manifest signing;
- closed-inventory manifest assembly with explicit empty evidence for the
  unrelated controller parts;
- immutable object streaming between distinct source and destination stores;
- destination stage and exact imported receipt binding;
- prepared-root recording, signed commit, and reconciliation entry;
- logging promotion and signed-Complete activation; and
- local coordinator replay plus provider-effect idempotency.

The non-logging controller slots use deterministic empty test responders. The
logging slot uses `LoggingHandoffSourceControlResponder`,
`LoggingHandoffControlResponder`, `LoggingHandoffStagingController`, and
`LoggingHandoffDestinationReconciler` without substitutes.

## Dependency handoff

The test compiles against the matched signed local `container-engine-api`
implementation because released 0.3.5 predates the handoff coordinator API.
`ContainerAPIServiceTests` now declares the `ContainerEngineService` product
explicitly. Validation temporarily places that package in SwiftPM editable
mode, then removes the edit and restores the published lockfile exactly.

The Engine API, devcontainer source, and Container destination changes must be
published as one synchronized dependency wave after all programme development
is complete. The released 0.3.5 pin remains unchanged in this handoff.

## Validation

Run only the focused slice while the matched Engine API is editable:

```console
swift test --filter 'gateway coordinator transfers'
swift test --skip-build --filter LoggingHandoffControlResponderTests
swift-format lint --strict \
  Tests/ContainerAPIServiceTests/LoggingHandoffControlResponderTests.swift
git diff --check
```

Current MacBook Pro evidence:

- gateway cutover: 1/1 passed;
- complete responder slice: 6/6 passed in parallel;
- the gateway streamed objects from a distinct source store, recorded two
  destination-key proofs, obtained one source signature, staged and promoted
  logging once, and replayed activation without duplicating the promoted or
  activated effect; and
- SwiftPM editable state was removed after validation.

## Remaining closure

This closes the coordinator-driven success transaction, not the whole work
package. Before claiming logging handoff parity, retain explicit evidence for:

- rematerialized public history reads followed by a greater-sequence writer
  after the imported epoch;
- coordinator-driven abort and compensation after staged transfer, including
  crash replay;
- source histories above the current 64 MiB capture bound; and
- synchronized release, security, failure, and performance gates.
