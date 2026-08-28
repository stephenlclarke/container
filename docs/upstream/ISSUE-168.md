# Convergence handoff: sync Apple tmpfs and skill updates for 0.14.0

## Problem

The support fork was two commits behind Apple `main` while the matched 0.14.0
stack was being frozen. Apple pull request 2138 fixes empty tmpfs mount sources
for `--mount type=tmpfs`, and Apple pull request 2154 adds the current Container
skill. Shipping without those commits would retain a known runtime defect and a
stale user-support surface.

Tracking issue:
[`stephenlclarke/container#168`](https://github.com/stephenlclarke/container/issues/168).

## Required result

- Preserve the complete fork history while merging Apple through `388d964f`.
- Adapt Apple's tmpfs parser coverage to the fork's additional image-mount
  result without weakening either behavior.
- Point the matched dependency graph at reviewed Containerization and
  SwiftNIO SSL revisions.
- Align the imported skill with the fork's shipped isolation, memory,
  lifecycle, networking, and Compose functionality.
- Retain focused resolution, parser, help, metadata, review, and exact-head CI
  evidence before the upper Compose release pins this repository.

## Scope boundary

This is a convergence and release-provenance change. The Apple tmpfs fix and
skill are integrated without removing fork functionality. The additional
documentation corrections describe commands already present in this fork; they
do not add a new runtime contract.

## Related work

- Containerization issue 53 and pull request 54 provide the lower runtime pin.
- SwiftNIO SSL pull request 2 provides the reviewed TLS pin.
- Container Compose issue 332 and pull request 333 own the 0.14.0 release.
- Pull-request evidence is retained in [PR-169.md](PR-169.md).
