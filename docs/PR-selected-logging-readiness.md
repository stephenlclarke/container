<!-- markdownlint-disable MD013 -->

# perf(logging): probe readiness for the selected driver

## Motivation and change

Default Compose launches carry a typed request whose driver is omitted. The authority resolves that request to its configured `json-file` default, but the old full-catalog lookup first activates unrelated journald readiness. Add a selected-driver catalog method with a full-catalog fallback for existing providers. The production authority returns the current dynamic catalog without journald effects for other selections; when journald is selected, it probes readiness and fetches the registry again after the await. Create uses the effective request/default driver, start uses the persisted resolved driver, and legacy requests avoid catalog work.

## Compatibility and safety

The full catalog and side-effect-free advertised catalog remain available to existing callers. Selected journald unavailability still removes its descriptor so the existing resolver or start validator rejects the operation. Cancellation propagates. Unknown drivers and provider-generation or contract changes still fail through the existing validators. This changes readiness timing for unrelated drivers, not the journal's effect admission.

## Validation

Focused tests cover default and explicit non-journald routing, selected journald success/failure/cancellation, unknown drivers, legacy requests, and provider-generation drift between create and start. The maintained Bazel `//:container-api-tests` target passed with test caching disabled: 424 API-service tests and 270 resource tests, including all 40 cases in the two affected suites. Independent source review passed. Live first-start timing remains pending; no speed improvement is claimed. No Compose or published runtime pin moves with this isolated source change. See [the issue](ISSUE-selected-logging-readiness.md).
