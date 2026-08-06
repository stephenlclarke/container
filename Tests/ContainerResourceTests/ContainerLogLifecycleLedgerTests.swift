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

import Foundation
import Testing

@testable import ContainerResource

struct ContainerLogLifecycleLedgerTests {
    private let controllerID = "logging-controller"
    private let providerID = BuiltinLogDriverDescriptors.coreProvider.id

    @Test func writerReservationReplayConflictAndCrashReloadAreStrict() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "container-log-ledger-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "lifecycle.json")
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(fileURL: fileURL)
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let request = try writerRequest()

        guard case .reserved = try await ledger.reserveWriter(request) else {
            Issue.record("first writer reservation was not new")
            return
        }
        guard case .replay(let replay) = try await ledger.reserveWriter(request) else {
            Issue.record("identical writer reservation did not replay")
            return
        }
        #expect(replay.request == request)

        let conflict = try writerRequest(semanticRequestDigest: "sha256:conflict")
        await #expect(throws: ContainerLogLifecycleLedgerError.idempotencyConflict) {
            try await ledger.reserveWriter(conflict)
        }

        let reference = try writerReference(sessionID: request.sessionID)
        _ = try await ledger.recordWriterPreparation(
            writerPreparation(request, reference: reference),
            for: request
        )
        let activation = try await ledger.commitWriterActivation(for: request)
        #expect(activation.state == .active)

        let reloaded = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        #expect(await reloaded.snapshot() == ledger.snapshot())
        #expect(await reloaded.writerActivation(sessionID: request.sessionID) == activation)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        #expect(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )

        let data = try #require(try await persistence.load())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["future"] = true
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let corruptPersistence = InMemoryContainerLogLifecycleLedgerPersistenceV1(
            initialData: corrupt
        )
        await #expect(throws: (any Error).self) {
            try await ContainerLogLifecycleLedgerV1.open(
                owningControllerID: self.controllerID,
                persistence: corruptPersistence
            )
        }
    }

    @Test func filePersistenceRejectsSymbolicLinkDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "container-log-ledger-symlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let realDirectory = root.appending(
            path: "real",
            directoryHint: .isDirectory
        )
        let linkedDirectory = root.appending(
            path: "linked",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: linkedDirectory.appending(path: "lifecycle.json")
        )
        await #expect(
            throws: ContainerLogLifecycleLedgerError.corruptSnapshot(
                "lifecycle snapshot directory must be a non-symbolic-link directory"
            )
        ) {
            try await persistence.save(Data("{}".utf8))
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: realDirectory.appending(path: "lifecycle.json").path
            )
        )
    }

    @Test func filePersistenceAcceptsDirectTemporaryDirectoryAliases() async throws {
        #if os(macOS)
        for temporaryRoot in ["/private/tmp", "/tmp"] {
            let directory = URL(
                fileURLWithPath: temporaryRoot,
                isDirectory: true
            ).appending(
                path: "container-log-ledger-private-tmp-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
                fileURL: directory.appending(path: "lifecycle.json")
            )
            let snapshot = Data("{}".utf8)
            try await persistence.save(snapshot)
            #expect(try await persistence.load() == snapshot)
        }
        #endif
    }

    @Test func deadlineFenceTransfersExactReferenceAtomicallyAndCanReplay() async throws {
        let persistence = InMemoryContainerLogLifecycleLedgerPersistenceV1()
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let request = try writerRequest()
        let reference = try writerReference(sessionID: request.sessionID)
        _ = try await ledger.reserveWriter(request)
        _ = try await ledger.recordWriterPreparation(
            writerPreparation(request, reference: reference),
            for: request
        )
        let active = try await ledger.commitWriterActivation(for: request)
        let draining = try await ledger.beginWriterDrain(active)
        let cleanup = try await ledger.transferWriterToDetachedCleanup(
            draining,
            cleanupID: "cleanup-1",
            writerFenceReceiptDigest: "sha256:fence"
        )

        #expect(cleanup.effectTokenReference == reference)
        #expect(cleanup.state == .pending)
        let closed = try #require(await ledger.writerActivation(sessionID: request.sessionID))
        #expect(closed.state == .closed)
        #expect(closed.closeDisposition == .deadlineTruncated)
        #expect(closed.effectTokenReference == nil)

        let replay = try await ledger.transferWriterToDetachedCleanup(
            draining,
            cleanupID: "cleanup-1",
            writerFenceReceiptDigest: "sha256:fence"
        )
        #expect(replay == cleanup)

        let completed = try await ledger.completeDetachedCleanup(
            cleanup,
            providerCloseOutcomeDigest: "sha256:closed"
        )
        #expect(completed.effectTokenReference == nil)
        #expect(completed.state == .complete)
        #expect(try await ledger.tombstoneDetachedCleanup(completed).state == .tombstoned)

        let next = try writerRequest(
            operationGeneration: 2,
            sessionID: "writer-session-2",
            processGeneration: 12
        )
        guard case .reserved = try await ledger.reserveWriter(next) else {
            Issue.record("deadline-fenced writer blocked the next generation")
            return
        }
        let stale = try writerRequest(
            operationGeneration: 3,
            sessionID: "writer-session-stale",
            processGeneration: 10
        )
        await #expect(throws: ContainerLogLifecycleLedgerError.staleGeneration) {
            try await ledger.reserveWriter(stale)
        }
    }

    @Test func failedWriterCandidateCanNeverActivate() async throws {
        let ledger = try ContainerLogLifecycleLedgerV1(owningControllerID: controllerID)
        let request = try writerRequest()
        let reference = try writerReference(sessionID: request.sessionID)
        _ = try await ledger.reserveWriter(request)
        _ = try await ledger.recordWriterPreparation(
            writerPreparation(request, reference: reference),
            for: request
        )
        _ = try await ledger.markWriterCandidateClosing(for: request)
        _ = try await ledger.markWriterCandidateRecoveryRequired(for: request)

        await #expect(throws: (any Error).self) {
            try await ledger.commitWriterActivation(for: request)
        }
        let terminal = try await ledger.completeWriterCandidate(for: request)
        #expect(terminal.result == .candidateClosed)
        await #expect(throws: (any Error).self) {
            try await ledger.commitWriterActivation(for: request)
        }
    }

    @Test func normalWriterCloseRequiresDrainRecoversAndTombstones() async throws {
        let ledger = try ContainerLogLifecycleLedgerV1(owningControllerID: controllerID)
        let request = try writerRequest()
        let reference = try writerReference(sessionID: request.sessionID)
        _ = try await ledger.reserveWriter(request)
        _ = try await ledger.recordWriterPreparation(
            writerPreparation(request, reference: reference),
            for: request
        )
        let active = try await ledger.commitWriterActivation(for: request)

        await #expect(throws: (any Error).self) {
            try await ledger.completeWriterClose(active)
        }
        let recovery = try await ledger.markWriterRecoveryRequired(active)
        let restored = try await ledger.restoreWriterActive(recovery)
        let draining = try await ledger.beginWriterDrain(restored)
        let closed = try await ledger.completeWriterClose(draining)
        #expect(closed.state == .closed)
        #expect(closed.closeDisposition == .complete)
        #expect(closed.effectTokenReference == nil)
        #expect(try await ledger.tombstoneWriter(closed).state == .tombstoned)
    }

    @Test func readerLifecycleBindsExactLiveWriterAndClearsReference() async throws {
        let ledger = try ContainerLogLifecycleLedgerV1(owningControllerID: controllerID)
        let writer = try writerRequest()
        let writerReference = try writerReference(sessionID: writer.sessionID)
        _ = try await ledger.reserveWriter(writer)
        _ = try await ledger.recordWriterPreparation(
            writerPreparation(writer, reference: writerReference),
            for: writer
        )
        _ = try await ledger.commitWriterActivation(for: writer)

        let request = try readerRequest(source: activeReaderSource(writer))
        guard case .reserved = try await ledger.reserveReader(request) else {
            Issue.record("reader was not reserved")
            return
        }
        guard case .replay = try await ledger.reserveReader(request) else {
            Issue.record("reader replay was not recognized")
            return
        }
        let conflict = try readerRequest(
            semanticRequestDigest: "sha256:reader-conflict",
            source: request.source
        )
        await #expect(throws: ContainerLogLifecycleLedgerError.idempotencyConflict) {
            try await ledger.reserveReader(conflict)
        }

        let reference = try readerReference(readerSessionID: request.readerSessionID)
        _ = try await ledger.recordReaderPreparation(
            readerPreparation(request, reference: reference),
            for: request
        )
        let active = try await ledger.commitReaderSession(for: request)
        let closing = try await ledger.beginReaderClose(active)
        let closed = try await ledger.completeReaderClose(
            closing,
            terminalOutcomeDigest: "sha256:reader-closed"
        )
        #expect(closed.state == .closed)
        #expect(closed.effectTokenReference == nil)
        #expect(try await ledger.tombstoneReader(closed).state == .tombstoned)

        let staleSource = try LoggingReaderSourceV1(
            activeWriterSessionID: writer.sessionID,
            writerProviderID: writer.providerID,
            writerProviderGeneration: writer.providerGeneration,
            activeProcessGeneration: writer.candidateProcessGeneration + 1,
            activeSandboxGeneration: writer.candidateSandboxGeneration
        )
        let staleReader = try readerRequest(
            operationGeneration: 3,
            readerSessionID: "reader-stale",
            source: staleSource
        )
        await #expect(throws: ContainerLogLifecycleLedgerError.staleGeneration) {
            try await ledger.reserveReader(staleReader)
        }
    }

    @Test func concurrentIdenticalReservationsCreateOneDurableOperation() async throws {
        let persistence = InMemoryContainerLogLifecycleLedgerPersistenceV1()
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let request = try writerRequest()
        let newReservations = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<128 {
                group.addTask {
                    switch try await ledger.reserveWriter(request) {
                    case .reserved: true
                    case .replay: false
                    }
                }
            }
            var count = 0
            for try await wasNew in group where wasNew {
                count += 1
            }
            return count
        }

        #expect(newReservations == 1)
        #expect(await ledger.snapshot().writerOperations.count == 1)
    }

    @Test func controllerUsesTokenlessStartRecoveryAndNeverPersistsRawMaterial() async throws {
        let events = LifecycleEventRecorder()
        let persistence = RecordingLifecyclePersistence(events: events)
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let effects = FakeProtectedLoggingEffectStore(events: events)
        let provider = FakeLifecycleProvider(events: events, loseFirstWriterStartResponse: true)
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: effects
        )
        let request = try writerRequest()

        await #expect(throws: LifecycleTestError.responseLost) {
            try await controller.prepareWriter(request, using: provider)
        }
        let uncertain = try #require(try await ledger.writerOperation(for: request))
        #expect(uncertain.result == .startRecoveryRequired)

        let started = try await controller.prepareWriter(request, using: provider)
        #expect(started.receipt.request == request)
        let prepared = try #require(try await ledger.writerOperation(for: request))
        #expect(prepared.result.preparation != nil)
        #expect(await provider.writerStartCount == 1)
        #expect(await provider.writerStartReconcileCount == 1)

        let persisted = try #require(await persistence.currentData)
        let persistedText = try #require(String(data: persisted, encoding: .utf8))
        #expect(!persistedText.contains(FakeLifecycleProvider.writerSecret))
        #expect(!persistedText.contains(FakeLifecycleProvider.readerSecret))

        let eventValues = await events.values
        let firstPersist = try #require(eventValues.firstIndex(of: "persist"))
        let firstStart = try #require(eventValues.firstIndex(of: "writer.start"))
        #expect(firstPersist < firstStart)
        #expect(eventValues.contains("writer.reconcileStart"))
    }

    @Test func controllerFencesThenCleansExactReferenceAndRejectsSubstitutionPreCall() async throws {
        let events = LifecycleEventRecorder()
        let persistence = RecordingLifecyclePersistence(events: events)
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let effects = FakeProtectedLoggingEffectStore(events: events)
        let provider = FakeLifecycleProvider(events: events)
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: effects
        )
        let request = try writerRequest()
        _ = try await controller.prepareWriter(request, using: provider)
        let active = try await controller.activateWriter(request)

        let substituted = try LoggingSessionActivationV1(
            sessionID: active.sessionID,
            containerID: active.containerID,
            leaseGeneration: active.leaseGeneration,
            activeProcessGeneration: active.activeProcessGeneration + 1,
            providerID: active.providerID,
            providerGeneration: active.providerGeneration,
            activeSandboxGeneration: active.activeSandboxGeneration,
            effectTokenReference: active.effectTokenReference,
            closeDisposition: nil,
            state: .active
        )
        let callsBeforeSubstitution = await provider.sessionEffectCallCount
        await #expect(throws: ContainerLogLifecycleLedgerError.staleSession) {
            try await controller.closeWriter(substituted, using: provider)
        }
        #expect(await provider.sessionEffectCallCount == callsBeforeSubstitution)

        let outcome = try await controller.fenceWriterAtDeadline(
            active,
            cleanupID: "cleanup-controller",
            using: provider
        )
        guard case .detached(let cleanup) = outcome else {
            Issue.record("deadline fence unexpectedly completed synchronously")
            return
        }
        #expect(cleanup.state == .pending)
        #expect(cleanup.effectTokenReference == active.effectTokenReference)
        let closed = try #require(await ledger.writerActivation(sessionID: active.sessionID))
        #expect(closed.state == .closed)
        #expect(closed.effectTokenReference == nil)

        let completed = try await controller.runDetachedCleanup(cleanup, using: provider)
        #expect(completed.state == .complete)
        #expect(completed.providerCloseOutcomeDigest?.hasPrefix("sha256:") == true)
        #expect(await effects.contains(effectID: active.sessionID) == false)

        let eventValues = await events.values
        let resolve = try #require(eventValues.firstIndex(of: "effect.resolve"))
        let fence = try #require(eventValues.firstIndex(of: "writer.fence"))
        #expect(resolve < fence)
    }

    @Test func controllerReaderLifecycleReplaysOpenAndClosesExactSession() async throws {
        let events = LifecycleEventRecorder()
        let persistence = RecordingLifecyclePersistence(events: events)
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let effects = FakeProtectedLoggingEffectStore(events: events)
        let provider = FakeLifecycleProvider(
            events: events,
            loseFirstReaderOpenResponse: true
        )
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: effects
        )
        let request = try readerRequest(source: .stoppedContainer)

        await #expect(throws: LifecycleTestError.responseLost) {
            try await controller.prepareReader(request, using: provider)
        }
        let uncertain = try #require(try await ledger.readerOperation(for: request))
        #expect(uncertain.result == .openRecoveryRequired)
        _ = try await controller.prepareReader(request, using: provider)
        #expect(await provider.readerOpenCount == 1)
        #expect(await provider.readerOpenReconcileCount == 1)

        let active = try await controller.activateReader(request)
        let closed = try await controller.closeReader(active, using: provider)
        #expect(closed.state == .closed)
        #expect(closed.terminalOutcomeDigest == "sha256:reader-closed")
        #expect(closed.effectTokenReference == nil)
        #expect(await effects.contains(effectID: request.readerSessionID) == false)
        #expect(
            await provider.reclaimedEffects
                == [
                    try LogDriverTerminalEffectReclaimV1(
                        kind: .readerSession,
                        effectID: request.readerSessionID,
                        providerID: request.providerID,
                        providerGeneration: request.providerGeneration
                    )
                ]
        )
        let eventValues = await events.values
        let reclaim = try #require(
            eventValues.firstIndex(of: "provider.reclaim.readerSession")
        )
        let terminalPersist = try #require(
            eventValues[..<reclaim].lastIndex(of: "persist")
        )
        let remove = try #require(eventValues.firstIndex(of: "effect.remove"))
        #expect(terminalPersist < reclaim)
        #expect(reclaim < remove)
    }

    @Test(
        arguments: EffectRemovalTestPath.allCases,
        EffectRemovalFailureBoundary.allCases
    )
    func terminalEffectRemovalJournalSurvivesBothCrashBoundaries(
        path: EffectRemovalTestPath,
        boundary: EffectRemovalFailureBoundary
    ) async throws {
        let persistence = InMemoryContainerLogLifecycleLedgerPersistenceV1()
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let events = LifecycleEventRecorder()
        let effects = FakeProtectedLoggingEffectStore(events: events)
        let effectID = path.effectID
        let binding = try ProtectedLoggingEffectBindingV1(
            effectID: effectID,
            owningControllerID: controllerID,
            providerID: providerID,
            providerGeneration: 1
        )
        let reference = try await effects.seal(
            LogDriverOpaqueEffectTokenV1(validating: Data("journal-secret".utf8)),
            binding: binding
        )
        try await installTerminalEffectRemoval(
            path: path,
            reference: reference,
            ledger: ledger
        )

        let committed = await ledger.snapshot()
        let pending = try #require(committed.pendingEffectRemovals.first)
        #expect(committed.pendingEffectRemovals.count == 1)
        #expect(pending.effectTokenReference == reference)
        #expect(pending.kind == path.kind)
        await effects.failNextRemoval(at: boundary)

        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: effects
        )
        await #expect(throws: LifecycleTestError.responseLost) {
            try await controller.reconcilePendingEffectRemovals()
        }
        #expect(await ledger.snapshot().pendingEffectRemovals == [pending])
        #expect(
            await effects.contains(effectID: effectID)
                == (boundary == .beforeDeletion)
        )

        let reopenedLedger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        #expect(await reopenedLedger.snapshot().pendingEffectRemovals == [pending])
        let restartedController = ContainerLogLifecycleControllerV1(
            ledger: reopenedLedger,
            protectedEffects: effects
        )
        if boundary == .beforeDeletion {
            try await replayTerminalEffectRemoval(
                path: path,
                ledger: reopenedLedger,
                controller: restartedController,
                provider: FakeLifecycleProvider(events: events)
            )
        } else {
            try await restartedController.reconcilePendingEffectRemovals()
        }
        #expect(await reopenedLedger.snapshot().pendingEffectRemovals.isEmpty)
        #expect(await effects.contains(effectID: effectID) == false)
        try await assertTerminalOutcome(path: path, ledger: reopenedLedger)
    }

    private func installTerminalEffectRemoval(
        path: EffectRemovalTestPath,
        reference: ProtectedLoggingEffectReferenceV1,
        ledger: ContainerLogLifecycleLedgerV1
    ) async throws {
        switch path {
        case .writerCandidate:
            let request = try writerRequest(sessionID: path.ownerID)
            _ = try await ledger.reserveWriter(request)
            _ = try await ledger.recordWriterPreparation(
                writerPreparation(request, reference: reference),
                for: request
            )
            _ = try await ledger.markWriterCandidateClosing(for: request)
            _ = try await ledger.completeWriterCandidate(for: request)
        case .writerSession:
            let request = try writerRequest(sessionID: path.ownerID)
            _ = try await ledger.reserveWriter(request)
            _ = try await ledger.recordWriterPreparation(
                writerPreparation(request, reference: reference),
                for: request
            )
            let active = try await ledger.commitWriterActivation(for: request)
            let draining = try await ledger.beginWriterDrain(active)
            _ = try await ledger.completeWriterClose(draining)
        case .detachedCleanup:
            let request = try writerRequest(sessionID: "detached-writer")
            _ = try await ledger.reserveWriter(request)
            _ = try await ledger.recordWriterPreparation(
                writerPreparation(request, reference: reference),
                for: request
            )
            let active = try await ledger.commitWriterActivation(for: request)
            let draining = try await ledger.beginWriterDrain(active)
            let cleanup = try await ledger.transferWriterToDetachedCleanup(
                draining,
                cleanupID: path.ownerID,
                writerFenceReceiptDigest: "sha256:fence"
            )
            _ = try await ledger.completeDetachedCleanup(
                cleanup,
                providerCloseOutcomeDigest: "sha256:cleanup-closed"
            )
        case .readerCandidate:
            let request = try readerRequest(
                readerSessionID: path.ownerID,
                source: .stoppedContainer
            )
            _ = try await ledger.reserveReader(request)
            _ = try await ledger.recordReaderPreparation(
                readerPreparation(request, reference: reference),
                for: request
            )
            _ = try await ledger.markReaderCandidateClosing(for: request)
            _ = try await ledger.completeReaderCandidate(for: request)
        case .readerSession:
            let request = try readerRequest(
                readerSessionID: path.ownerID,
                source: .stoppedContainer
            )
            _ = try await ledger.reserveReader(request)
            _ = try await ledger.recordReaderPreparation(
                readerPreparation(request, reference: reference),
                for: request
            )
            let active = try await ledger.commitReaderSession(for: request)
            let closing = try await ledger.beginReaderClose(active)
            _ = try await ledger.completeReaderClose(
                closing,
                terminalOutcomeDigest: "sha256:reader-closed"
            )
        }
    }

    private func assertTerminalOutcome(
        path: EffectRemovalTestPath,
        ledger: ContainerLogLifecycleLedgerV1
    ) async throws {
        switch path {
        case .writerCandidate:
            let request = try writerRequest(sessionID: path.ownerID)
            #expect(try await ledger.writerOperation(for: request)?.result == .candidateClosed)
        case .writerSession:
            let session = try #require(await ledger.writerActivation(sessionID: path.ownerID))
            #expect(session.state == .closed)
            #expect(session.closeDisposition == .complete)
        case .detachedCleanup:
            let cleanup = try #require(await ledger.detachedCleanup(cleanupID: path.ownerID))
            #expect(cleanup.state == .complete)
            #expect(cleanup.providerCloseOutcomeDigest == "sha256:cleanup-closed")
        case .readerCandidate:
            let request = try readerRequest(
                readerSessionID: path.ownerID,
                source: .stoppedContainer
            )
            #expect(try await ledger.readerOperation(for: request)?.result == .candidateClosed)
        case .readerSession:
            let session = try #require(await ledger.readerSession(readerSessionID: path.ownerID))
            #expect(session.state == .closed)
            #expect(session.terminalOutcomeDigest == "sha256:reader-closed")
        }
    }

    private func replayTerminalEffectRemoval(
        path: EffectRemovalTestPath,
        ledger: ContainerLogLifecycleLedgerV1,
        controller: ContainerLogLifecycleControllerV1,
        provider: FakeLifecycleProvider
    ) async throws {
        switch path {
        case .writerCandidate:
            _ = try await controller.closePreparedWriter(
                writerRequest(sessionID: path.ownerID),
                using: provider
            )
        case .writerSession:
            let session = try #require(await ledger.writerActivation(sessionID: path.ownerID))
            _ = try await controller.closeWriter(session, using: provider)
        case .detachedCleanup:
            let cleanup = try #require(await ledger.detachedCleanup(cleanupID: path.ownerID))
            _ = try await controller.runDetachedCleanup(cleanup, using: provider)
        case .readerCandidate:
            _ = try await controller.closePreparedReader(
                readerRequest(
                    readerSessionID: path.ownerID,
                    source: .stoppedContainer
                ),
                using: provider
            )
        case .readerSession:
            let session = try #require(
                await ledger.readerSession(readerSessionID: path.ownerID)
            )
            _ = try await controller.closeReader(session, using: provider)
        }
    }

    private func writerRequest(
        operationGeneration: UInt64 = 1,
        semanticRequestDigest: String = "sha256:writer-request",
        sessionID: String = "writer-session",
        processGeneration: UInt64 = 11
    ) throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: operationGeneration,
            idempotencyKey: "writer-key",
            semanticRequestDigest: semanticRequestDigest,
            sessionID: sessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            candidateProcessGeneration: processGeneration,
            providerID: providerID,
            providerGeneration: 1,
            candidateSandboxGeneration: nil
        )
    }

    private func readerRequest(
        operationGeneration: UInt64 = 2,
        semanticRequestDigest: String = "sha256:reader-request",
        readerSessionID: String = "reader-session",
        source: LoggingReaderSourceV1
    ) throws -> LogDriverReaderOpenRequestV1 {
        try LogDriverReaderOpenRequestV1(
            operationGeneration: operationGeneration,
            idempotencyKey: "reader-key",
            semanticRequestDigest: semanticRequestDigest,
            readerSessionID: readerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: providerID,
            providerGeneration: 1,
            source: source,
            read: ContainerLogReadRequest()
        )
    }

    private func writerReference(
        sessionID: String
    ) throws -> ProtectedLoggingEffectReferenceV1 {
        try ProtectedLoggingEffectReferenceV1(
            effectID: sessionID,
            owningControllerID: controllerID,
            providerID: providerID,
            providerGeneration: 1,
            protectedStoreObjectID: "object-\(sessionID)",
            integrityDigest: "hmac:\(sessionID)"
        )
    }

    private func readerReference(
        readerSessionID: String
    ) throws -> ProtectedLoggingEffectReferenceV1 {
        try ProtectedLoggingEffectReferenceV1(
            effectID: readerSessionID,
            owningControllerID: controllerID,
            providerID: providerID,
            providerGeneration: 1,
            protectedStoreObjectID: "object-\(readerSessionID)",
            integrityDigest: "hmac:\(readerSessionID)"
        )
    }

    private func writerPreparation(
        _ request: LogDriverStartRequestV1,
        reference: ProtectedLoggingEffectReferenceV1
    ) throws -> LoggingSessionPreparationV1 {
        try LoggingSessionPreparationV1(
            operationGeneration: request.operationGeneration,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: request.semanticRequestDigest,
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            candidateProcessGeneration: request.candidateProcessGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            candidateSandboxGeneration: request.candidateSandboxGeneration,
            effectTokenReference: reference
        )
    }

    private func readerPreparation(
        _ request: LogDriverReaderOpenRequestV1,
        reference: ProtectedLoggingEffectReferenceV1
    ) throws -> LoggingReaderPreparationV1 {
        try LoggingReaderPreparationV1(
            operationGeneration: request.operationGeneration,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: request.semanticRequestDigest,
            readerSessionID: request.readerSessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            source: request.source,
            effectTokenReference: reference
        )
    }

    private func activeReaderSource(
        _ request: LogDriverStartRequestV1
    ) throws -> LoggingReaderSourceV1 {
        try LoggingReaderSourceV1(
            activeWriterSessionID: request.sessionID,
            writerProviderID: request.providerID,
            writerProviderGeneration: request.providerGeneration,
            activeProcessGeneration: request.candidateProcessGeneration,
            activeSandboxGeneration: request.candidateSandboxGeneration
        )
    }
}

private enum LifecycleTestError: Error {
    case responseLost
    case protectedEffectConflict
    case protectedEffectMissing
}

enum EffectRemovalFailureBoundary: String, CaseIterable, Sendable {
    case beforeDeletion
    case afterDeletion
}

enum EffectRemovalTestPath: String, CaseIterable, Sendable {
    case writerCandidate
    case writerSession
    case detachedCleanup
    case readerCandidate
    case readerSession

    var kind: LoggingEffectRemovalKindV1 {
        switch self {
        case .writerCandidate: .writerCandidate
        case .writerSession: .writerSession
        case .detachedCleanup: .detachedCleanup
        case .readerCandidate: .readerCandidate
        case .readerSession: .readerSession
        }
    }

    var ownerID: String { "removal-owner-\(rawValue)" }

    var effectID: String {
        self == .detachedCleanup ? "detached-writer" : ownerID
    }
}

private actor LifecycleEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor RecordingLifecyclePersistence: ContainerLogLifecycleLedgerPersistenceV1 {
    private let events: LifecycleEventRecorder
    private(set) var currentData: Data?

    init(events: LifecycleEventRecorder) {
        self.events = events
    }

    func load() -> Data? {
        currentData
    }

    func save(_ data: Data) async {
        currentData = data
        await events.append("persist")
    }
}

private actor FakeProtectedLoggingEffectStore: ProtectedLoggingEffectStoreV1 {
    private struct Entry: Sendable {
        let binding: ProtectedLoggingEffectBindingV1
        let reference: ProtectedLoggingEffectReferenceV1
        let material: LogDriverOpaqueEffectTokenV1
    }

    private let events: LifecycleEventRecorder
    private var entries: [Entry] = []
    private var nextRemovalFailure: EffectRemovalFailureBoundary?

    init(events: LifecycleEventRecorder) {
        self.events = events
    }

    func seal(
        _ material: LogDriverOpaqueEffectTokenV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> ProtectedLoggingEffectReferenceV1 {
        await events.append("effect.seal")
        if let existing = entries.first(where: { $0.binding == binding }) {
            guard existing.material.isByteIdentical(to: material) else {
                throw LifecycleTestError.protectedEffectConflict
            }
            return existing.reference
        }
        let reference = try ProtectedLoggingEffectReferenceV1(
            binding: binding,
            protectedStoreObjectID: "protected-\(binding.effectID)",
            integrityDigest: "hmac:\(binding.effectID)"
        )
        entries.append(Entry(binding: binding, reference: reference, material: material))
        return reference
    }

    func resolve(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> LogDriverOpaqueEffectTokenV1 {
        guard let entry = entries.first(where: { $0.binding == binding }) else {
            throw LifecycleTestError.protectedEffectMissing
        }
        try reference.validateExactReference(entry.reference)
        try reference.validateBinding(binding)
        await events.append("effect.resolve")
        return entry.material
    }

    func remove(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws {
        if nextRemovalFailure == .beforeDeletion {
            nextRemovalFailure = nil
            throw LifecycleTestError.responseLost
        }
        guard let index = entries.firstIndex(where: { $0.binding == binding }) else {
            return
        }
        try reference.validateExactReference(entries[index].reference)
        entries.remove(at: index)
        await events.append("effect.remove")
        if nextRemovalFailure == .afterDeletion {
            nextRemovalFailure = nil
            throw LifecycleTestError.responseLost
        }
    }

    func failNextRemoval(at boundary: EffectRemovalFailureBoundary) {
        nextRemovalFailure = boundary
    }

    func contains(effectID: String) -> Bool {
        entries.contains(where: { $0.binding.effectID == effectID })
    }
}

private actor LifecycleFakeWriterSession: ContainerLogDriverSession {
    func write(_ record: ContainerLogRecordV2) async throws {}
    func flush(deadline: ContinuousClock.Instant) async throws {}
    func close(deadline: ContinuousClock.Instant) async throws {}
}

private actor LifecycleFakeReader: ContainerLogReader {
    func next() async throws -> ContainerLogReaderEventV1 {
        .endOfStream
    }

    func cancel() async {}
}

private actor FakeLifecycleProvider: ContainerLogDriverProvider {
    static let writerSecret = "raw-writer-effect-secret"
    static let readerSecret = "raw-reader-effect-secret"

    private let events: LifecycleEventRecorder
    private var loseFirstWriterStartResponse: Bool
    private var loseFirstReaderOpenResponse: Bool
    private var writerRequest: LogDriverStartRequestV1?
    private var readerRequest: LogDriverReaderOpenRequestV1?
    private var writerClosed = false
    private var writerFenced = false
    private var readerClosed = false

    private(set) var writerStartCount = 0
    private(set) var writerStartReconcileCount = 0
    private(set) var readerOpenCount = 0
    private(set) var readerOpenReconcileCount = 0
    private(set) var sessionEffectCallCount = 0
    private(set) var reclaimedEffects = [LogDriverTerminalEffectReclaimV1]()

    init(
        events: LifecycleEventRecorder,
        loseFirstWriterStartResponse: Bool = false,
        loseFirstReaderOpenResponse: Bool = false
    ) {
        self.events = events
        self.loseFirstWriterStartResponse = loseFirstWriterStartResponse
        self.loseFirstReaderOpenResponse = loseFirstReaderOpenResponse
    }

    var descriptor: LogDriverDescriptor {
        get async throws {
            await events.append("provider.descriptor")
            return BuiltinLogDriverDescriptors.jsonFile
        }
    }

    func start(_ request: LogDriverStartRequestV1) async throws -> StartedLogDriverSessionV1 {
        writerStartCount += 1
        await events.append("writer.start")
        writerRequest = request
        if loseFirstWriterStartResponse {
            loseFirstWriterStartResponse = false
            throw LifecycleTestError.responseLost
        }
        return try startedWriter(request)
    }

    func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        writerStartReconcileCount += 1
        await events.append("writer.reconcileStart")
        guard let writerRequest else {
            return .absent
        }
        guard writerRequest == request else {
            return .conflict
        }
        return .prepared(try startedWriter(request))
    }

    func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        sessionEffectCallCount += 1
        await events.append("writer.reconcile")
        if writerClosed {
            return try LogDriverSessionAcknowledgementV1(
                call: request,
                observation: .closed,
                writerFenceReceiptDigest: nil
            )
        }
        if writerFenced {
            return try LogDriverSessionAcknowledgementV1(
                call: request,
                observation: .writerFenced,
                writerFenceReceiptDigest: "sha256:fence"
            )
        }
        return try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .active,
            writerFenceReceiptDigest: nil
        )
    }

    func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        sessionEffectCallCount += 1
        writerFenced = true
        await events.append("writer.fence")
        return try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .writerFenced,
            writerFenceReceiptDigest: "sha256:fence"
        )
    }

    func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        sessionEffectCallCount += 1
        writerClosed = true
        await events.append("writer.close")
        return try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .closed,
            writerFenceReceiptDigest: nil
        )
    }

    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        readerOpenCount += 1
        readerRequest = request
        await events.append("reader.open")
        if loseFirstReaderOpenResponse {
            loseFirstReaderOpenResponse = false
            throw LifecycleTestError.responseLost
        }
        return try startedReader(request)
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        readerOpenReconcileCount += 1
        await events.append("reader.reconcileOpen")
        guard let readerRequest else {
            return .absent
        }
        guard readerRequest == request else {
            return .conflict
        }
        return .prepared(try startedReader(request))
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        await events.append("reader.reconcile")
        return try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: readerClosed ? .closed : .active,
            terminalOutcomeDigest: readerClosed ? "sha256:reader-closed" : nil
        )
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        readerClosed = true
        await events.append("reader.close")
        return try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: .closed,
            terminalOutcomeDigest: "sha256:reader-closed"
        )
    }

    func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async {
        reclaimedEffects.append(request)
        await events.append("provider.reclaim.\(request.kind.rawValue)")
    }

    private func startedWriter(
        _ request: LogDriverStartRequestV1
    ) throws -> StartedLogDriverSessionV1 {
        StartedLogDriverSessionV1(
            receipt: LogDriverStartReceiptV1(
                request: request,
                effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(
                    validating: Data(Self.writerSecret.utf8)
                )
            ),
            session: LifecycleFakeWriterSession()
        )
    }

    private func startedReader(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> StartedLogDriverReaderV1 {
        StartedLogDriverReaderV1(
            receipt: LogDriverReaderOpenReceiptV1(
                request: request,
                effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(
                    validating: Data(Self.readerSecret.utf8)
                )
            ),
            reader: LifecycleFakeReader()
        )
    }
}
