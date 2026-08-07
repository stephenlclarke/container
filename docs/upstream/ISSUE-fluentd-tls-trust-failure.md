<!-- markdownlint-disable MD013 -->

# Runtime gap: Docker Fluentd TLS trust-failure diagnostic and alert

## Problem

Docker Engine accepts a cache-disabled Fluentd `tls://host.docker.internal:PORT` configuration at create and rejects `docker start` when the bounded receiver presents an untrusted self-signed certificate. It reports `failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority`, retains the Docker-visible `created` state, and the receiver observes a TLS `bad_certificate` alert.

The signed Container checkpoint now reaches the same create/start phase, retains `created`, and projects Docker's exact diagnostic. Its BoringSSL client still sends `certificate_unknown` rather than Docker's `bad_certificate` alert. The remaining wire-alert gap is independently observable through the public Docker CLI path and is rooted in SwiftNIO SSL's Darwin custom-verification bridge.

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
- [x] The first exact-fingerprint candidate from Container `66e0cac3c7e86147d3cb5e26c5dc68fe2a987d4f` matches Docker's public start diagnostic and rejected `created` state while retaining the requested Fluentd configuration and an unchanged user runtime.
- [ ] Resolve the receiver-observed `certificate_unknown` versus Docker `bad_certificate` alert mismatch at the NIOSSL/BoringSSL verification callback boundary.
- [ ] Retain two fresh exact-fingerprint candidates after that dependency correction proves create/start/inspect/alert/cleanup parity.

## Local evidence

The original candidate, built from signed Container `359e14e4f991db0f3729d44651b9f82d9ab1b0ed` with Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API `f5d0d120bb139675e96a4ef9f7b0ac800827c295`, is retained under `/private/tmp/container-rest-fluentd-tls.candidate.qmcDLQ`. It first exposed the generic public error and the bounded receiver's `SSLV3_ALERT_CERTIFICATE_UNKNOWN`.

The corrected candidate evidence is retained under `/private/tmp/container-rest-fluentd-tls.candidate-66e-1.tBR6n1` with exact inputs at `/private/tmp/container-fluentd-runtime-stage-66e.FjAkAu/candidate-run-1.inputs.txt`. Its `start.stderr` matches Docker's exact diagnostic, its inspection is `created`/exit `128`, and the user Docker runtime remained `29.7.1/29.2.1` after the candidate namespace stopped. Its receiver has one rejected connection and `SSLV3_ALERT_CERTIFICATE_UNKNOWN`, so the strict fixture stops before a passing result JSON. The synthetic private key is absent.

The Container source correction is intentionally not a parity completion claim. A local SwiftNIO SSL alert-control patch and two new marker-protected candidates are required before this handoff can record resolution.

The Stephen-owned tracking issue is [stephenlclarke/container#87](https://github.com/stephenlclarke/container/issues/87). It remains open until the full candidate evidence passes.

## Apple-shaped boundary

The Container work remains local on `upstream/logging-fluentd-tls-trust-failure-rest-01`. The dependent SwiftNIO SSL work is documented in `docs/upstream/ISSUE-swift-nio-ssl-darwin-tls-alert.md` and `docs/upstream/PR-swift-nio-ssl-darwin-tls-alert.md`. No Apple issue, pull request, branch publication, or push has been created. Defer publication until all programme waves complete and the user explicitly authorises it.

Related pull-request handoff: `docs/upstream/PR-fluentd-tls-trust-failure.md`.

<!-- markdownlint-enable MD013 -->
