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

public enum EngineLinuxSandboxManagerError: Error, Equatable, Sendable {
    case invalidReceipt
    case recoveryRequired
}

public struct EngineLinuxSandboxBootRequestV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let generation: UInt64
    public let idempotencyKey: String
    public let requestDigest: String
    public let effectID: String

    public init(
        sandboxID: String,
        generation: UInt64,
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.effectID = effectID
    }
}

public struct EngineLinuxSandboxBootReceiptV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let generation: UInt64
    public let effectID: String
    public let requestDigest: String
    public let runtimeFingerprint: String

    public init(
        sandboxID: String,
        generation: UInt64,
        effectID: String,
        requestDigest: String,
        runtimeFingerprint: String
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.effectID = effectID
        self.requestDigest = requestDigest
        self.runtimeFingerprint = runtimeFingerprint
    }
}

public enum EngineLinuxSandboxBootObservationV1: Codable, Equatable, Sendable {
    case absent
    case ready(EngineLinuxSandboxBootReceiptV1)
    case unknown
}

public struct EngineLinuxSandboxShutdownRequestV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let generation: UInt64
    public let idempotencyKey: String
    public let requestDigest: String
    public let effectID: String

    public init(
        sandboxID: String,
        generation: UInt64,
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.effectID = effectID
    }
}

public struct EngineLinuxSandboxShutdownReceiptV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let generation: UInt64
    public let effectID: String
    public let requestDigest: String

    public init(
        sandboxID: String,
        generation: UInt64,
        effectID: String,
        requestDigest: String
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.effectID = effectID
        self.requestDigest = requestDigest
    }
}

public enum EngineLinuxSandboxShutdownObservationV1: Codable, Equatable, Sendable {
    case absent(EngineLinuxSandboxShutdownReceiptV1)
    case running
    case unknown
}

public protocol EngineLinuxSandboxRuntimeV1: Sendable {
    func boot(_ request: EngineLinuxSandboxBootRequestV1) async throws -> EngineLinuxSandboxBootReceiptV1
    func observeBoot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootObservationV1
    func shutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownReceiptV1
    func observeShutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownObservationV1
}

/// Owns only the shared Linux sandbox lifecycle. Per-workload namespace,
/// network, volume, resource, logging, and engine-socket effects remain in the
/// workload ledger and are materialized by their specialized controllers.
public actor EngineLinuxSandboxManagerV1 {
    private let ledger: EngineWorkloadLedgerV1
    private let runtime: any EngineLinuxSandboxRuntimeV1

    public init(
        ledger: EngineWorkloadLedgerV1,
        runtime: any EngineLinuxSandboxRuntimeV1
    ) {
        self.ledger = ledger
        self.runtime = runtime
    }

    public func ensureReady(
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) async throws -> EngineLinuxSandboxRecordV1 {
        let reservation = try await ledger.beginSandboxBoot(
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
        let record: EngineLinuxSandboxRecordV1
        let isNew: Bool
        switch reservation {
        case .reserved(let value):
            record = value
            isNew = true
        case .replay(let value):
            record = value
            isNew = false
        }

        if record.state == .ready {
            return record
        }
        let request = try bootRequest(from: record)
        if isNew {
            let receipt: EngineLinuxSandboxBootReceiptV1
            do {
                receipt = try await runtime.boot(request)
            } catch {
                try await markRecovery("sandbox boot outcome is unknown")
                throw error
            }
            return try await commitReady(receipt, request: request)
        }

        switch try await runtime.observeBoot(request) {
        case .ready(let receipt):
            return try await commitReady(receipt, request: request)
        case .absent:
            let receipt: EngineLinuxSandboxBootReceiptV1
            do {
                receipt = try await runtime.boot(request)
            } catch {
                try await markRecovery("sandbox boot retry outcome is unknown")
                throw error
            }
            return try await commitReady(receipt, request: request)
        case .unknown:
            try await markRecovery("sandbox boot reconciliation is inconclusive")
            throw EngineLinuxSandboxManagerError.recoveryRequired
        }
    }

    public func shutdownIfIdle(
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) async throws -> EngineLinuxSandboxRecordV1 {
        let reservation = try await ledger.beginSandboxStop(
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
        let record: EngineLinuxSandboxRecordV1
        let isNew: Bool
        switch reservation {
        case .reserved(let value):
            record = value
            isNew = true
        case .replay(let value):
            record = value
            isNew = false
        }
        if record.state == .absent {
            return record
        }
        let request = try shutdownRequest(from: record)
        if isNew {
            let receipt: EngineLinuxSandboxShutdownReceiptV1
            do {
                receipt = try await runtime.shutdown(request)
            } catch {
                try await markRecovery("sandbox shutdown outcome is unknown")
                throw error
            }
            return try await commitAbsent(receipt, request: request)
        }

        switch try await runtime.observeShutdown(request) {
        case .absent(let receipt):
            return try await commitAbsent(receipt, request: request)
        case .running:
            let receipt: EngineLinuxSandboxShutdownReceiptV1
            do {
                receipt = try await runtime.shutdown(request)
            } catch {
                try await markRecovery("sandbox shutdown retry outcome is unknown")
                throw error
            }
            return try await commitAbsent(receipt, request: request)
        case .unknown:
            try await markRecovery("sandbox shutdown reconciliation is inconclusive")
            throw EngineLinuxSandboxManagerError.recoveryRequired
        }
    }

    private func bootRequest(from record: EngineLinuxSandboxRecordV1) throws -> EngineLinuxSandboxBootRequestV1 {
        guard record.state == .booting || record.state == .recoveryRequired,
            let idempotencyKey = record.idempotencyKey,
            let requestDigest = record.requestDigest,
            let effectID = record.effectID
        else { throw EngineLinuxSandboxManagerError.recoveryRequired }
        return .init(
            sandboxID: record.sandboxID,
            generation: record.generation,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
    }

    private func shutdownRequest(
        from record: EngineLinuxSandboxRecordV1
    ) throws -> EngineLinuxSandboxShutdownRequestV1 {
        guard record.state == .stopping || record.state == .recoveryRequired,
            let idempotencyKey = record.idempotencyKey,
            let requestDigest = record.requestDigest,
            let effectID = record.effectID
        else { throw EngineLinuxSandboxManagerError.recoveryRequired }
        return .init(
            sandboxID: record.sandboxID,
            generation: record.generation,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
    }

    private func commitReady(
        _ receipt: EngineLinuxSandboxBootReceiptV1,
        request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxRecordV1 {
        guard receipt.sandboxID == request.sandboxID,
            receipt.generation == request.generation,
            receipt.effectID == request.effectID,
            receipt.requestDigest == request.requestDigest,
            !receipt.runtimeFingerprint.isEmpty
        else {
            try await markRecovery("sandbox boot receipt does not match its reservation")
            throw EngineLinuxSandboxManagerError.invalidReceipt
        }
        return try await ledger.commitSandboxReady(
            effectID: receipt.effectID,
            runtimeFingerprint: receipt.runtimeFingerprint
        )
    }

    private func commitAbsent(
        _ receipt: EngineLinuxSandboxShutdownReceiptV1,
        request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxRecordV1 {
        guard receipt.sandboxID == request.sandboxID,
            receipt.generation == request.generation,
            receipt.effectID == request.effectID,
            receipt.requestDigest == request.requestDigest
        else {
            try await markRecovery("sandbox shutdown receipt does not match its reservation")
            throw EngineLinuxSandboxManagerError.invalidReceipt
        }
        return try await ledger.commitSandboxAbsent(effectID: receipt.effectID)
    }

    private func markRecovery(_ reason: String) async throws {
        _ = try await ledger.markSandboxRecoveryRequired(reason: reason)
    }
}
