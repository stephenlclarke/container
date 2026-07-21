# Stale launchd service labels can bind a new Container installation to an old owner

## Problem

Container uses stable `launchd` labels for the API server, machine API server,
image helper, and default vmnet helper. Before the fix, registration treated a
matching label as sufficient evidence that the requested service was already
running. Starting a second installation or an isolated test runtime therefore
could reuse a helper whose plist belongs to the first application root. The new
client then waits for an XPC service that has the wrong executable, environment,
and data root.

## Reproduction on macOS

1. Build and install a signed debug runtime outside a protected source tree.
2. Start it with a temporary application root A.
3. Start the same binary with a different temporary application root B.
4. Observe that the prior implementation reused the A-owned registrations
   solely because their labels existed; the B start could wait indefinitely.

This is macOS `launchd` behavior. It has no Linux guest or Windows equivalent.

## Expected behavior

- Reuse a registered label only when `launchctl print` reports the canonical
  plist path requested by the current installation.
- For the same label with a different owner plist, boot out only that service
  and bootstrap the requested plist.
- Keep repeated starts from one application root idempotent.
- Centralize the decision in `ServiceManager` so the API server and plugin
  helpers cannot drift into different registration rules.

## Scope and Apple-shaped boundary

The correction belongs in Apple Container's existing macOS service-management
abstraction. It neither adds a Compose-specific API nor alters Linux OCI guest
semantics. `SystemStart` and `PluginLoader` continue to construct their normal
`LaunchPlist` values and delegate ownership reconciliation to `ServiceManager`.

## Proposed resolution

Apply the signed runtime commit
`7272c401bc134f67f64f50da5b6b5db922ebc6f7`
(`fix(launchd): reconcile stale service ownership`). The accompanying pull
request handoff is
[PR-launchd-service-ownership.md](PR-launchd-service-ownership.md).

## Validation

- `swift test --filter ContainerPluginTests`
- `make test SWIFT_TEST_FLAGS=--no-parallel`
- `make coverage-unit SWIFT_TEST_FLAGS=--no-parallel`
- Start two different temporary `--app-root` installations sequentially and
  confirm that all four services are owned by the second root.
- Run the source-matched Container Compose V2 parity suite after the runtime
  update; Compose is the downstream consumer but requires no schema change.
