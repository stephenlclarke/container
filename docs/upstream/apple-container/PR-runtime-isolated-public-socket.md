# Pull request: isolate opt-in candidate service ownership

## Summary

- Preserve stock service names and sockets when no namespace override is set.
- Validate an explicit `CONTAINER_SERVICE_NAMESPACE` and derive every
  Container service label and public Engine socket from it.
- Route system start, status, and stop plus client and plug-in discovery through
  the selected namespace.
- Ensure scoped stop cannot enumerate or remove services in the default or a
  different candidate namespace.

See the companion [issue handoff](ISSUE-runtime-isolated-public-socket.md).

## Code map

- `Sources/ContainerXPC/ContainerServiceNamespace.swift`
  - validates namespace values, retains the default compatibility case, and
    derives labels and the non-default Engine socket.
- Container system lifecycle and client/plug-in call sites
  - obtain service identifiers from `ContainerServiceNamespace` rather than
    concatenating a fixed global service name.
- Focused namespace/start/stop tests
  - protect default compatibility, custom isolation, invalid input rejection,
    and scoped lifecycle behavior.

## Validation

- [x] 19 focused namespace/start/stop tests passed with 100% line/function/
  region coverage for `ContainerServiceNamespace.swift`.
- [x] Bash syntax, ShellCheck, and `Tests/ScriptTests/TestInstallInit.sh`
  passed.
- [x] A source-pinned, marker-protected candidate completed public Docker CLI
  `docker version`, then removed only its own services and socket.
- [x] The unrelated `devcontainer-engine` remained running and responsive.

## Compatibility and risk

The default namespace intentionally retains the existing stock labels and
socket. The custom namespace is opt-in and bounded to a safe launchd/Mach
label form. This change does not claim generic multi-runtime release support,
Docker logging-driver parity, or comparable-or-better performance.

## Publication status

The signed local checkpoint is `c740a8f6a79ce176d03a941f49cdfe7350625a71` on
`upstream/runtime-isolated-public-socket-01`. Do not publish this Apple-shaped
handoff until the programme-wide publication boundary and explicit user
authorisation.
