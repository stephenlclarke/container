# Pull request handoff: verify streamed build-context archives

## Summary

Make Container's file-synchronisation client describe the bytes that it
actually streams to the Builder:

- omit the context root itself from `Walk` results, because it has no relative
  child path and therefore cannot have a valid parent inside the context;
- calculate the `tar` transfer digest from the completed archive, rather than
  from the source walk; and
- cover both properties with focused `BuildFSSync` tests, including a context
  rooted below macOS's `/private/tmp` alias.

## Apple-shaped boundary

This change is confined to `Sources/ContainerBuild/BuildFSSync.swift`. It does
not add a Compose concept, modify a public CLI option, or change a runtime
service. The existing file-transfer protocol already contains the archive
digest and walk entries; this makes their values match the bytes and paths that
are already sent.

## Problem and rationale

The Builder validates the archive digest before using a transferred build
context. Hashing a source traversal can differ from hashing the emitted PAX
archive, causing valid contexts to be rejected. In addition, publishing the
context root as a child makes a root without a parent appear in the protocol.
That showed up for Dockerfile paths outside their context, particularly when
macOS's `/tmp` and `/private/tmp` aliases participated in the path comparison.

The archive is already written to a temporary file before transfer. Streaming
that file through `bufferedCopyReader()` into `SHA256` keeps memory bounded and
makes the header's `hash` value exactly match the following data packets.

## Code map

- `Sources/ContainerBuild/BuildFSSync.swift`
  - skips the empty relative root path while constructing `Walk` entries;
  - hashes the completed archive bytes before sending the `BuildTransfer`
    header.
- `Tests/ContainerBuildTests/BuildFSSyncTests.swift`
  - checks the advertised header digest against the reassembled transfer;
  - checks that `Walk` emits only child paths;
  - exercises tar walking under `/private/tmp`.

## Builder source/image pairing

The Stephen-owned fork also pins its Builder image to an immutable digest and
pins protocol generation to the matching Builder source revision. That is
release plumbing for the fork, not required by this Apple PR. It prevents a
mutable `current-*` OCI tag from being incorrectly treated as a Git branch
while regenerating the existing protocol bindings.

## Validation

```sh
make test
make -f Protobuf.Makefile protos SWIFT=swift \
  BUILD_BIN_DIR="$PWD/.build/arm64-apple-macosx/debug"
APP_ROOT=/private/tmp/container-build-isolation/app \
LOG_ROOT=/private/tmp/container-build-isolation/logs \
SCRATCH_ROOT=/private/tmp/container-build-isolation/scratch \
WARMUP_FILTER=ImageWarmup/ \
CONCURRENT_FILTER=ImageWarmup/ \
SERIAL_FILTER=TestCLIBuilderSerial/ \
make integration
make check
```

The local validation passed 1,087 unit tests, all 45 Builder serial integration
tests, protocol regeneration at the pinned source revision, and `make check`.
The integration test uses a fresh `XDG_CONFIG_HOME` so that it validates the
declared Builder image instead of a developer's local override.

Compose's `build.context` contract is unchanged: Compose passes the normalised
context and Dockerfile to this existing CLI transfer path. The paired
`container-compose` release gate runs its Docker Compose V2 build-context
parity scenario after the source package is published; no Compose schema or
fallback is proposed by this handoff.

## Upstream context

- [apple/container issue #1899](https://github.com/apple/container/issues/1899)
  documents the external-Dockerfile path failure.
- [apple/container pull request #1922](https://github.com/apple/container/pull/1922)
  addresses path canonicalisation. This handoff complements it by ensuring the
  protocol's root entry and archive digest are valid independently of path
  spelling.

## Commit tracking

- `375cb51a7b349a20a7b10536e185e2b32efe3940`
  (`fix(build): verify fssync context archives`).
