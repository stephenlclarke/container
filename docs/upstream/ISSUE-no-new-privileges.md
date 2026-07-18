# Compatibility gap: no-new-privileges process security option

## Compose surface

`services.<name>.security_opt: [no-new-privileges:true]`

## Docker Compose V2 behavior

Docker Compose V2 preserves the string `no-new-privileges:true` in
`config --format json` and passes it to Docker as a container security option.
The Linux process must then be unable to gain privileges through `execve`,
including set-user-ID and file-capability transitions.

## Existing Apple primitive

`Containerization.LinuxProcessConfiguration` already exposes
`noNewPrivileges`, which renders OCI process `noNewPrivileges`. The missing
piece is a generic `container` CLI/configuration bridge; no Compose-specific
API belongs in either Apple-shaped fork.

## Required `container` behavior

- Accept repeatable `container run/create --security-opt` input.
- Support only `no-new-privileges:true|false` and
  `no-new-privileges=true|false`; reject unknown security options rather than
  silently weakening or ignoring a security request.
- Persist the setting in `ProcessConfiguration`, with `false` as the
  backwards-compatible decode default.
- Apply it to the initial Linux process through the existing Containerization
  primitive.

## Non-goals

- SELinux/AppArmor labels, custom seccomp profiles, masked/readonly path
  overrides, user namespaces, and Docker-complete `--privileged` behavior.
- Windows `credential_spec`, `isolation`, or Windows security-option forms.
- Compose orchestration logic; the follow-on Compose slice only renders this
  generic runtime option.
