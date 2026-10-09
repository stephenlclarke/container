# Pull request handoff: restore the 63-character native container ID limit

## Summary

`ManagedContainer.nameValid` had been widened from 63 to 255 bytes. Native
`--name` is the container ID, and that ID is used as a hostname on the default
network, so names over the DNS label limit are not valid. Restore the 63-byte
check without changing the existing character pattern or relaxing the upstream
regression.

## Changes

- Restore the production validator's 63-byte maximum.
- Restore the 63/64 boundary regression test.
- State the limit in shared CLI help and both `container create` and
  `container run` command-reference entries.
- Preserve the existing benchmark record and its failed-run evidence; this
  change does not retroactively mark that run compatible.

## Compatibility and risks

This rejects native container IDs from 64 through 255 ASCII characters that
the fork previously accepted. Docker API names use the separate `dockerName`
field and are not changed here. The limit matches use of the native ID as a
hostname label.

## Validation

- Fail-before evidence: the retained `ContainerResourceTests` run for candidate
  source `052a5be4` accepted a 64-character name where the test expected
  rejection.
- Pass-after: `Tools/bazel/run.sh test @swiftpkg_container//:ContainerResourceTests.rspm
  --nocache_test_results` passed; the test log reports 270 tests in 45 suites,
  including `nameValidRejectsNamesLongerThan63Characters`.
- The Bazel invocation took 52.244 seconds (44.51-second critical path),
  rebuilt the focused target and dependencies, and reported 995 disk-cache
  hits plus 240 action-cache hits. The test target itself ran in 2.1 seconds.
- No runtime, build qualification, parity timing, or publication is included
  in this change.
