# Application-health tests can block on an unread stdout pipe

## Prerequisites

- [x] Searched existing Container issues and pull requests.
- [x] Audited the open fork pull request that first identified the problem.
- [x] Confirmed the helper remains on the current fork `main` branch.

## Steps to reproduce

Run `ApplicationHealthTests` repeatedly while either root-help fallback writes
enough diagnostic output or another concurrently scheduled test writes to the
process-wide standard output descriptor:

```console
for run in 1 2 3 4 5; do
  swift test --filter ApplicationHealthTests --no-parallel
done
```

The affected helper replaces process-wide stdout with a pipe, does not read
that pipe until the tested operation returns, and performs the replacement
across an `await`. If the pipe fills, the operation cannot return and the
cleanup reader is never reached. Concurrent process output can also be
captured unintentionally because file descriptor 1 is global.

## Problem description

The tests only need to prove that fallback help completes when plugin
discovery is unavailable. Suppressing output is not part of the behavior under
test. Redirecting a process-global descriptor to an unread pipe introduces a
deadlock and cross-test interference that can hide the real health-check
result.

The tests should run the commands directly and allow the test runner to handle
their small, expected output.

## Validation

- Five consecutive focused runs passed 75 tests in total.
- `make coverage-unit` passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- `make check` passed formatting and license checks.
- The complete source-build integration gate passed 3 warmup, 238 concurrent,
  and 143 serial tests with the simplified test compiled into the suite.

## Environment

- OS: macOS 26.5.2 (25F84)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Hardware: Apple silicon MacBook Pro

## Code of Conduct

- [x] I agree to follow Apple's Code of Conduct.

## Related work

- Fork PR [stephenlclarke/container#6](https://github.com/stephenlclarke/container/pull/6)
  first carried the correction alongside an upstream Makefile sync.
- The Makefile portion is intentionally excluded because current `main` uses
  the fork’s validated `build-tests` plus `--skip-build` integration flow.

## Commit tracking

- `659a01733ac03c07624b545fb552f1536f80b203`
  (`test(health): avoid unread stdout pipe`)
