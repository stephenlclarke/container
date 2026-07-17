# Apple PR Handoff: Volume Subpath Mounts

## Summary

Add the narrow runtime support required for Docker's
`--mount type=volume,volume-subpath=<directory>` option. The selected
directory is mounted from a named volume without exposing the volume root to
the container process.

## Scope

- Parse `volume-subpath` only for `type=volume` mount specifications.
- Preserve the value through named-volume resolution and runtime conversion.
- Add the value to the typed `Filesystem` model, keeping persisted
  configurations backward compatible.
- Delegate the secure guest-side staging to the paired Containerization
  primitive.

## Rationale

Docker requires the subdirectory to exist before container startup. The
Containerization primitive mounts the block volume privately, resolves the
relative subpath below that root using `openat2(RESOLVE_IN_ROOT)`, requires a
directory, and then exposes a bind mount to the OCI runtime. This keeps the
user-facing parser and service layer simple while preventing traversal and
symlink escape.

## Deliberately out of scope

- Automatically creating the requested subdirectory.
- Supporting `volume-subpath` for bind, tmpfs, or virtiofs mounts.
- Compose-file normalization and rendering; the Compose consumer remains a
  separate follow-up.

## Dependency

This change requires the Containerization mount-subpath primitive in the
paired fork PR. It deliberately uses no new Docker-specific backend API:
`container` continues to convert a typed filesystem into `Containerization.Mount`.

## Validation

- Parser coverage for a valid volume subpath and invalid non-volume use.
- Runtime conversion coverage confirming the subpath reaches
  `Containerization.Mount`.
- Full `make test`, `make fmt`, and `make check`.
