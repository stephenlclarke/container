# Pull request: preserve generic memory limits at byte precision

## Summary

- Preserve exact byte values for `container run/create --memory`.
- Preserve byte-valued configured defaults instead of converting through MiB.
- Correct `run` and `create` help and command-reference wording to say byte
  granularity.
- Add focused parser tests for a value one byte above 200 MiB.

## Apple-shaped boundary

- `apple/containerization`: no source change. Its Linux container configuration
  already stores a byte count and emits it as the OCI memory limit.
- `apple/container`: generic CLI/parser transport correction only.
- `container-compose`: separate consumer that already passes normalized
  `mem_limit` byte values through this generic flag.

No Compose-specific type, protocol, command, or host-side security behavior is
introduced in the fork.

## Code map

- `Sources/Services/ContainerAPIService/Client/Parser.swift` uses
  `memoryStringAsBytes` and `MemorySize.toUInt64(unit: .bytes)` when creating
  the generic resource model.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` reports the true
  byte-granular contract.
- `Tests/ContainerAPIClientTests/ParserTest.swift` proves exact byte retention
  for both explicit and configured values.
- `docs/command-reference.md` refreshes the public run/create documentation.

## Validation

Completed locally:

```sh
swift test --disable-automatic-resolution --filter ParserTest
make check
make coverage-unit
.build/debug/container run --help
.build/debug/container create --help
git diff --check
```

The focused parser suite passed 189 tests. The coverage-unit gate passed 940
unit tests and generated its report successfully. The project does not enforce
a repository-wide coverage percentage minimum; the added tests directly execute
the changed default and explicit conversion paths.

The downstream Compose parity fixture additionally compares Docker Compose V2
config output with `container-compose --dry-run up` using
`mem_limit: 209715201b`.

## Review checklist

- [ ] Confirm `e2ac60b4d8c14813abc8779ee9d1246078c8040e` still parents the
  current upstream base before opening the Apple PR.
- [ ] Confirm `--memory 209715201b` persists exactly as `209715201` bytes.
- [ ] Keep builder-memory behavior out of this narrowly scoped change.
- [ ] Confirm the Compose fixture remains a consumer of the generic flag, not
  a dependency of this fork.

## Non-goals

- Fractional CPU quota and other cgroup CPU controls.
- Memory swappiness, OOM-killer configuration, or memory-reservation policy.
- Windows resource or isolation behavior.
