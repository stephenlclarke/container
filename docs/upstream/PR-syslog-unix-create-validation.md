<!-- markdownlint-disable MD013 -->

# Pull request handoff: validate missing Syslog Unix paths during create

## Summary

- Resolve Unix Syslog endpoint syntax through the existing Docker semantic
  helper, then perform Docker's create-time existence check.
- Add stream and datagram regressions for existing and missing paths.
- Preserve deferred transport handling for connection and socket-type errors.

## Implementation

`SyslogDriverConfiguration.resolve` calls
`validateUnixSocketExists(for:)` immediately after endpoint parsing. The helper
examines only `unix` and `unixgram` endpoints, requires a UTF-8 path, and uses
`FileManager.fileExists(atPath:)` as the equivalent of the observed Docker
`stat` boundary. It returns the provider's existing typed missing-socket error;
no logger session, transport, workload, or resource is created.

## Docker oracle and validation

- Docker CLI 29.7.1 / Engine 29.2.1 rejects both URI schemes at create with
  `stat /definitely-missing/syslog.sock: no such file or directory` and no
  inspectable container. The strict fixture result is retained at
  `/private/tmp/container-rest-syslog-unix.reference.4FUUag/result.json`.
- Compose supplies
  `Tools/parity/check-docker-rest-syslog-unix-create-validation.sh`, which
  checks both URI schemes, optional native-authority absence, and
  marker-protected evidence output.
- Container `f4878c7a927c811fe5938d5a6f9027c89e64a818` has the same stable
  patch ID as the earlier signed source correction whose targeted build passed.
  The exact current-branch focused test and a fresh candidate are not claimed:
  the normal dependency graph remains unresolved, and the full resolver was
  stopped before it could exhaust the MBP disk.

## Review checklist

- [x] Only Unix stream and datagram endpoints gain create-time validation.
- [x] Existing paths and both missing URI schemes have focused regressions.
- [x] Docker reference proves the diagnostic, phase, and absence of residue.
- [ ] A current exact-graph focused test passes.
- [ ] A fresh exact-fingerprint public-socket candidate matches Docker.

## Publication boundary

No Apple issue, pull request, branch publication, or push has been created.
Do not publish this handoff until the matched dependency graph, focused test,
and public-socket candidate evidence are all complete.

Related issue handoff:
`docs/upstream/ISSUE-syslog-unix-create-validation.md`.

<!-- markdownlint-enable MD013 -->
