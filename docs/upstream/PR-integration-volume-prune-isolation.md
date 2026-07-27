# Pull request: isolate the empty volume-prune integration precondition

## Summary

- Prune unused volumes once to establish the serial test's empty-state
  precondition.
- Run the existing prune assertion a second time and continue requiring
  `Zero KB`.
- Avoid inheriting mutable global volume state from the preceding concurrent
  test process.

## Apple-shaped boundary

This is a six-line integration-test correction in `apple/container`. It
changes no production source, public CLI behavior, persistence schema, or
runtime service.

## Code map

- `Tests/IntegrationTests/Volumes/TestCLIVolumesSerial.swift`: establish the
  empty store before asserting empty-prune output.

## Validation

The failure was reproduced by creating `serial-isolation-probe` immediately
before the suite. After the correction, all four tests in
`TestCLIVolumesSerial` passed, including the seeded-state regression:

```sh
container volume create serial-isolation-probe
swift test --filter TestCLIVolumesSerial
```

The complete source-matched, coverage-enabled gate then passed 293 tests in 31
concurrent suites and 87 tests in 11 serial suites. In the full sequence,
`testVolumePruneNoVolumes` performed both the setup prune and the asserted
empty prune successfully. This is test orchestration only, so Docker Compose
configuration parity does not apply; the Compose release gate consumes the
validated runtime revision.

## Compatibility and risks

The setup prune is intentionally limited to the already-serialized destructive
suite. The integration target starts from a dedicated clean application root,
so clearing an unused volume is within the suite's existing ownership. A
volume still referenced by a container remains protected by the unchanged
product behavior and would make the empty-state assertion fail visibly.

## Commit tracking

- `d48a962c30b873d054345cbbb5856eb616e4f2ee`
  (`test(volume): isolate empty prune precondition`).
