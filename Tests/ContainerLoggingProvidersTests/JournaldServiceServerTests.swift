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
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct JournaldServiceServerTests {
    @Test func lifecycleRequestsReachBackendWithExactValues() async throws {
        let backend = JournaldServerRecordingBackend()
        let handler = JournaldServiceWireHandlerV1(backend: backend)

        let generationRequest =
            try JournaldServiceWireRequestV1
            .activeSandboxGeneration()
        #expect(
            await handler.handle(generationRequest).sandboxGeneration == 13
        )

        let writer = try journaldServerWriterOpen()
        let openWriter = try JournaldServiceWireRequestV1.openWriter(writer)
        #expect(await handler.handle(openWriter).failure == nil)

        let entry = try journaldServerEntry()
        let write = try JournaldServiceWireRequestV1.write(
            sessionID: "writer-session",
            entry: entry
        )
        #expect(await handler.handle(write).failure == nil)

        let flush = try JournaldServiceWireRequestV1.flushWriter(
            sessionID: "writer-session",
            timeoutNanoseconds: 8_000
        )
        #expect(await handler.handle(flush).failure == nil)

        let close = try JournaldServiceWireRequestV1.closeWriter(
            sessionID: "writer-session",
            fenced: true,
            timeoutNanoseconds: 9_000
        )
        #expect(await handler.handle(close).failure == nil)
        let reclaimWriter = try JournaldServiceWireRequestV1.reclaimWriter(
            sessionID: "writer-session",
            providerID: JournaldLogDriverContract.providerIdentity.id,
            providerGeneration: 1
        )
        #expect(await handler.handle(reclaimWriter).failure == nil)

        let readerOpen = try journaldServerReaderOpen()
        let openReader = try JournaldServiceWireRequestV1.openReader(
            readerOpen
        )
        let openReaderResponse = await handler.handle(openReader)
        #expect(openReaderResponse.failure == nil)
        #expect(openReaderResponse.readerSequence == 1)

        let next = try JournaldServiceWireRequestV1.nextReader(
            sessionID: readerOpen.readerSessionID,
            readerSequence: 1
        )
        let nextResponse = await handler.handle(next)
        guard case .record(let record)? = nextResponse.readerEvent else {
            Issue.record("reader did not return its first record")
            return
        }
        #expect(try record.record() == journaldServerReadRecord())

        let cancel = try JournaldServiceWireRequestV1.cancelReader(
            sessionID: readerOpen.readerSessionID
        )
        #expect(await handler.handle(cancel).failure == nil)
        let reclaimReader = try JournaldServiceWireRequestV1.reclaimReader(
            sessionID: readerOpen.readerSessionID,
            providerID: JournaldLogDriverContract.providerIdentity.id,
            providerGeneration: 1
        )
        #expect(await handler.handle(reclaimReader).failure == nil)

        let snapshot = await backend.snapshot()
        #expect(snapshot.activeGenerationCalls == 1)
        #expect(snapshot.writerOpen == writer)
        #expect(snapshot.entry == entry)
        #expect(snapshot.flush == .init(sessionID: "writer-session", timeout: 8_000))
        #expect(
            snapshot.close
                == .init(
                    sessionID: "writer-session",
                    fenced: true,
                    timeout: 9_000
                )
        )
        #expect(snapshot.readerOpen == readerOpen)
        #expect(
            snapshot.readerNext
                == .init(sessionID: "reader-session", sequence: 1)
        )
        #expect(snapshot.cancelledReader == "reader-session")
        #expect(snapshot.reclaimedWriter?.sessionID == "writer-session")
        #expect(snapshot.reclaimedReader?.sessionID == "reader-session")
    }

    @Test func concurrentIdenticalCallsJoinOneBackendEffect() async throws {
        let backend = JournaldServerBlockingBackend()
        let handler = JournaldServiceWireHandlerV1(backend: backend)
        let request =
            try JournaldServiceWireRequestV1
            .activeSandboxGeneration()

        let first = Task { await handler.handle(request) }
        await backend.waitUntilStarted()
        let replay = Task { await handler.handle(request) }
        while await handler.replaySnapshot().joinedWaiters == 0 {
            await Task.yield()
        }
        #expect(
            await handler.replaySnapshot()
                == JournaldServiceReplaySnapshotV1(
                    inFlightOperations: 1,
                    joinedWaiters: 1,
                    completedOperations: 0,
                    completedEncodedBytes: 0
                )
        )

        await backend.release()
        let firstResponse = await first.value
        let replayResponse = await replay.value
        #expect(firstResponse == replayResponse)
        #expect(firstResponse.sandboxGeneration == 17)
        #expect(await backend.callCount == 1)
        #expect(await handler.replaySnapshot().inFlightOperations == 0)
        #expect(await handler.replaySnapshot().completedOperations == 1)
    }

    @Test func completedOutcomeReplaysAndConflictingIDFailsClosed() async throws {
        let backend = JournaldServerRecordingBackend()
        let handler = JournaldServiceWireHandlerV1(backend: backend)
        let request =
            try JournaldServiceWireRequestV1
            .activeSandboxGeneration()

        let first = await handler.handle(request)
        let replay = await handler.handle(request)
        #expect(first == replay)
        #expect(await backend.snapshot().activeGenerationCalls == 1)

        let other = try JournaldServiceWireRequestV1.cancelReader(
            sessionID: "reader-session"
        )
        let conflicting = try replacingOperationID(
            in: other,
            with: request.operationID
        )
        let conflict = await handler.handle(conflicting)
        #expect(conflict.failure == .idempotencyConflict)
        #expect(await backend.snapshot().cancelledReader == nil)
    }

    @Test func completedReplayCacheEvictsToConfiguredBound() async throws {
        let backend = JournaldServerRecordingBackend()
        let limits = try JournaldServiceReplayLimitsV1(
            maximumCompletedOperations: 2,
            maximumEncodedBytes: 2 * 1_024 * 1_024
        )
        let handler = JournaldServiceWireHandlerV1(
            backend: backend,
            limits: limits
        )
        let requests = try (0..<3).map { _ in
            try JournaldServiceWireRequestV1.activeSandboxGeneration()
        }
        for request in requests {
            #expect(await handler.handle(request).sandboxGeneration == 13)
        }

        let snapshot = await handler.replaySnapshot()
        #expect(snapshot.completedOperations == 2)
        #expect(snapshot.completedEncodedBytes > 0)
        #expect(snapshot.completedEncodedBytes <= limits.maximumEncodedBytes)
        #expect(await backend.snapshot().activeGenerationCalls == 3)

        #expect(await handler.handle(requests[0]).sandboxGeneration == 13)
        #expect(await backend.snapshot().activeGenerationCalls == 4)
    }

    @Test func backendFailuresMapToStableWireFailures() async throws {
        let backend = JournaldServerRecordingBackend(writeError: .unknownSession)
        let handler = JournaldServiceWireHandlerV1(backend: backend)
        let request = try JournaldServiceWireRequestV1.write(
            sessionID: "missing-session",
            entry: journaldServerEntry()
        )

        #expect(await handler.handle(request).failure == .unknownSession)
        #expect(await handler.handle(request).failure == .unknownSession)
        #expect(await backend.snapshot().writeCalls == 1)
    }

    @Test func replayLimitsRejectUnsafeBudgets() {
        #expect(throws: JournaldServiceWireError.invalidReplayLimits) {
            try JournaldServiceReplayLimitsV1(
                maximumCompletedOperations: 0
            )
        }
        #expect(throws: JournaldServiceWireError.invalidReplayLimits) {
            try JournaldServiceReplayLimitsV1(
                maximumEncodedBytes: JournaldServiceFrameCodecV1
                    .maximumFrameBytes
            )
        }
    }

    @Test func framedConnectionServesPersistentClientEndToEnd() async throws {
        let pair = try journaldServerSocketPair()
        let backend = JournaldServerRecordingBackend()
        let handler = JournaldServiceWireHandlerV1(backend: backend)
        let server = JournaldServiceWireConnectionV1(handler: handler)
        let serverTask = Task {
            try await server.serve(pair.server)
        }
        let connector = JournaldServerSingleConnector(handle: pair.client)
        let transport = JournaldServiceFileHandleTransportV1 {
            try await connector.connect()
        }
        let client = JournaldServiceWireClientV1(transport: transport)

        #expect(try await client.activeSandboxGeneration() == 13)
        try await client.openWriter(journaldServerWriterOpen())
        try await client.write(
            sessionID: "writer-session",
            entry: journaldServerEntry()
        )
        await transport.close()
        try await serverTask.value

        let snapshot = await backend.snapshot()
        #expect(snapshot.activeGenerationCalls == 1)
        #expect(snapshot.writerOpen != nil)
        #expect(snapshot.writeCalls == 1)
        #expect(await connector.connectionCount == 1)
    }
}

private struct JournaldServerCall: Equatable, Sendable {
    let sessionID: String
    let timeout: UInt64
}

private struct JournaldServerCloseCall: Equatable, Sendable {
    let sessionID: String
    let fenced: Bool
    let timeout: UInt64
}

private struct JournaldServerReaderCall: Equatable, Sendable {
    let sessionID: String
    let sequence: UInt64
}

private struct JournaldServerBackendSnapshot: Equatable, Sendable {
    let activeGenerationCalls: Int
    let writerOpen: JournaldWriterOpenRequest?
    let entry: JournaldEntry?
    let flush: JournaldServerCall?
    let close: JournaldServerCloseCall?
    let readerOpen: LogDriverReaderOpenRequestV1?
    let readerNext: JournaldServerReaderCall?
    let cancelledReader: String?
    let reclaimedWriter: JournaldTerminalReclaimWireV1?
    let reclaimedReader: JournaldTerminalReclaimWireV1?
    let writeCalls: Int
}

private actor JournaldServerRecordingBackend: JournaldServiceBackendV1 {
    private let writeError: JournaldProviderError?
    private var activeGenerationCalls = 0
    private var writerOpen: JournaldWriterOpenRequest?
    private var entry: JournaldEntry?
    private var flush: JournaldServerCall?
    private var close: JournaldServerCloseCall?
    private var readerOpen: LogDriverReaderOpenRequestV1?
    private var readerNext: JournaldServerReaderCall?
    private var cancelledReader: String?
    private var reclaimedWriter: JournaldTerminalReclaimWireV1?
    private var reclaimedReader: JournaldTerminalReclaimWireV1?
    private var writeCalls = 0

    init(writeError: JournaldProviderError? = nil) {
        self.writeError = writeError
    }

    func activeSandboxGeneration() -> UInt64 {
        activeGenerationCalls += 1
        return 13
    }

    func openWriter(_ request: JournaldWriterOpenRequest) {
        writerOpen = request
    }

    func write(sessionID: String, entry: JournaldEntry) throws {
        writeCalls += 1
        if let writeError {
            throw writeError
        }
        self.entry = entry
    }

    func flushWriter(
        sessionID: String,
        timeoutNanoseconds: UInt64
    ) {
        flush = JournaldServerCall(
            sessionID: sessionID,
            timeout: timeoutNanoseconds
        )
    }

    func closeWriter(
        sessionID: String,
        fenced: Bool,
        timeoutNanoseconds: UInt64
    ) {
        close = JournaldServerCloseCall(
            sessionID: sessionID,
            fenced: fenced,
            timeout: timeoutNanoseconds
        )
    }

    func reclaimWriter(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        reclaimedWriter = try JournaldTerminalReclaimWireV1(
            sessionID: sessionID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    func openReader(_ request: LogDriverReaderOpenRequestV1) -> UInt64 {
        readerOpen = request
        return 1
    }

    func nextReader(
        sessionID: String,
        sequence: UInt64
    ) throws -> ContainerLogReaderEventV1 {
        readerNext = JournaldServerReaderCall(
            sessionID: sessionID,
            sequence: sequence
        )
        return .record(try journaldServerReadRecord())
    }

    func cancelReader(sessionID: String) {
        cancelledReader = sessionID
    }

    func reclaimReader(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        reclaimedReader = try JournaldTerminalReclaimWireV1(
            sessionID: sessionID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    func snapshot() -> JournaldServerBackendSnapshot {
        JournaldServerBackendSnapshot(
            activeGenerationCalls: activeGenerationCalls,
            writerOpen: writerOpen,
            entry: entry,
            flush: flush,
            close: close,
            readerOpen: readerOpen,
            readerNext: readerNext,
            cancelledReader: cancelledReader,
            reclaimedWriter: reclaimedWriter,
            reclaimedReader: reclaimedReader,
            writeCalls: writeCalls
        )
    }
}

private actor JournaldServerBlockingBackend: JournaldServiceBackendV1 {
    private(set) var callCount = 0
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func activeSandboxGeneration() async -> UInt64 {
        callCount += 1
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return 17
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func openWriter(_ request: JournaldWriterOpenRequest) {}
    func write(sessionID: String, entry: JournaldEntry) {}
    func flushWriter(sessionID: String, timeoutNanoseconds: UInt64) {}
    func closeWriter(
        sessionID: String,
        fenced: Bool,
        timeoutNanoseconds: UInt64
    ) {}
    func reclaimWriter(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) {}
    func openReader(_ request: LogDriverReaderOpenRequestV1) -> UInt64 { 1 }
    func nextReader(
        sessionID: String,
        sequence: UInt64
    ) -> ContainerLogReaderEventV1 { .endOfStream }
    func cancelReader(sessionID: String) {}
    func reclaimReader(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) {}
}

private actor JournaldServerSingleConnector {
    private var handle: FileHandle?
    private(set) var connectionCount = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func connect() throws -> FileHandle {
        guard let handle else {
            throw JournaldServiceWireError.disconnected
        }
        self.handle = nil
        connectionCount += 1
        return handle
    }
}

private func journaldServerSocketPair() throws -> (
    client: FileHandle,
    server: FileHandle
) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (
        FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
        FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
}

private func replacingOperationID(
    in request: JournaldServiceWireRequestV1,
    with operationID: String
) throws -> JournaldServiceWireRequestV1 {
    let encoded = try JSONEncoder().encode(request)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["operationID"] = operationID
    return try JSONDecoder().decode(
        JournaldServiceWireRequestV1.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func journaldServerWriterOpen() throws -> JournaldWriterOpenRequest {
    let identifier = String(repeating: "a", count: 64)
    let request = try LogDriverStartRequestV1(
        operationGeneration: 1,
        idempotencyKey: "writer-operation",
        semanticRequestDigest: "sha256:writer",
        sessionID: "writer-session",
        containerID: identifier,
        leaseGeneration: 2,
        candidateProcessGeneration: 4,
        providerID: JournaldLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: 13
    )
    let configuration = try JournaldDriverConfiguration(
        containerID: identifier,
        fields: [
            JournaldField.containerID: String(identifier.prefix(12)),
            JournaldField.containerIDFull: identifier,
            JournaldField.containerTag: "service",
            JournaldField.syslogIdentifier: "service",
        ]
    )
    return try JournaldWriterOpenRequest(
        request: request,
        configuration: configuration,
        epoch: "epoch-1"
    )
}

private func journaldServerReaderOpen() throws -> LogDriverReaderOpenRequestV1 {
    try LogDriverReaderOpenRequestV1(
        operationGeneration: 1,
        idempotencyKey: "reader-operation",
        semanticRequestDigest: "sha256:reader",
        readerSessionID: "reader-session",
        containerID: String(repeating: "a", count: 64),
        leaseGeneration: 2,
        providerID: JournaldLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        source: .stoppedContainer,
        read: ContainerLogReadRequest(tail: 10)
    )
}

private func journaldServerEntry() throws -> JournaldEntry {
    try JournaldEntry(
        message: Data("line".utf8),
        priority: .informational,
        fields: [
            JournaldField.containerIDFull: String(repeating: "a", count: 64),
            JournaldField.logEpoch: "epoch-1",
            JournaldField.logOrdinal: "1",
        ],
        receivedTimestamp: ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_785_751_872,
            nanoseconds: 123_456_789
        ),
        processGeneration: 4
    )
}

private func journaldServerReadRecord() throws -> ContainerLogReadRecordV1 {
    try ContainerLogReadRecordV1(
        stream: .stdout,
        timestamp: ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_785_751_872,
            nanoseconds: 123_456_789
        ),
        data: Data("history\n".utf8),
        sequence: 1,
        processGeneration: 4
    )
}
