# Pull request: accept macOS system aliases in native logging storage

## Summary

- Map Darwin's immutable `/tmp` and `/var` aliases to their `/private`
  spellings before secure logging-directory traversal.
- Apply the rule consistently to Docker json-file storage, native local
  storage, and legacy native reads.
- Add focused lifecycle regressions using literal `/tmp` paths.

## Apple-shaped boundary

This is a generic `apple/container` logging-storage correctness fix. It changes
no Compose-specific behavior, public API, log encoding, delivery policy, or
retention semantics. Only the two fixed Darwin system aliases are accepted;
all arbitrary path components continue through descriptor-relative
`O_NOFOLLOW` traversal and the existing ownership and permission fences.

## Code map

- `Sources/ContainerLoggingStorage/DarwinSystemDirectoryAlias.swift`
  - defines the narrow fixed-alias mapping.
- `Sources/ContainerLoggingStorage/DockerJSONFileLogStore.swift`
  - uses the mapping for secure json-file store and reader traversal.
- `Sources/ContainerLoggingStorage/NativeLocalLogStore.swift`
  - uses the mapping for secure local and dual-cache traversal.
- `Sources/ContainerLoggingStorage/ContainerLogNativeReader.swift`
  - uses the mapping for legacy static reads.
- `Tests/ContainerRuntimeLinuxServerTests/ContainerLogRuntimePlanTests.swift`
  - covers `json-file` and `local` write/read lifecycle below literal `/tmp`.
- `Tests/ContainerRuntimeLinuxServerTests/ContainerLogNativeReaderTests.swift`
  - covers legacy static reading below literal `/tmp`.
- `docs/upstream/ISSUE-logging-system-directory-aliases.md`
  - records the upstream bug, boundary, reproduction, and evidence.

## Validation

```sh
swift test \
  --filter ContainerLogRuntimePlanTests/darwinSystemDirectoryAliasesPreserveNativeStoreLifecycle
swift test \
  --filter ContainerLogNativeReaderTests/legacyReaderAcceptsDarwinSystemDirectoryAlias
```

Both exact tests pass on this Apple-silicon Mac. A grouped staged runtime replay
and the broad repository gates remain intentionally deferred until several
related logging slices are ready for validation together.

Signed local implementation checkpoint:
`5a9802499bc720994d50d055a63a1710a75795d5`.

## Compatibility and risks

The behavioral expansion is limited to paths that macOS itself publishes as
fixed system aliases. A general symlink is still rejected. Existing canonical
`/private/tmp` and `/private/var` paths are unchanged, as are paths outside
those aliases.

## Publication state

This handoff is prepared locally on the `upstream/logging-driver-parity` branch.
Do not publish it to Apple until all programme development is complete and the
user explicitly authorises upstream publication.
