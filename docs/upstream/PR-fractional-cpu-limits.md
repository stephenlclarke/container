# Pull request: support fractional CPU limits

## Summary

- Accept fractional `--cpus` values, including `0.25`, for `container run`
  and `container create`.
- Keep sandbox VM CPU allocation integral while persisting an optional CFS
  quota in microseconds.
- Carry that quota through generic container configuration and apply it to the
  existing macOS-hosted Linux runtime configuration.
- Preserve integer CPU behavior by emitting the same 100 ms period and quota
  as before.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Separate generic optional `cpuQuotaInMicroseconds` primitive. |
| `apple/container` | Generic CLI parsing, persisted resource configuration, and runtime projection. |
| `container-compose` | Separate consumer; it already emits generic `--cpus` arguments. |

This does not introduce Docker or Compose types into `apple/container`.
`cpus` continues to allocate an integral sandbox VM CPU count; the optional
CFS quota limits the workload within that VM and is usable by every client.

## Code map

- `Sources/Services/ContainerAPIService/Client/Flags.swift` makes `--cpus`
  fractional and documents it in CLI help.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` validates a
  positive, representable CPU value, rounds VM allocation up to an integral
  CPU, and derives the 100 ms CFS quota.
- `Sources/ContainerResource/Container/ContainerConfiguration.swift`
  persists the optional quota while decoding old configuration as `nil`.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` transfers the
  quota to the generic Containerization configuration.
- `Sources/ContainerCommands/Builder/BuilderStart.swift` retains the builder
  path's integer CPU input through the generalized resource parser.

## Validation

Completed locally against the companion Containerization change:

```sh
swift test --disable-automatic-resolution --filter \
  'ParserTest/(testResourcesFlagOverridesDefaults|testResourcesSupportsFractionalCPUs|testResourcesRejectsUnrepresentableCPUs)|ContainerRunCreateCommandTests/runParsesFractionalCPUFlag|ContainerConfigurationResourcesTests'
make integration CONCURRENT_FILTER='TestCLIRunCommand/testRunCommandFractionalCPUs' \
  SERIAL_FILTER='__NoMatchingIntegrationSuite__/' \
  WARMUP_FILTER='ImageWarmup/' PARALLEL_WIDTH=1
make check
make coverage-unit
make cli
bin/container run --help
git diff --check
```

The focused parser/configuration/CLI suite passed 8 tests. The staged macOS
guest integration created a container with `--cpus 0.25` and verified
`/sys/fs/cgroup/cpu.max` is exactly `25000 100000`. The unit coverage gate
passed 1,034 tests in 123 suites (36.06% line coverage). `container run
--help` advertises the fractional CPU capability.

The downstream Compose parity fixture compares Docker Compose V2 5.3.1 config
output for `cpus: 0.25` and confirms `container-compose --dry-run up` renders
`--cpus 0.25`. Docker Engine dry-run confirmation is optional and was skipped
because no local daemon was available.

## Review checklist

- [ ] Replay `b2a44aa` after companion commit `f7b45bf` from
  `apple/containerization`.
- [ ] Verify integer `--cpus 2` still yields `200000 100000`.
- [ ] Verify `--cpus 0.25` creates an integral one-vCPU VM and applies CFS
  quota `25000` with period `100000`.
- [ ] Verify old saved container configurations decode without a CPU quota.
- [ ] Keep Docker Compose normalization and Docker-specific CPU period/quota
  policy out of this generic runtime pull request.

## Non-goals

- Explicit Docker `cpu_period`, `cpu_quota`, CPU realtime, or cpuset flags.
- Windows resource controls.
- Changing VM CPU hotplug or host scheduling behavior.
