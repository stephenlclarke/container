<!-- markdownlint-disable MD013 -->

# Request: reduce the Bazel workflow to container

## Feature or enhancement request details

The family-wide build/test workflow has become too expensive and difficult to diagnose. Preserve existing repositories, local changes and evidence, retain Bazel, and qualify only `container` and its dependencies. Start at the lowest dependencies and admit the next layer only after focused builds and tests pass.

Separate tests by dependency layer. Keep one configuration and persistent outputs so unchanged work can be reused. Runtime integration, installation and release qualification must not happen implicitly during a library test.

## Scope

Existing package revisions remain pinned. Compose/devcontainer and other family products remain outside scope. Following the reduced build checkpoint, restore container-only integration, quality, packaging and notarization as explicit unattended layers. The implementation and evidence are tracked in [PR-289.md](PR-289.md).

Compare each active fork with its matching stock Apple source. Keep common test workloads identical, report build and component performance separately, and record dependencies without an Apple counterpart as not applicable. Preserve functional differences and failed experiments in the evidence.

Final build qualification must also execute real speed benchmarks against stock Apple, including VM startup, warm process execution, CPU/disk workloads, image transfer and cached/uncached image builds. Record exact optimized binary and guest-image fingerprints and validate workload outputs.

Release admission must preserve a clean checkout. CodeQL extractor version checks emit invocation diagnostics, so they must execute in a disposable directory before the immutable qualification check.

Keep dormant original Apple/Homebrew service registrations aside across the whole unattended run. Restoring them between runtime stages allowed background clients to reactivate the original service and interfere with the next admission. The existing ownership guard still refuses active workloads; cleanup attempts both Colima and registration restoration even if either fails.

The reduced quality lane must preserve the original workflow's separate zero-unresolved-issues and zero-unreviewed-hotspots checks, even when Sonar's configurable quality gate passes. Manual GitHub qualification must also test its event SHA rather than the branch tip at runner startup, otherwise queued branch updates can misidentify the tested source.
