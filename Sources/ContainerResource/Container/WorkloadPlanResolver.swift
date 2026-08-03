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

public enum WorkloadPlanResolverError: Error, Equatable, Sendable {
    case duplicateDomain(EngineWorkloadEffectDomainV1)
    case invalidReservation(EngineWorkloadEffectDomainV1)
    case effectFailed(EngineWorkloadEffectDomainV1)
    case processFailed
    case recoveryRequired
}

public struct WorkloadStartContextV1: Equatable, Sendable {
    public let containerID: String
    public let operationGeneration: UInt64
    public let candidateProcessGeneration: UInt64
    public let sandboxGeneration: UInt64
    public let requestDigest: String

    public init(
        containerID: String,
        operationGeneration: UInt64,
        candidateProcessGeneration: UInt64,
        sandboxGeneration: UInt64,
        requestDigest: String
    ) {
        self.containerID = containerID
        self.operationGeneration = operationGeneration
        self.candidateProcessGeneration = candidateProcessGeneration
        self.sandboxGeneration = sandboxGeneration
        self.requestDigest = requestDigest
    }
}

public struct WorkloadEffectReceiptV1: Equatable, Sendable {
    public let domain: EngineWorkloadEffectDomainV1
    public let leaseID: String
    public let leaseGeneration: UInt64
    public let effectID: String
    public let integrityDigest: String

    public init(
        domain: EngineWorkloadEffectDomainV1,
        leaseID: String,
        leaseGeneration: UInt64,
        effectID: String,
        integrityDigest: String
    ) {
        self.domain = domain
        self.leaseID = leaseID
        self.leaseGeneration = leaseGeneration
        self.effectID = effectID
        self.integrityDigest = integrityDigest
    }
}

public enum WorkloadEffectObservationV1: Equatable, Sendable {
    case absent
    case applied(WorkloadEffectReceiptV1)
    case compensated(WorkloadEffectReceiptV1)
    case unknown
}

/// One specialized controller bound to a single immutable workload intent.
/// `reservation` is side-effect-free. Apply and compensation must be
/// idempotent for the exact effect identity supplied by the resolver.
public protocol WorkloadEffectControllerV1: Sendable {
    var domain: EngineWorkloadEffectDomainV1 { get }

    func reservation(for context: WorkloadStartContextV1) async throws -> EngineWorkloadEffectV1
    func apply(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectReceiptV1
    func observe(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectObservationV1
    func compensate(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> WorkloadEffectReceiptV1
}

public struct WorkloadProcessReceiptV1: Equatable, Sendable {
    public let containerID: String
    public let operationGeneration: UInt64
    public let processGeneration: UInt64
    public let sandboxGeneration: UInt64
    public let requestDigest: String

    public init(
        containerID: String,
        operationGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64,
        requestDigest: String
    ) {
        self.containerID = containerID
        self.operationGeneration = operationGeneration
        self.processGeneration = processGeneration
        self.sandboxGeneration = sandboxGeneration
        self.requestDigest = requestDigest
    }
}

public enum WorkloadProcessObservationV1: Equatable, Sendable {
    case absent
    case started(WorkloadProcessReceiptV1)
    case unknown
}

public protocol WorkloadProcessStarterV1: Sendable {
    func start(context: WorkloadStartContextV1) async throws -> WorkloadProcessReceiptV1
    func observe(context: WorkloadStartContextV1) async throws -> WorkloadProcessObservationV1
}

/// Orders independently owned effects around one candidate process start.
///
/// The caller supplies controllers in dependency order. The resolver persists
/// every reservation before apply, validates the complete receipt tuple, and
/// compensates confirmed effects in reverse order when a later step is known
/// not to have happened. Any inconclusive observation fences the workload.
public actor WorkloadPlanResolverV1 {
    private struct AppliedEffect: Sendable {
        let controller: any WorkloadEffectControllerV1
        let effect: EngineWorkloadEffectV1
    }

    private let ledger: EngineWorkloadLedgerV1

    public init(ledger: EngineWorkloadLedgerV1) {
        self.ledger = ledger
    }

    public func start(
        _ request: EngineWorkloadMutationRequestV1,
        sandboxGeneration: UInt64,
        controllers: [any WorkloadEffectControllerV1],
        process: any WorkloadProcessStarterV1
    ) async throws -> EngineWorkloadRecordV1 {
        try validateUniqueDomains(controllers)
        let reservation = try await ledger.beginStart(request, sandboxGeneration: sandboxGeneration)
        let starting: EngineWorkloadRecordV1
        switch reservation {
        case .reserved(let record):
            starting = record
        case .replay(let record):
            if record.state == .running {
                return record
            }
            guard record.state == .starting else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
            starting = record
        }
        let operation = try requireOperation(starting)
        let context = WorkloadStartContextV1(
            containerID: starting.containerID,
            operationGeneration: operation.operationGeneration,
            candidateProcessGeneration: try require(operation.candidateProcessGeneration),
            sandboxGeneration: try require(operation.sandboxGeneration),
            requestDigest: operation.requestDigest
        )

        var applied = [AppliedEffect]()
        for controller in controllers {
            let effect: EngineWorkloadEffectV1
            do {
                effect = try await controller.reservation(for: context)
            } catch {
                try await compensate(applied, context: context)
                throw WorkloadPlanResolverError.effectFailed(controller.domain)
            }
            guard effect.domain == controller.domain, effect.state == .reserved else {
                try await compensate(applied, context: context)
                throw WorkloadPlanResolverError.invalidReservation(controller.domain)
            }
            let record = try await ledger.reserveEffect(
                containerID: context.containerID,
                operationGeneration: context.operationGeneration,
                effect: effect
            )
            let persisted = try requireEffect(effect.effectID, in: record)
            switch persisted.state {
            case .applied:
                applied.append(.init(controller: controller, effect: persisted))
                continue
            case .reserved:
                break
            case .unknown:
                throw WorkloadPlanResolverError.recoveryRequired
            case .active, .compensating, .compensated:
                try await fenceOperation(context, reason: "effect state cannot continue start")
                throw WorkloadPlanResolverError.recoveryRequired
            }

            switch try await apply(controller, effect: persisted, context: context) {
            case .applied:
                _ = try await ledger.acknowledgeEffectApplied(
                    containerID: context.containerID,
                    operationGeneration: context.operationGeneration,
                    effectID: persisted.effectID
                )
                applied.append(.init(controller: controller, effect: persisted))
            case .absent:
                try await compensate(applied, context: context)
                throw WorkloadPlanResolverError.effectFailed(controller.domain)
            case .unknown:
                _ = try await ledger.markEffectUnknown(
                    containerID: context.containerID,
                    operationGeneration: context.operationGeneration,
                    effectID: persisted.effectID,
                    reason: "effect apply outcome is unknown"
                )
                throw WorkloadPlanResolverError.recoveryRequired
            }
        }

        switch try await startProcess(process, context: context) {
        case .started:
            _ = try await ledger.recordProcessStarted(
                containerID: context.containerID,
                operationGeneration: context.operationGeneration
            )
            return try await ledger.commitStart(
                containerID: context.containerID,
                operationGeneration: context.operationGeneration
            )
        case .absent:
            try await compensate(applied, context: context)
            throw WorkloadPlanResolverError.processFailed
        case .unknown:
            try await fenceOperation(context, reason: "process start outcome is unknown")
            throw WorkloadPlanResolverError.recoveryRequired
        }
    }

    private enum ApplyOutcome {
        case applied
        case absent
        case unknown
    }

    private func apply(
        _ controller: any WorkloadEffectControllerV1,
        effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) async throws -> ApplyOutcome {
        do {
            let receipt = try await controller.apply(effect, context: context)
            guard receipt.matches(effect) else {
                return .unknown
            }
            return .applied
        } catch {
            do {
                switch try await controller.observe(effect, context: context) {
                case .absent:
                    return .absent
                case .compensated(let receipt):
                    return receipt.matches(effect) ? .absent : .unknown
                case .applied(let receipt):
                    return receipt.matches(effect) ? .applied : .unknown
                case .unknown:
                    return .unknown
                }
            } catch {
                return .unknown
            }
        }
    }

    private enum ProcessStartOutcome {
        case started
        case absent
        case unknown
    }

    private func startProcess(
        _ process: any WorkloadProcessStarterV1,
        context: WorkloadStartContextV1
    ) async throws -> ProcessStartOutcome {
        do {
            return try await process.start(context: context).matches(context) ? .started : .unknown
        } catch {
            do {
                switch try await process.observe(context: context) {
                case .absent:
                    return .absent
                case .started(let receipt):
                    return receipt.matches(context) ? .started : .unknown
                case .unknown:
                    return .unknown
                }
            } catch {
                return .unknown
            }
        }
    }

    private func compensate(
        _ applied: [AppliedEffect],
        context: WorkloadStartContextV1
    ) async throws {
        _ = try await ledger.beginStartCompensation(
            containerID: context.containerID,
            operationGeneration: context.operationGeneration
        )
        for item in applied.reversed() {
            let compensated: Bool
            do {
                compensated = try await item.controller.compensate(item.effect, context: context).matches(item.effect)
            } catch {
                do {
                    switch try await item.controller.observe(item.effect, context: context) {
                    case .absent:
                        compensated = true
                    case .compensated(let receipt):
                        compensated = receipt.matches(item.effect)
                    case .applied, .unknown:
                        compensated = false
                    }
                } catch {
                    compensated = false
                }
            }
            guard compensated else {
                _ = try await ledger.markEffectUnknown(
                    containerID: context.containerID,
                    operationGeneration: context.operationGeneration,
                    effectID: item.effect.effectID,
                    reason: "effect compensation outcome is unknown"
                )
                throw WorkloadPlanResolverError.recoveryRequired
            }
            _ = try await ledger.acknowledgeEffectCompensated(
                containerID: context.containerID,
                operationGeneration: context.operationGeneration,
                effectID: item.effect.effectID
            )
        }
        _ = try await ledger.completeStartFailure(
            containerID: context.containerID,
            operationGeneration: context.operationGeneration
        )
    }

    private func validateUniqueDomains(_ controllers: [any WorkloadEffectControllerV1]) throws {
        var domains = Set<EngineWorkloadEffectDomainV1>()
        for controller in controllers where !domains.insert(controller.domain).inserted {
            throw WorkloadPlanResolverError.duplicateDomain(controller.domain)
        }
    }

    private func fenceOperation(_ context: WorkloadStartContextV1, reason: String) async throws {
        _ = try await ledger.markOperationRecoveryRequired(
            containerID: context.containerID,
            operationGeneration: context.operationGeneration,
            reason: reason
        )
    }

    private func requireOperation(_ record: EngineWorkloadRecordV1) throws -> EngineWorkloadOperationV1 {
        guard let operation = record.operation else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        return operation
    }

    private func requireEffect(_ effectID: String, in record: EngineWorkloadRecordV1) throws -> EngineWorkloadEffectV1 {
        guard let effect = record.operation?.effects.first(where: { $0.effectID == effectID }) else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        return effect
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw WorkloadPlanResolverError.recoveryRequired }
        return value
    }
}

extension WorkloadEffectReceiptV1 {
    fileprivate func matches(_ effect: EngineWorkloadEffectV1) -> Bool {
        domain == effect.domain && leaseID == effect.leaseID && leaseGeneration == effect.leaseGeneration
            && effectID == effect.effectID && integrityDigest == effect.integrityDigest
    }
}

extension WorkloadProcessReceiptV1 {
    fileprivate func matches(_ context: WorkloadStartContextV1) -> Bool {
        containerID == context.containerID && operationGeneration == context.operationGeneration
            && processGeneration == context.candidateProcessGeneration
            && sandboxGeneration == context.sandboxGeneration && requestDigest == context.requestDigest
    }
}
