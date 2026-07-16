# Persistent Config Store for Compose External Configs

## Summary

Add a small, generic `container config` resource API for immutable, non-secret
byte content. It gives higher-level tools an explicit way to provision and
retrieve externally managed Compose configs without depending on a private
on-disk layout.

## Motivation

The Compose specification defines `configs.<name>.external` as a
platform-existing resource. `container-compose` can materialize local config
files into temporary read-only bind mounts today, but it correctly rejects
external configs because `apple/container` has no persistent,
user-addressable config primitive.

External configuration is not an OCI runtime feature and does not require a VM,
image, network, or mount-layer change. A narrow API store keeps this capability
at the `container` boundary while allowing Compose to retain Docker-compatible
file placement and service orchestration.

## Proposed API

- `ClientConfig.create(name:contents:labels:)`
- `ClientConfig.inspect(_:)` and `ClientConfig.list()` return metadata only.
- `ClientConfig.read(name:)` returns the immutable bytes through an explicit operation.
- `ClientConfig.delete(name:)` removes a config.
- `container config create|list|inspect|read|delete` exposes the same
  non-secret resource for administrators.

Metadata contains name, creation date, labels, and byte count. Content is
persisted separately from the metadata and never appears in list or inspect
output.

## Semantics

- Config names use the existing resource-name safety rules: no path traversal
  or nested path components.
- Content is immutable: creating an existing name fails; replacement is delete
  then create.
- Empty content is valid.
- This resource is intentionally **not** a secret store. It has no Keychain
  integration, encrypted-at-rest claim, restricted read authorization, or
  masking behavior.
- Compose remains responsible for creating a temporary read-only bind-mount
  source at the requested target path; the container runtime stays unaware of
  Compose.

## Deliberately out of scope

- Docker Swarm config API emulation or remote distribution.
- Secret storage. Secrets need a separate security and lifecycle design rather
  than reusing this plaintext config store.
- Live in-place update of a config already consumed by a service.
- New containerization framework APIs.

## Validation

- Unit tests cover safe storage-path construction and persistence across a
  service restart.
- Unit tests prove config bytes round-trip unchanged and metadata does not
  contain content.
- CLI help and end-to-end coverage should use a temporary `container system`
  app root to create, inspect, read, and delete a config.

## Upstream context

On 2026-07-16, targeted searches of `apple/container` found no existing
config-store or external-config implementation.
[apple/container#1736](https://github.com/apple/container/pull/1736) is an
unrelated Python Compose example and makes no Swift/runtime changes.
