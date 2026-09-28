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

The reduced workflow also needs the original integration and combined coverage tiers. Unit-only evidence cannot replace these. Build tests share a private builder that must be removed at their layer boundary before System tests assert an empty image store.

The container-only lock alone does not exclude existing family workers from the shared macOS service namespace. Full unattended qualification must hold the common host lock and recoverably quiesce authorized idle workers, without interrupting an active job. Restore original runtime state before workers and retain recovery authority when restoration fails.

Release-install cleanup previously let a log-copy error skip restoration and checked only launchd registrations before replacing executable files. The outer wrapper also resumed workers without checking the private installation. Persist recovery evidence before moving the original, reject surviving processes, restore despite log-retention failure, and require verified original binaries before workers can resume.

Cancellation of GitHub run `36362949702` killed the wrapper before its final cleanup, leaving the host journal and paused workers behind. Manual recovery verified and restored all four original service registrations, all three paused workers and the original stopped Colima state. Add a separate always-run recovery step with invocation ownership checks and an inherited command lease, so a surviving controller cannot launch more work after restoration. Reconcile actual service registrations even when receipt flags lag a completed mutation. Unconfirmed binary replacement remains a manual recovery condition, and neither cancellation nor host recovery can be reported as a successful qualification.

A manual-only workflow absent from the default branch cannot provide pre-merge qualification. Add an opt-in same-repository PR label trigger with exact-head binding; require server-side approval for every external contributor because editable PR workflow conditions are not a trust boundary. Keep public-fork code off the persistent Mac.

External DNS failure currently collapses to an empty test error because nslookup writes details to stdout. Retain the fixed-query output and check native host DNS readiness before expensive release qualification. Preserve the original guest lookup and its deadlines, without automatic retries or resolver overrides. Native resolution timing and response/cancellation logs must distinguish host lookup delay from a lost forwarded response without exposing query names.

The self-hosted runner also needs its own Local Network consent. The original HTTP network test failed in GitHub run `36362949702` with explicit macOS `Local network prohibited` logs attributed to the runner's Node executable, although local terminal validation had passed. Record this setup requirement and verify consent through the original test in the actual runner context; credentials and DNS admission cannot prove it.

The SSL suite has a known rejected-certificate alert difference, so its failed suite duration cannot establish SSL runtime performance. Add identical optimized upstream handshake and encrypted-write workloads while retaining the complete compatibility result.

Bazel records inherited client environment values in raw build events. Its process boundary must admit only intentional build inputs, keeping scanner/notarization credentials separate, while preserving explicit CodeQL tracing and runtime-test arguments. Retained local event files need environment redaction without discarding test evidence.
