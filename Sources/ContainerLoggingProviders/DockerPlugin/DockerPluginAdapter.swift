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
import Foundation

/// A validated FIFO name inside Docker's protected Linux logging namespace.
/// The host filesystem and arbitrary paths are not representable here.
public struct DockerPluginFIFOReference: Equatable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let protectedPrefix = "/run/docker/logging/"
    public static let maximumComponentUTF8Bytes = 128

    package let pluginPath: String

    public init(validatingPluginPath pluginPath: String) throws {
        guard pluginPath.hasPrefix(Self.protectedPrefix) else {
            throw DockerPluginProtocolError.invalidFIFOReference
        }
        let component = pluginPath.dropFirst(Self.protectedPrefix.count)
        guard
            !component.isEmpty,
            component != ".",
            component != "..",
            component.utf8.count <= Self.maximumComponentUTF8Bytes,
            component.utf8.allSatisfy(Self.isAllowedComponentByte)
        else {
            throw DockerPluginProtocolError.invalidFIFOReference
        }
        self.pluginPath = pluginPath
    }

    public var description: String {
        "DockerPluginFIFOReference(<redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["pluginPath": "<redacted>"], displayStyle: .struct)
    }

    private static func isAllowedComponentByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}

/// Service-plane FIFO opened `O_RDWR | O_CREAT | O_NONBLOCK` with mode `0700`
/// inside the Engine Linux sandbox. Implementations must await each complete
/// frame and never buffer an unbounded producer queue.
public protocol DockerPluginFIFO: Sendable {
    var reference: DockerPluginFIFOReference { get }

    func writeFrame(_ frame: Data) async throws

    /// Graceful teardown after `StopLogging` has acknowledged its drain. This
    /// and `revokeAndRemove` must be mutually safe and idempotent; a concurrent
    /// revoke supersedes graceful teardown.
    func closeAndRemove() async

    /// Irrevocably revokes writes before forced or cancellation cleanup.
    /// This must interrupt an outstanding `writeFrame` without waiting behind
    /// that write, and is idempotent across concurrent cleanup callers.
    func revokeAndRemove() async
}

/// Creates a unique FIFO in the already-selected protected provider namespace.
public protocol DockerPluginFIFOFactory: Sendable {
    func createFIFO(
        sessionID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginFIFO
}

/// One acquired, authenticated plugin generation.
public protocol DockerPluginProviderLease: Sendable {
    var providerGeneration: UInt64 { get }
    var transport: any DockerPluginRPCTransport { get }

    /// Idempotently drops the provider acquisition without exposing its token.
    func release() async
}

public enum DockerPluginSessionState: Equatable, Sendable {
    case active
    case stopOutcomeUncertain
    case writerFencing
    case writerFenced
    case closing
    case closed
}

public struct DockerPluginStartedSession: Sendable {
    public let capabilities: DockerPluginCapabilities
    public let readRouting: DockerPluginReadRouting
    public let session: DockerPluginDriverSession

    package init(
        capabilities: DockerPluginCapabilities,
        readRouting: DockerPluginReadRouting,
        session: DockerPluginDriverSession
    ) {
        self.capabilities = capabilities
        self.readRouting = readRouting
        self.session = session
    }
}

/// One acquired capability/FIFO tuple whose `StartLogging` outcome can be
/// reconciled without allocating a second FIFO or provider lease.
///
/// The higher-level provider persists the request identity and opaque receipt
/// before calling ``start(info:deadline:)``. If the response is lost, it keeps
/// this object and replays the exact call against the same FIFO. Standalone
/// callers can use ``abandon()`` to perform bounded best-effort stop followed
/// by authoritative local revocation.
public actor DockerPluginPreparedWriter: Sendable {
    public let capabilities: DockerPluginCapabilities
    public let readRouting: DockerPluginReadRouting

    private let client: DockerPluginProtocolClient
    private let lease: any DockerPluginProviderLease
    private let fifo: any DockerPluginFIFO
    private var started: DockerPluginDriverSession?
    private var abandoned = false

    fileprivate init(
        capabilities: DockerPluginCapabilities,
        client: DockerPluginProtocolClient,
        lease: any DockerPluginProviderLease,
        fifo: any DockerPluginFIFO
    ) {
        self.capabilities = capabilities
        self.readRouting = DockerPluginReadRouting(capabilities: capabilities)
        self.client = client
        self.lease = lease
        self.fifo = fifo
    }

    public func start(
        info: DockerPluginInfo,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DockerPluginStartedSession {
        guard !abandoned else {
            throw DockerPluginProtocolError.writerUnavailable
        }
        if let started {
            return DockerPluginStartedSession(
                capabilities: capabilities,
                readRouting: readRouting,
                session: started
            )
        }
        try await client.startLogging(
            fifo: fifo.reference,
            info: info,
            deadline: deadline
        )
        let session = DockerPluginDriverSession(
            client: client,
            lease: lease,
            fifo: fifo
        )
        started = session
        return DockerPluginStartedSession(
            capabilities: capabilities,
            readRouting: readRouting,
            session: session
        )
    }

    public func abandon() async {
        guard !abandoned, started == nil else {
            return
        }
        abandoned = true
        let cleanup = Task.detached { [client, fifo] in
            try? await client.stopLogging(
                fifo: fifo.reference,
                deadline: ContinuousClock().now + .seconds(5)
            )
        }
        _ = await cleanup.value
        await fifo.revokeAndRemove()
        await lease.release()
    }
}

/// Lifecycle-safe writer for one Docker logging-plugin FIFO.
///
/// Start order is capability handshake, FIFO creation, then `StartLogging`.
/// Graceful close calls `StopLogging` before FIFO teardown and lease release.
/// Cancellation and authoritative fencing revoke the FIFO first so a stale
/// generation can never resume writes.
public actor DockerPluginDriverSession: ContainerLogDriverSession {
    public static let maximumOperationWaiters = 64

    private enum StopAttemptResult: Sendable {
        case success
        case cancelled
        case failure(DockerPluginProtocolError)

        func get() throws {
            switch self {
            case .success:
                return
            case .cancelled:
                throw CancellationError()
            case .failure(let error):
                throw error
            }
        }
    }

    private let client: DockerPluginProtocolClient
    private let lease: any DockerPluginProviderLease
    private let fifo: any DockerPluginFIFO
    private var state: DockerPluginSessionState = .active
    private var fenceInProgress = false
    private var fenceComplete = false
    private var fenceWaiters = [CheckedContinuation<Void, Never>]()
    private var gracefulCloseWaiters = [CheckedContinuation<Void, Never>]()
    private var stopSucceeded = false
    private var stopInProgress = false
    private var stopWaiters = [CheckedContinuation<StopAttemptResult, Never>]()
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    fileprivate init(
        client: DockerPluginProtocolClient,
        lease: any DockerPluginProviderLease,
        fifo: any DockerPluginFIFO
    ) {
        self.client = client
        self.lease = lease
        self.fifo = fifo
    }

    public static func start(
        sessionID: String,
        providerGeneration: UInt64,
        info: DockerPluginInfo,
        lease: any DockerPluginProviderLease,
        fifoFactory: any DockerPluginFIFOFactory,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DockerPluginStartedSession {
        let prepared = try await prepare(
            sessionID: sessionID,
            providerGeneration: providerGeneration,
            lease: lease,
            fifoFactory: fifoFactory,
            deadline: deadline
        )
        do {
            return try await prepared.start(info: info, deadline: deadline)
        } catch {
            await prepared.abandon()
            throw error
        }
    }

    /// Acquires capabilities and the exact FIFO while deliberately leaving the
    /// effect unstarted. A provider can persist its claim before the first
    /// `StartLogging` call and retain this object when the response is
    /// uncertain.
    public static func prepare(
        sessionID: String,
        providerGeneration: UInt64,
        lease: any DockerPluginProviderLease,
        fifoFactory: any DockerPluginFIFOFactory,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DockerPluginPreparedWriter {
        guard
            !sessionID.isEmpty,
            providerGeneration > 0,
            lease.providerGeneration == providerGeneration
        else {
            await lease.release()
            throw DockerPluginProtocolError.providerGenerationMismatch
        }
        let client = DockerPluginProtocolClient(transport: lease.transport)
        let capabilities: DockerPluginCapabilities
        do {
            capabilities = try await client.capabilities(deadline: deadline)
        } catch is CancellationError {
            await lease.release()
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                await lease.release()
                throw CancellationError()
            }
            // Moby treats a failed optional capability handshake as the legacy
            // non-readable capability and continues to StartLogging.
            capabilities = DockerPluginCapabilities(readLogs: false)
        }

        let fifo: any DockerPluginFIFO
        do {
            try Task.checkCancellation()
            fifo = try await fifoFactory.createFIFO(
                sessionID: sessionID,
                providerGeneration: providerGeneration
            )
        } catch is CancellationError {
            await lease.release()
            throw CancellationError()
        } catch {
            await lease.release()
            throw DockerPluginProtocolError.invalidFIFOReference
        }
        if Task.isCancelled {
            await fifo.revokeAndRemove()
            await lease.release()
            throw CancellationError()
        }

        return DockerPluginPreparedWriter(
            capabilities: capabilities,
            client: client,
            lease: lease,
            fifo: fifo
        )
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            throw state == .stopOutcomeUncertain
                ? DockerPluginProtocolError.stopOutcomeUncertain
                : DockerPluginProtocolError.writerUnavailable
        }

        do {
            let entry = try DockerPluginLogEntry(record)
            let frame = try DockerPluginLogEntryCodec.encodeFrame(entry)
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await fifo.writeFrame(frame)
            } onCancel: {
                Task {
                    await self.fenceImmediately()
                }
            }
            guard state == .active else {
                throw DockerPluginProtocolError.writerUnavailable
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            await fenceImmediately()
            throw CancellationError()
        } catch let error as DockerPluginProtocolError {
            if Task.isCancelled {
                await fenceImmediately()
                throw CancellationError()
            }
            throw error
        } catch {
            if Task.isCancelled {
                await fenceImmediately()
                throw CancellationError()
            }
            throw DockerPluginProtocolError.fifoFailure
        }
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        guard ContinuousClock().now < deadline else {
            throw DockerPluginProtocolError.deadlineExceeded
        }
        guard state == .active else {
            throw state == .stopOutcomeUncertain
                ? DockerPluginProtocolError.stopOutcomeUncertain
                : DockerPluginProtocolError.writerUnavailable
        }
        // FIFO writes are individually awaited. Owning the operation gate is
        // therefore the complete writer-side flush barrier.
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        switch state {
        case .closed:
            return
        case .writerFencing, .writerFenced:
            await fenceImmediately()
            return
        case .closing:
            await waitForGracefulClose()
            return
        case .active, .stopOutcomeUncertain:
            break
        }

        guard ContinuousClock().now < deadline else {
            throw DockerPluginProtocolError.deadlineExceeded
        }

        state = .stopOutcomeUncertain
        do {
            try await stopLogging(deadline: deadline)
        } catch {
            if state == .writerFencing || state == .writerFenced {
                await fenceImmediately()
                return
            }
            throw error
        }
        guard state == .stopOutcomeUncertain else {
            if state == .writerFencing || state == .writerFenced {
                await fenceImmediately()
            }
            return
        }
        state = .closing
        await fifo.closeAndRemove()
        await lease.release()
        state = .closed
        resumeGracefulCloseWaiters()
    }

    /// Irrevocably fences local writes, then performs best-effort remote stop.
    public func fence() async {
        await fenceImmediately()
    }

    public func currentState() -> DockerPluginSessionState {
        state
    }

    private func fenceImmediately() async {
        guard state != .closed, !fenceComplete else {
            return
        }
        if state == .closing {
            await waitForGracefulClose()
            return
        }
        if fenceInProgress {
            await withCheckedContinuation { continuation in
                fenceWaiters.append(continuation)
            }
            return
        }
        fenceInProgress = true
        state = .writerFencing
        await fifo.revokeAndRemove()
        state = .writerFenced
        try? await stopLogging(deadline: ContinuousClock().now + .seconds(5))
        await lease.release()
        fenceComplete = true
        fenceInProgress = false
        let waiters = fenceWaiters
        fenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func stopLogging(deadline: ContinuousClock.Instant) async throws {
        if stopSucceeded {
            return
        }
        if stopInProgress {
            let result = await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            try result.get()
            return
        }

        stopInProgress = true
        let result: StopAttemptResult
        do {
            try await client.stopLogging(fifo: fifo.reference, deadline: deadline)
            result = .success
        } catch is CancellationError {
            result = .cancelled
        } catch let error as DockerPluginProtocolError {
            result = .failure(error)
        } catch {
            result = .failure(.transportFailure(endpoint: .stopLogging))
        }
        if case .success = result {
            stopSucceeded = true
        }
        stopInProgress = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        try result.get()
    }

    private func waitForGracefulClose() async {
        guard state == .closing else {
            return
        }
        await withCheckedContinuation { continuation in
            gracefulCloseWaiters.append(continuation)
        }
    }

    private func resumeGracefulCloseWaiters() {
        let waiters = gracefulCloseWaiters
        gracefulCloseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func acquireOperation() async throws {
        if !operationActive {
            operationActive = true
            return
        }
        guard operationWaiters.count < Self.maximumOperationWaiters else {
            throw DockerPluginProtocolError.operationQueueFull(
                maximumWaiters: Self.maximumOperationWaiters
            )
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

/// Pull-based adapter for the optional `LogDriver.ReadLogs` stream.
public actor DockerPluginLogReader: ContainerLogReader {
    private enum FilteredEntry {
        case record(ContainerLogReadRecordV1)
        case skip
        case endOfStream
    }

    private let stream: any DockerPluginResponseStream
    private let request: ContainerLogReadRequest
    private let processGeneration: UInt64?
    private var decoder = DockerPluginFrameDecoder()
    private var pending = [DockerPluginLogEntry]()
    private var nextSequence: UInt64 = 1
    private var ended = false
    private var streamClosed = false
    private var closeInProgress = false
    private var closeWaiters = [CheckedContinuation<Void, Never>]()
    private var readInProgress = false
    private var explicitlyCancelled = false
    private var sinceGate: Date?

    private init(
        stream: any DockerPluginResponseStream,
        request: ContainerLogReadRequest,
        processGeneration: UInt64?,
        initialSequence: UInt64 = 1
    ) {
        self.stream = stream
        self.request = request
        self.processGeneration = processGeneration
        self.nextSequence = initialSequence
        sinceGate = request.since
    }

    public static func open(
        client: DockerPluginProtocolClient,
        capabilities: DockerPluginCapabilities,
        info: DockerPluginInfo,
        request: ContainerLogReadRequest,
        processGeneration: UInt64? = nil
    ) async throws -> DockerPluginLogReader {
        guard capabilities.readLogs else {
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
        }
        let stream = try await client.readLogs(
            info: info,
            configuration: DockerPluginReadConfiguration(request)
        )
        if Task.isCancelled {
            await stream.close()
            throw CancellationError()
        }
        return DockerPluginLogReader(
            stream: stream,
            request: request,
            processGeneration: processGeneration
        )
    }

    /// Attaches the standard Docker frame/filter adapter to an already-opened
    /// service-owned `ReadLogs` stream. The service has durably claimed the
    /// reader before returning this stream, so this path must not issue a
    /// second plugin request.
    public static func attach(
        stream: any DockerPluginResponseStream,
        request: ContainerLogReadRequest,
        processGeneration: UInt64? = nil,
        initialSequence: UInt64 = 1
    ) throws -> DockerPluginLogReader {
        guard initialSequence > 0 else {
            throw DockerPluginProtocolError.partialOrdinalOutOfRange
        }
        let reader = DockerPluginLogReader(
            stream: stream,
            request: request,
            processGeneration: processGeneration,
            initialSequence: initialSequence
        )
        return reader
    }

    public func next() async throws -> ContainerLogReaderEventV1 {
        guard !readInProgress else {
            throw ContainerLogReaderError.concurrentReadNotSupported
        }
        readInProgress = true
        defer { readInProgress = false }
        return try await withTaskCancellationHandler {
            try await nextWhileHoldingOperation()
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    public func cancel() async {
        explicitlyCancelled = true
        await closeImmediately()
    }

    public func close() async {
        await closeImmediately()
    }

    private func nextWhileHoldingOperation() async throws -> ContainerLogReaderEventV1 {
        guard !ended else {
            throw ContainerLogReaderError.alreadyEnded
        }

        do {
            while true {
                while !pending.isEmpty {
                    let entry = pending.removeFirst()
                    switch try filter(entry) {
                    case .record(let record):
                        return .record(record)
                    case .skip:
                        continue
                    case .endOfStream:
                        await closeImmediately()
                        return .endOfStream
                    }
                }

                try Task.checkCancellation()
                let nextChunk = try await stream.nextChunk(
                    maximumBytes: DockerPluginProtocolClient.maximumStreamChunkBytes
                )
                try Task.checkCancellation()
                guard !ended else {
                    if explicitlyCancelled {
                        throw ContainerLogReaderError.cancelled
                    }
                    throw ContainerLogReaderError.alreadyEnded
                }
                guard let chunk = nextChunk else {
                    try decoder.finish()
                    await closeImmediately()
                    return .endOfStream
                }
                guard chunk.count <= DockerPluginProtocolClient.maximumStreamChunkBytes else {
                    throw DockerPluginProtocolError.frameTooLarge(
                        maximumBytes: DockerPluginProtocolClient.maximumStreamChunkBytes
                    )
                }
                pending.append(contentsOf: try decoder.append(chunk))
            }
        } catch is CancellationError {
            await closeImmediately()
            if explicitlyCancelled, !Task.isCancelled {
                throw ContainerLogReaderError.cancelled
            }
            throw CancellationError()
        } catch let error as DockerPluginProtocolError {
            if Task.isCancelled {
                await closeImmediately()
                throw CancellationError()
            }
            if explicitlyCancelled {
                throw ContainerLogReaderError.cancelled
            }
            await closeImmediately()
            throw error
        } catch {
            if Task.isCancelled {
                await closeImmediately()
                throw CancellationError()
            }
            if explicitlyCancelled {
                throw ContainerLogReaderError.cancelled
            }
            if ended {
                throw ContainerLogReaderError.alreadyEnded
            }
            await closeImmediately()
            throw DockerPluginProtocolError.transportFailure(endpoint: .readLogs)
        }
    }

    private func closeImmediately() async {
        ended = true
        if streamClosed {
            return
        }
        if closeInProgress {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
            return
        }
        closeInProgress = true
        await stream.close()
        streamClosed = true
        closeInProgress = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func filter(_ entry: DockerPluginLogEntry) throws -> FilteredEntry {
        let timestamp = try Self.timestamp(entry.timeNano)
        if let sinceGate {
            guard timestamp >= (try Self.timestamp(sinceGate)) else {
                return .skip
            }
            self.sinceGate = nil
        }
        if let until = request.until, timestamp > (try Self.timestamp(until)) {
            return .endOfStream
        }

        let stream: ContainerLogStream
        switch entry.source {
        case ContainerLogStream.stdout.rawValue:
            guard request.stdout else { return .skip }
            stream = .stdout
        case ContainerLogStream.stderr.rawValue:
            guard request.stderr else { return .skip }
            stream = .stderr
        default:
            throw DockerPluginProtocolError.invalidStream
        }
        let record = try ContainerLogReadRecordV1(
            stream: stream,
            timestamp: timestamp,
            data: entry.line,
            sequence: nextSequence,
            processGeneration: processGeneration
        )
        nextSequence += 1
        return .record(record)
    }

    private static func timestamp(_ nanosecondsSinceEpoch: Int64) throws -> ContainerLogTimestamp {
        var seconds = nanosecondsSinceEpoch / 1_000_000_000
        var nanoseconds = nanosecondsSinceEpoch % 1_000_000_000
        if nanoseconds < 0 {
            seconds -= 1
            nanoseconds += 1_000_000_000
        }
        return try ContainerLogTimestamp(
            secondsSinceUnixEpoch: seconds,
            nanoseconds: UInt32(nanoseconds)
        )
    }

    private static func timestamp(_ date: Date) throws -> ContainerLogTimestamp {
        let interval = date.timeIntervalSince1970
        guard interval >= Double(Int64.min), interval < Double(Int64.max) else {
            throw DockerPluginProtocolError.timestampOutOfRange
        }
        var seconds = Int64(interval.rounded(.down))
        var nanoseconds = Int(((interval - Double(seconds)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            let (incremented, overflow) = seconds.addingReportingOverflow(1)
            guard !overflow else {
                throw DockerPluginProtocolError.timestampOutOfRange
            }
            seconds = incremented
            nanoseconds = 0
        }
        return try ContainerLogTimestamp(
            secondsSinceUnixEpoch: seconds,
            nanoseconds: UInt32(nanoseconds)
        )
    }

}
