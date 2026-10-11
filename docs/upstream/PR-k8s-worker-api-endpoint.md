# fix(k8s): use a worker-reachable API endpoint for multi-node clusters

## Summary

Choose one control-plane endpoint from the worker count and VM address, then pass that same value to kubeadm init and each worker join. Zero-worker clusters retain the node-local loopback endpoint; clusters with workers persist and use the control-plane VM address. Add focused coverage for the default and explicit zero-worker cases, one worker, multiple workers, and rendered kubeadm YAML.

See the [matching issue](ISSUE-k8s-worker-api-endpoint.md).

## Validation

- [x] Optimized `K8sPluginTests` component: 98 tests passed, no failures or skips.
- [x] Both original worker-join failures pass, with three nodes Ready; the complete original CLI integration suite passes 431 tests with no failures or skips.
- [x] Independent source review: no actionable findings; Swift formatting and scoped Markdown lint passed.

The regression proof retained the old loopback behavior and failed for both one and three workers while the zero-worker cases passed. Swift Testing reports those two parameter cases as one JUnit test with four failed assertions. The corrected component passed afterward. The original full CLI run passed 429 of 431 tests; its two worker-join failures remain retained alongside the corrected exact-source integration results and eight runtime workloads with seven fresh candidate samples each. Historical Apple measurements were reused without rebuilding or rerunning that baseline.

The [measured candidate checkpoint](https://github.com/stephenlclarke/container/releases/tag/candidate-performance-aa05963f815b-83e37af4a629) contains the exact signed executables for `aa05963f815b5ab5cdfaee43932301beb9699321`, benchmark/parity provenance, raw logs, JUnit and preserved failed attempts. All four assets were downloaded and checksum-verified after publication. This is a measured candidate checkpoint, not a notarized production distribution or a claim of complete Docker parity; main integration and unavailable exact-head GitHub authority remain programme close-out work.

## Compatibility and risks

Single-node clusters continue to use loopback, preserving their independence from a rotating VM address. Multi-node clusters use the current control-plane VM address so kubeadm's persisted cluster configuration matches worker discovery. Multi-node clusters still require that address to remain stable; recreating the control-plane container at a new address requires recreating its workers as well.

## Upstream relationship

Apple Container PR [#2276](https://github.com/apple/container/pull/2276) introduced multi-node creation. This fork change adapts it to the fork's loopback endpoint behavior and is suitable for upstream consideration if Apple adopts the same single-node endpoint policy.
