# Bootstrap input cannot opt into process stdin EOF

## Steps to reproduce

Run devcontainer's unchanged E07 init attachment fixture against the enhanced dedicated runtime. Bootstrap `sh -c` with a retained input socket, send four MiB through `cat`, half-close input, and retain a second output-only attachment. Require exact stdout/stderr, the stdin-closed suffix, exit 17, EOF on both output connections, saved history and a second generation.

## Problem description

`AttachableInput` treats every client EOF as detach, which is correct for ordinary reattachment but insufficient for a bootstrap client that explicitly owns process stdin. After the guest relay correction in [Containerization PR 104](https://github.com/stephenlclarke/containerization/pull/104), both clients receive 4,196,824 wire bytes but init remains waiting for stdin. The original 30-second connection deadline still fails. Wire counts do not establish exact payload parity.

The failing diagnostic case is `8785478d2c4f7ee629371e221133a9097704de802aa352eee2bcd827f5142317`, seal `0b803f3d0604bcf4a384f79df4753f1d275026872c2e0ea1435b9943c69d3ccd`. The exact guest boot commit was verified; cleanup removed all owned resources and recovery is clear. This remains an E07 failure, not a benchmark or release pass.

## Environment

macOS 27.0, Xcode 27.0 (27A266a), Apple Silicon; downloaded enhanced Container `780a86b995ac`, local guest `e45a379d2f8c7cc3bfcdd554bff701f3719c5279`. The fix starts from Stephen fork main `353c7b3784fa790c413c5b5ef02431fbdb817690`. Local SwiftPM tests use Swift 6.3 and macOS SDK 26.5. Runtime reproduction on the new main-based implementation remains required.

## Acceptance and ownership

Opt-in descriptor-owned EOF must drain previously accepted bytes, preserve default detach/reattach, remain bound to its original runtime generation, survive queued callbacks after closure and propagate through cold and prewarmed bootstrap. Unsupported shared-runtime requests must fail rather than silently lose the policy. Devcontainer must send the option when built with either supported client SDK. No change to Docker's assertions or deadlines is permitted.

Tracked in [issue 287](https://github.com/stephenlclarke/container/issues/287). Owner: the Container-family release workstream. The topic branch and worktree are retained only through reviewed PR integration and its exact-input live proof; they are removed after merge. This is a fork-specific attachment integration fix, not an Apple submission. Stable behavior and public release claims are unchanged until the affected gates pass.
