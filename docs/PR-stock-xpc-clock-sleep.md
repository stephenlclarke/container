# fix(xpc): avoid generic sleep in stock SDK timeout

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The optimized consumer aborts when it cancels a successful request's timeout child. See [the issue](ISSUE-stock-xpc-clock-sleep.md).

## Modifications

Replace `Task.sleep(for: responseTimeout)` with `ContinuousClock.sleep(until:)` using the same duration and default tolerance. Keep the task group, checked continuation, reply handling, cancellation and error policy unchanged. The branch remains based on Apple's exact 1.4.1 source; the published SDK must identify this derivative's own revision.

## Testing

- [x] Source parsing and strict Swift formatting passed.
- [x] Documentation lint passed with long paragraphs and the existing README HTML retained.
- [ ] Optimized consumer regression and runtime qualification; executed by the Devcontainer release workflow before artifact publication.

Both original signed-consumer failures are retained as controls. The consumer's optimized real-XPC regression, compiled SDK provenance, full package checks and runtime qualification remain required; no runtime success is claimed by this source-only change.

## Compatibility and risk

No public API or nested dependency graph changes. This does not repair the separate behavior of requests whose reply never arrives. The direct clock call bypasses the generic sleep wrapper implicated by the upstream report, but only actual consumer validation can confirm the crash is resolved.
