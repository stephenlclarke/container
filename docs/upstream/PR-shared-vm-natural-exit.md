<!-- markdownlint-disable MD013 -->

# Pull request handoff: complete shared VM natural exit

## Type of change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and context

The first runtime proof of the merged shared-VM lifecycle found that a successful short-lived process could leave `container run --rm` blocked. The exit callback assumed `config.json` existed even though shared workloads can validly remain in the pre-materialized `runtime-configuration.json` form. After correcting that representation mismatch, the shared sandbox still retained the initial output writer after terminal observation, preventing the foreground CLI from receiving EOF. This change accepts both durable exit representations and gives the sandbox explicit per-workload I/O ownership so terminal cleanup publishes EOF before removal.

## Testing

- [x] Focused runtime-configuration and terminal-output EOF regressions pass.
- [x] Affected shared stop and rematerialisation tests pass.
- [x] Exact matched signed runtime reproduction prints output, completes, and auto-removes the container.
- [x] Pin the reviewed VZ unified-share readiness fix from Containerization pull request 39.
- [x] Run overlapping and sequential shared workloads in one VM with the final dependency pin.
- [x] Strict Swift format, Markdown lint, and `git diff --check` pass.

The final signed certificate used Containerization `c60ba717`: overlapping
workloads shared one VM boot ID but had distinct PID namespaces, and a third
workload reused that VM after both predecessors exited. The omitted-isolation
control used a different VM boot ID, an invalid isolation value failed closed,
and automatic removal left none of the named containers behind.

## Compatibility

Dedicated VM remains the default. The change does not alter isolation selection, accepted shared configurations, restart policy, or removal semantics; it only makes the existing exit path accept the durable representation already used by shared workloads.

## Links

- Issue: [`stephenlclarke/container#147`](https://github.com/stephenlclarke/container/issues/147).
- Parent parity issue: [`stephenlclarke/container#113`](https://github.com/stephenlclarke/container/issues/113).
- Shared lifecycle pull request: [`stephenlclarke/container#146`](https://github.com/stephenlclarke/container/pull/146).
- Natural-exit pull request: [`stephenlclarke/container#148`](https://github.com/stephenlclarke/container/pull/148).
- VZ share-readiness issue: [`stephenlclarke/containerization#38`](https://github.com/stephenlclarke/containerization/issues/38).
- VZ share-readiness pull request: [`stephenlclarke/containerization#39`](https://github.com/stephenlclarke/containerization/pull/39).

<!-- markdownlint-enable MD013 -->
