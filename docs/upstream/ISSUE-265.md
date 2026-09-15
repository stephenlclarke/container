# Pin a published exact Containerization VM-init authority

## Problem

A fresh enhanced Container installation derives its default VM-init image from
the pinned `stephenlclarke/containerization` source revision. The current
revision has no image in that namespace, so an isolated `container system
start` fails with a registry `404`. Retained release-gate archives and ambient
user configuration can mask the missing immutable runtime dependency.

## Required behavior

- Pin Container and `Package.resolved` to the merged Containerization revision
  that publishes its exact VM-init image.
- Resolve the compiled default image anonymously from GHCR before accepting the
  pin.
- Boot and stop a clean runtime with no inherited user configuration or cached
  application assets.
- Preserve the immutable builder-image authority and stock Apple behavior.
- Report exact Container and Containerization source identities throughout the
  runtime and release evidence.

## Acceptance evidence

- [x] The exact source-revision image resolves anonymously from GHCR at digest
      `sha256:37d083fbd28eabb01da0e3ad009f7c6829d60808fb23baa38c4ac9dffc35663b`.
- [x] Package manifest and lockfile contain the same full revision.
- [x] Repository build, all 2,501 package tests, formatting, licensing, and
      auxiliary test harnesses pass.
- [x] A clean isolated runtime starts, reports healthy, runs an Alpine command
      with the exact published VM-init authority, and stops. The candidate was
      Developer-ID signed with the production virtualization entitlement and
      used a marker-owned application root with no inherited configuration.
- [x] The downstream Compose Current release consumes the same immutable
      authority through the later protected-main Container revision
      `ef78345f59fdb913b3abce6ac0445616955c4e55`.
- [ ] A fresh Docker-less devcontainer parity lane produces complete evidence
      against that authority. The 15 September run failed while locating lane
      `results.json` artifacts and is not runtime certification.

## Closure status

Pull request 266 merged on 13 September 2026 as
`14257435e40367d60ac3904f4f67ca35d1c29fe5`. The downstream matched Current
package was published successfully by
[`container-compose` run 34968418462](https://github.com/stephenlclarke/container-compose/actions/runs/34968418462).
The Container issue is closed; the explicitly separate devcontainer evidence
gap remains tracked in that repository's parity documentation.

## Tracking

- Issue: <https://github.com/stephenlclarke/container/issues/265>
- Publisher: <https://github.com/stephenlclarke/containerization/pull/96>
- Pull request: <https://github.com/stephenlclarke/container/pull/266>
