# Feature request: add a Docker-compatible Splunk HEC logging provider

## Feature or enhancement request details

The macOS container runtime has an authority-owned remote logging plane for
Docker-compatible logging drivers, but it did not provide the `splunk` driver.
Higher-level clients could preserve a Splunk logging request in configuration,
but container start failed because no built-in provider owned the HTTP Event
Collector connection or its protected token.

Add a generic native Splunk HEC provider whose behavior is pinned to Moby
29.2.1. The provider should keep the token inside the API authority, expose no
secret in persisted or diagnostic configuration, and preserve the existing
generation-fenced provider lifecycle.

Expected behavior:

- Require `splunk-url` and a non-empty protected `splunk-token` at start.
- Accept only HTTP or HTTPS base URLs without credentials, query, fragment, or
  a non-root path, then send to `/services/collector/event/1.0`.
- Implement Moby's `inline`, `json`, and `raw` event formats, default short-ID
  tag, label/environment metadata selection, optional gzip, connection
  verification, index acknowledgement, source, sourcetype, and index fields.
- Batch 1,000 events or five seconds, retain failed batches for retry, bound the
  pending buffer at 10,000 events, and discard a failed final close attempt as
  Moby does.
- Honor HTTP proxy environment variables and the Splunk TLS CA path, server
  name, and insecure-verification controls.
- Preserve exact provider identity, idempotency, effect-token, generation,
  fencing, close, and recovery contracts.
- Keep native reads unavailable unless the existing Docker-compatible dual
  cache is explicitly configured.

## Scope and non-goals

This is a generic macOS-hosted logging provider. It does not add Compose YAML,
a Docker socket, Docker REST API emulation, a Splunk server, or a native Splunk
log reader. AWS CloudWatch Logs, Google Cloud Logging, and journald remain
separate provider slices.

## Upstream publication

The implementation is being retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete logging/parity programme is ready for its
coordinated upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
