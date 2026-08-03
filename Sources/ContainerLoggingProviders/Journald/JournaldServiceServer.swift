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

/// Linux-local effects consumed by the journald wire server.
///
/// Every method must also be idempotent by its complete logical request. The
/// replay cache absorbs ordinary response loss, while backend idempotency keeps
/// an evicted or post-restart retry from creating a second journal effect.
public protocol JournaldServiceBackendV1: Sendable {
    func activeSandboxGeneration() async throws -> UInt64
    func openWriter(_ request: JournaldWriterOpenRequest) async throws
    func write(sessionID: String, entry: JournaldEntry) async throws
    func flushWriter(
        sessionID: String,
        timeoutNanoseconds: UInt64
    ) async throws
    func closeWriter(
        sessionID: String,
        fenced: Bool,
        timeoutNanoseconds: UInt64
    ) async throws
    func openReader(_ request: LogDriverReaderOpenRequestV1) async throws -> UInt64
    func nextReader(
        sessionID: String,
        sequence: UInt64
    ) async throws -> ContainerLogReaderEventV1
    func cancelReader(sessionID: String) async throws
}

public struct JournaldServiceReplayLimitsV1: Equatable, Sendable {
    public static let defaultMaximumCompletedOperations = 4_096
    public static let defaultMaximumEncodedBytes = 16 * 1_024 * 1_024
    public static let standard = Self(
        validatedMaximumCompletedOperations: defaultMaximumCompletedOperations,
        maximumEncodedBytes: defaultMaximumEncodedBytes
    )

    public let maximumCompletedOperations: Int
    public let maximumEncodedBytes: Int

    public init(
        maximumCompletedOperations: Int = Self.defaultMaximumCompletedOperations,
        maximumEncodedBytes: Int = Self.defaultMaximumEncodedBytes
    ) throws {
        guard
            maximumCompletedOperations > 0,
            maximumEncodedBytes >= JournaldServiceFrameCodecV1.maximumFrameBytes * 2
        else {
            throw JournaldServiceWireError.invalidReplayLimits
        }
        self.maximumCompletedOperations = maximumCompletedOperations
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    private init(
        validatedMaximumCompletedOperations: Int,
        maximumEncodedBytes: Int
    ) {
        self.maximumCompletedOperations = validatedMaximumCompletedOperations
        self.maximumEncodedBytes = maximumEncodedBytes
    }
}

public struct JournaldServiceReplaySnapshotV1: Equatable, Sendable {
    public let inFlightOperations: Int
    public let joinedWaiters: Int
    public let completedOperations: Int
    public let completedEncodedBytes: Int

    public init(
        inFlightOperations: Int,
        joinedWaiters: Int,
        completedOperations: Int,
        completedEncodedBytes: Int
    ) {
        self.inFlightOperations = inFlightOperations
        self.joinedWaiters = joinedWaiters
        self.completedOperations = completedOperations
        self.completedEncodedBytes = completedEncodedBytes
    }
}

/// Exact-once protocol engine shared by the production listener and loopback
/// tests. Calls with one operation ID are either joined while in flight or
/// replayed from a bounded completed-outcome cache. Reusing an operation ID for
/// different bytes is rejected before reaching the backend.
public actor JournaldServiceWireHandlerV1 {
    private struct CompletedOperation: Sendable {
        let request: JournaldServiceWireRequestV1
        let response: JournaldServiceWireResponseV1
        let encodedBytes: Int
    }

    private struct InFlightOperation {
        let request: JournaldServiceWireRequestV1
        var waiters: [CheckedContinuation<JournaldServiceWireResponseV1, Never>]
    }

    private enum OperationState {
        case inFlight(InFlightOperation)
        case completed(CompletedOperation)
    }

    private let backend: any JournaldServiceBackendV1
    private let limits: JournaldServiceReplayLimitsV1
    private var operations = [String: OperationState]()
    private var completedOrder = [String]()
    private var completedEncodedBytes = 0

    public init(
        backend: any JournaldServiceBackendV1,
        limits: JournaldServiceReplayLimitsV1 = .standard
    ) {
        self.backend = backend
        self.limits = limits
    }

    public func handle(
        _ request: JournaldServiceWireRequestV1
    ) async -> JournaldServiceWireResponseV1 {
        if let state = operations[request.operationID] {
            switch state {
            case .completed(let completed):
                guard completed.request == request else {
                    return conflict(for: request.operationID)
                }
                return completed.response
            case .inFlight(var inFlight):
                guard inFlight.request == request else {
                    return conflict(for: request.operationID)
                }
                return await withCheckedContinuation { continuation in
                    inFlight.waiters.append(continuation)
                    operations[request.operationID] = .inFlight(inFlight)
                }
            }
        }

        operations[request.operationID] = .inFlight(
            InFlightOperation(request: request, waiters: [])
        )
        let response = await execute(request)
        complete(request: request, response: response)
        return response
    }

    public func replaySnapshot() -> JournaldServiceReplaySnapshotV1 {
        var inFlight = 0
        var joinedWaiters = 0
        var completed = 0
        for state in operations.values {
            switch state {
            case .inFlight(let operation):
                inFlight += 1
                joinedWaiters += operation.waiters.count
            case .completed:
                completed += 1
            }
        }
        return JournaldServiceReplaySnapshotV1(
            inFlightOperations: inFlight,
            joinedWaiters: joinedWaiters,
            completedOperations: completed,
            completedEncodedBytes: completedEncodedBytes
        )
    }

    private func execute(
        _ request: JournaldServiceWireRequestV1
    ) async -> JournaldServiceWireResponseV1 {
        do {
            switch request.operation {
            case .activeSandboxGeneration:
                let generation = try await backend.activeSandboxGeneration()
                guard generation > 0 else {
                    return failure(
                        operationID: request.operationID,
                        failure: .internalFailure
                    )
                }
                return try .generation(
                    operationID: request.operationID,
                    sandboxGeneration: generation
                )
            case .openWriter:
                let value = try required(request.writerOpen).value()
                try await backend.openWriter(value)
                return try .acknowledgement(operationID: request.operationID)
            case .write:
                try await backend.write(
                    sessionID: try required(request.sessionID),
                    entry: try required(request.entry).entry()
                )
                return try .acknowledgement(operationID: request.operationID)
            case .flushWriter:
                try await backend.flushWriter(
                    sessionID: try required(request.sessionID),
                    timeoutNanoseconds: try required(
                        request.timeoutNanoseconds
                    )
                )
                return try .acknowledgement(operationID: request.operationID)
            case .closeWriter:
                try await backend.closeWriter(
                    sessionID: try required(request.sessionID),
                    fenced: try required(request.fenced),
                    timeoutNanoseconds: try required(
                        request.timeoutNanoseconds
                    )
                )
                return try .acknowledgement(operationID: request.operationID)
            case .openReader:
                let sequence = try await backend.openReader(
                    try required(request.readerOpen)
                )
                return try .readerOpened(
                    operationID: request.operationID,
                    readerSequence: sequence
                )
            case .nextReader:
                let event = try await backend.nextReader(
                    sessionID: try required(request.sessionID),
                    sequence: try required(request.readerSequence)
                )
                switch event {
                case .record(let record):
                    return try .reader(
                        operationID: request.operationID,
                        event: .record(ContainerLogReadRecordWireV1(record))
                    )
                case .endOfStream:
                    return try .reader(
                        operationID: request.operationID,
                        event: .endOfStream
                    )
                }
            case .cancelReader:
                try await backend.cancelReader(
                    sessionID: try required(request.sessionID)
                )
                return try .acknowledgement(operationID: request.operationID)
            }
        } catch is CancellationError {
            return failure(
                operationID: request.operationID,
                failure: .unavailable
            )
        } catch let error as JournaldProviderError {
            return failure(
                operationID: request.operationID,
                failure: Self.failure(for: error)
            )
        } catch is JournaldServiceWireError {
            return failure(
                operationID: request.operationID,
                failure: .invalidRequest
            )
        } catch {
            return failure(
                operationID: request.operationID,
                failure: .internalFailure
            )
        }
    }

    private func complete(
        request: JournaldServiceWireRequestV1,
        response: JournaldServiceWireResponseV1
    ) {
        guard case .inFlight(let inFlight) = operations[request.operationID] else {
            return
        }
        let encodedBytes = Self.encodedBytes(request, response)
        operations[request.operationID] = .completed(
            CompletedOperation(
                request: request,
                response: response,
                encodedBytes: encodedBytes
            )
        )
        completedOrder.append(request.operationID)
        let (newEncodedBytes, overflow) =
            completedEncodedBytes
            .addingReportingOverflow(encodedBytes)
        completedEncodedBytes = overflow ? Int.max : newEncodedBytes
        evictCompletedOperationsIfNeeded()
        for waiter in inFlight.waiters {
            waiter.resume(returning: response)
        }
    }

    private func evictCompletedOperationsIfNeeded() {
        while completedOrder.count > limits.maximumCompletedOperations
            || completedEncodedBytes > limits.maximumEncodedBytes
        {
            let operationID = completedOrder.removeFirst()
            guard
                case .completed(let completed) = operations.removeValue(
                    forKey: operationID
                )
            else {
                continue
            }
            completedEncodedBytes -= completed.encodedBytes
        }
        if completedOrder.isEmpty {
            completedEncodedBytes = 0
        }
    }

    private func conflict(
        for operationID: String
    ) -> JournaldServiceWireResponseV1 {
        failure(operationID: operationID, failure: .idempotencyConflict)
    }

    private func failure(
        operationID: String,
        failure: JournaldServiceWireFailureV1
    ) -> JournaldServiceWireResponseV1 {
        do {
            return try .failed(operationID: operationID, failure: failure)
        } catch {
            preconditionFailure("validated request supplied invalid operation ID")
        }
    }

    private static func encodedBytes(
        _ request: JournaldServiceWireRequestV1,
        _ response: JournaldServiceWireResponseV1
    ) -> Int {
        let encoder = JSONEncoder()
        guard
            let requestBytes = try? encoder.encode(request).count,
            let responseBytes = try? encoder.encode(response).count
        else {
            return Int.max
        }
        let (total, overflow) = requestBytes.addingReportingOverflow(
            responseBytes
        )
        return overflow ? Int.max : total
    }

    private static func failure(
        for error: JournaldProviderError
    ) -> JournaldServiceWireFailureV1 {
        switch error {
        case .invalidSessionFence:
            return .generationMismatch
        case .idempotencyConflict:
            return .idempotencyConflict
        case .unknownSession:
            return .unknownSession
        case .deadlineExceeded:
            return .deadlineExceeded
        case .transportClosed:
            return .unavailable
        case .invalidJournalEntry, .unsupportedJournalPriority,
            .invalidContainerIdentity, .invalidProviderIdentity, .invalidEffectToken,
            .unknownOption, .invalidMetadataRegularExpression, .invalidTagTemplate,
            .tagExceedsUTF8Limit:
            return .invalidRequest
        }
    }

    private func required<Value>(_ value: Value?) throws -> Value {
        guard let value else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        return value
    }
}

/// Serves one persistent, already-authenticated vsock connection until the
/// peer closes it. The shared-sandbox runtime owns authentication and exact
/// generation fencing before this layer receives the file descriptor.
public struct JournaldServiceWireConnectionV1: Sendable {
    private let handler: JournaldServiceWireHandlerV1

    public init(handler: JournaldServiceWireHandlerV1) {
        self.handler = handler
    }

    public func serve(_ handle: FileHandle) async throws {
        try Self.suppressBrokenPipeSignal(on: handle)
        defer { Self.close(handle) }
        do {
            try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    let request = try await Task.detached {
                        try JournaldServiceFrameCodecV1.read(
                            JournaldServiceWireRequestV1.self,
                            from: handle
                        )
                    }.value
                    let response = await handler.handle(request)
                    try await Task.detached {
                        try JournaldServiceFrameCodecV1.write(
                            response,
                            to: handle
                        )
                    }.value
                }
            } onCancel: {
                Self.close(handle)
            }
        } catch JournaldServiceWireError.disconnected {
            // An orderly peer close ends only this connection.
        } catch is POSIXError {
            // A peer may disappear after its request but before the response.
            // The retained handler outcome services its exact reconnect replay.
        }
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

    private static func close(_ handle: FileHandle) {
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
    }
}
