# fix(k8s): use a worker-reachable API endpoint for multi-node clusters

## Summary

Choose one control-plane endpoint from the worker count and VM address, then pass that same value to kubeadm init and each worker join. Zero-worker clusters retain the node-local loopback endpoint; clusters with workers persist and use the control-plane VM address. Add focused coverage for the default and explicit zero-worker cases, one worker, multiple workers, and rendered kubeadm YAML.

See the [matching issue](ISSUE-k8s-worker-api-endpoint.md).

## Validation

- [x] Optimized `K8sPluginTests` component: 98 tests passed, no failures or skips.
- [ ] `testCreateWithWorkersRegistersAllNodes` integration case after the active runtime session is complete.
- [x] Independent source review: no actionable findings; Swift formatting and scoped Markdown lint passed.

The regression proof retained the old loopback behavior and failed for both one and three workers while the zero-worker cases passed. Swift Testing reports those two parameter cases as one JUnit test with four failed assertions. The corrected component passed afterward. The original full CLI run passed 429 of 431 tests; its two worker-join failures are retained, and runtime validation of this correction is pending.

## Compatibility and risks

Single-node clusters continue to use loopback, preserving their independence from a rotating VM address. Multi-node clusters use the current control-plane VM address so kubeadm's persisted cluster configuration matches worker discovery. Multi-node clusters still require that address to remain stable; recreating the control-plane container at a new address requires recreating its workers as well.

## Upstream relationship

Apple Container PR [#2276](https://github.com/apple/container/pull/2276) introduced multi-node creation. This fork change adapts it to the fork's loopback endpoint behavior and is suitable for upstream consideration if Apple adopts the same single-node endpoint policy.
