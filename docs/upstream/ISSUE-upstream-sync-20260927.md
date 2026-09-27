# Synchronize container and its direct fork dependencies

## Motivation

The reduced container build must include Apple main `4a7d8615241b8ddecfd3bf225cd7c44f4b2ccf7c`. Limit synchronization to container, containerization, container-builder-shim, swift-nio-ssl, and grpc-swift-nio-transport. Preserve existing work and avoid expanding to unrelated container-family applications.

## Acceptance

Include upstream history, retain the fork's supported behavior, update the containerization pin, and validate the combined container host suites. Preserve benchmark evidence with its exact original revisions.
