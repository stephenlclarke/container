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

import Darwin
import Foundation

public enum EngineWorkloadLedgerLimitsV1 {
    public static let maximumWorkloads = 4_096
    public static let maximumEffectsPerOperation = 128
    public static let maximumSnapshotBytes = 16 * 1024 * 1024
    public static let maximumIdentifierBytes = 256
    public static let maximumDigestBytes = 512
    public static let maximumRecoveryReasonBytes = 4_096
}

public enum EngineWorkloadLedgerError: Error, Equatable, Sendable {
    case capacityExceeded(collection: String, maximum: Int)
    case corruptSnapshot(String)
    case persistenceExceedsLimit(maximumBytes: Int)
    case idempotencyConflict
    case staleGeneration
    case staleOperation
    case invalidTransition(expected: String, actual: String)
    case duplicateEffect
    case effectNotFound
    case incompleteEffects
    case recoveryRequired
    case persistenceFailed
}

public protocol EngineWorkloadLedgerPersistenceV1: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public actor InMemoryEngineWorkloadLedgerPersistenceV1: EngineWorkloadLedgerPersistenceV1 {
    private var data: Data?

    public init(initialData: Data? = nil) {
        self.data = initialData
    }

    public func load() -> Data? {
        data
    }

    public func save(_ data: Data) {
        self.data = data
    }
}

public actor FileEngineWorkloadLedgerPersistenceV1: EngineWorkloadLedgerPersistenceV1 {
    private let fileURL: URL
    private let maximumBytes: Int

    public init(
        fileURL: URL,
        maximumBytes: Int = EngineWorkloadLedgerLimitsV1.maximumSnapshotBytes
    ) throws {
        guard fileURL.isFileURL, maximumBytes > 0 else {
            throw EngineWorkloadLedgerError.corruptSnapshot(
                "file persistence requires a file URL and positive byte limit"
            )
        }
        self.fileURL = fileURL.standardizedFileURL
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> Data? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return nil }
        try rejectNonRegularOrSymbolicLink()
        let attributes = try manager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw EngineWorkloadLedgerError.persistenceExceedsLimit(maximumBytes: maximumBytes)
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw EngineWorkloadLedgerError.persistenceExceedsLimit(maximumBytes: maximumBytes)
        }
        return data
    }

    public func save(_ data: Data) throws {
        guard data.count <= maximumBytes else {
            throw EngineWorkloadLedgerError.persistenceExceedsLimit(maximumBytes: maximumBytes)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try rejectNonRegularOrSymbolicLink()
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensureProtectedDirectory(directory, manager: manager)
        try data.write(to: fileURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try rejectNonRegularOrSymbolicLink()
        try synchronize(fileURL)
        try synchronize(directory, directory: true)
    }

    private func ensureProtectedDirectory(
        _ directory: URL,
        manager: FileManager
    ) throws {
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            directory.resolvingSymlinksInPath().standardizedFileURL.path
                == directory.path
        else {
            throw EngineWorkloadLedgerError.corruptSnapshot(
                "workload ledger directory must be a non-symbolic-link directory"
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func rejectNonRegularOrSymbolicLink() throws {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw EngineWorkloadLedgerError.corruptSnapshot(
                "workload ledger path must be a regular non-symbolic-link file"
            )
        }
    }

    private func synchronize(_ url: URL, directory: Bool = false) throws {
        let flags =
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            | (directory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        let expected = directory ? S_IFDIR : S_IFREG
        guard
            Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == expected,
            Darwin.fsync(descriptor) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum EngineLinuxSandboxStateV1: String, Codable, Equatable, Sendable {
    case absent
    case booting
    case ready
    case stopping
    case recoveryRequired
}

public enum EngineLinuxSandboxOperationKindV1: String, Codable, Equatable, Sendable {
    case boot
    case stop
}

public struct EngineLinuxSandboxRecordV1: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let sandboxID: String
    public let generation: UInt64
    public let revision: UInt64
    public let state: EngineLinuxSandboxStateV1
    public let operationKind: EngineLinuxSandboxOperationKindV1?
    public let idempotencyKey: String?
    public let requestDigest: String?
    public let effectID: String?
    public let runtimeFingerprint: String?
    public let recoveryReason: String?

    public init(
        sandboxID: String,
        generation: UInt64 = 0,
        revision: UInt64 = 0,
        state: EngineLinuxSandboxStateV1 = .absent,
        operationKind: EngineLinuxSandboxOperationKindV1? = nil,
        idempotencyKey: String? = nil,
        requestDigest: String? = nil,
        effectID: String? = nil,
        runtimeFingerprint: String? = nil,
        recoveryReason: String? = nil
    ) throws {
        try EngineWorkloadLedgerValidation.identifier(sandboxID, field: "sandboxID")
        try EngineWorkloadLedgerValidation.optionalIdentifier(idempotencyKey, field: "idempotencyKey")
        try EngineWorkloadLedgerValidation.optionalIdentifier(effectID, field: "effectID")
        try EngineWorkloadLedgerValidation.optionalDigest(requestDigest, field: "requestDigest")
        try EngineWorkloadLedgerValidation.optionalDigest(runtimeFingerprint, field: "runtimeFingerprint")
        try EngineWorkloadLedgerValidation.optionalReason(recoveryReason)
        self.schemaVersion = 1
        self.sandboxID = sandboxID
        self.generation = generation
        self.revision = revision
        self.state = state
        self.operationKind = operationKind
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.effectID = effectID
        self.runtimeFingerprint = runtimeFingerprint
        self.recoveryReason = recoveryReason
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw EngineWorkloadLedgerError.corruptSnapshot("unsupported sandbox record version")
        }
        try EngineWorkloadLedgerValidation.identifier(sandboxID, field: "sandboxID")
        try EngineWorkloadLedgerValidation.counter(generation, field: "sandbox generation")
        try EngineWorkloadLedgerValidation.counter(revision, field: "sandbox revision")
        try EngineWorkloadLedgerValidation.optionalIdentifier(idempotencyKey, field: "idempotencyKey")
        try EngineWorkloadLedgerValidation.optionalIdentifier(effectID, field: "effectID")
        try EngineWorkloadLedgerValidation.optionalDigest(requestDigest, field: "requestDigest")
        try EngineWorkloadLedgerValidation.optionalDigest(runtimeFingerprint, field: "runtimeFingerprint")
        try EngineWorkloadLedgerValidation.optionalReason(recoveryReason)
        switch state {
        case .absent:
            let initial =
                generation == 0 && operationKind == nil && idempotencyKey == nil && requestDigest == nil
                && effectID == nil
            let stopped =
                generation > 0 && operationKind == .stop && idempotencyKey != nil && requestDigest != nil
                && effectID != nil
            guard initial || stopped, runtimeFingerprint == nil, recoveryReason == nil else {
                throw EngineWorkloadLedgerError.corruptSnapshot("invalid absent sandbox authority")
            }
        case .booting:
            guard generation > 0, operationKind == .boot, idempotencyKey != nil, requestDigest != nil, effectID != nil,
                runtimeFingerprint == nil, recoveryReason == nil
            else { throw EngineWorkloadLedgerError.corruptSnapshot("incomplete sandbox operation") }
        case .stopping:
            guard generation > 0, operationKind == .stop, idempotencyKey != nil, requestDigest != nil, effectID != nil,
                runtimeFingerprint == nil, recoveryReason == nil
            else { throw EngineWorkloadLedgerError.corruptSnapshot("incomplete sandbox operation") }
        case .ready:
            guard generation > 0, operationKind == .boot, idempotencyKey != nil,
                requestDigest != nil, effectID != nil, runtimeFingerprint != nil,
                recoveryReason == nil
            else { throw EngineWorkloadLedgerError.corruptSnapshot("incomplete ready sandbox") }
        case .recoveryRequired:
            guard generation > 0, operationKind != nil, requestDigest != nil, effectID != nil, recoveryReason != nil else {
                throw EngineWorkloadLedgerError.corruptSnapshot("incomplete sandbox recovery evidence")
            }
        }
    }
}

public enum EngineWorkloadStateV1: String, Codable, Equatable, Sendable {
    case created
    case starting
    case running
    case pausing
    case paused
    case resuming
    case stopping
    case stopped
    case removing
    case recoveryRequired
    case removed
}

public enum EngineWorkloadOperationKindV1: String, Codable, Equatable, Sendable {
    case start
    case pause
    case resume
    case stop
    case remove
}

public enum EngineWorkloadOperationPhaseV1: String, Codable, Equatable, Sendable {
    case reserved
    case preparing
    case processStarted
    case compensating
    case recoveryRequired
}

public enum EngineWorkloadEffectDomainV1: String, Codable, CaseIterable, Hashable, Sendable {
    case namespace
    case network
    case volume
    case rootfs
    case resource
    case device
    case security
    case logging
    case engineSocket
    case modelRoute
}

public enum EngineWorkloadEffectStateV1: String, Codable, Equatable, Hashable, Sendable {
    case reserved
    case applied
    case active
    case compensating
    case compensated
    case unknown
}

public struct EngineWorkloadEffectV1: Codable, Equatable, Sendable {
    public let domain: EngineWorkloadEffectDomainV1
    public let leaseID: String
    public let leaseGeneration: UInt64
    public let effectID: String
    public let integrityDigest: String
    public let state: EngineWorkloadEffectStateV1

    public init(
        domain: EngineWorkloadEffectDomainV1,
        leaseID: String,
        leaseGeneration: UInt64,
        effectID: String,
        integrityDigest: String,
        state: EngineWorkloadEffectStateV1 = .reserved
    ) throws {
        try EngineWorkloadLedgerValidation.identifier(leaseID, field: "leaseID")
        try EngineWorkloadLedgerValidation.identifier(effectID, field: "effectID")
        try EngineWorkloadLedgerValidation.digest(integrityDigest, field: "integrityDigest")
        guard leaseGeneration > 0 else { throw EngineWorkloadLedgerError.staleGeneration }
        self.domain = domain
        self.leaseID = leaseID
        self.leaseGeneration = leaseGeneration
        self.effectID = effectID
        self.integrityDigest = integrityDigest
        self.state = state
        try validate()
    }

    public func validate() throws {
        try EngineWorkloadLedgerValidation.identifier(leaseID, field: "leaseID")
        try EngineWorkloadLedgerValidation.counter(leaseGeneration, field: "leaseGeneration", allowsZero: false)
        try EngineWorkloadLedgerValidation.identifier(effectID, field: "effectID")
        try EngineWorkloadLedgerValidation.digest(integrityDigest, field: "integrityDigest")
    }

    fileprivate func with(state: EngineWorkloadEffectStateV1) throws -> Self {
        try .init(
            domain: domain,
            leaseID: leaseID,
            leaseGeneration: leaseGeneration,
            effectID: effectID,
            integrityDigest: integrityDigest,
            state: state
        )
    }

    fileprivate func hasSameReservation(as other: Self) -> Bool {
        domain == other.domain && leaseID == other.leaseID && leaseGeneration == other.leaseGeneration
            && effectID == other.effectID && integrityDigest == other.integrityDigest
    }
}

public struct EngineWorkloadOperationV1: Codable, Equatable, Sendable {
    public let kind: EngineWorkloadOperationKindV1
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let requestDigest: String
    public let candidateProcessGeneration: UInt64?
    public let sandboxGeneration: UInt64?
    public let returnState: EngineWorkloadStateV1
    public let phase: EngineWorkloadOperationPhaseV1
    public let effects: [EngineWorkloadEffectV1]

    public init(
        kind: EngineWorkloadOperationKindV1,
        operationGeneration: UInt64,
        idempotencyKey: String,
        requestDigest: String,
        candidateProcessGeneration: UInt64?,
        sandboxGeneration: UInt64?,
        returnState: EngineWorkloadStateV1,
        phase: EngineWorkloadOperationPhaseV1 = .reserved,
        effects: [EngineWorkloadEffectV1] = []
    ) throws {
        guard operationGeneration > 0 else { throw EngineWorkloadLedgerError.staleGeneration }
        try EngineWorkloadLedgerValidation.identifier(idempotencyKey, field: "idempotencyKey")
        try EngineWorkloadLedgerValidation.digest(requestDigest, field: "requestDigest")
        guard effects.count <= EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation else {
            throw EngineWorkloadLedgerError.capacityExceeded(
                collection: "operation effects",
                maximum: EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation
            )
        }
        guard Set(effects.map(\.effectID)).count == effects.count else {
            throw EngineWorkloadLedgerError.duplicateEffect
        }
        self.kind = kind
        self.operationGeneration = operationGeneration
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.candidateProcessGeneration = candidateProcessGeneration
        self.sandboxGeneration = sandboxGeneration
        self.returnState = returnState
        self.phase = phase
        self.effects = effects
        try validate()
    }

    public func validate() throws {
        try EngineWorkloadLedgerValidation.counter(
            operationGeneration,
            field: "operationGeneration",
            allowsZero: false
        )
        try EngineWorkloadLedgerValidation.identifier(idempotencyKey, field: "idempotencyKey")
        try EngineWorkloadLedgerValidation.digest(requestDigest, field: "requestDigest")
        if let candidateProcessGeneration {
            try EngineWorkloadLedgerValidation.counter(
                candidateProcessGeneration,
                field: "candidateProcessGeneration",
                allowsZero: false
            )
        }
        if let sandboxGeneration {
            try EngineWorkloadLedgerValidation.counter(
                sandboxGeneration,
                field: "sandboxGeneration",
                allowsZero: false
            )
        }
        guard effects.count <= EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation else {
            throw EngineWorkloadLedgerError.capacityExceeded(
                collection: "operation effects",
                maximum: EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation
            )
        }
        guard Set(effects.map(\.effectID)).count == effects.count else {
            throw EngineWorkloadLedgerError.duplicateEffect
        }
        try effects.forEach { try $0.validate() }
        switch kind {
        case .start:
            guard candidateProcessGeneration != nil, sandboxGeneration != nil,
                returnState == .created || returnState == .stopped
            else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid start operation") }
        case .pause:
            guard candidateProcessGeneration != nil, sandboxGeneration != nil, returnState == .running,
                effects.isEmpty
            else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid pause operation") }
        case .resume:
            guard candidateProcessGeneration != nil, sandboxGeneration != nil, returnState == .paused,
                effects.isEmpty
            else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid resume operation") }
        case .stop:
            guard candidateProcessGeneration != nil, sandboxGeneration != nil,
                returnState == .running || returnState == .paused
            else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid stop operation") }
        case .remove:
            guard sandboxGeneration == nil, returnState == .created || returnState == .stopped else {
                throw EngineWorkloadLedgerError.corruptSnapshot("invalid remove operation")
            }
        }
    }

    fileprivate func replacing(
        phase: EngineWorkloadOperationPhaseV1? = nil,
        effects: [EngineWorkloadEffectV1]? = nil
    ) throws -> Self {
        try .init(
            kind: kind,
            operationGeneration: operationGeneration,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            candidateProcessGeneration: candidateProcessGeneration,
            sandboxGeneration: sandboxGeneration,
            returnState: returnState,
            phase: phase ?? self.phase,
            effects: effects ?? self.effects
        )
    }
}

public enum EngineWorkloadOperationOutcomeV1: String, Codable, Equatable, Sendable {
    case running
    case paused
    case resumed
    case stopped
    case startFailed
    case removed
}

public struct EngineWorkloadTerminalOperationV1: Codable, Equatable, Sendable {
    public let kind: EngineWorkloadOperationKindV1
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let requestDigest: String
    public let outcome: EngineWorkloadOperationOutcomeV1
    public let processGeneration: UInt64?

    fileprivate func validate() throws {
        try EngineWorkloadLedgerValidation.counter(
            operationGeneration,
            field: "terminal operationGeneration",
            allowsZero: false
        )
        try EngineWorkloadLedgerValidation.identifier(idempotencyKey, field: "terminal idempotencyKey")
        try EngineWorkloadLedgerValidation.digest(requestDigest, field: "terminal requestDigest")
        if let processGeneration {
            try EngineWorkloadLedgerValidation.counter(
                processGeneration,
                field: "terminal processGeneration",
                allowsZero: false
            )
        }
    }
}

public struct EngineWorkloadRecordV1: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let containerID: String
    public let planDigest: String
    public let state: EngineWorkloadStateV1
    public let transitionRevision: UInt64
    public let latestProcessGeneration: UInt64?
    public let activeProcessGeneration: UInt64?
    public let activeSandboxGeneration: UInt64?
    public let activeEffects: [EngineWorkloadEffectV1]
    public let operation: EngineWorkloadOperationV1?
    public let lastOperation: EngineWorkloadTerminalOperationV1?
    public let recoveryReason: String?

    public init(
        containerID: String,
        planDigest: String,
        state: EngineWorkloadStateV1 = .created,
        transitionRevision: UInt64 = 0,
        latestProcessGeneration: UInt64? = nil,
        activeProcessGeneration: UInt64? = nil,
        activeSandboxGeneration: UInt64? = nil,
        activeEffects: [EngineWorkloadEffectV1] = [],
        operation: EngineWorkloadOperationV1? = nil,
        lastOperation: EngineWorkloadTerminalOperationV1? = nil,
        recoveryReason: String? = nil
    ) throws {
        try EngineWorkloadLedgerValidation.identifier(containerID, field: "containerID")
        try EngineWorkloadLedgerValidation.digest(planDigest, field: "planDigest")
        try EngineWorkloadLedgerValidation.optionalReason(recoveryReason)
        self.schemaVersion = 1
        self.containerID = containerID
        self.planDigest = planDigest
        self.state = state
        self.transitionRevision = transitionRevision
        self.latestProcessGeneration = latestProcessGeneration
        self.activeProcessGeneration = activeProcessGeneration
        self.activeSandboxGeneration = activeSandboxGeneration
        self.activeEffects = activeEffects
        self.operation = operation
        self.lastOperation = lastOperation
        self.recoveryReason = recoveryReason
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw EngineWorkloadLedgerError.corruptSnapshot("unsupported workload record version")
        }
        try EngineWorkloadLedgerValidation.identifier(containerID, field: "containerID")
        try EngineWorkloadLedgerValidation.digest(planDigest, field: "planDigest")
        try EngineWorkloadLedgerValidation.counter(transitionRevision, field: "transitionRevision")
        for (field, generation) in [
            ("latestProcessGeneration", latestProcessGeneration),
            ("activeProcessGeneration", activeProcessGeneration),
            ("activeSandboxGeneration", activeSandboxGeneration),
        ] {
            if let generation {
                try EngineWorkloadLedgerValidation.counter(generation, field: field, allowsZero: false)
            }
        }
        try EngineWorkloadLedgerValidation.optionalReason(recoveryReason)
        guard activeEffects.count <= EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation,
            Set(activeEffects.map(\.effectID)).count == activeEffects.count,
            activeEffects.allSatisfy({ $0.state == .active })
        else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid active effects") }
        try activeEffects.forEach { try $0.validate() }
        try operation?.validate()
        try lastOperation?.validate()
        guard activeProcessGeneration == nil || activeProcessGeneration == latestProcessGeneration else {
            throw EngineWorkloadLedgerError.corruptSnapshot("active process is not the latest committed generation")
        }
        guard (activeProcessGeneration == nil) == (activeSandboxGeneration == nil) else {
            throw EngineWorkloadLedgerError.corruptSnapshot("workload active tuple is incomplete")
        }
        let requiresActiveTuple =
            state == .running || state == .paused || state == .pausing || state == .resuming
            || state == .stopping
        let forbidsActiveTuple =
            state == .created || state == .starting || state == .stopped || state == .removing
            || state == .removed
        guard !requiresActiveTuple || activeProcessGeneration != nil,
            !forbidsActiveTuple || activeProcessGeneration == nil
        else {
            throw EngineWorkloadLedgerError.corruptSnapshot("workload active tuple does not match state")
        }
        let operating = [.starting, .pausing, .resuming, .stopping, .removing, .recoveryRequired].contains(state)
        guard (operation != nil) == operating else {
            throw EngineWorkloadLedgerError.corruptSnapshot("workload operation does not match state")
        }
        if let operation, state != .recoveryRequired {
            let expectedKind: EngineWorkloadOperationKindV1
            switch state {
            case .starting: expectedKind = .start
            case .pausing: expectedKind = .pause
            case .resuming: expectedKind = .resume
            case .stopping: expectedKind = .stop
            case .removing: expectedKind = .remove
            default: throw EngineWorkloadLedgerError.corruptSnapshot("unexpected workload operation")
            }
            guard operation.kind == expectedKind else {
                throw EngineWorkloadLedgerError.corruptSnapshot("workload operation kind does not match state")
            }
        }
        guard (state == .recoveryRequired) == (recoveryReason != nil) else {
            throw EngineWorkloadLedgerError.corruptSnapshot("workload recovery reason does not match state")
        }
        if state == .removed {
            guard activeEffects.isEmpty, operation == nil else {
                throw EngineWorkloadLedgerError.corruptSnapshot("removed workload retains live effects")
            }
        }
    }

    fileprivate func replacing(
        state: EngineWorkloadStateV1? = nil,
        transitionRevision: UInt64? = nil,
        latestProcessGeneration: UInt64?? = nil,
        activeProcessGeneration: UInt64?? = nil,
        activeSandboxGeneration: UInt64?? = nil,
        activeEffects: [EngineWorkloadEffectV1]? = nil,
        operation: EngineWorkloadOperationV1?? = nil,
        lastOperation: EngineWorkloadTerminalOperationV1?? = nil,
        recoveryReason: String?? = nil
    ) throws -> Self {
        try .init(
            containerID: containerID,
            planDigest: planDigest,
            state: state ?? self.state,
            transitionRevision: transitionRevision ?? self.transitionRevision,
            latestProcessGeneration: latestProcessGeneration ?? self.latestProcessGeneration,
            activeProcessGeneration: activeProcessGeneration ?? self.activeProcessGeneration,
            activeSandboxGeneration: activeSandboxGeneration ?? self.activeSandboxGeneration,
            activeEffects: activeEffects ?? self.activeEffects,
            operation: operation ?? self.operation,
            lastOperation: lastOperation ?? self.lastOperation,
            recoveryReason: recoveryReason ?? self.recoveryReason
        )
    }
}

public struct EngineWorkloadLedgerSnapshotV1: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let owningControllerID: String
    public let sandbox: EngineLinuxSandboxRecordV1
    public let workloads: [EngineWorkloadRecordV1]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case owningControllerID
        case sandbox
        case workloads
    }

    public init(
        owningControllerID: String,
        sandbox: EngineLinuxSandboxRecordV1,
        workloads: [EngineWorkloadRecordV1] = []
    ) throws {
        try EngineWorkloadLedgerValidation.identifier(owningControllerID, field: "owningControllerID")
        guard workloads.count <= EngineWorkloadLedgerLimitsV1.maximumWorkloads else {
            throw EngineWorkloadLedgerError.capacityExceeded(
                collection: "workloads",
                maximum: EngineWorkloadLedgerLimitsV1.maximumWorkloads
            )
        }
        guard Set(workloads.map(\.containerID)).count == workloads.count else {
            throw EngineWorkloadLedgerError.corruptSnapshot("duplicate workload ID")
        }
        try sandbox.validate()
        try workloads.forEach { try $0.validate() }
        self.schemaVersion = 1
        self.owningControllerID = owningControllerID
        self.sandbox = sandbox
        self.workloads = workloads.sorted { $0.containerID < $1.containerID }
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw EngineWorkloadLedgerError.corruptSnapshot("unsupported workload ledger version")
        }
        _ = try Self(owningControllerID: owningControllerID, sandbox: sandbox, workloads: workloads)
    }

    public init(from decoder: any Decoder) throws {
        try EngineWorkloadLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "workload ledger snapshot"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported workload ledger version \(version)"
            )
        }
        try self.init(
            owningControllerID: container.decode(String.self, forKey: .owningControllerID),
            sandbox: container.decode(EngineLinuxSandboxRecordV1.self, forKey: .sandbox),
            workloads: container.decode([EngineWorkloadRecordV1].self, forKey: .workloads)
        )
    }
}

public struct EngineWorkloadMutationRequestV1: Equatable, Sendable {
    public let containerID: String
    public let idempotencyKey: String
    public let requestDigest: String
    public let expectedTransitionRevision: UInt64?

    public init(
        containerID: String,
        idempotencyKey: String,
        requestDigest: String,
        expectedTransitionRevision: UInt64? = nil
    ) {
        self.containerID = containerID
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.expectedTransitionRevision = expectedTransitionRevision
    }
}

public enum EngineWorkloadOperationReservationV1: Equatable, Sendable {
    case reserved(EngineWorkloadRecordV1)
    case replay(EngineWorkloadRecordV1)
}

public enum EngineSandboxOperationReservationV1: Equatable, Sendable {
    case reserved(EngineLinuxSandboxRecordV1)
    case replay(EngineLinuxSandboxRecordV1)
}

public actor EngineWorkloadLedgerV1 {
    public nonisolated let owningControllerID: String

    private let persistence: (any EngineWorkloadLedgerPersistenceV1)?
    private var currentSnapshot: EngineWorkloadLedgerSnapshotV1
    private var persistenceFailed = false

    public init(owningControllerID: String, sandboxID: String) throws {
        let sandbox = try EngineLinuxSandboxRecordV1(sandboxID: sandboxID)
        self.owningControllerID = owningControllerID
        self.persistence = nil
        self.currentSnapshot = try .init(owningControllerID: owningControllerID, sandbox: sandbox)
    }

    private init(
        snapshot: EngineWorkloadLedgerSnapshotV1,
        persistence: any EngineWorkloadLedgerPersistenceV1
    ) {
        self.owningControllerID = snapshot.owningControllerID
        self.persistence = persistence
        self.currentSnapshot = snapshot
    }

    public static func open(
        owningControllerID: String,
        sandboxID: String,
        persistence: any EngineWorkloadLedgerPersistenceV1
    ) async throws -> EngineWorkloadLedgerV1 {
        var changed = false
        let snapshot: EngineWorkloadLedgerSnapshotV1
        if let data = try await persistence.load() {
            guard data.count <= EngineWorkloadLedgerLimitsV1.maximumSnapshotBytes else {
                throw EngineWorkloadLedgerError.persistenceExceedsLimit(
                    maximumBytes: EngineWorkloadLedgerLimitsV1.maximumSnapshotBytes
                )
            }
            var loaded = try JSONDecoder().decode(EngineWorkloadLedgerSnapshotV1.self, from: data)
            try loaded.validate()
            guard loaded.owningControllerID == owningControllerID,
                loaded.sandbox.sandboxID == sandboxID
            else {
                throw EngineWorkloadLedgerError.corruptSnapshot("workload ledger authority mismatch")
            }
            (loaded, changed) = try recoverInterruptedOperations(loaded)
            snapshot = loaded
        } else {
            snapshot = try .init(
                owningControllerID: owningControllerID,
                sandbox: .init(sandboxID: sandboxID)
            )
        }
        let ledger = EngineWorkloadLedgerV1(snapshot: snapshot, persistence: persistence)
        if changed {
            try await ledger.persist(snapshot)
        }
        return ledger
    }

    public func snapshot() -> EngineWorkloadLedgerSnapshotV1 {
        currentSnapshot
    }

    public func workload(containerID: String) -> EngineWorkloadRecordV1? {
        currentSnapshot.workloads.first { $0.containerID == containerID }
    }

    public func registerWorkload(containerID: String, planDigest: String) async throws -> EngineWorkloadRecordV1 {
        if let existing = workload(containerID: containerID) {
            guard existing.planDigest == planDigest else { throw EngineWorkloadLedgerError.idempotencyConflict }
            return existing
        }
        guard currentSnapshot.workloads.count < EngineWorkloadLedgerLimitsV1.maximumWorkloads else {
            throw EngineWorkloadLedgerError.capacityExceeded(
                collection: "workloads",
                maximum: EngineWorkloadLedgerLimitsV1.maximumWorkloads
            )
        }
        let record = try EngineWorkloadRecordV1(containerID: containerID, planDigest: planDigest)
        try await replacingWorkload(record, append: true)
        return record
    }

    public func beginStart(
        _ request: EngineWorkloadMutationRequestV1,
        sandboxGeneration: UInt64
    ) async throws -> EngineWorkloadOperationReservationV1 {
        var record = try requireWorkload(request.containerID)
        if let replay = try replay(record: record, request: request, kind: .start) { return .replay(replay) }
        try validateRequest(request, record: record)
        guard record.state == .created || record.state == .stopped else {
            throw invalidTransition("created or stopped", record.state)
        }
        guard currentSnapshot.sandbox.state == .ready,
            currentSnapshot.sandbox.generation == sandboxGeneration
        else { throw EngineWorkloadLedgerError.staleGeneration }

        let operationGeneration = nextOperationGeneration(record)
        let processGeneration = (record.latestProcessGeneration ?? 0) + 1
        let operation = try EngineWorkloadOperationV1(
            kind: .start,
            operationGeneration: operationGeneration,
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            candidateProcessGeneration: processGeneration,
            sandboxGeneration: sandboxGeneration,
            returnState: record.state
        )
        record = try record.replacing(
            state: .starting,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation)
        )
        try await replacingWorkload(record)
        return .reserved(record)
    }

    public func reserveEffect(
        containerID: String,
        operationGeneration: UInt64,
        effect: EngineWorkloadEffectV1
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        guard record.state == .starting || record.state == .removing else {
            throw invalidTransition("starting or removing", record.state)
        }
        var operation = record.operation!
        guard effect.state == .reserved else {
            throw invalidTransition("reserved effect", effect.state)
        }
        let reservedEffect = record.state == .removing ? try effect.with(state: .compensating) : effect
        if let existing = operation.effects.first(where: { $0.effectID == reservedEffect.effectID }) {
            guard existing.hasSameReservation(as: reservedEffect) else {
                throw EngineWorkloadLedgerError.duplicateEffect
            }
            return record
        }
        guard operation.effects.count < EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation else {
            throw EngineWorkloadLedgerError.capacityExceeded(
                collection: "operation effects",
                maximum: EngineWorkloadLedgerLimitsV1.maximumEffectsPerOperation
            )
        }
        var effects = operation.effects
        effects.append(reservedEffect)
        operation = try operation.replacing(phase: .preparing, effects: effects)
        record = try record.replacing(operation: .some(operation))
        try await replacingWorkload(record)
        return record
    }

    public func acknowledgeEffectApplied(
        containerID: String,
        operationGeneration: UInt64,
        effectID: String
    ) async throws -> EngineWorkloadRecordV1 {
        try await transitionEffect(
            containerID: containerID,
            operationGeneration: operationGeneration,
            effectID: effectID,
            expected: [.reserved],
            target: .applied
        )
    }

    public func recordProcessStarted(
        containerID: String,
        operationGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        guard record.state == .starting, record.operation?.kind == .start else {
            throw invalidTransition("starting", record.state)
        }
        let operation = try record.operation!.replacing(phase: .processStarted)
        record = try record.replacing(operation: .some(operation))
        try await replacingWorkload(record)
        return record
    }

    public func commitStart(
        containerID: String,
        operationGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        let operation = record.operation!
        guard record.state == .starting, operation.kind == .start, operation.phase == .processStarted else {
            throw invalidTransition("started candidate", record.state)
        }
        guard operation.effects.allSatisfy({ $0.state == .applied }) else {
            throw EngineWorkloadLedgerError.incompleteEffects
        }
        let processGeneration = try require(operation.candidateProcessGeneration)
        let sandboxGeneration = try require(operation.sandboxGeneration)
        let activeEffects = try operation.effects.map { try $0.with(state: .active) }
        let terminal = terminal(operation, outcome: .running, processGeneration: processGeneration)
        record = try record.replacing(
            state: .running,
            transitionRevision: record.transitionRevision + 1,
            latestProcessGeneration: .some(processGeneration),
            activeProcessGeneration: .some(processGeneration),
            activeSandboxGeneration: .some(sandboxGeneration),
            activeEffects: activeEffects,
            operation: .some(nil),
            lastOperation: .some(terminal)
        )
        try await replacingWorkload(record)
        return record
    }

    public func beginStartCompensation(
        containerID: String,
        operationGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        guard record.state == .starting, record.operation?.kind == .start else {
            throw invalidTransition("starting", record.state)
        }
        let effects = try record.operation!.effects.map { effect in
            switch effect.state {
            case .reserved:
                return try effect.with(state: .compensated)
            case .applied, .active:
                return try effect.with(state: .compensating)
            case .compensating, .compensated, .unknown:
                return effect
            }
        }
        let operation = try record.operation!.replacing(phase: .compensating, effects: effects)
        record = try record.replacing(operation: .some(operation))
        try await replacingWorkload(record)
        return record
    }

    public func acknowledgeEffectCompensated(
        containerID: String,
        operationGeneration: UInt64,
        effectID: String
    ) async throws -> EngineWorkloadRecordV1 {
        let record = try requireOperation(containerID, operationGeneration: operationGeneration)
        guard record.operation?.effects.last(where: { $0.state == .compensating })?.effectID == effectID else {
            throw EngineWorkloadLedgerError.invalidTransition(
                expected: "reverse reservation order",
                actual: effectID
            )
        }
        return try await transitionEffect(
            containerID: containerID,
            operationGeneration: operationGeneration,
            effectID: effectID,
            expected: [.compensating],
            target: .compensated
        )
    }

    public func markEffectUnknown(
        containerID: String,
        operationGeneration: UInt64,
        effectID: String,
        reason: String
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try await transitionEffect(
            containerID: containerID,
            operationGeneration: operationGeneration,
            effectID: effectID,
            expected: [.reserved, .applied, .active, .compensating],
            target: .unknown,
            persistResult: false
        )
        try EngineWorkloadLedgerValidation.optionalReason(reason)
        let operation = try record.operation!.replacing(phase: .recoveryRequired)
        record = try record.replacing(
            state: .recoveryRequired,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation),
            recoveryReason: .some(reason)
        )
        try await replacingWorkload(record)
        return record
    }

    public func markOperationRecoveryRequired(
        containerID: String,
        operationGeneration: UInt64,
        reason: String
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        try EngineWorkloadLedgerValidation.optionalReason(reason)
        let operation = try record.operation!.replacing(phase: .recoveryRequired)
        record = try record.replacing(
            state: .recoveryRequired,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation),
            recoveryReason: .some(reason)
        )
        try await replacingWorkload(record)
        return record
    }

    public func completeStartFailure(
        containerID: String,
        operationGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        let operation = record.operation!
        guard record.state == .starting, operation.kind == .start, operation.phase == .compensating else {
            throw invalidTransition("compensating start", record.state)
        }
        guard operation.effects.allSatisfy({ $0.state == .compensated }) else {
            throw EngineWorkloadLedgerError.incompleteEffects
        }
        let terminal = terminal(
            operation,
            outcome: .startFailed,
            processGeneration: operation.candidateProcessGeneration
        )
        record = try record.replacing(
            state: operation.returnState,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(nil),
            lastOperation: .some(terminal)
        )
        try await replacingWorkload(record)
        return record
    }

    public func beginPause(_ request: EngineWorkloadMutationRequestV1) async throws -> EngineWorkloadOperationReservationV1 {
        try await beginActiveMutation(request, kind: .pause, from: .running, to: .pausing)
    }

    public func commitPause(containerID: String, operationGeneration: UInt64) async throws -> EngineWorkloadRecordV1 {
        try await commitActiveMutation(
            containerID: containerID,
            operationGeneration: operationGeneration,
            kind: .pause,
            from: .pausing,
            to: .paused,
            outcome: .paused
        )
    }

    public func beginResume(_ request: EngineWorkloadMutationRequestV1) async throws -> EngineWorkloadOperationReservationV1 {
        try await beginActiveMutation(request, kind: .resume, from: .paused, to: .resuming)
    }

    public func commitResume(containerID: String, operationGeneration: UInt64) async throws -> EngineWorkloadRecordV1 {
        try await commitActiveMutation(
            containerID: containerID,
            operationGeneration: operationGeneration,
            kind: .resume,
            from: .resuming,
            to: .running,
            outcome: .resumed
        )
    }

    public func beginStop(_ request: EngineWorkloadMutationRequestV1) async throws -> EngineWorkloadOperationReservationV1 {
        var record = try requireWorkload(request.containerID)
        if let replay = try replay(record: record, request: request, kind: .stop) { return .replay(replay) }
        try validateRequest(request, record: record)
        guard record.state == .running || record.state == .paused else {
            throw invalidTransition("running or paused", record.state)
        }
        let operationGeneration = nextOperationGeneration(record)
        let effects = try record.activeEffects.map { try $0.with(state: .compensating) }
        let operation = try EngineWorkloadOperationV1(
            kind: .stop,
            operationGeneration: operationGeneration,
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            candidateProcessGeneration: record.activeProcessGeneration,
            sandboxGeneration: record.activeSandboxGeneration,
            returnState: record.state,
            phase: .compensating,
            effects: effects
        )
        record = try record.replacing(
            state: .stopping,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation)
        )
        try await replacingWorkload(record)
        return .reserved(record)
    }

    /// Reopens only an interrupted stop whose controller effects were already
    /// empty. The caller must still reconcile the exact runtime stop before
    /// committing; stops with compensating or unknown effects remain fenced.
    public func resumeEffectlessStop(
        _ request: EngineWorkloadMutationRequestV1
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireWorkload(request.containerID)
        guard
            record.state == .recoveryRequired,
            let operation = record.operation,
            operation.kind == .stop,
            operation.phase == .recoveryRequired,
            operation.effects.isEmpty,
            operation.idempotencyKey == request.idempotencyKey,
            operation.requestDigest == request.requestDigest,
            operation.candidateProcessGeneration
                == record.activeProcessGeneration,
            operation.sandboxGeneration == record.activeSandboxGeneration
        else {
            throw EngineWorkloadLedgerError.recoveryRequired
        }
        let resumed = try operation.replacing(phase: .compensating)
        record = try record.replacing(
            state: .stopping,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(resumed),
            recoveryReason: .some(nil)
        )
        try await replacingWorkload(record)
        return record
    }

    public func commitStop(containerID: String, operationGeneration: UInt64) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        let operation = record.operation!
        guard record.state == .stopping, operation.kind == .stop else {
            throw invalidTransition("stopping", record.state)
        }
        guard operation.effects.allSatisfy({ $0.state == .compensated }) else {
            throw EngineWorkloadLedgerError.incompleteEffects
        }
        let terminal = terminal(
            operation,
            outcome: .stopped,
            processGeneration: operation.candidateProcessGeneration
        )
        record = try record.replacing(
            state: .stopped,
            transitionRevision: record.transitionRevision + 1,
            activeProcessGeneration: .some(nil),
            activeSandboxGeneration: .some(nil),
            activeEffects: [],
            operation: .some(nil),
            lastOperation: .some(terminal)
        )
        try await replacingWorkload(record)
        return record
    }

    public func beginRemove(_ request: EngineWorkloadMutationRequestV1) async throws -> EngineWorkloadOperationReservationV1 {
        var record = try requireWorkload(request.containerID)
        if let replay = try replay(record: record, request: request, kind: .remove) { return .replay(replay) }
        try validateRequest(request, record: record)
        guard record.state == .created || record.state == .stopped else {
            throw invalidTransition("created or stopped", record.state)
        }
        let operation = try EngineWorkloadOperationV1(
            kind: .remove,
            operationGeneration: nextOperationGeneration(record),
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            candidateProcessGeneration: record.latestProcessGeneration,
            sandboxGeneration: nil,
            returnState: record.state,
            phase: .preparing
        )
        record = try record.replacing(
            state: .removing,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation)
        )
        try await replacingWorkload(record)
        return .reserved(record)
    }

    public func commitRemove(containerID: String, operationGeneration: UInt64) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        let operation = record.operation!
        guard record.state == .removing, operation.kind == .remove else {
            throw invalidTransition("removing", record.state)
        }
        guard operation.effects.allSatisfy({ $0.state == .compensated }) else {
            throw EngineWorkloadLedgerError.incompleteEffects
        }
        let terminal = terminal(operation, outcome: .removed, processGeneration: record.latestProcessGeneration)
        record = try record.replacing(
            state: .removed,
            transitionRevision: record.transitionRevision + 1,
            activeEffects: [],
            operation: .some(nil),
            lastOperation: .some(terminal)
        )
        try await replacingWorkload(record)
        return record
    }

    public func beginSandboxBoot(
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) async throws -> EngineSandboxOperationReservationV1 {
        let current = currentSnapshot.sandbox
        if current.operationKind == .boot, current.idempotencyKey == idempotencyKey {
            guard current.requestDigest == requestDigest, current.effectID == effectID else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return .replay(current)
        }
        guard current.state == .absent else {
            throw invalidTransition("absent sandbox", current.state)
        }
        let next = try EngineLinuxSandboxRecordV1(
            sandboxID: current.sandboxID,
            generation: current.generation + 1,
            revision: current.revision + 1,
            state: .booting,
            operationKind: .boot,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
        try await replacingSandbox(next)
        return .reserved(next)
    }

    public func commitSandboxReady(effectID: String, runtimeFingerprint: String) async throws -> EngineLinuxSandboxRecordV1 {
        let current = currentSnapshot.sandbox
        guard current.state == .booting || current.state == .recoveryRequired,
            current.effectID == effectID
        else { throw EngineWorkloadLedgerError.staleOperation }
        let next = try EngineLinuxSandboxRecordV1(
            sandboxID: current.sandboxID,
            generation: current.generation,
            revision: current.revision + 1,
            state: .ready,
            operationKind: .boot,
            idempotencyKey: current.idempotencyKey,
            requestDigest: current.requestDigest,
            effectID: current.effectID,
            runtimeFingerprint: runtimeFingerprint
        )
        try await replacingSandbox(next)
        return next
    }

    public func markSandboxRecoveryRequired(reason: String) async throws -> EngineLinuxSandboxRecordV1 {
        let current = currentSnapshot.sandbox
        guard current.state != .absent else { throw invalidTransition("non-absent sandbox", current.state) }
        let next = try EngineLinuxSandboxRecordV1(
            sandboxID: current.sandboxID,
            generation: current.generation,
            revision: current.revision + 1,
            state: .recoveryRequired,
            operationKind: current.operationKind,
            idempotencyKey: current.idempotencyKey,
            requestDigest: current.requestDigest,
            effectID: current.effectID,
            recoveryReason: reason
        )
        try await replacingSandbox(next)
        return next
    }

    public func beginSandboxStop(
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) async throws -> EngineSandboxOperationReservationV1 {
        let current = currentSnapshot.sandbox
        if current.operationKind == .stop, current.idempotencyKey == idempotencyKey {
            guard current.requestDigest == requestDigest, current.effectID == effectID else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return .replay(current)
        }
        guard current.state == .ready else { throw invalidTransition("ready sandbox", current.state) }
        guard
            !currentSnapshot.workloads.contains(where: {
                $0.state == .running || $0.state == .paused || $0.operation != nil
            })
        else { throw EngineWorkloadLedgerError.invalidTransition(expected: "idle sandbox", actual: "active workloads") }
        let next = try EngineLinuxSandboxRecordV1(
            sandboxID: current.sandboxID,
            generation: current.generation,
            revision: current.revision + 1,
            state: .stopping,
            operationKind: .stop,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            effectID: effectID
        )
        try await replacingSandbox(next)
        return .reserved(next)
    }

    public func commitSandboxAbsent(effectID: String) async throws -> EngineLinuxSandboxRecordV1 {
        let current = currentSnapshot.sandbox
        guard current.state == .stopping || current.state == .recoveryRequired,
            current.effectID == effectID
        else { throw EngineWorkloadLedgerError.staleOperation }
        let next = try EngineLinuxSandboxRecordV1(
            sandboxID: current.sandboxID,
            generation: current.generation,
            revision: current.revision + 1,
            state: .absent,
            operationKind: .stop,
            idempotencyKey: current.idempotencyKey,
            requestDigest: current.requestDigest,
            effectID: current.effectID
        )
        try await replacingSandbox(next)
        return next
    }

    private func beginActiveMutation(
        _ request: EngineWorkloadMutationRequestV1,
        kind: EngineWorkloadOperationKindV1,
        from: EngineWorkloadStateV1,
        to: EngineWorkloadStateV1
    ) async throws -> EngineWorkloadOperationReservationV1 {
        var record = try requireWorkload(request.containerID)
        if let replay = try replay(record: record, request: request, kind: kind) { return .replay(replay) }
        try validateRequest(request, record: record)
        guard record.state == from else { throw invalidTransition(from.rawValue, record.state) }
        let operation = try EngineWorkloadOperationV1(
            kind: kind,
            operationGeneration: nextOperationGeneration(record),
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            candidateProcessGeneration: record.activeProcessGeneration,
            sandboxGeneration: record.activeSandboxGeneration,
            returnState: record.state
        )
        record = try record.replacing(
            state: to,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(operation)
        )
        try await replacingWorkload(record)
        return .reserved(record)
    }

    private func commitActiveMutation(
        containerID: String,
        operationGeneration: UInt64,
        kind: EngineWorkloadOperationKindV1,
        from: EngineWorkloadStateV1,
        to: EngineWorkloadStateV1,
        outcome: EngineWorkloadOperationOutcomeV1
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        let operation = record.operation!
        guard record.state == from, operation.kind == kind else { throw invalidTransition(from.rawValue, record.state) }
        let terminal = terminal(operation, outcome: outcome, processGeneration: record.activeProcessGeneration)
        record = try record.replacing(
            state: to,
            transitionRevision: record.transitionRevision + 1,
            operation: .some(nil),
            lastOperation: .some(terminal)
        )
        try await replacingWorkload(record)
        return record
    }

    private func transitionEffect(
        containerID: String,
        operationGeneration: UInt64,
        effectID: String,
        expected: Set<EngineWorkloadEffectStateV1>,
        target: EngineWorkloadEffectStateV1,
        persistResult: Bool = true
    ) async throws -> EngineWorkloadRecordV1 {
        var record = try requireOperation(containerID, operationGeneration: operationGeneration)
        var operation = record.operation!
        guard let index = operation.effects.firstIndex(where: { $0.effectID == effectID }) else {
            throw EngineWorkloadLedgerError.effectNotFound
        }
        let current = operation.effects[index]
        if current.state == target { return record }
        guard expected.contains(current.state) else {
            throw EngineWorkloadLedgerError.invalidTransition(expected: "\(expected)", actual: current.state.rawValue)
        }
        var effects = operation.effects
        effects[index] = try current.with(state: target)
        operation = try operation.replacing(effects: effects)
        record = try record.replacing(operation: .some(operation))
        if persistResult { try await replacingWorkload(record) }
        return record
    }

    private func requireWorkload(_ containerID: String) throws -> EngineWorkloadRecordV1 {
        guard let record = workload(containerID: containerID) else {
            throw EngineWorkloadLedgerError.corruptSnapshot("unknown workload '\(containerID)'")
        }
        return record
    }

    private func requireOperation(
        _ containerID: String,
        operationGeneration: UInt64
    ) throws -> EngineWorkloadRecordV1 {
        let record = try requireWorkload(containerID)
        guard record.operation?.operationGeneration == operationGeneration else {
            throw EngineWorkloadLedgerError.staleOperation
        }
        return record
    }

    private func replay(
        record: EngineWorkloadRecordV1,
        request: EngineWorkloadMutationRequestV1,
        kind: EngineWorkloadOperationKindV1
    ) throws -> EngineWorkloadRecordV1? {
        if let operation = record.operation, operation.idempotencyKey == request.idempotencyKey {
            guard operation.kind == kind, operation.requestDigest == request.requestDigest else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return record
        }
        if let operation = record.lastOperation, operation.idempotencyKey == request.idempotencyKey {
            guard operation.kind == kind, operation.requestDigest == request.requestDigest else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return record
        }
        return nil
    }

    private func validateRequest(
        _ request: EngineWorkloadMutationRequestV1,
        record: EngineWorkloadRecordV1
    ) throws {
        try EngineWorkloadLedgerValidation.identifier(request.idempotencyKey, field: "idempotencyKey")
        try EngineWorkloadLedgerValidation.digest(request.requestDigest, field: "requestDigest")
        if let expected = request.expectedTransitionRevision, expected != record.transitionRevision {
            throw EngineWorkloadLedgerError.staleGeneration
        }
        if record.state == .recoveryRequired { throw EngineWorkloadLedgerError.recoveryRequired }
    }

    private func nextOperationGeneration(_ record: EngineWorkloadRecordV1) -> UInt64 {
        max(record.operation?.operationGeneration ?? 0, record.lastOperation?.operationGeneration ?? 0) + 1
    }

    private func terminal(
        _ operation: EngineWorkloadOperationV1,
        outcome: EngineWorkloadOperationOutcomeV1,
        processGeneration: UInt64?
    ) -> EngineWorkloadTerminalOperationV1 {
        .init(
            kind: operation.kind,
            operationGeneration: operation.operationGeneration,
            idempotencyKey: operation.idempotencyKey,
            requestDigest: operation.requestDigest,
            outcome: outcome,
            processGeneration: processGeneration
        )
    }

    private func replacingSandbox(_ sandbox: EngineLinuxSandboxRecordV1) async throws {
        let snapshot = try EngineWorkloadLedgerSnapshotV1(
            owningControllerID: owningControllerID,
            sandbox: sandbox,
            workloads: currentSnapshot.workloads
        )
        try await persist(snapshot)
    }

    private func replacingWorkload(_ record: EngineWorkloadRecordV1, append: Bool = false) async throws {
        var workloads = currentSnapshot.workloads
        if append {
            workloads.append(record)
        } else if let index = workloads.firstIndex(where: { $0.containerID == record.containerID }) {
            workloads[index] = record
        } else {
            throw EngineWorkloadLedgerError.corruptSnapshot("unknown workload '\(record.containerID)'")
        }
        let snapshot = try EngineWorkloadLedgerSnapshotV1(
            owningControllerID: owningControllerID,
            sandbox: currentSnapshot.sandbox,
            workloads: workloads
        )
        try await persist(snapshot)
    }

    private func persist(_ snapshot: EngineWorkloadLedgerSnapshotV1) async throws {
        guard !persistenceFailed else { throw EngineWorkloadLedgerError.persistenceFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= EngineWorkloadLedgerLimitsV1.maximumSnapshotBytes else {
            throw EngineWorkloadLedgerError.persistenceExceedsLimit(
                maximumBytes: EngineWorkloadLedgerLimitsV1.maximumSnapshotBytes
            )
        }
        currentSnapshot = snapshot
        if let persistence {
            do {
                try await persistence.save(data)
            } catch {
                persistenceFailed = true
                throw error
            }
        }
        guard !persistenceFailed else { throw EngineWorkloadLedgerError.persistenceFailed }
    }

    private static func recoverInterruptedOperations(
        _ snapshot: EngineWorkloadLedgerSnapshotV1
    ) throws -> (EngineWorkloadLedgerSnapshotV1, Bool) {
        var changed = false
        var sandbox = snapshot.sandbox
        if sandbox.state == .booting || sandbox.state == .stopping {
            sandbox = try EngineLinuxSandboxRecordV1(
                sandboxID: sandbox.sandboxID,
                generation: sandbox.generation,
                revision: sandbox.revision + 1,
                state: .recoveryRequired,
                operationKind: sandbox.operationKind,
                idempotencyKey: sandbox.idempotencyKey,
                requestDigest: sandbox.requestDigest,
                effectID: sandbox.effectID,
                recoveryReason: "authority restarted during sandbox \(sandbox.state.rawValue)"
            )
            changed = true
        }
        let workloads = try snapshot.workloads.map { record -> EngineWorkloadRecordV1 in
            guard record.operation != nil, record.state != .recoveryRequired else { return record }
            changed = true
            let operation = try record.operation!.replacing(phase: .recoveryRequired)
            return try record.replacing(
                state: .recoveryRequired,
                transitionRevision: record.transitionRevision + 1,
                operation: .some(operation),
                recoveryReason: .some("authority restarted during \(record.state.rawValue)")
            )
        }
        return (
            try .init(
                owningControllerID: snapshot.owningControllerID,
                sandbox: sandbox,
                workloads: workloads
            ),
            changed
        )
    }

    private func invalidTransition<T>(_ expected: String, _ actual: T) -> EngineWorkloadLedgerError {
        .invalidTransition(expected: expected, actual: String(describing: actual))
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw EngineWorkloadLedgerError.corruptSnapshot("missing generation") }
        return value
    }
}

private struct EngineWorkloadLedgerAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum EngineWorkloadLedgerValidation {
    static func rejectUnknownKeys<Key>(
        from decoder: any Decoder,
        allowed: Key.Type,
        type: String
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: EngineWorkloadLedgerAnyCodingKey.self)
        let known = Set(Key.allCases.map(\.stringValue))
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown key '\(unknown)' in \(type)"
                )
            )
        }
    }

    static func counter(_ value: UInt64, field: String, allowsZero: Bool = true) throws {
        guard value < UInt64.max, allowsZero || value > 0 else {
            throw EngineWorkloadLedgerError.corruptSnapshot("invalid \(field)")
        }
    }

    static func identifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid \(field)") }
    }

    static func optionalIdentifier(_ value: String?, field: String) throws {
        if let value { try identifier(value, field: field) }
    }

    static func digest(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumDigestBytes,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid \(field)") }
    }

    static func optionalDigest(_ value: String?, field: String) throws {
        if let value { try digest(value, field: field) }
    }

    static func optionalReason(_ value: String?) throws {
        if let value {
            guard !value.isEmpty, value.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumRecoveryReasonBytes,
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw EngineWorkloadLedgerError.corruptSnapshot("invalid recovery reason") }
        }
    }
}
