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
import Darwin
import Foundation

public enum JournaldServiceWireError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt32)
    case invalidEnvelope
    case invalidOperationID
    case invalidSessionID
    case invalidEpoch
    case invalidFields
    case frameTooLarge(Int)
    case disconnected
    case deadlineExceeded
    case responseMismatch
    case invalidReplayLimits
}

public enum JournaldServiceWireOperationV1: String, Codable, Sendable {
    case activeSandboxGeneration
    case openWriter
    case write
    case flushWriter
    case closeWriter
    case openReader
    case nextReader
    case cancelReader
}

public enum JournaldServiceWireFailureV1: String, Codable, Sendable {
    case invalidRequest
    case generationMismatch
    case idempotencyConflict
    case unknownSession
    case deadlineExceeded
    case unavailable
    case internalFailure
}

private enum JournaldServiceWireLimitsV1 {
    static let maximumIdentifierBytes = 256
    static let maximumEpochBytes = 128
    static let maximumFieldCount = 256
    static let maximumFieldBytes = 512 * 1_024
    static let maximumMessageBytes = 512 * 1_024

    static func validate(identifier: String) throws {
        guard
            !identifier.isEmpty,
            identifier.utf8.count <= maximumIdentifierBytes
        else {
            throw JournaldServiceWireError.invalidSessionID
        }
    }

    static func validate(fields: [String: String]) throws {
        guard fields.count <= maximumFieldCount else {
            throw JournaldServiceWireError.invalidFields
        }
        var bytes = 0
        for (key, value) in fields {
            let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(
                value.utf8.count
            )
            let (nextBytes, totalOverflow) = bytes.addingReportingOverflow(entryBytes)
            guard
                !key.isEmpty,
                key.first != "_",
                !entryOverflow,
                !totalOverflow,
                nextBytes <= maximumFieldBytes
            else {
                throw JournaldServiceWireError.invalidFields
            }
            bytes = nextBytes
        }
    }
}

public struct JournaldDriverConfigurationWireV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let containerID: String
    public let fields: [String: String]

    public init(_ configuration: JournaldDriverConfiguration) throws {
        try JournaldServiceWireLimitsV1.validate(identifier: configuration.containerID)
        try JournaldServiceWireLimitsV1.validate(fields: configuration.fields)
        self.schemaVersion = Self.currentSchemaVersion
        self.containerID = configuration.containerID
        self.fields = configuration.fields
    }

    public func configuration() throws -> JournaldDriverConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw JournaldServiceWireError.unsupportedSchemaVersion(schemaVersion)
        }
        try JournaldServiceWireLimitsV1.validate(identifier: containerID)
        try JournaldServiceWireLimitsV1.validate(fields: fields)
        return try JournaldDriverConfiguration(
            containerID: containerID,
            fields: fields
        )
    }

    public init(from decoder: any Decoder) throws {
        let value = try Self.decodeUnchecked(from: decoder)
        self = try Self(value.configuration())
    }

    private static func decodeUnchecked(
        from decoder: any Decoder
    ) throws -> Self {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return Self(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            containerID: try container.decode(String.self, forKey: .containerID),
            fields: try container.decode([String: String].self, forKey: .fields)
        )
    }

    private init(
        schemaVersion: UInt32,
        containerID: String,
        fields: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.containerID = containerID
        self.fields = fields
    }
}

public struct JournaldEntryWireV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let message: Data
    public let priority: Int
    public let fields: [String: String]
    public let secondsSinceUnixEpoch: Int64
    public let nanoseconds: UInt32
    public let processGeneration: UInt64

    public init(_ entry: JournaldEntry) throws {
        guard entry.message.count <= JournaldServiceWireLimitsV1.maximumMessageBytes else {
            throw JournaldServiceWireError.frameTooLarge(entry.message.count)
        }
        try JournaldServiceWireLimitsV1.validate(fields: entry.fields)
        self.schemaVersion = Self.currentSchemaVersion
        self.message = entry.message
        self.priority = entry.priority.rawValue
        self.fields = entry.fields
        self.secondsSinceUnixEpoch = entry.receivedTimestamp.secondsSinceUnixEpoch
        self.nanoseconds = entry.receivedTimestamp.nanoseconds
        self.processGeneration = entry.processGeneration
    }

    public func entry() throws -> JournaldEntry {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw JournaldServiceWireError.unsupportedSchemaVersion(schemaVersion)
        }
        guard
            message.count <= JournaldServiceWireLimitsV1.maximumMessageBytes,
            let priority = JournaldPriority(rawValue: priority)
        else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        try JournaldServiceWireLimitsV1.validate(fields: fields)
        return try JournaldEntry(
            message: message,
            priority: priority,
            fields: fields,
            receivedTimestamp: ContainerLogTimestamp(
                secondsSinceUnixEpoch: secondsSinceUnixEpoch,
                nanoseconds: nanoseconds
            ),
            processGeneration: processGeneration
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            message: try container.decode(Data.self, forKey: .message),
            priority: try container.decode(Int.self, forKey: .priority),
            fields: try container.decode([String: String].self, forKey: .fields),
            secondsSinceUnixEpoch: try container.decode(
                Int64.self,
                forKey: .secondsSinceUnixEpoch
            ),
            nanoseconds: try container.decode(UInt32.self, forKey: .nanoseconds),
            processGeneration: try container.decode(
                UInt64.self,
                forKey: .processGeneration
            )
        )
        self = try Self(value.entry())
    }

    private init(
        schemaVersion: UInt32,
        message: Data,
        priority: Int,
        fields: [String: String],
        secondsSinceUnixEpoch: Int64,
        nanoseconds: UInt32,
        processGeneration: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.message = message
        self.priority = priority
        self.fields = fields
        self.secondsSinceUnixEpoch = secondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
        self.processGeneration = processGeneration
    }
}

public struct JournaldWriterOpenWireV1: Codable, Equatable, Sendable {
    public let request: LogDriverStartRequestV1
    public let configuration: JournaldDriverConfigurationWireV1
    public let epoch: String

    public init(_ value: JournaldWriterOpenRequest) throws {
        guard
            !value.epoch.isEmpty,
            value.epoch.utf8.count <= JournaldServiceWireLimitsV1.maximumEpochBytes
        else {
            throw JournaldServiceWireError.invalidEpoch
        }
        self.request = value.request
        self.configuration = try JournaldDriverConfigurationWireV1(
            value.configuration
        )
        self.epoch = value.epoch
    }

    public func value() throws -> JournaldWriterOpenRequest {
        guard
            !epoch.isEmpty,
            epoch.utf8.count <= JournaldServiceWireLimitsV1.maximumEpochBytes
        else {
            throw JournaldServiceWireError.invalidEpoch
        }
        return try JournaldWriterOpenRequest(
            request: request,
            configuration: configuration.configuration(),
            epoch: epoch
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            request: try container.decode(
                LogDriverStartRequestV1.self,
                forKey: .request
            ),
            configuration: try container.decode(
                JournaldDriverConfigurationWireV1.self,
                forKey: .configuration
            ),
            epoch: try container.decode(String.self, forKey: .epoch)
        )
        self = try Self(value.value())
    }

    private init(
        request: LogDriverStartRequestV1,
        configuration: JournaldDriverConfigurationWireV1,
        epoch: String
    ) {
        self.request = request
        self.configuration = configuration
        self.epoch = epoch
    }
}

public struct JournaldServiceWireRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationID: String
    public let operation: JournaldServiceWireOperationV1
    public let writerOpen: JournaldWriterOpenWireV1?
    public let sessionID: String?
    public let entry: JournaldEntryWireV1?
    public let timeoutNanoseconds: UInt64?
    public let fenced: Bool?
    public let readerOpen: LogDriverReaderOpenRequestV1?
    public let readerSequence: UInt64?

    public static func activeSandboxGeneration() throws -> Self {
        try make(operation: .activeSandboxGeneration)
    }

    public static func openWriter(_ value: JournaldWriterOpenRequest) throws -> Self {
        try make(operation: .openWriter, writerOpen: JournaldWriterOpenWireV1(value))
    }

    public static func write(sessionID: String, entry: JournaldEntry) throws -> Self {
        try make(
            operation: .write,
            sessionID: sessionID,
            entry: JournaldEntryWireV1(entry)
        )
    }

    public static func flushWriter(
        sessionID: String,
        timeoutNanoseconds: UInt64
    ) throws -> Self {
        try make(
            operation: .flushWriter,
            sessionID: sessionID,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public static func closeWriter(
        sessionID: String,
        fenced: Bool,
        timeoutNanoseconds: UInt64
    ) throws -> Self {
        try make(
            operation: .closeWriter,
            sessionID: sessionID,
            timeoutNanoseconds: timeoutNanoseconds,
            fenced: fenced
        )
    }

    public static func openReader(_ request: LogDriverReaderOpenRequestV1) throws -> Self {
        try make(operation: .openReader, readerOpen: request)
    }

    public static func nextReader(
        sessionID: String,
        readerSequence: UInt64
    ) throws -> Self {
        try make(
            operation: .nextReader,
            sessionID: sessionID,
            readerSequence: readerSequence
        )
    }

    public static func cancelReader(sessionID: String) throws -> Self {
        try make(operation: .cancelReader, sessionID: sessionID)
    }

    private static func make(
        operation: JournaldServiceWireOperationV1,
        writerOpen: JournaldWriterOpenWireV1? = nil,
        sessionID: String? = nil,
        entry: JournaldEntryWireV1? = nil,
        timeoutNanoseconds: UInt64? = nil,
        fenced: Bool? = nil,
        readerOpen: LogDriverReaderOpenRequestV1? = nil,
        readerSequence: UInt64? = nil
    ) throws -> Self {
        try Self(
            schemaVersion: currentSchemaVersion,
            operationID: UUID().uuidString.lowercased(),
            operation: operation,
            writerOpen: writerOpen,
            sessionID: sessionID,
            entry: entry,
            timeoutNanoseconds: timeoutNanoseconds,
            fenced: fenced,
            readerOpen: readerOpen,
            readerSequence: readerSequence
        )
    }

    private init(
        schemaVersion: UInt32,
        operationID: String,
        operation: JournaldServiceWireOperationV1,
        writerOpen: JournaldWriterOpenWireV1?,
        sessionID: String?,
        entry: JournaldEntryWireV1?,
        timeoutNanoseconds: UInt64?,
        fenced: Bool?,
        readerOpen: LogDriverReaderOpenRequestV1?,
        readerSequence: UInt64?
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw JournaldServiceWireError.unsupportedSchemaVersion(schemaVersion)
        }
        guard UUID(uuidString: operationID) != nil else {
            throw JournaldServiceWireError.invalidOperationID
        }
        if let sessionID {
            try JournaldServiceWireLimitsV1.validate(identifier: sessionID)
        }
        switch operation {
        case .activeSandboxGeneration:
            guard
                writerOpen == nil, sessionID == nil, entry == nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen == nil,
                readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .openWriter:
            guard
                writerOpen != nil, sessionID == nil, entry == nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen == nil,
                readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .write:
            guard
                writerOpen == nil, sessionID != nil, entry != nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen == nil,
                readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .flushWriter:
            guard
                writerOpen == nil, sessionID != nil, entry == nil,
                timeoutNanoseconds != nil, timeoutNanoseconds != 0,
                fenced == nil, readerOpen == nil, readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .closeWriter:
            guard
                writerOpen == nil, sessionID != nil, entry == nil,
                timeoutNanoseconds != nil, timeoutNanoseconds != 0,
                fenced != nil, readerOpen == nil, readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .openReader:
            guard
                writerOpen == nil, sessionID == nil, entry == nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen != nil,
                readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .nextReader:
            guard
                writerOpen == nil, sessionID != nil, entry == nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen == nil,
                readerSequence != nil, readerSequence != 0
            else { throw JournaldServiceWireError.invalidEnvelope }
        case .cancelReader:
            guard
                writerOpen == nil, sessionID != nil, entry == nil,
                timeoutNanoseconds == nil, fenced == nil, readerOpen == nil,
                readerSequence == nil
            else { throw JournaldServiceWireError.invalidEnvelope }
        }
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.operation = operation
        self.writerOpen = writerOpen
        self.sessionID = sessionID
        self.entry = entry
        self.timeoutNanoseconds = timeoutNanoseconds
        self.fenced = fenced
        self.readerOpen = readerOpen
        self.readerSequence = readerSequence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            operationID: try container.decode(String.self, forKey: .operationID),
            operation: try container.decode(
                JournaldServiceWireOperationV1.self,
                forKey: .operation
            ),
            writerOpen: try container.decodeIfPresent(
                JournaldWriterOpenWireV1.self,
                forKey: .writerOpen
            ),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
            entry: try container.decodeIfPresent(
                JournaldEntryWireV1.self,
                forKey: .entry
            ),
            timeoutNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .timeoutNanoseconds
            ),
            fenced: try container.decodeIfPresent(Bool.self, forKey: .fenced),
            readerOpen: try container.decodeIfPresent(
                LogDriverReaderOpenRequestV1.self,
                forKey: .readerOpen
            ),
            readerSequence: try container.decodeIfPresent(
                UInt64.self,
                forKey: .readerSequence
            )
        )
    }
}

public enum JournaldServiceReaderEventWireV1: Codable, Equatable, Sendable {
    case record(ContainerLogReadRecordWireV1)
    case endOfStream

    private enum Kind: String, Codable {
        case record
        case endOfStream
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case record
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .record:
            self = .record(
                try container.decode(
                    ContainerLogReadRecordWireV1.self,
                    forKey: .record
                )
            )
        case .endOfStream:
            guard !container.contains(.record) else {
                throw JournaldServiceWireError.invalidEnvelope
            }
            self = .endOfStream
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .record(let record):
            try container.encode(Kind.record, forKey: .kind)
            try container.encode(record, forKey: .record)
        case .endOfStream:
            try container.encode(Kind.endOfStream, forKey: .kind)
        }
    }
}

public struct JournaldServiceWireResponseV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationID: String
    public let sandboxGeneration: UInt64?
    public let readerEvent: JournaldServiceReaderEventWireV1?
    public let failure: JournaldServiceWireFailureV1?

    public static func acknowledgement(operationID: String) throws -> Self {
        try Self(operationID: operationID)
    }

    public static func generation(
        operationID: String,
        sandboxGeneration: UInt64
    ) throws -> Self {
        try Self(
            operationID: operationID,
            sandboxGeneration: sandboxGeneration
        )
    }

    public static func reader(
        operationID: String,
        event: JournaldServiceReaderEventWireV1
    ) throws -> Self {
        try Self(operationID: operationID, readerEvent: event)
    }

    public static func failed(
        operationID: String,
        failure: JournaldServiceWireFailureV1
    ) throws -> Self {
        try Self(operationID: operationID, failure: failure)
    }

    private init(
        schemaVersion: UInt32 = currentSchemaVersion,
        operationID: String,
        sandboxGeneration: UInt64? = nil,
        readerEvent: JournaldServiceReaderEventWireV1? = nil,
        failure: JournaldServiceWireFailureV1? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw JournaldServiceWireError.unsupportedSchemaVersion(schemaVersion)
        }
        guard UUID(uuidString: operationID) != nil else {
            throw JournaldServiceWireError.invalidOperationID
        }
        let payloadCount = [
            sandboxGeneration != nil,
            readerEvent != nil,
            failure != nil,
        ].filter { $0 }.count
        guard payloadCount <= 1, sandboxGeneration != 0 else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.sandboxGeneration = sandboxGeneration
        self.readerEvent = readerEvent
        self.failure = failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            operationID: try container.decode(String.self, forKey: .operationID),
            sandboxGeneration: try container.decodeIfPresent(
                UInt64.self,
                forKey: .sandboxGeneration
            ),
            readerEvent: try container.decodeIfPresent(
                JournaldServiceReaderEventWireV1.self,
                forKey: .readerEvent
            ),
            failure: try container.decodeIfPresent(
                JournaldServiceWireFailureV1.self,
                forKey: .failure
            )
        )
    }
}

public enum JournaldServiceFrameCodecV1 {
    public static let maximumFrameBytes = 1 * 1_024 * 1_024

    public static func write<Value: Encodable>(
        _ value: Value,
        to handle: FileHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= maximumFrameBytes else {
            throw JournaldServiceWireError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try handle.write(contentsOf: frame)
    }

    public static func read<Value: Decodable>(
        _ type: Value.Type,
        from handle: FileHandle
    ) throws -> Value {
        let header = try readExactly(4, from: handle)
        let length = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0, length <= maximumFrameBytes else {
            throw JournaldServiceWireError.frameTooLarge(Int(length))
        }
        let payload = try readExactly(Int(length), from: handle)
        return try JSONDecoder().decode(type, from: payload)
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard
                let part = try handle.read(upToCount: count - result.count),
                !part.isEmpty
            else {
                throw JournaldServiceWireError.disconnected
            }
            result.append(part)
        }
        return result
    }
}

public protocol JournaldServiceWireTransportV1: Sendable {
    func call(
        _ request: JournaldServiceWireRequestV1
    ) async throws -> JournaldServiceWireResponseV1
}

/// One persistent framed connection to the signed service. A disconnected
/// call is replayed once with the same operation ID so the service can return
/// its cached outcome instead of duplicating a writer, entry, or reader event.
public actor JournaldServiceFileHandleTransportV1: JournaldServiceWireTransportV1 {
    public typealias Connector = @Sendable () async throws -> FileHandle

    private let connector: Connector
    private var handle: FileHandle?
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    public func call(
        _ request: JournaldServiceWireRequestV1
    ) async throws -> JournaldServiceWireResponseV1 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            await acquireOperation()
            defer { releaseOperation() }
            try Task.checkCancellation()
            var lastError: (any Error)?
            for attempt in 0..<2 {
                do {
                    let handle = try await connectedHandle()
                    let response = try await Task.detached {
                        try JournaldServiceFrameCodecV1.write(
                            request,
                            to: handle
                        )
                        return try JournaldServiceFrameCodecV1.read(
                            JournaldServiceWireResponseV1.self,
                            from: handle
                        )
                    }.value
                    guard response.operationID == request.operationID else {
                        throw JournaldServiceWireError.responseMismatch
                    }
                    return response
                } catch {
                    lastError = error
                    invalidateHandle()
                    try Task.checkCancellation()
                    guard attempt == 0, Self.isReconnectable(error) else {
                        break
                    }
                }
            }
            throw lastError ?? JournaldServiceWireError.disconnected
        } onCancel: {
            Task { await self.close() }
        }
    }

    public func close() {
        invalidateHandle()
    }

    private func connectedHandle() async throws -> FileHandle {
        if let handle {
            return handle
        }
        let connected = try await connector()
        do {
            try Self.suppressBrokenPipeSignal(on: connected)
        } catch {
            try? connected.close()
            throw error
        }
        handle = connected
        return connected
    }

    private func invalidateHandle() {
        guard let handle else {
            return
        }
        self.handle = nil
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
    }

    private static func isReconnectable(_ error: any Error) -> Bool {
        if let error = error as? JournaldServiceWireError {
            return error == .disconnected
        }
        return error is POSIXError || error is CocoaError
    }

    private static func suppressBrokenPipeSignal(on handle: FileHandle) throws {
        var enabled: Int32 = 1
        let result = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                handle.fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func acquireOperation() async {
        guard operationActive else {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

public actor JournaldServiceWireClientV1: JournaldService {
    private let transport: any JournaldServiceWireTransportV1

    public init(transport: any JournaldServiceWireTransportV1) {
        self.transport = transport
    }

    public func activeSandboxGeneration() async throws -> UInt64 {
        let request = try JournaldServiceWireRequestV1.activeSandboxGeneration()
        let response = try await invoke(request)
        guard let generation = response.sandboxGeneration else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        return generation
    }

    public func openWriter(_ request: JournaldWriterOpenRequest) async throws {
        try await requireAcknowledgement(
            JournaldServiceWireRequestV1.openWriter(request)
        )
    }

    public func write(sessionID: String, entry: JournaldEntry) async throws {
        try await requireAcknowledgement(
            JournaldServiceWireRequestV1.write(
                sessionID: sessionID,
                entry: entry
            )
        )
    }

    public func flushWriter(
        sessionID: String,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await requireAcknowledgement(
            JournaldServiceWireRequestV1.flushWriter(
                sessionID: sessionID,
                timeoutNanoseconds: try Self.timeout(to: deadline)
            )
        )
    }

    public func closeWriter(
        sessionID: String,
        fenced: Bool,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await requireAcknowledgement(
            JournaldServiceWireRequestV1.closeWriter(
                sessionID: sessionID,
                fenced: fenced,
                timeoutNanoseconds: try Self.timeout(to: deadline)
            )
        )
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> any ContainerLogReader {
        try await requireAcknowledgement(
            JournaldServiceWireRequestV1.openReader(request)
        )
        return JournaldServiceWireReaderV1(
            sessionID: request.readerSessionID,
            client: self
        )
    }

    fileprivate func nextReader(
        sessionID: String,
        sequence: UInt64
    ) async throws -> ContainerLogReaderEventV1 {
        let response = try await invoke(
            JournaldServiceWireRequestV1.nextReader(
                sessionID: sessionID,
                readerSequence: sequence
            )
        )
        guard let event = response.readerEvent else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        switch event {
        case .record(let wire):
            return .record(try wire.record())
        case .endOfStream:
            return .endOfStream
        }
    }

    fileprivate func cancelReader(sessionID: String) async {
        guard
            let request = try? JournaldServiceWireRequestV1.cancelReader(
                sessionID: sessionID
            )
        else {
            return
        }
        try? await requireAcknowledgement(request)
    }

    private func requireAcknowledgement(
        _ request: JournaldServiceWireRequestV1
    ) async throws {
        let response = try await invoke(request)
        guard
            response.sandboxGeneration == nil,
            response.readerEvent == nil
        else {
            throw JournaldServiceWireError.invalidEnvelope
        }
    }

    private func invoke(
        _ request: JournaldServiceWireRequestV1
    ) async throws -> JournaldServiceWireResponseV1 {
        let response: JournaldServiceWireResponseV1
        do {
            response = try await transport.call(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as JournaldServiceWireError {
            if error == .deadlineExceeded {
                throw JournaldProviderError.deadlineExceeded
            }
            throw JournaldProviderError.transportClosed
        } catch {
            throw JournaldProviderError.transportClosed
        }
        guard response.operationID == request.operationID else {
            throw JournaldServiceWireError.responseMismatch
        }
        if let failure = response.failure {
            throw Self.providerError(failure)
        }
        return response
    }

    private static func providerError(
        _ failure: JournaldServiceWireFailureV1
    ) -> JournaldProviderError {
        switch failure {
        case .invalidRequest:
            return .invalidJournalEntry
        case .generationMismatch:
            return .invalidSessionFence
        case .idempotencyConflict:
            return .idempotencyConflict
        case .unknownSession:
            return .unknownSession
        case .deadlineExceeded:
            return .deadlineExceeded
        case .unavailable, .internalFailure:
            return .transportClosed
        }
    }

    private static func timeout(
        to deadline: ContinuousClock.Instant
    ) throws -> UInt64 {
        let duration = ContinuousClock().now.duration(to: deadline)
        let components = duration.components
        guard components.seconds >= 0 else {
            throw JournaldProviderError.deadlineExceeded
        }
        let seconds = UInt64(components.seconds)
        let (wholeNanoseconds, overflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard !overflow else {
            return UInt64.max
        }
        let fractional = UInt64(max(0, components.attoseconds / 1_000_000_000))
        let (result, additionOverflow) = wholeNanoseconds.addingReportingOverflow(
            fractional
        )
        guard !additionOverflow, result > 0 else {
            throw JournaldProviderError.deadlineExceeded
        }
        return result
    }
}

private actor JournaldServiceWireReaderV1: ContainerLogReader {
    private let sessionID: String
    private let client: JournaldServiceWireClientV1
    private var sequence: UInt64 = 1
    private var closed = false

    init(sessionID: String, client: JournaldServiceWireClientV1) {
        self.sessionID = sessionID
        self.client = client
    }

    func next() async throws -> ContainerLogReaderEventV1 {
        guard !closed else {
            throw ContainerLogReaderError.alreadyEnded
        }
        let event = try await client.nextReader(
            sessionID: sessionID,
            sequence: sequence
        )
        switch event {
        case .record:
            let next = sequence.addingReportingOverflow(1)
            guard !next.overflow else {
                closed = true
                throw JournaldServiceWireError.invalidEnvelope
            }
            sequence = next.partialValue
        case .endOfStream:
            closed = true
        }
        return event
    }

    func cancel() async {
        guard !closed else {
            return
        }
        closed = true
        await client.cancelReader(sessionID: sessionID)
    }
}
