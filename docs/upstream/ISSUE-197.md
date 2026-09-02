# Issue 197: pin deterministic Containerization cctl NBD scheduling

## Problem

The Container Compose 0.14.1 release gate exposed two remaining
Virtualization.framework scheduling failures in Containerization's VM-backed
`cctl --block` integration coverage. Containerization issue
[#69](https://github.com/stephenlclarke/containerization/issues/69) and pull
request [#70](https://github.com/stephenlclarke/containerization/pull/70)
route every VM-booting case through the existing exclusive VZ lane while
keeping validation-only coverage concurrent.

Container still pins the preceding Containerization merge
`f77f8d2833b54498546c081a0a5d15b4751b62bd`. The stable controller correctly
refuses to publish a stack whose immutable dependency pin differs from the
reviewed sibling main revision.

## Scope

- Update the Containerization revision in the Swift package manifest and
  lockfile to the reviewed merge
  `818f5917819a32dac1bc233605c253b4a105e0e0`.
- Preserve all Container source and runtime behavior unchanged.
- Verify that SwiftPM changes no unrelated dependency.
- Compile the focused Container runtime client against the exact new pin.

## Acceptance evidence

- SwiftPM resolves Containerization at
  `818f5917819a32dac1bc233605c253b4a105e0e0`.
- No other package revision changes.
- `ContainerRuntimeClient` compiles with automatic resolution disabled.
- Required hosted checks and exact-head review pass before merge.

Related issue: [#197](https://github.com/stephenlclarke/container/issues/197).
