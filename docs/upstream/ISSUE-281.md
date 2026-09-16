# Issue 281: pin coverage-compatible Containerization revision

## Problem

The unattended Container-family release controller runs `make coverage` in
the exact Containerization revision selected by Container. Container pins
`4c95face06701be6572c92db34ca1864329c7b69`, whose inherited Makefile expects
the removed aggregate SwiftPM test bundle and fails under Xcode 27 and Swift
6.4.

Containerization issue
[#101](https://github.com/stephenlclarke/containerization/issues/101) and pull
request
[#102](https://github.com/stephenlclarke/containerization/pull/102) add
deterministic coverage generation for legacy and split SwiftPM bundles. The
reviewed change merged as
`51bf8a10e2036861f87ccdf2fd881a8726c534d2`.

## Scope

- Update the Containerization revision in the Swift package manifest and
  lockfile to the reviewed merge.
- Preserve all Container source and runtime behaviour unchanged.
- Verify that SwiftPM changes no unrelated dependency.
- Compile the focused Container runtime client against the exact new pin.

## Acceptance evidence

- SwiftPM resolves Containerization at
  `51bf8a10e2036861f87ccdf2fd881a8726c534d2`.
- No other package revision changes.
- `ContainerRuntimeClient` compiles with automatic resolution disabled.
- Required hosted checks and exact-head review pass before merge.

Related issue: [#281](https://github.com/stephenlclarke/container/issues/281).
