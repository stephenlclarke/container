# Packaging handoff: Container must consume the vmexec namespace-entry repair

## Problem

Container's pinned Containerization revision predates the generic `vmexec`
repair for the Linux-invalid attempt to reenter the current user namespace.
The runtime bundle would therefore rebuild a guest that can return `EINVAL`
for execution against workloads sharing vmexec's user namespace.

## Required fork maintenance

- Pin `Package.swift` and `Package.resolved` to the immutable Containerization
  handoff tip `422302c9490f337ebfad0b17b9542de97bde9e34`.
- Resolve the dependency from its remote URL, then build and test the resulting
  Container package graph on macOS.
- Keep the upper Compose runtime manifest synchronized before it publishes a
  matched artifact.

## Apple-shaped boundary

The lower change is generic guest namespace-entry behavior. This Container
slice introduces no Docker or Compose vocabulary, no API, and no new host
policy; it only consumes an immutable reviewed runtime revision.

## Commit tracking

- Lower implementation:
  `fe896b6511d9fe0f0b8d3d25d3a8d8a1ed5ab5a1`
  (`fix(vmexec): avoid reentering the current user namespace`).
- Lower handoff tip:
  `422302c9490f337ebfad0b17b9542de97bde9e34`.
- Container provenance update:
  `1e8b8f57df4e7e43adb85db842c16e242e0f3f04`
  (`chore(deps): align vmexec namespace runtime revision`).
