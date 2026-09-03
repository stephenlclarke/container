# Issue 199: sync Apple clean reliability updates before 0.14.1

## Problem

The 0.14.1 stable preflight correctly stopped because this support fork was two
commits behind Apple `container` main. Apple pull request 2228 fixes
`container clean` for read-only root filesystems and named-volume mounts, and
Apple pull request 2226 updates the pinned release action.

## Scope

- Merge Apple main through `025f57c6c0fed55bc155af0ddc13b11fff6f22e6`
  without rewriting fork history.
- Preserve the fork's lifecycle, isolation, memory, logging, Engine API, and
  prewarm extensions.
- Retain Apple's focused read-only clean regressions and release-action pin.
- Validate the exact merged revision before updating the Compose release stack.

## Acceptance evidence

- `git rev-list --left-right --count origin/main...HEAD` reports zero behind.
- The merge commit and handoff commit are signed.
- The modified runtime service compiles in the matched package graph.
- Workflow syntax, focused source checks, hosted required checks, and exact-head
  review pass before merge.
