# Optimized XPC response deadlines can abort the process

## Prerequisites and scope

Existing upstream compiler issue [swiftlang/swift#86204](https://github.com/swiftlang/swift/issues/86204) was checked. This is a local handoff; no Apple issue or pull request has been submitted. The observed consumer is Container Compose `085da2fb9e9a0f62b56ddb546b001f64c36e55f8` using its published prebuilt Container SDK, not a reproduction against stock Apple main.

## Steps to reproduce

1. Build the optimized Compose candidate with its frozen prebuilt Container SDK and dependency archives.
2. Start the isolated published Container runtime and invoke the retained one-service `compose up -d` preflight.
3. Observe the process abort before benchmark timings are collected.

## Problem description

The process reports `freed pointer was not the last allocation` and aborts in `swift_task_dealloc`. Its image offset `0x9ebea4` maps to the timeout task's async resume function in `XPCClient.send`, immediately after `Task.sleep(for: responseTimeout)`. The retained symbol inventory contains several local resume bodies for the cross-module `Clock.sleep(for:)` specialization. This is strongly consistent with compiler issue #86204; it does not establish the exact linker allocation mismatch independently.

A response deadline should either return the server reply or throw the existing timeout/cancellation error without corrupting the task frame. Switching to `ContinuousClock.sleep(until:)` avoids the reported specialization while preserving the existing response-result race handling.

## Environment and evidence

- macOS 27, Apple silicon; Swift 6.4.0.34.1, Xcode 27.0 build 27A266a.
- Candidate and published SDK records name the same compiler and SDK; a simple compiler-version mismatch was not established.
- Local retained evidence: `candidate-compose-attached-output/measurement-v4`, crash reports dated 2026-10-12 01:51, and the separate successful native recovery receipt `recovery-native-v2/acceptance.json`.
- Published baseline binaries and measurements remain unchanged and were not rebuilt or rerun.

## Remaining validation

The focused optimized XPC suite passed all 28 cases without failures or skips at code checkpoint `145955284a54c61a2e80b5fd677439b961d3e437` in 22.126 seconds. The actual prebuilt Compose link must still pass before the candidate is accepted. This fix does not resolve the separate stopped-copy performance gap or establish complete Compose parity.
