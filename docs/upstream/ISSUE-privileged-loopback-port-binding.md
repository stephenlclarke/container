# Privileged loopback host ports fail for non-root users

## Prerequisites

- [x] Searched the existing Apple Container issues.
- [x] Reproduced the issue from the current `apple/container` `main` line on
  macOS.
- [x] Confirmed that the equivalent wildcard-address binding still succeeds.

This handoff implements
[apple/container#1985](https://github.com/apple/container/issues/1985).

## Steps to reproduce

As a non-root user on macOS, run a container with an explicit loopback host
address and a host port below 1024:

```console
container run --rm --name low-port -p 127.0.0.1:80:80 alpine:3.20 \
  sh -c 'while true; do nc -l -p 80 -e echo ok; done'
```

Before the fix, bootstrap fails with `EACCES` while binding
`127.0.0.1:80`. The same port succeeds when the listener uses `0.0.0.0:80`
or an implicit wildcard address.

The underlying macOS socket behavior can be reproduced without Container:
an unprivileged process cannot bind a low port to an explicit loopback
address, but can bind the same port to a wildcard address. Applying
`IP_BOUND_IF` or `IPV6_BOUND_IF` to a wildcard socket scopes it to the owning
loopback interface and retains the successful low-port behavior.

## Problem description

Explicit loopback publication is the safer form for local-only development,
but it fails precisely where a wildcard listener succeeds. Running the CLI
with `sudo` is not a valid workaround because the per-user API server rejects
a client whose effective UID does not match its own.

The expected behavior is that explicit IPv4 and IPv6 loopback host addresses
can publish ports below 1024 without root, remain inaccessible through other
host interfaces, and preserve the current behavior for high ports, wildcard
addresses, and non-loopback addresses.

## Validation

- Seven address-resolution unit tests and four real TCP/UDP forwarder tests
  passed.
- `make coverage-unit` passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- The source-build integration gate passed 3 warmup tests, 238 concurrent tests
  in 27 suites, and 143 serial tests in 14 suites.
- The concurrent gate successfully ran `--publish 127.0.0.1:80:80` as the
  non-root MacBook Pro user, then inspected, stopped, and removed the container.

## Environment

- OS: macOS 26.5.2 (25F84)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Hardware: Apple silicon MacBook Pro
- Container source: Apple `main` through `f0b2b96`

## Code of Conduct

- [x] I agree to follow Apple's Code of Conduct.

## Commit tracking

- `71cdae6b695508086cef81b94e9ad77a633635f6`
  (`fix(network): bind privileged loopback ports`)
