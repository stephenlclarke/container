# Export the Container client SDK from the qualified native dependency graph

## Prerequisites and scope

This is a local implementation handoff; no upstream issue or pull request has been submitted. Container source checkpoint `22109f1ba7d012af1aa7c0278affe321c6bb26c5` selects SDK `e4e39e2a197730d64a35b5d5116af6f3b3915c4b` through its published native archive, evidence and portable-proof locks. The existing four-layer admission passes at that checkpoint. This change does not modify those locks or package pins.

## Steps to reproduce

1. Admit the existing native ArgumentParser, Foundation, Containerization and Engine API layers.
2. Ask the native producer to export `container-sdk` for a Compose consumer.
3. Observe that the original producer accepts only the four dependency groups, despite the maintained `container_sdk_outputs` aspect already selecting Container modules.

## Expected behavior

Export Container's compiled client closure from the same configured native graph. Bind Container's own exact clean commit without adding a fictitious Container entry to `Package.resolved`. Retain all four authenticated lower identities, the original native format and portable source/build/test proof.

## Implementation

The export-only group uses the existing `//:container-executables` closure and `container_sdk_outputs` aspect. The archive includes only reached Container package outputs and metadata; lower binaries remain references. Its owner and target are Container's own commit. Production imports the complete four-layer chain, while default runtime importer groups remain unchanged to prevent self-import.

Qualification requires 15 finite existing host test targets covering the client, XPC, commands, resources, persistence, build and related host utilities. It excludes VM `IntegrationTests` and does not expand the existing dependency test suite. Missing, filtered, cached or contradictory evidence continues to fail existing admission.

## Validation and remaining work

Deterministic producer/evidence/format tests pass 62 cases; existing importer/consumer tests pass 21 cases. New regressions cover own-source identity, all four lower replacements, production selection, the source client/XPC inventory and portable proof replay. No Swift compilation, VM operation, publication or native qualification was executed for this change.

The export changes recipe hashes. The finite four-file recipe transition is implemented; root review and actual lower-artifact readmission from the new immutable checkpoint remain required. Actual source-mode client qualification, SDK production/publication and separate Compose native consumer admission remain pending. Historical binaries, benchmarks and failed evidence stay unchanged.
