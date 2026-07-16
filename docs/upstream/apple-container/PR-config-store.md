# Apple PR Handoff: Persistent Non-Secret Config Store

## Summary

Add a persistent, immutable configuration resource to `container` with a public
XPC client, server implementation, and `container config` command group.

## Changes

- Add `ConfigConfiguration`, `ConfigResource`, `ConfigStorage`, and typed
  config errors.
- Persist metadata using the existing `FilesystemEntityStore` under the API
  server's `configs` root; persist the bytes as a sibling `content` file.
- Add XPC create, delete, list, inspect, and explicit read routes.
- Add `ClientConfig` as the public consumer API.
- Add `container config create|list|inspect|read|delete` for provisioning and
  inspecting non-secret configs.
- Add path-safety and persistence/round-trip tests.

## Design notes

This is deliberately a resource-management primitive, not Compose integration.
It does not know Compose project names, service targets, lifecycle, or Docker
image metadata. `container-compose` will consume `ClientConfig.read` and
continue materializing a private read-only bind mount for the service target.

The server does not return content as part of `list` or `inspect`; callers must
request `read` explicitly. This reduces accidental disclosure in routine CLI
output without claiming secret-grade protection.

## Security boundary

This feature is for public/non-secret configuration such as application
settings, policy files, and generated config fragments. It is not appropriate
for passwords, tokens, private keys, or certificates. A future secret feature
needs separate key-management, permissions, and redaction design.

## Validation

- `swift test --filter 'ConfigValidationTests|ConfigsServiceTests|StoragePathTests'`
- `swift build --target ContainerCommands --target container-apiserver`
- Managed-system smoke test:

  ```console
  printf 'mode=production\n' > config.env
  container config create --label owner=compose app-config config.env
  container config inspect app-config
  container config read app-config
  container config delete app-config
  ```

## Follow-up consumer

Once the backend lands, `container-compose` can lift external `configs` from
partial to supported. External `secrets` remain intentionally separate and
partial pending a secure store.
