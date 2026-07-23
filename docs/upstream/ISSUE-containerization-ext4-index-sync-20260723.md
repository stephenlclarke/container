# Dependency sync: indexed Containerization EXT4 file tree

## Context

Apple Containerization commit
[`450d44e`](https://github.com/apple/containerization/commit/450d44e)
fixes quadratic EXT4 directory unpacking by indexing children by name while
preserving insertion order.

The Containerization fork reconciles that change with directory-subtree export
in signed commit
[`6aa6e803539c59ce754c55628e5417356216b297`](https://github.com/stephenlclarke/containerization/commit/6aa6e803539c59ce754c55628e5417356216b297).
Container must resolve and report the same reviewed runtime source.

## Required behavior

- Pin the Container package graph to the reconciled Containerization tip.
- Keep executable runtime behavior and all other dependencies unchanged.
- Compile and test the complete Container surface against the indexed file
  tree.
- Preserve exact source provenance for downstream Compose packaging.

## Resolution

The signed commit
[`40ce80785ab70f6fa3442c2706152e42efef5adf`](https://github.com/stephenlclarke/container/commit/40ce80785ab70f6fa3442c2706152e42efef5adf)
updates the manifest and lockfile to Containerization `6aa6e803`. The selected
tip includes Apple's performance fix, the minimal subtree-export conflict
resolution, full Containerization coverage evidence, and matching handoff
documentation.

## Validation

```console
swift package resolve
make check
make test
make coverage-unit
```

Observed on Apple silicon macOS:

- SwiftPM resolved exactly `6aa6e803539c59ce754c55628e5417356216b297`.
- Formatting and license checks passed.
- The normal unit target passed 1,134 tests in 131 suites.
- The instrumented unit target passed 1,135 tests in 131 suites.
- Unit coverage remained 38.82% lines, 40.44% functions, and 40.59% regions.
- The dependency's own coverage run passed 647 tests in 85 suites.

## Commit tracking

- Containerization reviewed tip:
  `6aa6e803539c59ce754c55628e5417356216b297`.
- Container pin:
  `40ce80785ab70f6fa3442c2706152e42efef5adf`.
