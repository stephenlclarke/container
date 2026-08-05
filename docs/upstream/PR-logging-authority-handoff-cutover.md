# Pull request handoff: complete logging authority cutover through the gateway

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
- canonical, ordered 8 MiB transport stores for Docker JSON history above the
  former 64 MiB aggregate ceiling;
- destination stage and exact imported receipt binding;
- prepared-root recording, signed commit, and reconciliation entry;
- logging promotion and signed-Complete activation;
- imported `json-file` history rematerialization through the production bundle
  publisher, including multiple transport stores joined into one active
  `json.log`, public read-back, cursor adoption, and a greater-sequence writer;
- coordinator-driven staged abort, logging compensation, and protected-object
  cleanup; and
- exact replay through a newly constructed coordinator over the same durable
  gateway store plus provider-effect idempotency.

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
swift test --filter 'gateway coordinator aborts'
swift test --skip-build --filter LoggingHandoffControlResponderTests
swift test --skip-build --filter LoggingHandoffPayloadTests
swift test --skip-build --filter LoggingHandoffBundleHistoryPublisherTests
swift format lint --strict --configuration .swift-format-nolint \
  $(git diff --name-only -- '*.swift')
git diff --check
```

Current MacBook Pro evidence:

- gateway cutover: 1/1 passed;
- gateway abort/restart replay: 1/1 passed;
- complete responder slice: 7/7 passed in parallel;
- decoded-payload slice: 6/6 passed, including a shared Engine API payload
  whose encoded JSON history exceeds 64 MiB;
- bundle-history publisher slice: 5/5 passed, including strict incomplete-set
  rejection and repeatable ordered publication into one active file;
- the gateway streamed objects from a distinct source store, recorded two
  destination-key proofs, obtained one source signature, staged and promoted
  logging once, and replayed activation without duplicating the promoted or
  activated effect;
- Complete rematerialized two ordered portable Docker JSON chunks on the public
  bundle path as one active file, the production reader returned both records,
  the adopted cursor reserved epoch 8 from sequence 42, and a production writer
  appended a later readable record;
- a staged remote-provider transaction reached signed Aborted, compensated
  logging twice with equal terminal results across coordinator reconstruction,
  and left zero protected staging objects; and
- the installed readable-plugin fixture completed native lifecycle and
  independent Docker info/inspect/logs certification, then the same deleted
  container ID completed another lifecycle after daemon restart without
  colliding with its prior protected-effect tombstone; and
- SwiftPM editable state was removed after validation.

## Remaining closure

This closes the former 64 MiB source-history gap, coordinator-driven success,
public-history/new-writer, and staged-abort/restart-replay transactions. It
does not close the whole work package. Before claiming logging handoff parity,
retain explicit evidence for:

- the defensive 4096-store limit (at most 32 GiB of encoded history per
  container), either as an accepted operational limit or with a streaming
  continuation design for larger histories; and
- public Docker create/start routing
  ([container#61](https://github.com/stephenlclarke/container/issues/61)) and
  provider-root-scoped handoff trust storage (`container-engine-api#14`); and
- synchronized release, external-client, security, failure, migration, and
  performance gates.

Installed-system certification and the recreated-container regression are
retained in signed local Container commit
`36ef9c8fbed136641550eed695039440e578de70`.
