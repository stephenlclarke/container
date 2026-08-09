<!-- markdownlint-disable MD013 -->

# Pull request handoff: reconstruct stopped cache-disabled Syslog loggers

## Summary

- Recreate Moby's stopped-container Syslog logger construction before returning the Docker public unsupported-history error.
- Use one transient provider session and the existing typed Syslog configuration path, without retaining a reader or writer effect.
- Add deterministic success and connection-failure provider regressions.

## Scope

This is a narrow native Syslog Docker REST compatibility correction. It covers cache-disabled Syslog TCP `docker logs` after container exit. It does not claim Syslog TLS, Unix sockets, retries, backpressure, every option, external clients, Compose projection, or comparable-or-better release performance.

## Implementation

`SyslogLogDriverProvider.recreateStoppedLogger` serializes a transient `SyslogDriverSession` creation through the provider operation fence and closes it without retaining a session identifier or ledger effect. A close failure is deliberately ignored so it cannot replace the Moby-compatible unsupported-reader result; connection failures still surface.

`AuthorityRemoteLogDriverPlane` resolves the same typed `SyslogDriverConfiguration` used by writer registration. `ContainersService` invokes that reconstruction only for an unavailable native Syslog read on a non-live container, then maps success to `ContainerLogReaderError.configuredDriverDoesNotSupportReading`. This preserves normal cache-backed and active-reader paths.

## Docker oracle and validation

- Docker Engine 29.2.1 / CLI 29.7.1 passes the fresh TCP fixture in `0.967602000s`, with two connections and an empty second stream after `docker logs`.
- The exact signed Container source is `b82e34874b944d2b9ecc65d4068aee5d7b46905e`; focused `SyslogProviderTests` pass 8/8 on the matched local Containerization and Engine API graph.
- Instrumented focused coverage records 10/10 executable lines (100%) for `recreateStoppedLogger`; the public CLI candidate exercises the authority and service route.
- Fresh signed archive candidates pass in `2.003332125s` and `1.660303875s` (2.07x and 1.72x Docker). They satisfy the focused <10x functional guard only, not comparable-or-better programme performance.
- The marker-protected roots `/private/tmp/container-syslog-tcp-reference-v8.YBX82T` and `/private/tmp/container-syslog-tcp-candidate-v4.OZHeoC` retain exact fingerprints, binary and guest inputs, results, kernel, and cleanup evidence.

## Review checklist

- [x] The transient logger is limited to stopped, unavailable native Syslog reads.
- [x] Writer configuration and reconstruction share one typed configuration helper.
- [x] Successful reconstruction returns the Docker public unreadable-history error; connection failure remains visible.
- [x] Focused provider success/failure regressions pass with 100% focused method line coverage.
- [x] Fresh Docker reference and two exact public-socket candidates prove the reconnect and cleanup behavior.
- [x] Performance is recorded as functional-only; no comparable-or-better claim is made.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all parity development waves are complete and the user explicitly authorises the coordinated upstream publication.

Related issue handoff: `docs/upstream/ISSUE-syslog-stopped-logger.md`.

<!-- markdownlint-enable MD013 -->
