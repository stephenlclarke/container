# Runtime gap: callers cannot select a guest cgroup parent

## Problem

The Container CLI and Linux runtime data payload have no way to request the
generic `LinuxContainer.Configuration.cgroupParent` primitive. A macOS client
therefore cannot arrange its containers beneath a named cgroup hierarchy in the
sandbox VM, even though the lower runtime validates the hierarchy and creates
the OCI leaf cgroup.

This is a missing generic Container option, not a Docker or Compose feature.

## Required behavior

- Accept `--cgroup-parent <relative-path>` on `container run` and `create`.
- Carry the value through `LinuxRuntimeData` to the runtime service.
- Apply it to `LinuxContainer.Configuration.cgroupParent`.
- Reject absolute paths and empty, `.` or `..` components before runtime work.
- Preserve the default guest cgroup path when the option is omitted.

## Apple-shaped boundary

The parent is a relative Linux guest path below Containerization's managed
`/container` root. It does not represent a macOS host cgroup, expose host
namespaces, or add Docker/Compose parsing to `apple/container`.

## Dependencies

This change consumes the generic lower-runtime code commit
`8d4b530b5a8a9b8bca550e54a9820296cc548b7d`
(`feat(runtime): add guest cgroup parent support`). Its Container implementation
commit is `aa11d79f001af25a162925a5093f585fc24be955`.
