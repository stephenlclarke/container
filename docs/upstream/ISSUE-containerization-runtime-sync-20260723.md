# Dependency sync: Containerization runtime through `9097a24d`

## Context

The Container fork still resolved Containerization at
`9a3c5b4db57013256b681df9d90fe1a9235fcd03`. The current runtime fork now
includes:

- Apple Containerization PR
  [#809](https://github.com/apple/containerization/pull/809), adding virtiofs
  rootfs hotplug for cloud-hypervisor `LinuxPod` instances; and
- the Apple-shaped fix for issue
  [#804](https://github.com/apple/containerization/issues/804), ensuring
  `LinuxContainer.create()` stops a VM when `start()` fails.

Without an exact downstream pin update, Container and Compose releases would
continue compiling and packaging the older runtime even though the runtime
fixes were present on the Containerization fork's `main`.

## Required behavior

- Resolve the Containerization package at
  `9097a24d60deddaaa394f73c2ec5f8276ab5867b`.
- Keep `Package.swift` and `Package.resolved` on the same immutable revision.
- Avoid any Container command, API, persistence, or service source change.
- Rebuild the guest init image from the same revision used for host binaries.
- Preserve the existing environment overrides for local and upstream testing.

## Resolution

The signed dependency commit
[`8cf9468b861306a801c56924e591e98f39f771e8`](https://github.com/stephenlclarke/container/commit/8cf9468b861306a801c56924e591e98f39f771e8)
updates the two authoritative pins and makes no executable source change.
`swift package resolve` reproduced the exact requested revision without any
other lockfile delta.

## Validation

```console
swift package resolve
make check
make test
make coverage
```

Observed on Apple silicon macOS:

- Formatting and license checks passed.
- The normal unit target passed 1,134 tests in 131 suites, plus the XCTest
  set.
- Instrumented unit coverage passed 1,135 tests in 131 suites.
- Live coverage passed a 1-test image warmup, 238 tests in 27 concurrent
  suites, and 143 tests in 14 serial suites.
- Combined coverage reports were generated at 51.58% lines, 50.01%
  functions, and 51.44% regions.
- Runtime help provenance reported the exact `9097a24d` Containerization pin.

The downstream Compose repository still owns Docker Compose V2 parity,
release-asset provenance, and Homebrew installation evidence.

## Commit tracking

- Containerization runtime:
  `9097a24d60deddaaa394f73c2ec5f8276ab5867b`.
- Container dependency update:
  `8cf9468b861306a801c56924e591e98f39f771e8`.
