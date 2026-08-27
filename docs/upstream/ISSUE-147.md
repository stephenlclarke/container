<!-- markdownlint-disable MD013 -->

# [Bug] Shared VM natural exit hangs `container run --rm`

## Problem

A short-lived `shared-vm` process exits successfully, but two ownership assumptions prevent foreground completion. The API exit callback reads only the traditional `config.json` bundle even though a valid shared workload can still store its container configuration in `runtime-configuration.json`. Once that path progresses, the shared sandbox also retains the initial output writer after terminal observation, so the CLI does not receive end-of-file. The foreground `container run --rm` command either remains blocked or reaches its I/O deadline after the guest process has exited.

## Reproduction

1. Start the exact `main` candidate at `7d927d2f8cffff36117f5a5261e4d6fb490572d9` with its matched Containerization guest.
2. Run `container run --rm --name shared-one --isolation shared-vm --network none ghcr.io/linuxcontainers/alpine:3.20 true`.
3. Observe the successful guest exit followed by `ExitCallback for shared-one threw error ... config.json ... no such file` while the CLI remains blocked.
4. If the durable-configuration read is corrected alone, observe automatic removal followed by a foreground `CancellationError` after the three-second output EOF deadline.

## Required behavior

- Load exit lifecycle configuration and creation options from either a materialized bundle or the durable runtime configuration.
- Own and close each shared workload's initial I/O streams when that workload reaches a terminal state.
- Complete the stopped lifecycle and automatic removal after a natural shared-workload exit.
- Preserve the existing dedicated-VM lifecycle and default isolation choice.

## Acceptance evidence

- [x] Focused regressions load exit inputs from runtime configuration and publish output EOF on terminal observation.
- [x] Affected exit-input, stop, and shared rematerialisation tests pass.
- [x] The exact signed runtime reproduction prints output, completes, and removes the container.
- [x] The VZ share-readiness dependency is reviewed and merged.
- [x] Two sequential shared workloads complete in one VM with the final dependency pin.
- [x] The final diff passes strict formatting.

The final signed runtime certificate used Containerization `c60ba717`. Two
overlapping shared workloads reported boot ID
`00a77287-49e9-406b-b177-e38515167542` while reporting distinct PID namespaces
`pid:[4026532182]` and `pid:[4026532264]`. A third workload started after both
had exited and retained the same boot ID, proving sequential hot-plug reuse.
The omitted-isolation control booted a different dedicated VM, invalid
isolation failed closed, and all named containers were removed.

## Tracking

- Issue: [`stephenlclarke/container#147`](https://github.com/stephenlclarke/container/issues/147).
- Parent parity issue: [`stephenlclarke/container#113`](https://github.com/stephenlclarke/container/issues/113).
- Shared lifecycle pull request: [`stephenlclarke/container#146`](https://github.com/stephenlclarke/container/pull/146).
- Natural-exit pull request: [`stephenlclarke/container#148`](https://github.com/stephenlclarke/container/pull/148).
- VZ share-readiness issue: [`stephenlclarke/containerization#38`](https://github.com/stephenlclarke/containerization/issues/38).
- VZ share-readiness pull request: [`stephenlclarke/containerization#39`](https://github.com/stephenlclarke/containerization/pull/39).

<!-- markdownlint-enable MD013 -->
