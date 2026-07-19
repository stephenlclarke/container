# Packaging gap: Phase 1 runtime revision is not in the Container artifact

## Problem

The checked-in `containerization` dependency was pinned to
`14e7957efc369507ff308c9217397c7ccca43445`. That revision predates the
completed generic shared-sandbox namespace policy. As a result, a clean
Container build cannot contain the reviewed lower-runtime Phase 1 work even
though the fork's implementation and handoff commits are on its `main` branch.

This is a build provenance error, not a request for Docker or Compose behavior
in `apple/container`.

## Required fork maintenance

- Pin `Package.swift` and `Package.resolved` to the immutable lower-runtime
  handoff tip `2d7ae6c01227d4c95a5f44fdc9768070923ee335`.
- Resolve the package from its remote URL without a local path or source
  override, then build and test the resulting package graph.
- Keep the pin synchronized with Compose's complete stack manifest before a
  Compose artifact is published.

## Apple-shaped boundary

The lower-runtime implementation is generic:
`LinuxPod.Configuration.NamespaceSharing` selects PID and IPC namespace sharing
without Docker or Compose types. Container continues to expose no
Compose-specific interface and no unsafe adapter for service namespace sharing.
The subsequent Compose stack-reference update is release provenance only.

## Non-goals

- Adding Docker or Compose parsing to `container`.
- Replacing independent containers with a pod, which would incorrectly share
  guest networking.
- Windows support, macOS host namespace access, or arbitrary namespace paths.

## Upstream handoff

This fork-only pin is not itself an Apple pull request. An upstream Container
change, if needed after the lower-runtime API is accepted, must depend on the
accepted `apple/containerization` revision instead of this fork URL or hash.
