# Issue 267: make SonarQube analysis authoritative

<!-- markdownlint-disable MD013 -->

## Problem

The SonarQube workflow scans source without importing the repository's existing Swift coverage, does not identify analyses with the exact source commit, and does not wait for a previous-version quality gate. The dashboard therefore reports 0% coverage and three Kubernetes-manifest security findings.

## Acceptance criteria

- Import real instrumented Swift unit coverage into SonarQube.
- Verify the `Previous version` policy and use the exact lowercase 40-character Git SHA.
- Analyze pull requests and `main`, wait for the quality gate, and reject unresolved new issues and security hotspots.
- Add bounded ephemeral-storage request and limit values for kindnet.
- Narrowly document the host-network and `NET_ADMIN`/`NET_RAW` requirements of the CNI manifest.
- Preserve stock Apple behavior and validate through a signed pull request.

GitHub issue: [#267](https://github.com/stephenlclarke/container/issues/267)

<!-- markdownlint-enable MD013 -->
