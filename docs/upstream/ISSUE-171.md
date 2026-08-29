# Release handoff: pin the exact Containerization 0.14.0 head

## Problem

Container still selects an older Containerization revision while the matched
0.14.0 stack is being frozen. Containerization pull request 58 integrates the
current Apple runtime and security changes, preserves the fork contracts, and
closes the resulting registry, content-store, and guest-filesystem review
findings. Apple Container also advanced through `d65874da3655` after this
release branch was cut, adding validated digest-path handling and readable JSON
paths. Compose cannot publish a coherent stack until Container consumes both
authorities.

Tracking issue:
[`stephenlclarke/container#171`](https://github.com/stephenlclarke/container/issues/171).

## Required result

- Merge Apple Container main through `d65874da3655` while preserving the fork
  package graph and enhanced runtime contracts.
- Combine Apple's validated digest handling with the fork's concurrent image
  and snapshot disk-usage paths.
- Pin Containerization to the merged authority from pull request 58; reviewed
  head `d6c3586fe88a` is used only until the merge commit exists.
- Refresh the lock graph without moving unrelated dependencies.
- Retain focused manifest, resolution, image/snapshot, JSON rendering, affected
  API, and exact-head review evidence.
- Merge the signed pin before Container Compose pull request 333 records the
  final Container head.

## Scope boundary

This change advances the lower dependency and integrates the two Apple commits
that landed after the release branch was cut. It does not duplicate
Containerization implementation in Container, broaden functional parity scope,
or perform benchmark and documentation publication work that belongs to the
upper release workflow.

## Related work

- Containerization issue 57 and pull request 58 provide the lower runtime
  authority.
- Apple Container pull requests 2207 and 2205 provide the upstream dependency,
  digest-validation, and JSON-rendering changes.
- Container Compose issue 332 and pull request 333 own the 0.14.0 release.
