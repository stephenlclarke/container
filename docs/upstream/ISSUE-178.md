# Release blocker: dedicated prewarming reserves shared block mounts

## Problem

Creating two dedicated containers that reference the same named volume allows
both create operations, but background prewarming for the first container boots
a VM and retains the block-backed storage attachment while the public container
remains in the `created` state. Starting the second container then fails with
Virtualization.framework `VZErrorDomain Code=2` (`The storage device attachment
is invalid`).

Tracking issue: [`stephenlclarke/container#178`](https://github.com/stephenlclarke/container/issues/178).

## Reproduction

1. Create a named volume.
2. Create two never-started dedicated containers that mount it.
3. Start the second container.

Deleting the first created container before starting the second releases the
attachment and allows the second container to start. The same ownership
conflict blocks Container Compose `pre_start` helpers that inherit a stopped
service volume.

## Required result

- Background prewarming must not reserve block-backed resources needed by
  another container.
- Containers with block or named-volume mounts must start cold unless
  prewarming can prove exclusive ownership.
- Mount-free and VirtioFS-only dedicated containers must remain eligible for
  the existing prewarm optimization.
- A focused regression and the strict lifecycle-hook parity fixture must prove
  the boundary.

## Release boundary

This defect was found by the strict 0.14.0 Docker Compose lifecycle-hook parity
gate. Stable promotion stopped before creating the `0.14.0` tag or publishing
release assets.
