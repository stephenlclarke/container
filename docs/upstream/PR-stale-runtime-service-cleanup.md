# Pull request: bound stale runtime service teardown

## Summary

- Make stop idempotent for a persisted stopped snapshot.
- Add bounded XPC response waits to runtime stop and shutdown.
- Add a deadline to launchctl deregistration and replacement.
- Recover a timed-out bootout by killing only the exact service and retrying
  bootout once.
- Add focused regression coverage for each decision boundary.

## Apple-shaped boundary

This is a generic lifecycle correction in `apple/container`. A Compose client
can expose the hang through multi-container stop and removal, but the faulty
primitives are the native container service, runtime XPC client, and launchd
service manager. The patch adds no Compose behavior and performs no wildcard
or domain-wide cleanup.

## Code map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  - avoids contacting a runtime for an already-stopped snapshot.
- `Sources/Services/Runtime/RuntimeClient/RuntimeClient.swift`
  - bounds stop and shutdown response waits.
- `Sources/ContainerPlugin/ServiceManager.swift`
  - bounds bootout and implements exact-service kill-and-retry recovery.
- `Tests/ContainerAPIServiceTests/ContainerStopDispositionTests.swift`
  - covers the runtime-contact decision for every snapshot status.
- `Tests/ContainerRuntimeLinuxServerTests/RuntimeClientTimeoutTests.swift`
  - covers timeout derivation and the fixed shutdown deadline.
- `Tests/ContainerPluginTests/ServiceManagerTests.swift`
  - covers normal, timeout-recovery, and ordinary-failure deregistration.

## Validation

```sh
swift test \
  --filter 'ServiceManagerTests|ContainerStopDispositionTests|RuntimeClientTimeoutTests'
swift format lint --strict --configuration .swift-format-nolint \
  Sources/ContainerPlugin/ServiceManager.swift \
  Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift \
  Sources/Services/Runtime/RuntimeClient/RuntimeClient.swift \
  Tests/ContainerPluginTests/ServiceManagerTests.swift \
  Tests/ContainerAPIServiceTests/ContainerStopDispositionTests.swift \
  Tests/ContainerRuntimeLinuxServerTests/RuntimeClientTimeoutTests.swift
```

The focused test run passed 17 tests across three suites on this Apple-silicon
Mac. The changed-file format lint and `git diff --check` also passed. The
repository-wide format gate still reports unrelated pre-existing logging-plane
formatting findings, which this patch does not modify.

Signed local implementation checkpoint:
`c697aabb6d8e769c3d9c9d2d0cf977eacc63ca5f`.

## Publication state

This handoff is local to `upstream/logging-driver-parity`. Do not publish it to
Apple until all programme development is complete and the user explicitly
authorises upstream publication.
