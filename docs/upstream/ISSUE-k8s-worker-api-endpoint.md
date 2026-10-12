# Issue: align the kubeadm API endpoint for worker joins

## Problem

Creating a cluster with workers initializes kubeadm with `127.0.0.1:6443` as the persisted `controlPlaneEndpoint`, then runs `kubeadm join` from each worker using the control-plane VM address. During join preflight, kubeadm reads the `kubeadm-config` ConfigMap and follows the persisted loopback endpoint from the worker, where no API server listens. Worker creation therefore fails even though the control-plane API is healthy.

The loopback endpoint was added in the fork to keep single-node clusters independent of a rotating VM address. Apple upstream later added worker creation, which needs a worker-reachable endpoint. These behaviors need to be selected together based on the requested worker count.

## Expected behavior

With the default or explicit worker count of zero, kubeadm continues to persist `127.0.0.1:6443`, preserving single-node behavior across VM address changes. With one or more workers, kubeadm init and every worker join use the same control-plane VM address and port.

## Scope and limitation

This fixes initial multi-node creation. Multi-node clusters currently depend on the control-plane VM address remaining stable while workers use the cluster. If the control-plane container is recreated with a different address, the cluster and its workers must be recreated. A stable worker-reachable endpoint requires a separate networking design.

## Validation

Focused unit coverage should verify default zero, explicit zero, one worker, multiple workers, and the rendered kubeadm configuration. The multi-node integration test should confirm that all worker nodes join and become Ready.

## Related work

See [the proposed correction](PR-k8s-worker-api-endpoint.md). The underlying upstream multi-node implementation was introduced by Apple Container PR [#2276](https://github.com/apple/container/pull/2276); the loopback endpoint behavior is fork-specific.
