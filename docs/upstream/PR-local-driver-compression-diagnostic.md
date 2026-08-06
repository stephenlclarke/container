<!-- markdownlint-disable MD013 -->

# Pull request handoff: align local compression start diagnostic

## Summary

- Match Docker Engine's local-driver diagnostic when compression is effective and `max-file=1`.
- Keep the validation at container start, preserving the configured created container after rejection.
- Leave json-file's broader missing-size/one-file diagnostic unchanged.
- Add a repository-owned Docker CLI certificate for local rotation, compressed retention, restart behavior, tailing, and deferred validation.

## Scope

This is the Container-owned start-validation portion of the logging parity work. It deliberately excludes Compose parsing, remote logging providers, Docker plugin distribution, release publication, and unrelated log-driver behavior.

## Implementation

`ContainerLogStartValidator` now distinguishes local's defaulted maximum-size policy from json-file's missing-size case. When the effective local `max-file` count is below two, it emits Docker's concrete one-file compression diagnostic. The existing generic diagnostic remains the fallback for json-file and any missing-size case.

The paired Compose repository extends `Tools/parity/check-docker-rest-logging-contract.sh` so the same Docker CLI fixture is an executable oracle for local rotation and public REST behavior. The fixture does not inspect a candidate's private log-file format; it asserts only Docker-visible configuration, lifecycle state, `LogPath`, retained records, tail output, and failure behavior.

## Docker oracle and validation

Pinned reference: Docker Engine 29.2.1, Docker CLI 29.7.1, and `alpine:3.20` on the programme MacBook Pro.

- `Tools/parity/check-docker-rest-logging-contract.sh --strict --reference` passes with local rotation records `26...40` then `66...80` across restart, correct tails, empty public `LogPath`, and the one-file compression rejection.
- `swift format lint` and `git diff --check` pass for the changed Container source and test.
- The named Swift regression is present but has no green execution evidence yet: SwiftPM's filtered test command rebuilt unrelated package targets and was intentionally stopped before execution. The marker-protected scratch root was removed and the generated `Package.resolved` change restored exactly.
- Exact current-head public-socket certification remains required before treating this handoff as verified.

## Review checklist

- [x] The local diagnostic is selected only for local's concrete one-file rotation policy.
- [x] Json-file behavior remains generic when compression lacks a usable rotation configuration.
- [x] Create-time configuration remains accepted and start-time rejection retains the container.
- [x] Docker-visible local rotation and restart retention have an executable reference certificate.
- [ ] The exact current artifact passes that certificate through the Container public socket.
- [ ] The broader parity, performance, security, migration, and release gates run at the programme checkpoint.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created. Do not publish this handoff until all programme development is complete and the user explicitly authorises the coordinated Apple upstream wave.

Related issue handoff: `docs/upstream/ISSUE-local-driver-compression-diagnostic.md`.

<!-- markdownlint-enable MD013 -->
