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

import Testing

@testable import ContainerResource

struct WorkloadPlanResolverTests {
    @Test func commitsEffectsAndProcessInDependencyOrderThenReplaysWithoutSideEffects() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controllers = [
            TestEffectController(domain: .network, recorder: recorder),
            TestEffectController(domain: .volume, recorder: recorder),
        ]
        let process = TestProcessStarter(recorder: recorder)
        let request = mutation("start-1")

        let running = try await resolver.start(
            request,
            sandboxGeneration: 1,
            controllers: controllers,
            process: process
        )

        #expect(running.state == .running)
        #expect(running.latestProcessGeneration == 1)
        #expect(running.activeEffects.map(\.domain) == [.network, .volume])
        #expect(
            await recorder.events() == [
                "reserve:network", "apply:network", "reserve:volume", "apply:volume", "process:start",
            ]
        )

        let replay = try await resolver.start(
            request,
            sandboxGeneration: 1,
            controllers: controllers,
            process: process
        )
        #expect(replay == running)
        #expect(await recorder.events().count == 5)
        #expect(await ledger.workload(containerID: "container-1") == running)
    }

    @Test func knownEffectFailureCompensatesPriorEffects() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controllers = [
            TestEffectController(domain: .network, recorder: recorder),
            TestEffectController(domain: .volume, applyMode: .throwsObservedAbsent, recorder: recorder),
        ]

        do {
            _ = try await resolver.start(
                mutation("start-1"),
                sandboxGeneration: 1,
                controllers: controllers,
                process: TestProcessStarter(recorder: recorder)
            )
            Issue.record("start unexpectedly succeeded")
        } catch {
            #expect(error as? WorkloadPlanResolverError == .effectFailed(.volume))
        }

        #expect(
            await recorder.events() == [
                "reserve:network", "apply:network", "reserve:volume", "apply:volume", "observe:volume",
                "compensate:network",
            ]
        )
        let failed = try #require(await ledger.workload(containerID: "container-1"))
        #expect(failed.state == .created)
        #expect(failed.latestProcessGeneration == nil)
        #expect(failed.lastOperation?.outcome == .startFailed)
    }

    @Test func lostEffectResponseUsesExactObservationWithoutDuplicateApply() async throws {
        let (_, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controller = TestEffectController(
            domain: .network,
            applyMode: .throwsObservedApplied,
            recorder: recorder
        )

        let running = try await resolver.start(
            mutation("start-1"),
            sandboxGeneration: 1,
            controllers: [controller],
            process: TestProcessStarter(recorder: recorder)
        )

        #expect(running.state == .running)
        #expect(
            await recorder.events() == [
                "reserve:network", "apply:network", "observe:network", "process:start",
            ]
        )
    }

    @Test func unknownEffectOutcomeFencesWorkload() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controller = TestEffectController(
            domain: .network,
            applyMode: .throwsObservedUnknown,
            recorder: recorder
        )

        await #expect(throws: WorkloadPlanResolverError.recoveryRequired) {
            try await resolver.start(
                self.mutation("start-1"),
                sandboxGeneration: 1,
                controllers: [controller],
                process: TestProcessStarter(recorder: recorder)
            )
        }

        let fenced = try #require(await ledger.workload(containerID: "container-1"))
        #expect(fenced.state == .recoveryRequired)
        #expect(fenced.operation?.phase == .recoveryRequired)
        #expect(fenced.operation?.effects.first?.state == .unknown)
        #expect(await recorder.events().contains("process:start") == false)
    }

    @Test func knownProcessFailureCompensatesAllEffectsInReverseOrder() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controllers = [
            TestEffectController(domain: .network, recorder: recorder),
            TestEffectController(domain: .volume, recorder: recorder),
        ]

        await #expect(throws: WorkloadPlanResolverError.processFailed) {
            try await resolver.start(
                self.mutation("start-1"),
                sandboxGeneration: 1,
                controllers: controllers,
                process: TestProcessStarter(mode: .throwsObservedAbsent, recorder: recorder)
            )
        }

        #expect(
            await recorder.events().suffix(4) == [
                "process:start", "process:observe", "compensate:volume", "compensate:network",
            ]
        )
        let failed = try #require(await ledger.workload(containerID: "container-1"))
        #expect(failed.state == .created)
        #expect(failed.latestProcessGeneration == nil)
    }

    @Test func unknownProcessOutcomePreservesAppliedEffectsAndFencesWorkload() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()

        await #expect(throws: WorkloadPlanResolverError.recoveryRequired) {
            try await resolver.start(
                self.mutation("start-1"),
                sandboxGeneration: 1,
                controllers: [TestEffectController(domain: .network, recorder: recorder)],
                process: TestProcessStarter(mode: .throwsObservedUnknown, recorder: recorder)
            )
        }

        let fenced = try #require(await ledger.workload(containerID: "container-1"))
        #expect(fenced.state == .recoveryRequired)
        #expect(fenced.operation?.effects.first?.state == .applied)
        #expect(await recorder.events().contains("compensate:network") == false)
    }

    @Test func interruptedStartSkipsAlreadyAppliedEffect() async throws {
        let (ledger, resolver) = try await readyResolver()
        let request = mutation("start-1")
        let starting = try reserved(try await ledger.beginStart(request, sandboxGeneration: 1))
        let generation = try #require(starting.operation?.operationGeneration)
        let effect = try TestEffectController.effect(domain: .network, context: context(from: starting))
        _ = try await ledger.reserveEffect(
            containerID: request.containerID,
            operationGeneration: generation,
            effect: effect
        )
        _ = try await ledger.acknowledgeEffectApplied(
            containerID: request.containerID,
            operationGeneration: generation,
            effectID: effect.effectID
        )
        let recorder = InvocationRecorder()

        let running = try await resolver.start(
            request,
            sandboxGeneration: 1,
            controllers: [TestEffectController(domain: .network, recorder: recorder)],
            process: TestProcessStarter(recorder: recorder)
        )

        #expect(running.state == .running)
        #expect(await recorder.events() == ["reserve:network", "process:start"])
    }

    @Test func duplicateDomainsFailBeforeLedgerMutation() async throws {
        let (ledger, resolver) = try await readyResolver()
        let recorder = InvocationRecorder()
        let controllers = [
            TestEffectController(domain: .network, recorder: recorder),
            TestEffectController(domain: .network, recorder: recorder),
        ]

        await #expect(throws: WorkloadPlanResolverError.duplicateDomain(.network)) {
            try await resolver.start(
                self.mutation("start-1"),
                sandboxGeneration: 1,
                controllers: controllers,
                process: TestProcessStarter(recorder: recorder)
            )
        }

        #expect(await ledger.workload(containerID: "container-1")?.state == .created)
        #expect(await recorder.events().isEmpty)
    }

    private func readyResolver() async throws -> (EngineWorkloadLedgerV1, WorkloadPlanResolverV1) {
        let ledger = try EngineWorkloadLedgerV1(owningControllerID: "controller-1", sandboxID: "sandbox-1")
        _ = try await ledger.beginSandboxBoot(
            idempotencyKey: "boot-1",
            requestDigest: "sha256:boot",
            effectID: "effect-boot-1"
        )
        _ = try await ledger.commitSandboxReady(effectID: "effect-boot-1", runtimeFingerprint: "runtime:test")
        _ = try await ledger.registerWorkload(containerID: "container-1", planDigest: "sha256:plan")
        return (ledger, WorkloadPlanResolverV1(ledger: ledger))
    }

    private func mutation(_ key: String) -> EngineWorkloadMutationRequestV1 {
        .init(containerID: "container-1", idempotencyKey: key, requestDigest: "sha256:\(key)")
    }

    private func reserved(
        _ reservation: EngineWorkloadOperationReservationV1
    ) throws -> EngineWorkloadRecordV1 {
        guard case .reserved(let record) = reservation else {
            throw EngineWorkloadLedgerError.idempotencyConflict
        }
        return record
    }

    private func context(from record: EngineWorkloadRecordV1) throws -> WorkloadStartContextV1 {
        let operation = try #require(record.operation)
        return .init(
            containerID: record.containerID,
            operationGeneration: operation.operationGeneration,
            candidateProcessGeneration: try #require(operation.candidateProcessGeneration),
            sandboxGeneration: try #require(operation.sandboxGeneration),
            requestDigest: operation.requestDigest
        )
    }
}

private actor InvocationRecorder {
    private var values = [String]()

    func append(_ value: String) {
        values.append(value)
    }

    func events() -> [String] {
        values
    }
}

private actor TestEffectController: WorkloadEffectControllerV1 {
    enum ApplyMode: Sendable {
        case succeeds
        case throwsObservedApplied
        case throwsObservedAbsent
        case throwsObservedUnknown
    }

    enum CompensationMode: Sendable {
        case succeeds
        case throwsObservedCompensated
        case throwsObservedUnknown
    }

    enum Failure: Error {
        case lostResponse
    }

    nonisolated let domain: EngineWorkloadEffectDomainV1
    private let applyMode: ApplyMode
    private let compensationMode: CompensationMode
    private let recorder: InvocationRecorder
    private var compensationAttempted = false

    init(
        domain: EngineWorkloadEffectDomainV1,
        applyMode: ApplyMode = .succeeds,
        compensationMode: CompensationMode = .succeeds,
        recorder: InvocationRecorder
    ) {
        self.domain = domain
        self.applyMode = applyMode
        self.compensationMode = compensationMode
        self.recorder = recorder
    }

    func reservation(for context: WorkloadStartContextV1) async throws -> EngineWorkloadEffectV1 {
        await recorder.append("reserve:\(domain.rawValue)")
        return try Self.effect(domain: domain, context: context)
    }

    func apply(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectReceiptV1 {
        await recorder.append("apply:\(domain.rawValue)")
        switch applyMode {
        case .succeeds:
            return Self.receipt(effect)
        case .throwsObservedApplied, .throwsObservedAbsent, .throwsObservedUnknown:
            throw Failure.lostResponse
        }
    }

    func observe(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectObservationV1 {
        await recorder.append("observe:\(domain.rawValue)")
        if compensationAttempted {
            switch compensationMode {
            case .succeeds, .throwsObservedCompensated:
                return .compensated(Self.receipt(effect))
            case .throwsObservedUnknown:
                return .unknown
            }
        }
        switch applyMode {
        case .succeeds, .throwsObservedApplied:
            return .applied(Self.receipt(effect))
        case .throwsObservedAbsent:
            return .absent
        case .throwsObservedUnknown:
            return .unknown
        }
    }

    func compensate(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectReceiptV1 {
        await recorder.append("compensate:\(domain.rawValue)")
        compensationAttempted = true
        switch compensationMode {
        case .succeeds:
            return Self.receipt(effect)
        case .throwsObservedCompensated, .throwsObservedUnknown:
            throw Failure.lostResponse
        }
    }

    nonisolated static func effect(
        domain: EngineWorkloadEffectDomainV1,
        context: WorkloadStartContextV1
    ) throws -> EngineWorkloadEffectV1 {
        try .init(
            domain: domain,
            leaseID: "lease-\(domain.rawValue)-\(context.containerID)",
            leaseGeneration: context.candidateProcessGeneration,
            effectID: "effect-\(domain.rawValue)-\(context.operationGeneration)",
            integrityDigest: "sha256:\(domain.rawValue)-\(context.requestDigest)"
        )
    }

    nonisolated private static func receipt(_ effect: EngineWorkloadEffectV1) -> WorkloadEffectReceiptV1 {
        .init(
            domain: effect.domain,
            leaseID: effect.leaseID,
            leaseGeneration: effect.leaseGeneration,
            effectID: effect.effectID,
            integrityDigest: effect.integrityDigest
        )
    }
}

private actor TestProcessStarter: WorkloadProcessStarterV1 {
    enum Mode: Sendable {
        case succeeds
        case throwsObservedStarted
        case throwsObservedAbsent
        case throwsObservedUnknown
    }

    enum Failure: Error {
        case lostResponse
    }

    private let mode: Mode
    private let recorder: InvocationRecorder

    init(mode: Mode = .succeeds, recorder: InvocationRecorder) {
        self.mode = mode
        self.recorder = recorder
    }

    func start(context: WorkloadStartContextV1) async throws -> WorkloadProcessReceiptV1 {
        await recorder.append("process:start")
        switch mode {
        case .succeeds:
            return receipt(context)
        case .throwsObservedStarted, .throwsObservedAbsent, .throwsObservedUnknown:
            throw Failure.lostResponse
        }
    }

    func observe(context: WorkloadStartContextV1) async throws -> WorkloadProcessObservationV1 {
        await recorder.append("process:observe")
        switch mode {
        case .succeeds, .throwsObservedStarted:
            return .started(receipt(context))
        case .throwsObservedAbsent:
            return .absent
        case .throwsObservedUnknown:
            return .unknown
        }
    }

    private func receipt(_ context: WorkloadStartContextV1) -> WorkloadProcessReceiptV1 {
        .init(
            containerID: context.containerID,
            operationGeneration: context.operationGeneration,
            processGeneration: context.candidateProcessGeneration,
            sandboxGeneration: context.sandboxGeneration,
            requestDigest: context.requestDigest
        )
    }
}
