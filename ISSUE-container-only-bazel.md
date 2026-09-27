<!-- markdownlint-disable MD013 -->

# Request: reduce the Bazel workflow to container

## Feature or enhancement request details

The family-wide build/test workflow has become too expensive and difficult to diagnose. Preserve existing repositories, local changes and evidence, retain Bazel, and qualify only `container` and its dependencies. Start at the lowest dependencies and admit the next layer only after focused builds and tests pass.

Separate tests by dependency layer. Keep one configuration and persistent outputs so unchanged work can be reused. Runtime integration, installation and release qualification must not happen implicitly during a library test.

## Scope

Existing package revisions remain pinned. Compose/devcontainer, other family products and release automation are deferred. The implementation and evidence are tracked in [PR-container-only-bazel.md](PR-container-only-bazel.md).

Compare each active fork with its matching stock Apple source. Keep common test workloads identical, report build and component performance separately, and record dependencies without an Apple counterpart as not applicable. Preserve functional differences and failed experiments in the evidence.
