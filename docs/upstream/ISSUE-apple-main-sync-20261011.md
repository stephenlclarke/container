# Synchronize the fork with Apple's builder plugins, machine setup and Kubernetes changes

## I have done the following

- [x] Reviewed current Apple commits, relevant issues and the fork's existing upstream pull requests.
- [x] Compared the measured fork source with Apple main before resolving conflicts.

## Steps to reproduce

Compare measured fork revision `2e1f3269fd421c52ab7abb415e5b9b2301ab44ea` with Apple main `f70ecbb926d925818a34917529e304b1177ce98c`. The measured runtime predates the extracted build/builder plugins, shared resource output, machine user setup and Kubernetes multi-node/CNI changes. Merely merging those files leaves incompatible public build entry points, retired machine helpers and an incomplete executable inventory in the native release pipeline.

## Problem description

Adopt Apple's current implementation and retain only the necessary fork behavior. Preserve named builders, SSH and DNS forwarding, builder startup locking, API invocation isolation, service health checks and machine bundle rollback. Include the new executables in compiled-consumer proof, staging, signing, debug symbols and measured-product retention. Historical published binaries and benchmarks must remain valid without rebuilding or recapturing them.

The imported Kubernetes worker selector must also distinguish a cluster's numeric worker suffix from another cluster whose name starts with that prefix. For example, deleting `dev` must not select a worker belonging to `dev-worker-blue`.

## Environment

- Local Apple silicon MBP, Xcode 27 / Swift 6.4.
- Container measured source: `2e1f3269fd421c52ab7abb415e5b9b2301ab44ea`.
- Apple Container source: `f70ecbb926d925818a34917529e304b1177ce98c`.
- Provisional SDK verification source: `9ab51bbcf4a2dedf75d7f49d257de16ca13cd09f`.

## Related work

See [the proposed integration and validation](PR-apple-main-sync-20261011.md). This is a local source integration handoff, not a new submission to Apple.
