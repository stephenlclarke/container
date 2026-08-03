# Feature request: add a Docker-compatible Google Cloud Logs provider

## Feature or enhancement request details

The macOS container runtime has an authority-owned remote logging plane, but it
did not provide Docker's `gcplogs` driver. A valid Compose request therefore
survived normalization and persistence but could not start a workload using
Google Cloud Logging.

Add a native provider pinned to the Moby 29.2.1 contract. The API authority
must own Application Default Credentials, Google Cloud Logging connections,
asynchronous publication, and the existing generation-fenced provider
lifecycle.

Expected behavior:

- Resolve `gcp-project` over compute metadata and reject a start when neither
  source supplies a project.
- Use the official Google Cloud Logging client and Application Default
  Credentials, including file, metadata, workforce, and external-account
  credential chains available in the authority environment.
- Publish through the `gcplogs-docker-driver` logger, verify connectivity with
  `Ping`, and use a `gce_instance` monitored resource when compute or explicit
  `gcp-meta-zone`, `gcp-meta-name`, or `gcp-meta-id` metadata is present.
- Preserve Docker's container JSON payload, timestamps, binary-to-string line
  conversion, optional `gcp-log-cmd`, and exact label/environment selection.
- Preserve the official client's asynchronous delivery, `ErrOverflow` count
  reporting, flush, and close behavior.
- Preserve exact provider identity, idempotency, effect-token, generation,
  fencing, close, and recovery contracts.
- Keep native reads unavailable unless the existing Docker-compatible dual
  cache is explicitly configured.

## Scope and non-goals

This is a generic macOS-hosted Google Cloud Logging provider. It does not add
Compose YAML, a Docker socket or REST API, a Google service emulator, or a
native Google Cloud Logging reader. Journald, production plugin hosting, and
Engine/gateway integration remain separate slices.

## Upstream publication

The implementation is retained on the local
`upstream/logging-driver-parity` branch. No Apple issue or pull request should
be published until the complete logging/parity programme is ready for its
coordinated upstream handoff.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
