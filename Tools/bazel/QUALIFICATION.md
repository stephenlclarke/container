<!-- markdownlint-disable MD013 -->

# Container-only qualification — 27 September 2026

The active branch builds container and its required dependencies using native Bazel compilation. The complete preserved baseline remains at the path in `/Users/sclarke/Documents/devcontainer/CURRENT-PRESERVATION.txt`.

| Check | Result |
| --- | --- |
| Eight container executables | Build passed |
| Same-repository Go semantic helper and manifest | Build and Go/Swift tests passed |
| Container unit tests | All 24 Swift suites and the Go suite passed |
| Selected dependency tests | All 66 suites passed |
| Combined normal verification | 91 suites passed; 63 executed, 28 reused |
| Warm complete build | 3.27 seconds wall time; no compilation |
| Warm combined tests | 2.27 seconds wall time; all 91 cached |
| Warm container tests | 1.15 seconds wall time; all 25 cached |
| CLI version/help smoke | Both passed |
| Runtime integration harness | Compiled; not run against live services |
| Launcher/report/runner checks | Six regression tests, shell syntax and shellcheck passed |
| Touched Swift and Markdown | Formatting and lint passed |

Wall times include the launcher, SSD checks, logging and report retention. They are one observed warm run on this Mac, not a performance guarantee. Raw Bazel events confirm that the warm runs used only internal bookkeeping actions, without compiler, linker or generator execution.

The combined reports contain 13,831 JUnit testcase records. XCTest records five skips in XML; Swift Testing reports another 37 skipped test entries in the retained logs and omits those entries from its XML. Do not interpret the XML count as all discovered tests having executed. Skips include explicit Keychain/network/registry checks, a Docker interoperability check and upstream disabled or large-memory cases. Their source assertions remain intact.

The two DocC-only lockfile packages are excluded. Smithy's empty placeholder test is not counted; its real generated-SDK test project remains outside this reduced build. CRT qualification selects upstream offline test files. The selected AWS runtime tests exercise Smithy consumers. No VM execution, release packaging, installed service qualification, coverage percentage or cloud Sonar result is claimed.

## Evidence

Raw logs, source fingerprints, Bazel events and copied test reports are retained under:

`~/Library/Application Support/ContainerFamily/retained/container-only`

The combined run is `20260927T103325Z-46909`. `qualification-20260927.json` records the exact evidence files and warm measurements; `cli-smoke-20260927.json` contains the CLI output and timing. Initial failures remain alongside the passing reports.

Use [README.md](README.md) for the separate build, unit, dependency, host and runtime commands.
