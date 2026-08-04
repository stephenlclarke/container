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

struct EngineWorkloadLedgerTests {
    @Test func startCommitsCandidateGenerationAndLifecycleUsesExactAuthority() async throws {
        let ledger = try await readyLedger()
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        let request = mutation("start-1", digest: "sha256:start")
        let starting = try reserved(try await ledger.beginStart(request, sandboxGeneration: 1))
        let operationGeneration = try #require(starting.operation?.operationGeneration)
        let effect = try workloadEffect("network-1", domain: .network)
        _ = try await ledger.reserveEffect(
            containerID: request.containerID,
            operationGeneration: operationGeneration,
            effect: effect
        )
        _ = try await ledger.acknowledgeEffectApplied(
            containerID: request.containerID,
            operationGeneration: operationGeneration,
            effectID: effect.effectID
        )
        _ = try await ledger.recordProcessStarted(
            containerID: request.containerID,
            operationGeneration: operationGeneration
        )
        let running = try await ledger.commitStart(
            containerID: request.containerID,
            operationGeneration: operationGeneration
        )

        #expect(running.state == .running)
        #expect(running.latestProcessGeneration == 1)
        #expect(running.activeProcessGeneration == 1)
        #expect(running.activeSandboxGeneration == 1)
        #expect(running.activeEffects.map(\.state) == [.active])
        guard case .replay(let replay) = try await ledger.beginStart(request, sandboxGeneration: 1) else {
            Issue.record("committed start did not replay")
            return
        }
        #expect(replay == running)

        let pausing = try reserved(try await ledger.beginPause(mutation("pause-1", digest: "sha256:pause")))
        let paused = try await ledger.commitPause(
            containerID: request.containerID,
            operationGeneration: try #require(pausing.operation?.operationGeneration)
        )
        #expect(paused.state == .paused)
        let resuming = try reserved(try await ledger.beginResume(mutation("resume-1", digest: "sha256:resume")))
        let resumed = try await ledger.commitResume(
            containerID: request.containerID,
            operationGeneration: try #require(resuming.operation?.operationGeneration)
        )
        #expect(resumed.state == .running)

        let stopping = try reserved(try await ledger.beginStop(mutation("stop-1", digest: "sha256:stop")))
        let stopGeneration = try #require(stopping.operation?.operationGeneration)
        _ = try await ledger.acknowledgeEffectCompensated(
            containerID: request.containerID,
            operationGeneration: stopGeneration,
            effectID: effect.effectID
        )
        let stopped = try await ledger.commitStop(
            containerID: request.containerID,
            operationGeneration: stopGeneration
        )
        #expect(stopped.state == .stopped)
        #expect(stopped.latestProcessGeneration == 1)
        #expect(stopped.activeProcessGeneration == nil)
        #expect(stopped.activeSandboxGeneration == nil)
        #expect(stopped.activeEffects.isEmpty)
    }

    @Test func failedStartCompensatesInReverseOrderWithoutCommittingCandidate() async throws {
        let ledger = try await readyLedger()
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        let starting = try reserved(
            try await ledger.beginStart(mutation("start-1", digest: "sha256:start"), sandboxGeneration: 1)
        )
        let generation = try #require(starting.operation?.operationGeneration)
        let first = try workloadEffect("network-1", domain: .network)
        let second = try workloadEffect("volume-1", domain: .volume)
        for effect in [first, second] {
            _ = try await ledger.reserveEffect(
                containerID: "container-1",
                operationGeneration: generation,
                effect: effect
            )
            _ = try await ledger.acknowledgeEffectApplied(
                containerID: "container-1",
                operationGeneration: generation,
                effectID: effect.effectID
            )
        }
        _ = try await ledger.beginStartCompensation(
            containerID: "container-1",
            operationGeneration: generation
        )
        await #expect(throws: EngineWorkloadLedgerError.self) {
            try await ledger.acknowledgeEffectCompensated(
                containerID: "container-1",
                operationGeneration: generation,
                effectID: first.effectID
            )
        }
        for effect in [second, first] {
            _ = try await ledger.acknowledgeEffectCompensated(
                containerID: "container-1",
                operationGeneration: generation,
                effectID: effect.effectID
            )
        }
        let failed = try await ledger.completeStartFailure(
            containerID: "container-1",
            operationGeneration: generation
        )
        #expect(failed.state == .created)
        #expect(failed.latestProcessGeneration == nil)
        #expect(failed.lastOperation?.outcome == .startFailed)

        let retry = try reserved(
            try await ledger.beginStart(mutation("start-2", digest: "sha256:start-2"), sandboxGeneration: 1)
        )
        #expect(retry.operation?.candidateProcessGeneration == 1)
    }

    @Test func uncertainEffectFencesMutationsAndSurvivesReload() async throws {
        let persistence = InMemoryEngineWorkloadLedgerPersistenceV1()
        let ledger = try await readyLedger(persistence: persistence)
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        let starting = try reserved(
            try await ledger.beginStart(mutation("start-1", digest: "sha256:start"), sandboxGeneration: 1)
        )
        let generation = try #require(starting.operation?.operationGeneration)
        let effect = try workloadEffect("volume-1", domain: .volume)
        _ = try await ledger.reserveEffect(
            containerID: "container-1",
            operationGeneration: generation,
            effect: effect
        )
        let recovery = try await ledger.markEffectUnknown(
            containerID: "container-1",
            operationGeneration: generation,
            effectID: effect.effectID,
            reason: "guest result was not observed"
        )
        #expect(recovery.state == .recoveryRequired)
        #expect(recovery.operation?.effects.first?.state == .unknown)
        await #expect(throws: EngineWorkloadLedgerError.recoveryRequired) {
            try await ledger.beginStart(
                self.mutation("start-2", digest: "sha256:start-2"),
                sandboxGeneration: 1
            )
        }

        let reloaded = try await EngineWorkloadLedgerV1.open(
            owningControllerID: "controller-1",
            sandboxID: "sandbox-1",
            persistence: persistence
        )
        #expect(await reloaded.workload(containerID: "container-1") == recovery)
    }

    @Test func interruptedStopReloadPreservesActiveTupleAndRequiresRecovery() async throws {
        let persistence = InMemoryEngineWorkloadLedgerPersistenceV1()
        let ledger = try await readyLedger(persistence: persistence)
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        _ = try await commitStart(on: ledger)
        let stopping = try reserved(try await ledger.beginStop(mutation("stop-1", digest: "sha256:stop")))

        let reloaded = try await EngineWorkloadLedgerV1.open(
            owningControllerID: "controller-1",
            sandboxID: "sandbox-1",
            persistence: persistence
        )
        let recovered = try #require(await reloaded.workload(containerID: "container-1"))
        #expect(recovered.state == .recoveryRequired)
        #expect(recovered.activeProcessGeneration == stopping.activeProcessGeneration)
        #expect(recovered.activeSandboxGeneration == stopping.activeSandboxGeneration)
        #expect(recovered.operation?.phase == .recoveryRequired)

        let resumed = try await reloaded.resumeEffectlessStop(
            mutation("stop-1", digest: "sha256:stop")
        )
        #expect(resumed.state == .stopping)
        #expect(resumed.operation?.phase == .compensating)
        let stopped = try await reloaded.commitStop(
            containerID: "container-1",
            operationGeneration: try #require(
                resumed.operation?.operationGeneration
            )
        )
        #expect(stopped.state == .stopped)
    }

    @Test func removePersistsCleanupIntentBeforeCompletion() async throws {
        let ledger = try await readyLedger()
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        let removing = try reserved(try await ledger.beginRemove(mutation("remove-1", digest: "sha256:remove")))
        let generation = try #require(removing.operation?.operationGeneration)
        let cleanup = try workloadEffect("rootfs-1", domain: .rootfs)
        let reservedCleanup = try await ledger.reserveEffect(
            containerID: "container-1",
            operationGeneration: generation,
            effect: cleanup
        )
        #expect(reservedCleanup.operation?.effects.first?.state == .compensating)
        _ = try await ledger.acknowledgeEffectCompensated(
            containerID: "container-1",
            operationGeneration: generation,
            effectID: cleanup.effectID
        )
        let removed = try await ledger.commitRemove(
            containerID: "container-1",
            operationGeneration: generation
        )
        #expect(removed.state == .removed)
        #expect(removed.activeEffects.isEmpty)
    }

    @Test func filePersistenceUsesPrivateModeAndRejectsSymbolicLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "engine-workload-ledger-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "ledger.json")
        let persistence = try FileEngineWorkloadLedgerPersistenceV1(fileURL: fileURL)
        let ledger = try await EngineWorkloadLedgerV1.open(
            owningControllerID: "controller-1",
            sandboxID: "sandbox-1",
            persistence: persistence
        )
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
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
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["future"] = true
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let corruptPersistence = InMemoryEngineWorkloadLedgerPersistenceV1(initialData: corrupt)
        await #expect(throws: (any Error).self) {
            try await EngineWorkloadLedgerV1.open(
                owningControllerID: "controller-1",
                sandboxID: "sandbox-1",
                persistence: corruptPersistence
            )
        }

        let linkURL = directory.appending(path: "ledger-link.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        let linkPersistence = try FileEngineWorkloadLedgerPersistenceV1(fileURL: linkURL)
        await #expect(throws: EngineWorkloadLedgerError.self) {
            try await linkPersistence.save(Data("{}".utf8))
        }

        let targetDirectory = directory.appending(path: "target")
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        let linkedDirectory = directory.appending(path: "linked")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: targetDirectory
        )
        let linkedParentPersistence =
            try FileEngineWorkloadLedgerPersistenceV1(
                fileURL: linkedDirectory.appending(path: "ledger.json")
            )
        await #expect(throws: EngineWorkloadLedgerError.self) {
            try await linkedParentPersistence.save(Data("{}".utf8))
        }
    }

    @Test func managerReconcilesLostBootResponseWithoutDuplicateBoot() async throws {
        let persistence = InMemoryEngineWorkloadLedgerPersistenceV1()
        let ledger = try await EngineWorkloadLedgerV1.open(
            owningControllerID: "controller-1",
            sandboxID: "sandbox-1",
            persistence: persistence
        )
        let runtime = TestSandboxRuntime(failFirstBootResponse: true)
        let manager = EngineLinuxSandboxManagerV1(ledger: ledger, runtime: runtime)

        await #expect(throws: TestSandboxRuntime.Failure.lostResponse) {
            try await manager.ensureReady(
                idempotencyKey: "boot-1",
                requestDigest: "sha256:boot",
                effectID: "effect-boot-1"
            )
        }
        #expect(await ledger.snapshot().sandbox.state == .recoveryRequired)
        let ready = try await manager.ensureReady(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        #expect(ready.state == .ready)
        #expect(ready.runtimeFingerprint == "runtime:test")
        #expect(await runtime.bootCallCount() == 1)

        let observedReady = try await manager.ensureReady(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        #expect(observedReady == ready)
        #expect(await runtime.observeBootCallCount() == 2)

        let absent = try await manager.shutdownIfIdle(
            idempotencyKey: "stop-sandbox-1",
            requestDigest: "sha256:stop-sandbox",
            effectID: "effect-stop-sandbox-1"
        )
        #expect(absent.state == .absent)
        let absentReplay = try await manager.shutdownIfIdle(
            idempotencyKey: "stop-sandbox-1",
            requestDigest: "sha256:stop-sandbox",
            effectID: "effect-stop-sandbox-1"
        )
        #expect(absentReplay == absent)
        #expect(await runtime.shutdownCallCount() == 1)

        let readyAgain = try await manager.ensureReady(
            idempotencyKey: "boot-2",
            requestDigest: "sha256:boot-2",
            effectID: "effect-boot-2"
        )
        #expect(readyAgain.generation == 2)

        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        _ = try await commitStart(on: ledger, sandboxGeneration: 2)
        await #expect(throws: EngineWorkloadLedgerError.self) {
            try await manager.shutdownIfIdle(
                idempotencyKey: "stop-sandbox-1",
                requestDigest: "sha256:stop-sandbox",
                effectID: "effect-stop-sandbox-1"
            )
        }
        #expect(await runtime.shutdownCallCount() == 1)
    }

    @Test func managerRebootsAfterRuntimeProvesSandboxAbsence() async throws {
        let ledger = try await readyLedger()
        let runtime = TestSandboxRuntime(failFirstBootResponse: false)
        await runtime.seedBootReceipt(
            .init(
                sandboxID: "sandbox-1",
                generation: 1,
                effectID: "effect-boot-1",
                requestDigest: "sha256:boot",
                runtimeFingerprint: "runtime:test"
            )
        )
        let manager = EngineLinuxSandboxManagerV1(ledger: ledger, runtime: runtime)

        _ = try await manager.ensureReady(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        _ = try await ledger.registerWorkload(
            containerID: "container-1",
            planDigest: "sha256:plan"
        )
        _ = try await commitStart(on: ledger)
        await runtime.loseSandbox()

        let recovered = try await manager.ensureReady(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        #expect(recovered.state == .ready)
        #expect(recovered.generation == 2)
        #expect(await ledger.snapshot().workloads.isEmpty)
        #expect(await runtime.bootCallCount() == 1)
    }

    private func readyLedger(
        persistence: (any EngineWorkloadLedgerPersistenceV1)? = nil
    ) async throws -> EngineWorkloadLedgerV1 {
        let ledger: EngineWorkloadLedgerV1
        if let persistence {
            ledger = try await EngineWorkloadLedgerV1.open(
                owningControllerID: "controller-1",
                sandboxID: "sandbox-1",
                persistence: persistence
            )
        } else {
            ledger = try EngineWorkloadLedgerV1(owningControllerID: "controller-1", sandboxID: "sandbox-1")
        }
        _ = try await ledger.beginSandboxBoot(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        _ = try await ledger.commitSandboxReady(
            effectID: "effect-boot-1",
            runtimeFingerprint: "runtime:test"
        )
        return ledger
    }

    private func mutation(_ key: String, digest: String) -> EngineWorkloadMutationRequestV1 {
        .init(containerID: "container-1", idempotencyKey: key, requestDigest: digest)
    }

    private func workloadEffect(
        _ id: String,
        domain: EngineWorkloadEffectDomainV1
    ) throws -> EngineWorkloadEffectV1 {
        try .init(
            domain: domain,
            leaseID: "lease-\(id)",
            leaseGeneration: 1,
            effectID: id,
            integrityDigest: "sha256:\(id)"
        )
    }

    private func reserved(
        _ reservation: EngineWorkloadOperationReservationV1
    ) throws -> EngineWorkloadRecordV1 {
        guard case .reserved(let record) = reservation else {
            throw EngineWorkloadLedgerError.idempotencyConflict
        }
        return record
    }

    private func commitStart(
        on ledger: EngineWorkloadLedgerV1,
        sandboxGeneration: UInt64 = 1
    ) async throws -> EngineWorkloadRecordV1 {
        let starting = try reserved(
            try await ledger.beginStart(
                mutation("start-1", digest: "sha256:start"),
                sandboxGeneration: sandboxGeneration
            )
        )
        let generation = try #require(starting.operation?.operationGeneration)
        _ = try await ledger.recordProcessStarted(containerID: "container-1", operationGeneration: generation)
        return try await ledger.commitStart(containerID: "container-1", operationGeneration: generation)
    }
}

private actor TestSandboxRuntime: EngineLinuxSandboxRuntimeV1 {
    enum Failure: Error, Equatable {
        case lostResponse
    }

    private var bootCalls = 0
    private var shutdownCalls = 0
    private var observeBootCalls = 0
    private var failFirstBootResponse: Bool
    private var bootReceipt: EngineLinuxSandboxBootReceiptV1?

    init(failFirstBootResponse: Bool) {
        self.failFirstBootResponse = failFirstBootResponse
    }

    func boot(_ request: EngineLinuxSandboxBootRequestV1) throws -> EngineLinuxSandboxBootReceiptV1 {
        bootCalls += 1
        let receipt = EngineLinuxSandboxBootReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest,
            runtimeFingerprint: "runtime:test"
        )
        bootReceipt = receipt
        if failFirstBootResponse {
            failFirstBootResponse = false
            throw Failure.lostResponse
        }
        return receipt
    }

    func observeBoot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) -> EngineLinuxSandboxBootObservationV1 {
        observeBootCalls += 1
        guard let bootReceipt else { return .absent }
        return .ready(bootReceipt)
    }

    func shutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) -> EngineLinuxSandboxShutdownReceiptV1 {
        shutdownCalls += 1
        bootReceipt = nil
        return .init(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest
        )
    }

    func observeShutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) -> EngineLinuxSandboxShutdownObservationV1 {
        if bootReceipt == nil {
            return .absent(
                .init(
                    sandboxID: request.sandboxID,
                    generation: request.generation,
                    effectID: request.effectID,
                    requestDigest: request.requestDigest
                )
            )
        }
        return .running
    }

    func bootCallCount() -> Int {
        bootCalls
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    func observeBootCallCount() -> Int {
        observeBootCalls
    }

    func seedBootReceipt(_ receipt: EngineLinuxSandboxBootReceiptV1) {
        bootReceipt = receipt
    }

    func loseSandbox() {
        bootReceipt = nil
    }
}
