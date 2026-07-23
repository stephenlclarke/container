# Homebrew CI fails after template archive retention expires

## Context

The maintained Container formula template references the immutable archive
created by its last source-branch packaging run. GitHub can retire that
historical release and its assets under the repository's retention policy
without changing the formula source.

The Homebrew workflow then fails before testing any current package:

```console
brew audit --formula --strict --online stephenlclarke/container/container
```

Run
[`30046875470`](https://github.com/stephenlclarke/container/actions/runs/30046875470)
reproduced the failure after the referenced
`homebrew-main-98-d42bf04af959` archive returned HTTP 404.

## Required behavior

- Keep formula generation, Ruby syntax, service metadata, and strict Homebrew
  auditing mandatory.
- Fetch, install, and test the template package while its immutable archive is
  retained.
- Treat an archive removed by release retention as a visible, non-failing
  template condition.
- Continue to require live archive and formula tests for active stable and
  Current releases in their downstream release gates.

## Resolution

The signed commit
[`02a3d0e2e848e6400fa6a7c55004c7ef9d88c9f7`](https://github.com/stephenlclarke/container/commit/02a3d0e2e848e6400fa6a7c55004c7ef9d88c9f7)
runs the maintained template through the offline strict audit, then probes its
archive URL. Fetch and installation run only when the retained archive is
available. A retired archive produces an annotated workflow notice instead of
masking the formula-source checks with an unrelated HTTP 404.

A focused regression prevents restoration of the online audit and requires
both archive-dependent steps to use the retention result.

## Validation

```console
actionlint .github/workflows/homebrew.yml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover scripts \
  -p 'test_update_homebrew_formula.py'
ruby -c Formula/container.rb
make check
```

Observed on Apple silicon macOS:

- The workflow passed `actionlint`.
- All three formula and workflow regressions passed.
- The formula passed Ruby syntax validation.
- Formatting and license checks passed.
- The active `0.8.0` stable Container and Compose formula tests passed against
  retained release assets.

## Commit tracking

- Workflow and regression:
  `02a3d0e2e848e6400fa6a7c55004c7ef9d88c9f7`.
