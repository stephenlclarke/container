# Compatibility gap: fractional CPU limits

## Surface

Generic `container run/create --cpus` resource configuration.

## Problem

The runtime accepted only an integer CPU count. Docker Compose normalizes
`cpus` as a fractional value, such as `0.25`, but forwarding that value to the
generic CLI failed before a container was created. The macOS Linux guest
already uses cgroup v2 CFS CPU quotas, so the missing piece was the generic
configuration bridge rather than a host-platform limitation.

## Required behavior

- Accept a positive fractional CPU value.
- Preserve an integral virtual CPU allocation for the sandbox VM.
- Apply an exact CFS quota with the established 100 ms period inside the Linux
  guest.
- Persist the optional quota without breaking existing saved configuration.
- Retain current integer CPU semantics.

## Apple-shaped implementation

The implementation commit is `b2a44aa`
(`feat(runtime): accept fractional CPU limits`) and depends on companion
generic runtime commit `f7b45bf` in `apple/containerization`
(`feat(runtime): support fractional CPU quota`).

The forks expose a generic optional quota measured in microseconds. Container
CLI parsing computes it from `--cpus`; the separate Compose adapter remains a
consumer of the generic CLI and contains no fork-specific policy.

## Scope and non-goals

- Support macOS-hosted Linux containers only.
- Do not add Windows controls.
- Do not expose Docker's separate CPU period, quota, realtime, or cpuset
  options in this narrow slice.
- Do not change host VM scheduling; the VM remains integral and the cgroup
  limits the workload.

## Upstream handoff condition

Both commits remain local-only until batched validation and push. Replay the
Containerization commit first, then replay the Container commit, rerun the
focused parser tests, staged fractional CPU integration test, `make check`,
and `make coverage-unit`. Update commit references if replay changes them.
