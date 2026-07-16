# Live Export for Running Containers

## Summary

Add a narrow runtime-backed export path for a running container's root
filesystem. The public surface can remain `container export --live`; no
Docker-shaped image commit endpoint is required.

## Motivation

`container export` currently reads a stopped container's ext4 root filesystem.
For a running container, the backing image must not be copied while the guest
is writing to it. A short freeze/copy/thaw sequence produces a consistent
snapshot while keeping the container running.

This is also the missing primitive for Docker Compose-compatible live service
commits. `container-compose` already owns Compose metadata, OCI archive
assembly, and image loading, so it needs only a safe running-filesystem export.

## Proposed runtime shape

- The Container API service derives the selected container's ext4 rootfs path.
- It asks that container's runtime service to snapshot the disk to a unique
  temporary file.
- The runtime serializes the operation with lifecycle work, freezes `/`, copies
  the image, and always attempts to thaw `/` before replying.
- The API service exports the temporary ext4 snapshot and removes it.

The runtime endpoint stays internal to the Container API service. It is not a
general host-file copy API: the Container API service resolves the source path
from the selected container bundle before invoking it.

## Validation

- Export a running container and verify its archive contents.
- Verify the container remains writable after the snapshot completes.
- Cover failed copy/thaw paths so a failed export does not leave the guest
  filesystem frozen.

## References

- Existing Apple discussion: <https://github.com/apple/container/pull/1630>
- Fork implementation: `feat(export): add live filesystem snapshots`
- Compose consumer handoff: `container-compose` live commit/export support
