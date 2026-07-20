# Reliability gap: CLI integration test width follows host core count

## Impact

The CLI integration target used `hw.physicalcpu` as its default concurrent-test
width. On high-core-count Apple-silicon Macs, that schedules many simultaneous
VM-backed `container run` requests through one local API server. The server can
become saturated and clients then fail with an XPC `containerCreate` timeout.
The failure is a test-harness scheduling problem: it does not represent a
runtime feature failure, and retrying at the same width is not reliable.

## Required Apple behavior

- Keep the complete warmup, concurrent, and serial test partition; do not skip
  tests or weaken their assertions.
- Use a deterministic serial default suitable for Virtualization-backed guests
  rather than a host-CPU-derived value.
- Retain an explicit `PARALLEL_WIDTH` override for developers and CI systems
  that have demonstrated a safe higher or lower capacity.

## Non-goals

- Change the API server, XPC timeout, Linux guest runtime, or product CLI
  behavior.
- Introduce Docker Compose-specific behavior into `container`.
- Claim that arbitrary concurrency levels are supported on every Mac.
