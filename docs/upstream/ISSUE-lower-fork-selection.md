# Consume the validated SDK, SSL and gRPC forks in Container

## I have done the following

- [x] Verified the selected commits are published in Stephen-owned forks.
- [x] Compared the published foundation source pins with the intended fork sources.

## Steps to reproduce

Inspect the existing foundation release source graph. It selects canonical gRPC transport `2ca31f06658ed288a2560e23ad649acbb3d6b3a3` and SSL `322f3c2a4a21df31c84ca416bf65ee5e9059e440`, so independent fork test results do not establish runtime consumption of their corrections.

## Problem description

Select the validated fork revisions explicitly in the root manifest and resolved lock. Select SDK `96ef6bd6a3530723353fdda783f076fc0b35598b`, which includes current Apple code and the same immutable SSL/gRPC selections in both its host and guest locks. Preserve existing release assets and benchmark measurements; the changed candidate graph requires new compiled-layer and consumer evidence.

## Environment

Apple silicon MBP, Xcode 27 / Apple Swift 6.4. See [the integration handoff](PR-lower-fork-selection.md).
