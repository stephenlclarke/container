# Compatibility gap: CPU CFS quota and period

## Surface

Generic `container run/create` resource configuration used by the macOS Linux
runtime.

## Problem

Container supported a CPU count/fractional quota but had no generic way to
pass a Linux CFS period or an explicit quota. Docker Compose V2 normalizes
`cpu_period` and `cpu_quota`, so a macOS-capable cgroup v2 feature was
previously rejected before container creation.

## Required behavior

- Persist and apply an explicit CFS period/quota pair in microseconds.
- Preserve zero-as-unset and `-1` unlimited quota semantics.
- Reject invalid negative values and positive `--cpus` combinations that
  conflict with explicit CFS controls.
- Keep the implementation generic and independent of Compose/Docker models.

## Apple-shaped implementation

Implementation commit: `81cc56f`
(`feat(runtime): support CPU CFS quota and period`).

Companion generic runtime commit: `e540824` in `apple/containerization`
(`feat(runtime): support CPU CFS quota and period`), which follows the earlier
fractional quota change `f7b45bf`.

The Compose consumer is deliberately separate: it maps its normalized values
to these generic CLI flags and does not change the fork's public API.

## Scope and non-goals

- macOS-hosted Linux containers only.
- No Windows controls.
- No realtime CPU scheduler, CPU affinity, or cgroup hierarchy support.
- No change to VM CPU allocation or host scheduling.

## Upstream handoff condition

Keep the commits local until the tested batch is ready. Replay the two
Containerization commits, then this consumer commit, run the focused unit and
guest cgroup test, `make check`, and unit coverage. Update commit references
if replays change their identifiers.
