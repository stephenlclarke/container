# Upstream sync: Apple `main` through `d1d76353`

## Context

Apple `container` advanced after the fork's Phase 4 release candidate with the
macOS-relevant builder fix from apple/container#2002:

- `d1d763530df3c6a326dbae7f0c0a59a335808045`
  (`Fix BuilderStart race, parallelize container build tests. (#2002)`).

The change closes apple/container#2001. Concurrent cold-start builds could both
observe that the shared BuildKit container was absent, then race to create it.
The losing build received `ContainerizationError.exists` and failed even though
the winning build had created the builder it needed.

## Required behavior

- Preserve Apple ancestry through `d1d76353`.
- Treat an `exists` error from the builder-container create race as success and
  continue through the idempotent BuildKit bootstrap path.
- Preserve all fork-specific named-builder, SSH-forwarding, lifecycle,
  provenance, and Compose integration behavior.
- Adopt Apple's parallel build-test layout while keeping builder lifecycle
  tests serialized.
- Revalidate the downstream Compose source graph before publishing Phase 4.

## Reproduction

Apple issue #2001 reproduces the failure by running the build integration tests
in the parallel pass:

```sh
rm -rf ./test-logs ./test-temp
make APP_ROOT=./test-data LOG_ROOT=./test-logs \
  PRESERVE_KERNELS=true all test integration
```

Before `d1d76353`, overlapping builds can report:

```text
Error: internalError: "failed to create container"
(cause: "exists: \"container already exists: buildkit\"")
```

Apple's fix catches only `ContainerizationError.exists` around builder
creation. Other create failures still propagate.

## Merge reconciliation

The source fix merged without conflict. Apple deleted
`Tests/IntegrationTests/Build/TestCLIBuilderSerial.swift` and the temporary
`withBuilder`/`withBuilderLock` fixture helpers while moving ordinary build
tests into parallel suites. The fork had modified that deleted file and still
used `withBuilderLock` in its named-builder lifecycle test.

The signed merge accepts Apple's deleted test file and removes the obsolete
lock call from the named-builder test. That test remains inside
`TestCLIBuilderLifecycleSerial`, so its serialized lifecycle boundary is
preserved without retaining the removed global fixture lock.

## Validation gate

```sh
make check
make test
git diff --check
test -z "$(git ls-files -u)"
```

Verified on this Apple-silicon Mac:

- Swift formatting and Hawkeye license checks passed;
- the complete test bundle, including Apple's parallel build suites, compiled;
- 1,134 Swift tests in 131 suites passed, plus 94 XCTest cases;
- the merge has no unresolved entries or whitespace errors.

The downstream Compose pin, live builder exercise, Docker Compose V2 parity,
Sonar, Current package, and stable release gates remain required before the
Phase 4 release is complete.

## Commit tracking

- Apple issue: <https://github.com/apple/container/issues/2001>
- Apple pull request: <https://github.com/apple/container/pull/2002>
- Apple upstream commit:
  `d1d763530df3c6a326dbae7f0c0a59a335808045`.
- Signed ancestry merge:
  `1bc31674629287f3386637db4c6d8652dc36602a`.
