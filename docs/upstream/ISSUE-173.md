# Release handoff: pin the VZ lifecycle repair

## Problem

The prepared 0.14.0 Container graph selects Containerization revision
`59ce8dafa11841f47287e3c29d1e8fe6d976236c`. The matched release gate
exposed three VZ pod lifecycle failures at that revision: repeated stop and NBD
cleanup could race process reaping, and a hotplugged block root filesystem
could not safely use its reserved runtime virtiofs mount.

Containerization issue 59 and pull request 60 repair those contracts with
pidfd-backed signaling and mount-ID-bound `openat2` resolution. Container must
pin the exact signed merge before Compose and the stable release artifacts can
consume a coherent stack.

Tracking issue:
[`stephenlclarke/container#173`](https://github.com/stephenlclarke/container/issues/173).

## Required result

- Pin Containerization to the signed merge of pull request 60.
- Refresh `Package.resolved` without changing unrelated dependency revisions.
- Confirm package resolution and the focused Container build path affected by
  the dependency pin.
- Retain clean exact-head review and hosted check evidence.
- Merge the signed pin and provide its merge revision to the final Compose pin
  and 0.14.0 release archive.

## Scope boundary

This change advances only Container's lower runtime dependency. It does not
duplicate the Containerization repair, add unrelated parity work, rerun broad
benchmarks, or publish release documentation.

## Related work

- Containerization issue 59 and pull request 60 own the runtime repair.
- Container Compose issue 332 owns the coherent 0.14.0 release.
