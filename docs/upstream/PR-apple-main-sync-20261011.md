# feat: synchronize Container with Apple main through f70ecbb9

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Integrate Apple main `f70ecbb926d925818a34917529e304b1177ce98c` into measured fork source `2e1f3269fd421c52ab7abb415e5b9b2301ab44ea`. Adopt upstream build/builder plugins, shared output rendering, machine user setup and Kubernetes multi-node/CNI behavior while preserving the fork's runtime, isolation, security and provenance changes. See [the matching issue](ISSUE-apple-main-sync-20261011.md).

## Implementation

Move builder lifecycle and SSH forwarding into ContainerBuild, keeping the public `Application.BuildCommand` compatibility adapter for in-process callers. Package both new plugins and include all ten executables in native compiled-consumer proof. Retain the exact legacy measured-product layouts for existing evidence; new candidate fingerprints explicitly select the expanded layout.

Use Apple's machine user setup and image-fetch path, preserving exclusive bundle creation, rollback, service namespaces and bounded launchctl behavior. Remove retired machine-resource helpers and their duplicate tests; the active ImagesService authentication suite retains all three old policy cases and two additional credential/host boundary cases. Keep upstream image-list partial-result behavior and injectable API invocation boundaries.

Restrict Kubernetes worker selection to canonical positive numeric suffixes. Preserve secure manifest descriptor snapshots and stdin-based CNI application. Retain serial integration defaults and restore the repository-pinned license checker rather than selecting an incompatible global installation.

## Testing

- [ ] Final exact-head source/component qualification.
- [x] Added/updated focused tests for builder parsing, worker selection, CNI behavior and machine setup.
- [x] Added/updated documentation and release inventory.

Provisional checks: `make check` passed; focused pipeline regressions passed 92 tests; packaging script checks passed, including 11 debug-symbol regressions. Native compilation caught missing imports and retired machine-artifact call sites; these were corrected while preserving bundle-safety tests and moving user-identity tests to the client layer. The subsequent focused run compiled and exercised 1,274 tests, with two failures in ApplicationHealthTests. Updating help assertions for the extracted plugin and requiring explicit provenance for a local SDK override made all 17 ApplicationHealthTests pass. Raw failures remain retained. Final exact-head qualification and matched dependency admission remain pending; these provisional results do not qualify a released runtime.

The accompanying SDK merge passed 453 focused tests, 19 coverage-tool tests and two independent `e2fsck -fn` image checks. Those are SDK evidence, not substitutes for this Container candidate's tests.

## Compatibility and Risks

Existing immutable baseline executables, kernel/init references and recorded benchmark pairs are unchanged. New plugin products require an updated release layout. Changing the SDK or lower fork source pins invalidates their compiled-layer admission and requires fresh candidate layer proof before downstream release consumption. VM-backed integration, final release gates and performance/parity acceptance remain outstanding.
