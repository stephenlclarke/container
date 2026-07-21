# Pull request: add a generic clear-entrypoint process override

## Summary

- Add `--clear-entrypoint` to `container run` and `container create`.
- Resolve the initial process from the image `Cmd` while intentionally omitting the image `Entrypoint`.
- Reject an ambiguous combination with `--entrypoint`.
- Document the new CLI option and add parser regression coverage.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | No change; the existing process configuration receives the resolved command. |
| `apple/container` | Generic CLI and process-resolution adapter. |
| `container-compose` | Separate renderer maps only Compose `entrypoint: []` to this generic option. |

The product code has no Compose dependency. The CLI can be used by any macOS caller that needs OCI-style clearing of an image entrypoint.

## Code map

- `Sources/Services/ContainerAPIService/Client/Flags.swift` adds the documented Boolean CLI flag.
- `Sources/Services/ContainerAPIService/Client/Parser.swift` resolves the image command without inheriting the image entrypoint and rejects conflicting overrides.
- `Tests/ContainerAPIClientTests/ParserTest.swift` covers the retained image command and conflicting-flag error.
- `docs/command-reference.md` documents the option for both `run` and `create`.

## Validation

```sh
swift test --disable-automatic-resolution --filter ParserTest --no-parallel
make check
```

The companion `container-compose` slice compares `command: []` and `entrypoint: []` normalization against Docker Compose V2 and uses a Compose YAML integration fixture whose image has an entrypoint that would fail unless it is correctly cleared.

## Compatibility

The new flag is opt-in. Existing `--entrypoint`, image-entrypoint, image-command, and positional-command resolution paths are unchanged.

## Non-goals and risks

This is not a Docker CLI compatibility layer for every process override. It introduces one macOS-implementable OCI process form. The runtime value is validated by the companion Compose fixture after the pinned fork revision is consumed.

## Commit tracking

- `container` code, tests, and command-reference update: introduced by this PR as `feat(process): clear image entrypoint`; the companion Compose handoff records the exact dependency revision it pins.
- `containerization` code change: none.
- `container-compose` follow-up: pending commit; it will reference the final `container` revision.
