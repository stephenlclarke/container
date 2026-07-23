# Pull request handoff: preserve matched stable Homebrew formula ownership

## Proposed title

`fix(homebrew): preserve matched stable formula ownership`

## Summary

Prevent Container main prebuilt builds from replacing the runtime half of the
matched container-compose stable Homebrew pair.

Main builds still produce immutable prerelease archives and provenance. Only
the shared tap mutation is suppressed. Named release lanes retain their
distinct formula publishing behavior.

## Why

The Container main workflow and the container-compose stable workflow both
wrote `Formula/container.rb`. Their independent completion order allowed a
successful main build to replace a newly promoted stable runtime without
updating the paired Compose formula.

The supported Homebrew path is a matched stack, so stable formula ownership
belongs to the container-compose release transaction.

## Scope

- `.github/workflows/prebuilt-binaries.yml`
  - emits an explicit per-lane tap-promotion decision;
  - prevents the main lane from entering the tap mutation chain;
  - preserves named release-lane formula publishing.
- `scripts/test_update_homebrew_formula.py`
  - locks the ownership decision and workflow gate.
- `docs/upstream/ISSUE-homebrew-stable-formula-ownership-20260723.md`
  - records the reproduced race and acceptance criteria.
- `docs/upstream/PR-homebrew-stable-formula-ownership-20260723.md`
  - supplies this upstream-ready handoff.

## Commits

Apply the signed source commit:

```text
9e9f55d fix(homebrew): preserve matched stable formula ownership
```

Apply the following signed documentation commit for the issue and handoff:

```text
docs(homebrew): hand off stable formula ownership
```

## Validation

```bash
actionlint .github/workflows/prebuilt-binaries.yml
python3 -m unittest discover scripts -p 'test_update_homebrew_formula.py'
ruby -c Formula/container.rb
make check
```

Expected results:

- actionlint reports no workflow errors;
- all focused Homebrew tests pass;
- the formula template has valid Ruby syntax;
- the full repository check passes.

## Compatibility and risk

The package archive, release tag, attestation, and workflow artifact behavior
is unchanged. Only the shared tap side effect is disabled for `main`.

Named release branches continue to use unique formula names and preserve their
existing behavior.

## Rollback

Revert the source commit to restore main-lane tap mutation. Before doing so,
choose a distinct main formula name; restoring both workflows as writers of
the stable formula would reintroduce the race.

## Checklist

- [x] Reproduced against the fork
- [x] Minimal workflow-only production change
- [x] Focused regression coverage
- [x] Full repository validation
- [x] No Windows-specific behavior
- [x] macOS/Homebrew behavior documented
- [x] Issue and pull-request handoff included

## Tracking issue

See
`docs/upstream/ISSUE-homebrew-stable-formula-ownership-20260723.md`.
