<!-- markdownlint-disable MD013 -->

# Test-only recipe drift invalidates unchanged compiled layers

## Motivation and context

After the corrected timeout fixture passed the full HTTP-client host suite, importing published ArgumentParser, foundation, Containerization and EngineAPI archives failed because the recipe includes all dependency test patches. The only additional difference in all four authenticated manifests is the reviewed AsyncHTTPClient macOS fixture patch. Production compilation inputs, pins, toolchains and archive contents are unchanged.

## Required behavior

Admit only the exact old/new patch hashes alongside the existing exact verifier update. Reject unknown or reversed fixture edits, partial verifier transitions, inventory changes and unrelated production recipe differences. Preserve the published producer identity and both recipe fingerprints in consumption evidence.
