# Pull request: bridge no-new-privileges into the Linux runtime

## Summary

- Add the generic `--security-opt` surface to `container run` and
  `container create`.
- Parse Compose-compatible colon syntax and Docker CLI-compatible equals
  syntax for `no-new-privileges`.
- Store the setting in `ProcessConfiguration` and apply it to the existing
  Containerization OCI process primitive.
- Reject unsupported or malformed options before runtime side effects.
- Add unit, command-parsing, serialization, and runtime-configuration tests;
  update the command reference.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Existing `noNewPrivileges` primitive. |
| `apple/container` | Generic CLI/configuration adapter. |
| `container-compose` | Separate follow-up renderer. |

The change does not mention Compose in product code and does not create a
Compose-specific runtime protocol. The follow-up renderer uses
`--security-opt no-new-privileges:true` from the Compose field.

## Code map

- `Sources/ContainerResource/Container/ProcessConfiguration.swift` persists
  the process security bit with a compatible default for existing state.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` exposes the
  repeatable CLI option.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` validates and
  maps the accepted values while building the initial process.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` applies the bit
  to `LinuxProcessConfiguration`.

## Validation

```sh
swift test --disable-automatic-resolution --filter \
  'ParserTest|ContainerRunCreateCommandTests|ProcessConfigurationPrivilegeTests|RuntimeServiceHostsTests'
make check
```

The follow-on `container-compose` parity fixture uses Docker Compose V2
`config --format json` plus `container-compose --dry-run up` to confirm the
same `security_opt` value reaches this generic CLI option. A live Docker Engine
assertion runs whenever a daemon is available.

## Non-goals

This is not an implementation of arbitrary Docker `security_opt` forms or
full privileged isolation. It is one auditable, cross-Linux-guest security
primitive that works from macOS.

## Commit tracking

The immediate follow-up linkage commit records the exact implementation commit
after local validation completes.
