<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker Fluentd TLS trust-failure diagnostic and alert

## Problem

Docker Engine accepts a cache-disabled Fluentd `tls://host.docker.internal:PORT` configuration at create and rejects `docker start` when the bounded receiver presents an untrusted self-signed certificate. It reports `failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority`, retains the Docker-visible `created` state, and the receiver observes a TLS `bad_certificate` alert.

Container reached the same create/start phase and retained `created`, but collapsed NIOSSL's certificate-verification error into `container logging operation failed`. Its BoringSSL client also sent `certificate_unknown` rather than Docker's `bad_certificate` alert. The diagnostic and wire-alert gaps are independently observable through the public Docker CLI path.

## Required behavior

- Normalize only BoringSSL's certificate-chain verification failure to a typed Fluentd provider error; preserve transport, protocol, timeout, and post-handshake identity errors.
- Project the exact Docker Fluentd TLS trust diagnostic through the Docker logging backend and durable rejected-start state.
- Retain Docker's create acceptance, start rejection phase, `created` state, requested Fluentd configuration, and cleanup behavior.
- Match Docker's receiver-observed TLS alert without weakening certificate validation or changing host trust stores.

## Acceptance evidence

- [x] `FluentdNIOTransportLoopbackTests.tlsVerifiesDNSAndIPSANAndRejectsTrustAndIdentityFailures` proves the actual NIOSSL `CERTIFICATE_VERIFY_FAILED` path maps to `FluentdProviderError.tlsTrustVerificationFailed` while trusted DNS/IP cases remain valid.
- [x] `FluentdNIOTransportLoopbackTests.tlsTrustErrorMapperPreservesNonTrustFailures` proves an unrelated provider error is not reclassified.
- [x] `ContainerLoggingStartErrorTests.mapsFluentdTLSTrustFailureToDockerDiagnostic` proves the Docker backend emits Docker's exact trust-failure diagnostic.
- [x] Same-MBP Docker CLI 29.7.1 / Engine 29.2.1 / API 1.53 reference retained under `/private/tmp/container-rest-fluentd-tls.docker.m7QDss` reports HTTP 500, `created`, and `SSLV3_ALERT_BAD_CERTIFICATE`.
- [ ] Two fresh exact-fingerprint Container candidates prove the full create/start/inspect/alert/cleanup contract.
- [ ] Resolve the receiver-observed `certificate_unknown` versus Docker `bad_certificate` alert mismatch, likely at the NIOSSL/BoringSSL verification callback boundary.

## Local evidence

The first candidate, built from signed Container `359e14e4f991db0f3729d44651b9f82d9ab1b0ed` with Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API `f5d0d120bb139675e96a4ef9f7b0ac800827c295`, is retained under `/private/tmp/container-rest-fluentd-tls.candidate.qmcDLQ`. It proves the current gap: HTTP 500 and `created` are retained, but the public error is generic and the bounded receiver records `SSLV3_ALERT_CERTIFICATE_UNKNOWN`.

The focused source checkpoint is intentionally not a parity completion claim. A new immutable source commit and two new marker-protected candidates are required before this handoff can record resolution.

The Stephen-owned tracking issue is [stephenlclarke/container#87](https://github.com/stephenlclarke/container/issues/87). It remains open until the full candidate evidence passes.

## Apple-shaped boundary

The work remains local on `upstream/logging-fluentd-tls-trust-failure-rest-01`. No Apple issue, pull request, branch publication, or push has been created. If controlling the TLS alert requires an NIOSSL change, retain a separate Apple-shaped handoff and defer publication until all programme waves are complete and the user explicitly authorises it.

Related pull-request handoff: `docs/upstream/PR-fluentd-tls-trust-failure.md`.

<!-- markdownlint-enable MD013 -->
