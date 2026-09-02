# Issue 193: pin the deterministic Containerization NBD test

## Problem

The Container Compose 0.14.1 matched-stack gate exposed a concurrency-sensitive
Containerization integration test. The test passed in isolation but could lose
its virtual machine when it shared the concurrent `cctl` lane with other
write-heavy block tests.

Containerization issue
[#65](https://github.com/stephenlclarke/containerization/issues/65) and pull
request [#66](https://github.com/stephenlclarke/containerization/pull/66)
serialize only that persistence case. Container must pin the reviewed merge so
the release stack is internally consistent.

## Scope

- Update the Containerization revision in the Swift package manifest and
  lockfile.
- Preserve every runtime source and behavior unchanged.
- Prove exact dependency resolution and targeted client compilation before
  using the new Container head in Compose.

## Acceptance evidence

- SwiftPM resolves Containerization at
  `7d325176c08d45ca88be2761726bb2e07ed9dc94`.
- `ContainerRuntimeClient` compiles with automatic resolution disabled.
- Hosted required checks and an exact-head review pass before merge.
