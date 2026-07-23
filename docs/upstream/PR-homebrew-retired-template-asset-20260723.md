# Pull request handoff: tolerate retired formula template assets

## Proposed pull request

`fix(ci): tolerate retired formula template assets`

This handoff covers the signed source commit
[`02a3d0e2e848e6400fa6a7c55004c7ef9d88c9f7`](https://github.com/stephenlclarke/container/commit/02a3d0e2e848e6400fa6a7c55004c7ef9d88c9f7).

## Summary

Keep all source-level Homebrew checks mandatory while making the historical
template archive probe aware of GitHub release retention. The workflow still
fetches, installs, and tests the template whenever its immutable archive
exists.

## Apple-shaped boundary

- Changes only the Homebrew workflow and one focused Python regression.
- Does not change Container executable, API, runtime, or package behavior.
- Preserves immutable formula URLs and one-shot service validation.
- Leaves retained stable and Current release assets under their existing live
  formula gates.

## Code map

- `.github/workflows/homebrew.yml`
  - runs the strict formula audit without requiring historical network assets;
  - probes the immutable template archive and publishes a notice when release
    retention has removed it;
  - gates only archive fetch and installation on that probe.
- `scripts/test_update_homebrew_formula.py`
  - rejects the former online audit;
  - requires the archive probe and both dependent workflow conditions.
- `docs/upstream/ISSUE-homebrew-retired-template-asset-20260723.md`
  - records the reproduction, contract, and validation.
- `docs/upstream/PR-homebrew-retired-template-asset-20260723.md`
  - provides this upstream handoff.

## Validation on macOS

```console
actionlint .github/workflows/homebrew.yml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover scripts \
  -p 'test_update_homebrew_formula.py'
ruby -c Formula/container.rb
make check
```

Results:

- Workflow lint passed.
- Formula/workflow regressions: 3 passed.
- Ruby syntax passed.
- Formatting and license checks passed.
- The active stable Container and Compose formula tests passed with retained
  `0.8.0` release assets.

## Compatibility and risks

The workflow no longer asks Homebrew's strict audit to contact a historical
template URL. It validates availability explicitly and reports retirement as
a notice, so source regressions still fail while retention is no longer
misreported as a formula defect.

When the archive exists, fetch, install, and `brew test` behavior is unchanged.
Active stable and Current releases continue to validate their retained
archives in the Compose release gates.

## PR template

### Type of change

- [x] CI reliability
- [x] Homebrew packaging validation
- [x] Regression coverage
- [x] Documentation update
- [ ] Runtime behavior
- [ ] Breaking change

### Motivation and context

GitHub release retention can remove a maintained template's immutable archive
after its source remains unchanged. The workflow must distinguish that
expected lifecycle event from a formula-source or package regression.

### Testing

- [x] Reproduced the retired-archive 404
- [x] Workflow lint passed
- [x] Formula/workflow regressions passed
- [x] Ruby syntax passed
- [x] Formatting and license checks passed
- [x] Active stable formula tests passed

Related issue handoff:
`docs/upstream/ISSUE-homebrew-retired-template-asset-20260723.md`.
