# feat: measure all fork candidates against retained Apple baselines

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The reference-reuse comparison normally measures only fork components whose source revisions changed. Add an explicit all-candidate option for runs that need current evidence across all five forks while reusing the authenticated historical Apple stock lanes. The option retains the existing reference validation and records the full measured inventory and selected scope in `metadata.json`.

## Implementation

`--measure-all-candidates` requires `--reuse-reference` and selects all five fork components after the complete historical-input validation succeeds. All source preparation, build, tests, CLI, Go benchmark and TLS workload dispatches use the fork lane only. The builder harness now accepts its selected lanes and preserves retained historical stock Go samples when it writes fresh candidate results. Candidate inventory validation includes the builder's distinct fixture set. The default paired and changed-components-only workflows keep their existing lane behavior.

The historical input check admits only the exact host-test patch and native-consumer verifier transitions already named by `Tools/bazel/artifacts/recipe_compatibility.py`. It also admits the exact current canonical AST hashes for the lane-selection-only changes in `Runner.builder` and `Runner.tls`; unrecognized changes remain rejected. The TLS workload alternates only across the selected lanes, so a candidate-only invocation never tries to build or launch a stock executable. Evidence metadata retains the producer and current recipe digests, recipe-policy SHA and mode, raw producer/current workload hashes, and workload-policy SHA.

`--candidate-component` can be repeated with `--reuse-reference` to run a selected continuation set. Metadata reports only those selected components, and historical rows for unselected components remain marked historical. This allows an interrupted all-candidate attempt to continue remaining components without rerunning already completed work.

## Testing

- [x] Tested locally: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/bazel -p 'test_component_reference.py'` passed (8 tests), and `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/bazel -p 'test_fork_benchmark.py'` passed (19 tests). Read-only `validate_inputs(fetch(), current pairs, ROOT, BAZEL_SHA)` also passed.
- [x] Added/updated tests: fake-runner regressions check all-five and selected-component dispatch, fork-only preparation and execution, historical stock retention, and provenance selection; a real `Runner.tls` method test mocks builds and executables to prove every inner trial stays in the selected lane.
- [x] Added/updated docs: benchmark guide, operator README, top-level README, and this issue/PR handoff pair.

No builds, component benchmarks, or runtime workloads were run for this harness change.

## Compatibility and risks

The option produces fresh fork timings compared with retained, historical Apple stock timings; reports continue to mark that comparison as historical rather than contemporaneous. Existing dependency, source, workload, toolchain and host checks remain authoritative. The routine mode still measures only changed fork components.

## Related work

See the matching [issue](ISSUE-all-component-candidate-benchmark-20261008.md).
