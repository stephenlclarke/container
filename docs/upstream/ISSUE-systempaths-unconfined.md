# Compatibility gap: unconfined Linux guest system paths

## Compose surface

`services.<name>.security_opt: [systempaths=unconfined]`

Docker Compose V2 also preserves the equivalent colon form,
`systempaths:unconfined`, when it appears in a Compose file.

## Docker-compatible behavior required on macOS

The `systempaths=unconfined` security option removes the OCI masked-path and
read-only-path overrides normally applied to the Linux container. It does not
imply `privileged`, add Linux capabilities, alter the macOS host boundary, or
enable Windows-only options.

On macOS, the relevant boundary is the Linux guest managed by
Containerization. `LinuxContainer.Configuration` already provides
`maskedPaths` and `readonlyPaths`, so the required change is a small, generic
bridge in `container`; it does not require a Compose-specific or Docker-specific
API in either Apple-shaped fork.

## Required `container` behavior

- Accept repeatable `container run/create --security-opt` input in both
  `systempaths:unconfined` and `systempaths=unconfined` forms.
- Persist the requested guest-path behavior with a backwards-compatible
  `false` default for previously serialized container configurations.
- Clear only `LinuxContainer.Configuration.maskedPaths` and `.readonlyPaths`
  for this setting.
- Keep explicit capability selection independent. In particular,
  `--cap-drop ALL` must remain effective.
- Reject malformed values and unknown security options before a container is
  created.

## Non-goals

- SELinux/AppArmor labels, custom seccomp profiles, or arbitrary Docker
  `security_opt` values.
- Host filesystem exposure, host process privileges, or a weakened macOS
  sandbox boundary.
- Windows `credential_spec`, `isolation`, and other Windows-only forms.
- Compose orchestration logic. The follow-on Compose slice translates the
  Docker spelling to this generic runtime control.
