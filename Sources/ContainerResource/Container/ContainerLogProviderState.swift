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

/// Wire and durable-state limits shared by logging provider lifecycle v1.
///
/// Limits are measured in UTF-8 bytes, not characters. They bound authenticated
/// provider IPC and authority ledgers without imposing a Docker-visible record
/// or history limit.
public enum LogDriverLifecycleLimitsV1 {
    public static let maximumIdentifierUTF8Bytes = 4 * 1024
    public static let maximumDigestUTF8Bytes = 1024
    public static let maximumIdempotencyKeyUTF8Bytes = 4 * 1024
    public static let maximumOpaqueEffectTokenBytes = 64 * 1024
}

public enum LogDriverLifecycleContractError: Error, Equatable, Sendable {
    case emptyField(String)
    case fieldExceedsUTF8Limit(field: String, maximumBytes: Int)
    case zeroGeneration(String)
    case invalidReadRequest(String)
    case invalidSessionState(String)
    case invalidReaderState(String)
    case effectReferenceBindingMismatch
    case effectTokenTooLarge(maximumBytes: Int)
    case invalidAcknowledgement(String)
}

private struct LogDriverLifecycleAnyCodingKey: CodingKey {
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

private enum LogDriverLifecycleValidation {
    static func rejectUnknownKeys<Key>(
        from decoder: any Decoder,
        allowed: Key.Type,
        type: String
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: LogDriverLifecycleAnyCodingKey.self)
        let known = Set(Key.allCases.map(\.stringValue))
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown key '\(unknown)' in \(type)"
                )
            )
        }
    }

    static func schemaVersion<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        expected: UInt32,
        type: String
    ) throws -> UInt32 {
        let version = try container.decode(UInt32.self, forKey: key)
        guard version == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "unsupported \(type) schema version \(version)"
            )
        }
        return version
    }

    static func identifier(_ value: String, field: String) throws {
        try boundedString(
            value,
            field: field,
            maximumBytes: LogDriverLifecycleLimitsV1.maximumIdentifierUTF8Bytes
        )
    }

    static func digest(_ value: String, field: String) throws {
        try boundedString(
            value,
            field: field,
            maximumBytes: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes
        )
    }

    static func idempotencyKey(_ value: String) throws {
        try boundedString(
            value,
            field: "idempotencyKey",
            maximumBytes: LogDriverLifecycleLimitsV1.maximumIdempotencyKeyUTF8Bytes
        )
    }

    static func generation(_ value: UInt64, field: String) throws {
        guard value > 0 else {
            throw LogDriverLifecycleContractError.zeroGeneration(field)
        }
    }

    static func optionalGeneration(_ value: UInt64?, field: String) throws {
        if let value {
            try generation(value, field: field)
        }
    }

    private static func boundedString(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty else {
            throw LogDriverLifecycleContractError.emptyField(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw LogDriverLifecycleContractError.fieldExceedsUTF8Limit(
                field: field,
                maximumBytes: maximumBytes
            )
        }
    }
}

public enum LoggingSessionState: String, Codable, Equatable, Sendable {
    case active
    case draining
    case recoveryRequired
    case closed
    case tombstoned
}

public enum LoggingSessionCloseDispositionV1: String, Codable, Equatable, Sendable {
    case complete
    case deadlineTruncated
}

public enum LoggingDetachedCleanupStateV1: String, Codable, Equatable, Sendable {
    case pending
    case recoveryRequired
    case complete
    case tombstoned
}

public enum LoggingReaderSessionStateV1: String, Codable, Equatable, Sendable {
    case active
    case closing
    case recoveryRequired
    case closed
    case tombstoned
}

/// A reader's immutable relationship to stopped history or one exact writer.
public enum LoggingReaderSourceV1: Codable, Equatable, Sendable {
    case stoppedContainer
    case activeWriter(
        sessionID: String,
        writerProviderID: String,
        writerProviderGeneration: UInt64,
        activeProcessGeneration: UInt64,
        activeSandboxGeneration: UInt64?
    )

    private enum Kind: String, Codable {
        case stoppedContainer = "stopped-container"
        case activeWriter = "active-writer"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case sessionID
        case writerProviderID
        case writerProviderGeneration
        case activeProcessGeneration
        case activeSandboxGeneration
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging reader source v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stoppedContainer:
            guard container.allKeys == [.kind] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "stopped reader source contains active-writer fields"
                )
            }
            self = .stoppedContainer
        case .activeWriter:
            try self.init(
                activeWriterSessionID: container.decode(String.self, forKey: .sessionID),
                writerProviderID: container.decode(String.self, forKey: .writerProviderID),
                writerProviderGeneration: container.decode(UInt64.self, forKey: .writerProviderGeneration),
                activeProcessGeneration: container.decode(UInt64.self, forKey: .activeProcessGeneration),
                activeSandboxGeneration: container.decodeIfPresent(
                    UInt64.self,
                    forKey: .activeSandboxGeneration
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stoppedContainer:
            try container.encode(Kind.stoppedContainer, forKey: .kind)
        case .activeWriter(
            let sessionID,
            let writerProviderID,
            let writerProviderGeneration,
            let activeProcessGeneration,
            let activeSandboxGeneration
        ):
            try container.encode(Kind.activeWriter, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(writerProviderID, forKey: .writerProviderID)
            try container.encode(writerProviderGeneration, forKey: .writerProviderGeneration)
            try container.encode(activeProcessGeneration, forKey: .activeProcessGeneration)
            try container.encodeIfPresent(activeSandboxGeneration, forKey: .activeSandboxGeneration)
        }
    }

    public init(
        activeWriterSessionID sessionID: String,
        writerProviderID: String,
        writerProviderGeneration: UInt64,
        activeProcessGeneration: UInt64,
        activeSandboxGeneration: UInt64?
    ) throws {
        try LogDriverLifecycleValidation.identifier(sessionID, field: "writerSessionID")
        try LogDriverLifecycleValidation.identifier(writerProviderID, field: "writerProviderID")
        try LogDriverLifecycleValidation.generation(
            writerProviderGeneration,
            field: "writerProviderGeneration"
        )
        try LogDriverLifecycleValidation.generation(
            activeProcessGeneration,
            field: "activeProcessGeneration"
        )
        try LogDriverLifecycleValidation.optionalGeneration(
            activeSandboxGeneration,
            field: "activeSandboxGeneration"
        )
        self = .activeWriter(
            sessionID: sessionID,
            writerProviderID: writerProviderID,
            writerProviderGeneration: writerProviderGeneration,
            activeProcessGeneration: activeProcessGeneration,
            activeSandboxGeneration: activeSandboxGeneration
        )
    }
}

/// The non-secret tuple to which one protected provider effect is sealed.
public struct ProtectedLoggingEffectBindingV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let effectID: String
    public let owningControllerID: String
    public let providerID: String
    public let providerGeneration: UInt64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case effectID
        case owningControllerID
        case providerID
        case providerGeneration
    }

    public init(
        effectID: String,
        owningControllerID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        try LogDriverLifecycleValidation.identifier(effectID, field: "effectID")
        try LogDriverLifecycleValidation.identifier(owningControllerID, field: "owningControllerID")
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        self.schemaVersion = Self.currentSchemaVersion
        self.effectID = effectID
        self.owningControllerID = owningControllerID
        self.providerID = providerID
        self.providerGeneration = providerGeneration
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "protected logging effect binding v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "protected logging effect binding"
        )
        try self.init(
            effectID: container.decode(String.self, forKey: .effectID),
            owningControllerID: container.decode(String.self, forKey: .owningControllerID),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration)
        )
    }
}

/// Complete common-store reference to opaque provider effect material.
///
/// This value contains no raw provider token bytes. `integrityDigest` is the
/// authority-lineage MAC over those bytes and the complete ``binding`` tuple.
public struct ProtectedLoggingEffectReferenceV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let effectID: String
    public let owningControllerID: String
    public let providerID: String
    public let providerGeneration: UInt64
    public let protectedStoreObjectID: String
    public let integrityDigest: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case effectID
        case owningControllerID
        case providerID
        case providerGeneration
        case protectedStoreObjectID
        case integrityDigest
    }

    public init(
        binding: ProtectedLoggingEffectBindingV1,
        protectedStoreObjectID: String,
        integrityDigest: String
    ) throws {
        try LogDriverLifecycleValidation.identifier(protectedStoreObjectID, field: "protectedStoreObjectID")
        try LogDriverLifecycleValidation.digest(integrityDigest, field: "integrityDigest")
        self.schemaVersion = Self.currentSchemaVersion
        self.effectID = binding.effectID
        self.owningControllerID = binding.owningControllerID
        self.providerID = binding.providerID
        self.providerGeneration = binding.providerGeneration
        self.protectedStoreObjectID = protectedStoreObjectID
        self.integrityDigest = integrityDigest
    }

    public init(
        effectID: String,
        owningControllerID: String,
        providerID: String,
        providerGeneration: UInt64,
        protectedStoreObjectID: String,
        integrityDigest: String
    ) throws {
        try self.init(
            binding: ProtectedLoggingEffectBindingV1(
                effectID: effectID,
                owningControllerID: owningControllerID,
                providerID: providerID,
                providerGeneration: providerGeneration
            ),
            protectedStoreObjectID: protectedStoreObjectID,
            integrityDigest: integrityDigest
        )
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "protected logging effect reference v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "protected logging effect reference"
        )
        try self.init(
            effectID: container.decode(String.self, forKey: .effectID),
            owningControllerID: container.decode(String.self, forKey: .owningControllerID),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            protectedStoreObjectID: container.decode(String.self, forKey: .protectedStoreObjectID),
            integrityDigest: container.decode(String.self, forKey: .integrityDigest)
        )
    }

    public var binding: ProtectedLoggingEffectBindingV1 {
        // Construction and decoding have already validated every component.
        ProtectedLoggingEffectBindingV1(
            validatedEffectID: effectID,
            owningControllerID: owningControllerID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    public func validateBinding(_ expected: ProtectedLoggingEffectBindingV1) throws {
        guard binding == expected else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
    }

    /// Requires every public reference field to match before protected-store
    /// resolution, including the object identifier and integrity digest.
    public func validateExactReference(_ expected: Self) throws {
        guard self == expected else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
    }
}

/// The lifecycle path that owns one durable protected-effect removal.
public enum LoggingEffectRemovalKindV1: String, Codable, Equatable, Sendable {
    case writerCandidate
    case writerSession
    case detachedCleanup
    case readerCandidate
    case readerSession
}

/// The exact terminal provider outcome retained until protected removal is
/// durably acknowledged. Keeping this outcome beside the complete protected
/// reference makes the terminal transition and cleanup intent one transaction.
public enum LoggingEffectRemovalTerminalOutcomeV1: Equatable, Sendable {
    case writerCandidateClosed
    case writerClosed(LoggingSessionCloseDispositionV1)
    case detachedCleanupCompleted(providerCloseOutcomeDigest: String)
    case readerCandidateClosed
    case readerClosed(terminalOutcomeDigest: String)
}

extension LoggingEffectRemovalTerminalOutcomeV1: Codable {
    private enum Kind: String, Codable {
        case writerCandidateClosed
        case writerClosed
        case detachedCleanupCompleted
        case readerCandidateClosed
        case readerClosed
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case writerCloseDisposition
        case outcomeDigest
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging effect removal terminal outcome v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .writerCandidateClosed:
            try Self.requireNoPayload(container)
            self = .writerCandidateClosed
        case .writerClosed:
            guard !container.contains(.outcomeDigest) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .writerClosed(
                try container.decode(
                    LoggingSessionCloseDispositionV1.self,
                    forKey: .writerCloseDisposition
                )
            )
        case .detachedCleanupCompleted:
            guard !container.contains(.writerCloseDisposition) else {
                throw Self.unexpectedPayload(in: container)
            }
            let digest = try container.decode(String.self, forKey: .outcomeDigest)
            try LogDriverLifecycleValidation.digest(
                digest,
                field: "providerCloseOutcomeDigest"
            )
            self = .detachedCleanupCompleted(providerCloseOutcomeDigest: digest)
        case .readerCandidateClosed:
            try Self.requireNoPayload(container)
            self = .readerCandidateClosed
        case .readerClosed:
            guard !container.contains(.writerCloseDisposition) else {
                throw Self.unexpectedPayload(in: container)
            }
            let digest = try container.decode(String.self, forKey: .outcomeDigest)
            try LogDriverLifecycleValidation.digest(
                digest,
                field: "terminalOutcomeDigest"
            )
            self = .readerClosed(terminalOutcomeDigest: digest)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .writerCandidateClosed:
            try container.encode(Kind.writerCandidateClosed, forKey: .kind)
        case .writerClosed(let disposition):
            try container.encode(Kind.writerClosed, forKey: .kind)
            try container.encode(disposition, forKey: .writerCloseDisposition)
        case .detachedCleanupCompleted(let digest):
            try container.encode(Kind.detachedCleanupCompleted, forKey: .kind)
            try container.encode(digest, forKey: .outcomeDigest)
        case .readerCandidateClosed:
            try container.encode(Kind.readerCandidateClosed, forKey: .kind)
        case .readerClosed(let digest):
            try container.encode(Kind.readerClosed, forKey: .kind)
            try container.encode(digest, forKey: .outcomeDigest)
        }
    }

    private static func requireNoPayload(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard
            !container.contains(.writerCloseDisposition),
            !container.contains(.outcomeDigest)
        else {
            throw unexpectedPayload(in: container)
        }
    }

    private static func unexpectedPayload(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "effect removal outcome contains payload for another kind"
            )
        )
    }
}

/// Redaction-safe durable transaction record for one protected-effect removal.
///
/// `ownerID` identifies the exact lifecycle record named by ``kind``. The
/// reference contains no raw token material and is retained until the secure
/// store has durably published its authenticated removal tombstone.
public struct LoggingEffectRemovalPendingV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let kind: LoggingEffectRemovalKindV1
    public let ownerID: String
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1
    public let terminalOutcome: LoggingEffectRemovalTerminalOutcomeV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case ownerID
        case effectTokenReference
        case terminalOutcome
    }

    public init(
        kind: LoggingEffectRemovalKindV1,
        ownerID: String,
        effectTokenReference: ProtectedLoggingEffectReferenceV1,
        terminalOutcome: LoggingEffectRemovalTerminalOutcomeV1
    ) throws {
        try LogDriverLifecycleValidation.identifier(ownerID, field: "effectRemovalOwnerID")
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.ownerID = ownerID
        self.effectTokenReference = effectTokenReference
        self.terminalOutcome = terminalOutcome
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging effect removal pending v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging effect removal pending"
        )
        try self.init(
            kind: container.decode(LoggingEffectRemovalKindV1.self, forKey: .kind),
            ownerID: container.decode(String.self, forKey: .ownerID),
            effectTokenReference: container.decode(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            ),
            terminalOutcome: container.decode(
                LoggingEffectRemovalTerminalOutcomeV1.self,
                forKey: .terminalOutcome
            )
        )
    }
}

extension ProtectedLoggingEffectBindingV1 {
    fileprivate init(
        validatedEffectID effectID: String,
        owningControllerID: String,
        providerID: String,
        providerGeneration: UInt64
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.effectID = effectID
        self.owningControllerID = owningControllerID
        self.providerID = providerID
        self.providerGeneration = providerGeneration
    }
}

public struct LoggingSessionPreparationV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let semanticRequestDigest: String
    public let sessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let candidateProcessGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let candidateSandboxGeneration: UInt64?
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case operationGeneration
        case idempotencyKey
        case semanticRequestDigest
        case sessionID
        case containerID
        case leaseGeneration
        case candidateProcessGeneration
        case providerID
        case providerGeneration
        case candidateSandboxGeneration
        case effectTokenReference
    }

    public init(
        operationGeneration: UInt64,
        idempotencyKey: String,
        semanticRequestDigest: String,
        sessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        candidateProcessGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        candidateSandboxGeneration: UInt64?,
        effectTokenReference: ProtectedLoggingEffectReferenceV1
    ) throws {
        try LogDriverLifecycleValidation.generation(operationGeneration, field: "operationGeneration")
        try LogDriverLifecycleValidation.idempotencyKey(idempotencyKey)
        try LogDriverLifecycleValidation.digest(semanticRequestDigest, field: "semanticRequestDigest")
        try LogDriverLifecycleValidation.identifier(sessionID, field: "sessionID")
        try LogDriverLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverLifecycleValidation.generation(
            candidateProcessGeneration,
            field: "candidateProcessGeneration"
        )
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        try LogDriverLifecycleValidation.optionalGeneration(
            candidateSandboxGeneration,
            field: "candidateSandboxGeneration"
        )
        try Self.validateReference(
            effectTokenReference,
            sessionID: sessionID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.operationGeneration = operationGeneration
        self.idempotencyKey = idempotencyKey
        self.semanticRequestDigest = semanticRequestDigest
        self.sessionID = sessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.candidateProcessGeneration = candidateProcessGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.candidateSandboxGeneration = candidateSandboxGeneration
        self.effectTokenReference = effectTokenReference
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging session preparation v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging session preparation"
        )
        try self.init(
            operationGeneration: container.decode(UInt64.self, forKey: .operationGeneration),
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            semanticRequestDigest: container.decode(String.self, forKey: .semanticRequestDigest),
            sessionID: container.decode(String.self, forKey: .sessionID),
            containerID: container.decode(String.self, forKey: .containerID),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            candidateProcessGeneration: container.decode(UInt64.self, forKey: .candidateProcessGeneration),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            candidateSandboxGeneration: container.decodeIfPresent(
                UInt64.self,
                forKey: .candidateSandboxGeneration
            ),
            effectTokenReference: container.decode(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            )
        )
    }

    public func validateEffectReference(owningControllerID: String) throws {
        try effectTokenReference.validateBinding(
            ProtectedLoggingEffectBindingV1(
                effectID: sessionID,
                owningControllerID: owningControllerID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        )
    }

    public func validateEffectReference(
        _ expected: ProtectedLoggingEffectReferenceV1,
        owningControllerID: String
    ) throws {
        try effectTokenReference.validateExactReference(expected)
        try validateEffectReference(owningControllerID: owningControllerID)
    }

    fileprivate static func validateReference(
        _ reference: ProtectedLoggingEffectReferenceV1,
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        guard
            reference.effectID == sessionID,
            reference.providerID == providerID,
            reference.providerGeneration == providerGeneration
        else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
    }
}

public struct LoggingSessionActivationV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let sessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let activeProcessGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let activeSandboxGeneration: UInt64?
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1?
    public let closeDisposition: LoggingSessionCloseDispositionV1?
    public let state: LoggingSessionState

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sessionID
        case containerID
        case leaseGeneration
        case activeProcessGeneration
        case providerID
        case providerGeneration
        case activeSandboxGeneration
        case effectTokenReference
        case closeDisposition
        case state
    }

    public init(
        sessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        activeProcessGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        activeSandboxGeneration: UInt64?,
        effectTokenReference: ProtectedLoggingEffectReferenceV1?,
        closeDisposition: LoggingSessionCloseDispositionV1?,
        state: LoggingSessionState
    ) throws {
        try LogDriverLifecycleValidation.identifier(sessionID, field: "sessionID")
        try LogDriverLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverLifecycleValidation.generation(activeProcessGeneration, field: "activeProcessGeneration")
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        try LogDriverLifecycleValidation.optionalGeneration(
            activeSandboxGeneration,
            field: "activeSandboxGeneration"
        )
        switch state {
        case .active, .draining, .recoveryRequired:
            guard effectTokenReference != nil, closeDisposition == nil else {
                throw LogDriverLifecycleContractError.invalidSessionState(
                    "live writer state requires an effect reference and no close disposition"
                )
            }
        case .closed, .tombstoned:
            guard effectTokenReference == nil, closeDisposition != nil else {
                throw LogDriverLifecycleContractError.invalidSessionState(
                    "terminal writer state requires a close disposition and no effect reference"
                )
            }
        }
        if let effectTokenReference {
            try LoggingSessionPreparationV1.validateReference(
                effectTokenReference,
                sessionID: sessionID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.activeProcessGeneration = activeProcessGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.activeSandboxGeneration = activeSandboxGeneration
        self.effectTokenReference = effectTokenReference
        self.closeDisposition = closeDisposition
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging session activation v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging session activation"
        )
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            containerID: container.decode(String.self, forKey: .containerID),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            activeProcessGeneration: container.decode(UInt64.self, forKey: .activeProcessGeneration),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            activeSandboxGeneration: container.decodeIfPresent(UInt64.self, forKey: .activeSandboxGeneration),
            effectTokenReference: container.decodeIfPresent(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            ),
            closeDisposition: container.decodeIfPresent(
                LoggingSessionCloseDispositionV1.self,
                forKey: .closeDisposition
            ),
            state: container.decode(LoggingSessionState.self, forKey: .state)
        )
    }

    public func validateEffectReference(owningControllerID: String) throws {
        if let effectTokenReference {
            try effectTokenReference.validateBinding(
                ProtectedLoggingEffectBindingV1(
                    effectID: sessionID,
                    owningControllerID: owningControllerID,
                    providerID: providerID,
                    providerGeneration: providerGeneration
                )
            )
        }
    }

    public func validateEffectReference(
        _ expected: ProtectedLoggingEffectReferenceV1?,
        owningControllerID: String
    ) throws {
        guard effectTokenReference == expected else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
        try validateEffectReference(owningControllerID: owningControllerID)
    }
}

public struct LoggingDetachedCleanupV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let cleanupID: String
    public let sessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let activeProcessGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let activeSandboxGeneration: UInt64?
    public let writerFenceReceiptDigest: String
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1?
    public let providerCloseOutcomeDigest: String?
    public let state: LoggingDetachedCleanupStateV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case cleanupID
        case sessionID
        case containerID
        case leaseGeneration
        case activeProcessGeneration
        case providerID
        case providerGeneration
        case activeSandboxGeneration
        case writerFenceReceiptDigest
        case effectTokenReference
        case providerCloseOutcomeDigest
        case state
    }

    public init(
        cleanupID: String,
        sessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        activeProcessGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        activeSandboxGeneration: UInt64?,
        writerFenceReceiptDigest: String,
        effectTokenReference: ProtectedLoggingEffectReferenceV1?,
        providerCloseOutcomeDigest: String?,
        state: LoggingDetachedCleanupStateV1
    ) throws {
        try LogDriverLifecycleValidation.identifier(cleanupID, field: "cleanupID")
        try LogDriverLifecycleValidation.identifier(sessionID, field: "sessionID")
        try LogDriverLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverLifecycleValidation.generation(activeProcessGeneration, field: "activeProcessGeneration")
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        try LogDriverLifecycleValidation.optionalGeneration(
            activeSandboxGeneration,
            field: "activeSandboxGeneration"
        )
        try LogDriverLifecycleValidation.digest(
            writerFenceReceiptDigest,
            field: "writerFenceReceiptDigest"
        )
        if let providerCloseOutcomeDigest {
            try LogDriverLifecycleValidation.digest(
                providerCloseOutcomeDigest,
                field: "providerCloseOutcomeDigest"
            )
        }
        switch state {
        case .pending, .recoveryRequired:
            guard effectTokenReference != nil, providerCloseOutcomeDigest == nil else {
                throw LogDriverLifecycleContractError.invalidSessionState(
                    "unfinished cleanup requires an effect reference and no close outcome"
                )
            }
        case .complete, .tombstoned:
            guard effectTokenReference == nil, providerCloseOutcomeDigest != nil else {
                throw LogDriverLifecycleContractError.invalidSessionState(
                    "terminal cleanup requires a close outcome and no effect reference"
                )
            }
        }
        if let effectTokenReference {
            try LoggingSessionPreparationV1.validateReference(
                effectTokenReference,
                sessionID: sessionID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.cleanupID = cleanupID
        self.sessionID = sessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.activeProcessGeneration = activeProcessGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.activeSandboxGeneration = activeSandboxGeneration
        self.writerFenceReceiptDigest = writerFenceReceiptDigest
        self.effectTokenReference = effectTokenReference
        self.providerCloseOutcomeDigest = providerCloseOutcomeDigest
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging detached cleanup v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging detached cleanup"
        )
        try self.init(
            cleanupID: container.decode(String.self, forKey: .cleanupID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            containerID: container.decode(String.self, forKey: .containerID),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            activeProcessGeneration: container.decode(UInt64.self, forKey: .activeProcessGeneration),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            activeSandboxGeneration: container.decodeIfPresent(UInt64.self, forKey: .activeSandboxGeneration),
            writerFenceReceiptDigest: container.decode(String.self, forKey: .writerFenceReceiptDigest),
            effectTokenReference: container.decodeIfPresent(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            ),
            providerCloseOutcomeDigest: container.decodeIfPresent(
                String.self,
                forKey: .providerCloseOutcomeDigest
            ),
            state: container.decode(LoggingDetachedCleanupStateV1.self, forKey: .state)
        )
    }

    public func validateEffectReference(owningControllerID: String) throws {
        if let effectTokenReference {
            try effectTokenReference.validateBinding(
                ProtectedLoggingEffectBindingV1(
                    effectID: sessionID,
                    owningControllerID: owningControllerID,
                    providerID: providerID,
                    providerGeneration: providerGeneration
                )
            )
        }
    }

    public func validateEffectReference(
        _ expected: ProtectedLoggingEffectReferenceV1?,
        owningControllerID: String
    ) throws {
        guard effectTokenReference == expected else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
        try validateEffectReference(owningControllerID: owningControllerID)
    }
}

public struct LoggingReaderPreparationV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let semanticRequestDigest: String
    public let readerSessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let source: LoggingReaderSourceV1
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case operationGeneration
        case idempotencyKey
        case semanticRequestDigest
        case readerSessionID
        case containerID
        case leaseGeneration
        case providerID
        case providerGeneration
        case source
        case effectTokenReference
    }

    public init(
        operationGeneration: UInt64,
        idempotencyKey: String,
        semanticRequestDigest: String,
        readerSessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        source: LoggingReaderSourceV1,
        effectTokenReference: ProtectedLoggingEffectReferenceV1
    ) throws {
        try LogDriverLifecycleValidation.generation(operationGeneration, field: "operationGeneration")
        try LogDriverLifecycleValidation.idempotencyKey(idempotencyKey)
        try LogDriverLifecycleValidation.digest(semanticRequestDigest, field: "semanticRequestDigest")
        try LogDriverLifecycleValidation.identifier(readerSessionID, field: "readerSessionID")
        try LogDriverLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        try Self.validateReference(
            effectTokenReference,
            readerSessionID: readerSessionID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.operationGeneration = operationGeneration
        self.idempotencyKey = idempotencyKey
        self.semanticRequestDigest = semanticRequestDigest
        self.readerSessionID = readerSessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.source = source
        self.effectTokenReference = effectTokenReference
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging reader preparation v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging reader preparation"
        )
        try self.init(
            operationGeneration: container.decode(UInt64.self, forKey: .operationGeneration),
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            semanticRequestDigest: container.decode(String.self, forKey: .semanticRequestDigest),
            readerSessionID: container.decode(String.self, forKey: .readerSessionID),
            containerID: container.decode(String.self, forKey: .containerID),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            source: container.decode(LoggingReaderSourceV1.self, forKey: .source),
            effectTokenReference: container.decode(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            )
        )
    }

    public func validateEffectReference(owningControllerID: String) throws {
        try effectTokenReference.validateBinding(
            ProtectedLoggingEffectBindingV1(
                effectID: readerSessionID,
                owningControllerID: owningControllerID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        )
    }

    public func validateEffectReference(
        _ expected: ProtectedLoggingEffectReferenceV1,
        owningControllerID: String
    ) throws {
        try effectTokenReference.validateExactReference(expected)
        try validateEffectReference(owningControllerID: owningControllerID)
    }

    fileprivate static func validateReference(
        _ reference: ProtectedLoggingEffectReferenceV1,
        readerSessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        guard
            reference.effectID == readerSessionID,
            reference.providerID == providerID,
            reference.providerGeneration == providerGeneration
        else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
    }
}

public struct LoggingReaderSessionV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let readerSessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let source: LoggingReaderSourceV1
    public let effectTokenReference: ProtectedLoggingEffectReferenceV1?
    public let terminalOutcomeDigest: String?
    public let state: LoggingReaderSessionStateV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case readerSessionID
        case containerID
        case leaseGeneration
        case providerID
        case providerGeneration
        case source
        case effectTokenReference
        case terminalOutcomeDigest
        case state
    }

    public init(
        readerSessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        source: LoggingReaderSourceV1,
        effectTokenReference: ProtectedLoggingEffectReferenceV1?,
        terminalOutcomeDigest: String?,
        state: LoggingReaderSessionStateV1
    ) throws {
        try LogDriverLifecycleValidation.identifier(readerSessionID, field: "readerSessionID")
        try LogDriverLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        if let terminalOutcomeDigest {
            try LogDriverLifecycleValidation.digest(terminalOutcomeDigest, field: "terminalOutcomeDigest")
        }
        switch state {
        case .active, .closing, .recoveryRequired:
            guard effectTokenReference != nil, terminalOutcomeDigest == nil else {
                throw LogDriverLifecycleContractError.invalidReaderState(
                    "live reader state requires an effect reference and no terminal outcome"
                )
            }
        case .closed, .tombstoned:
            guard effectTokenReference == nil, terminalOutcomeDigest != nil else {
                throw LogDriverLifecycleContractError.invalidReaderState(
                    "terminal reader state requires an outcome and no effect reference"
                )
            }
        }
        if let effectTokenReference {
            try LoggingReaderPreparationV1.validateReference(
                effectTokenReference,
                readerSessionID: readerSessionID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.readerSessionID = readerSessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.source = source
        self.effectTokenReference = effectTokenReference
        self.terminalOutcomeDigest = terminalOutcomeDigest
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging reader session v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try LogDriverLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging reader session"
        )
        try self.init(
            readerSessionID: container.decode(String.self, forKey: .readerSessionID),
            containerID: container.decode(String.self, forKey: .containerID),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            providerID: container.decode(String.self, forKey: .providerID),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            source: container.decode(LoggingReaderSourceV1.self, forKey: .source),
            effectTokenReference: container.decodeIfPresent(
                ProtectedLoggingEffectReferenceV1.self,
                forKey: .effectTokenReference
            ),
            terminalOutcomeDigest: container.decodeIfPresent(String.self, forKey: .terminalOutcomeDigest),
            state: container.decode(LoggingReaderSessionStateV1.self, forKey: .state)
        )
    }

    public func validateEffectReference(owningControllerID: String) throws {
        if let effectTokenReference {
            try effectTokenReference.validateBinding(
                ProtectedLoggingEffectBindingV1(
                    effectID: readerSessionID,
                    owningControllerID: owningControllerID,
                    providerID: providerID,
                    providerGeneration: providerGeneration
                )
            )
        }
    }

    public func validateEffectReference(
        _ expected: ProtectedLoggingEffectReferenceV1?,
        owningControllerID: String
    ) throws {
        guard effectTokenReference == expected else {
            throw LogDriverLifecycleContractError.effectReferenceBindingMismatch
        }
        try validateEffectReference(owningControllerID: owningControllerID)
    }
}
