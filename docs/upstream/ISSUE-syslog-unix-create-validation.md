<!-- markdownlint-disable MD013 -->

# Runtime gap: create-time validation for Syslog Unix paths

## Problem

Docker Engine 29.2.1 rejects a missing Unix Syslog path while creating a
container. Both `unix://` and `unixgram://` return the same `stat` diagnostic,
and neither leaves an inspectable container. The active Container source branch
parsed those addresses but deferred all failure to the transport start path.

## Required behavior

- Parse a Syslog endpoint through the Docker semantic helper, then validate
  existence only for Unix stream and datagram endpoints.
- Return `unixSocketDoesNotExist` before provider or workload creation when
  `stat` cannot find the path.
- Leave socket type, permissions, connection, and write errors to the later
  transport session, matching Docker's observable phase boundary.
- Keep system, UDP, TCP, and TCP+TLS configuration behavior unchanged.

## Local evidence

- [x] The Docker CLI 29.7.1 / Engine 29.2.1 strict reference fixture records
  both required create failures in
  `/private/tmp/container-rest-syslog-unix.reference.4FUUag/result.json`.
- [x] Signed local Container `f4878c7a927c811fe5938d5a6f9027c89e64a818`
  adds the narrow validation and stream/datagram existing/missing-path
  regressions. Its stable patch ID is
  `aa617b84dca40f1331d1a42aa133dab49572aa50`, exactly matching the earlier
  signed correction `52da6f47afe89c58df9e42f960aa52775ae865a4`.
- [x] Strict formatting and `git diff --check` pass for the integrated change.
- [ ] A fresh candidate and current-branch focused test remain required. The
  normal package graph must first be made coherently resolvable; an attempted
  full resolution was stopped before compilation to prevent an ENOSPC failure.

## Local issue and upstream boundary

The Stephen-owned tracking issue
[stephenlclarke/container#94](https://github.com/stephenlclarke/container/issues/94)
retains the original reproduction. This remains a fork-only logging-provider
path. No Apple issue, upstream pull request, push, or publication is authorised
until the complete matched stack and its public-socket certificate pass.

Related pull-request handoff:
`docs/upstream/PR-syslog-unix-create-validation.md`.

<!-- markdownlint-enable MD013 -->
