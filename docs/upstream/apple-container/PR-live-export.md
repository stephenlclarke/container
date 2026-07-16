# Apple PR Handoff: Live Export for Running Containers

## Summary

Add `container export --live` by taking a short, consistent snapshot of a
running container's ext4 root filesystem.

## Scope

- Add an internal runtime snapshot request that freezes `/`, copies the
  selected rootfs image, and thaws `/` even after a copy failure.
- Wire the existing Container API export flow to select that path only for a
  running container when `--live` is requested.
- Keep normal stopped-container export unchanged.

## Deliberately out of scope

- A Docker-shaped `container commit` command or image metadata policy.
- Source-scoped networking, image registry, or Compose-specific behavior.
- General arbitrary-host-file copy access through the runtime endpoint.

Compose commit remains a consumer: it exports the live filesystem, builds the
OCI image archive with Docker-compatible metadata, then loads the image.

## Fork commit mapping

- `feat(export): add live filesystem snapshots`
- `test(export): verify live snapshots leave container writable`

The changes are intentionally kept as a focused export primitive so the
runtime implementation can be reviewed or cherry-picked independently of
Compose.

## Validation

- `make check`
- `make test`
- Focused real-runtime `TestCLIExportCommand/testExportCommandLive`

## Upstream references

- <https://github.com/apple/container/pull/1630>
- <https://github.com/apple/container/issues/1400>
