# Pull request handoff: add the Engine-owned shared Linux sandbox runtime

## Summary

- Add a production `container-runtime-linux shared-sandbox` helper backed by
  Containerization's multi-workload `LinuxPod`.
- Add exact typed XPC requests, receipts, and observations for sandbox and
  workload-start/workload-stop operations.
- Add a generation-fenced XPC/FD route for authority-owned protected service
  connections over the shared VM's vsock device.
- Materialize sealed workload bundles into the shared VM with independent
  namespace, resource, mount, socket, network, process, and logging settings.

## Type of change

- [x] Generic runtime API
- [x] Production helper and XPC transport
- [x] Crash-recovery and lifecycle behavior
- [x] Workload materialization adapter
- [x] Unit tests
- [ ] Docker or Compose parsing
- [ ] Engine REST or socket API
- [ ] API-service cutover from per-container VMs

## Runtime contract

`EngineLinuxSandboxRuntimeServiceV1` owns one `LinuxPod` and checks its typed
snapshot before every operation. A matching in-flight request shares the same
task; a conflicting request fails. A running sandbox or workload is returned
only when the service retains an exact matching receipt. Any state whose
effect cannot be attributed is reported as unknown or rejected, never inferred
as success.

The workload request binds the durable operation context to a canonical sealed
bundle root, a digest of its runtime configuration, dynamic environment, and
resolved network endpoints. The helper reads and hashes one
`RuntimeConfiguration` value, checks the digest and container identity,
activates the sealed logging plan, and maps that same configuration into
`LinuxPod.ContainerConfiguration`. It returns a process receipt only after the
Containerization snapshot reports the workload running with an init PID.

Sandbox boot/shutdown cannot race workload materialization. Successful
shutdown closes retained log captures and clears resident receipts. Stopped
workloads can be removed and rematerialized under a later exact process
generation; running or prepared workloads with a mismatched intent are fenced.
Protected service dials name the exact sandbox ID/generation, workload
ID/process generation, and port; the helper checks both live snapshots and
retained receipts before transferring only the connected file descriptor.
Shutdown cannot overlap an in-flight dial. A stale authority therefore cannot
reconnect a journald, logging-plugin, volume, or API service after sandbox or
workload replacement.

Workloads may opt into terminal monitoring. Exit immediately withdraws the
retained running receipt, exact durable authority state is reclaimed, and a
later process generation can rematerialize the workload. The production
journald service exercises this route with a pinned OCI workload, persistent
journal storage, readiness probing, and reconnecting Swift/Go transport.

Authority-requested reclamation uses a separate exact stop operation. The
request binds sandbox generation, workload process generation, operation
generation, idempotency key, and digest. The helper coalesces identical calls,
rejects conflicts, retains a terminal receipt, and exposes stop observation so
the macOS authority can recover a lost XPC response without stopping a newer
workload generation.

## Code map

- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxRuntimeConfiguration.swift`
  contains the private durable launch configuration.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxRuntimeClient.swift`
  contains the typed XPC client and wire helpers.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxServiceRuntime.swift`
  contains the generic protected-service dial identity and runtime boundary.
- `Sources/Services/Runtime/RuntimeClient/EngineLinuxSandboxWorkloadRuntime.swift`
  binds a sealed workload intent to `WorkloadProcessStarterV1`.
- `Sources/Services/RuntimeLinux/Server/EngineLinuxSandboxRuntimeService.swift`
  contains authoritative lifecycle, reconciliation, coalescing, and handlers.
- `Sources/Services/RuntimeLinux/Server/EngineLinuxSandboxWorkloadMapper.swift`
  maps sealed Container configuration to the shared workload API.
- `Sources/Plugins/RuntimeLinux/RuntimeLinuxHelper+SharedSandbox.swift` contains
  the production helper command and XPC servers.
- `Tests/ContainerRuntimeLinuxServerTests/EngineLinuxSandboxRuntimeServiceTests.swift`
  covers exact lifecycle, unattributed state, materialization, and wire models.

## Dependency handoff

This change compiles against the local signed Containerization commits:

- `8465b1fdafef6c88d44ae1daabdba31639f96894` — expose workload observations;
- `864455bf1a104f0215b7c912a45800b0a0538973` — observation handoff docs.

The repository pin must remain unchanged until the complete programme is ready
for coordinated Apple upstream publication. The manifest now uses
`CONTAINERIZATION_SOURCE` and `CONTAINERIZATION_REF` for both the selected
remote dependency and compiled provenance. `CONTAINERIZATION_PACKAGE_PATH` and
`CONTAINER_ENGINE_API_PACKAGE_PATH` select identity-preserving local packages
without creating SwiftPM editable-dependency metadata. With no overrides, the
same public Containerization revision and Engine API 0.3.5 remain selected.

## Deliberate boundaries

- Network/IPAM controllers allocate and persist leases, then supply only
  resolved endpoint plans.
- Volume, logging-provider, security, model-routing, and Engine-socket effects
  remain specialized transaction controllers.
- GPU workloads are rejected until the shared sandbox launch configuration can
  provide a real graphics device; the mapper does not silently accept them.
- General `ContainersService` cutover and the remaining specialized effect
  controllers remain integration work. Journald service packaging and its
  provider-specific bounded protocol are now implemented; other protected
  service domains retain their own separate work packages.

No Apple issue, branch, pull request, or push has been created. This handoff is
held locally until all parity development is complete.

## Commit tracking

- `ec95450741789341870aca07d24eaa460b83b44c` — signed shared-sandbox runtime
  materialization implementation and tests.
- `203c88b4d71d25a3ef6036035c54ca8b65f4923c` — signed API-service authority,
  ready-state recovery, and workload integrity follow-up.
- `2d7512c54cfe2fc01d506e08c0300d6f432fd437` — signed enhanced Engine
  logging-authority adapter and exact active-read wire follow-up.
- `20071d97d10b386c2a24c84c51bca0e37c0280aa` — signed, generation-fenced
  protected-service vsock/XPC transport and authority composition.
- `84d160671f3ba6c265a02b49b2ff4309f6584d30` — signed exact workload service
  routing, terminal monitoring/reclamation, and production journald workload
  supervision.
- `6e462443dd744bda0b605bf26e093833d7818e77` — signed exact workload-stop
  request/observation routes, response-loss reconciliation, and isolated
  provider-generation reclamation.

## Validation

```console
swift build --target container-runtime-linux
swift test --filter EngineLinuxSandboxRuntimeServiceTests
swift test --filter engineLinuxSandboxConfigurationReadWrite
CONTAINERIZATION_PACKAGE_PATH=/path/to/containerization \
  CONTAINER_ENGINE_API_PACKAGE_PATH=/path/to/container-engine-api \
  CONTAINERIZATION_SOURCE=owner/containerization \
  CONTAINERIZATION_REF=<signed-revision> \
  swift test --filter EngineLinuxSandboxRuntimeServiceTests
make check
make test
git diff --check
```

Current results on the development MacBook Pro:

- shared helper target builds successfully;
- focused runtime suite: 7 tests in 1 suite passed;
- combined protected-service runtime and API-authority run: 8 tests in 2
  suites passed;
- current exact-routing/terminal-recovery runtime and authority filter: 14
  tests passed; the same runtime filter passed under Thread Sanitizer without
  a race report;
- current provider-cutover/runtime filter: 63 tests in 9 suites passed;
- focused durable-configuration test passed;
- `make check` passed;
- the full unit run compiled and exercised 1,789 tests in 206 suites with no
  product-test failure; its two release-provenance assertions exposed a local
  mirror basename that changed the resolved identity;
- the corrected identity-preserving mirror passed all 3 release-provenance
  tests, completing the unit evidence without another redundant full run;
- no SDK or dependency installation was required.
- default manifest inspection selects Containerization `77f06d4c` and Engine
  API 0.3.5; the local-worktree graph selects signed Containerization
  `38d9c695` and Engine API `5e52a0f4` without `swift package edit`, and the
  focused Engine attach-state test passes under warnings-as-errors.

## Review checklist

- [x] Production state is observed before receipt decisions.
- [x] Exact retries do not repeat confirmed work.
- [x] Conflicting operations cannot overlap.
- [x] Workload identity is bound to a sealed canonical bundle.
- [x] Process receipt commits only after a running PID observation.
- [x] Unattributed and unsupported state fails closed.
- [x] The XPC/runtime boundary contains no Docker-specific policy.
- [x] Protected service connections are bound to the exact live sandbox
  and workload generations and cannot overlap shutdown.
- [x] Monitored terminal workloads withdraw stale receipts and can be reclaimed
  and rematerialized under an exact later process generation.
- [x] Authority-requested stop targets only the exact active workload process
  generation and is replay-safe after response loss.
- [x] Full macOS formatting, license, and unit behavior is green.
- [x] Implementation commit is signed.
