# Pull request handoff: consume the indexed EXT4 runtime

## Proposed pull request

`build(deps): consume EXT4 index sync`

This handoff covers the signed source commit
[`40ce80785ab70f6fa3442c2706152e42efef5adf`](https://github.com/stephenlclarke/container/commit/40ce80785ab70f6fa3442c2706152e42efef5adf).

## Summary

Advance Container's immutable Containerization dependency to the reviewed tip
that includes Apple's constant-time EXT4 child lookup and the fork's minimal
subtree-export reconciliation.

## Apple-shaped boundary

- Changes only the existing immutable Containerization revision.
- Keeps all Container source, CLI, API, and packaging behavior unchanged.
- Consumes Apple's performance implementation through the standard SwiftPM
  dependency seam.
- Preserves exact runtime provenance for downstream release metadata.

## Code map

- `Package.swift`
  - advances `containerizationRevision` to `6aa6e803`.
- `Package.resolved`
  - records the same immutable Containerization revision.
- `docs/upstream/ISSUE-containerization-ext4-index-sync-20260723.md`
  - records the dependency contract and validation.
- `docs/upstream/PR-containerization-ext4-index-sync-20260723.md`
  - provides this upstream handoff.

## Validation on macOS

```console
swift package resolve
make check
make test
make coverage-unit
```

Results:

- Exact dependency resolution passed.
- Formatting and license gates passed.
- Normal unit run: 1,134 tests in 131 suites passed.
- Instrumented unit run: 1,135 tests in 131 suites passed.
- Unit coverage: 38.82% lines, 40.44% functions, 40.59% regions.
- Containerization full coverage: 647 tests in 85 suites passed.

## Compatibility and risks

The pin changes internal EXT4 file-tree representation in the dependency from
a child array to insertion-ordered indexed values. The public Container API
does not expose that representation. Containerization's full suite, including
subtree export, passed before this package graph was advanced.

No Container executable source changes are included.

## PR template

### Type of change

- [x] Dependency update
- [x] Upstream performance fix
- [x] Documentation update
- [ ] Container behavior
- [ ] Breaking change

### Motivation and context

Keep the matched runtime current with Apple's EXT4 unpacking performance fix
while preserving fork-owned subtree export behavior and release provenance.

### Testing

- [x] Exact SwiftPM resolution passed
- [x] Formatting and license checks passed
- [x] Full unit suite passed
- [x] Instrumented unit coverage passed
- [x] Containerization full coverage passed

Related issue handoff:
`docs/upstream/ISSUE-containerization-ext4-index-sync-20260723.md`.
