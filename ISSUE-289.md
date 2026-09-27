<!-- markdownlint-disable MD013 -->

# Request: reduce the Bazel workflow to container

## Feature or enhancement request details

The family-wide build/test workflow has become too expensive and difficult to diagnose. Preserve existing repositories, local changes and evidence, retain Bazel, and qualify only `container` and its dependencies. Start at the lowest dependencies and admit the next layer only after focused builds and tests pass.

Separate tests by dependency layer. Keep one configuration and persistent outputs so unchanged work can be reused. Runtime integration, installation and release qualification must not happen implicitly during a library test.

## Scope

Existing package revisions remain pinned. Compose/devcontainer and other family products remain outside scope. Following the reduced build checkpoint, restore container-only integration, quality, packaging and notarization as explicit unattended layers. The implementation and evidence are tracked in [PR-289.md](PR-289.md).

Compare each active fork with its matching stock Apple source. Keep common test workloads identical, report build and component performance separately, and record dependencies without an Apple counterpart as not applicable. Preserve functional differences and failed experiments in the evidence.

Final build qualification must also execute real speed benchmarks against stock Apple, including VM startup, warm process execution, CPU/disk workloads, image transfer and cached/uncached image builds. Record exact optimized binary and guest-image fingerprints and validate workload outputs.
