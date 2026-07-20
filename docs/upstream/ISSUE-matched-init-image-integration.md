# Reliability gap: CPU cgroup integration checks use the release guest

## Impact

The CPU-limit and CPU-share tests in `TestCLIRunCommand` build and install the
current `vminit:latest` guest as part of the integration target, but then start
their containers with the stock `container` default guest image. The default is
the intentionally versioned upstream release guest rather than the guest built
from the checked-out source. A released guest that predates the current cgroup
v2 CPU bridge can reject `cpu.max` configuration or report the default
`cpu.weight` value even though the current runtime implementation is correct.

The resulting test failure is not a CLI data-loss regression: the runtime
configuration contains `cpuShares`, and the current guest applies the expected
cgroup v2 weight. The test needs to validate the source-matched guest that the
integration target already installed.

## Required Apple behavior

- Keep the production `container` default guest image versioned and unchanged.
- Have each CPU cgroup integration check explicitly select `vminit:latest`,
  matching the guest installed by the integration setup.
- Retain the existing `cpu.max` and `cpu.weight` assertions.

## Non-goals

- Change the public `container run` default image.
- Alter container runtime configuration, cgroup mapping, or Docker Compose behavior.
- Treat an arbitrary external guest image as equivalent to the checked-out
  source tree.
