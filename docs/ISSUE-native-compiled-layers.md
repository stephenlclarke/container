<!-- markdownlint-disable MD013 -->

# Consume published compiled Swift dependencies in native Container production

## Current and expected behavior

The normal optimized Container build still compiles its dependency packages from source. A warm Bazel cache can avoid repeated compiler work locally, but that does not establish that a fresh machine consumed the exact released dependency binaries. The source-mode build and unit checks must remain available for hosted quality analysis and ordinary development.

Native production should release and import a dependency-first chain: a macOS 12 ArgumentParser tool layer, foundation packages, Containerization, then EngineAPI. Each layer needs its exact source pins, compiler and recipe, successful configured outputs, original source-test reports, and published lower archive identities. The existing runtime-smoke build must use those imports and prove that all eight Container executables link their selected archives with no dependency source compiler or archive actions. Missing assets, changed inputs or source fallbacks must fail qualification.

## Evidence and remaining work

Development overlays demonstrated the full graph with 37 imported repositories, eight Container links and no dependency compile, archive or link actions. This is a feasibility proof, not a published layer or qualified release. The maintained producer, importer and consumer admission checks must pass source review and focused tests before clean dependency-first publication. The final runtime, VM, coverage, benchmarks, notarization, hosted quality and release checks remain required.
