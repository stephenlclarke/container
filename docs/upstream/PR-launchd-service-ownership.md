# Pull request: reconcile stale launchd service ownership

> [!IMPORTANT]
> This handoff is limited to the macOS launchd runtime boundary. It does not
> change Linux guest behavior or introduce Windows support.

## Type of change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and context

`container` services use stable launchd labels so that the CLI, API server,
and plugins can find one another. Before this change, a second installation or
application root reused a matching label solely because it was registered.
That connects the new API server to a helper owned by the old root, which can
leave `container system start` waiting for an XPC response indefinitely.

This is reproducible by starting one source-matched runtime, then starting a
second one with a different `--app-root`. The second start must replace the
API server, machine API, image, and vmnet network-helper plists together.

The companion problem statement is
[ISSUE-launchd-service-ownership.md](ISSUE-launchd-service-ownership.md).

## Apple-shaped boundary

The change is confined to `apple/container`'s existing `ServiceManager`
abstraction:

- inspect the registered service's plist path with `launchctl print`;
- reuse the service only when its canonical plist path matches the requested
  registration;
- boot out and register a same-label service only when its owner differs.

`SystemStart` and `PluginLoader` continue to create the same `LaunchPlist`
objects. They now delegate idempotency and stale-owner replacement to the one
launchd abstraction instead of making separate label-only decisions. No
Compose-specific runtime API is added.

## Code map

- `Sources/ContainerPlugin/ServiceManager.swift` derives the label from the
  requested plist, compares canonical owner paths, and performs the narrowly
  scoped `bootout`/`bootstrap` replacement when necessary.
- `Sources/ContainerCommands/System/SystemStart.swift` delegates API-server
  registration to that reconciler.
- `Sources/ContainerPlugin/PluginLoader.swift` delegates every plugin helper
  registration to the same reconciler.
- `Tests/ContainerPluginTests/ServiceManagerTests.swift` covers missing,
  matching, stale, and `/tmp` symlink-canonicalized ownership states plus
  `launchctl print` parsing.
- `Tests/ContainerPluginTests/PluginLoaderTest.swift` verifies plugin
  registration is delegated to the reconciler even when a label already exists.

## Validation

```sh
swift test --filter ContainerPluginTests
make test SWIFT_TEST_FLAGS=--no-parallel
```

The targeted unit suite passes 55 tests. The full unit suite passes 1,119
tests in 128 suites. `make coverage-unit` reports 38.3% line coverage
(13,364/34,897), 39.99% function coverage (1,740/4,351), and 40.22% region
coverage (5,329/13,248); the new registration-state branches are covered by
the targeted unit suite.

Live macOS validation stages the signed debug runtime outside protected source
directories, starts it with two distinct temporary app roots, and confirms:

1. both `container system start` commands exit successfully;
2. `container system status --format json` reports the second root; and
3. `launchctl print` reports second-root plists for the API server, machine
   API, images, and default vmnet helper.

## Docker Compose V2 parity status

This patch has no Compose schema or YAML translation surface: it fixes the
generic macOS runtime that Compose invokes. The Phase 2 Compose V2 networking
parity suite remains the integration gate; it is rerun from the source-matched
installation after this runtime fix lands.

## Compatibility and risks

- The comparison is by canonical plist path, so an already-running service in
  the same installation is not restarted.
- A same-label helper from a different installation is intentionally replaced;
  that is the only safe behavior because its environment and data root are not
  compatible with the caller.
- The change affects only launchd-managed services on macOS.

## Review checklist

- [ ] Confirm the source package is run from an installed, non-protected path.
- [ ] Start two application roots sequentially and confirm all four service
  plists point to the second root.
- [ ] Confirm a repeated start for one root reuses its services.
- [ ] Confirm the Phase 2 Docker Compose V2 parity suite is green.

## Commit tracking

- `container` code and tests: `7272c401bc134f67f64f50da5b6b5db922ebc6f7`
  (`fix(launchd): reconcile stale service ownership`, signed and verified).
- `container` issue/PR handoff completion: this documentation commit.
