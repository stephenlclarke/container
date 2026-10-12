# Candidate dependency graph must consume the corrected connection lifetime

## Steps to reproduce

Run the full SDK macOS coverage suite using the earlier candidate SDK and transport. Closing a guest client before its connection runner starts can release an unfinished NIO async writer. The original and activation-only failures, thread traces and exact source identities are retained with the performance/parity checkpoint.

## Problem description

The SDK and gRPC fixes are published on Stephen-owned candidate branches, but Container must select the same revisions in both its manifest and resolved graph. Previously published native Foundation and SDK proofs remain historical evidence for their recorded graph. Updating a dependency must not silently admit those older binaries or rebuild the unchanged ArgumentParser baseline.

The local Linux test image also lacks Python, although the existing Linux coverage export uses it. The bounded preflight retained that refusal before expensive tests.

## Expected behavior

Consume the corrected exact source revisions, preserve all unrelated pins, reuse the unchanged ArgumentParser release and require fresh affected Foundation, SDK and Engine API qualification. Install Python in the local Linux test image so the maintained coverage tools are available. Reuse all unchanged published benchmark baseline artifacts and measurements.

## Environment

The qualification host is the local Apple silicon Mac. The SDK and transport revisions are recorded in the [implementation handoff](PR-connection-dependency-consumption.md). No Apple branch, issue or pull request is published by this change.
