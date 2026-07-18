# Pull request: persist generic container stop defaults

## Summary

- Add `--stop-signal` and `--stop-timeout` to `container run` and
  `container create`.
- Persist the configured signal and timeout in `ContainerConfiguration`.
- Use persisted values only when a later `container stop` caller does not
  provide an explicit signal or timeout.
- Retain the existing five-second runtime fallback when neither caller nor
  container configuration provides a timeout.
- Add parser, serialization, staged macOS runtime-integration, and coverage
  tests.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | No source change; the existing Linux process stop path accepts signal and timeout. |
| `apple/container` | Generic CLI, persisted configuration, and stop-default resolution. |
| `container-compose` | Separate consumer that renders Compose service defaults through these generic flags. |

No Compose-specific type, protocol, command, or policy is introduced in this
fork. Explicit `container stop --signal/--time` values continue to override
the persisted defaults, which makes the behavior useful to every container
client rather than just Compose.

## Code map

- `Sources/Services/ContainerAPIService/Client/Flags.swift` defines the two
  generic creation flags and rejects a negative timeout.
- `Sources/Services/ContainerAPIService/Client/Utility.swift` stores the
  creation-time defaults in `ContainerConfiguration`.
- `Sources/ContainerResource/Container/ContainerConfiguration.swift` keeps
  the optional timeout backward-compatible for existing saved containers.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`
  fills unspecified stop options from persisted configuration.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` applies the
  established five-second fallback only after default resolution.
- `Sources/ContainerCommands/Container/ContainerStop.swift` makes an omitted
  `--time` distinct from an explicit timeout.

## Validation

Completed locally:

```sh
swift test --disable-automatic-resolution --filter \
  'ContainerRunCreateCommandTests|ContainerConfigurationStopTests'
make integration CONCURRENT_FILTER='TestCLIStop/' \
  SERIAL_FILTER='__NoMatchingIntegrationSuite__/' \
  WARMUP_FILTER='ImageWarmup/' PARALLEL_WIDTH=1
make check
make coverage-unit
make cli
bin/container run --help
git diff --check
```

The focused parser/configuration suites passed 33 tests. The staged macOS
runtime integration pass ran five `TestCLIStop` cases, including a container
created with `--stop-signal SIGKILL --stop-timeout 0` and stopped without
explicit overrides. The coverage-unit gate passed 1,029 tests in 123 suites.
`container run --help` exposes both new options.

The downstream Compose check uses Docker Compose V2 5.3.1 config output plus
`container-compose --dry-run up` to confirm `stop_signal: SIGUSR1` and
`stop_grace_period: 9s` render as `--stop-signal SIGUSR1 --stop-timeout 9`.
The local Docker daemon was unavailable, so the optional Engine dry-run check
was skipped without weakening the config and Compose dry-run assertions.

## Review checklist

- [ ] Confirm `8650e5d` is replayed on the intended Apple upstream base.
- [ ] Create a container with explicit defaults and inspect both persisted
  fields.
- [ ] Verify omitted `container stop` options use the persisted values.
- [ ] Verify explicit `container stop --signal/--time` remains authoritative.
- [ ] Keep Compose policy and Docker-specific duration parsing out of this
  generic runtime pull request.

## Non-goals

- Docker event or lifecycle-state expansion.
- Windows shutdown semantics.
- Arbitrary signal validation beyond the existing runtime signal parser.
- Compose command behavior; it is a separately tested downstream adapter.
