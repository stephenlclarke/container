# Pull request: bootstrap an isolated Container root from an OCI init-image archive

## Summary

- Add `container system start --init-image-archive <path>`.
- Load and unpack the configured initial filesystem from that archive before
  any registry fallback.
- Retain the normal pull path when no archive is provided.
- Add command parsing coverage and document the option.

## Apple-shaped boundary

This is a generic `apple/container` offline/bootstrap primitive. It has no
Compose-specific semantics: a caller provides an OCI archive that must contain
the existing configured initial filesystem reference, and the normal runtime
remains the authority that validates and unpacks it.

## Code map

- `Sources/ContainerCommands/System/SystemStart.swift` adds the option and
  safe archive-load/unpack path.
- `Tests/ContainerCommandsTests/SystemStartTests.swift` proves argument
  parsing.
- `docs/command-reference.md` exposes the public invocation and fallback
  behavior.

## Validation

```sh
swift test --disable-automatic-resolution \
  --filter 'SystemStartTests/parsesInitialFilesystemArchive'
```

The focused parser regression passed. The exact signed candidate built from
the local Container, Containerization, and Engine API graph also passed the
real Docker CLI `local` logging lifecycle certificate through the public
Container Engine socket. Its first start loaded the source-derived OCI archive
for `docker.io/library/vminit:container-compose` before a registry pull, then
the second start completed with the installed image; the runtime/socket were
absent after cleanup.

Signed local implementation checkpoint:
`e048dc19d54e25aa3887689d0015d5af447d4ad5`.

## Publication state

Retain this unsubmitted handoff on `upstream/logging-driver-parity`. Rebase
onto the current Apple head and rerun the focused command and isolated runtime
certificate during the single user-authorised upstream publication wave; do
not publish beforehand.
