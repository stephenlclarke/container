# Upstream sync: Apple system status output enhancement

## Context

Apple `container` advanced during the 0.14.0 release window with
[`apple/container#1769`](https://github.com/apple/container/pull/1769), which
closes [`apple/container#815`](https://github.com/apple/container/issues/815).
The change replaces the flat `container system status` payload with grouped
client, server, host, path, and resource information and corrects the API
server version field.

Tracking issue:
[`stephenlclarke/container#180`](https://github.com/stephenlclarke/container/issues/180).

## Required behavior

- Preserve Apple ancestry through `d925dab865cf69fa497ad38720f03f309546ce6a`.
- Adopt Apple's grouped JSON status schema and richer table output.
- Preserve the fork's Container Engine service status and socket fields.
- Preserve the fork's builder-shim repository, version, digest, and rendered
  image provenance.
- Keep daemon-backed container and image counts best-effort so status remains
  useful while individual resource queries are unavailable.
- Retain useful `unregistered`, `not running`, and `degraded` status payloads.

## Merge reconciliation

Apple and the fork both changed the status command and its integration tests.
The reconciliation keeps Apple's new payload types and collection behavior,
then carries the fork-only Engine and builder-shim fields into the grouped
server output. The API server version correction and Apple's new focused unit
suite are retained.

## Validation boundary

The focused `SystemStatusTests` suite passes all seven tests from the resolved
merge. It covers table rendering, JSON round-tripping, builder-shim and Engine
fields, optional paths, and best-effort image counts. The exact downstream
Compose pin and stable release gates remain required before 0.14.0 promotion.

## Commit tracking

- Apple issue: <https://github.com/apple/container/issues/815>
- Apple pull request: <https://github.com/apple/container/pull/1769>
- Apple upstream commit:
  `d925dab865cf69fa497ad38720f03f309546ce6a`
- Fork issue: <https://github.com/stephenlclarke/container/issues/180>
- Fork pull request: <https://github.com/stephenlclarke/container/pull/181>
