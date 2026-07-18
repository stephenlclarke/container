# Pull request: support CPU CFS quota and period

## Summary

- Add generic `container run/create --cpu-period` and `--cpu-quota` options.
- Persist optional CFS values in container resource configuration, including
  backward-compatible decoding of existing saved configurations.
- Project values through the existing macOS Linux runtime bridge to the
  generic Containerization CFS primitive.
- Match Docker's interaction rules: zero leaves a value unset; `-1` is an
  unlimited quota; positive `--cpus` conflicts with positive explicit quota
  or period controls.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Generic optional CFS quota/period runtime primitive (`e540824`). |
| `apple/container` | Generic CLI, validation, persisted configuration, and runtime projection (`81cc56f`). |
| `container-compose` | Separate adapter that passes normalized Compose values as generic flags. |

No Docker or Compose types enter this fork. The CLI names describe the Linux
CFS resource mechanism; all policy remains with the caller.

## Code map

- `Sources/Services/ContainerAPIService/Client/Flags.swift` exposes help for
  `--cpu-period` and `--cpu-quota` on `run` and `create`.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` validates CFS
  values, models zero as unset, accepts `-1` for unlimited quota, and rejects
  the Docker-conflicting positive `--cpus`/quota-or-period combinations.
- `Sources/ContainerResource/Container/ContainerConfiguration.swift` persists
  the optional period with backward-compatible decoding.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` projects both
  fields to `LinuxContainer.Configuration`.
- Unit and guest integration tests cover parsing, persistence, CLI help, and
  exact cgroup v2 `cpu.max` behavior.

## Validation

```sh
swift test --disable-automatic-resolution --filter \
  'ParserTest/(testResourcesAppliesExplicitCPUQuotaAndPeriod|testResourcesTreatsZeroCPUQuotaAndPeriodAsUnset|testResourcesAllowsUnlimitedCPUQuota|testResourcesRejectsInvalidCPUPeriodAndQuota|testResourcesRejectsCPUsCombinedWithExplicitQuotaOrPeriod|testResourcesSupportsFractionalCPUs)|ContainerRunCreateCommandTests/createParsesCPUQuotaAndPeriodFlags|ContainerConfigurationResourcesTests'
make integration CONCURRENT_FILTER='TestCLIRunCommand/testRunCommandCPUQuotaAndPeriod' \
  SERIAL_FILTER='__NoMatchingIntegrationSuite__/' \
  WARMUP_FILTER='ImageWarmup/' PARALLEL_WIDTH=1
make cli
bin/container run --help
git diff --check
```

The focused suite passed 13 tests. The staged macOS guest integration passed
after launching a container with `--cpu-period 200000 --cpu-quota 50000` and
asserting `/sys/fs/cgroup/cpu.max` is exactly `50000 200000`. `container run
--help` advertises both options. The full unit-coverage and `make check` gates
are run as part of the local batch before push.

The downstream Compose parity fixture compares Docker Compose V2 5.3.1 config
output and verifies the local Compose dry-run renders the same CFS arguments.
Docker Engine confirmation remains optional when a local daemon is absent.

## Review checklist

- [ ] Replay companion Containerization commit `e540824` after `f7b45bf`.
- [ ] Replay `81cc56f` after the dependency is available.
- [ ] Verify zero remains unset, `-1` represents unlimited quota, and values
  below `-1` are rejected.
- [ ] Verify `--cpus` conflicts only with positive explicit quota/period,
  matching Docker Engine's NanoCPU conflict rules.
- [ ] Verify `50000 200000` in a macOS guest cgroup v2 `cpu.max` file.
- [ ] Keep Compose/Docker model code out of this PR.

## Non-goals

- CPU realtime (`cpu_rt_period`, `cpu_rt_runtime`) or cpuset controls.
- Windows resources.
- Changing VM CPU allocation or host scheduling.
