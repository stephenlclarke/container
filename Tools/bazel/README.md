<!-- markdownlint-disable MD013 -->

# Container-only Bazel build

This workspace qualifies `container` and its required dependencies in order. It uses the exact revisions in `Package.resolved`, one macOS configuration and native Bazel compilation. SwiftPM supplies package descriptions only; it does not run a second build engine.

See [QUALIFICATION.md](QUALIFICATION.md) for validation and explicit limits, and [BENCHMARK.md](BENCHMARK.md) for repeated warm and incremental timings.

[FORK_BENCHMARK.md](FORK_BENCHMARK.md) compares the active forks with matching Apple revisions, including identical test workloads and explicit behavior differences.

[RUNTIME_BENCHMARK.md](RUNTIME_BENCHMARK.md) compares actual container startup, execution, CPU/disk workloads, image transfers and image builds using optimized Apple and fork stacks. It is part of the final build qualification.

## Commands

Run these in the container checkout:

| Command | Scope |
| --- | --- |
| `make bazel-build` | Eight container executables and the semantic helper |
| `make bazel-test` | Container unit suites and the helper's Go tests |
| `make bazel-build LAYER=system` | One dependency layer and its prerequisites |
| `make bazel-test LAYER=system` | One layer's tests |
| `make bazel-dependency-test` | Selected tests for all admitted dependencies |
| `make bazel-test-all` | Container and dependency tests together |
| `make bazel-fork-benchmark` | Isolated fork/Apple component comparisons; retains mismatches and timings |
| `make bazel-runtime-benchmark` | Build optimized Apple/fork stacks and run repeated runtime speed benchmarks |
| `make bazel-final` | Tool checks, all 101 normal test targets, optimized builds and runtime comparison |
| `make bazel-preflight PREFLIGHT_PROFILE=release` | Check signing, package access, pushed source context and the configured notarization profile |
| `make bazel-repository-test` | Six original packaging/install script checks as independent cached targets |
| `make bazel-guest-build` | Cross-compile the exact pinned Linux guest and retain a verified OCI archive |
| `make bazel-guest-runc-build` | Package a separate guest variant with the optional checksum-pinned runc runtime, reusing guest compilation |
| `make bazel-vm-integration` | Run the complete pinned VM suite against `QUALIFICATION_EVIDENCE/guest-runc/guest-artifact.json` |
| `make bazel-linux-test` | Guest core/netlink and vmexec Linux tests, with separate build caches and coverage |
| `make bazel-builder-build` | Production-toolchain formatting, vet, race tests and coverage, then a pinned builder OCI archive |
| `make bazel-unattended-artifacts` | Preflight, tool checks, guest/Linux/builder qualification and one live Apple/fork smoke trial; restore a Colima VM started by this run |
| `make bazel-unattended` | Run full laptop qualification from a clean committed checkpoint; require matching hosted quality before packaging |
| `make bazel-recover QUALIFICATION_EVIDENCE=...` | Recover the recorded host state after a killed wrapper, once every owned command has exited; retain failures for manual recovery |
| `make bazel-service-artifacts` | Original journald/GELF race, coverage and reproducibility checks, with reusable verified OCI outputs |
| `make bazel-service-integration` | Original Swift-to-journald protocol test against the packaged Linux service, compiled by Bazel |
| `make bazel-maintenance` | Original format/license checks and isolated protobuf regeneration/diff |
| `make bazel-coverage` | Unit line coverage with LCOV, Sonar XML, JSON summary and HTML source reports |
| `make bazel-runtime-integration PREPARED_RUNTIME=... INTEGRATION_ARGS=--coverage` | CLI layers and runtime coverage using a temporary profiled installation; restore original binaries afterward |
| `make bazel-combined-coverage` | Combine qualified unit and complete integration line coverage for the same sources |
| `make bazel-docs` | Original 15 API modules, extracted through Bazel and merged with DocC |
| `make bazel-codeql` | Optional local diagnostic scan with a traced Bazel build; excluded from unattended qualification |
| `make bazel-github-quality` | Verify the newest hosted quality run and both successful analysis jobs for this exact pushed commit |
| `make bazel-quality` | Legacy explicit local combined-coverage scan; not used by the split workflow or accepted as hosted evidence |
| `make bazel-release-artifact PREPARED_RUNTIME=... SERVICE_ARTIFACTS=... RELEASE_ARGS=--notarize` | Sign and validate the original archive payload, then retain Apple's notarization result |
| `make bazel-release-install` | Validate and exercise the signed archive in the private runtime location, then restore its predecessor |
| `make bazel-tools-test` | Launcher, runner and retained-report checks |
| `make bazel-check` | Tool checks, complete build, container unit tests |
| `make bazel-host-test LAYER=container-api` | Explicit host checks; requires the relevant host services |
| `make bazel-integration-build` | Compile the runtime integration harness without running it |
| `make bazel-integration-test CONTAINER_CLI_PATH=/absolute/path/to/container` | Run integration against an already prepared test installation |
| `make bazel-runtime-integration PREPARED_RUNTIME=/absolute/evidence/path` | Reset owned runtime data and run original CLI suites by layer; select one with `INTEGRATION_ARGS='--layer System'` |

`LAYER` defaults to `container`. Pick individual layer names from [layers.bzl](layers.bzl). Build and test commands reuse the same outputs. Host and runtime integration runs deliberately disable result caching because their external state can change.

The separate runtime integration suite requires a matching prepared installation, running services, kernel/images, permissions and network access. Its tests can create and remove runtime resources. Ordinary build/test commands do not start these prerequisites. The explicit runtime benchmark stages and starts its own signed installations, restores inactive default registrations afterward, and fails if an active default installation would be displaced. Compilation alone is not a runtime pass.

The foreground non-TTY stdin EOF correction is intentionally opt-in at primary `run` and `start` bootstrap when interactive input is enabled and the command is not detached. The input adapter drains buffered bytes before closing guest stdin; attach, TTY, and detached sessions keep their previous policy. Focused Bazel tests establish the API and runtime paths, including dedicated and shared workload forwarding. Live installation and finite-input CLI behavior must still pass the original integration checks before qualification.

## Available layers

[`layers.bzl`](layers.bzl) declares each layer's package, build targets, executable tests and compile-only checks. It is the authoritative list of available layer names; a layer under qualification can be present before its tests pass. Each build requests its dependency libraries and C archives, including archives hidden behind provider-only package groups.

Each executable test gets a private source directory presenting only its declared runfiles, with both package-relative and Bazel external-package paths. This supports upstream fixture lookup without writing into a checkout. `zstd` has no upstream Swift test target and is a build-only layer; its consumers provide later integration coverage.

Additional dependencies are admitted only after the preceding layer passes. Runtime integration has a separate explicit target; dependency and unit tests do not install or launch container services. Compose, devcontainer, Kubernetes repositories and family release automation are outside this workflow.

## Storage and evidence

`Tools/bazel/run.sh` checks the enrolled external SSD and the SHA-256 of Bazel 8.8.0 before running. Scratch and compiler outputs live in `/Volumes/SSD/cf/container-only`. Each invocation saves its source status, toolchain version and raw output, Bazel events and copied JUnit/test logs under `~/Library/Application Support/ContainerFamily/retained/container-only`. Bazel receives an allowlisted environment (identity, locale, Xcode selectors, revision and optional CI, plus fixed PATH/temporary directories). Scanner and notarization credentials stay in their separate dispatch processes. Explicit compiler tracing and test-fixture arguments remain supported; secrets must never be passed as Bazel arguments. Raw Bazel events are excluded from CI uploads. Commands run immediately, without a scheduler. The unattended artifact check stops only its own temporary workloads and restores Colima when it started it; it does not clear compiler caches or install a system package.

## Unattended artifact checkpoint

The host graph remains native Bazel. The Linux guest uses the repository's Swift 6.3 static SDK build, and Linux-only tests use a digest-pinned Swift 6.3 glibc container because the installed musl SDK omits Swift Testing. These specialized lanes have independent persistent build directories; they do not rebuild the macOS SwiftPM graph. The builder uses its repository's digest-pinned production Go/BuildKit images and vendored dependencies.

Artifact receipts bind source revisions, toolchains, helper inputs and archive hashes. The runtime harness verifies the guest against `Package.resolved` and the builder against the container manifest, imports those exact local archives, and checks their hashes again before starting. Verified guest and builder archives are reused; Linux tests run again against the current VM and retain their instrumented coverage files. Ordinary host targets now also cover Netlink, CloudHypervisor, cctl, the macOS portion of VminitdCore, and six original repository script checks.

`make bazel-unattended-artifacts` requires the enrolled SSD, stable Developer ID signing identity, and an existing default arm64 Docker Colima profile. If that profile is stopped, the command starts it with a temporary SSD mount and restores its stopped state afterward. It preserves the selected Docker context and saved Colima configuration. Existing containers cause an admission failure. The wrapper first acquires the existing family runtime lock at `/private/tmp/container-compose-runtime-$UID.lock`. It pauses only known idle Stephen-owned Container-family runners and the idle Homebrew devcontainer engine; an active job or container session causes admission failure. Runner process groups are suspended and checked again before removal to close the job-assignment race. A GitHub job exempts its own runner only after checking process ancestry. Dormant Apple/Homebrew service registrations are preserved and held aside for the complete qualification, then restored even after a failed stage or Colima cleanup. Admission requires an affirmative top-level launchd `not running` state with no PID; scheduled restarts, unknown states and inspection failures are rejected. Before each displacement the wrapper rechecks every remaining registration, its saved path and checksum, and rejects newly appearing registrations. If a later check fails, cleanup restores any originals already unloaded. An already running Colima instance is retained; it must already expose the SSD. Workers restart only after original services and Colima have been restored, and the shared lock stays held until worker health checks finish. Failed restoration retains `config/container-only-host-recovery.json` under the ContainerFamily support directory and blocks the next container-only run; reconcile the recorded original services before restarting the workers. `host-lease.json` retains the affected identities and cleanup outcome without credential values. Every invocation needs a new `QUALIFICATION_EVIDENCE` directory; failures remain in the previous one.

For release admission, store a notarization profile in Keychain and put only its name in `~/Library/Application Support/ContainerFamily/config/unattended.json`, for example `{"notary_profile":"container-only-unattended"}`. Release preflight checks native host resolution of `example.com.` A and AAAA against the existing three-second DNS proxy deadline, with a four-second process limit and no retries or resolver override. The original guest lookup remains required. Preflight also verifies signing with a disposable probe, GitHub keyring package scopes and the matching pushed PR. Topic branches require exactly one open Stephen-owned PR targeting main at the same commit. Local admission no longer requires Sonar credentials, scanners, the CodeQL extractor or Rosetta. GitHub owns analysis and retains Previous version policy, exact SHA versions, unchanged quality thresholds, zero unresolved issues/hotspots and zero CodeQL findings. Credentials and passwords never belong in this repository.

The following runner setup is retained for earlier evidence and optional maintenance; the current workflow does not dispatch heavy work through GitHub. The dedicated runner uses a LaunchAgent in the existing Aqua login session, with `SessionCreate` false and `LimitLoadToSessionType` set to `Aqua`. Creating a separate security session prevented signing, GitHub keyring access and notarization even though terminal checks passed. Preserve the runner definition before changing it and restart only an idle runner. The logged-in local session must have its authorized Keychain available; this setup does not unlock it or change key access permissions.

The retained `Tools/bazel/runner` app supplies the stable Developer ID bundle identity `io.github.stephenlclarke.container.qualification-runner` and a Local Network purpose string. `make bazel-runner-app RUNNER_APP_OUTPUT="/chosen/new/Container Build Runner.app"` builds and verifies it without replacing an existing app. Its `--service` mode executes only the existing dedicated `runner/container-only/runsvc.sh`; opening it normally requests consent with a bounded TCP connection to the configured router. Its grant applies to that execution context and does not prove laptop integration passed. This helper is not required for the current hosted quality workflow.

An already broken original installation can require an explicit operational stop before qualification. The optional local `failed_api_hold` object in `unattended.json` must name its exact `program`, `binary_sha256` and `plist_sha256`. Configure this only after diagnosing that installation and authorizing its temporary stop. It is not enabled by default. All other preflight checks must pass first. After taking the host lock and quiescing idle clients, the wrapper requires the unchanged API to be scheduled after exit code 1, with zero active count and no PID, only known inactive helper registrations, no runtime/guest processes, and stopped saved workload records. It checks twice, journals the original in the standard service-restoration transaction before stopping it, confirms bounded process exit and unchanged workload records, then reruns ordinary slot admission. Unknown state or drift fails closed. Normal cleanup and cancellation recovery restore this registration before workers. The retained report explicitly leaves live API inventory unconfirmed; restoring its registration may restore its pre-existing failure. No keys, bindings or container data are changed.

Local Network consent belongs to the actual process running integration. GitHub run `36362949702` failed the original HTTP test with explicit `Local network prohibited` evidence attributed to its Node executable, while terminal tests had passed. The user subsequently granted the stable runner app access; that context has not completed its HTTP retest. Current heavy tests run directly on the laptop and must pass the original `TestCLINetwork/testNetworkCreateAndUse`; a socket setup probe is not a substitute. See [Apple's Local Network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). Operating-system or executable-identity changes can still require one-time consent.

Local commands use `DEVELOPER_DIR` when set or the active `xcode-select` directory otherwise; the configured laptop uses `/Applications/Xcode.app/Contents/Developer`. Preflight requires full Xcode as well as Swift. Hosted unit/quality checks select `/Applications/Xcode_26.6.app/Contents/Developer` in their disposable runner. These selections do not change the laptop's system-wide developer directory.

Workflow unit fixtures select their own local or Actions environment. The plugin cleanup fixture compiles a small executable with the selected native C compiler and waits for its own readiness marker; a renamed copy of an Apple system executable can be killed asynchronously by macOS launch constraints. Production process ownership checks still require the recorded PID, birth time and exact executable.

Full VM qualification includes the optional runc tests already present in the pinned containerization repository. The `guest-runc` stage reads that source's runc version and ARM64 checksum, verifies download and cache reuse, and creates a separate guest receipt and image reference containing `/sbin/runc`. The VM driver stages the identical bytes for the suite's host presence check. Default guest artifacts, runtime comparisons and release installation continue to use the base guest. Only the two named graphics tests may skip when the selected kernel lacks its render device; a missing tool or any other skip fails VM qualification. Individual results must reconcile with the suite totals, including timings in scientific notation. Earlier runs with 191 passed and 22 skipped lacked 20 runc tests; only two were graphics-capability exclusions. The corrected suite at `6b94960b` passed 211 tests with only those two graphics skips and verified cleanup and service restoration; `CURRENT-RUNC-QUALIFICATION.txt` in the preservation workspace points to its receipts.

The first unattended artifact checkpoint passed, including 69 Linux tests, builder race tests, and eight live workloads on both Apple and fork stacks. Its target took 83.96 seconds with reused guest/builder archives; the wrapper also started and stopped Colima. Subsequent checkpoints passed original service reproducibility tests, the Swift/journald wire test, original maintenance checks, and CLI layers for containers, run, volumes, network, images, build, system, registry and machines. The first Build run encountered a public Alpine repository fetch failure; a recorded rerun passed all 61 tests. Existing TCP-forwarding known issues remain visible in Run results.

Apple accepted pilot notarization submission `aa97fc82-3cd8-45f8-b9d2-48157926eb4b` using Keychain profile `container-only-release`. That pilot is not the final source checkpoint and has not been published. Host unit line coverage is 63.38% and builder statement coverage is 49.2%, both below the 90% aim. Coverage export rejects empty reports and retains the original raw profile evidence. Checkpoint `79ddfd7e` passed CodeQL with zero findings and the strict Sonar PR gate with zero unresolved issues or unreviewed hotspots. Qualification of the updated workflow, final archive installation and final runtime benchmarks remain pending; intermediate green checkpoints do not certify them.

Kubernetes integration exposed a regular-file stdin EOF defect: Darwin's readability callback delivered contents but never completed the stream, leaving `kubectl apply -f -` waiting. A focused empty/large-file regression failed before the fix and passes afterward. Regular files now use bounded pull reads; pipes retain event-driven reads. All nine Kubernetes cases subsequently passed across the recorded full/focused runs after correcting private kubeconfig lookup and restart readiness. A final combined run remains required.

## Complete unattended run

Colima startup has its own temporary command lease. After startup and readiness/configuration checks succeed, the wrapper explicitly unlocks that shared description before closing it; persistent Lima helpers otherwise retain it and prevent cleanup forever. Later test controllers use independent leases and remain protected. Failed or interrupted startup does not unlock this authority: uncertain surviving descendants keep the host quarantined for explicit recovery.

`make bazel-unattended` requires a clean committed checkout. It runs tools, dependency/container/repository tests, maintenance, host checks, guest and Linux tests, builder and service qualification, VM and CLI integration, local coverage, component and Apple/Docker benchmarks, signed/notarized packaging and private archive installation. SonarCloud and CodeQL run only in GitHub. Before packaging, `github-quality` waits up to 30 minutes for the newest matching hosted run and requires both its `Analyze Swift` and `Analyze CodeQL` jobs to have actually succeeded for the same SHA, attempt and PR/base context. Missing, skipped, failed, cancelled, wrong-source or superseded results cannot qualify it. Each local stage has a deadline and separate result; failed prerequisites block dependent work, while independent checks continue. The command exits nonzero for incomplete qualification and retains `QUALIFICATION.md`, `qualification.json`, `BENCHMARK.md`, raw measurements and cleanup records.

The private release installation records its original binary hashes and recovery directory in `install/install.json` before moving the original installation. Log-retention failures still restore the original binaries. Surviving processes prevent replacement, and failed restoration retains the backup for recovery. Before resuming shared workers, the outer wrapper requires an affirmative restoration record and rechecks the original binaries and idle installation. Missing, malformed or incomplete installation evidence keeps workers quiesced and retains the host recovery journal; it cannot be treated as successful cleanup.

A killed wrapper can leave cleanup unfinished. Run `make bazel-recover QUALIFICATION_EVIDENCE=/absolute/original/evidence` after the owning process has exited. Recovery verifies invocation identity, the dead owner and exclusive host/runtime locks. Controllers and Colima commands inherit a shared `commands.lock`; cleanup needs exclusive ownership of the same inode. If only an idle Bazel server retains the lease, cleanup requests official nonblocking shutdown for the recorded workspace and retries exclusive acquisition once. A busy server or surviving controller still prevents restoration; no process is force-killed and disk caches remain. Every saved service registration is reconciled against its plist and checksum. Original binary replacement must already have a checksum-verified restoration receipt; uncertain replacements retain backups and keep workers paused. Recovery writes a separate receipt and never turns interrupted qualification into a pass. Legacy journals without a command lease need manual verification; never delete a journal or lock to bypass admission.

GitHub now runs `sonar.yml` for same-repository PRs and main updates. Two parallel, same-revision macOS jobs separate native unit coverage/SonarCloud from CodeQL's fresh arm64 build of every default SwiftPM production product. The former retains the strict Sonar policy, quality gate and separate zero-issue/hotspot checks; the latter requires a completed Swift analysis with zero SARIF findings. Both jobs retain their own evidence and have 90-minute bounds. The first combined hosted attempt at `3c4345b4` exhausted that bound while CodeQL was still tracing an instrumented test build, before unit tests began. The split does not reduce unit or production analysis scope. For the first successful split run, compare the uploaded `codeql-source-inventory.txt` with CodeQL's analyzed-files CSV from the GitHub code scanning tool-status page; the CodeQL job enables GitHub's documented `CODEQL_ACTION_FILE_COVERAGE_ON_PRS: 'true'` setting for this user-owned advanced workflow; retain the analyzed-files CSV with the run evidence. Do not treat the SARIF artifact list alone as a scanned-file list. CLI integration is excluded from hosted tests. External-fork and Dependabot PRs receive no analysis secrets and cannot qualify a local release via skipped jobs. The duplicate Stephen PR/main builds, heavyweight self-hosted workflow and automatic prebuilt package workflow are retired. Stephen tag builds no longer package or publish; upstream Apple build paths are preserved. Signature and lightweight formula checks remain. There is no timer, label trigger or automatic laptop run. Push a coherent checkpoint, then run `make bazel-unattended QUALIFICATION_EVIDENCE=/new/absolute/evidence` locally. Source changes invalidate qualification; old logs or a committed report do not certify a newer commit. Review concise source-bound results with the PR and retain large artifacts outside Git. The local command creates release candidates without publication or replacement of the installed runtime, and imports exact guest/builder artifacts without claiming unpublished registry references are available.

The separately runnable four NIO host behavior checks remain known failures on this macOS version. Identical upstream benchmark fixtures expose intentional container-name and TLS-alert differences; failed assertions remain visible and receive no qualified performance claim. Exit status 2 means only those exact reviewed differences remain; any extra failure, timeout or tenfold timing fails the gate. API documentation builds all 15 original modules through Bazel/DocC. Optimized release configuration emits nonempty dSYMs with verified binary UUIDs. An Installer certificate is not configured, so only archive distribution is signed/notarized; the native PKG remains explicitly unsigned.

Keep the same build directory between runs. Repeating the same target should reuse compiled outputs and passing test results. An edit invalidates its affected actions and dependents; separating layers limits which tests are requested, but does not prevent necessary dependent rebuilds. Do not clean the cache to diagnose an ordinary source error.

## Imported package tests

The package importer normally omits tests because package locks can omit test-only dependencies. A small patch enables an explicit list of upstream test targets. Add any required test dependencies at reviewed immutable revisions before enabling another test. The patch also preserves the consumer's deployment target when a dependency declares a lower minimum; this gives the container graph one macOS 15 configuration and supports the Bazel test runner.

Standalone Swift tests also need their plain resource bundles materialized as declared Bazel inputs. The importer creates these from the manifest's resource entries, preserves copied directory layouts, and rejects duplicate destinations or resources that need an Apple asset compiler. The generated bundle accessor adds a lookup used only inside Bazel tests.

Argument Parser also declares its checked-in snapshots and example executable as test inputs. A test-helper patch locates the example in Bazel runfiles; snapshot comparisons and assertions remain unchanged.

The certificate suite also has a test-only patch removing an unsupported XCTest activity-reporting wrapper; its key generation and every assertion still run.

The zstd importer exposes only its public headers to Swift. This supports upstream containerization's streaming zstd reader without importing private compression implementation headers as a Swift module.

Additional retained compatibility patches cover rules_license provider fields and Swift test output/coverage handling. They do not change container product behavior.

## Preservation and recovery

The pre-change snapshot is recorded in `/Users/sclarke/Documents/devcontainer/CURRENT-PRESERVATION.txt`. It contains all repository refs and metadata, tracked and nonignored worktree files, earlier retained artifacts/evidence and workspace notes. Ignored compiler caches remain in place. Work continues on `build/container-only-bazel` in a separate checkout; the original working trees have not been replaced.

## Host-dependent validation

The `nio-transport-services` library builds successfully. Its upstream suite is kept in a separate explicit host-test target: on this macOS installation, `NIOTSConnectionChannelTests.testConnectingInvolvesWaiting` waited indefinitely for a DNS/connectivity event concerning `example.invalid`. The qualification run was interrupted after 94 seconds and its raw log retained; that host-dependent check is not claimed as passing. The HTTP client timeout test also fails because this host resets a full TCP backlog instead of timing out. The platform network accounting test also returns zero path reports where upstream expects one. Two test-only patches mark these four checks (including both HTTP client timeout variants) as explicit `XCTSkip` in normal runs. `make bazel-host-test LAYER=nio-transport-services` or `LAYER=async-http-client` enables the original checks with `CONTAINER_HOST_TESTS=1`; every assertion is retained. None of these four host checks is claimed as passing. Other tests in those suites remain in the normal layer.

Normal tests set `CI=1`, respecting upstream opt-outs for interactive host services. Containerization uses this to skip its two login-Keychain checks; the initial sandbox run returned Keychain status 100001. The explicit host-test command clears `CI` and includes those checks. Skipped cases remain visible in retained test logs; XCTest also records its skips in JUnit XML.

Archive permission tests run with the `no-sandbox` execution requirement because the macOS sandbox strips set-ID bits. A focused comparison failed in the sandbox and passed locally. This preserves the complete permission assertions; compilation remains sandboxed and test outputs/results are still cached normally.

OCI tests that contact public registries also require the explicit host-test command (`LAYER=containerization-oci`). The initial Docker Hub ping timed out. A test-only trait gates live-registry methods while keeping local registry stubs, authentication validation, parsing and metadata checks in normal runs. Existing upstream credential requirements and disabled push tests remain unchanged.

Engine API key-store tests require the explicit host command (`LAYER=engine-core`, `LAYER=engine-session`, or `LAYER=engine-service`): eleven cases need an accessible Keychain, which returned status 100001 in the sandbox. Ordinary cache, protocol, cryptographic, signing-identity and routing tests remain enabled. The test runner uses a private standalone copy of the executable because the incomplete `.xctest` layout emitted by rules_swift fails strict code-signature validation (status -67056). No existing product is re-signed or installed by the test runner. Explicit host runs execute locally and still require an accessible Keychain; they are not part of normal qualification.

## Container source and semantic helper

The local container package is imported from this checkout with the same selected-test mechanism. Its tests declare their manifest, lockfile and helper fixtures. The executable-path test uses the invoked test binary name, which works with SwiftPM and Bazel.

The same-repository semantic helper builds natively with rules_go, its existing Go 1.25.6 pin and go.mod/go.sum. Bazel generates the source/oracle digest constants used by the native helper, then signs the new output and generates its manifest using the existing manifest routine. The helper's Go tests and Swift attestation tests exercise the resulting payload. Unrelated Swift edits reuse this output.

Seven API logging-handoff tests require Keychain access. In CI they are explicit skips unless CONTAINER_HOST_TESTS=1; native non-CI behavior is unchanged. Use the container-api host-test layer to request their original checks.

## AWS dependency scope

The AWS SDK import retains its exact lockfile revision and selects only the CloudWatch Logs service through that revision's native batch mechanism. Its internal authentication/runtime libraries remain available. A manifest patch keeps runtime unit tests available in this selected batch.

The CRT import initializes its pinned recursive C submodules. A manifest-only patch selects upstream offline tests for cryptography, checksums, encoding, configuration, signing and local I/O. Network, MQTT, metadata-service and credential-provider integration suites are outside this normal target; their sources and assertions are untouched.

Smithy's main-package test is an empty placeholder. Its real tests require generated SDK subprojects and a Java code generator, so this reduced workflow treats Smithy as build-only and exercises it through AWS and container consumers. It does not report the placeholder as meaningful test coverage.

The Smithy source-generation plugin is represented by a native Bazel action. It builds the pinned Swift generator, reads each selected service's settings/model and declares all five generated Swift files. A narrow resource patch passes the generator's existing header file as a declared input. This avoids nested SwiftPM builds and allows generation results to be cached.

## Build boundaries

The active graph contains this repository and 39 pinned Swift package dependencies, plus the same-repository Go helper's pinned module dependencies. The two DocC-only lockfile packages are not imported. The internal K8s module belongs to this container repository; no separate Kubernetes repository is admitted.

Normal builds produce debug artifacts. `bazel-final` also builds optimized binaries, signs the private benchmark installations and runs VMs. Packaging, publishing and family-wide release gates remain outside this check. The engine command keeps its original `main.swift` filename and explicitly selects Swift's library parsing mode for its `@main` entry point.

## Performance interpretation

The SSL component additionally builds the unchanged upstream `NIOSSLPerformanceTester` in release mode and runs matching handshake and encrypted-write workloads directly. Three alternating process trials retain monotonic durations, executable and workload hashes, and the ten upstream samples. Speed ratios include process startup and one warmup; upstream wall-clock samples are diagnostic only. The known rejected-certificate compatibility assertions remain separately failed and receive no speed ratio. Use `make bazel-fork-benchmark BENCHMARK_ARGS="--component swift-nio-ssl --phase tls"` to check only these optimized workloads during development; complete qualification still includes the compatibility suite.

See [the performance diagnosis](PERFORMANCE_DIAGNOSIS.md) before comparing fork and upstream timings. Component rebuilds deliberately invalidate every component Swift file, and archive suite timings use debug builds. Runtime measurements use optimized binaries. The benchmark waits directly for child exit with a separate timeout watchdog, avoiding up to roughly 50 ms of parent polling delay on short commands. Exact fingerprints and earlier results remain retained.

## Docker/Colima reference

After the Apple/fork runtime comparison, use `make bazel-docker-benchmark`
with an already running, idle Colima Docker engine. Set `DOCKER_CONTEXT` for
another explicit context. Seven trials use the same immutable ARM64 Alpine
image, workload resources, hashes and build payload. The command saves raw
timings, engine information, validation results and cleanup results.
It removes only its uniquely named container and result image; downloaded
base images and build cache remain available. It does not start or stop an engine.

Docker uses a warm shared VM; Apple/fork startup includes a fresh dedicated
VM. Docker's default builder shares the Colima resources recorded in engine
information, whereas Apple/fork builders use 2 CPUs and 2 GiB. Import/save
formats and storage implementations differ. These are product-level latency
comparisons, not controlled measurements of a common kernel or storage engine.

Runtime Makefile targets use seven trials by default; override `BENCHMARK_TRIALS`
for an explicitly shorter smoke run. The final optimization report is
[PERFORMANCE_OPTIMIZATIONS.md](PERFORMANCE_OPTIMIZATIONS.md).

The lower-level VM suite exposed retained original VSOCK descriptors that prevented silent close from reaching the guest. Closing the original descriptors after duplication restored all 100 parallel relay rounds. The complete native suite then passed 191 tests with 20 missing-runc skips and two graphics-capability skips and verified cleanup. The focused owner-lifetime unit selection also exposed an existing gRPC/NIO teardown assertion after both assertions passed; the complete containerization unit target passed, and both outcomes remain retained.

## Qualification follow-up

The second clean checkpoint passed the cached dependency/container layers, 15 documentation modules, service checks, 69 Linux tests and 191 VM tests (20 missing-runc skips and two graphics-capability skips), but correctly failed qualification. The Unix-socket CLI test depended on a live Alpine package-server download; it now uses a digest-pinned Python image warmed before testing, preserving its guest-user and socket-permission assertions. Socket suite stress also reproduced echo failures in both Apple and fork (2/10 and 4/10 runs); serial execution of the unchanged cases passed 10/10 per lane. The runner now isolates these cases while preserving their internal 100/500-connection workloads. Diagnostic runs and original failures remain retained. At checkpoint `327011b2`, all 86 container-management and 87 Run integration tests passed, including the pinned Unix-socket fixture; the VM suite again passed 191 tests with 20 missing-runc skips and two graphics-capability skips. That intermediate run was deliberately stopped after review found missing strict Sonar checks and mutable CI checkout. Both corrections are now implemented and reviewed; a complete run from the new checkpoint remains required.

## Integration coverage and layer boundaries

Full qualification instruments the existing CLI integration run, rather than running every layer twice. A separate optimized coverage configuration enables the original runtime profile forwarding. Each layer retains its own Bazel LCOV; continuous profiles from the CLI and launchd helpers are exported against retained, matching Swift executables. Coverage is line-based: unit, integration and combined reports contain source-relative LCOV, Sonar XML, JSON line totals and browsable HTML. These reports do not claim function or region coverage. Linux and Go services retain their existing separate coverage evidence.

Integration holds the private runtime lock, saves the original installation, stages instrumented binaries at its existing path, stops owned processes, exports profiles and restores original binaries with checksum verification. Report failures still trigger restoration. Surviving processes prevent replacement and leave an explicit recovery directory. Performance and release use the original uninstrumented installation. Local integration and combined coverage are full laptop evidence; GitHub SonarCloud uses only the hosted unit report. These coverage scopes are reported separately, with unchanged quality thresholds and zero-issue/hotspot requirements.

Combined coverage accepts only passed unit evidence and a complete integration run for identical source hashes; focused selections remain partial. It verifies report checksums and combines source/line counters, never averages percentages. Failed integration or combined coverage blocks local packaging. Hosted analysis is independently required for the same commit; a local report cannot substitute for it. The Build layer removes its own shared default builder before System disk accounting tests. Original System assertions remain unchanged.

The focused instrumented regression at `focused-coverage-20260927T203832Z` passed Warmup (1 test), Build (61) and System (25), retained 302 runtime profiles and verified restoration of every original binary. Its 22.89% integration line coverage is explicitly partial; full combined coverage cannot consume it. Export of the real unit LCOV also preserves the existing 63.38% result. All 74 workflow tests and the touched Markdown checks passed.

TLS-only and compilation-only reports identify their phase and selected components and make no compatibility claim. Every paired Bazel component shuts down both owned servers through bounded cleanup, including failed builds and discovery; compiler caches remain intact.
