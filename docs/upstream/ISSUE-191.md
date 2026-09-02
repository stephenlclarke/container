# Issue 191: sync Apple upstream before the 0.14.1 stack release

## Problem

The Container Compose 0.14.1 release preflight found this support fork two
commits behind Apple `container` main. The stable release gate requires every
Apple-backed support fork to contain current upstream history.

## Scope

- Merge Apple main without rewriting fork history.
- Preserve the fork's attach, process inspection, lifecycle, logging, Engine
  API, isolation, prewarm, and memory-control extensions.
- Integrate Apple's new `container clean` command and Containerization 0.43
  package requirements with the matched fork graph.
- Validate the exact merged revision before using it in 0.14.1.

## Acceptance evidence

- `git rev-list --left-right --count origin/main...HEAD` reports zero behind.
- The merge commit and follow-up handoff commit are signed.
- The `container` product compiles against the synchronized Containerization
  fork, and hosted required checks pass.
- The exact-head Codex review reports no unresolved findings before merge.
