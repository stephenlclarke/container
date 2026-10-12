<!-- markdownlint-disable MD013 -->

# Unrelated logging readiness delays default container creation

## Current and expected behavior

An ordinary typed create request selects the configured default `json-file` driver, yet the authority asks for a full logging-driver catalog before resolving that request. The full catalog probes journald readiness, which can start its Linux service workload even though the container will not use journald. Start validation repeats the full lookup. A focused Compose profile observed the journald workload during the first default service start; the same profile also observed a separate first-image snapshot cost, so the whole first-start delay must not be attributed to logging.

Create and start should fetch the current dynamic registry and check effectful readiness only for the selected driver. A journald selection must retain its sandbox-generation probe, cancellation behavior, create-time refusal when unavailable, and start-time generation and contract validation. Legacy configurations and discovery surfaces keep their existing behavior.

## Validation status

The isolated implementation and focused regressions were prepared against Container commit `6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc`. The maintained Bazel API/resource test target passed, including all 40 cases in the affected suites. Independent source review passed. Runtime profiling and matched Compose qualification remain pending.

Hosted Sonar analysis of the later combined source `4d82da2c571d0924bd97569249a5d200ca764a13` failed its unchanged new-code coverage gate: 79.9% against 80% (271 of 339 new lines). Unit coverage compiled `ContainerLoggingAuthorityIntegrationTests` but the broad `--skip IntegrationTests` filter excluded its 20 mock-based authority boundary cases along with the intended separate live-service integration target. Those 20 tests had passed when selected directly. The unit suite and file are now named `ContainerLoggingAuthorityBoundaryTests` so the maintained unit-coverage selection can run them while leaving the real journald-service integration suite excluded. The same analysis reported one open unused-parameter issue in the default catalog method; its unused internal name is removed without changing the external `forSelectedDriver` label. Fresh uncached local Bazel coverage passed 416 executed API-service and 270 resource tests, including all 20 renamed cases and all 20 selected-driver-plane cases. Seven Keychain-dependent cases and one Docker CLI interoperability case were discovered but explicitly skipped by the unit layer. The local report covered 17 of the 22 source lines missed by the failed hosted analysis. Exact-source hosted coverage, issue/hotspot checks, CodeQL, and full qualification remain pending for this correction. The failed `4d82da2c` analysis and local qualification remain failed evidence, not release acceptance.
