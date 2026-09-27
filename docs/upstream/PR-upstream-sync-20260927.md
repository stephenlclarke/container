# chore: synchronize container with Apple main

## Changes

Merge Apple main `4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c` and pin the merged containerization fork at `f58053cc72dc5dfae419bfc1667220b35b61a1a1`. Preserve the four previously published fork commits, including debug-symbol packaging fixes. Adapt both standalone containers and engine sandboxes to explicit VM sizing. Combine Apple's empty-image-entrypoint handling with the fork's clear-entrypoint flag. Retain the stable Kubernetes control-plane endpoint while adopting upstream node-image version selection and lifecycle changes.

## Validation

All 25 container Bazel suites passed against the merged dependency source. All six containerization host suites passed, both Linux guest executables cross-compiled, and the SSL and gRPC dependency suites passed. The installed Static Linux SDK lacks Swift Testing, so Linux guest unit-test compilation remains blocked and is recorded separately. Dependency resolution succeeded without changing unrelated dependency revisions.

Preserved bundles and validation evidence: `ContainerFamily/retained/container-only/upstream-sync/20260927T123656Z`. Tests used the previously qualified Bazel adaptations for executable names and logging handoff; those adaptations remain in the reduced build branch.

## Compatibility and risks

The main fork now uses containerization's explicit `VMResources` API and version 0.47 metadata. Existing benchmark reports describe their recorded previous revisions; they are not evidence of performance at this merge. No unrelated fork is changed.

## Related work

See [the matching issue](ISSUE-upstream-sync-20260927.md).
