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

## Closure status

Pull request 268 merged on 15 September 2026. The current source-bearing main
revision `ef78345f59fdb913b3abce6ac0445616955c4e55` passes exact-source
SonarQube analysis with the required Previous Version policy. The public
project reports quality gate `OK`, 61.8% aggregate coverage, 2.4% duplicated
lines, 121,453 lines of code, and zero unresolved bugs, vulnerabilities, code
smells, or security hotspots. Reliability, security, and maintainability are A.
The 61.8% overall coverage remains below the Container-family's approximately
90% objective even though the configured SonarQube gate passes.

GitHub issue: [#267](https://github.com/stephenlclarke/container/issues/267)

Implementation pull request:
[#268](https://github.com/stephenlclarke/container/pull/268)

<!-- markdownlint-enable MD013 -->
