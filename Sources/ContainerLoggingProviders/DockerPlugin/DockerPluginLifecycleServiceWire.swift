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
import CryptoKit
import Darwin
import Foundation

public enum DockerPluginLifecycleServiceWireError: Error, Equatable,
    Sendable
{
    case invalidEnvelope
    case responseMismatch
    case disconnected
    case frameTooLarge(Int)
    case generationMismatch
    case idempotencyConflict
    case invalidToken
    case invalidFence
    case capabilityMismatch
    case pluginRejected
    case unknownSession
    case unavailable
    case internalFailure
    case invalidAuthentication
}

package enum DockerPluginLifecycleServiceWireOperationV1: String, Codable,
    Sendable
{
    case activeSandboxGeneration
    case migrateHistory
    case reclaimGeneration
    case startWriter
    case reconcileWriterOpen
    case writeWriter
    case flushWriter
    case finishWriter
    case reconcileWriter
    case fenceWriter
    case closeWriter
    case openReader
    case reconcileReaderOpen
    case nextReader
    case cancelReader
    case reconcileReader
    case closeReader
    case reclaimTerminalEffect
}

package enum DockerPluginLifecycleServiceWireFailureV1: String, Codable,
    Sendable
{
    case invalidRequest
    case generationMismatch
    case idempotencyConflict
    case invalidToken
    case invalidFence
    case capabilityMismatch
    case pluginRejected
    case unknownSession
    case unavailable
    case internalFailure
}

package enum DockerPluginLifecycleServiceOpenObservationV1: String, Codable,
    Sendable
{
    case absent
    case prepared
    case conflict
    case uncertain
}

package struct DockerPluginCapabilitiesWireV1: Codable, Equatable, Sendable {
    package let readLogs: Bool

    private enum CodingKeys: String, CodingKey {
        case readLogs = "ReadLogs"
    }

    package init(_ capabilities: DockerPluginCapabilities) {
        self.readLogs = capabilities.readLogs
    }

    package var value: DockerPluginCapabilities {
        DockerPluginCapabilities(readLogs: readLogs)
    }
}

package struct DockerPluginWriterOpenWireV1: Codable, Equatable, Sendable {
    package let request: LogDriverStartRequestV1
    package let info: DockerPluginInfoWireV1
    package let expectedReadLogs: Bool

    package init(
        _ open: DockerPluginWriterOpenRequest,
        expectedReadLogs: Bool
    ) {
        self.request = open.request
        self.info = DockerPluginInfoWireV1(open.info)
        self.expectedReadLogs = expectedReadLogs
    }
}

package struct DockerPluginReaderOpenWireV1: Codable, Equatable, Sendable {
    package let request: LogDriverReaderOpenRequestV1
    package let pluginRequest: DockerPluginReadRequestWireV1

    package init(_ open: DockerPluginReaderOpenRequest) {
        self.request = open.request
        self.pluginRequest = DockerPluginReadRequestWireV1(
            info: DockerPluginInfoWireV1(open.info),
            config: DockerPluginReadConfigurationWireV1(
                DockerPluginReadConfiguration(open.request.read)
            )
        )
    }
}

package struct DockerPluginWriterCallWireV1: Codable, Equatable, Sendable {
    package let schemaVersion: UInt32
    package let sessionID: String
    package let containerID: String
    package let leaseGeneration: UInt64
    package let providerID: String
    package let providerGeneration: UInt64
    package let fence: LogDriverSessionFenceV1
    package let token: Data

    package init(_ call: LogDriverSessionCallV1) {
        self.schemaVersion = call.schemaVersion
        self.sessionID = call.sessionID
        self.containerID = call.containerID
        self.leaseGeneration = call.leaseGeneration
        self.providerID = call.providerID
        self.providerGeneration = call.providerGeneration
        self.fence = call.fence
        self.token = Self.data(call.effectTokenMaterial)
    }

    private static func data(_ token: LogDriverOpaqueEffectTokenV1) -> Data {
        token.withUnsafeBytes { Data($0) }
    }
}

package struct DockerPluginReaderCallWireV1: Codable, Equatable, Sendable {
    package let schemaVersion: UInt32
    package let readerSessionID: String
    package let containerID: String
    package let leaseGeneration: UInt64
    package let providerID: String
    package let providerGeneration: UInt64
    package let source: LoggingReaderSourceV1
    package let token: Data

    package init(_ call: LogDriverReaderCallV1) {
        self.schemaVersion = call.schemaVersion
        self.readerSessionID = call.readerSessionID
        self.containerID = call.containerID
        self.leaseGeneration = call.leaseGeneration
        self.providerID = call.providerID
        self.providerGeneration = call.providerGeneration
        self.source = call.source
        self.token = call.effectTokenMaterial.withUnsafeBytes { Data($0) }
    }
}

package struct DockerPluginTerminalReclaimWireV1: Codable, Equatable, Sendable {
    package let schemaVersion: UInt32
    package let kind: LoggingEffectRemovalKindV1
    package let effectID: String
    package let providerID: String
    package let providerGeneration: UInt64

    package init(_ reclaim: LogDriverTerminalEffectReclaimV1) {
        self.schemaVersion = 1
        self.kind = reclaim.kind
        self.effectID = reclaim.effectID
        self.providerID = reclaim.providerID
        self.providerGeneration = reclaim.providerGeneration
    }
}

public struct DockerPluginLifecycleServiceWireRequestV1: Codable, Equatable,
    Sendable
{
    package static let schemaVersion: UInt32 = 1

    package let schemaVersion: UInt32
    package let operationID: String
    package let operation: DockerPluginLifecycleServiceWireOperationV1
    package let writerOpen: DockerPluginWriterOpenWireV1?
    package let writerStart: LogDriverStartRequestV1?
    package let writerCall: DockerPluginWriterCallWireV1?
    package let readerOpen: DockerPluginReaderOpenWireV1?
    package let readerStart: LogDriverReaderOpenRequestV1?
    package let readerCall: DockerPluginReaderCallWireV1?
    package let terminalReclaim: DockerPluginTerminalReclaimWireV1?
    package let historyMigration: LogDriverHistoryMigrationRequestV1?
    package let generationReclaim: LogDriverProviderGenerationReclaimV1?
    package let sessionID: String?
    package let token: Data?
    package let frame: Data?
    package let sequence: UInt64?
    package let fenced: Bool?
    package let authentication: Data?

    private init(
        operation: DockerPluginLifecycleServiceWireOperationV1,
        writerOpen: DockerPluginWriterOpenWireV1? = nil,
        writerStart: LogDriverStartRequestV1? = nil,
        writerCall: DockerPluginWriterCallWireV1? = nil,
        readerOpen: DockerPluginReaderOpenWireV1? = nil,
        readerStart: LogDriverReaderOpenRequestV1? = nil,
        readerCall: DockerPluginReaderCallWireV1? = nil,
        terminalReclaim: DockerPluginTerminalReclaimWireV1? = nil,
        historyMigration: LogDriverHistoryMigrationRequestV1? = nil,
        generationReclaim: LogDriverProviderGenerationReclaimV1? = nil,
        sessionID: String? = nil,
        token: Data? = nil,
        frame: Data? = nil,
        sequence: UInt64? = nil,
        fenced: Bool? = nil,
        authentication: Data? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.operationID = UUID().uuidString.lowercased()
        self.operation = operation
        self.writerOpen = writerOpen
        self.writerStart = writerStart
        self.writerCall = writerCall
        self.readerOpen = readerOpen
        self.readerStart = readerStart
        self.readerCall = readerCall
        self.terminalReclaim = terminalReclaim
        self.historyMigration = historyMigration
        self.generationReclaim = generationReclaim
        self.sessionID = sessionID
        self.token = token
        self.frame = frame
        self.sequence = sequence
        self.fenced = fenced
        self.authentication = authentication
    }

    package static func generation() -> Self {
        Self(operation: .activeSandboxGeneration)
    }

    package static func migrateHistory(
        _ request: LogDriverHistoryMigrationRequestV1
    ) -> Self {
        Self(operation: .migrateHistory, historyMigration: request)
    }

    package static func reclaimGeneration(
        _ request: LogDriverProviderGenerationReclaimV1
    ) -> Self {
        Self(operation: .reclaimGeneration, generationReclaim: request)
    }

    package static func startWriter(
        _ open: DockerPluginWriterOpenRequest,
        expectedReadLogs: Bool
    ) -> Self {
        Self(
            operation: .startWriter,
            writerOpen: DockerPluginWriterOpenWireV1(
                open,
                expectedReadLogs: expectedReadLogs
            )
        )
    }

    package static func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) -> Self {
        Self(operation: .reconcileWriterOpen, writerStart: request)
    }

    package static func writeWriter(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1,
        sequence: UInt64,
        frame: Data
    ) -> Self {
        Self(
            operation: .writeWriter,
            sessionID: sessionID,
            token: token.withUnsafeBytes { Data($0) },
            frame: frame,
            sequence: sequence
        )
    }

    package static func flushWriter(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1
    ) -> Self {
        Self(
            operation: .flushWriter,
            sessionID: sessionID,
            token: token.withUnsafeBytes { Data($0) }
        )
    }

    package static func finishWriter(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1,
        fenced: Bool
    ) -> Self {
        Self(
            operation: .finishWriter,
            sessionID: sessionID,
            token: token.withUnsafeBytes { Data($0) },
            fenced: fenced
        )
    }

    package static func writerCall(
        _ operation: DockerPluginLifecycleServiceWireOperationV1,
        call: LogDriverSessionCallV1
    ) -> Self {
        Self(operation: operation, writerCall: DockerPluginWriterCallWireV1(call))
    }

    package static func openReader(
        _ open: DockerPluginReaderOpenRequest
    ) -> Self {
        Self(operation: .openReader, readerOpen: DockerPluginReaderOpenWireV1(open))
    }

    package static func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) -> Self {
        Self(operation: .reconcileReaderOpen, readerStart: request)
    }

    package static func nextReader(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1,
        sequence: UInt64
    ) -> Self {
        Self(
            operation: .nextReader,
            sessionID: sessionID,
            token: token.withUnsafeBytes { Data($0) },
            sequence: sequence
        )
    }

    package static func cancelReader(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1
    ) -> Self {
        Self(
            operation: .cancelReader,
            sessionID: sessionID,
            token: token.withUnsafeBytes { Data($0) }
        )
    }

    package static func readerCall(
        _ operation: DockerPluginLifecycleServiceWireOperationV1,
        call: LogDriverReaderCallV1
    ) -> Self {
        Self(operation: operation, readerCall: DockerPluginReaderCallWireV1(call))
    }

    package static func reclaim(
        _ request: LogDriverTerminalEffectReclaimV1
    ) -> Self {
        Self(
            operation: .reclaimTerminalEffect,
            terminalReclaim: DockerPluginTerminalReclaimWireV1(request)
        )
    }

    package func authenticated(using key: Data) throws -> Self {
        guard key.count == 32, authentication == nil else {
            throw DockerPluginLifecycleServiceWireError
                .invalidAuthentication
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let unsigned = try encoder.encode(self)
        let authentication = Data(
            HMAC<SHA256>.authenticationCode(
                for: unsigned,
                using: SymmetricKey(data: key)
            )
        )
        return Self(
            schemaVersion: schemaVersion,
            operationID: operationID,
            operation: operation,
            writerOpen: writerOpen,
            writerStart: writerStart,
            writerCall: writerCall,
            readerOpen: readerOpen,
            readerStart: readerStart,
            readerCall: readerCall,
            terminalReclaim: terminalReclaim,
            historyMigration: historyMigration,
            generationReclaim: generationReclaim,
            sessionID: sessionID,
            token: token,
            frame: frame,
            sequence: sequence,
            fenced: fenced,
            authentication: authentication
        )
    }

    private init(
        schemaVersion: UInt32,
        operationID: String,
        operation: DockerPluginLifecycleServiceWireOperationV1,
        writerOpen: DockerPluginWriterOpenWireV1?,
        writerStart: LogDriverStartRequestV1?,
        writerCall: DockerPluginWriterCallWireV1?,
        readerOpen: DockerPluginReaderOpenWireV1?,
        readerStart: LogDriverReaderOpenRequestV1?,
        readerCall: DockerPluginReaderCallWireV1?,
        terminalReclaim: DockerPluginTerminalReclaimWireV1?,
        historyMigration: LogDriverHistoryMigrationRequestV1?,
        generationReclaim: LogDriverProviderGenerationReclaimV1?,
        sessionID: String?,
        token: Data?,
        frame: Data?,
        sequence: UInt64?,
        fenced: Bool?,
        authentication: Data?
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.operation = operation
        self.writerOpen = writerOpen
        self.writerStart = writerStart
        self.writerCall = writerCall
        self.readerOpen = readerOpen
        self.readerStart = readerStart
        self.readerCall = readerCall
        self.terminalReclaim = terminalReclaim
        self.historyMigration = historyMigration
        self.generationReclaim = generationReclaim
        self.sessionID = sessionID
        self.token = token
        self.frame = frame
        self.sequence = sequence
        self.fenced = fenced
        self.authentication = authentication
    }
}

public struct DockerPluginLifecycleServiceWireResponseV1: Codable, Equatable,
    Sendable
{
    package let schemaVersion: UInt32
    package let operationID: String
    package let failure: DockerPluginLifecycleServiceWireFailureV1?
    package let sandboxGeneration: UInt64?
    package let openObservation: DockerPluginLifecycleServiceOpenObservationV1?
    package let capabilities: DockerPluginCapabilitiesWireV1?
    package let token: Data?
    package let writerObservation: LogDriverSessionObservationV1?
    package let readerObservation: LogDriverReaderObservationV1?
    package let fenceReceiptDigest: String?
    package let terminalOutcomeDigest: String?
    package let sequence: UInt64?
    package let frame: Data?
    package let endOfStream: Bool?
    package let historyMigrationReceipt: LogDriverHistoryMigrationReceiptV1?

    package init(
        operationID: String,
        failure: DockerPluginLifecycleServiceWireFailureV1? = nil,
        sandboxGeneration: UInt64? = nil,
        openObservation: DockerPluginLifecycleServiceOpenObservationV1? = nil,
        capabilities: DockerPluginCapabilitiesWireV1? = nil,
        token: Data? = nil,
        writerObservation: LogDriverSessionObservationV1? = nil,
        readerObservation: LogDriverReaderObservationV1? = nil,
        fenceReceiptDigest: String? = nil,
        terminalOutcomeDigest: String? = nil,
        sequence: UInt64? = nil,
        frame: Data? = nil,
        endOfStream: Bool? = nil,
        historyMigrationReceipt: LogDriverHistoryMigrationReceiptV1? = nil
    ) {
        self.schemaVersion =
            DockerPluginLifecycleServiceWireRequestV1
            .schemaVersion
        self.operationID = operationID
        self.failure = failure
        self.sandboxGeneration = sandboxGeneration
        self.openObservation = openObservation
        self.capabilities = capabilities
        self.token = token
        self.writerObservation = writerObservation
        self.readerObservation = readerObservation
        self.fenceReceiptDigest = fenceReceiptDigest
        self.terminalOutcomeDigest = terminalOutcomeDigest
        self.sequence = sequence
        self.frame = frame
        self.endOfStream = endOfStream
        self.historyMigrationReceipt = historyMigrationReceipt
    }
}

public enum DockerPluginLifecycleServiceFrameCodecV1 {
    public static let maximumFrameBytes = 24 * 1_024 * 1_024

    public static func write<Value: Encodable>(
        _ value: Value,
        to handle: FileHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else {
            throw DockerPluginLifecycleServiceWireError.frameTooLarge(
                payload.count
            )
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
        guard
            length > 0,
            length <= UInt32(Self.maximumFrameBytes)
        else {
            throw DockerPluginLifecycleServiceWireError.frameTooLarge(
                Int(length)
            )
        }
        return try JSONDecoder().decode(
            type,
            from: readExactly(Int(length), from: handle)
        )
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
                throw DockerPluginLifecycleServiceWireError.disconnected
            }
            result.append(part)
        }
        return result
    }
}

public protocol DockerPluginLifecycleServiceWireTransportV1: Sendable {
    func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1
}

/// A bounded pool of persistent connections. Each lane has one in-flight
/// operation, so independent container writers/readers make progress in
/// parallel without allowing responses to cross operation identities. A lost
/// response reconnects its lane and replays the byte-identical operation once.
public actor DockerPluginLifecycleServiceFileHandleTransportV1:
    DockerPluginLifecycleServiceWireTransportV1
{
    public typealias Connector = @Sendable () async throws -> FileHandle
    private static let maximumWaiters = 4_096

    private struct Lane {
        var handle: FileHandle?
        var inUse: Bool
    }

    private struct LaneWaiter {
        let operationID: String
        let continuation: CheckedContinuation<Int, any Error>
    }

    private let connector: Connector
    private let authenticationKey: Data
    private let maximumConnections: Int
    private var lanes = [Lane]()
    private var laneWaiters = [LaneWaiter]()
    private var activeOperations = [String: Set<Int>]()

    public init(
        authenticationKey: Data,
        maximumConnections: Int = 8,
        connector: @escaping Connector
    ) throws {
        guard
            authenticationKey.count == 32,
            maximumConnections > 0,
            maximumConnections <= 64
        else {
            throw DockerPluginLifecycleServiceWireError
                .invalidAuthentication
        }
        self.authenticationKey = authenticationKey
        self.maximumConnections = maximumConnections
        self.connector = connector
    }

    public func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        try Task.checkCancellation()
        let authenticatedRequest = try request.authenticated(
            using: authenticationKey
        )
        let operationID = authenticatedRequest.operationID
        return try await withTaskCancellationHandler {
            let lane = try await acquireLane(operationID: operationID)
            defer { releaseLane(lane, operationID: operationID) }
            var lastError: (any Error)?
            for attempt in 0..<2 {
                do {
                    try Task.checkCancellation()
                    let handle = try await connectedHandle(for: lane)
                    let response = try await Task.detached {
                        try DockerPluginLifecycleServiceFrameCodecV1.write(
                            authenticatedRequest,
                            to: handle
                        )
                        return try DockerPluginLifecycleServiceFrameCodecV1.read(
                            DockerPluginLifecycleServiceWireResponseV1.self,
                            from: handle
                        )
                    }.value
                    guard
                        response.schemaVersion
                            == DockerPluginLifecycleServiceWireRequestV1
                            .schemaVersion,
                        response.operationID == authenticatedRequest.operationID
                    else {
                        throw DockerPluginLifecycleServiceWireError
                            .responseMismatch
                    }
                    try response.validate(for: authenticatedRequest.operation)
                    return response
                } catch {
                    lastError = error
                    invalidateHandle(for: lane)
                    try Task.checkCancellation()
                    guard attempt == 0, Self.isReconnectable(error) else {
                        break
                    }
                }
            }
            throw lastError
                ?? DockerPluginLifecycleServiceWireError.disconnected
        } onCancel: {
            Task { await self.cancelOperation(operationID) }
        }
    }

    public func close() {
        for lane in lanes.indices {
            invalidateHandle(for: lane)
        }
    }

    private func connectedHandle(for lane: Int) async throws -> FileHandle {
        if let handle = lanes[lane].handle {
            return handle
        }
        let connected = try await connector()
        do {
            try Task.checkCancellation()
            try Self.suppressBrokenPipeSignal(on: connected)
        } catch {
            try? connected.close()
            throw error
        }
        lanes[lane].handle = connected
        return connected
    }

    private func invalidateHandle(for lane: Int) {
        guard let handle = lanes[lane].handle else {
            return
        }
        lanes[lane].handle = nil
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
    }

    private static func isReconnectable(_ error: any Error) -> Bool {
        if let error = error as? DockerPluginLifecycleServiceWireError {
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

    private func acquireLane(operationID: String) async throws -> Int {
        if let lane = lanes.firstIndex(where: { !$0.inUse }) {
            lanes[lane].inUse = true
            activeOperations[operationID, default: []].insert(lane)
            return lane
        }
        if lanes.count < maximumConnections {
            let lane = lanes.count
            lanes.append(Lane(handle: nil, inUse: true))
            activeOperations[operationID, default: []].insert(lane)
            return lane
        }
        guard laneWaiters.count < Self.maximumWaiters else {
            throw DockerPluginLifecycleServiceWireError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            laneWaiters.append(
                LaneWaiter(
                    operationID: operationID,
                    continuation: continuation
                )
            )
        }
    }

    private func releaseLane(_ lane: Int, operationID: String) {
        guard activeOperations[operationID]?.remove(lane) != nil else {
            return
        }
        if activeOperations[operationID]?.isEmpty == true {
            activeOperations.removeValue(forKey: operationID)
        }
        guard !laneWaiters.isEmpty else {
            lanes[lane].inUse = false
            return
        }
        let waiter = laneWaiters.removeFirst()
        activeOperations[waiter.operationID, default: []].insert(lane)
        waiter.continuation.resume(returning: lane)
    }

    private func cancelOperation(_ operationID: String) {
        let cancelledWaiters = laneWaiters.filter {
            $0.operationID == operationID
        }
        laneWaiters.removeAll { $0.operationID == operationID }
        for waiter in cancelledWaiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        for lane in activeOperations[operationID] ?? [] {
            invalidateHandle(for: lane)
        }
    }
}

extension DockerPluginLifecycleServiceWireResponseV1 {
    fileprivate func validate(
        for operation: DockerPluginLifecycleServiceWireOperationV1
    ) throws {
        let payloadCount = [
            sandboxGeneration != nil,
            openObservation != nil,
            capabilities != nil,
            token != nil,
            writerObservation != nil,
            readerObservation != nil,
            fenceReceiptDigest != nil,
            terminalOutcomeDigest != nil,
            sequence != nil,
            frame != nil,
            endOfStream != nil,
            historyMigrationReceipt != nil,
        ].filter { $0 }.count
        if failure != nil {
            guard payloadCount == 0 else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
            return
        }
        switch operation {
        case .activeSandboxGeneration:
            guard payloadCount == 1, sandboxGeneration != nil else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .migrateHistory:
            guard payloadCount == 1, historyMigrationReceipt != nil else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .reclaimGeneration:
            guard payloadCount == 0 else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .startWriter:
            guard
                payloadCount == 3,
                token?.isEmpty == false,
                capabilities != nil,
                sequence != nil
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .reconcileWriterOpen:
            try validateOpenObservation(reader: false, payloadCount: payloadCount)
        case .writeWriter, .flushWriter, .finishWriter,
            .reclaimTerminalEffect:
            guard payloadCount == 0 else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .reconcileWriter, .closeWriter:
            guard
                writerObservation != nil,
                payloadCount == (fenceReceiptDigest == nil ? 1 : 2)
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .fenceWriter:
            guard
                writerObservation == .writerFenced,
                fenceReceiptDigest != nil,
                payloadCount == 2
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .openReader:
            guard
                payloadCount == 3,
                token?.isEmpty == false,
                capabilities != nil,
                sequence != nil
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .reconcileReaderOpen:
            try validateOpenObservation(reader: true, payloadCount: payloadCount)
        case .nextReader:
            guard
                let endOfStream,
                payloadCount == (endOfStream ? 1 : 2),
                endOfStream ? frame == nil : frame?.isEmpty == false
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .cancelReader:
            guard payloadCount == 0 else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .reconcileReader, .closeReader:
            guard
                readerObservation != nil,
                payloadCount == (terminalOutcomeDigest == nil ? 1 : 2)
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        }
    }

    private func validateOpenObservation(
        reader: Bool,
        payloadCount: Int
    ) throws {
        guard let openObservation else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        switch openObservation {
        case .prepared:
            guard
                payloadCount == 4,
                token?.isEmpty == false,
                capabilities != nil,
                sequence != nil
            else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        case .absent, .conflict, .uncertain:
            guard payloadCount == 1 else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
        }
    }
}

public actor DockerPluginLifecycleServiceWireClientV1:
    DockerPluginLifecycleService
{
    private let expectedReadLogs: Bool
    private let transport: any DockerPluginLifecycleServiceWireTransportV1

    public init(
        expectedReadLogs: Bool,
        transport: any DockerPluginLifecycleServiceWireTransportV1
    ) {
        self.expectedReadLogs = expectedReadLogs
        self.transport = transport
    }

    public func activeSandboxGeneration() async throws -> UInt64 {
        let response = try await invoke(.generation())
        guard let generation = response.sandboxGeneration, generation > 0 else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        return generation
    }

    public func migrateHistory(
        _ request: LogDriverHistoryMigrationRequestV1
    ) async throws -> LogDriverHistoryMigrationReceiptV1 {
        let response = try await invoke(.migrateHistory(request))
        guard
            let receipt = response.historyMigrationReceipt,
            receipt.request == request
        else {
            throw LogDriverHistoryMigrationError.receiptMismatch
        }
        return receipt
    }

    public func reclaimGeneration(
        _ request: LogDriverProviderGenerationReclaimV1
    ) async throws {
        _ = try await invoke(.reclaimGeneration(request))
    }

    public func startWriter(
        _ open: DockerPluginWriterOpenRequest
    ) async throws -> DockerPluginServiceStartedWriter {
        do {
            let response = try await invoke(
                .startWriter(open, expectedReadLogs: expectedReadLogs)
            )
            return try startedWriter(request: open.request, response: response)
        } catch DockerPluginLifecycleServiceWireError.pluginRejected {
            throw DockerPluginProtocolError.endpointRejected(
                endpoint: .startLogging
            )
        }
    }

    public func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) async throws -> DockerPluginServiceWriterReconciliation {
        let response = try await invoke(.reconcileWriterOpen(request))
        guard let observation = response.openObservation else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        switch observation {
        case .absent:
            return .absent
        case .prepared:
            return .prepared(
                try startedWriter(request: request, response: response)
            )
        case .conflict:
            return .conflict
        case .uncertain:
            return .uncertain
        }
    }

    public func reconcileWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try await writerAcknowledgement(
            request,
            operation: .reconcileWriter
        )
    }

    public func fenceWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try await writerAcknowledgement(request, operation: .fenceWriter)
    }

    public func closeWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try await writerAcknowledgement(request, operation: .closeWriter)
    }

    public func openReader(
        _ open: DockerPluginReaderOpenRequest
    ) async throws -> DockerPluginServiceStartedReader {
        let response = try await invoke(.openReader(open))
        return try startedReader(request: open.request, response: response)
    }

    public func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginServiceReaderReconciliation {
        let response = try await invoke(.reconcileReaderOpen(request))
        guard let observation = response.openObservation else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        switch observation {
        case .absent:
            return .absent
        case .prepared:
            return .prepared(
                try startedReader(request: request, response: response)
            )
        case .conflict:
            return .conflict
        case .uncertain:
            return .uncertain
        }
    }

    public func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try await readerAcknowledgement(
            request,
            operation: .reconcileReader
        )
    }

    public func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try await readerAcknowledgement(request, operation: .closeReader)
    }

    public func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async throws {
        _ = try await invoke(.reclaim(request))
    }

    package func invoke(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        let response = try await transport.call(request)
        try response.validate(for: request.operation)
        if let failure = response.failure {
            throw Self.error(failure)
        }
        return response
    }

    private func startedWriter(
        request: LogDriverStartRequestV1,
        response: DockerPluginLifecycleServiceWireResponseV1
    ) throws -> DockerPluginServiceStartedWriter {
        guard
            let bytes = response.token,
            let capabilities = response.capabilities?.value,
            capabilities.readLogs == expectedReadLogs,
            let sequence = response.sequence,
            sequence > 0
        else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        let token = try LogDriverOpaqueEffectTokenV1(validating: bytes)
        return DockerPluginServiceStartedWriter(
            capabilities: capabilities,
            started: StartedLogDriverSessionV1(
                receipt: LogDriverStartReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                session: DockerPluginLifecycleServiceWriterV1(
                    sessionID: request.sessionID,
                    token: token,
                    nextSequence: sequence,
                    transport: transport
                )
            )
        )
    }

    private func startedReader(
        request: LogDriverReaderOpenRequestV1,
        response: DockerPluginLifecycleServiceWireResponseV1
    ) throws -> DockerPluginServiceStartedReader {
        guard
            let bytes = response.token,
            let capabilities = response.capabilities?.value,
            capabilities.readLogs,
            capabilities.readLogs == expectedReadLogs,
            let sequence = response.sequence,
            sequence > 0
        else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        let token = try LogDriverOpaqueEffectTokenV1(validating: bytes)
        let stream = DockerPluginLifecycleServiceResponseStreamV1(
            sessionID: request.readerSessionID,
            token: token,
            nextSequence: sequence,
            transport: transport
        )
        let processGeneration: UInt64?
        switch request.source {
        case .stoppedContainer:
            processGeneration = nil
        case .activeWriter(_, _, _, let generation, _):
            processGeneration = generation
        }
        let reader = try DockerPluginLogReader.attach(
            stream: stream,
            request: request.read,
            processGeneration: processGeneration,
            initialSequence: sequence
        )
        return DockerPluginServiceStartedReader(
            capabilities: capabilities,
            started: StartedLogDriverReaderV1(
                receipt: LogDriverReaderOpenReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                reader: reader
            )
        )
    }

    private func writerAcknowledgement(
        _ call: LogDriverSessionCallV1,
        operation: DockerPluginLifecycleServiceWireOperationV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        let response = try await invoke(.writerCall(operation, call: call))
        guard let observation = response.writerObservation else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        return try LogDriverSessionAcknowledgementV1(
            call: call,
            observation: observation,
            writerFenceReceiptDigest: response.fenceReceiptDigest
        )
    }

    private func readerAcknowledgement(
        _ call: LogDriverReaderCallV1,
        operation: DockerPluginLifecycleServiceWireOperationV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        let response = try await invoke(.readerCall(operation, call: call))
        guard let observation = response.readerObservation else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        return try LogDriverReaderAcknowledgementV1(
            call: call,
            observation: observation,
            terminalOutcomeDigest: response.terminalOutcomeDigest
        )
    }

    fileprivate static func error(
        _ failure: DockerPluginLifecycleServiceWireFailureV1
    ) -> DockerPluginLifecycleServiceWireError {
        switch failure {
        case .invalidRequest:
            return .invalidEnvelope
        case .generationMismatch:
            return .generationMismatch
        case .idempotencyConflict:
            return .idempotencyConflict
        case .invalidToken:
            return .invalidToken
        case .invalidFence:
            return .invalidFence
        case .capabilityMismatch:
            return .capabilityMismatch
        case .pluginRejected:
            return .pluginRejected
        case .unknownSession:
            return .unknownSession
        case .unavailable:
            return .unavailable
        case .internalFailure:
            return .internalFailure
        }
    }
}

private actor DockerPluginLifecycleServiceWriterV1: ContainerLogDriverSession {
    private let sessionID: String
    private let token: LogDriverOpaqueEffectTokenV1
    private let transport: any DockerPluginLifecycleServiceWireTransportV1
    private var nextSequence: UInt64
    private var closed = false
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    init(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1,
        nextSequence: UInt64,
        transport: any DockerPluginLifecycleServiceWireTransportV1
    ) {
        self.sessionID = sessionID
        self.token = token
        self.nextSequence = nextSequence
        self.transport = transport
    }

    func write(_ record: ContainerLogRecordV2) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard !closed else {
            throw DockerPluginProtocolError.writerUnavailable
        }
        let frame = try DockerPluginLogEntryCodec.encodeFrame(
            DockerPluginLogEntry(record)
        )
        do {
            try await withTaskCancellationHandler {
                _ = try await invoke(
                    .writeWriter(
                        sessionID: sessionID,
                        token: token,
                        sequence: nextSequence,
                        frame: frame
                    )
                )
            } onCancel: {
                Task { await self.fence() }
            }
        } catch is CancellationError {
            await fenceWhileOperationActive()
            throw CancellationError()
        }
        guard nextSequence < UInt64.max else {
            await fenceWhileOperationActive()
            throw DockerPluginProtocolError.writerUnavailable
        }
        nextSequence += 1
    }

    func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard !closed else {
            throw DockerPluginProtocolError.writerUnavailable
        }
        guard ContinuousClock().now < deadline else {
            throw DockerPluginProtocolError.deadlineExceeded
        }
        _ = try await invoke(
            .flushWriter(sessionID: sessionID, token: token)
        )
    }

    func close(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard !closed else {
            return
        }
        guard ContinuousClock().now < deadline else {
            throw DockerPluginProtocolError.deadlineExceeded
        }
        _ = try await invoke(
            .finishWriter(
                sessionID: sessionID,
                token: token,
                fenced: false
            )
        )
        closed = true
    }

    private func fence() async {
        await acquireOperation()
        defer { releaseOperation() }
        await fenceWhileOperationActive()
    }

    private func fenceWhileOperationActive() async {
        guard !closed else {
            return
        }
        _ = try? await invoke(
            .finishWriter(
                sessionID: sessionID,
                token: token,
                fenced: true
            )
        )
        closed = true
    }

    private func invoke(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        let response = try await transport.call(request)
        try response.validate(for: request.operation)
        if let failure = response.failure {
            switch failure {
            case .invalidToken:
                throw DockerPluginProtocolError.invalidEffectToken
            case .invalidFence:
                throw DockerPluginProtocolError.invalidSessionFence
            case .unavailable:
                throw DockerPluginProtocolError.writerUnavailable
            default:
                throw DockerPluginLifecycleServiceWireClientV1.error(failure)
            }
        }
        return response
    }

    private func acquireOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationActive = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}

private actor DockerPluginLifecycleServiceResponseStreamV1:
    DockerPluginResponseStream
{
    private let sessionID: String
    private let token: LogDriverOpaqueEffectTokenV1
    private let transport: any DockerPluginLifecycleServiceWireTransportV1
    private var nextSequence: UInt64
    private var pending = Data()
    private var ended = false
    private var closed = false

    init(
        sessionID: String,
        token: LogDriverOpaqueEffectTokenV1,
        nextSequence: UInt64,
        transport: any DockerPluginLifecycleServiceWireTransportV1
    ) {
        self.sessionID = sessionID
        self.token = token
        self.nextSequence = nextSequence
        self.transport = transport
    }

    func nextChunk(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        guard !closed else {
            return nil
        }
        if !pending.isEmpty {
            return takePending(maximumBytes: maximumBytes)
        }
        guard !ended else {
            return nil
        }
        let request = DockerPluginLifecycleServiceWireRequestV1.nextReader(
            sessionID: sessionID,
            token: token,
            sequence: nextSequence
        )
        let response = try await transport.call(request)
        try response.validate(for: request.operation)
        if let failure = response.failure {
            closed = true
            switch failure {
            case .invalidToken:
                throw DockerPluginProtocolError.invalidEffectToken
            case .unavailable:
                throw DockerPluginProtocolError.writerUnavailable
            default:
                throw DockerPluginLifecycleServiceWireError.internalFailure
            }
        }
        guard let endOfStream = response.endOfStream else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        if endOfStream {
            guard response.frame == nil || response.frame?.isEmpty == true else {
                throw DockerPluginLifecycleServiceWireError.invalidEnvelope
            }
            ended = true
            return nil
        }
        guard let frame = response.frame, !frame.isEmpty else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        let increment = nextSequence.addingReportingOverflow(1)
        guard !increment.overflow else {
            throw DockerPluginProtocolError.partialOrdinalOutOfRange
        }
        nextSequence = increment.partialValue
        pending = frame
        return takePending(maximumBytes: maximumBytes)
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        let request = DockerPluginLifecycleServiceWireRequestV1.cancelReader(
            sessionID: sessionID,
            token: token
        )
        _ = try? await transport.call(request)
        pending.removeAll(keepingCapacity: false)
    }

    private func takePending(maximumBytes: Int) -> Data {
        let count = min(maximumBytes, pending.count)
        let chunk = Data(pending.prefix(count))
        pending.removeFirst(count)
        return chunk
    }
}
