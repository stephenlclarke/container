# fix(xpc): use direct clock deadlines for response timeouts

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

An optimized Compose consumer aborts in the timeout task's async resume frame in `XPCClient.send`. The failure matches the cross-module sleep-specialization failure documented in [swiftlang/swift#86204](https://github.com/swiftlang/swift/issues/86204). See the [issue handoff](ISSUE-xpc-response-deadline-sleep.md) for the exact consumer and retained failure evidence.

## Implementation and Compatibility

Use `ContinuousClock.sleep(until: clock.now.advanced(by: responseTimeout))` inside the existing detached timeout task. Preserve the full `Duration`, monotonic timing, cancellation, exactly-once response completion and existing error text. No public API, wire protocol, resource lifecycle or deployment-target change is required. Do not replace the frozen published baseline.

Regression tests repeatedly expire no-reply deadlines and then reuse the client; successful replies repeatedly cancel both short and long deadlines. Existing tests cover caller cancellation, connection close and late replies. A uniform unit-test link alone cannot prove the cross-module compiler workaround, so the optimized Compose executable with prebuilt dependencies remains the decisive regression.

## Testing

- [x] Focused optimized Container XPC suite: 28 cases, zero failures or skips, 22.126 seconds; retained `candidate-compose-attached-output/xpc-units-v1/acceptance.json` at code checkpoint `145955284a54c61a2e80b5fd677439b961d3e437`, using published native lower layers.
- [ ] Optimized Compose prebuilt-layer runtime preflight passes.
- [x] Added regression tests and updated documentation.

Actual optimized Compose link validation is pending; this handoff is not a successful release or full parity claim. No Apple submission has been made. Remaining risks are the cross-module link and other unrelated runtime failures, which must remain visible if encountered.
