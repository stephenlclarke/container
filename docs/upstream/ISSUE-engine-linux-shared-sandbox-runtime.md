# Runtime gap: production Engine-owned shared Linux sandbox

## Problem

The durable sandbox/workload ledger and workload-plan resolver can persist and
order exact operations, but the production Linux runtime still launches one VM
per container. The authority therefore has no common sandbox in which to
materialize independently isolated workloads, and its lost-response receipts
cannot be reconciled against production runtime state.

Without a shared runtime boundary:

- a durable sandbox generation does not identify a real VM;
- an exact process-start receipt cannot be attributed to a Linux workload;
- a retry can add or start the same workload twice after losing an XPC reply;
- logging capture, mounts, namespaces, resources, devices, and resolved network
  endpoints can diverge from the sealed workload bundle;
- higher-level controllers cannot safely replace the legacy per-container VM
  path.

## Required runtime behavior

- Launch one Engine-owned Linux sandbox helper from a bounded, private,
  durable configuration.
- Expose typed XPC operations for exact sandbox boot, boot observation,
  shutdown, shutdown observation, workload start, and workload-start
  observation.
- Consult authoritative Containerization snapshots before every decision.
- Coalesce identical in-flight operations and reject conflicting operations.
- Fence running or prepared state that has no matching request and receipt.
- Read the sealed workload bundle at materialization time rather than accepting
  a divergent copy of its configuration over XPC.
- Map workload process, namespace, cgroup/resource, mount, socket, DNS/hosts,
  capability, device, stdio, and logging-capture configuration to `LinuxPod`.
- Accept only resolved network endpoint plans; allocation and lease ownership
  remain higher-level transactional effects.
- Return the exact durable process-generation tuple only after the workload is
  observed running with an init process.
- Reject unsupported sandbox-wide capabilities instead of reporting false
  workload success.

## Apple-shaped boundary

This is generic Container runtime infrastructure. It contains no Docker or
Compose parsing, provider policy, REST route, compatibility fallback, network
allocation, volume-driver selection, or Engine socket protocol. The helper
materializes only an already sealed workload and already resolved endpoint
plan.

The implementation depends on the local Containerization shared-sandbox API
and observation handoff. It is retained locally for later Apple upstream
submission and must not be published until the complete parity programme is
ready.

## Acceptance evidence

- [x] Shared helper has a production launch command and anonymous XPC service.
- [x] Launch configuration is validated, atomically written, and mode `0600`.
- [x] Exact sandbox boot/shutdown calls are idempotent and observable.
- [x] Exact workload materialization/start is idempotent and observable.
- [x] Lost-response state is reconciled from typed Containerization snapshots.
- [x] Conflicting and unattributed operations fail closed.
- [x] Sealed bundle identity and canonical root path are validated.
- [x] Materialization is bound to the exact runtime-configuration digest and
  rejects post-reservation mutation.
- [x] Workload configuration maps to the independent `LinuxPod` surface.
- [x] Focused runtime and wire-format tests pass.
- [x] The full macOS unit corpus passes under warnings-as-errors; the release
  provenance suite also passes with an identity-preserving local mirror.

## Follow-on integration

The API-service authority now launches and supervises the shared helper, opens
the durable ledger, reconciles the sandbox manager, and routes a workload
start through the common resolver. Production `ContainersService` traffic
still awaits specialized controllers, scoped workload lifecycle routes, guest
network/IPAM semantics, and controlled migration. See
`ISSUE-engine-linux-sandbox-api-authority.md`.

The enhanced Engine logging provider follow-up is retained at signed commit
`2d7512c54cfe2fc01d506e08c0300d6f432fd437`. It uses the existing authority
and exact active logging generation without claiming shared-sandbox lifecycle
cutover.
