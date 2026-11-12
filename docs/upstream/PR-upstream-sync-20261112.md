# chore: rebase container on Apple main

## Type of Change

- [x] Bug fix
- [x] New feature
- [x] Breaking change
- [x] Documentation update

## Motivation and Context

Rebase on Apple `c05a5604c5f784c41274ed8032def13e4aeb8e35` and use the reviewed
containerization SDK at `97b33cfedb641abbaf3638765c4e70fa6a2eef05`.
The directory watcher fix in apple/container#2126 is included from Apple history.

Move the fork's named builders, SSH forwarding, named contexts and cache controls
into Apple's new build modules. Keep DNS settings during builder startup and
recovery. Pin both default and named context directories for descriptor-based
file reads. Keep Apple's cluster topology and shared image store, with the fork's
safe CNI staging and single-node DNS setup.

Review fixes retain byte-precise memory values, reject an overflowing CPU quota,
avoid repeated logging setup, and load the init image after test-root cleanup.

Keep shared network aliases for service discovery and add Apple's wildcard
matching. Host DNS selects a primary name before an alias, then the longest
matching subtree. Network DNS can return all addresses for a shared alias.

The shell quoting and repeated node setup fixes from open apple/container#2130
are included in the new cluster provisioner. The startup container ID check from
open apple/container#2127 is retained. Those two PRs have not merged upstream.

## Testing

- [x] All 2,859 unit tests in 323 suites pass against the published SDK revision.
- [x] Packaging scripts and the focused test fixture checks pass.
- [x] Added or updated regression tests.
- [x] Updated docs.
- [x] All workflow, shell, Swift format and changed-document checks pass.
- [x] Build, builder and cluster help expose the expected options.
- [x] Removing the context-directory pin and CPU bound makes the new tests fail.

The matching SDK passes 1,065 macOS tests and 1,115 Linux tests. Both guest
executables build with Swift 6.3 and 6.4.1; the static ARM64 build also passes.
Builder shim tests, race tests, vet and the ARM64 Linux build pass.
Evidence is in `upstream-pr-refresh/20261112/fork-sync` in the task workspace.

## Compatibility and remaining limits

Apple's experimental `cluster` command replaces `k8s`. Build and builder are now
plugins. The fork keeps its workload, resource, logging and service DNS features.
The local container API service did not start in the runtime preflight, so these
checks do not establish a full VM integration run on macOS. The new cluster shim
was not built locally, so shared image store runtime tests remain pending.
The builder protocol has not changed. The existing builder image pin is retained;
a new image must be published separately to deploy the updated builder code.

Main requires review and blocks force pushes. A history-only merge retains the
published fork main as an ancestor without changing the rebased tree. Publication
uses a separate review branch and leaves main protection unchanged.
See [the issue handoff](ISSUE-upstream-sync-20261112.md).
