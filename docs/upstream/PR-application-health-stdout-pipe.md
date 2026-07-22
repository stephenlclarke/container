# Pull request handoff: avoid an unread stdout pipe in health tests

> [!IMPORTANT]
> All commits offered to Apple must remain signed and verified.

## Summary

Remove a test-only helper that redirects process-wide stdout to an unread pipe
across asynchronous work. Run the two fallback-help operations directly under
their existing wall-time guard.

## Apple-shaped boundary

- The change is limited to `ApplicationHealthTests`; production code and CLI
  output are unchanged.
- It removes a local interception mechanism rather than adding another test
  abstraction.
- The existing completion assertions and two-second wall timeout are retained.
- No Compose behavior or fork-specific policy is introduced.

## Code map

- `Tests/ContainerCommandsTests/ApplicationHealthTests.swift` runs both help
  fallbacks directly, deletes the unread-pipe helper, and removes the now-unused
  Darwin import.

## Validation

```console
for run in 1 2 3 4 5; do
  swift test --filter ApplicationHealthTests --no-parallel
done
make test
make check
```

- Five consecutive focused runs passed 75 tests in total.
- `make coverage-unit` passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- `make check` passed formatting and license checks.
- The source-build integration gate passed 3 warmup tests, 238 concurrent tests
  in 27 suites, and 143 serial tests in 14 suites.

The downstream Compose prerelease also runs the strict Docker Compose V2
parity suite, although this test-only change does not alter Compose behavior.

## Compatibility and risks

The two tests may write a few help lines to the test runner’s captured stdout.
That is preferable to mutating a global descriptor across suspension points.
No runtime binary, public interface, stored state, or command output changes.

## PR template

### Type of change

- [x] Bug fix / test reliability
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

### Motivation and context

An unread pipe can fill before the awaited command completes, while a
process-wide stdout replacement can capture unrelated concurrent output. The
output suppression is unnecessary for the completion behavior under test.

### Testing

- [x] Tested locally on macOS
- [x] Existing tests preserve behavioral coverage
- [x] Full unit suite passed
- [x] Documentation updated
- [ ] Docker Compose V2 parity (completed in the downstream Compose pin)

## Commit tracking

- `659a01733ac03c07624b545fb552f1536f80b203`
  (`test(health): avoid unread stdout pipe`)
