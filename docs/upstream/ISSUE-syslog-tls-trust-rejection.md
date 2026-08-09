# Syslog TLS trust rejection must preserve Docker's public failure

## Problem

Docker Engine `29.2.1` accepts a cache-disabled Syslog `tcp+tls` logger at
create time, then rejects `start` when a bounded self-signed receiver cannot
be verified. The public failure is:

```text
failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority
```

The retained Container candidate reached the same receiver and retained the
container in `created`, but reported the generic `container logging operation
failed` diagnostic. It also sent `certificate_unknown`, where Docker sent
`bad_certificate`.

## Proposed local correction

Map only NIOSSL handshake failures whose BoringSSL stack contains
`CERTIFICATE_VERIFY_FAILED` to
`SyslogProviderError.tlsTrustVerificationFailed`. Map that provider error to
Docker's exact public start diagnostic. Preserve all transport, protocol, and
post-handshake identity errors without reclassification.

The Darwin TLS alert is supplied by the existing local SwiftNIO SSL
alert-control handoff; no host trust-store mutation is permitted.

## Current evidence and blocker

The Docker oracle is retained at
`/private/tmp/container-syslog-tls-probe.4Imdsj/result.json`. The candidate
mismatch is retained at
`/private/tmp/container-syslog-tls-candidate-probe.ssxkB4/result.json`.
The candidate's source base is `d843dd598fa086c8572e5df8a71eece56ad7b576`
with a staged patch that does not touch Syslog.

The source parser and strict format checks pass for the touched provider and
test files. A copy-on-write focused release test stage stalled in SwiftPM
manifest setup before producing compiler or test output; it was stopped and
removed without altering the immutable build stage. A fresh exact candidate
with the source change and local SwiftNIO SSL alert-control dependency is
still required before this contract can be verified.

## Publication boundary

This is a local Container handoff only. No external issue, pull request,
branch publication, or push has been created. Defer publication until the
programme is complete and the user explicitly authorizes it.

Related pull-request handoff:
`docs/upstream/PR-syslog-tls-trust-rejection.md`.
