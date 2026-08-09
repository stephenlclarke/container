# Pull request: stage release packages from the selected SwiftPM build graph

## Summary

- Use `SWIFT_BUILD --show-bin-path` for `BUILD_BIN_DIR`.
- Keep package staging on the exact isolated SwiftPM graph requested by the
  caller.
- Add a deterministic Make dry-run regression for the staged API-server
  product path.

## Apple-shaped boundary

This is a generic `apple/container` packaging correction. It changes neither
Compose policy nor runtime behavior; it prevents a package from mixing a
selected source graph with stale default `.build` products.

## Code map

- `Makefile` derives the staging directory from the fully configured build
  command and runs the regression from the normal `test` target.
- `Tests/ScriptTests/TestBuildArtifactDirectory.sh` injects a selected build
  path and verifies the `homebrew-package` dry run stages from it.

## Validation

```sh
bash Tests/ScriptTests/TestBuildArtifactDirectory.sh
```

The focused regression passed on this Apple-silicon MBP. The exact local
release package subsequently built from an explicit scratch path, produced
archive SHA-256
`57067dd534f61e652deb0fb24de09c61efcc0c5d84896131eaa596113f67af85`, and
passed the isolated public Docker-socket logging certificate.

Signed local implementation checkpoint:
`c7b4898d4befad75480856305294001bd2eabf37`.

## Publication state

Retain this unsubmitted handoff on `upstream/logging-driver-parity`. Rebase
onto the current Apple head and rerun the focused regression during the single
user-authorised upstream publication wave; do not publish beforehand.
