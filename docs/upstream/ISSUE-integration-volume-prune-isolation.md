# Integration volume-prune test inherits state from concurrent suites

## Impact

`TestCLIVolumesSerial.testVolumePruneNoVolumes` assumes that the preceding
concurrent integration pass leaves no volumes behind. A failed or best-effort
fixture cleanup can leave an unused volume visible to the next test process.
The first serial volume-prune assertion then reports the storage reclaimed from
that unrelated volume instead of `Zero KB`.

The failure is deterministic when an unused volume is seeded before the serial
suite:

```sh
container volume create serial-isolation-probe
swift test --filter TestCLIVolumesSerial
```

The product correctly prunes the seeded volume, but the test fails because its
empty-state precondition was never established.

## Required Apple behavior

- Make the destructive serial test establish its own global volume state.
- Continue validating that pruning an already-empty volume store reports zero
  reclaimed bytes.
- Keep production volume-prune behavior unchanged.

## Non-goals

- Hide product failures while deleting a volume.
- Change concurrent fixture cleanup semantics.
- Change the CLI's reclaim accounting or output.

## Commit tracking

- `d48a962c30b873d054345cbbb5856eb616e4f2ee` —
  `test(volume): isolate empty prune precondition`.
