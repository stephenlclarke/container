# Pull request handoff: isolate Docker logging-plugin lifecycle

## Summary

- Add an isolated Linux/arm64 service that owns Docker plugin writer/reader
  claims, effect tokens, FIFOs, stream cursors, terminal state, and replay.
- Authenticate the complete Swift-to-Go lifecycle protocol with a protected
  per-provider-generation HMAC key.
- Discover and verify closed, digest-pinned installed plugin bundles before
  publishing their driver names.
- Materialize one read-only, resource-bounded OCI workload per approved
  provider generation inside the shared Engine Linux sandbox.
- Route writer delivery and direct `ReadLogs` sessions through the same
  generation-fenced Container logging authority.
- Preserve the existing in-process adapter as a conformance seam while making
  the durable service-owned facade the only production installation path.
- Discover, stage, readiness-probe, activate, retain, and roll back multiple
  immutable generations of one provider without publishing two generations.
- Recover the exact active/draining generation set from a protected durable
  registry after API-service restart without replaying provider effects.

## Type of change

- [x] Container logging provider plane
- [x] Engine Linux sandbox workload
- [x] Docker logging-plugin protocol
- [x] Durable writer and reader lifecycle
- [x] Direct provider read path
- [x] Security and resource isolation
- [x] Unit and Linux conformance tests
- [ ] Compose parser behavior
- [ ] Plugin distribution or approval UI

## Architecture

An installed logging plugin contributes a protected manifest and OCI archive.
APIServer discovery sorts logging plugins, verifies each closed manifest and
asset digest, permits distinct generations of one provider, rejects every
cross-provider registered-name, reserved-provider, exact-generation, and
service-port collision, and builds a lazy installation. Catalog readiness
probes the exact service generation; failed or stale workloads are not
advertised.

The provider registry persists immutable descriptors and staged, active, and
draining phases before changing its in-memory publication. The synchronous
commit inside the registry actor prevents another transition from interleaving
between fsync and publication. A healthy N+1 candidate becomes the sole
name/catalog selection while N remains available only by exact generation for
existing reconciliation and cleanup. A failed candidate is removed without
changing N; an unhealthy or missing active generation rolls back through the
newest retained healthy generation. Restart reconstructs the same phases from
a closed, bounded, mode-0600 state file and never calls `StartLogging` or
`ReadLogs` merely to recover registry state.

The materializer imports only the exact Linux/arm64 image-manifest digest. It
writes a mode-0600 runtime configuration for a read-only root filesystem with a
protected persistent service-state mount and private tmpfs mounts at `/run` and
`/tmp`. The plugin-owned entrypoint starts the plugin and lifecycle service in
one namespace, so the Unix socket never crosses into the macOS authority.

The Swift client connects over AF_VSOCK using a bounded persistent pool. Each
lane carries one request at a time. A lost response closes and reconnects that
lane, then replays the byte-identical authenticated operation once. Queued
cancellation removes the exact waiter immediately; active cancellation shuts
down the socket so a blocked read or FIFO write can unwind.

The Go service authenticates and validates every bounded request, stores
claims atomically before effects, and keeps an in-memory bounded response
ledger for same-process replay. Durable writer state prevents a second plugin
start after a service crash; durable reader state prevents a second read stream.
Unprovable outcomes remain explicitly uncertain for authority reconciliation.

Writer records carry monotonically increasing sequences and stable frame
digests. Replaying the same sequence and frame is a no-op; changing the bytes is
an idempotency conflict. FIFO writes are fully awaited without a per-record
fsync. Graceful close invokes `StopLogging` before removal, while a fence revokes
the FIFO before the best-effort plugin stop.

Direct readers call the optional Docker `ReadLogs` endpoint, retain a durable
sequence and last response, emit bounded protobuf frames, and return an explicit
EOF. Terminal writer and reader state is removed only through the authority's
generation-fenced reclaim request.

## Security properties

- The 32-byte authentication key is mode 0600 and absent from arguments,
  environment, manifests, diagnostics, and error bodies.
- Authentication is checked before state-store, plugin, FIFO, and listener
  bootstrap.
- Installed resources and service state reject symbolic links, permissive
  files, unsafe roots, oversized data, and malformed closed schemas.
- Plugin socket paths are restricted to `/run/docker/plugins/...`.
- The plugin workload has a read-only root, private writable runtime mounts,
  host networking only inside the existing Linux sandbox, fixed CPU/memory
  limits, and bounded file descriptors.
- Public wire failures are typed and do not relay plugin bodies, log records,
  protected options, keys, or private paths.

## Code map

- `DockerPluginLifecycleService.swift` defines the durable service facade and
  production provider boundary.
- `DockerPluginLifecycleServiceWire.swift` defines authentication, framing,
  pooling, replay, writer sessions, and reader streams.
- `DockerPluginProvider.swift` retains the low-level protocol adapter as a
  focused conformance seam.
- `EngineLinuxSandboxDockerPluginService.swift` verifies installed assets,
  materializes the workload, connects AF_VSOCK, and supervises readiness.
- `AuthorityRemoteLogDriverPlane.swift` binds exact Docker metadata/options and
  routes provider writers and readers through the lifecycle controller, probes
  the selected plugin generation, and recovers a retained healthy fallback.
- `LogDriverProviderRegistry.swift` owns durable staged/active/draining
  transitions, exact-generation routing, activation, and rollback.
- `DockerPluginInstallationCollisionRegistry.swift` permits same-provider
  generations while preserving discovery collision fences.
- `Tools/ContainerDockerPluginService` contains the Linux service, durable
  backend, Unix HTTP plugin client, FIFO implementation, and conformance tests.

## Validation

```console
swift test --filter 'DockerPlugin|dockerPluginDirectReader' \
  -Xswiftc -warnings-as-errors
swift test --skip TestCLI --skip IntegrationTests \
  --skip ReleaseVersionTests --skip rootHelpProvenanceShowsCustomBuild \
  --no-parallel -Xswiftc -warnings-as-errors
swift build --product container-apiserver -Xswiftc -warnings-as-errors
make check
git diff --check
```

From `Tools/ContainerDockerPluginService`:

<!-- markdownlint-disable MD013 -->
```console
go test -race -cover ./...
go vet ./...
docker run --rm --platform linux/arm64 \
  -v "$PWD:/src" -w /src \
  golang@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e \
  go test -race -cover ./...
```
<!-- markdownlint-enable MD013 -->

Current development MacBook Pro evidence after staged-generation activation:

- 35 focused Swift tests in registry, provider-set, discovery, and authority
  suites passed; the preceding isolated-service suite remains covered by the
  scoped package gate.
- The scoped package gate passed 1,861 Swift Testing tests in 216 suites and 94
  XCTest tests under warnings-as-errors.
- The APIServer product build passed under warnings-as-errors.
- macOS Go race and vet passed at 70.2% statement coverage.
- Pinned Linux/arm64 Go race passed at 74.1% statement coverage, including real
  FIFO, readable plugin, write-only plugin, cancellation, private-key/state,
  listener, and connection-HUP tests.
- `make check`, Markdown lint, and `git diff --check` passed.
- Signed implementation commit:
  `08677dc8b5a677533de80cf634fee1d14f4da069`.
- Signed staged-generation implementation commit:
  `70f976611bd5e39a9bfeb4965df7c073bbd789ad`.

The local SwiftPM mirror intentionally replaces the remote Containerization
package during development. SwiftPM therefore removes that remote pin from its
generated `Package.resolved` before tests. Two `ReleaseVersionTests` cases and
`rootHelpProvenanceShowsCustomBuild` are excluded from the scoped gate because
they inspect the missing remote pin; the committed lockfile is restored exactly
after validation. This is a local provenance-test/mirror incompatibility, not a
logging behavior failure.

## Review checklist

- [x] The Linux service, not a reconstructible macOS actor, owns protected
  writer and reader effects.
- [x] Lost responses replay one operation and cannot duplicate plugin effects.
- [x] Every lifecycle call is provider, generation, lease, session, and token
  fenced.
- [x] Readable and write-only plugin behavior is independently exercised.
- [x] Direct reads and live attachment remain separate authority paths.
- [x] Plugin bodies, protected options, keys, and records stay out of failures.
- [x] Workloads are digest-pinned, read-only, bounded, and privately mounted.
- [x] Stage multiple provider generations, publish one active generation,
  retain exact draining-generation routing, roll back failed/unhealthy
  candidates, and recover the durable phase set after restart.
- [ ] Quiesce new N claims, migrate/revalidate every durable N configuration
  and history reference, and prove all N sessions/cleanup effects terminal
  before alias cutover and final generation reclamation.
- [ ] Certify a distributable third-party plugin through the complete stack.
- [ ] Complete paired Docker behavior/performance and release evidence.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. The
commit remains local on `upstream/logging-driver-parity` until every parity
development wave is complete and the matched Containerization dependency can
be published coherently.

## Owned issue tracking

- [container#47](https://github.com/stephenlclarke/container/issues/47) is
  closed with queued-cancellation regression coverage.
- [container#48](https://github.com/stephenlclarke/container/issues/48) is
  closed with private runtime-mount regression coverage.
- [container#49](https://github.com/stephenlclarke/container/issues/49) is
  closed with durable multi-generation activation and rollback coverage.
