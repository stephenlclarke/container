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

private struct LogDriverProviderAnyCodingKey: CodingKey {
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

private enum LogDriverProviderLifecycleValidation {
    static func rejectUnknownKeys<Key>(
        from decoder: any Decoder,
        allowed: Key.Type,
        type: String
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: LogDriverProviderAnyCodingKey.self)
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
    ) throws {
        let version = try container.decode(UInt32.self, forKey: key)
        guard version == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "unsupported \(type) schema version \(version)"
            )
        }
    }

    static func identifier(_ value: String, field: String) throws {
        try bounded(
            value,
            field: field,
            maximumBytes: LogDriverLifecycleLimitsV1.maximumIdentifierUTF8Bytes
        )
    }

    static func digest(_ value: String, field: String) throws {
        try bounded(
            value,
            field: field,
            maximumBytes: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes
        )
    }

    static func idempotencyKey(_ value: String) throws {
        try bounded(
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

    private static func bounded(
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

/// Driver-neutral filters for one bounded static or streaming log reader.
public struct ContainerLogReadRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedTransportBytes = 16 * 1024

    public let schemaVersion: UInt32
    public let stdout: Bool
    public let stderr: Bool
    public let follow: Bool
    public let tail: Int?
    public let since: Date?
    public let until: Date?
    public let timestamps: Bool
    public let details: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case stdout
        case stderr
        case follow
        case tail
        case since
        case until
        case timestamps
        case details
    }

    public init(
        stdout: Bool = true,
        stderr: Bool = true,
        follow: Bool = false,
        tail: Int? = nil,
        since: Date? = nil,
        until: Date? = nil,
        timestamps: Bool = false,
        details: Bool = false
    ) throws {
        if let tail, tail < 0 {
            throw LogDriverLifecycleContractError.invalidReadRequest("tail must be non-negative")
        }
        if let since, !since.timeIntervalSinceReferenceDate.isFinite {
            throw LogDriverLifecycleContractError.invalidReadRequest("since must be finite")
        }
        if let until, !until.timeIntervalSinceReferenceDate.isFinite {
            throw LogDriverLifecycleContractError.invalidReadRequest("until must be finite")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.stdout = stdout
        self.stderr = stderr
        self.follow = follow
        self.tail = tail
        self.since = since
        self.until = until
        self.timestamps = timestamps
        self.details = details
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverProviderLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "container log read request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try LogDriverProviderLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "container log read request"
        )
        try self.init(
            stdout: container.decode(Bool.self, forKey: .stdout),
            stderr: container.decode(Bool.self, forKey: .stderr),
            follow: container.decode(Bool.self, forKey: .follow),
            tail: container.decodeIfPresent(Int.self, forKey: .tail),
            since: container.decodeIfPresent(Date.self, forKey: .since),
            until: container.decodeIfPresent(Date.self, forKey: .until),
            timestamps: container.decode(Bool.self, forKey: .timestamps),
            details: container.decode(Bool.self, forKey: .details)
        )
    }
}

/// Private provider material deliberately lacking `Codable`, textual, and
/// generic persistence conformances.
public struct LogDriverOpaqueEffectTokenV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private let storage: Data

    public init(validating bytes: Data) throws {
        guard bytes.count <= LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes else {
            throw LogDriverLifecycleContractError.effectTokenTooLarge(
                maximumBytes: LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes
            )
        }
        self.storage = bytes
    }

    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }

    public func isByteIdentical(to other: Self) -> Bool {
        guard storage.count == other.storage.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in storage.indices {
            difference |= storage[index] ^ other.storage[index]
        }
        return difference == 0
    }

    public var description: String {
        "LogDriverOpaqueEffectTokenV1(<redacted>, byteCount: \(storage.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["redacted": true, "byteCount": storage.count],
            displayStyle: .struct
        )
    }
}

public enum LogDriverIdempotencyComparisonV1: Equatable, Sendable {
    case distinctScope
    case identicalReplay
    case conflict
}

public struct LogDriverWriterIdempotencyScopeV1: Equatable, Sendable {
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
}

public struct LogDriverWriterOperationIdentityV1: Equatable, Sendable {
    public let scope: LogDriverWriterIdempotencyScopeV1
    public let sessionID: String
    public let candidateProcessGeneration: UInt64
    public let candidateSandboxGeneration: UInt64?
}

public struct LogDriverStartRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedTransportBytes = 32 * 1024

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
        candidateSandboxGeneration: UInt64?
    ) throws {
        try LogDriverProviderLifecycleValidation.generation(operationGeneration, field: "operationGeneration")
        try LogDriverProviderLifecycleValidation.idempotencyKey(idempotencyKey)
        try LogDriverProviderLifecycleValidation.digest(semanticRequestDigest, field: "semanticRequestDigest")
        try LogDriverProviderLifecycleValidation.identifier(sessionID, field: "sessionID")
        try LogDriverProviderLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverProviderLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverProviderLifecycleValidation.generation(
            candidateProcessGeneration,
            field: "candidateProcessGeneration"
        )
        try LogDriverProviderLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverProviderLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        try LogDriverProviderLifecycleValidation.optionalGeneration(
            candidateSandboxGeneration,
            field: "candidateSandboxGeneration"
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
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverProviderLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "log driver start request v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try LogDriverProviderLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver start request"
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
            )
        )
    }

    public var idempotencyScope: LogDriverWriterIdempotencyScopeV1 {
        LogDriverWriterIdempotencyScopeV1(
            operationGeneration: operationGeneration,
            idempotencyKey: idempotencyKey,
            containerID: containerID,
            leaseGeneration: leaseGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    public var operationIdentity: LogDriverWriterOperationIdentityV1 {
        LogDriverWriterOperationIdentityV1(
            scope: idempotencyScope,
            sessionID: sessionID,
            candidateProcessGeneration: candidateProcessGeneration,
            candidateSandboxGeneration: candidateSandboxGeneration
        )
    }

    public func idempotencyComparison(to other: Self) -> LogDriverIdempotencyComparisonV1 {
        guard idempotencyScope == other.idempotencyScope else {
            return .distinctScope
        }
        return self == other ? .identicalReplay : .conflict
    }
}

public struct LogDriverStartReceiptV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let request: LogDriverStartRequestV1
    public let effectTokenMaterial: LogDriverOpaqueEffectTokenV1

    public init(
        request: LogDriverStartRequestV1,
        effectTokenMaterial: LogDriverOpaqueEffectTokenV1
    ) {
        self.request = request
        self.effectTokenMaterial = effectTokenMaterial
    }

    public var description: String {
        "LogDriverStartReceiptV1(sessionID: \(request.sessionID), effectTokenMaterial: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["request": request, "effectTokenMaterial": "<redacted>"],
            displayStyle: .struct
        )
    }
}

public enum LogDriverStartReconciliationV1: Sendable {
    case absent
    case prepared(StartedLogDriverSessionV1)
    case conflict
    case uncertain
}

public enum LogDriverSessionFenceV1: Codable, Equatable, Sendable {
    case candidate(
        operationGeneration: UInt64,
        candidateProcessGeneration: UInt64,
        candidateSandboxGeneration: UInt64?
    )
    case active(
        activeProcessGeneration: UInt64,
        activeSandboxGeneration: UInt64?
    )

    private enum Kind: String, Codable {
        case candidate
        case active
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case operationGeneration
        case processGeneration
        case sandboxGeneration
    }

    public init(
        candidateOperationGeneration operationGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64?
    ) throws {
        try LogDriverProviderLifecycleValidation.generation(operationGeneration, field: "operationGeneration")
        try LogDriverProviderLifecycleValidation.generation(
            processGeneration,
            field: "candidateProcessGeneration"
        )
        try LogDriverProviderLifecycleValidation.optionalGeneration(
            sandboxGeneration,
            field: "candidateSandboxGeneration"
        )
        self = .candidate(
            operationGeneration: operationGeneration,
            candidateProcessGeneration: processGeneration,
            candidateSandboxGeneration: sandboxGeneration
        )
    }

    public init(
        activeProcessGeneration processGeneration: UInt64,
        sandboxGeneration: UInt64?
    ) throws {
        try LogDriverProviderLifecycleValidation.generation(
            processGeneration,
            field: "activeProcessGeneration"
        )
        try LogDriverProviderLifecycleValidation.optionalGeneration(
            sandboxGeneration,
            field: "activeSandboxGeneration"
        )
        self = .active(
            activeProcessGeneration: processGeneration,
            activeSandboxGeneration: sandboxGeneration
        )
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverProviderLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "log driver session fence v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .candidate:
            try self.init(
                candidateOperationGeneration: container.decode(UInt64.self, forKey: .operationGeneration),
                processGeneration: container.decode(UInt64.self, forKey: .processGeneration),
                sandboxGeneration: container.decodeIfPresent(UInt64.self, forKey: .sandboxGeneration)
            )
        case .active:
            guard !container.contains(.operationGeneration) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operationGeneration,
                    in: container,
                    debugDescription: "active writer fence contains a candidate operation generation"
                )
            }
            try self.init(
                activeProcessGeneration: container.decode(UInt64.self, forKey: .processGeneration),
                sandboxGeneration: container.decodeIfPresent(UInt64.self, forKey: .sandboxGeneration)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .candidate(let operationGeneration, let processGeneration, let sandboxGeneration):
            try container.encode(Kind.candidate, forKey: .kind)
            try container.encode(operationGeneration, forKey: .operationGeneration)
            try container.encode(processGeneration, forKey: .processGeneration)
            try container.encodeIfPresent(sandboxGeneration, forKey: .sandboxGeneration)
        case .active(let processGeneration, let sandboxGeneration):
            try container.encode(Kind.active, forKey: .kind)
            try container.encode(processGeneration, forKey: .processGeneration)
            try container.encodeIfPresent(sandboxGeneration, forKey: .sandboxGeneration)
        }
    }
}

public struct LogDriverSessionCallIdentityV1: Equatable, Sendable {
    public let sessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let fence: LogDriverSessionFenceV1
}

public struct LogDriverSessionCallV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let sessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let fence: LogDriverSessionFenceV1
    public let effectTokenMaterial: LogDriverOpaqueEffectTokenV1

    public init(
        sessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        fence: LogDriverSessionFenceV1,
        effectTokenMaterial: LogDriverOpaqueEffectTokenV1
    ) throws {
        try LogDriverProviderLifecycleValidation.identifier(sessionID, field: "sessionID")
        try LogDriverProviderLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverProviderLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverProviderLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverProviderLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fence = fence
        self.effectTokenMaterial = effectTokenMaterial
    }

    public var identity: LogDriverSessionCallIdentityV1 {
        LogDriverSessionCallIdentityV1(
            sessionID: sessionID,
            containerID: containerID,
            leaseGeneration: leaseGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fence: fence
        )
    }

    public var description: String {
        "LogDriverSessionCallV1(identity: \(identity), effectTokenMaterial: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["identity": identity, "effectTokenMaterial": "<redacted>"],
            displayStyle: .struct
        )
    }
}

public enum LogDriverSessionObservationV1: String, Codable, Equatable, Sendable {
    case active
    case draining
    case writerFenced
    case closed
    case absent
    case uncertain
}

public struct LogDriverSessionAcknowledgementV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let call: LogDriverSessionCallV1
    public let observation: LogDriverSessionObservationV1
    public let writerFenceReceiptDigest: String?

    public init(
        call: LogDriverSessionCallV1,
        observation: LogDriverSessionObservationV1,
        writerFenceReceiptDigest: String?
    ) throws {
        if let writerFenceReceiptDigest {
            try LogDriverProviderLifecycleValidation.digest(
                writerFenceReceiptDigest,
                field: "writerFenceReceiptDigest"
            )
        }
        guard (observation == .writerFenced) == (writerFenceReceiptDigest != nil) else {
            throw LogDriverLifecycleContractError.invalidAcknowledgement(
                "writer fence observation and receipt digest must be present together"
            )
        }
        self.call = call
        self.observation = observation
        self.writerFenceReceiptDigest = writerFenceReceiptDigest
    }

    public var description: String {
        "LogDriverSessionAcknowledgementV1(identity: \(call.identity), observation: \(observation.rawValue))"
    }

    public var debugDescription: String { description }
}

public struct StartedLogDriverSessionV1: Sendable {
    public let receipt: LogDriverStartReceiptV1
    public let session: any ContainerLogDriverSession

    public init(
        receipt: LogDriverStartReceiptV1,
        session: any ContainerLogDriverSession
    ) {
        self.receipt = receipt
        self.session = session
    }
}

public struct LogDriverReaderIdempotencyScopeV1: Equatable, Sendable {
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
}

public struct LogDriverReaderOperationIdentityV1: Equatable, Sendable {
    public let scope: LogDriverReaderIdempotencyScopeV1
    public let readerSessionID: String
    public let source: LoggingReaderSourceV1
}

public struct LogDriverReaderOpenRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedTransportBytes = 64 * 1024

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
    public let read: ContainerLogReadRequest

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
        case read
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
        read: ContainerLogReadRequest
    ) throws {
        try LogDriverProviderLifecycleValidation.generation(operationGeneration, field: "operationGeneration")
        try LogDriverProviderLifecycleValidation.idempotencyKey(idempotencyKey)
        try LogDriverProviderLifecycleValidation.digest(semanticRequestDigest, field: "semanticRequestDigest")
        try LogDriverProviderLifecycleValidation.identifier(readerSessionID, field: "readerSessionID")
        try LogDriverProviderLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverProviderLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverProviderLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverProviderLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
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
        self.read = read
    }

    public init(from decoder: any Decoder) throws {
        try LogDriverProviderLifecycleValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "log driver reader open request v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try LogDriverProviderLifecycleValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver reader open request"
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
            read: container.decode(ContainerLogReadRequest.self, forKey: .read)
        )
    }

    public var idempotencyScope: LogDriverReaderIdempotencyScopeV1 {
        LogDriverReaderIdempotencyScopeV1(
            operationGeneration: operationGeneration,
            idempotencyKey: idempotencyKey,
            containerID: containerID,
            leaseGeneration: leaseGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    public var operationIdentity: LogDriverReaderOperationIdentityV1 {
        LogDriverReaderOperationIdentityV1(
            scope: idempotencyScope,
            readerSessionID: readerSessionID,
            source: source
        )
    }

    public func idempotencyComparison(to other: Self) -> LogDriverIdempotencyComparisonV1 {
        guard idempotencyScope == other.idempotencyScope else {
            return .distinctScope
        }
        return self == other ? .identicalReplay : .conflict
    }
}

public struct LogDriverReaderOpenReceiptV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let request: LogDriverReaderOpenRequestV1
    public let effectTokenMaterial: LogDriverOpaqueEffectTokenV1

    public init(
        request: LogDriverReaderOpenRequestV1,
        effectTokenMaterial: LogDriverOpaqueEffectTokenV1
    ) {
        self.request = request
        self.effectTokenMaterial = effectTokenMaterial
    }

    public var description: String {
        "LogDriverReaderOpenReceiptV1(readerSessionID: \(request.readerSessionID), effectTokenMaterial: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["request": request, "effectTokenMaterial": "<redacted>"],
            displayStyle: .struct
        )
    }
}

public enum LogDriverReaderOpenReconciliationV1: Sendable {
    case absent
    case prepared(StartedLogDriverReaderV1)
    case conflict
    case uncertain
}

public struct LogDriverReaderCallIdentityV1: Equatable, Sendable {
    public let readerSessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let source: LoggingReaderSourceV1
}

public struct LogDriverReaderCallV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let readerSessionID: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let source: LoggingReaderSourceV1
    public let effectTokenMaterial: LogDriverOpaqueEffectTokenV1

    public init(
        readerSessionID: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        source: LoggingReaderSourceV1,
        effectTokenMaterial: LogDriverOpaqueEffectTokenV1
    ) throws {
        try LogDriverProviderLifecycleValidation.identifier(readerSessionID, field: "readerSessionID")
        try LogDriverProviderLifecycleValidation.identifier(containerID, field: "containerID")
        try LogDriverProviderLifecycleValidation.generation(leaseGeneration, field: "leaseGeneration")
        try LogDriverProviderLifecycleValidation.identifier(providerID, field: "providerID")
        try LogDriverProviderLifecycleValidation.generation(providerGeneration, field: "providerGeneration")
        self.schemaVersion = Self.currentSchemaVersion
        self.readerSessionID = readerSessionID
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.source = source
        self.effectTokenMaterial = effectTokenMaterial
    }

    public var identity: LogDriverReaderCallIdentityV1 {
        LogDriverReaderCallIdentityV1(
            readerSessionID: readerSessionID,
            containerID: containerID,
            leaseGeneration: leaseGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            source: source
        )
    }

    public var description: String {
        "LogDriverReaderCallV1(identity: \(identity), effectTokenMaterial: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["identity": identity, "effectTokenMaterial": "<redacted>"],
            displayStyle: .struct
        )
    }
}

public enum LogDriverReaderObservationV1: String, Codable, Equatable, Sendable {
    case active
    case closing
    case closed
    case absent
    case uncertain
}

public struct LogDriverReaderAcknowledgementV1: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let call: LogDriverReaderCallV1
    public let observation: LogDriverReaderObservationV1
    public let terminalOutcomeDigest: String?

    public init(
        call: LogDriverReaderCallV1,
        observation: LogDriverReaderObservationV1,
        terminalOutcomeDigest: String?
    ) throws {
        if let terminalOutcomeDigest {
            try LogDriverProviderLifecycleValidation.digest(
                terminalOutcomeDigest,
                field: "terminalOutcomeDigest"
            )
        }
        if observation == .closed, terminalOutcomeDigest == nil {
            throw LogDriverLifecycleContractError.invalidAcknowledgement(
                "closed reader observation requires a terminal outcome digest"
            )
        }
        if observation == .active || observation == .closing || observation == .uncertain,
            terminalOutcomeDigest != nil
        {
            throw LogDriverLifecycleContractError.invalidAcknowledgement(
                "nonterminal reader observation cannot carry a terminal outcome digest"
            )
        }
        self.call = call
        self.observation = observation
        self.terminalOutcomeDigest = terminalOutcomeDigest
    }

    public var description: String {
        "LogDriverReaderAcknowledgementV1(identity: \(call.identity), observation: \(observation.rawValue))"
    }

    public var debugDescription: String { description }
}

public struct StartedLogDriverReaderV1: Sendable {
    public let receipt: LogDriverReaderOpenReceiptV1
    public let reader: any ContainerLogReader

    public init(
        receipt: LogDriverReaderOpenReceiptV1,
        reader: any ContainerLogReader
    ) {
        self.receipt = receipt
        self.reader = reader
    }
}

/// One bounded event from a driver-neutral reader. A reader yields records one
/// at a time and then exactly one terminal event.
public enum ContainerLogReaderEventV1: Equatable, Sendable {
    case record(ContainerLogRecordV2)
    case endOfStream
}

public protocol ContainerLogReader: Sendable {
    func next() async throws -> ContainerLogReaderEventV1
}

public protocol ContainerLogDriverSession: Sendable {
    func write(_ record: ContainerLogRecordV2) async throws
    func flush(deadline: ContinuousClock.Instant) async throws
    func close(deadline: ContinuousClock.Instant) async throws
}

/// Generation-fenced lifecycle boundary implemented by native and isolated
/// logging providers. Create-time option resolution remains the authority's
/// side-effect-free descriptor contract; this interface begins at effectful
/// writer or reader preparation.
public protocol ContainerLogDriverProvider: Sendable {
    var descriptor: LogDriverDescriptor { get async throws }

    func start(_ request: LogDriverStartRequestV1) async throws -> StartedLogDriverSessionV1
    func reconcileStart(_ request: LogDriverStartRequestV1) async throws -> LogDriverStartReconciliationV1
    func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1
    func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1
    func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1

    func openReader(_ request: LogDriverReaderOpenRequestV1) async throws -> StartedLogDriverReaderV1
    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1
    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1
    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1
}
