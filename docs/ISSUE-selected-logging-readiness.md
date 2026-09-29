<!-- markdownlint-disable MD013 -->

# Unrelated logging readiness delays default container creation

## Current and expected behavior

An ordinary typed create request selects the configured default `json-file` driver, yet the authority asks for a full logging-driver catalog before resolving that request. The full catalog probes journald readiness, which can start its Linux service workload even though the container will not use journald. Start validation repeats the full lookup. A focused Compose profile observed the journald workload during the first default service start; the same profile also observed a separate first-image snapshot cost, so the whole first-start delay must not be attributed to logging.

Create and start should fetch the current dynamic registry and check effectful readiness only for the selected driver. A journald selection must retain its sandbox-generation probe, cancellation behavior, create-time refusal when unavailable, and start-time generation and contract validation. Legacy configurations and discovery surfaces keep their existing behavior.

## Validation status

The isolated implementation and focused regressions are prepared against Container commit `6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc`. The maintained Bazel API/resource test target passed (424 and 270 tests respectively), including all 40 cases in the affected suites. Independent source review passed. Runtime profiling and matched Compose qualification remain pending; the existing released Q6fe artifacts are unchanged.
