//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import ContainerRuntimeClient
import ContainerizationError
import Foundation
import Testing
import Virtualization

@testable import ContainerAPIService

struct ContainerLifecycleValidationTests {
    @Test
    func foregroundProcessAccessRequiresRunningOrPausedContainer() throws {
        try ContainersService.validateForegroundProcessStatus(
            .running,
            id: "running"
        )
        try ContainersService.validateForegroundProcessStatus(
            .paused,
            id: "paused"
        )

        let error = #expect(throws: ContainerizationError.self) {
            try ContainersService.validateForegroundProcessStatus(
                .stopped,
                id: "prepared"
            )
        }
        #expect(error?.code == .invalidState)
        #expect(error?.message == "container prepared is not running or paused")
    }

    @Test
    func preparedInitProcessCannotBypassForegroundBootstrap() throws {
        try ContainersService.validateProcessStartState(
            status: .stopped,
            isInit: true,
            prewarmed: false,
            cleanupRequired: false,
            id: "cold"
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateProcessStartState(
                status: .stopped,
                isInit: true,
                prewarmed: true,
                cleanupRequired: false,
                id: "prepared"
            )
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateProcessStartState(
                status: .stopped,
                isInit: true,
                prewarmed: false,
                cleanupRequired: true,
                id: "cleanup"
            )
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateProcessStartState(
                status: .stopped,
                isInit: false,
                prewarmed: false,
                cleanupRequired: false,
                id: "exec"
            )
        }
    }

    @Test
    func preparedRuntimeShutdownFailureRecoversByObservedState() {
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: .stopped)
                == .retryShutdown
        )
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: .stopping)
                == .retryShutdown
        )
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: .running)
                == .stopThenShutdown
        )
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: .paused)
                == .resumeStopThenShutdown
        )
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: .unknown)
                == .retainForRetry
        )
        #expect(
            ContainersService.preparedRuntimeShutdownRecovery(status: nil)
                == .confirmInactiveService
        )
        #expect(
            !ContainersService.preparedRuntimeCleanupRequiresServiceStopBeforeLogging(
                .stopThenShutdown
            )
        )
        #expect(
            ContainersService.preparedRuntimeCleanupRequiresServiceStopBeforeLogging(
                .confirmInactiveService
            )
        )
    }

    @Test
    func stoppedPrewarmFallbackRequiresOriginalAndFreshOwnedState() {
        var state = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        state.prewarmed = true
        state.prewarmCleanupRequiresLoggingClose = true
        let captured = ContainersService.PreparedServiceRecoveryState(state)
        #expect(captured.generation == state.generation)
        #expect(captured.prewarmed)
        #expect(!captured.cleanupRequired)
        #expect(captured.startedDate == nil)
        #expect(captured.loggingRequiresClose)
        let context = ContainersService.PreparedServiceRecoveryContext(
            captured: captured,
            isDedicated: true,
            label: "gui/501/prepared.runtime"
        )
        func eligible(status: RuntimeStatus = .stopped, current: ContainersService.ContainerState) -> Bool {
            ContainersService.stoppedPreparedRuntimeMayStopService(
                status: status,
                context: context,
                current: ContainersService.PreparedServiceRecoveryState(current)
            )
        }
        #expect(eligible(current: state))
        #expect(!eligible(status: .stopping, current: state))
        #expect(!eligible(status: .running, current: state))
        #expect(!eligible(status: .paused, current: state))
        #expect(!eligible(status: .unknown, current: state))
        #expect(
            !ContainersService.stoppedPreparedRuntimeMayStopService(
                status: .stopped,
                context: .init(captured: captured, isDedicated: false, label: context.label),
                current: .init(state)
            ))
        state.prewarmed = false
        #expect(!eligible(current: state))
        state.prewarmed = true
        state.prewarmCleanupRequired = true
        #expect(!eligible(current: state))
        state.prewarmCleanupRequired = false
        state.snapshot.startedDate = Date()
        #expect(!eligible(current: state))
        let replacement = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        #expect(!eligible(current: replacement))
        var capturedTombstone = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        capturedTombstone.prewarmed = true
        capturedTombstone.prewarmCleanupRequired = true
        #expect(
            !ContainersService.stoppedPreparedRuntimeMayStopService(
                status: .stopped,
                context: .init(captured: .init(capturedTombstone), isDedicated: true, label: context.label),
                current: .init(capturedTombstone)
            ))
    }

    @Test
    func stoppedPrewarmServiceRecoveryReadsFreshStateBeforeExactStop() async throws {
        var state = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        state.prewarmed = true
        let label = "gui/501/prepared.runtime"
        let context = ContainersService.PreparedServiceRecoveryContext(
            captured: .init(state), isDedicated: true, label: label
        )
        var events = [String]()
        try await ContainersService.stopStoppedPreparedServiceIfOwned(
            context: context,
            freshStatus: {
                events.append("fresh-runtime-stopped")
                return .stopped
            },
            currentState: {
                events.append("locked-current-state")
                return .init(state)
            },
            stopService: { selected in
                events.append("exact-service-inactive")
                #expect(selected == label)
            }
        )
        #expect(events == ["fresh-runtime-stopped", "locked-current-state", "exact-service-inactive"])

        for status in [RuntimeStatus.stopping, .running, .paused, .unknown] {
            events.removeAll()
            await #expect(throws: ContainerizationError.self) {
                try await ContainersService.stopStoppedPreparedServiceIfOwned(
                    context: context,
                    freshStatus: {
                        events.append("fresh-runtime-state")
                        return status
                    },
                    currentState: {
                        events.append("locked-current-state")
                        return .init(state)
                    },
                    stopService: { _ in events.append("unexpected-service-stop") }
                )
            }
            #expect(events == ["fresh-runtime-state", "locked-current-state"])
        }

        events.removeAll()
        var replacement = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        replacement.prewarmed = true
        await #expect(throws: ContainerizationError.self) {
            try await ContainersService.stopStoppedPreparedServiceIfOwned(
                context: context,
                freshStatus: {
                    events.append("fresh-runtime-stopped")
                    return .stopped
                },
                currentState: {
                    events.append("replacement-generation")
                    return .init(replacement)
                },
                stopService: { _ in events.append("unexpected-service-stop") }
            )
        }
        #expect(events == ["fresh-runtime-stopped", "replacement-generation"])
    }

    @Test
    func stoppedPrewarmServiceRecoveryRejectsCapturedStateDrift() async {
        var current = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        current.prewarmed = true
        var notPrewarmed = current
        notPrewarmed.prewarmed = false
        var cleanupTombstone = current
        cleanupTombstone.prewarmCleanupRequired = true
        var alreadyStarted = current
        alreadyStarted.snapshot.startedDate = Date()
        for captured in [notPrewarmed, cleanupTombstone, alreadyStarted] {
            var events = [String]()
            await #expect(throws: ContainerizationError.self) {
                try await ContainersService.stopStoppedPreparedServiceIfOwned(
                    context: .init(
                        captured: .init(captured),
                        isDedicated: true,
                        label: "gui/501/prepared.runtime"
                    ),
                    freshStatus: {
                        events.append("fresh-runtime-stopped")
                        return .stopped
                    },
                    currentState: {
                        events.append("current-eligible")
                        return .init(current)
                    },
                    stopService: { _ in events.append("unexpected-service-stop") }
                )
            }
            #expect(events == ["fresh-runtime-stopped", "current-eligible"])
        }
    }

    @Test
    func stoppedPrewarmServiceRecoveryFailsClosedOnObservationOrStopError() async {
        var state = ContainersService.ContainerState(snapshot: Self.snapshot(id: "prepared"))
        state.prewarmed = true
        let context = ContainersService.PreparedServiceRecoveryContext(
            captured: .init(state), isDedicated: true, label: "gui/501/prepared.runtime"
        )
        var events = [String]()
        await #expect(throws: PreparedShutdownTestError.sticky) {
            try await ContainersService.stopStoppedPreparedServiceIfOwned(
                context: context,
                freshStatus: { throw PreparedShutdownTestError.sticky },
                currentState: {
                    events.append("unexpected-state-read")
                    return .init(state)
                },
                stopService: { _ in events.append("unexpected-service-stop") }
            )
        }
        #expect(events.isEmpty)
        await #expect(throws: PreparedShutdownTestError.sticky) {
            try await ContainersService.stopStoppedPreparedServiceIfOwned(
                context: context,
                freshStatus: {
                    events.append("fresh-runtime-stopped")
                    return .stopped
                },
                currentState: { throw PreparedShutdownTestError.sticky },
                stopService: { _ in events.append("unexpected-service-stop") }
            )
        }
        #expect(events == ["fresh-runtime-stopped"])
        events.removeAll()
        await #expect(throws: PreparedShutdownTestError.inactiveProof) {
            try await ContainersService.stopStoppedPreparedServiceIfOwned(
                context: context,
                freshStatus: {
                    events.append("fresh-runtime-stopped")
                    return .stopped
                },
                currentState: {
                    events.append("locked-current-state")
                    return .init(state)
                },
                stopService: { _ in
                    events.append("inactive-proof-failed")
                    throw PreparedShutdownTestError.inactiveProof
                }
            )
        }
        #expect(events == ["fresh-runtime-stopped", "locked-current-state", "inactive-proof-failed"])
    }

    @Test
    func repeatedStoppedShutdownFailureStopsExactServiceBeforeLogging() async throws {
        var events = ["first-shutdown-failed"]
        var tombstoneRetained = true
        let stoppedService = try await ContainersService.retryPreparedShutdownOrStopService(
            initialStatus: .stopped,
            retryShutdown: {
                events.append("second-shutdown-failed")
                throw PreparedShutdownTestError.sticky
            },
            stopIfStillEligible: {
                events.append("exact-service-inactive")
            }
        )
        #expect(stoppedService)
        try await ContainersService.finishPreparedRuntimeCleanup(
            stopServiceBeforeLogging: false,
            serviceAlreadyStopped: stoppedService,
            stopService: { events.append("unexpected-second-service-stop") },
            cleanupLogging: { events.append("logging-cleanup") },
            clearState: {
                events.append("clear-tombstone")
                tombstoneRetained = false
            }
        )
        #expect(
            events == [
                "first-shutdown-failed", "second-shutdown-failed",
                "exact-service-inactive", "logging-cleanup", "clear-tombstone",
            ])
        #expect(!tombstoneRetained)

        var rejectedEvents = [String]()
        await #expect(throws: PreparedShutdownTestError.sticky) {
            try await ContainersService.retryPreparedShutdownOrStopService(
                initialStatus: .stopping,
                retryShutdown: {
                    rejectedEvents.append("second-shutdown-failed")
                    throw PreparedShutdownTestError.sticky
                },
                stopIfStillEligible: {
                    rejectedEvents.append("unexpected-service-stop")
                }
            )
        }
        #expect(rejectedEvents == ["second-shutdown-failed"])
    }

    @Test
    func successfulShutdownRetryUsesNormalCleanupWithoutFallback() async throws {
        var events = [String]()
        let stoppedService = try await ContainersService.retryPreparedShutdownOrStopService(
            initialStatus: .stopped,
            retryShutdown: { events.append("retry-shutdown-succeeded") },
            stopIfStillEligible: { events.append("unexpected-forced-stop") }
        )
        #expect(!stoppedService)
        try await ContainersService.finishPreparedRuntimeCleanup(
            stopServiceBeforeLogging: false,
            serviceAlreadyStopped: stoppedService,
            stopService: { events.append("normal-service-inactive") },
            cleanupLogging: { events.append("logging-cleanup") },
            clearState: { events.append("clear-tombstone") }
        )
        #expect(
            events == [
                "retry-shutdown-succeeded", "logging-cleanup", "normal-service-inactive",
                "clear-tombstone",
            ])
    }

    @Test
    func exactServiceStopFailureRetainsPreparedCleanup() async {
        var events = [String]()
        var tombstoneRetained = true
        await #expect(throws: PreparedShutdownTestError.inactiveProof) {
            try await ContainersService.retryPreparedShutdownOrStopService(
                initialStatus: .stopped,
                retryShutdown: {
                    events.append("second-shutdown-failed")
                    throw PreparedShutdownTestError.sticky
                },
                stopIfStillEligible: {
                    events.append("inactive-proof-failed")
                    throw PreparedShutdownTestError.inactiveProof
                }
            )
        }
        #expect(events == ["second-shutdown-failed", "inactive-proof-failed"])
        #expect(tombstoneRetained)

        await #expect(throws: PreparedShutdownTestError.inactiveProof) {
            try await ContainersService.finishPreparedRuntimeCleanup(
                stopServiceBeforeLogging: true,
                serviceAlreadyStopped: false,
                stopService: {
                    events.append("inactive-proof-failed-again")
                    throw PreparedShutdownTestError.inactiveProof
                },
                cleanupLogging: { events.append("unexpected-logging-cleanup") },
                clearState: { tombstoneRetained = false }
            )
        }
        #expect(tombstoneRetained)
        #expect(!events.contains("unexpected-logging-cleanup"))
    }

    @Test
    func preparedLoggingFailureRetainsTombstoneAfterServiceStop() async {
        var events = [String]()
        var tombstoneRetained = true
        await #expect(throws: PreparedShutdownTestError.logging) {
            try await ContainersService.finishPreparedRuntimeCleanup(
                stopServiceBeforeLogging: false,
                serviceAlreadyStopped: false,
                stopService: { events.append("exact-service-inactive") },
                cleanupLogging: {
                    events.append("logging-failed")
                    throw PreparedShutdownTestError.logging
                },
                clearState: { tombstoneRetained = false }
            )
        }
        #expect(events == ["logging-failed", "exact-service-inactive"])
        #expect(tombstoneRetained)
    }

    @Test
    func recoveredRunningPrewarmIsStoppedBeforeDiscard() {
        #expect(
            ContainersService.recoveredPrewarmRuntimeAction(for: .stopped)
                == .discard
        )
        #expect(
            ContainersService.recoveredPrewarmRuntimeAction(for: .stopping)
                == .discard
        )
        #expect(
            ContainersService.recoveredPrewarmRuntimeAction(for: .running)
                == .stop
        )
        #expect(
            ContainersService.recoveredPrewarmRuntimeAction(for: .paused)
                == .resumeAndStop
        )
        #expect(
            ContainersService.recoveredPrewarmRuntimeAction(for: .unknown)
                == .reject
        )
    }

    @Test
    func preparedCleanupOrchestratesNormalRetryAndStickyStoppedRuntime() async throws {
        let normal = PreparedCleanupProbe(state: Self.preparedState())
        try await normal.run()
        #expect(normal.events == ["shutdown-1", "abort-logging", "stop-exact-service", "commit-state", "deactivate-grant"])
        #expect(!normal.state.prewarmed)
        #expect(!normal.state.prewarmCleanupRequired)
        #expect(!normal.state.prewarmCleanupRequiresLoggingClose)
        #expect(normal.state.generation == normal.context.captured.generation)
        #expect(normal.state.snapshot.status == .stopped)

        let retried = PreparedCleanupProbe(state: Self.preparedState())
        retried.shutdownFailures = [1]
        try await retried.run()
        #expect(
            retried.events == [
                "shutdown-1", "status", "shutdown-2", "abort-logging",
                "stop-exact-service", "commit-state", "deactivate-grant",
            ])

        let sticky = PreparedCleanupProbe(state: Self.preparedState(requiresLoggingClose: true))
        sticky.shutdownFailures = [1, 2]
        try await sticky.run()
        #expect(
            sticky.events == [
                "shutdown-1", "status", "shutdown-2", "status", "current-state",
                "stop-exact-service", "close-logging", "commit-state", "deactivate-grant",
            ])
        #expect(sticky.stopServiceCalls == 1)
    }

    @Test
    func preparedCleanupOrchestratesActivePausedUnknownAndUnavailableRuntime() async throws {
        let running = PreparedCleanupProbe(state: Self.preparedState())
        running.shutdownFailures = [1]
        running.status = .running
        try await running.run()
        #expect(
            running.events == [
                "shutdown-1", "status", "stop-runtime", "shutdown-2", "abort-logging",
                "stop-exact-service", "commit-state", "deactivate-grant",
            ])

        let paused = PreparedCleanupProbe(state: Self.preparedState())
        paused.shutdownFailures = [1]
        paused.status = .paused
        try await paused.run()
        #expect(
            paused.events == [
                "shutdown-1", "status", "resume-runtime", "stop-runtime", "shutdown-2",
                "abort-logging", "stop-exact-service", "commit-state", "deactivate-grant",
            ])

        let unknown = PreparedCleanupProbe(state: Self.preparedState())
        unknown.shutdownFailures = [1]
        unknown.status = .unknown
        await #expect(throws: PreparedShutdownTestError.sticky) { try await unknown.run() }
        #expect(unknown.events == ["shutdown-1", "status", "report-retainForRetry"])
        #expect(unknown.state.prewarmed)

        let unavailable = PreparedCleanupProbe(state: Self.preparedState())
        unavailable.shutdownFailures = [1]
        unavailable.status = nil
        try await unavailable.run()
        #expect(
            unavailable.events == [
                "shutdown-1", "status-unavailable", "report-confirmInactiveService",
                "stop-exact-service", "abort-logging", "commit-state", "deactivate-grant",
            ])
    }

    @Test
    func preparedCleanupKeepsStateOnEligibilityAndCleanupFailures() async {
        let changed = PreparedCleanupProbe(state: Self.preparedState())
        changed.shutdownFailures = [1, 2]
        changed.state = Self.preparedState()
        await #expect(throws: ContainerizationError.self) { try await changed.run() }
        #expect(
            changed.events == [
                "shutdown-1", "status", "shutdown-2", "status", "current-state",
            ])

        let inactiveProof = PreparedCleanupProbe(state: Self.preparedState())
        inactiveProof.shutdownFailures = [1, 2]
        inactiveProof.stopServiceError = .inactiveProof
        await #expect(throws: PreparedShutdownTestError.inactiveProof) {
            try await inactiveProof.run()
        }
        #expect(!inactiveProof.events.contains("abort-logging"))
        #expect(inactiveProof.state.prewarmed)

        let logging = PreparedCleanupProbe(state: Self.preparedState())
        logging.loggingError = .logging
        await #expect(throws: PreparedShutdownTestError.logging) { try await logging.run() }
        #expect(
            logging.events == [
                "shutdown-1", "abort-logging", "stop-exact-service",
            ])
        #expect(logging.state.prewarmed)

        let normalStop = PreparedCleanupProbe(state: Self.preparedState())
        normalStop.stopServiceError = .inactiveProof
        await #expect(throws: PreparedShutdownTestError.inactiveProof) {
            try await normalStop.run()
        }
        #expect(
            normalStop.events == [
                "shutdown-1", "abort-logging", "stop-exact-service",
            ])
        #expect(normalStop.state.prewarmed)

        let bothFailed = PreparedCleanupProbe(state: Self.preparedState())
        bothFailed.loggingError = .logging
        bothFailed.stopServiceError = .inactiveProof
        await #expect(throws: PreparedShutdownTestError.logging) {
            try await bothFailed.run()
        }
        #expect(
            bothFailed.events == [
                "shutdown-1", "abort-logging", "stop-exact-service",
            ])
        #expect(bothFailed.state.prewarmed)

        let changedAtCommit = PreparedCleanupProbe(state: Self.preparedState())
        changedAtCommit.replaceStateBeforeCommit = true
        await #expect(throws: ContainerizationError.self) { try await changedAtCommit.run() }
        #expect(
            changedAtCommit.events == [
                "shutdown-1", "abort-logging", "stop-exact-service", "commit-attempt",
            ])
        #expect(changedAtCommit.state.prewarmed)
        #expect(changedAtCommit.state.generation != changedAtCommit.context.captured.generation)

        let grant = PreparedCleanupProbe(state: Self.preparedState())
        grant.grantError = .inactiveProof
        await #expect(throws: PreparedShutdownTestError.inactiveProof) { try await grant.run() }
        #expect(
            grant.events == [
                "shutdown-1", "abort-logging", "stop-exact-service", "commit-state",
                "deactivate-grant",
            ])
        #expect(!grant.state.prewarmed)
    }

    @Test
    func preparedCleanupCommitClearsOnlyRuntimeOwnershipAfterGuard() throws {
        var prepared = Self.preparedState(requiresLoggingClose: true)
        prepared.prewarmCleanupRequired = true
        prepared.dockerStateError = "retained-docker-state"
        prepared.restart = ContainerRestartTracker(restoringConsecutiveFailureCount: 3)
        let captured = ContainersService.PreparedServiceRecoveryState(prepared)
        let originalGeneration = prepared.generation
        let originalSnapshot = prepared.snapshot
        try ContainersService.preparedRuntimeCleanupCommitState(
            &prepared,
            captured: captured,
            id: "prepared"
        )
        #expect(prepared.client == nil)
        #expect(!prepared.prewarmed)
        #expect(!prepared.prewarmCleanupRequired)
        #expect(!prepared.prewarmCleanupRequiresLoggingClose)
        #expect(prepared.generation == originalGeneration)
        #expect(prepared.snapshot.configuration.id == originalSnapshot.configuration.id)
        #expect(prepared.snapshot.status == originalSnapshot.status)
        #expect(prepared.dockerStateError == "retained-docker-state")
        #expect(prepared.restart.consecutiveFailures == 3)

        var notPrepared = ContainersService.ContainerState(snapshot: originalSnapshot)
        notPrepared.dockerStateError = "unchanged-error"
        notPrepared.restart = ContainerRestartTracker(restoringConsecutiveFailureCount: 5)
        let notPreparedGeneration = notPrepared.generation
        let notPreparedCapture = ContainersService.PreparedServiceRecoveryState(notPrepared)
        #expect(throws: ContainerizationError.self) {
            try ContainersService.preparedRuntimeCleanupCommitState(
                &notPrepared,
                captured: notPreparedCapture,
                id: "prepared"
            )
        }
        #expect(notPrepared.generation == notPreparedGeneration)
        #expect(notPrepared.snapshot.configuration.id == originalSnapshot.configuration.id)
        #expect(notPrepared.snapshot.status == originalSnapshot.status)
        #expect(!notPrepared.prewarmed)
        #expect(!notPrepared.prewarmCleanupRequired)
        #expect(notPrepared.dockerStateError == "unchanged-error")
        #expect(notPrepared.restart.consecutiveFailures == 5)
    }

    @Test
    func emptyPostStartProcessSnapshotDefersToTheExitMonitor() {
        #expect(ContainersService.reportedInitPID([]) == 0)
        #expect(ContainersService.reportedInitPID([-1, 42, 7]) == 7)
    }

    @Test
    func finalStartCommitRecordsRuntimeStateAtomically() {
        var state = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "started")
        )
        state.snapshot.exitCode = 1
        state.snapshot.exitedDate = Date(timeIntervalSince1970: 100)
        let startedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let runtimeState = SandboxSnapshot(
            status: .running,
            networks: [],
            containers: []
        )

        ContainersService.markContainerStarted(
            &state,
            from: runtimeState,
            at: startedDate
        )

        #expect(state.snapshot.status == .running)
        #expect(state.snapshot.networks.isEmpty)
        #expect(state.snapshot.startedDate == startedDate)
        #expect(state.snapshot.exitCode == nil)
        #expect(state.snapshot.exitedDate == nil)
    }

    @Test
    func exitedPostStartProcessSnapshotDefersToTheExitMonitor() {
        let exited = ContainerizationError(
            .invalidState,
            message: "failed to processIdentifiers: container must be running or paused"
        )
        let wrapped = ContainerizationError(
            .internalError,
            message: "failed to get processes for container example",
            cause: exited
        )

        #expect(ContainersService.isPostStartProcessExitRace(wrapped))
        #expect(
            !ContainersService.isPostStartProcessExitRace(
                ContainerizationError(.timeout, message: "process snapshot timed out")
            )
        )
    }

    @Test
    func unsupportedPostStartProcessSnapshotKeepsTheStartedContainer() {
        let unsupported = ContainerizationError(
            .unknown,
            message: "unimplemented: \"Requested RPC isn't implemented by this server.\""
        )
        let wrapped = ContainerizationError(
            .internalError,
            message: "failed to get processes for container example",
            cause: unsupported
        )

        #expect(ContainersService.isRecoverablePostStartProcessSnapshotError(unsupported))
        #expect(ContainersService.isRecoverablePostStartProcessSnapshotError(wrapped))
        #expect(
            !ContainersService.isRecoverablePostStartProcessSnapshotError(
                ContainerizationError(.timeout, message: "process snapshot timed out")
            )
        )
    }

    @Test
    func stoppedVirtualMachinePostStartProcessSnapshotDefersToTheExitMonitor() {
        let stoppedVM = NSError(
            domain: VZErrorDomain,
            code: VZError.Code.internalError.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The virtual machine stopped unexpectedly."]
        )
        let wrapped = ContainerizationError(
            .internalError,
            message: "failed to get processes for container example",
            cause: stoppedVM
        )
        let transported = ContainerizationError(
            .internalError,
            message: "failed to get processes for container example",
            cause: ContainerizationError(
                .unknown,
                message: "Error Domain=VZErrorDomain Code=1 The virtual machine stopped unexpectedly."
            )
        )

        #expect(ContainersService.isRecoverablePostStartProcessSnapshotError(wrapped))
        #expect(ContainersService.isRecoverablePostStartProcessSnapshotError(transported))
        #expect(
            !ContainersService.isRecoverablePostStartProcessSnapshotError(
                NSError(
                    domain: VZErrorDomain,
                    code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Virtual machine configuration is invalid."]
                )
            )
        )
    }

    @Test
    func failedDedicatedStartCleanupRemainsRetryable() {
        #expect(
            ContainersService.failedStartCleanupRequiresTombstone(
                cleanupSucceeded: false,
                clientIsDedicated: true
            )
        )
        #expect(
            !ContainersService.failedStartCleanupRequiresTombstone(
                cleanupSucceeded: true,
                clientIsDedicated: true
            )
        )
        #expect(
            !ContainersService.failedStartCleanupRequiresTombstone(
                cleanupSucceeded: false,
                clientIsDedicated: false
            )
        )
    }

    @Test
    func failedStartRetriesActivatedLoggingWithClose() {
        #expect(
            ContainersService.preparedLoggingCleanup(requiresClose: true)
                == .closeActivatedRun
        )
        #expect(
            ContainersService.preparedLoggingCleanup(requiresClose: false)
                == .abortBootstrap
        )
    }

    @Test
    func automaticRestartFailurePreservesCleanupTombstone() {
        #expect(
            ContainersService.restartFailurePreservesCleanupTombstone(
                cleanupRequired: true,
                clientExists: true
            )
        )
        #expect(
            !ContainersService.restartFailurePreservesCleanupTombstone(
                cleanupRequired: false,
                clientExists: true
            )
        )
        #expect(
            !ContainersService.restartFailurePreservesCleanupTombstone(
                cleanupRequired: true,
                clientExists: false
            )
        )
    }

    @Test
    func createAndUpdateShareTheBootableMemoryFloor() throws {
        try ContainersService.validateBootableMemory(
            ContainersService.minimumBootableMemoryInBytes
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateBootableMemory(
                ContainersService.minimumBootableMemoryInBytes - 1
            )
        }
    }

    @Test
    func liveMemoryTargetUsesPortableBoundsAndAlignment() throws {
        try ContainersService.validateLiveMemoryTarget(
            ContainersService.minimumLiveMemoryTargetInBytes,
            maximum: 1024 * 1024 * 1024
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateLiveMemoryTarget(
                ContainersService.minimumLiveMemoryTargetInBytes - 1,
                maximum: 1024 * 1024 * 1024
            )
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateLiveMemoryTarget(
                ContainersService.minimumLiveMemoryTargetInBytes + 1,
                maximum: 1024 * 1024 * 1024
            )
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateLiveMemoryTarget(
                2 * 1024 * 1024 * 1024,
                maximum: 1024 * 1024 * 1024
            )
        }
    }

    @Test
    func adaptiveMemoryReclamationRequiresSafeDedicatedBounds() throws {
        var configuration = Self.snapshot(id: "adaptive").configuration
        configuration.resources.memoryInBytes = 1024.mib()
        configuration.resources.adaptiveMemoryReclamation = .init(
            floorInBytes: 256.mib()
        )
        try ContainersService.validateAdaptiveMemoryReclamation(configuration)

        configuration.effectiveIsolation = .sharedVM
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateAdaptiveMemoryReclamation(configuration)
        }

        configuration.effectiveIsolation = .dedicatedVM
        configuration.resources.adaptiveMemoryReclamation?.floorInBytes = 256.mib() + 1
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateAdaptiveMemoryReclamation(configuration)
        }

        configuration.resources.adaptiveMemoryReclamation?.floorInBytes = 256.mib()
        configuration.resources.adaptiveMemoryReclamation?.sampleIntervalInNanoseconds = 5
        configuration.resources.adaptiveMemoryReclamation?.cooldownInNanoseconds = 4
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateAdaptiveMemoryReclamation(configuration)
        }
    }

    @Test
    func nanoCPUsRequireARepresentablePositiveQuota() throws {
        #expect(throws: ContainerizationError.self) {
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 0)
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 9_999)
        }
        #expect(
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 10_000) == 1
        )
        #expect(
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 1_000_000_000)
                == 100_000
        )
    }

    @Test
    func autoRemoveRejectsRestartPolicyUpdates() throws {
        try ContainersService.validateRestartPolicy(.no, autoRemove: true)
        try ContainersService.validateRestartPolicy(
            ContainerRestartPolicy(mode: .always),
            autoRemove: false
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateRestartPolicy(
                ContainerRestartPolicy(mode: .always),
                autoRemove: true
            )
        }
    }

    @Test
    func invalidResourceUpdateIsRejectedBeforePrewarmInvalidation() throws {
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validatedResourceUpdateInvalidatesPrewarm(
                prewarmed: true,
                memoryBytes: 512 * 1024 * 1024,
                nanoCPUs: nil,
                restartPolicy: ContainerRestartPolicy(mode: .always),
                autoRemove: true
            )
        }
        #expect(
            try ContainersService.validatedResourceUpdateInvalidatesPrewarm(
                prewarmed: true,
                memoryBytes: 512 * 1024 * 1024,
                nanoCPUs: nil,
                restartPolicy: .no,
                autoRemove: true
            )
        )
    }

    @Test
    func containerNamesAndDockerIDsRemainReservedForCreate() {
        let dockerID = String(repeating: "a", count: 64)
        let containers = [
            (
                id: "immutable-storage-id",
                dockerName: Optional("renamed"),
                dockerID: Optional(dockerID)
            )
        ]

        #expect(
            ContainersService.hasContainer(
                named: "renamed",
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            !ContainersService.hasContainer(
                named: "available",
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            ContainersService.hasContainer(
                named: dockerID,
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            ContainersService.hasContainer(
                named: "quarantined-name",
                excluding: "new-container",
                among: [],
                reservedNames: ["quarantined-name"]
            )
        )
        #expect(
            !ContainersService.hasContainer(
                named: dockerID,
                excluding: "immutable-storage-id",
                among: containers
            )
        )
    }

    @Test
    func overflowingLifecycleRevisionsAreRejected() {
        #expect(throws: ContainerizationError.self) {
            var snapshot = ContainerLifecycleSnapshotV2(
                state: .restarting,
                transitionRevision: .max,
                operationGeneration: 8
            )
            try ContainersService.advanceLifecycleRevisions(&snapshot)
        }
        #expect(throws: ContainerizationError.self) {
            var snapshot = ContainerLifecycleSnapshotV2(
                state: .restarting,
                transitionRevision: 7,
                operationGeneration: .max
            )
            try ContainersService.advanceLifecycleRevisions(&snapshot)
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.nextLifecycleCounter(
                .max,
                named: "process generation"
            )
        }
    }

    @Test
    func persistedOptionsOverrideTheOriginalRuntimeConfiguration() {
        let original = ContainerCreateOptions(
            autoRemove: false,
            restartPolicy: .no
        )
        let updated = ContainerCreateOptions(
            autoRemove: true,
            restartPolicy: ContainerRestartPolicy(mode: .always)
        )

        let selected = ContainersService.authoritativeCreateOptions(
            persisted: updated,
            runtime: original
        )

        #expect(selected.autoRemove)
        #expect(selected.restartPolicy.mode == .always)
    }

    @Test
    func failedExitPersistenceStillPublishesAnInMemoryExitedLifecycle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 120)
        let existing = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "api",
            immutableBundleKey: "api",
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .running,
                running: true,
                paused: true,
                restarting: true,
                removalInProgress: true,
                dead: true,
                oomKillCountBaseline: 2,
                pid: 42,
                transitionRevision: 7,
                operationGeneration: 8
            )
        )

        let recovered = ContainersService.recoveredLifecycleAfterExitPersistenceFailure(
            existing,
            exitCode: 137,
            startedAt: startedAt,
            finishedAt: finishedAt,
            health: "unhealthy",
            restartConsecutiveFailureCount: 3,
            observedOOMKillCount: 4,
            manualRestartSuppressed: true,
            terminalError: "restart failed",
            persistenceError: "disk full"
        )

        #expect(recovered.snapshot.state == .exited)
        #expect(!recovered.snapshot.running)
        #expect(!recovered.snapshot.paused)
        #expect(!recovered.snapshot.restarting)
        #expect(!recovered.snapshot.removalInProgress)
        #expect(!recovered.snapshot.dead)
        #expect(recovered.snapshot.pid == 0)
        #expect(recovered.snapshot.exitCode == 137)
        #expect(recovered.snapshot.startedAt == startedAt)
        #expect(recovered.snapshot.finishedAt == finishedAt)
        #expect(recovered.snapshot.health == "unhealthy")
        #expect(recovered.snapshot.restartConsecutiveFailureCount == 3)
        #expect(recovered.snapshot.oomKilled)
        #expect(recovered.snapshot.transitionRevision == 8)
        #expect(recovered.snapshot.operationGeneration == 9)
        #expect(recovered.snapshot.error.contains("restart failed"))
        #expect(recovered.snapshot.error.contains("disk full"))
        #expect(recovered.intent.manualRestartSuppressed)
    }

    @Test
    func failedStartDropsTheInvalidRuntimeClientState() {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        let configuration = ContainerConfiguration(
            id: "api",
            image: image,
            process: process
        )
        let state = ContainersService.ContainerState(
            snapshot: ContainerSnapshot(
                configuration: configuration,
                status: .running,
                networks: [],
                health: .healthy
            )
        )

        let recovered = ContainersService.recoveredContainerStateAfterFailedStart(
            state
        )

        #expect(recovered.client == nil)
        #expect(recovered.snapshot.status == .stopped)
        #expect(recovered.snapshot.networks.isEmpty)
        #expect(recovered.snapshot.health == nil)
    }

    @Test
    func exitPersistenceRecoveryRejectsStaleOrLiveState() {
        #expect(
            ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 9,
                expectedOperationGeneration: 9,
                status: .stopped
            )
        )
        #expect(
            !ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 10,
                expectedOperationGeneration: 9,
                status: .stopped
            )
        )
        #expect(
            !ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 9,
                expectedOperationGeneration: 9,
                status: .running
            )
        )
    }

    @Test
    func restartStabilityPersistenceRecoveryRejectsStaleOrStoppedState() {
        let startedDate = Date(timeIntervalSince1970: 100)
        #expect(
            ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .running,
                startedDate: startedDate,
                expectedStartedDate: startedDate
            )
        )
        #expect(
            !ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .stopped,
                startedDate: startedDate,
                expectedStartedDate: startedDate
            )
        )
        #expect(
            !ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .running,
                startedDate: Date(timeIntervalSince1970: 101),
                expectedStartedDate: startedDate
            )
        )
    }

    @Test
    func restartBackoffClearsTheExitedProcessPID() {
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .restarting,
                runtimeStatus: .stopped,
                reportedPID: nil
            ) == 0
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .restarting,
                runtimeStatus: .running,
                reportedPID: nil
            ) == 42
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .running,
                runtimeStatus: .running,
                reportedPID: 84
            ) == 84
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .exited,
                runtimeStatus: .stopped,
                reportedPID: 84
            ) == 0
        )
    }

    private static func preparedState(requiresLoggingClose: Bool = false) -> ContainersService.ContainerState {
        var state = ContainersService.ContainerState(snapshot: snapshot(id: "prepared"))
        state.prewarmed = true
        state.prewarmCleanupRequiresLoggingClose = requiresLoggingClose
        return state
    }

    private static func snapshot(id: String) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        return ContainerSnapshot(
            configuration: ContainerConfiguration(
                id: id,
                image: image,
                process: process
            ),
            status: .stopped,
            networks: [],
            startedDate: nil
        )
    }
}

private enum PreparedShutdownTestError: Error {
    case sticky
    case inactiveProof
    case logging
}

private final class PreparedCleanupProbe {
    var events = [String]()
    var state: ContainersService.ContainerState
    let context: ContainersService.PreparedServiceRecoveryContext
    var shutdownFailures = Set<Int>()
    var status: RuntimeStatus? = .stopped
    var stopServiceError: PreparedShutdownTestError?
    var loggingError: PreparedShutdownTestError?
    var grantError: PreparedShutdownTestError?
    var replaceStateBeforeCommit = false
    private(set) var stopServiceCalls = 0
    private var shutdownCalls = 0

    init(state: ContainersService.ContainerState) {
        self.state = state
        context = .init(
            captured: .init(state),
            isDedicated: true,
            label: "gui/501/prepared.runtime"
        )
    }

    func run() async throws {
        try await ContainersService.performPreparedRuntimeCleanup(
            context: context,
            operations: .init(
                shutdown: {
                    self.shutdownCalls += 1
                    self.events.append("shutdown-\(self.shutdownCalls)")
                    if self.shutdownFailures.contains(self.shutdownCalls) {
                        throw PreparedShutdownTestError.sticky
                    }
                },
                status: {
                    guard let status = self.status else {
                        self.events.append("status-unavailable")
                        throw PreparedShutdownTestError.sticky
                    }
                    self.events.append("status")
                    return status
                },
                stop: { self.events.append("stop-runtime") },
                resume: { self.events.append("resume-runtime") },
                currentState: {
                    self.events.append("current-state")
                    return .init(self.state)
                },
                stopService: { selected in
                    guard selected == self.context.label else {
                        throw PreparedShutdownTestError.inactiveProof
                    }
                    self.stopServiceCalls += 1
                    self.events.append("stop-exact-service")
                    if let error = self.stopServiceError { throw error }
                },
                cleanupLogging: { selection in
                    switch selection {
                    case .abortBootstrap: self.events.append("abort-logging")
                    case .closeActivatedRun: self.events.append("close-logging")
                    }
                    if let error = self.loggingError { throw error }
                },
                commitState: {
                    if self.replaceStateBeforeCommit {
                        var replacement = ContainersService.ContainerState(snapshot: self.state.snapshot)
                        replacement.prewarmed = true
                        self.state = replacement
                        self.events.append("commit-attempt")
                    }
                    try ContainersService.preparedRuntimeCleanupCommitState(
                        &self.state,
                        captured: self.context.captured,
                        id: "prepared"
                    )
                    self.events.append("commit-state")
                },
                deactivateGrant: {
                    self.events.append("deactivate-grant")
                    if let error = self.grantError { throw error }
                },
                reportRecovery: { recovery, _ in
                    self.events.append("report-\(recovery)")
                }
            )
        )
    }
}
