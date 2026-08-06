<!-- markdownlint-disable MD013 -->

# Pull request handoff: return canonical Docker container IDs

## Summary

- Persist Docker-specific immutable ID and requested-name fields without
  changing the native Container resource identity.
- Return the canonical 64-character lowercase-hex ID from Docker create and
  resolve requested name, full ID, and unique short ID on public lifecycle and
  log routes.
- Project the canonical identity in Docker list/inspect output, filters, and
  ordering.
- Use one shared identity projection for GELF and Docker logging plug-in
  inputs, preventing native resource identity leakage.

## Scope

This is a narrow Docker Engine identity compatibility fix in Container. It
does not add Docker event, rename, exec, object-migration, image, volume, or
network semantics. It does not alter native Container resource IDs, and it
does not claim full Docker route or programme-wide performance parity.

## Implementation

`ContainerConfiguration` now stores optional `dockerID` and `dockerName`
fields. Native Container-created objects retain `nil` values and preserve their
existing behavior. Docker creation keeps the native ID for lower runtime
authority but mints a separate, durable 256-bit canonical Docker ID and
records the requested Docker name.

`ContainersService` resolves exact names, complete Docker IDs, and unique ID
prefixes to the native resource ID. The Docker logging backend uses that
resolver for lifecycle, attach, resize, and log operations while retaining the
original supplied identifier in external error messages. Docker shared
responses use Docker identity/name for list, inspect, filters, and sorting.

`AuthorityRemoteLogDriverPlane.dockerLogInfo` centralizes logging identity
projection. Both GELF and Docker plug-in configuration use it, so wire metadata
and plug-in inputs use the same canonical ID/name as public Docker routes.

## Docker oracle and validation

Pinned reference: Docker Engine `29.2.1` / API `1.53` and Docker CLI `29.7.1`
on the programme MBP.

- `ContainerLogsTests.dockerContainerIdentityUsesCanonicalIDAndNameAliases`
  passes on the exact local Containerization `38d9c695` and Engine API graph.
- `AuthorityRemoteLogDriverPlaneTests.dockerLogInfoUsesCanonicalDockerIdentityWhenAvailable`
  passes on the same graph.
- A fresh Docker reference returns a canonical 64-character ID in
  `0.700619291s`.
- Two fresh code-signed public candidates pass the same Docker CLI fixture in
  `1.591354583s` and `1.574481541s`. The fixture covers create, name/full/short
  inspect aliases, start, stop, delete, logs, GELF identity, and exact cleanup.
- `/private/tmp/container-create-id-candidate-v2.9lSjrX` is marker-protected
  and retains the complete preflight, archive-verification, final fingerprint,
  Docker reference, candidate result, and cleanup evidence.
- The focused candidates are 2.27x/2.25x Docker. They pass the retained 10x
  functional guard but leave comparable-or-better release performance open.

## Review checklist

- [x] Canonical Docker IDs and requested names are durable and separate from
  native resource IDs.
- [x] Name, full ID, and unique short ID resolve to one public Docker object.
- [x] List/inspect/logging-driver projections use the canonical identity.
- [x] Focused source regressions and two exact public Docker CLI candidates
  pass with retained cleanup evidence.
- [x] The signed source implementation is
  `9d2257a81176a895a31388124bd6a7b0b74d10e6`.
- [ ] The matching Compose evidence/docs checkpoint and owned issue closure
  remain required for a complete cross-repository verification claim.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created.
Do not publish this handoff until all parity development waves are complete and
the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-docker-create-id-identity.md`.

<!-- markdownlint-enable MD013 -->
