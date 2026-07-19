# [Bug]: Attachment-name validation is global instead of network-scoped

## I have done the following

- [x] I have searched the existing issues.
- [x] I reproduced the issue from the current upstream `main` baseline before
  applying the fix.

## Steps to reproduce

1. Create two distinct named networks.
2. Create a container on the first network with `--network FIRST,alias=api`.
3. Create a different container on the second network with
   `--network SECOND,alias=api`.

Before the fix, the second `container create` fails with
`hostname(s) already exist: ["api"]`, even though the two attachment names
belong to different networks.

## Problem description

`ContainersService.create` collected every existing attachment hostname and
alias into one global set. It then rejected a requested name if it occurred
anywhere, irrespective of `AttachmentConfiguration.network`.

Attachment hostnames and aliases identify an attachment in a particular
network, so a name conflict must be evaluated per network. The global check
incorrectly prevents otherwise independent networks from using the same
service-like attachment name. It also treats two requested attachments on
different networks as conflicting.

The expected behavior is:

- Reject a hostname or alias that is already reserved on the same network.
- Reject duplicate names among requested attachments on the same network.
- Allow the same hostname or alias on distinct networks.

## Environment

- OS: macOS 26.5.2
- Xcode: 26.6 (17F113)
- Container: local debug build from
  `17cc06a514bd15ec1236e01f0ad7a9bce02aaa6b`

## Proposed Apple-shaped fix

`17cc06a514bd15ec1236e01f0ad7a9bce02aaa6b` replaces the global set with a
small, internal `ContainersService.conflictingNetworkNames` helper keyed by
network identifier. The helper keeps the existing error path and deterministic
sorted error names, while applying the allocation rule at the correct generic
runtime boundary.

The change is intentionally limited to generic `AttachmentConfiguration`
semantics. It has no Compose-specific types, syntax, or runtime protocol.

## Scope and non-goals

- This fixes generic runtime allocation validation on macOS-hosted Linux
  guests.
- This does not add embedded DNS, guest-side hostname resolution, or dynamic
  alias propagation.
- This does not change Docker Compose parsing or claim Docker Compose V2
  service-alias parity. Compose aliases must remain unsupported until the
  runtime can resolve them correctly inside each guest network.
- This does not add Windows-specific networking behavior.

## Docker Compose V2 relationship

Docker Compose V2 permits service aliases scoped to a network. This generic
fix removes one prerequisite validation defect, but it cannot by itself provide
that behavior: the current runtime has no embedded discovery service wired into
guest DNS. No `DockerCompose.yml` parity fixture accompanies this commit,
because accepting a Compose alias without guest resolution would be misleading.
The follow-up Compose slice must add a fixture only when an end-to-end resolver
is implemented and can be compared with Docker Compose V2.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
