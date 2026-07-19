# Pull request: support unconfined Linux guest system paths

## Summary

- Add the narrowly scoped `systempaths:unconfined` / `systempaths=unconfined`
  security option to `container run` and `container create`.
- Persist the resulting generic `unconfinedSystemPaths` setting with a safe
  decode default for existing state.
- Clear the existing Containerization OCI masked and read-only guest-path
  lists, while leaving capability selection unchanged.
- Extend exact `container run --help` text and add parser, serialization,
  command, runtime, and matched-guest integration coverage.

## Apple-shaped boundary

- `apple/containerization`: no source change. Its
  `LinuxContainer.Configuration.maskedPaths` and `.readonlyPaths` are the
  existing generic primitive.
- `apple/container`: generic configuration, CLI parsing, and Linux guest
  runtime adapter. No Compose library, Docker type, or host-specific policy is
  introduced.
- `container-compose`: a separate follow-up adapter translates Compose
  `security_opt` spelling to this CLI option and owns Compose parity fixtures.

The generic model states the runtime outcome (`unconfinedSystemPaths`), not the
caller that requested it. Clearing guest-path overrides is deliberately
independent of `privileged` and capabilities, so a caller can retain
`--cap-drop ALL`.

## Code map

- `Sources/ContainerResource/Container/ContainerConfiguration.swift` persists
  `unconfinedSystemPaths` and defaults a missing serialized field to `false`.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` documents the two
  accepted option separators in live CLI help.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` centralizes
  supported security-option parsing and rejects invalid values before runtime
  side effects.
- `Sources/Services/ContainerAPIService/Client/Utility.swift` maps the generic
  parsed value into container configuration.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` clears only the
  guest OCI masked/read-only path lists.

## Validation

```sh
swift test --disable-automatic-resolution --filter \
  'ParserTest|ContainerRunCreateCommandTests|ContainerConfigurationSystemPathTests|RuntimeServiceHostsTests'
CONTAINER_CLI_PATH="$PWD/bin/container" \
  CLITEST_SCRATCH_ROOT="$PWD/.test-scratch" \
  swift test --skip-build --filter 'TestCLIRunCommand/testRunCommandUnconfinedSystemPaths'
make test
make coverage-unit
make check
```

The matched macOS guest integration test runs a default container and one with
`systempaths=unconfined`, both using `--cap-drop ALL`. It confirms that the
default `/proc/sys` mount is read-only, the unconfined container has no added
`/proc/sys` read-only override, and the unit runtime test confirms the empty
capability bounding set remains unchanged. The collected unit coverage report
is `coverage-reports/unit/coverage-summary.json`; the repository-wide line
figure is 36.44%, while every new branch has focused coverage.

The separate `container-compose` follow-up adds a Compose YAML fixture, Docker
Compose V2 config parity confirmation, and direct runtime mapping verification.

## Compatibility and non-goals

Existing container configuration files decode without the new field and retain
the prior confined behavior. The option does not grant host access, elevate
guest capabilities, implement profile labels, or support Windows-specific
security options.

## Commit tracking

- `container` code and tests: `687c2beec63e3de5a76f50ff81ac394f14dbf35b`
  (`feat(security): support unconfined guest system paths`).
- `containerization` code change: none; the implementation uses its existing
  generic guest path-list controls.
