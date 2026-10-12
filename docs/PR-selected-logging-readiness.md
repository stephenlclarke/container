<!-- markdownlint-disable MD013 -->

# perf(logging): probe readiness for the selected driver

## Motivation and change

Default Compose launches carry a typed request whose driver is omitted. The authority resolves that request to its configured `json-file` default, but the old full-catalog lookup first activates unrelated journald readiness. Add a selected-driver catalog method with a full-catalog fallback for existing providers. The production authority returns the current dynamic catalog without journald effects for other selections; when journald is selected, it probes readiness and fetches the registry again after the await. Create uses the effective request/default driver, start uses the persisted resolved driver, and legacy requests avoid catalog work.

## Compatibility and safety

The full catalog and side-effect-free advertised catalog remain available to existing callers. Selected journald unavailability still removes its descriptor so the existing resolver or start validator rejects the operation. Cancellation propagates. Unknown drivers and provider-generation or contract changes still fail through the existing validators. This changes readiness timing for unrelated drivers, not the journal's effect admission.

## Validation

Focused tests cover default and explicit non-journald routing, selected journald success/failure/cancellation, unknown drivers, legacy requests, and provider-generation drift between create and start. The maintained Bazel `//:container-api-tests` target passed with test caching disabled, including all 40 cases in the two affected suites. Independent source review passed.

The combined `4d82da2c571d0924bd97569249a5d200ca764a13` hosted Sonar analysis completed but failed the unchanged 80% new-code gate at 79.9% (271/339). Its `coverage-sonar` target used `--skip IntegrationTests`, which also excluded the 20 existing mock-based `ContainerLoggingAuthorityIntegrationTests` despite compiling them. The renamed `ContainerLoggingAuthorityBoundaryTests` preserves every test assertion and leaves the separate real-service integration exclusion intact. The unused internal argument in the default `logDriverCatalog(forSelectedDriver:)` fallback is now `_`, preserving its external label and behavior, to address the one open `swift:S1172` issue. Fresh uncached local Bazel coverage passed 416 executed API-service and 270 resource tests, including all 20 renamed cases and all 20 selected-driver-plane cases. Seven Keychain-dependent cases and one Docker CLI interoperability case were discovered but explicitly skipped by the unit layer. The local report covered 17 of the 22 lines missed by the failed hosted analysis. A passing exact-source hosted Sonar gate and zero unresolved issues/hotspots are still pending, as are CodeQL and full release qualification. Live first-start timing remains pending and no speed improvement is claimed. See [the issue](ISSUE-selected-logging-readiness.md).
