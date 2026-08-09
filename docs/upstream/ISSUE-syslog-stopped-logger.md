<!-- markdownlint-disable MD013 -->

# Runtime gap: stopped cache-disabled Syslog logger reconstruction

## Problem

Docker Engine 29.2.1 creates the remote logger before determining whether `docker logs` can read history. For an exited container with `--log-driver=syslog` and `cache-disabled=true`, Moby opens and closes a second empty Syslog TCP connection, then returns `configured logging driver does not support reading`.

The Container fork returned the same public unreadable-history error without reconstructing the native Syslog logger. The missing transport side effect made the public Docker socket observably incompatible and skipped connection failures that Docker exposes before its unsupported-reader result.

## Required behavior

- For a stopped or created native `syslog` container whose resolved read policy is unavailable, reconstruct one transient `SyslogDriverSession` from the same typed configuration used for the writer.
- Eagerly connect, close the transient session, and then retain the Docker-compatible unsupported-history error.
- Let a connection failure propagate at the same pre-reader phase; do not retain a session, reader token, or ledger effect.
- Leave running/paused/stopping containers, cache-backed reads, non-Syslog providers, and Docker-visible configuration unchanged.

## Acceptance evidence

- [x] `SyslogProviderTests` passes 8/8 against Container `b82e34874b944d2b9ecc65d4068aee5d7b46905e`, local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API `4949e743675f00ec102f7acacdb4e990409e383f`.
- [x] The new provider method has 10/10 executable focused lines covered; the authority/service path is exercised by the Docker CLI certificate.
- [x] Docker CLI 29.7.1 / Engine 29.2.1 records two TCP connections, with one empty post-`logs` connection, in `/private/tmp/container-syslog-tcp-reference-v8.YBX82T`.
- [x] The fresh signed candidate archive passes the same public-socket certificate twice in `/private/tmp/container-syslog-tcp-candidate-v4.OZHeoC`; source, dependencies, archive, binaries, guest images, harness, kernel, results, and cleanup are bound by `FINGERPRINT-COMPLETE.json`.

## Local issue and upstream boundary

The Stephen-owned tracking issue [stephenlclarke/container#79](https://github.com/stephenlclarke/container/issues/79) records the defect and must be commented and closed after the clean documentation checkpoint.

This is a fork-only Syslog provider path: Apple `origin/main` does not contain the provider or its authority integration. No Apple issue, pull request, branch publication, or push is appropriate. The implementation remains on local `upstream/logging-driver-parity` until the programme-wide publication boundary.

Related pull-request handoff: `docs/upstream/PR-syslog-stopped-logger.md`.

<!-- markdownlint-enable MD013 -->
