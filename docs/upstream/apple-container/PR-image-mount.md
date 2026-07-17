# Apple PR Handoff: Read-Only OCI Image Mounts

## Summary

Add Docker Engine 28-compatible `--mount type=image` support. An existing
local OCI image snapshot is attached as a read-only filesystem at the selected
container destination. `image-subpath` selects an existing directory inside
the source image.

## Scope

- Parse `type=image`, `source`, `destination`, and `image-subpath`.
- Require an existing local source image; image mounts do not introduce a
  second image pull policy.
- Reuse the images service's existing platform-specific snapshot primitive.
- Force the resulting mount read-only, matching Docker image-mount behavior.
- Preserve `image-subpath` through the typed `Filesystem` model into the
  generic secure block-subpath runtime path.

## Rationale

The images service already returns an immutable, unpacked ext4 snapshot for a
local OCI image. The only missing layer is converting that snapshot into a
mount at container configuration time. Reusing `Filesystem.block` keeps the
implementation general: Containerization's existing `openat2(RESOLVE_IN_ROOT)`
subpath staging supplies containment and symlink-escape protection without a
Compose-specific runtime API.

Docker added `--mount type=image` in Engine 28 through
[moby/moby#48798](https://github.com/moby/moby/pull/48798), with
`image-subpath` following in the same implementation. Its integration coverage
includes ordinary subdirectories, a symlink resolving within the image root,
and rejection of a path that escapes the image root.

## Deliberately out of scope

- Pulling a missing image-mount source. Docker's mount source is resolved from
  the local image store; service-image pull policy stays separate.
- Writable image mounts, arbitrary host filesystems, artifacts that are not
  OCI images, and bind/volume mount policy.
- Changes to Apple-owned remotes.

## Compose handoff

`container-compose` owns `type: image` normalization and Compose policy. Once
this primitive is present in the Stephen-owned `container` fork, it can render
the Docker-shaped argument:

```text
--mount type=image,source=<image>,destination=<target>,image-subpath=<path>
```

## Validation

- Parser coverage for valid image mounts, forced read-only behavior, subpath
  validation, and missing sources.
- Typed snapshot projection coverage for destination, read-only mode, and
  subpath retention.
- Full `make test`, `make fmt`, and `make check` before fork handoff.
