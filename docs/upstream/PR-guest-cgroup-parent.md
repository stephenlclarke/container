# Pull request handoff: add a guest cgroup parent option

## Summary

- Adds `container run/create --cgroup-parent <relative-path>`.
- Carries the value through the existing opaque Linux runtime-data boundary.
- Sets Containerization's generic guest-only `cgroupParent` configuration.
- Pins the package graph to the matching lower-runtime implementation.

## Type of change

- [x] Runtime API and CLI capability
- [x] Documentation update
- [x] Unit-test coverage
- [ ] Docker or Compose parser change

## Motivation and context

Containerization already safely supports a relative parent in the sandbox VM
cgroup v2 hierarchy. This change exposes that generic primitive through
Container so higher-level clients can use it without duplicate cgroup path
construction or a Compose-specific runtime seam.

## Apple-shaped boundary

- `apple/containerization` validates the relative parent and derives the OCI
  guest cgroup path.
- `apple/container` parses and transports a generic `--cgroup-parent` option.
- `container-compose` separately maps Docker Compose `cgroup_parent` to this
  generic option.

No product source mentions Compose. The option applies only inside the
macOS-hosted Linux VM; it cannot select, create, or expose a macOS-host
cgroup.

## Code map

- `Package.swift` and `Package.resolved` pin Containerization commit
  `8d4b530b5a8a9b8bca550e54a9820296cc548b7d`.
- `Flags.Management` declares the documented `--cgroup-parent` option.
- `Parser.cgroupParent(_:)` rejects unsafe path shapes.
- `LinuxRuntimeData` preserves the optional field across the runtime IPC
  payload, including compatibility decoding for older payloads.
- `RuntimeService.configureContainer` maps the value to
  `LinuxContainer.Configuration`.
- `docs/command-reference.md` matches the installed command help.

## Validation on macOS

```sh
swift package resolve
swift test --filter 'ParserTest.testCgroupParentAcceptsRelativeGuestPaths()'
swift test --filter 'ParserTest.testCgroupParentRejectsUnsafePaths()'
swift test --filter 'ContainerRunCreateCommandTests.runtimeDataEncodesCgroupParentFlag()'
swift test --filter 'RuntimeServiceHostsTests.configureContainerPassesCgroupParentToContainerization()'
make test
make check
.build/debug/container run --help
git diff --check
```

All focused checks pass. `make test` passed 1,084 tests in 128 suites, and
`make check` passed after installing the repository's pinned Hawkeye binary.
The local help output includes the guest-only cgroup-parent description.

## Docker Compose compatibility

Docker Compose v2 parity belongs to the separate Compose adapter: it compares
`cgroup_parent` configuration acceptance and verifies that the adapter emits
this CLI option. This Container PR is deliberately generic and has no Compose
YAML parser or Docker compatibility branch.

## Commit tracking

- Containerization implementation:
  `8d4b530b5a8a9b8bca550e54a9820296cc548b7d`
  (`feat(runtime): add guest cgroup parent support`).
- Container implementation:
  `aa11d79f001af25a162925a5093f585fc24be955`
  (`feat(runtime): add guest cgroup parent option`).

## Remaining risks

The option currently creates a hierarchy, but Container does not expose a
separate cgroup-parent lifecycle or administrative resource-control API. That
is intentional: the VM and its cgroups remain runtime-owned. Windows behavior,
Linux-host cgroup access, and profile-specific cgroup policies remain out of
scope.

Related issue handoff: `docs/upstream/ISSUE-guest-cgroup-parent.md`.
