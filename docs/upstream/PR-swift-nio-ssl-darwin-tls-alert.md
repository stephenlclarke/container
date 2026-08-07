<!-- markdownlint-disable MD013 -->

# Pull request handoff: select `bad_certificate` for Darwin default-trust failures

## Summary

- Carry BoringSSL's `outAlert` pointer through the internal custom-verification bridge.
- Give only the Darwin Security.framework default-trust manager a fixed `bad_certificate` failure alert.
- Preserve native trust validation, public custom-verifier semantics, retry/resume behavior, and non-Darwin behavior.
- Add a focused regression at the manager/bridge boundary, then verify the public Container Fluentd TLS failure contract through fresh exact-fingerprint candidates.

## Motivation

The current Darwin bridge returns `ssl_verify_invalid` without assigning BoringSSL's available `outAlert` value. BoringSSL chooses `certificate_unknown` by default. Docker Engine 29.2.1 sends `bad_certificate` for the same untrusted self-signed Fluentd peer. Container already produces Docker's exact public error and rejected state, so the alert is independently observable and must not be hidden by source-level error mapping.

## Proposed implementation

Add an internal optional failure-alert policy to `CustomVerifyManager`. The bridge passes `outAlert` into the manager; only the manager constructed for Darwin's Security.framework system-default verifier is configured with `SSL_AD_BAD_CERTIFICATE`. On its completed failed result, the manager writes that byte before returning `ssl_verify_invalid`. Default public custom-verifier managers retain no policy and therefore retain BoringSSL's existing default alert. Success and retry paths leave the pointer untouched.

This is intentionally an internal behavior correction rather than a new public callback option: callers must not gain a way to misrepresent certificate failures or vary alerts independently of the trust decision.

## Validation

- Add a focused manager/bridge regression for fixed-alert failure, unspecified public-custom failure, success, and retry behavior.
- Run the affected NIOSSL tests on macOS and the existing non-Darwin focused package tests where available.
- Build Container through a local dependency override at the exact pinned NIOSSL revision plus this patch.
- Run the retained unmodified Docker CLI fixture twice with exact source/dependency/binary/guest/fixture/root fingerprints. Both candidates must match Docker's error, `created` state, `SSLV3_ALERT_BAD_CERTIFICATE`, cleanup, and user-runtime health.

## Compatibility and risk

The change is scoped to Darwin's internal Security.framework default-trust bridge. It does not alter the accept/reject result, host trust roots, certificate validation, public API, protocol version, Linux behavior, or user-supplied custom verifier behavior. The focused regression must prove the scope before any Container candidate is counted as passing.

## Publication boundary

This handoff is local only. No Apple issue, pull request, branch publication, or push has been created. Do not publish until all parity development waves are complete and the user explicitly authorises coordinated upstream publication.

Related issue handoff: `docs/upstream/ISSUE-swift-nio-ssl-darwin-tls-alert.md`.

<!-- markdownlint-enable MD013 -->
