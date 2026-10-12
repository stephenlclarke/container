<!-- markdownlint-disable MD013 -->

# Runtime integration must use the admitted native dependency chain

## Problem

The runtime integration runner verified that the prepared executables consumed the published native dependency layers, but its later Bazel test invocations did not pass those verified repository overrides. Integration targets could therefore source-build dependencies even though the runtime under test was native-layer qualified.

## Expected behavior

After validating a prepared runtime, retain its exact native admission and pass the resulting canonical overrides to every warmup and selected integration test invocation, including coverage runs. Reject an empty override set before starting runtime services.

## Acceptance

- The prepared receipt and source checks still run before integration.
- Warmup and every selected layer receive the same admitted override flags.
- Test and coverage invocations are covered by a deterministic regression.
- Missing native overrides fail before starting services or tests.
- Existing integration assertions and cleanup behavior remain unchanged.

See [the PR handoff](PR-runtime-integration-native-overrides.md).
