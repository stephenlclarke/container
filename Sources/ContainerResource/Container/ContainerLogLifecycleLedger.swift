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

public enum ContainerLogLifecycleLedgerLimitsV1 {
    public static let maximumWriterOperations = 4_096
    public static let maximumReaderOperations = 4_096
    public static let maximumDetachedCleanups = 4_096
    public static let maximumPendingEffectRemovals = 4_096
    public static let maximumSnapshotBytes = 16 * 1024 * 1024
}

public enum ContainerLogLifecycleLedgerError: Error, Equatable, Sendable {
    case capacityExceeded(collection: String, maximum: Int)
    case corruptSnapshot(String)
    case persistenceExceedsLimit(maximumBytes: Int)
    case idempotencyConflict
    case staleGeneration
    case staleSession
    case invalidTransition(expected: String, actual: String)
    case providerIdentityMismatch
    case providerResponseMismatch
    case uncertainOwnership
    case terminalOperation
}

/// Persistence boundary for the redaction-safe lifecycle snapshot.
///
/// Implementations must replace a complete snapshot atomically. Raw provider
/// effect material cannot cross this boundary because every accepted value is
/// encoded from ``ContainerLogLifecycleLedgerSnapshotV1``.
public protocol ContainerLogLifecycleLedgerPersistenceV1: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public actor InMemoryContainerLogLifecycleLedgerPersistenceV1:
    ContainerLogLifecycleLedgerPersistenceV1
{
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

/// Bounded, atomic file persistence for lifecycle crash recovery.
///
/// The target must be a regular file (or absent), never a symbolic link. A
/// same-directory atomic replacement follows the durable configuration-store
/// pattern used elsewhere in the runtime. The ledger contains references and
/// digests only, but the final file is still restricted to mode `0600`.
public actor FileContainerLogLifecycleLedgerPersistenceV1:
    ContainerLogLifecycleLedgerPersistenceV1
{
    private let fileURL: URL
    private let maximumBytes: Int

    public init(
        fileURL: URL,
        maximumBytes: Int = ContainerLogLifecycleLedgerLimitsV1.maximumSnapshotBytes
    ) throws {
        guard fileURL.isFileURL, maximumBytes > 0 else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "file persistence requires a file URL and positive byte limit"
            )
        }
        self.fileURL = fileURL.standardizedFileURL
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> Data? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try rejectNonRegularOrSymbolicLink(manager: manager)
        let attributes = try manager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw ContainerLogLifecycleLedgerError.persistenceExceedsLimit(
                maximumBytes: maximumBytes
            )
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw ContainerLogLifecycleLedgerError.persistenceExceedsLimit(
                maximumBytes: maximumBytes
            )
        }
        return data
    }

    public func save(_ data: Data) throws {
        guard data.count <= maximumBytes else {
            throw ContainerLogLifecycleLedgerError.persistenceExceedsLimit(
                maximumBytes: maximumBytes
            )
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try rejectNonRegularOrSymbolicLink(manager: manager)
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensureProtectedDirectory(directory, manager: manager)
        try data.write(to: fileURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try rejectNonRegularOrSymbolicLink(manager: manager)
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
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "lifecycle snapshot directory must be a non-symbolic-link directory"
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func rejectNonRegularOrSymbolicLink(manager: FileManager) throws {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "lifecycle snapshot path must be a regular non-symbolic-link file"
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

private struct ContainerLogLifecycleLedgerAnyCodingKey: CodingKey {
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

private enum ContainerLogLifecycleLedgerValidation {
    static func rejectUnknownKeys<Key>(
        from decoder: any Decoder,
        allowed: Key.Type,
        type: String
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: ContainerLogLifecycleLedgerAnyCodingKey.self)
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

    private static func bounded(_ value: String, field: String, maximumBytes: Int) throws {
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

public enum LoggingWriterOperationResultV1: Equatable, Sendable {
    case reserved
    case startRecoveryRequired
    case prepared(LoggingSessionPreparationV1)
    case candidateClosing(LoggingSessionPreparationV1)
    case candidateRecoveryRequired(LoggingSessionPreparationV1)
    case candidateClosed
    case activated(LoggingSessionActivationV1)

    public var preparation: LoggingSessionPreparationV1? {
        switch self {
        case .prepared(let preparation), .candidateClosing(let preparation),
            .candidateRecoveryRequired(let preparation):
            preparation
        case .reserved, .startRecoveryRequired, .candidateClosed, .activated:
            nil
        }
    }

    public var activation: LoggingSessionActivationV1? {
        if case .activated(let activation) = self {
            return activation
        }
        return nil
    }

    var kindName: String {
        switch self {
        case .reserved: "reserved"
        case .startRecoveryRequired: "startRecoveryRequired"
        case .prepared: "prepared"
        case .candidateClosing: "candidateClosing"
        case .candidateRecoveryRequired: "candidateRecoveryRequired"
        case .candidateClosed: "candidateClosed"
        case .activated: "activated"
        }
    }
}

extension LoggingWriterOperationResultV1: Codable {
    private enum Kind: String, Codable {
        case reserved
        case startRecoveryRequired
        case prepared
        case candidateClosing
        case candidateRecoveryRequired
        case candidateClosed
        case activated
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case preparation
        case activation
    }

    public init(from decoder: any Decoder) throws {
        try ContainerLogLifecycleLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging writer operation result v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .reserved:
            try Self.requireNoPayload(container)
            self = .reserved
        case .startRecoveryRequired:
            try Self.requireNoPayload(container)
            self = .startRecoveryRequired
        case .prepared:
            guard !container.contains(.activation) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .prepared(
                try container.decode(LoggingSessionPreparationV1.self, forKey: .preparation)
            )
        case .candidateClosing:
            guard !container.contains(.activation) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .candidateClosing(
                try container.decode(LoggingSessionPreparationV1.self, forKey: .preparation)
            )
        case .candidateRecoveryRequired:
            guard !container.contains(.activation) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .candidateRecoveryRequired(
                try container.decode(LoggingSessionPreparationV1.self, forKey: .preparation)
            )
        case .candidateClosed:
            try Self.requireNoPayload(container)
            self = .candidateClosed
        case .activated:
            guard !container.contains(.preparation) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .activated(
                try container.decode(LoggingSessionActivationV1.self, forKey: .activation)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reserved:
            try container.encode(Kind.reserved, forKey: .kind)
        case .startRecoveryRequired:
            try container.encode(Kind.startRecoveryRequired, forKey: .kind)
        case .prepared(let preparation):
            try container.encode(Kind.prepared, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateClosing(let preparation):
            try container.encode(Kind.candidateClosing, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateRecoveryRequired(let preparation):
            try container.encode(Kind.candidateRecoveryRequired, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateClosed:
            try container.encode(Kind.candidateClosed, forKey: .kind)
        case .activated(let activation):
            try container.encode(Kind.activated, forKey: .kind)
            try container.encode(activation, forKey: .activation)
        }
    }

    private static func requireNoPayload(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !container.contains(.preparation), !container.contains(.activation) else {
            throw unexpectedPayload(in: container)
        }
    }

    private static func unexpectedPayload(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "writer operation result contains payload for another state"
            )
        )
    }
}

public struct LoggingWriterOperationRecordV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let request: LogDriverStartRequestV1
    public let result: LoggingWriterOperationResultV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case request
        case result
    }

    public init(
        request: LogDriverStartRequestV1,
        result: LoggingWriterOperationResultV1
    ) throws {
        try Self.validate(result: result, request: request)
        self.schemaVersion = Self.currentSchemaVersion
        self.request = request
        self.result = result
    }

    public init(from decoder: any Decoder) throws {
        try ContainerLogLifecycleLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging writer operation record v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try ContainerLogLifecycleLedgerValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging writer operation record"
        )
        try self.init(
            request: container.decode(LogDriverStartRequestV1.self, forKey: .request),
            result: container.decode(LoggingWriterOperationResultV1.self, forKey: .result)
        )
    }

    private static func validate(
        result: LoggingWriterOperationResultV1,
        request: LogDriverStartRequestV1
    ) throws {
        if let preparation = result.preparation {
            guard
                preparation.operationGeneration == request.operationGeneration,
                preparation.idempotencyKey == request.idempotencyKey,
                preparation.semanticRequestDigest == request.semanticRequestDigest,
                preparation.sessionID == request.sessionID,
                preparation.containerID == request.containerID,
                preparation.leaseGeneration == request.leaseGeneration,
                preparation.candidateProcessGeneration == request.candidateProcessGeneration,
                preparation.providerID == request.providerID,
                preparation.providerGeneration == request.providerGeneration,
                preparation.candidateSandboxGeneration == request.candidateSandboxGeneration
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "writer preparation does not match its reserved request"
                )
            }
        }
        if let activation = result.activation {
            guard
                activation.sessionID == request.sessionID,
                activation.containerID == request.containerID,
                activation.leaseGeneration == request.leaseGeneration,
                activation.activeProcessGeneration == request.candidateProcessGeneration,
                activation.providerID == request.providerID,
                activation.providerGeneration == request.providerGeneration,
                activation.activeSandboxGeneration == request.candidateSandboxGeneration
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "writer activation does not match its reserved request"
                )
            }
        }
    }
}

public enum LoggingReaderOperationResultV1: Equatable, Sendable {
    case reserved
    case openRecoveryRequired
    case prepared(LoggingReaderPreparationV1)
    case candidateClosing(LoggingReaderPreparationV1)
    case candidateRecoveryRequired(LoggingReaderPreparationV1)
    case candidateClosed
    case activated(LoggingReaderSessionV1)

    public var preparation: LoggingReaderPreparationV1? {
        switch self {
        case .prepared(let preparation), .candidateClosing(let preparation),
            .candidateRecoveryRequired(let preparation):
            preparation
        case .reserved, .openRecoveryRequired, .candidateClosed, .activated:
            nil
        }
    }

    public var session: LoggingReaderSessionV1? {
        if case .activated(let session) = self {
            return session
        }
        return nil
    }

    var kindName: String {
        switch self {
        case .reserved: "reserved"
        case .openRecoveryRequired: "openRecoveryRequired"
        case .prepared: "prepared"
        case .candidateClosing: "candidateClosing"
        case .candidateRecoveryRequired: "candidateRecoveryRequired"
        case .candidateClosed: "candidateClosed"
        case .activated: "activated"
        }
    }
}

extension LoggingReaderOperationResultV1: Codable {
    private enum Kind: String, Codable {
        case reserved
        case openRecoveryRequired
        case prepared
        case candidateClosing
        case candidateRecoveryRequired
        case candidateClosed
        case activated
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case preparation
        case session
    }

    public init(from decoder: any Decoder) throws {
        try ContainerLogLifecycleLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging reader operation result v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .reserved:
            try Self.requireNoPayload(container)
            self = .reserved
        case .openRecoveryRequired:
            try Self.requireNoPayload(container)
            self = .openRecoveryRequired
        case .prepared:
            guard !container.contains(.session) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .prepared(
                try container.decode(LoggingReaderPreparationV1.self, forKey: .preparation)
            )
        case .candidateClosing:
            guard !container.contains(.session) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .candidateClosing(
                try container.decode(LoggingReaderPreparationV1.self, forKey: .preparation)
            )
        case .candidateRecoveryRequired:
            guard !container.contains(.session) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .candidateRecoveryRequired(
                try container.decode(LoggingReaderPreparationV1.self, forKey: .preparation)
            )
        case .candidateClosed:
            try Self.requireNoPayload(container)
            self = .candidateClosed
        case .activated:
            guard !container.contains(.preparation) else {
                throw Self.unexpectedPayload(in: container)
            }
            self = .activated(
                try container.decode(LoggingReaderSessionV1.self, forKey: .session)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reserved:
            try container.encode(Kind.reserved, forKey: .kind)
        case .openRecoveryRequired:
            try container.encode(Kind.openRecoveryRequired, forKey: .kind)
        case .prepared(let preparation):
            try container.encode(Kind.prepared, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateClosing(let preparation):
            try container.encode(Kind.candidateClosing, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateRecoveryRequired(let preparation):
            try container.encode(Kind.candidateRecoveryRequired, forKey: .kind)
            try container.encode(preparation, forKey: .preparation)
        case .candidateClosed:
            try container.encode(Kind.candidateClosed, forKey: .kind)
        case .activated(let session):
            try container.encode(Kind.activated, forKey: .kind)
            try container.encode(session, forKey: .session)
        }
    }

    private static func requireNoPayload(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !container.contains(.preparation), !container.contains(.session) else {
            throw unexpectedPayload(in: container)
        }
    }

    private static func unexpectedPayload(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "reader operation result contains payload for another state"
            )
        )
    }
}

public struct LoggingReaderOperationRecordV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let request: LogDriverReaderOpenRequestV1
    public let result: LoggingReaderOperationResultV1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case request
        case result
    }

    public init(
        request: LogDriverReaderOpenRequestV1,
        result: LoggingReaderOperationResultV1
    ) throws {
        try Self.validate(result: result, request: request)
        self.schemaVersion = Self.currentSchemaVersion
        self.request = request
        self.result = result
    }

    public init(from decoder: any Decoder) throws {
        try ContainerLogLifecycleLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "logging reader operation record v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try ContainerLogLifecycleLedgerValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "logging reader operation record"
        )
        try self.init(
            request: container.decode(LogDriverReaderOpenRequestV1.self, forKey: .request),
            result: container.decode(LoggingReaderOperationResultV1.self, forKey: .result)
        )
    }

    private static func validate(
        result: LoggingReaderOperationResultV1,
        request: LogDriverReaderOpenRequestV1
    ) throws {
        if let preparation = result.preparation {
            guard
                preparation.operationGeneration == request.operationGeneration,
                preparation.idempotencyKey == request.idempotencyKey,
                preparation.semanticRequestDigest == request.semanticRequestDigest,
                preparation.readerSessionID == request.readerSessionID,
                preparation.containerID == request.containerID,
                preparation.leaseGeneration == request.leaseGeneration,
                preparation.providerID == request.providerID,
                preparation.providerGeneration == request.providerGeneration,
                preparation.source == request.source
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "reader preparation does not match its reserved request"
                )
            }
        }
        if let session = result.session {
            guard
                session.readerSessionID == request.readerSessionID,
                session.containerID == request.containerID,
                session.leaseGeneration == request.leaseGeneration,
                session.providerID == request.providerID,
                session.providerGeneration == request.providerGeneration,
                session.source == request.source
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "reader session does not match its reserved request"
                )
            }
        }
    }
}

public struct ContainerLogLifecycleLedgerSnapshotV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let owningControllerID: String
    public let writerOperations: [LoggingWriterOperationRecordV1]
    public let detachedCleanups: [LoggingDetachedCleanupV1]
    public let readerOperations: [LoggingReaderOperationRecordV1]
    public let pendingEffectRemovals: [LoggingEffectRemovalPendingV1]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case owningControllerID
        case writerOperations
        case detachedCleanups
        case readerOperations
        case pendingEffectRemovals
    }

    public init(
        owningControllerID: String,
        writerOperations: [LoggingWriterOperationRecordV1] = [],
        detachedCleanups: [LoggingDetachedCleanupV1] = [],
        readerOperations: [LoggingReaderOperationRecordV1] = [],
        pendingEffectRemovals: [LoggingEffectRemovalPendingV1] = []
    ) throws {
        try ContainerLogLifecycleLedgerValidation.identifier(
            owningControllerID,
            field: "owningControllerID"
        )
        guard writerOperations.count <= ContainerLogLifecycleLedgerLimitsV1.maximumWriterOperations else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "writerOperations",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumWriterOperations
            )
        }
        guard readerOperations.count <= ContainerLogLifecycleLedgerLimitsV1.maximumReaderOperations else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "readerOperations",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumReaderOperations
            )
        }
        guard detachedCleanups.count <= ContainerLogLifecycleLedgerLimitsV1.maximumDetachedCleanups else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "detachedCleanups",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumDetachedCleanups
            )
        }
        guard
            pendingEffectRemovals.count
                <= ContainerLogLifecycleLedgerLimitsV1.maximumPendingEffectRemovals
        else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "pendingEffectRemovals",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumPendingEffectRemovals
            )
        }

        try Self.validateUniqueWriterRecords(writerOperations)
        try Self.validateUniqueReaderRecords(readerOperations)
        try Self.validateCleanups(
            detachedCleanups,
            writerOperations: writerOperations,
            owningControllerID: owningControllerID
        )
        for record in writerOperations {
            if let preparation = record.result.preparation {
                try preparation.validateEffectReference(owningControllerID: owningControllerID)
            }
            if let activation = record.result.activation {
                try activation.validateEffectReference(owningControllerID: owningControllerID)
            }
        }
        for record in readerOperations {
            if let preparation = record.result.preparation {
                try preparation.validateEffectReference(owningControllerID: owningControllerID)
            }
            if let session = record.result.session {
                try session.validateEffectReference(owningControllerID: owningControllerID)
            }
        }
        try Self.validatePendingEffectRemovals(
            pendingEffectRemovals,
            writerOperations: writerOperations,
            detachedCleanups: detachedCleanups,
            readerOperations: readerOperations,
            owningControllerID: owningControllerID
        )

        self.schemaVersion = Self.currentSchemaVersion
        self.owningControllerID = owningControllerID
        self.writerOperations = writerOperations
        self.detachedCleanups = detachedCleanups
        self.readerOperations = readerOperations
        self.pendingEffectRemovals = pendingEffectRemovals
    }

    public init(from decoder: any Decoder) throws {
        try ContainerLogLifecycleLedgerValidation.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "container log lifecycle ledger snapshot v1"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try ContainerLogLifecycleLedgerValidation.schemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "container log lifecycle ledger snapshot"
        )
        try self.init(
            owningControllerID: container.decode(String.self, forKey: .owningControllerID),
            writerOperations: container.decode(
                [LoggingWriterOperationRecordV1].self,
                forKey: .writerOperations
            ),
            detachedCleanups: container.decode(
                [LoggingDetachedCleanupV1].self,
                forKey: .detachedCleanups
            ),
            readerOperations: container.decode(
                [LoggingReaderOperationRecordV1].self,
                forKey: .readerOperations
            ),
            pendingEffectRemovals: container.decodeIfPresent(
                [LoggingEffectRemovalPendingV1].self,
                forKey: .pendingEffectRemovals
            ) ?? []
        )
    }

    private static func validateUniqueWriterRecords(
        _ records: [LoggingWriterOperationRecordV1]
    ) throws {
        var sessionIDs = Set<String>()
        for (index, record) in records.enumerated() {
            guard sessionIDs.insert(record.request.sessionID).inserted else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate writer session ID"
                )
            }
            for prior in records[..<index] where prior.request.idempotencyScope == record.request.idempotencyScope {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate writer idempotency scope"
                )
            }
        }

        let live = records.compactMap(\.result.activation).filter {
            $0.state == .active || $0.state == .draining || $0.state == .recoveryRequired
        }
        for (index, activation) in live.enumerated() {
            guard !live[..<index].contains(where: { $0.containerID == activation.containerID }) else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "multiple live writer activations for one container"
                )
            }
        }
    }

    private static func validateUniqueReaderRecords(
        _ records: [LoggingReaderOperationRecordV1]
    ) throws {
        var sessionIDs = Set<String>()
        for (index, record) in records.enumerated() {
            guard sessionIDs.insert(record.request.readerSessionID).inserted else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate reader session ID"
                )
            }
            for prior in records[..<index] where prior.request.idempotencyScope == record.request.idempotencyScope {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate reader idempotency scope"
                )
            }
        }
    }

    private static func validateCleanups(
        _ cleanups: [LoggingDetachedCleanupV1],
        writerOperations: [LoggingWriterOperationRecordV1],
        owningControllerID: String
    ) throws {
        var cleanupIDs = Set<String>()
        var sessionIDs = Set<String>()
        for cleanup in cleanups {
            guard cleanupIDs.insert(cleanup.cleanupID).inserted,
                sessionIDs.insert(cleanup.sessionID).inserted
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate detached cleanup identity"
                )
            }
            try cleanup.validateEffectReference(owningControllerID: owningControllerID)
            guard
                let activation = writerOperations.compactMap(\.result.activation).first(where: {
                    $0.sessionID == cleanup.sessionID
                }),
                activation.containerID == cleanup.containerID,
                activation.leaseGeneration == cleanup.leaseGeneration,
                activation.activeProcessGeneration == cleanup.activeProcessGeneration,
                activation.providerID == cleanup.providerID,
                activation.providerGeneration == cleanup.providerGeneration,
                activation.activeSandboxGeneration == cleanup.activeSandboxGeneration,
                activation.closeDisposition == .deadlineTruncated,
                activation.state == .closed || activation.state == .tombstoned
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "detached cleanup has no matching deadline-fenced writer"
                )
            }
        }
    }

    private static func validatePendingEffectRemovals(
        _ removals: [LoggingEffectRemovalPendingV1],
        writerOperations: [LoggingWriterOperationRecordV1],
        detachedCleanups: [LoggingDetachedCleanupV1],
        readerOperations: [LoggingReaderOperationRecordV1],
        owningControllerID: String
    ) throws {
        for (index, removal) in removals.enumerated() {
            guard
                !removals[..<index].contains(where: {
                    $0.kind == removal.kind && $0.ownerID == removal.ownerID
                }),
                !removals[..<index].contains(where: {
                    $0.effectTokenReference == removal.effectTokenReference
                })
            else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "duplicate protected-effect removal"
                )
            }

            let reference = removal.effectTokenReference
            switch (removal.kind, removal.terminalOutcome) {
            case (.writerCandidate, .writerCandidateClosed):
                guard
                    let record = writerOperations.first(where: {
                        $0.request.sessionID == removal.ownerID
                    }),
                    case .candidateClosed = record.result
                else {
                    throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                        "writer-candidate removal has no matching terminal operation"
                    )
                }
                try reference.validateBinding(
                    ProtectedLoggingEffectBindingV1(
                        effectID: record.request.sessionID,
                        owningControllerID: owningControllerID,
                        providerID: record.request.providerID,
                        providerGeneration: record.request.providerGeneration
                    )
                )
            case (.writerSession, .writerClosed(let disposition)):
                guard
                    let activation = writerOperations.compactMap(\.result.activation).first(where: {
                        $0.sessionID == removal.ownerID
                    }),
                    activation.state == .closed || activation.state == .tombstoned,
                    activation.closeDisposition == disposition
                else {
                    throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                        "writer-session removal has no matching terminal outcome"
                    )
                }
                try reference.validateBinding(
                    ProtectedLoggingEffectBindingV1(
                        effectID: activation.sessionID,
                        owningControllerID: owningControllerID,
                        providerID: activation.providerID,
                        providerGeneration: activation.providerGeneration
                    )
                )
            case (
                .detachedCleanup,
                .detachedCleanupCompleted(let providerCloseOutcomeDigest)
            ):
                guard
                    let cleanup = detachedCleanups.first(where: {
                        $0.cleanupID == removal.ownerID
                    }),
                    cleanup.state == .complete || cleanup.state == .tombstoned,
                    cleanup.providerCloseOutcomeDigest == providerCloseOutcomeDigest
                else {
                    throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                        "detached-cleanup removal has no matching terminal outcome"
                    )
                }
                try reference.validateBinding(
                    ProtectedLoggingEffectBindingV1(
                        effectID: cleanup.sessionID,
                        owningControllerID: owningControllerID,
                        providerID: cleanup.providerID,
                        providerGeneration: cleanup.providerGeneration
                    )
                )
            case (.readerCandidate, .readerCandidateClosed):
                guard
                    let record = readerOperations.first(where: {
                        $0.request.readerSessionID == removal.ownerID
                    }),
                    case .candidateClosed = record.result
                else {
                    throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                        "reader-candidate removal has no matching terminal operation"
                    )
                }
                try reference.validateBinding(
                    ProtectedLoggingEffectBindingV1(
                        effectID: record.request.readerSessionID,
                        owningControllerID: owningControllerID,
                        providerID: record.request.providerID,
                        providerGeneration: record.request.providerGeneration
                    )
                )
            case (.readerSession, .readerClosed(let terminalOutcomeDigest)):
                guard
                    let session = readerOperations.compactMap(\.result.session).first(where: {
                        $0.readerSessionID == removal.ownerID
                    }),
                    session.state == .closed || session.state == .tombstoned,
                    session.terminalOutcomeDigest == terminalOutcomeDigest
                else {
                    throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                        "reader-session removal has no matching terminal outcome"
                    )
                }
                try reference.validateBinding(
                    ProtectedLoggingEffectBindingV1(
                        effectID: session.readerSessionID,
                        owningControllerID: owningControllerID,
                        providerID: session.providerID,
                        providerGeneration: session.providerGeneration
                    )
                )
            default:
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "protected-effect removal kind and outcome do not match"
                )
            }
        }
    }
}

public enum LoggingWriterReservationV1: Equatable, Sendable {
    case reserved(LoggingWriterOperationRecordV1)
    case replay(LoggingWriterOperationRecordV1)
}

public enum LoggingReaderReservationV1: Equatable, Sendable {
    case reserved(LoggingReaderOperationRecordV1)
    case replay(LoggingReaderOperationRecordV1)
}

/// Serialised common authority for provider writer, reader, and cleanup effects.
public actor ContainerLogLifecycleLedgerV1 {
    public nonisolated let owningControllerID: String

    private let persistence: (any ContainerLogLifecycleLedgerPersistenceV1)?
    private var currentSnapshot: ContainerLogLifecycleLedgerSnapshotV1
    private var persistenceFailed = false

    public init(owningControllerID: String) throws {
        let snapshot = try ContainerLogLifecycleLedgerSnapshotV1(
            owningControllerID: owningControllerID
        )
        self.owningControllerID = owningControllerID
        self.persistence = nil
        self.currentSnapshot = snapshot
        self.persistenceFailed = false
    }

    private init(
        snapshot: ContainerLogLifecycleLedgerSnapshotV1,
        persistence: any ContainerLogLifecycleLedgerPersistenceV1
    ) {
        self.owningControllerID = snapshot.owningControllerID
        self.persistence = persistence
        self.currentSnapshot = snapshot
        self.persistenceFailed = false
    }

    public static func open(
        owningControllerID: String,
        persistence: any ContainerLogLifecycleLedgerPersistenceV1
    ) async throws -> ContainerLogLifecycleLedgerV1 {
        let snapshot: ContainerLogLifecycleLedgerSnapshotV1
        if let data = try await persistence.load() {
            guard data.count <= ContainerLogLifecycleLedgerLimitsV1.maximumSnapshotBytes else {
                throw ContainerLogLifecycleLedgerError.persistenceExceedsLimit(
                    maximumBytes: ContainerLogLifecycleLedgerLimitsV1.maximumSnapshotBytes
                )
            }
            snapshot = try JSONDecoder().decode(
                ContainerLogLifecycleLedgerSnapshotV1.self,
                from: data
            )
            guard snapshot.owningControllerID == owningControllerID else {
                throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                    "snapshot belongs to another logging controller"
                )
            }
        } else {
            snapshot = try ContainerLogLifecycleLedgerSnapshotV1(
                owningControllerID: owningControllerID
            )
        }
        return ContainerLogLifecycleLedgerV1(snapshot: snapshot, persistence: persistence)
    }

    public func snapshot() -> ContainerLogLifecycleLedgerSnapshotV1 {
        currentSnapshot
    }

    public func writerOperation(
        for request: LogDriverStartRequestV1
    ) throws -> LoggingWriterOperationRecordV1? {
        try findWriterOperation(for: request).record
    }

    public func writerActivation(sessionID: String) -> LoggingSessionActivationV1? {
        currentSnapshot.writerOperations.first(where: { $0.request.sessionID == sessionID })?
            .result.activation
    }

    public func detachedCleanup(cleanupID: String) -> LoggingDetachedCleanupV1? {
        currentSnapshot.detachedCleanups.first(where: { $0.cleanupID == cleanupID })
    }

    public func readerOperation(
        for request: LogDriverReaderOpenRequestV1
    ) throws -> LoggingReaderOperationRecordV1? {
        try findReaderOperation(for: request).record
    }

    public func readerSession(readerSessionID: String) -> LoggingReaderSessionV1? {
        currentSnapshot.readerOperations.first(where: {
            $0.request.readerSessionID == readerSessionID
        })?.result.session
    }

    public func pendingEffectRemoval(
        kind: LoggingEffectRemovalKindV1,
        ownerID: String
    ) -> LoggingEffectRemovalPendingV1? {
        currentSnapshot.pendingEffectRemovals.first(where: {
            $0.kind == kind && $0.ownerID == ownerID
        })
    }

    public func acknowledgeEffectRemoval(
        _ expected: LoggingEffectRemovalPendingV1
    ) async throws {
        guard
            let index = currentSnapshot.pendingEffectRemovals.firstIndex(of: expected)
        else {
            if currentSnapshot.pendingEffectRemovals.contains(where: {
                $0.kind == expected.kind && $0.ownerID == expected.ownerID
            }) {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            return
        }
        var removals = currentSnapshot.pendingEffectRemovals
        removals.remove(at: index)
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations,
            pendingEffectRemovals: removals
        )
    }

    public func reserveWriter(
        _ request: LogDriverStartRequestV1
    ) async throws -> LoggingWriterReservationV1 {
        let match = try findWriterOperation(for: request)
        if let record = match.record {
            return .replay(record)
        }
        guard
            currentSnapshot.writerOperations.count
                < ContainerLogLifecycleLedgerLimitsV1.maximumWriterOperations
        else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "writerOperations",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumWriterOperations
            )
        }
        guard
            !currentSnapshot.writerOperations.contains(where: {
                $0.request.sessionID == request.sessionID
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        try rejectStaleWriterGeneration(request)
        guard
            !currentSnapshot.writerOperations.compactMap(\.result.activation).contains(where: {
                $0.containerID == request.containerID
                    && ($0.state == .active || $0.state == .draining || $0.state == .recoveryRequired)
            })
        else {
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: "no live writer",
                actual: "live writer exists"
            )
        }

        let record = try LoggingWriterOperationRecordV1(request: request, result: .reserved)
        try await persist(
            writerOperations: currentSnapshot.writerOperations + [record],
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations
        )
        return .reserved(record)
    }

    public func markWriterStartRecoveryRequired(
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingWriterOperationRecordV1 {
        try await replaceWriterOperation(for: request) { record in
            switch record.result {
            case .reserved, .startRecoveryRequired:
                return try LoggingWriterOperationRecordV1(
                    request: request,
                    result: .startRecoveryRequired
                )
            default:
                throw Self.invalidTransition(
                    expected: "reserved or startRecoveryRequired",
                    actual: record.result.kindName
                )
            }
        }
    }

    public func recordWriterPreparation(
        _ preparation: LoggingSessionPreparationV1,
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingWriterOperationRecordV1 {
        try preparation.validateEffectReference(owningControllerID: owningControllerID)
        return try await replaceWriterOperation(for: request) { record in
            switch record.result {
            case .reserved, .startRecoveryRequired:
                return try LoggingWriterOperationRecordV1(
                    request: request,
                    result: .prepared(preparation)
                )
            case .prepared(let existing) where existing == preparation:
                return record
            default:
                throw Self.invalidTransition(
                    expected: "reserved, recovery, or identical preparation",
                    actual: record.result.kindName
                )
            }
        }
    }

    public func markWriterCandidateClosing(
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingSessionPreparationV1 {
        let record = try await replaceWriterOperation(for: request) { record in
            switch record.result {
            case .prepared(let preparation), .candidateRecoveryRequired(let preparation),
                .candidateClosing(let preparation):
                return try LoggingWriterOperationRecordV1(
                    request: request,
                    result: .candidateClosing(preparation)
                )
            default:
                throw Self.invalidTransition(
                    expected: "prepared candidate",
                    actual: record.result.kindName
                )
            }
        }
        guard let preparation = record.result.preparation else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "candidate-closing writer lost its preparation"
            )
        }
        return preparation
    }

    public func markWriterCandidateRecoveryRequired(
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingSessionPreparationV1 {
        let record = try await replaceWriterOperation(for: request) { record in
            switch record.result {
            case .prepared(let preparation), .candidateClosing(let preparation),
                .candidateRecoveryRequired(let preparation):
                return try LoggingWriterOperationRecordV1(
                    request: request,
                    result: .candidateRecoveryRequired(preparation)
                )
            default:
                throw Self.invalidTransition(
                    expected: "prepared candidate",
                    actual: record.result.kindName
                )
            }
        }
        guard let preparation = record.result.preparation else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "candidate-recovery writer lost its preparation"
            )
        }
        return preparation
    }

    public func completeWriterCandidate(
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingWriterOperationRecordV1 {
        let located = try findWriterOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let reference: ProtectedLoggingEffectReferenceV1
        switch record.result {
        case .prepared(let preparation), .candidateClosing(let preparation),
            .candidateRecoveryRequired(let preparation):
            reference = preparation.effectTokenReference
        case .candidateClosed:
            return record
        default:
            throw Self.invalidTransition(
                expected: "prepared or closed candidate",
                actual: record.result.kindName
            )
        }
        let terminal = try LoggingWriterOperationRecordV1(
            request: request,
            result: .candidateClosed
        )
        let removal = try LoggingEffectRemovalPendingV1(
            kind: .writerCandidate,
            ownerID: request.sessionID,
            effectTokenReference: reference,
            terminalOutcome: .writerCandidateClosed
        )
        var operations = currentSnapshot.writerOperations
        operations[index] = terminal
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations,
            pendingEffectRemovals: currentSnapshot.pendingEffectRemovals + [removal]
        )
        return terminal
    }

    public func commitWriterActivation(
        for request: LogDriverStartRequestV1
    ) async throws -> LoggingSessionActivationV1 {
        let located = try findWriterOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if let existing = record.result.activation {
            return existing
        }
        guard case .prepared(let preparation) = record.result else {
            throw Self.invalidTransition(
                expected: "prepared",
                actual: record.result.kindName
            )
        }
        guard
            !currentSnapshot.writerOperations.enumerated().contains(where: { otherIndex, other in
                otherIndex != index
                    && other.result.activation?.containerID == request.containerID
                    && {
                        guard let state = other.result.activation?.state else { return false }
                        return state == .active || state == .draining || state == .recoveryRequired
                    }()
            })
        else {
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: "no live writer",
                actual: "live writer exists"
            )
        }
        let activation = try LoggingSessionActivationV1(
            sessionID: preparation.sessionID,
            containerID: preparation.containerID,
            leaseGeneration: preparation.leaseGeneration,
            activeProcessGeneration: preparation.candidateProcessGeneration,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            activeSandboxGeneration: preparation.candidateSandboxGeneration,
            effectTokenReference: preparation.effectTokenReference,
            closeDisposition: nil,
            state: .active
        )
        var operations = currentSnapshot.writerOperations
        operations[index] = try LoggingWriterOperationRecordV1(
            request: request,
            result: .activated(activation)
        )
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations
        )
        return activation
    }

    public func beginWriterDrain(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        try await replaceWriterActivation(expected) { activation in
            switch activation.state {
            case .active, .draining:
                return try Self.writerActivation(copying: activation, state: .draining)
            default:
                throw Self.invalidTransition(
                    expected: "active or draining",
                    actual: activation.state.rawValue
                )
            }
        }
    }

    public func markWriterRecoveryRequired(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        try await replaceWriterActivation(expected) { activation in
            switch activation.state {
            case .active, .draining, .recoveryRequired:
                return try Self.writerActivation(copying: activation, state: .recoveryRequired)
            case .closed, .tombstoned:
                throw Self.invalidTransition(
                    expected: "live writer",
                    actual: activation.state.rawValue
                )
            }
        }
    }

    public func restoreWriterActive(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        try await replaceWriterActivation(expected) { activation in
            guard activation.state == .recoveryRequired else {
                throw Self.invalidTransition(
                    expected: "recoveryRequired",
                    actual: activation.state.rawValue
                )
            }
            return try Self.writerActivation(copying: activation, state: .active)
        }
    }

    public func resumeWriterDrain(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        try await replaceWriterActivation(expected) { activation in
            guard activation.state == .recoveryRequired else {
                throw Self.invalidTransition(
                    expected: "recoveryRequired",
                    actual: activation.state.rawValue
                )
            }
            return try Self.writerActivation(copying: activation, state: .draining)
        }
    }

    public func completeWriterClose(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        let located = try locateWriterActivation(expected)
        let activation = expected
        if activation.state == .closed, activation.closeDisposition == .complete {
            return activation
        }
        guard activation.state == .draining, let reference = activation.effectTokenReference else {
            throw Self.invalidTransition(
                expected: "draining",
                actual: activation.state.rawValue
            )
        }
        let closed = try Self.writerActivation(
            copying: activation,
            reference: nil,
            disposition: .complete,
            state: .closed
        )
        let removal = try LoggingEffectRemovalPendingV1(
            kind: .writerSession,
            ownerID: activation.sessionID,
            effectTokenReference: reference,
            terminalOutcome: .writerClosed(.complete)
        )
        var operations = currentSnapshot.writerOperations
        operations[located.index] = try LoggingWriterOperationRecordV1(
            request: located.record.request,
            result: .activated(closed)
        )
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations,
            pendingEffectRemovals: currentSnapshot.pendingEffectRemovals + [removal]
        )
        return closed
    }

    public func transferWriterToDetachedCleanup(
        _ expected: LoggingSessionActivationV1,
        cleanupID: String,
        writerFenceReceiptDigest: String
    ) async throws -> LoggingDetachedCleanupV1 {
        try ContainerLogLifecycleLedgerValidation.identifier(cleanupID, field: "cleanupID")
        try ContainerLogLifecycleLedgerValidation.digest(
            writerFenceReceiptDigest,
            field: "writerFenceReceiptDigest"
        )
        if let existing = currentSnapshot.detachedCleanups.first(where: {
            $0.cleanupID == cleanupID || $0.sessionID == expected.sessionID
        }) {
            guard
                existing.cleanupID == cleanupID,
                existing.sessionID == expected.sessionID,
                existing.containerID == expected.containerID,
                existing.leaseGeneration == expected.leaseGeneration,
                existing.activeProcessGeneration == expected.activeProcessGeneration,
                existing.providerID == expected.providerID,
                existing.providerGeneration == expected.providerGeneration,
                existing.activeSandboxGeneration == expected.activeSandboxGeneration,
                existing.writerFenceReceiptDigest == writerFenceReceiptDigest
            else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            if let existingReference = existing.effectTokenReference,
                let expectedReference = expected.effectTokenReference
            {
                try existingReference.validateExactReference(expectedReference)
            }
            return existing
        }
        let located = try locateWriterActivation(expected)
        guard expected.state == .draining, let reference = expected.effectTokenReference else {
            throw Self.invalidTransition(
                expected: "draining writer with protected reference",
                actual: expected.state.rawValue
            )
        }
        let closed = try Self.writerActivation(
            copying: expected,
            reference: nil,
            disposition: .deadlineTruncated,
            state: .closed
        )
        let cleanup = try LoggingDetachedCleanupV1(
            cleanupID: cleanupID,
            sessionID: expected.sessionID,
            containerID: expected.containerID,
            leaseGeneration: expected.leaseGeneration,
            activeProcessGeneration: expected.activeProcessGeneration,
            providerID: expected.providerID,
            providerGeneration: expected.providerGeneration,
            activeSandboxGeneration: expected.activeSandboxGeneration,
            writerFenceReceiptDigest: writerFenceReceiptDigest,
            effectTokenReference: reference,
            providerCloseOutcomeDigest: nil,
            state: .pending
        )
        var operations = currentSnapshot.writerOperations
        operations[located.index] = try LoggingWriterOperationRecordV1(
            request: located.record.request,
            result: .activated(closed)
        )
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups + [cleanup],
            readerOperations: currentSnapshot.readerOperations
        )
        return cleanup
    }

    public func tombstoneWriter(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        try await replaceWriterActivation(expected) { activation in
            switch activation.state {
            case .closed, .tombstoned:
                return try Self.writerActivation(copying: activation, state: .tombstoned)
            default:
                throw Self.invalidTransition(
                    expected: "closed",
                    actual: activation.state.rawValue
                )
            }
        }
    }

    public func markDetachedCleanupRecoveryRequired(
        _ expected: LoggingDetachedCleanupV1
    ) async throws -> LoggingDetachedCleanupV1 {
        try await replaceDetachedCleanup(expected) { cleanup in
            switch cleanup.state {
            case .pending, .recoveryRequired:
                return try Self.detachedCleanup(copying: cleanup, state: .recoveryRequired)
            case .complete, .tombstoned:
                throw Self.invalidTransition(
                    expected: "unfinished cleanup",
                    actual: cleanup.state.rawValue
                )
            }
        }
    }

    public func completeDetachedCleanup(
        _ expected: LoggingDetachedCleanupV1,
        providerCloseOutcomeDigest: String
    ) async throws -> LoggingDetachedCleanupV1 {
        try ContainerLogLifecycleLedgerValidation.digest(
            providerCloseOutcomeDigest,
            field: "providerCloseOutcomeDigest"
        )
        guard
            let index = currentSnapshot.detachedCleanups.firstIndex(where: {
                $0.cleanupID == expected.cleanupID
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let cleanup = currentSnapshot.detachedCleanups[index]
        guard cleanup == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if cleanup.state == .complete,
            cleanup.providerCloseOutcomeDigest == providerCloseOutcomeDigest
        {
            return cleanup
        }
        guard
            cleanup.state == .pending || cleanup.state == .recoveryRequired,
            let reference = cleanup.effectTokenReference
        else {
            throw Self.invalidTransition(
                expected: "unfinished or identical complete cleanup",
                actual: cleanup.state.rawValue
            )
        }
        let completed = try Self.detachedCleanup(
            copying: cleanup,
            reference: nil,
            outcome: providerCloseOutcomeDigest,
            state: .complete
        )
        let removal = try LoggingEffectRemovalPendingV1(
            kind: .detachedCleanup,
            ownerID: cleanup.cleanupID,
            effectTokenReference: reference,
            terminalOutcome: .detachedCleanupCompleted(
                providerCloseOutcomeDigest: providerCloseOutcomeDigest
            )
        )
        var cleanups = currentSnapshot.detachedCleanups
        cleanups[index] = completed
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: cleanups,
            readerOperations: currentSnapshot.readerOperations,
            pendingEffectRemovals: currentSnapshot.pendingEffectRemovals + [removal]
        )
        return completed
    }

    public func tombstoneDetachedCleanup(
        _ expected: LoggingDetachedCleanupV1
    ) async throws -> LoggingDetachedCleanupV1 {
        try await replaceDetachedCleanup(expected) { cleanup in
            switch cleanup.state {
            case .complete, .tombstoned:
                return try Self.detachedCleanup(copying: cleanup, state: .tombstoned)
            case .pending, .recoveryRequired:
                throw Self.invalidTransition(
                    expected: "complete",
                    actual: cleanup.state.rawValue
                )
            }
        }
    }

    public func reserveReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderReservationV1 {
        let match = try findReaderOperation(for: request)
        if let record = match.record {
            return .replay(record)
        }
        guard
            currentSnapshot.readerOperations.count
                < ContainerLogLifecycleLedgerLimitsV1.maximumReaderOperations
        else {
            throw ContainerLogLifecycleLedgerError.capacityExceeded(
                collection: "readerOperations",
                maximum: ContainerLogLifecycleLedgerLimitsV1.maximumReaderOperations
            )
        }
        guard
            !currentSnapshot.readerOperations.contains(where: {
                $0.request.readerSessionID == request.readerSessionID
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        try rejectStaleReaderGeneration(request)
        try validateReaderSource(request.source)

        let record = try LoggingReaderOperationRecordV1(request: request, result: .reserved)
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations + [record]
        )
        return .reserved(record)
    }

    public func markReaderOpenRecoveryRequired(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderOperationRecordV1 {
        try await replaceReaderOperation(for: request) { record in
            switch record.result {
            case .reserved, .openRecoveryRequired:
                return try LoggingReaderOperationRecordV1(
                    request: request,
                    result: .openRecoveryRequired
                )
            default:
                throw Self.invalidTransition(
                    expected: "reserved or openRecoveryRequired",
                    actual: record.result.kindName
                )
            }
        }
    }

    public func recordReaderPreparation(
        _ preparation: LoggingReaderPreparationV1,
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderOperationRecordV1 {
        try preparation.validateEffectReference(owningControllerID: owningControllerID)
        return try await replaceReaderOperation(for: request) { record in
            switch record.result {
            case .reserved, .openRecoveryRequired:
                return try LoggingReaderOperationRecordV1(
                    request: request,
                    result: .prepared(preparation)
                )
            case .prepared(let existing) where existing == preparation:
                return record
            default:
                throw Self.invalidTransition(
                    expected: "reserved, recovery, or identical preparation",
                    actual: record.result.kindName
                )
            }
        }
    }

    public func markReaderCandidateClosing(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderPreparationV1 {
        let record = try await replaceReaderOperation(for: request) { record in
            switch record.result {
            case .prepared(let preparation), .candidateRecoveryRequired(let preparation),
                .candidateClosing(let preparation):
                return try LoggingReaderOperationRecordV1(
                    request: request,
                    result: .candidateClosing(preparation)
                )
            default:
                throw Self.invalidTransition(
                    expected: "prepared reader candidate",
                    actual: record.result.kindName
                )
            }
        }
        guard let preparation = record.result.preparation else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "candidate-closing reader lost its preparation"
            )
        }
        return preparation
    }

    public func markReaderCandidateRecoveryRequired(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderPreparationV1 {
        let record = try await replaceReaderOperation(for: request) { record in
            switch record.result {
            case .prepared(let preparation), .candidateClosing(let preparation),
                .candidateRecoveryRequired(let preparation):
                return try LoggingReaderOperationRecordV1(
                    request: request,
                    result: .candidateRecoveryRequired(preparation)
                )
            default:
                throw Self.invalidTransition(
                    expected: "prepared reader candidate",
                    actual: record.result.kindName
                )
            }
        }
        guard let preparation = record.result.preparation else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "candidate-recovery reader lost its preparation"
            )
        }
        return preparation
    }

    public func completeReaderCandidate(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderOperationRecordV1 {
        let located = try findReaderOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let reference: ProtectedLoggingEffectReferenceV1
        switch record.result {
        case .prepared(let preparation), .candidateClosing(let preparation),
            .candidateRecoveryRequired(let preparation):
            reference = preparation.effectTokenReference
        case .candidateClosed:
            return record
        default:
            throw Self.invalidTransition(
                expected: "prepared or closed reader candidate",
                actual: record.result.kindName
            )
        }
        let terminal = try LoggingReaderOperationRecordV1(
            request: request,
            result: .candidateClosed
        )
        let removal = try LoggingEffectRemovalPendingV1(
            kind: .readerCandidate,
            ownerID: request.readerSessionID,
            effectTokenReference: reference,
            terminalOutcome: .readerCandidateClosed
        )
        var operations = currentSnapshot.readerOperations
        operations[index] = terminal
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: operations,
            pendingEffectRemovals: currentSnapshot.pendingEffectRemovals + [removal]
        )
        return terminal
    }

    public func commitReaderSession(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderSessionV1 {
        let located = try findReaderOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if let existing = record.result.session {
            return existing
        }
        guard case .prepared(let preparation) = record.result else {
            throw Self.invalidTransition(
                expected: "prepared",
                actual: record.result.kindName
            )
        }
        try validateReaderSource(request.source)
        let session = try LoggingReaderSessionV1(
            readerSessionID: preparation.readerSessionID,
            containerID: preparation.containerID,
            leaseGeneration: preparation.leaseGeneration,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            source: preparation.source,
            effectTokenReference: preparation.effectTokenReference,
            terminalOutcomeDigest: nil,
            state: .active
        )
        var operations = currentSnapshot.readerOperations
        operations[index] = try LoggingReaderOperationRecordV1(
            request: request,
            result: .activated(session)
        )
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: operations
        )
        return session
    }

    public func beginReaderClose(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        try await replaceReaderSession(expected) { session in
            switch session.state {
            case .active, .closing:
                return try Self.readerSession(copying: session, state: .closing)
            default:
                throw Self.invalidTransition(
                    expected: "active or closing",
                    actual: session.state.rawValue
                )
            }
        }
    }

    public func markReaderRecoveryRequired(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        try await replaceReaderSession(expected) { session in
            switch session.state {
            case .active, .closing, .recoveryRequired:
                return try Self.readerSession(copying: session, state: .recoveryRequired)
            case .closed, .tombstoned:
                throw Self.invalidTransition(
                    expected: "live reader",
                    actual: session.state.rawValue
                )
            }
        }
    }

    public func restoreReaderActive(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        try await replaceReaderSession(expected) { session in
            guard session.state == .recoveryRequired else {
                throw Self.invalidTransition(
                    expected: "recoveryRequired",
                    actual: session.state.rawValue
                )
            }
            return try Self.readerSession(copying: session, state: .active)
        }
    }

    public func resumeReaderClose(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        try await replaceReaderSession(expected) { session in
            guard session.state == .recoveryRequired else {
                throw Self.invalidTransition(
                    expected: "recoveryRequired",
                    actual: session.state.rawValue
                )
            }
            return try Self.readerSession(copying: session, state: .closing)
        }
    }

    public func completeReaderClose(
        _ expected: LoggingReaderSessionV1,
        terminalOutcomeDigest: String
    ) async throws -> LoggingReaderSessionV1 {
        try ContainerLogLifecycleLedgerValidation.digest(
            terminalOutcomeDigest,
            field: "terminalOutcomeDigest"
        )
        guard
            let index = currentSnapshot.readerOperations.firstIndex(where: {
                $0.request.readerSessionID == expected.readerSessionID
            }), let session = currentSnapshot.readerOperations[index].result.session
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        guard session == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if session.state == .closed,
            session.terminalOutcomeDigest == terminalOutcomeDigest
        {
            return session
        }
        guard session.state == .closing, let reference = session.effectTokenReference else {
            throw Self.invalidTransition(
                expected: "closing",
                actual: session.state.rawValue
            )
        }
        let closed = try Self.readerSession(
            copying: session,
            reference: nil,
            outcome: terminalOutcomeDigest,
            state: .closed
        )
        let removal = try LoggingEffectRemovalPendingV1(
            kind: .readerSession,
            ownerID: session.readerSessionID,
            effectTokenReference: reference,
            terminalOutcome: .readerClosed(
                terminalOutcomeDigest: terminalOutcomeDigest
            )
        )
        var operations = currentSnapshot.readerOperations
        operations[index] = try LoggingReaderOperationRecordV1(
            request: currentSnapshot.readerOperations[index].request,
            result: .activated(closed)
        )
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: operations,
            pendingEffectRemovals: currentSnapshot.pendingEffectRemovals + [removal]
        )
        return closed
    }

    public func tombstoneReader(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        try await replaceReaderSession(expected) { session in
            switch session.state {
            case .closed, .tombstoned:
                return try Self.readerSession(copying: session, state: .tombstoned)
            default:
                throw Self.invalidTransition(
                    expected: "closed",
                    actual: session.state.rawValue
                )
            }
        }
    }

    private func findWriterOperation(
        for request: LogDriverStartRequestV1
    ) throws -> (index: Int?, record: LoggingWriterOperationRecordV1?) {
        for (index, record) in currentSnapshot.writerOperations.enumerated() {
            switch request.idempotencyComparison(to: record.request) {
            case .distinctScope:
                continue
            case .identicalReplay:
                return (index, record)
            case .conflict:
                throw ContainerLogLifecycleLedgerError.idempotencyConflict
            }
        }
        return (nil, nil)
    }

    private func findReaderOperation(
        for request: LogDriverReaderOpenRequestV1
    ) throws -> (index: Int?, record: LoggingReaderOperationRecordV1?) {
        for (index, record) in currentSnapshot.readerOperations.enumerated() {
            switch request.idempotencyComparison(to: record.request) {
            case .distinctScope:
                continue
            case .identicalReplay:
                return (index, record)
            case .conflict:
                throw ContainerLogLifecycleLedgerError.idempotencyConflict
            }
        }
        return (nil, nil)
    }

    private func replaceWriterOperation(
        for request: LogDriverStartRequestV1,
        transform: (LoggingWriterOperationRecordV1) throws -> LoggingWriterOperationRecordV1
    ) async throws -> LoggingWriterOperationRecordV1 {
        let located = try findWriterOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let replacement = try transform(record)
        var operations = currentSnapshot.writerOperations
        operations[index] = replacement
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations
        )
        return replacement
    }

    private func replaceReaderOperation(
        for request: LogDriverReaderOpenRequestV1,
        transform: (LoggingReaderOperationRecordV1) throws -> LoggingReaderOperationRecordV1
    ) async throws -> LoggingReaderOperationRecordV1 {
        let located = try findReaderOperation(for: request)
        guard let index = located.index, let record = located.record else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let replacement = try transform(record)
        var operations = currentSnapshot.readerOperations
        operations[index] = replacement
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: operations
        )
        return replacement
    }

    private func locateWriterActivation(
        _ expected: LoggingSessionActivationV1
    ) throws -> (index: Int, record: LoggingWriterOperationRecordV1) {
        guard
            let index = currentSnapshot.writerOperations.firstIndex(where: {
                $0.request.sessionID == expected.sessionID
            }), let actual = currentSnapshot.writerOperations[index].result.activation
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        guard actual == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return (index, currentSnapshot.writerOperations[index])
    }

    private func replaceWriterActivation(
        _ expected: LoggingSessionActivationV1,
        transform: (LoggingSessionActivationV1) throws -> LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1 {
        let located = try locateWriterActivation(expected)
        let replacement = try transform(expected)
        var operations = currentSnapshot.writerOperations
        operations[located.index] = try LoggingWriterOperationRecordV1(
            request: located.record.request,
            result: .activated(replacement)
        )
        try await persist(
            writerOperations: operations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: currentSnapshot.readerOperations
        )
        return replacement
    }

    private func replaceDetachedCleanup(
        _ expected: LoggingDetachedCleanupV1,
        transform: (LoggingDetachedCleanupV1) throws -> LoggingDetachedCleanupV1
    ) async throws -> LoggingDetachedCleanupV1 {
        guard
            let index = currentSnapshot.detachedCleanups.firstIndex(where: {
                $0.cleanupID == expected.cleanupID
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        guard currentSnapshot.detachedCleanups[index] == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let replacement = try transform(expected)
        var cleanups = currentSnapshot.detachedCleanups
        cleanups[index] = replacement
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: cleanups,
            readerOperations: currentSnapshot.readerOperations
        )
        return replacement
    }

    private func replaceReaderSession(
        _ expected: LoggingReaderSessionV1,
        transform: (LoggingReaderSessionV1) throws -> LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1 {
        guard
            let index = currentSnapshot.readerOperations.firstIndex(where: {
                $0.request.readerSessionID == expected.readerSessionID
            }), let actual = currentSnapshot.readerOperations[index].result.session
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        guard actual == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let replacement = try transform(expected)
        var operations = currentSnapshot.readerOperations
        operations[index] = try LoggingReaderOperationRecordV1(
            request: operations[index].request,
            result: .activated(replacement)
        )
        try await persist(
            writerOperations: currentSnapshot.writerOperations,
            detachedCleanups: currentSnapshot.detachedCleanups,
            readerOperations: operations
        )
        return replacement
    }

    private func rejectStaleWriterGeneration(_ request: LogDriverStartRequestV1) throws {
        let sameContainer = currentSnapshot.writerOperations.map(\.request).filter {
            $0.containerID == request.containerID
        }
        if let maximumLease = sameContainer.map(\.leaseGeneration).max(),
            request.leaseGeneration < maximumLease
        {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
        let sameLease = sameContainer.filter { $0.leaseGeneration == request.leaseGeneration }
        if let maximumOperation = sameLease.map(\.operationGeneration).max(),
            request.operationGeneration <= maximumOperation
        {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
        if let maximumProcess = sameLease.map(\.candidateProcessGeneration).max(),
            request.candidateProcessGeneration <= maximumProcess
        {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
    }

    private func rejectStaleReaderGeneration(_ request: LogDriverReaderOpenRequestV1) throws {
        let sameContainer = currentSnapshot.readerOperations.map(\.request).filter {
            $0.containerID == request.containerID
        }
        if let maximumLease = sameContainer.map(\.leaseGeneration).max(),
            request.leaseGeneration < maximumLease
        {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
        let sameLease = sameContainer.filter { $0.leaseGeneration == request.leaseGeneration }
        if let maximumOperation = sameLease.map(\.operationGeneration).max(),
            request.operationGeneration <= maximumOperation
        {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
    }

    private func validateReaderSource(_ source: LoggingReaderSourceV1) throws {
        guard
            case .activeWriter(
                let sessionID,
                let writerProviderID,
                let writerProviderGeneration,
                let activeProcessGeneration,
                let activeSandboxGeneration
            ) = source
        else {
            return
        }
        guard
            let activation = currentSnapshot.writerOperations.compactMap(\.result.activation)
                .first(where: { $0.sessionID == sessionID }),
            activation.providerID == writerProviderID,
            activation.providerGeneration == writerProviderGeneration,
            activation.activeProcessGeneration == activeProcessGeneration,
            activation.activeSandboxGeneration == activeSandboxGeneration,
            activation.state == .active
        else {
            throw ContainerLogLifecycleLedgerError.staleGeneration
        }
    }

    private func persist(
        writerOperations: [LoggingWriterOperationRecordV1],
        detachedCleanups: [LoggingDetachedCleanupV1],
        readerOperations: [LoggingReaderOperationRecordV1],
        pendingEffectRemovals: [LoggingEffectRemovalPendingV1]? = nil
    ) async throws {
        guard !persistenceFailed else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "lifecycle persistence previously failed; reload is required"
            )
        }
        let candidate = try ContainerLogLifecycleLedgerSnapshotV1(
            owningControllerID: owningControllerID,
            writerOperations: writerOperations,
            detachedCleanups: detachedCleanups,
            readerOperations: readerOperations,
            pendingEffectRemovals: pendingEffectRemovals
                ?? currentSnapshot.pendingEffectRemovals
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= ContainerLogLifecycleLedgerLimitsV1.maximumSnapshotBytes else {
            throw ContainerLogLifecycleLedgerError.persistenceExceedsLimit(
                maximumBytes: ContainerLogLifecycleLedgerLimitsV1.maximumSnapshotBytes
            )
        }
        // Publish before the suspension point so reentrant actor calls observe
        // this validated reservation/transition and can only build on it. If
        // persistence fails, the ledger becomes fail-stop until crash reload;
        // rolling memory back could let an already attempted provider effect
        // be issued under a duplicate authority claim.
        currentSnapshot = candidate
        if let persistence {
            do {
                try await persistence.save(data)
            } catch {
                persistenceFailed = true
                throw error
            }
        }
        guard !persistenceFailed else {
            throw ContainerLogLifecycleLedgerError.corruptSnapshot(
                "concurrent lifecycle persistence failed; reload is required"
            )
        }
    }

    private static func writerActivation(
        copying activation: LoggingSessionActivationV1,
        reference: ProtectedLoggingEffectReferenceV1? = nil,
        disposition: LoggingSessionCloseDispositionV1? = nil,
        state: LoggingSessionState
    ) throws -> LoggingSessionActivationV1 {
        let keepsLiveValues = state == .active || state == .draining || state == .recoveryRequired
        return try LoggingSessionActivationV1(
            sessionID: activation.sessionID,
            containerID: activation.containerID,
            leaseGeneration: activation.leaseGeneration,
            activeProcessGeneration: activation.activeProcessGeneration,
            providerID: activation.providerID,
            providerGeneration: activation.providerGeneration,
            activeSandboxGeneration: activation.activeSandboxGeneration,
            effectTokenReference: keepsLiveValues
                ? (reference ?? activation.effectTokenReference)
                : reference,
            closeDisposition: keepsLiveValues
                ? nil
                : (disposition ?? activation.closeDisposition),
            state: state
        )
    }

    private static func detachedCleanup(
        copying cleanup: LoggingDetachedCleanupV1,
        reference: ProtectedLoggingEffectReferenceV1? = nil,
        outcome: String? = nil,
        state: LoggingDetachedCleanupStateV1
    ) throws -> LoggingDetachedCleanupV1 {
        let keepsLiveValues = state == .pending || state == .recoveryRequired
        return try LoggingDetachedCleanupV1(
            cleanupID: cleanup.cleanupID,
            sessionID: cleanup.sessionID,
            containerID: cleanup.containerID,
            leaseGeneration: cleanup.leaseGeneration,
            activeProcessGeneration: cleanup.activeProcessGeneration,
            providerID: cleanup.providerID,
            providerGeneration: cleanup.providerGeneration,
            activeSandboxGeneration: cleanup.activeSandboxGeneration,
            writerFenceReceiptDigest: cleanup.writerFenceReceiptDigest,
            effectTokenReference: keepsLiveValues
                ? (reference ?? cleanup.effectTokenReference)
                : reference,
            providerCloseOutcomeDigest: keepsLiveValues
                ? nil
                : (outcome ?? cleanup.providerCloseOutcomeDigest),
            state: state
        )
    }

    private static func readerSession(
        copying session: LoggingReaderSessionV1,
        reference: ProtectedLoggingEffectReferenceV1? = nil,
        outcome: String? = nil,
        state: LoggingReaderSessionStateV1
    ) throws -> LoggingReaderSessionV1 {
        let keepsLiveValues = state == .active || state == .closing || state == .recoveryRequired
        return try LoggingReaderSessionV1(
            readerSessionID: session.readerSessionID,
            containerID: session.containerID,
            leaseGeneration: session.leaseGeneration,
            providerID: session.providerID,
            providerGeneration: session.providerGeneration,
            source: session.source,
            effectTokenReference: keepsLiveValues
                ? (reference ?? session.effectTokenReference)
                : reference,
            terminalOutcomeDigest: keepsLiveValues
                ? nil
                : (outcome ?? session.terminalOutcomeDigest),
            state: state
        )
    }

    private static func invalidTransition(
        expected: String,
        actual: String
    ) -> ContainerLogLifecycleLedgerError {
        .invalidTransition(expected: expected, actual: actual)
    }
}
