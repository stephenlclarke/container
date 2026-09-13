# Pin a published exact Containerization VM-init authority

## Problem

A fresh enhanced Container installation derives its default VM-init image from
the pinned `stephenlclarke/containerization` source revision. The current
revision has no image in that namespace, so an isolated `container system
start` fails with a registry `404`. Retained release-gate archives and ambient
user configuration can mask the missing immutable runtime dependency.

## Required behavior

- Pin Container and `Package.resolved` to the merged Containerization revision
  that publishes its exact VM-init image.
- Resolve the compiled default image anonymously from GHCR before accepting the
  pin.
- Boot and stop a clean runtime with no inherited user configuration or cached
  application assets.
- Preserve the immutable builder-image authority and stock Apple behavior.
- Report exact Container and Containerization source identities throughout the
  runtime and release evidence.

## Acceptance evidence

- [x] The exact source-revision image resolves anonymously from GHCR at digest
      `sha256:37d083fbd28eabb01da0e3ad009f7c6829d60808fb23baa38c4ac9dffc35663b`.
- [x] Package manifest and lockfile contain the same full revision.
- [x] Repository build, all 2,501 package tests, formatting, licensing, and
      auxiliary test harnesses pass.
- [x] A clean isolated runtime starts, reports healthy, runs an Alpine command
      with the exact published VM-init authority, and stops. The candidate was
      Developer-ID signed with the production virtualization entitlement and
      used a marker-owned application root with no inherited configuration.
- [ ] The downstream Compose release and Docker-less devcontainer parity lane
      consume the same immutable authority.

## Tracking

- Issue: <https://github.com/stephenlclarke/container/issues/265>
- Publisher: <https://github.com/stephenlclarke/containerization/pull/96>
