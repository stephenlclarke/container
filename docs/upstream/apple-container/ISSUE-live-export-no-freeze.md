# No-Freeze Live Export Snapshot for Compose Commit

## Summary

Expose a narrow `ContainerClient.export` option for a running container that creates an APFS copy-on-write clone of its ext4 disk image without freezing guest filesystem writes.

## Motivation

Docker documents `commit --pause=false` as an explicit consistency trade-off: the container remains running and the resulting image can be less reliable than a paused commit. `container-compose` needs that behavior for Docker Compose v2 parity, but it owns the Docker-compatible image metadata and archive assembly itself. The backend only needs to export a best-effort root filesystem snapshot.

The existing `container export --live` path remains the safe default. It freezes the guest filesystem before copying the disk image and is retained for callers that require filesystem consistency.

## Proposed runtime shape

- Add `noFreeze: Bool = false` to `ContainerClient.export` and the internal runtime disk-snapshot request.
- Keep an omitted or false value on the existing freeze/copy/thaw path.
- When true, use Darwin `clonefile` to create an APFS copy-on-write clone of the container's ext4 backing image while the guest keeps running.
- Do not fall back to a long ordinary copy in no-freeze mode. The operation must fail clearly if APFS cloning is unavailable so it never silently changes the interruption and consistency contract.

## Semantics and scope

- This is a best-effort disk-image clone, not a filesystem- or application-consistent checkpoint.
- The source and destination must be compatible with APFS cloning. A no-freeze request fails rather than pretending to be safe on unsupported storage.
- The normal live-export default remains filesystem-consistent and is unchanged.
- The generic `container export` CLI remains unchanged. `container-compose` is the initial consumer because it owns Docker's `--pause=false` contract.

## Validation

- Unit-test copy-on-write isolation: writing the source after cloning does not alter the clone.
- Integration-test `ContainerClient.export(live: true, noFreeze: true)` against a running container, inspect the archive, and verify the container is still writable afterward.
- Preserve the existing frozen live-export integration test.

## Upstream context

- [apple/container#1400](https://github.com/apple/container/issues/1400) requests live export.
- [apple/container#1630](https://github.com/apple/container/pull/1630) remains open for the frozen `--live` path.
- [apple/containerization#660](https://github.com/apple/containerization/issues/660) explains the framework-level freeze/thaw primitive that the default path uses.
