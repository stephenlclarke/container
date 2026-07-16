# Apple PR Handoff: No-Freeze Live Export Snapshot

## Summary

Add an opt-in `noFreeze` flag to the existing live-export client/runtime path. It creates an APFS copy-on-write clone of a running container's ext4 disk image without freezing guest filesystem writes.

## Scope

- Keep `ContainerClient.export(..., live: true)` on its current freeze/copy/thaw path.
- Thread `noFreeze` through the Container API and runtime XPC requests.
- Use `clonefile` only when `noFreeze` is true.
- Add unit and running-container integration coverage.

## Rationale

This is deliberately a small storage primitive. Docker's `commit --pause=false` explicitly accepts a higher likelihood of corruption in exchange for not pausing the container. The Compose plugin translates that CLI behavior into `ContainerClient.export(..., live: true, noFreeze: true)`, then continues to build its own OCI image archive and metadata.

## Deliberately out of scope

- A generic Docker-compatible `container commit` CLI.
- Changing the public `container export --live` default or adding a CLI no-freeze flag.
- Application-consistent snapshots, database quiescing, or a VM checkpoint API.
- Changes to `apple/containerization`; its existing freeze/thaw primitive still supplies the consistent default path.

## Failure behavior

No-freeze mode requires APFS copy-on-write cloning. If cloning is unavailable, the request fails rather than falling back to a full concurrent file copy, because that fallback would materially change both duration and consistency behavior.

## Validation

- `DiskSnapshotTests` proves the clone remains isolated after later source writes.
- `TestCLIExportCommand/testExportCommandLiveWithoutFreeze` checks the new client path against a running container.
- Existing `testExportCommandLive` keeps the frozen default covered.
