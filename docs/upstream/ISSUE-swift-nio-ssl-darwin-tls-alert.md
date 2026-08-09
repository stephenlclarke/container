<!-- markdownlint-disable MD013 -->

# Runtime gap: Darwin Security.framework verification cannot select its TLS failure alert

## Problem

At `apple/swift-nio-ssl` `d930168b86f46ca51a4bc09c5ca45c1833db8067`, the Darwin default-trust path installs `CustomVerifyManager` through `SSLConnection.setCustomVerificationCallback`. BoringSSL calls that bridge with an `outAlert` pointer. The bridge currently calls `CustomVerifyManager.process(on:)` and ignores `outAlert`; after Security.framework rejects an untrusted chain, the manager returns `ssl_verify_invalid` without an alert selection. BoringSSL therefore sends its documented default `certificate_unknown` alert.

The same bounded self-signed Fluentd receiver records `SSLV3_ALERT_BAD_CERTIFICATE` from Docker Engine 29.2.1, but `SSLV3_ALERT_CERTIFICATE_UNKNOWN` from the native Container client. Container's source checkpoint now maps the public Docker error exactly, so this low-level alert difference is the remaining observable parity gap.

## Required behavior

- Let the internal Darwin Security.framework default-trust verifier select the BoringSSL `bad_certificate` alert when its validation result is failed.
- Preserve the existing trust decision, asynchronous retry/resume behavior, public custom-verification callback behavior, and any caller-selected trust-root behavior.
- Do not expose a generic application-controlled alert selector, weaken certificate validation, mutate trust stores, or alter non-Darwin behavior.
- Retain a focused NIOSSL regression proving the failed default-verifier bridge writes only its fixed alert and successful/pending paths do not write one.

## Evidence

- BoringSSL's own `SSL_set_custom_verify` contract states that a failed callback may set `*out_alert`; if omitted it sends `certificate_unknown` by default. The vendored declaration is at `Sources/CNIOBoringSSL/include/CNIOBoringSSL_ssl.h` in the pinned source.
- `SSLConnection.setCustomVerificationCallback` receives `outAlert` but does not pass it to `CustomVerifyManager`.
- `CustomVerifyManager.process(on:)` returns `ssl_verify_invalid` for a failed Security.framework promise but retains no alert policy.
- The Docker oracle at `/private/tmp/container-rest-fluentd-tls.docker.m7QDss/result.json` records `SSLV3_ALERT_BAD_CERTIFICATE`.
- The exact Container candidate at `/private/tmp/container-rest-fluentd-tls.candidate-66e-1.tBR6n1/receiver-result.json` records `SSLV3_ALERT_CERTIFICATE_UNKNOWN` while `start.stderr` and inspection already match Docker.

## Acceptance evidence

- [ ] A narrow NIOSSL test proves the configured internal Darwin verifier writes `SSL_AD_BAD_CERTIFICATE` only when it returns `ssl_verify_invalid`.
- [ ] Existing custom-verifier, success, retry, and non-Darwin focused tests remain green without a changed public API or trust decision.
- [ ] Container is built with the exact local NIOSSL patch and the same self-signed Docker CLI fixture passes its receiver-alert assertion in two fresh source/dependency/binary/guest/root candidates.
- [ ] The Container issue handoff records the resolved evidence and Stephen-owned [container #87](https://github.com/stephenlclarke/container/issues/87) is commented and closed only after the full public contract passes.

## Safe local handoff

Create the local-only patch on a clean `upstream/fluentd-tls-alert-control-01` branch. Keep all work on this MBP. Do not create an Apple issue, pull request, branch publication, or push until the programme-wide publication boundary and explicit user authorisation.

Related Container handoff: `docs/upstream/ISSUE-fluentd-tls-trust-failure.md`.

<!-- markdownlint-enable MD013 -->
