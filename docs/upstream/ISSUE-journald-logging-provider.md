# Feature request: add a Docker-compatible journald logging provider

## Feature or enhancement request details

The macOS container runtime has an authority-owned logging plane, but it does
not yet provide Docker's `journald` driver. A valid Compose request can
therefore be normalized and persisted without a production Linux service able
to publish it to, or read it from, the system journal.

Add a native provider pinned to the Moby 29.2.1 journald contract. The API
authority must own configuration and provider selection, while a signed,
generation-fenced Linux service owns journal publication, persistence, and
queries.

Expected behavior:

- Accept Docker's `env`, `env-regex`, `labels`, `labels-regex`, `tag`, `mode`,
  and `max-buffer-size` options with Docker template and RE2 behavior.
- Emit Moby-compatible container, image, tag, syslog, priority, timestamp,
  partial-message, epoch, ordinal, and sanitized attribute fields.
- Preserve binary-safe messages and Docker's stdout/stderr priorities.
- Provide native `logs` reads with stdout/stderr, follow, tail, since, until,
  timestamps, and details filtering against journal receipt order.
- Make writer and reader opens idempotent and bind every operation to the
  container lease, provider generation, process generation, sandbox
  generation, and protected effect token.
- Fence stale writers before a replacement workload can publish under the same
  container identity and reconcile response loss without duplicating epochs or
  reader streams.
- Advertise `journald` only while the concrete signed Linux service is
  available and its active sandbox generation can be authenticated.

## Current local implementation boundary

The provider contract, exact Moby field/configuration codec, lifecycle fencing,
native-reader boundary, optional catalog registration, authority configuration,
and focused tests are implemented locally. The provider is intentionally not
advertised by the production API server because the protected Linux workload,
system-journal persistence/query adapter, supervision, and recovery path remain
to be implemented.

## Scope and non-goals

This change does not add Compose parsing, the public Docker REST/socket
gateway, or Docker logging-plugin hosting. It does not claim journald support
until the production service and external-client evidence are complete.

## Upstream publication

The implementation is retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete parity programme is ready for its coordinated
upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
