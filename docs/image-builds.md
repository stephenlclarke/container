# Image builds

Configure named builders, validate Dockerfiles, forward SSH credentials, and
request supply-chain attestations when you build an image.

## Use a named builder

The default builder is shared by ordinary `container build` commands. To keep a
separate builder lifecycle and cache, pass the same builder name to the builder
and build commands:

```bash
container builder start --builder remote --cpus 8 --memory 32g
container build --builder remote -t example .
```

Use `container builder status --builder remote` to inspect it, and pass the same
name to `builder stop` or `builder delete` when managing its lifecycle.

## Validate a build without exporting an image

Use `--check` to run the configured BuildKit validation checks without producing
the normal image output:

```bash
container build --check .
```

## Forward SSH authentication to a build

Dockerfile SSH mounts can use the current `SSH_AUTH_SOCK` or an explicit host
Unix socket:

```console
% container build --ssh default -t private-build .
% container build --ssh git=/tmp/agent.sock -t private-build .
% container build --ssh default=/tmp/default-agent.sock \
    --ssh git=/tmp/git-agent.sock -t private-build .
```

Repeated `--ssh` values may map different IDs to different sockets. Explicit
host paths are mounted into the builder and rewritten to guest paths before
BuildKit receives them.

## Add provenance and SBOM attestations

Use `--provenance` and `--sbom` to request BuildKit attestations on supported
outputs:

```console
% container build --provenance=true --sbom=true -t attested-build .
% container build --provenance=mode=max --sbom=true -t attested-build .
```

Use `false`, `0`, or `no` to explicitly disable either attestation in scripts
that share Docker-compatible build options:

```console
% container build --provenance=false --sbom=false -t regular-build .
```
