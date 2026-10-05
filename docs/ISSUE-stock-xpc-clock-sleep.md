# XPC timeout teardown aborts in the optimized SDK consumer

## Description

Devcontainer's signed stock build aborts while a successful XPC reply cancels the request timeout. Two retained release campaigns report `freed pointer was not the last allocation`, with `swift_task_dealloc` followed by the timeout child in `XPCClient.send(_:responseTimeout:)`. Removing a newly introduced application sleep specialization did not resolve the failure.

## Expected behavior

Successful replies cancel the timeout and return normally.

## Actual behavior and environment

The optimized Apple Swift 6.4 combined program aborts during startup against Apple Container 1.4.1. [Swift issue 86204](https://github.com/swiftlang/swift/issues/86204) documents this failure shape for generic sleep specializations across modules. The compiler interaction is suspected; the actual fixed SDK still requires validation.

## Compatibility and remaining validation

Keep Apple's 1.4.1 implementation except the timeout sleep call. Preserve nested dependency files and all lower released artifacts. Exercise optimized real-XPC quick replies with long timeouts and the signed consumer's full runtime qualification before SDK publication is accepted.
