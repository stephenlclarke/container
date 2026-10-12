<!-- markdownlint-disable MD013 -->

# fix(runtime): pass verified native overrides to integration tests

## Problem and behavior

Runtime integration validated the prepared Container executables against the published native dependency chain, then invoked its test targets without those overrides. The runtime exercised by the tests could be native-linked while the integration target rebuilt dependencies from source. The runner now retains the verified admission and applies its exact override flags to warmup and every selected layer in both test and coverage modes. Empty admissions fail before runtime startup.

## Changes

- Return the verified native admission from `verify_prepared` after all existing source, lock, receipt and binary checks pass.
- Construct native override flags once and append them to all runtime integration Bazel invocations.
- Pin `GIT_COMMIT` to the prepared source revision in normal test mode and to the profiling revision in coverage mode, matching the configured dependency selection for each mode.
- Add regressions for the actual runner path in test and coverage modes, and for rejecting missing overrides before startup.
- Document the integration dependency on native admission and link this handoff with its issue.

## Validation

The new runner regression failed against the original `HEAD` implementation in both test and coverage modes: warmup and selected-layer invocations had no native override flags. With the change, `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Tools/bazel /opt/homebrew/bin/python3 -m unittest Tools.bazel.test_runtime_integration -v` passed all 11 tests on Python 3.14.7, including exact override and `GIT_COMMIT` checks for both invocations and missing-admission rejection before startup. Runtime operations were mocked. No product rebuild, live integration, VM workload, benchmark, baseline rebuild, release or publication is included in this tool-only change.

The instrumented focused suite passes all 11 cases and covers all nine added or replaced executable statements, including the function definition and both configured revision branches. Module definitions and the suite are measured after preloading the repository coverage helper separately from the instrumenter. Whole-module coverage is 171/210 statements (81.43%) and 60/80 branches (75.0%). The 90% overall aim remains unmet; broader service/error-path coverage remains a follow-up. Live layer qualification is the next check; this percentage is not a runtime or parity waiver.

## Compatibility and risks

The original test filters, assertions, runtime operations and cleanup remain unchanged. This adds the already-verified lower-layer overrides to integration test builds; the prepared signed runtime remains source- and receipt-bound.
