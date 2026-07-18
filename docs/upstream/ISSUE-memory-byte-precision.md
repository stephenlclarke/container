# Compatibility gap: byte-precise container memory limits

## Surface

Generic `container run/create --memory VALUE` resource configuration, including
values expressed in bytes.

## Problem

The CLI parser already recognized byte-sized values, but the resource path
converted every configured and explicit value to an integral MiB count before
storing `ContainerConfiguration.Resources.memoryInBytes`. A valid value such as
`209715201b` therefore became `209715200` bytes, one byte below the requested
Docker-compatible hard limit.

`container-compose` normalizes Compose `mem_limit` to its exact byte count and
passes that count to this generic CLI. The truncation was therefore observable
through Compose even though its adapter did not alter the value.

## Required behavior

- Preserve exact byte values from `--memory` through the generic resource
  configuration model.
- Preserve an exact byte-valued configured default.
- Retain existing unit suffixes and minimum-memory validation.
- State byte granularity in `run` and `create` help text.

## Apple-shaped implementation

This is a generic `apple/container` parser/configuration correction. It does
not mention Compose in product code and requires no new `containerization`
primitive: the existing Linux container configuration already stores memory as
`UInt64` bytes and projects that exact value to the OCI Linux memory limit.

The implementation commit is
`e2ac60b4d8c14813abc8779ee9d1246078c8040e`:

- `Flags.swift` corrects the public option description.
- `Parser.resources` now uses byte conversion for both defaults and explicit
  values.
- Parser tests cover an exact non-MiB flag and default value.
- The command reference matches the actual CLI semantics.

## Scope and non-goals

- Apply the generic hard memory limit to the macOS-hosted Linux guest.
- Do not change builder-memory semantics, which retain their separate
  implementation and documented granularity.
- Do not add Windows-specific resource handling.
- Fractional CPU quota, CPU period/quota/realtime controls, cpuset,
  swappiness, and OOM-killer control remain separate runtime gaps.

## Upstream handoff condition

The code commit has been replayed onto the current `fork/main` base. Before
offering it to Apple, rerun the parser tests, `make check`, and the
coverage-unit gate on the final base, then update the commit link if it must be
replayed again.
