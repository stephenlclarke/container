<!-- markdownlint-disable MD013 -->

# Pull request handoff: preserve Docker Fluentd TLS trust-failure diagnostics

## Summary

- Map BoringSSL's certificate-chain verification failure to `FluentdProviderError.tlsTrustVerificationFailed` without changing unrelated TLS or transport errors.
- Project Docker's exact Fluentd TLS trust-failure message through `ContainerDockerLoggingBackend` instead of returning the generic logging-operation error.
- Add focused transport and Docker-backend regressions for the newly observable public contract.
- Retain the remaining receiver-alert mismatch as an explicit incomplete acceptance row rather than treating the source fix as parity completion.

## Scope

This is a narrow Container Docker logging compatibility change. It does not alter Fluentd address parsing, retry policy, host trust configuration, trusted TLS delivery, custom CA handling, Compose projection, guest images, Containerization, or Engine API revisions.

## Implementation

`FluentdTLSHandshakeObserver` routes NIOSSL errors through `FluentdTLSHandshakeErrorMapper`. The mapper recognizes only an `NIOSSLError.handshakeFailed(.sslError(...))` stack containing BoringSSL's public `CERTIFICATE_VERIFY_FAILED` signal. It returns the typed provider error for that trust failure and leaves every other error unchanged.

`ContainerDockerLoggingBackend` maps the typed error to Docker's stable `failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority` diagnostic. The existing rejected-start authority flow records that message while preserving the container's Docker-visible `created` state.

## Docker oracle and validation

Pinned reference: Docker Engine 29.2.1 / API 1.53 with Docker CLI 29.7.1 on the programme MBP.

- `FluentdNIOTransportLoopbackTests` passes 13 focused transport cases using the matched local Containerization and Engine API dependency overrides.
- `ContainerLoggingStartErrorTests` passes 4 focused Docker diagnostic cases, including the Fluentd TLS trust mapping.
- Targeted `swift format lint --strict` passes for the four changed provider/test files. The pre-existing full-file formatter findings in `ContainerDockerLoggingBackend.swift` are outside this diff; the added mapping lines have no formatter finding, and `git diff --check` passes.
- Docker reference evidence is retained at `/private/tmp/container-rest-fluentd-tls.docker.m7QDss`; it reports `created`, HTTP 500, Docker's exact diagnostic, and `SSLV3_ALERT_BAD_CERTIFICATE`.
- Candidate evidence remains pending an immutable source checkpoint. The earlier candidate recorded the separate NIOSSL `SSLV3_ALERT_CERTIFICATE_UNKNOWN` mismatch and cannot be used as passing evidence.

## Review checklist

- [x] Only native certificate-chain verification failures are normalized.
- [x] The Docker backend produces Docker's exact Fluentd TLS trust diagnostic.
- [x] Trusted DNS/IP TLS and the existing identity-negative behavior remain covered by the transport suite.
- [ ] Fresh source fingerprint, binary, guest archive, fixture, and two public Docker CLI candidates are retained.
- [ ] Receiver alert matches Docker's `bad_certificate` alert without changing trust policy.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises coordinated Apple upstream publication.

Related issue handoff: `docs/upstream/ISSUE-fluentd-tls-trust-failure.md`.

<!-- markdownlint-enable MD013 -->
