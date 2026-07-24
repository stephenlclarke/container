# Pull request handoff: synchronize Apple `container` main through `d1d76353`

## Summary

Merge Apple's fix for the concurrent BuildKit cold-start race and its parallel
build-test layout into the macOS fork. The runtime change remains Apple's code;
the only fork reconciliation removes a call to the test fixture lock that Apple
deleted while retaining the fork's named-builder lifecycle test in the
serialized lifecycle suite.

## Apple-shaped boundary

- Retains `d1d76353` as the second parent of one signed ancestry merge.
- Keeps Apple's `ContainerizationError.exists` handling unchanged.
- Keeps all other builder-create errors observable.
- Accepts Apple's parallel test files and deleted serialized build-test files.
- Does not introduce a Compose-specific conditional into the Apple runtime.
- Limits reconciliation to the fork-only named-builder lifecycle test.

## Code map

- `Sources/ContainerCommands/Builder/BuilderStart.swift`
  - continues bootstrap when a concurrent build already created BuildKit.
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift`
  - preserves `ContainerizationError` so the caller can distinguish `exists`.
- `Sources/ContainerTestSupport/BuildFixture.swift`
  - adopts Apple's removal of the global builder fixture lock.
- `Tests/IntegrationTests/Build/TestCLIBuilder*.swift`
  - adopts Apple's parallel ordinary-build suites and serialized lifecycle
    suite.
- `Tests/IntegrationTests/Build/TestCLIBuilderLifecycleSerial.swift`
  - preserves the fork's named-builder lifecycle test without the deleted
    `withBuilderLock` helper.
- `docs/upstream/ISSUE-apple-main-sync-20260724.md`
  - records the upstream bug, reproduction, resolution, and validation.
- `docs/upstream/PR-apple-main-sync-20260724.md`
  - provides this pull request handoff.

## Validation

```sh
make check
make test
git diff --check
test -z "$(git ls-files -u)"
```

Verified on this Apple-silicon Mac:

- Swift formatting and Hawkeye license checks passed;
- the complete test bundle, including the new parallel build suites, compiled;
- 1,134 Swift tests in 131 suites passed, plus 94 XCTest cases;
- the merge has no unresolved entries or whitespace errors.

Docker Compose V2 parity, the exact downstream Container pin, live builder
validation, Sonar, and release packaging are intentionally enforced by the
Compose repository after this fork commit is published.

## PR template

### Type of change

- [x] Upstream maintenance
- [x] Bug fix
- [x] Test concurrency update
- [x] Documentation update
- [ ] Breaking change

### Motivation and context

Keep the macOS fork aligned with apple/container#2002 and prevent concurrent
first builds from failing merely because another build won the shared BuildKit
container creation race.

### Testing

- [x] Fork formatting and license checks
- [x] Complete fork unit suite
- [x] Upstream parallel integration suites compile
- [x] Conflict and whitespace checks
- [ ] Downstream Compose unit and live integration suites
- [ ] Docker Compose V2 parity
- [ ] Exact Sonar and release gates

### Reviewer notes

Review the merge-parent relationship first. The runtime fix is unchanged from
Apple. The only manual reconciliation is the removal of `withBuilderLock` from
the fork-only named-builder test because Apple removed that helper; the test
still belongs to the serialized lifecycle suite.

## Commit tracking

- Apple issue: <https://github.com/apple/container/issues/2001>
- Apple pull request: <https://github.com/apple/container/pull/2002>
- Apple upstream commit:
  `d1d763530df3c6a326dbae7f0c0a59a335808045`.
- Signed ancestry merge:
  `1bc31674629287f3386637db4c6d8652dc36602a`.
