# Syslog TLS trust-rejection parity handoff

## Summary

This local change adds a typed Syslog TLS trust-verification failure,
normalizes only BoringSSL `CERTIFICATE_VERIFY_FAILED` handshake failures to
that type, and projects the type through the Docker logging backend as the
same public diagnostic Docker Engine `29.2.1` returns. Focused assertions
cover the self-signed transport failure, preservation of a non-trust error,
and the Docker-backend projection.

## Scope and non-goals

The change does not alter successful Syslog TLS delivery, custom CA roots,
client certificates, identity verification, retry policy, cache behavior, or
any performance path. It does not claim candidate or release-performance
parity. A real hang is blocking; ordinary timing is retained only for later
comparison.

## Validation status

`swift format lint --strict` passes for every touched provider and test file,
and `swiftc -parse` passes for every changed Swift file. The full focused
release test invocation did not begin compilation: SwiftPM stalled in manifest
setup on an isolated copy-on-write stage and was stopped. The fresh candidate
rebuild and two independent public-socket results therefore remain required.

## Dependency boundary

The existing local SwiftNIO SSL alert-control handoff at
`a9d648535c62e640d1df258a70c9117a8ddea43e` is required to make a Darwin
default-trust rejection emit Docker's `bad_certificate` alert. Do not move a
published dependency pin, mutate trust stores, or reuse the earlier candidate
as proof of this source correction.

## Publication boundary

No external pull request, issue, branch publication, or push has been made.
This document records a local-only, incomplete handoff until exact candidate
proof is available.

Related issue handoff:
`docs/upstream/ISSUE-syslog-tls-trust-rejection.md`.
