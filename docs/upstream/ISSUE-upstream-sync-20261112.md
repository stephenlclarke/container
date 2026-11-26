# Update the container fork to Apple main

## Steps to reproduce

Build the fork based on `cb30a2e0` against current Apple modules and SDK.

## Current behavior

Apple has moved build and builder commands into plugins and replaced the old
Kubernetes command with the cluster command. It also changed filesystem access,
DNS matching, machine setup and runtime resources. The old fork cannot simply
replay its changes without adapting these boundaries.

## Expected behavior

Base the fork on Apple `c05a5604` and retain the needed fork features. Use the
current SDK, include fixes that Apple has merged, and test the combined code.

## Environment and scope

Apple Silicon macOS with Xcode Swift 6.4.2. The matching SDK review branch is
`stephenlclarke/containerization:sync/apple-main-20261112`.
This is a fork update; it does not change the open Apple PR branches.
See [the PR handoff](PR-upstream-sync-20261112.md).
