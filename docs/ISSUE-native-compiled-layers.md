<!-- markdownlint-disable MD013 -->

# Consume published compiled Swift dependencies in native Container production

## Current and expected behavior

The normal optimized Container build previously compiled its dependency packages from source. A warm Bazel cache could avoid repeated compiler work locally, but it did not establish that a fresh machine consumed the exact released dependency binaries. The source-mode build and unit checks remain available for hosted quality analysis and ordinary development.

Native production should release and import a dependency-first chain: a macOS 12 ArgumentParser tool layer, foundation packages, Containerization, then EngineAPI. Each layer needs its exact source pins, compiler and recipe, successful configured outputs, original source-test reports, and published lower archive identities. The existing runtime-smoke build must use those imports and prove that all eight Container executables link their selected archives with no dependency source compiler or archive actions. Missing assets, changed inputs or source fallbacks must fail qualification.

## Evidence and remaining work

The ArgumentParser, foundation, Containerization and EngineAPI layers were produced, source-test qualified, published and download-verified in dependency order. Normal import validates all four releases and supplies 37 canonical repositories; optimized runtime smoke at `db4088b1` verified eight links and no imported compile, archive or link actions. Instrumented integration then failed because the action verifier rejected Bazel's input-free `BaselineCoverage` metadata. The failed qualification and guarded host recovery remain recorded. A narrow coverage-only action check and an authenticated two-file recipe transition preserve the original published archive identities and proofs without rebuilding them. The final coverage, benchmarks, notarization, hosted quality and release checks still require a new complete run.
