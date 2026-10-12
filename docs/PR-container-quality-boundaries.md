<!-- markdownlint-disable MD013 -->

# refactor(container): clarify process and startup option boundaries

## Type of change

Maintainability refactoring with regression tests and documentation; existing public entry points remain source compatible.

## Motivation and implementation

Split the offline child runner into argument ownership, descriptor configuration and monitoring functions. Copy the immutable arguments for the mutable POSIX spawn interface instead of casting away const. Keep the owned-child reap, charged-memory watchdog, timeout and descriptor cleanup. Group stopped-copy flags without changing authenticated cloning, independent SDK readback or atomic publication.

Builder.StartOptions carries the settings shared by initial startup and recovery. MachineClient.ConfigurationFlags groups the existing parser inputs. Production callers use the grouped APIs. The two original public signatures remain forwarding adapters to avoid breaking consumers. Only those two legacy declaration lines carry a documented S107 exception; no project-wide exclusion or gate change is introduced.

Name the fixed builder guest executable/mount paths, POSIX guest shell and Kubernetes readiness route at their protocol owner. They are runtime contracts, not unsupported user configuration. Extract the machine log-pipe task group while retaining both streams, error reporting and file-handle lifetime. Explain intentional empty production observers and the still-open upstream Dockerfile size restriction.

## Testing

Focused regression tests require invalid builder names and registry schemes to fail before progress callbacks or service/image requests through both public APIs. The child-process regression checks literal arguments, the two descriptor access modes and the isolated environment, alongside the existing success, failure, missing-executable, timeout, memory and reaping checks. Existing service, builder, machine, command and Kubernetes suites exercise the affected callers. The stopped-copy transaction and runtime paths must supply fresh coverage for changed writer code.

Record actual focused and checkpoint results before promotion. The earlier 436-case integration proof and the failed 78.6% analysis belong to their original source revisions; they are not a pass for this changed production tree. Reuse published baseline binaries and observations. Current candidate measurements, source quality and upward native-artifact consumption remain required.

Focused validation passes the bounded C process checks, Builder and Machine service suites, and all six Machine client cases after correcting the new test's parser setup. The maintained writer transaction passes four copy commits and six non-commit checks using the authenticated measured helper and published native SDK. Its standalone coverage covers 164 of 172 writer lines (95.35%); combined writer/process coverage is 261 of 279 lines (93.55%). These are focused line metrics, not a claim about overall project or branch coverage. The initial parser setup failure, standalone module-import failure and stale-helper probe failure remain retained separately.

## Compatibility, risks and linked work

The compatibility adapters retain all old parameters and defaults. Grouped options do not alter CLI flags or persisted formats. Allocation failure remains a safe process-launch rejection. Sampling remains a memory watchdog rather than a hard allocation quota. See [the problem](ISSUE-container-quality-boundaries.md), [issue 293](https://github.com/stephenlclarke/container/issues/293), [PR 292](https://github.com/stephenlclarke/container/pull/292) and [the stopped-copy contract](upstream/PR-stopped-copy-offline-write.md).
