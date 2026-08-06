<!-- markdownlint-disable MD013 -->

# Runtime gap: canonical Docker container create identity

## Problem

Docker Engine returns an immutable 64-character lowercase-hex container ID from
`docker container create`, separately from the requested name. The Container
Docker-compatible route previously returned the native resource identifier,
which is usually the requested name. That leaked the mutable/name-shaped native
identity into `create`, list, inspect, logging metadata, and Docker plug-in
configuration.

The first public-candidate run of the local correction also showed that routing
alone was insufficient: GELF records still received the native resource ID and
name. Docker-facing identity must be durable and shared by the route projection
and every logging-driver input.

## Required behavior

- Generate and persist a canonical immutable Docker ID that is distinct from
  the native Container resource ID.
- Preserve the requested Docker name separately from that canonical ID.
- Resolve a requested name, full ID, and unique short ID to the same Docker
  object for inspect, start, stop, delete, and logs.
- Project the canonical ID and requested name in Docker list/inspect responses,
  filters, sorting, GELF metadata, and Docker logging plug-in start input.
- Preserve native resource IDs for native Container callers and do not change
  their durable object identity.

## Acceptance evidence

- [x] `ContainerLogsTests.dockerContainerIdentityUsesCanonicalIDAndNameAliases`
  covers persistence, full/short/name resolution, list/inspect projection, and
  ID shape.
- [x] `AuthorityRemoteLogDriverPlaneTests.dockerLogInfoUsesCanonicalDockerIdentityWhenAvailable`
  covers the shared GELF/Docker plug-in identity projection.
- [x] Docker Engine `29.2.1` / API `1.53` with Docker CLI `29.7.1` provides
  the same-MBP create-ID oracle.
- [x] Two fresh public-socket candidates pass the retained Docker CLI fixture
  from one exact local source/dependency/archive/guest/root fingerprint.
- [x] The source implementation is retained in signed commit
  `9d2257a81176a895a31388124bd6a7b0b74d10e6`.
- [x] The matched Compose documentation and harness checkpoint is signed as
  `f79284097edc6729109ebda658dac25403384740`.

## Local evidence

The focused source command was:

```sh
env CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox \
  CONTAINERIZATION_REF=38d9c695 \
  CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api \
  swift test --filter 'ContainerLogsTests.dockerContainerIdentityUsesCanonicalIDAndNameAliases|AuthorityRemoteLogDriverPlaneTests.dockerLogInfoUsesCanonicalDockerIdentityWhenAvailable'
```

It passed with the exact local dependency graph. The marker-protected candidate
root `/private/tmp/container-create-id-candidate-v2.9lSjrX` retains the source
diff fingerprint, signed archive and binary hashes, guest images, wrapper,
Docker reference, two public-candidate results, and cleanup proof. Docker's
reference took `0.700619291s`; candidates took `1.591354583s` and
`1.574481541s` (2.27x and 2.25x). They satisfy the focused 10x functional
guard, but do not establish the programme's comparable-or-better release
performance requirement.

The Stephen-owned tracking issue
[`stephenlclarke/container#74`](https://github.com/stephenlclarke/container/issues/74)
was commented with the exact evidence and closed as completed after the final
signed cross-repository checkpoint. It remains separate from this Apple-shaped
handoff.

## Apple-shaped boundary

The implementation is retained locally on `upstream/logging-driver-parity`.
No Apple issue, pull request, branch publication, or push has been created.
Do not publish this handoff until every parity development wave is complete and
the user explicitly authorises coordinated upstream publication.

Related pull-request handoff: `docs/upstream/PR-docker-create-id-identity.md`.

<!-- markdownlint-enable MD013 -->
