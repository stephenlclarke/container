//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct DockerPluginAdapterTests {
    @Test func startWriteAndCloseUseExactDockerOrdering() async throws {
        let fixture = try DockerPluginLifecycleFixture(readLogs: true)

        let started = try await fixture.start()
        #expect(started.capabilities == DockerPluginCapabilities(readLogs: true))
        #expect(started.readRouting == .pluginReader)
        #expect(await fixture.events.values == ["capabilities", "fifo-create", "start"])

        try await started.session.write(
            dockerPluginRecord(
                stream: .stderr,
                payload: Data([0x00, 0xff]),
                seconds: 7,
                nanoseconds: 8
            )
        )
        let frame = try #require(await fixture.fifo.frames.first)
        var decoder = DockerPluginFrameDecoder()
        let entries = try decoder.append(frame)
        try decoder.finish()
        let entry = try #require(entries.first)
        #expect(entry.source == "stderr")
        #expect(entry.timeNano == 7_000_000_008)
        #expect(entry.line == Data([0x00, 0xff]))

        try await started.session.close(deadline: ContinuousClock().now + .seconds(1))
        try await started.session.close(deadline: ContinuousClock().now + .seconds(1))

        #expect(
            await fixture.events.values
                == [
                    "capabilities",
                    "fifo-create",
                    "start",
                    "fifo-write",
                    "stop",
                    "fifo-close",
                    "lease-release",
                ]
        )
        #expect(await started.session.currentState() == .closed)
        #expect(await fixture.lease.releaseCount == 1)
    }

    @Test func failedCapabilityHandshakeUsesLegacyUnreadableRouting() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            capabilityFailure: true
        )

        let started = try await fixture.start()

        #expect(started.capabilities == DockerPluginCapabilities(readLogs: false))
        #expect(started.readRouting == .dualLocalCache)
        #expect(await fixture.events.values == ["capabilities", "fifo-create", "start"])
        try await started.session.close(deadline: ContinuousClock().now + .seconds(1))
    }

    @Test func startFailureRevokesFIFOAndReleasesLease() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            startResponses: [Data(#"{"Err":"sensitive plugin failure"}"#.utf8)]
        )

        await #expect(
            throws: DockerPluginProtocolError.endpointRejected(endpoint: .startLogging)
        ) {
            try await fixture.start()
        }

        #expect(
            await fixture.events.values
                == ["capabilities", "fifo-create", "start", "stop", "fifo-revoke", "lease-release"]
        )
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
    }

    @Test func lostStartResponseIsStoppedBeforeFIFOAndLeaseCleanup() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            startTransportFailure: true
        )

        await #expect(
            throws: DockerPluginProtocolError.transportFailure(endpoint: .startLogging)
        ) {
            try await fixture.start()
        }

        #expect(
            await fixture.events.values
                == ["capabilities", "fifo-create", "start", "stop", "fifo-revoke", "lease-release"]
        )
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
    }

    @Test func failedStopFencesFutureWritesUntilAnExactRetrySucceeds() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            stopResponses: [
                Data(#"{"Err":"not drained"}"#.utf8),
                Data("{}".utf8),
            ]
        )
        let started = try await fixture.start()

        await #expect(
            throws: DockerPluginProtocolError.endpointRejected(endpoint: .stopLogging)
        ) {
            try await started.session.close(deadline: ContinuousClock().now + .seconds(1))
        }
        #expect(await started.session.currentState() == .stopOutcomeUncertain)
        #expect(await fixture.fifo.closeCount == 0)
        #expect(await fixture.lease.releaseCount == 0)
        await #expect(throws: DockerPluginProtocolError.stopOutcomeUncertain) {
            try await started.session.write(dockerPluginRecord(payload: Data("late".utf8)))
        }

        try await started.session.close(deadline: ContinuousClock().now + .seconds(1))
        #expect(await started.session.currentState() == .closed)
        #expect(await fixture.fifo.closeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
        #expect(
            await fixture.events.values.suffix(4)
                == ["stop", "stop", "fifo-close", "lease-release"]
        )
    }

    @Test func authoritativeFenceRevokesBeforeBestEffortStopAndRelease() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            stopResponses: [Data(#"{"Err":"remote secret"}"#.utf8)]
        )
        let started = try await fixture.start()

        await started.session.fence()
        await started.session.fence()

        #expect(await started.session.currentState() == .writerFenced)
        #expect(
            await fixture.events.values.suffix(3)
                == ["fifo-revoke", "stop", "lease-release"]
        )
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
        await #expect(throws: DockerPluginProtocolError.writerUnavailable) {
            try await started.session.write(dockerPluginRecord(payload: Data("late".utf8)))
        }
    }

    @Test func slowFIFOBackpressuresAndSerializesRecordOrder() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            blockFirstWrite: true
        )
        let started = try await fixture.start()

        let first = Task {
            try await started.session.write(
                dockerPluginRecord(payload: Data("first".utf8), sequence: 1)
            )
        }
        await fixture.fifo.waitUntilFirstWriteIsBlocked()
        let second = Task {
            try await started.session.write(
                dockerPluginRecord(payload: Data("second".utf8), sequence: 2)
            )
        }

        try await Task.sleep(for: .milliseconds(25))
        #expect(await fixture.fifo.frames.count == 1)
        await fixture.fifo.releaseFirstWrite()
        try await first.value
        try await second.value

        let frames = await fixture.fifo.frames
        #expect(frames.count == 2)
        var decoder = DockerPluginFrameDecoder()
        #expect(try decoder.append(frames[0]).first?.line == Data("first".utf8))
        #expect(try decoder.append(frames[1]).first?.line == Data("second".utf8))
        try await started.session.close(deadline: ContinuousClock().now + .seconds(1))
    }

    @Test func authoritativeFenceInterruptsAnOutstandingFIFOWrite() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            blockFirstWrite: true
        )
        let started = try await fixture.start()
        let write = Task {
            try await started.session.write(
                dockerPluginRecord(payload: Data("blocked".utf8))
            )
        }
        await fixture.fifo.waitUntilFirstWriteIsBlocked()

        await started.session.fence()

        await #expect(throws: DockerPluginProtocolError.writerUnavailable) {
            try await write.value
        }
        #expect(await started.session.currentState() == .writerFenced)
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
    }

    @Test func writerCancellationRevokesFIFOAndAwaitsFenceCompletion() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            blockFirstWrite: true
        )
        let started = try await fixture.start()
        let write = Task {
            try await started.session.write(
                dockerPluginRecord(payload: Data("cancelled".utf8))
            )
        }
        await fixture.fifo.waitUntilFirstWriteIsBlocked()

        write.cancel()

        await #expect(throws: CancellationError.self) {
            try await write.value
        }
        #expect(await started.session.currentState() == .writerFenced)
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
        #expect(await fixture.events.values.suffix(3) == ["fifo-revoke", "stop", "lease-release"])
    }

    @Test func nonDrainingStopCannotRaceFIFOClosureOrLeaseRelease() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            blockFirstStop: true
        )
        let started = try await fixture.start()

        let close = Task {
            try await started.session.close(deadline: ContinuousClock().now + .seconds(2))
        }
        await fixture.transport.waitUntilFirstStopIsBlocked()

        #expect(await fixture.fifo.closeCount == 0)
        #expect(await fixture.lease.releaseCount == 0)
        #expect(await fixture.events.values.suffix(1) == ["stop"])

        await fixture.transport.releaseFirstStop()
        try await close.value
        #expect(await fixture.events.values.suffix(3) == ["stop", "fifo-close", "lease-release"])
    }

    @Test func fenceWaitsForAnInProgressGracefulFIFOTeardown() async throws {
        let fixture = try DockerPluginLifecycleFixture(
            readLogs: false,
            blockFIFOClosure: true
        )
        let started = try await fixture.start()
        let close = Task {
            try await started.session.close(deadline: ContinuousClock().now + .seconds(2))
        }
        await fixture.fifo.waitUntilClosureIsBlocked()

        let fence = Task {
            await started.session.fence()
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(await fixture.fifo.revokeCount == 0)
        #expect(await fixture.lease.releaseCount == 0)

        await fixture.fifo.releaseClosure()
        try await close.value
        await fence.value

        #expect(await started.session.currentState() == .closed)
        #expect(await fixture.fifo.closeCount == 1)
        #expect(await fixture.fifo.revokeCount == 0)
        #expect(await fixture.lease.releaseCount == 1)
        #expect(await fixture.events.values.suffix(3) == ["stop", "fifo-close", "lease-release"])
    }

    @Test func mismatchedProviderGenerationIsRejectedBeforeAnyPluginOrFIFOEffect() async throws {
        let fixture = try DockerPluginLifecycleFixture(readLogs: false)

        await #expect(throws: DockerPluginProtocolError.providerGenerationMismatch) {
            try await DockerPluginDriverSession.start(
                sessionID: "session-id",
                providerGeneration: 8,
                info: dockerPluginTestInfo(),
                lease: fixture.lease,
                fifoFactory: fixture.factory
            )
        }

        #expect(await fixture.events.values == ["lease-release"])
        #expect(await fixture.lease.releaseCount == 1)
    }

    @Test func unreadableCapabilityNeverCallsReadLogs() async throws {
        let transport = DockerPluginTestTransport()
        let client = DockerPluginProtocolClient(transport: transport)

        await #expect(throws: ContainerLogReaderError.configuredDriverDoesNotSupportReading) {
            try await DockerPluginLogReader.open(
                client: client,
                capabilities: DockerPluginCapabilities(readLogs: false),
                info: dockerPluginTestInfo(),
                request: ContainerLogReadRequest()
            )
        }
        #expect(await transport.streamCalls.isEmpty)
    }

    @Test func readablePluginAppliesStreamAndTimeFiltersDefensively() async throws {
        let frames = try [
            DockerPluginLogEntry(
                source: "stderr",
                timeNano: 9_000_000_000,
                line: Data("before".utf8),
                partial: false,
                partialMetadata: nil
            ),
            DockerPluginLogEntry(
                source: "stdout",
                timeNano: 11_000_000_000,
                line: Data("wrong-stream".utf8),
                partial: false,
                partialMetadata: nil
            ),
            DockerPluginLogEntry(
                source: "stderr",
                timeNano: 12_250_000_000,
                line: Data([0x00, 0xff]),
                partial: true,
                partialMetadata: DockerPluginPartialMetadata(last: true, id: "id", ordinal: 1)
            ),
            DockerPluginLogEntry(
                source: "stderr",
                timeNano: 20_000_000_000,
                line: Data("at-until".utf8),
                partial: false,
                partialMetadata: nil
            ),
            DockerPluginLogEntry(
                source: "stderr",
                timeNano: 20_000_000_001,
                line: Data("after-until".utf8),
                partial: false,
                partialMetadata: nil
            ),
        ].map(DockerPluginLogEntryCodec.encodeFrame)
        var wire = Data()
        for frame in frames {
            wire.append(frame)
        }
        let chunks = stride(from: 0, to: wire.count, by: 3).map {
            Data(wire[$0..<min($0 + 3, wire.count)])
        }
        let responseStream = DockerPluginTestResponseStream(chunks: chunks)
        let transport = DockerPluginTestTransport(stream: responseStream)
        let request = try ContainerLogReadRequest(
            stdout: false,
            stderr: true,
            tail: 10,
            since: Date(timeIntervalSince1970: 10),
            until: Date(timeIntervalSince1970: 20)
        )
        let reader = try await DockerPluginLogReader.open(
            client: DockerPluginProtocolClient(transport: transport),
            capabilities: DockerPluginCapabilities(readLogs: true),
            info: dockerPluginTestInfo(),
            request: request,
            processGeneration: 7
        )

        let first = try await reader.next()
        let record: ContainerLogReadRecordV1
        switch first {
        case .record(let value): record = value
        case .endOfStream:
            Issue.record("expected one filtered record")
            return
        }
        #expect(record.stream == .stderr)
        #expect(record.timestamp == (try ContainerLogTimestamp(secondsSinceUnixEpoch: 12, nanoseconds: 250_000_000)))
        #expect(record.data == Data([0x00, 0xff]))
        #expect(record.sequence == 1)
        #expect(record.processGeneration == 7)
        let boundary = try await reader.next()
        switch boundary {
        case .record(let value):
            #expect(value.data == Data("at-until".utf8))
            #expect(value.sequence == 2)
        case .endOfStream:
            Issue.record("Docker's until boundary is inclusive")
        }
        #expect(try await reader.next() == .endOfStream)
        await #expect(throws: ContainerLogReaderError.alreadyEnded) {
            try await reader.next()
        }
        #expect(await responseStream.closeCount == 1)
    }

    @Test func readerCancellationClosesThePluginResponse() async throws {
        let responseStream = CancellableDockerPluginTestResponseStream()
        let transport = DockerPluginTestTransport(stream: responseStream)
        let reader = try await DockerPluginLogReader.open(
            client: DockerPluginProtocolClient(transport: transport),
            capabilities: DockerPluginCapabilities(readLogs: true),
            info: dockerPluginTestInfo(),
            request: ContainerLogReadRequest(follow: true)
        )

        let read = Task { try await reader.next() }
        await responseStream.waitUntilReading()
        read.cancel()
        await #expect(throws: CancellationError.self) {
            try await read.value
        }
        #expect(await responseStream.closeCount == 1)
    }

    @Test func protocolCancellationInterruptsPendingPluginRead() async throws {
        let responseStream = CancellableDockerPluginTestResponseStream()
        let transport = DockerPluginTestTransport(stream: responseStream)
        let reader: any ContainerLogReader = try await DockerPluginLogReader.open(
            client: DockerPluginProtocolClient(transport: transport),
            capabilities: DockerPluginCapabilities(readLogs: true),
            info: dockerPluginTestInfo(),
            request: ContainerLogReadRequest(follow: true)
        )
        let read = Task { try await reader.next() }
        await responseStream.waitUntilReading()

        await reader.cancel()

        await #expect(throws: ContainerLogReaderError.cancelled) {
            try await read.value
        }
        #expect(await responseStream.closeCount == 1)
    }

    @Test func sinceGateKeepsLaterTimestampRegressionsVisible() async throws {
        let entries = [
            DockerPluginLogEntry(
                source: "stdout",
                timeNano: 9_000_000_000,
                line: Data("before".utf8),
                partial: false,
                partialMetadata: nil
            ),
            DockerPluginLogEntry(
                source: "stdout",
                timeNano: 12_000_000_000,
                line: Data("qualifying".utf8),
                partial: false,
                partialMetadata: nil
            ),
            DockerPluginLogEntry(
                source: "stdout",
                timeNano: 8_000_000_000,
                line: Data("regressed".utf8),
                partial: false,
                partialMetadata: nil
            ),
        ]
        let wire = try entries.reduce(into: Data()) { data, entry in
            data.append(try DockerPluginLogEntryCodec.encodeFrame(entry))
        }
        let responseStream = DockerPluginTestResponseStream(chunks: [wire])
        let reader = try await DockerPluginLogReader.open(
            client: DockerPluginProtocolClient(
                transport: DockerPluginTestTransport(stream: responseStream)
            ),
            capabilities: DockerPluginCapabilities(readLogs: true),
            info: dockerPluginTestInfo(),
            request: ContainerLogReadRequest(
                follow: true,
                since: Date(timeIntervalSince1970: 10)
            )
        )

        let first = try await reader.next()
        let second = try await reader.next()
        #expect(first.record?.data == Data("qualifying".utf8))
        #expect(second.record?.data == Data("regressed".utf8))
        #expect(try await reader.next() == .endOfStream)
    }

    @Test func concurrentReaderPullIsRejectedWithoutQueuing() async throws {
        let responseStream = CancellableDockerPluginTestResponseStream()
        let transport = DockerPluginTestTransport(stream: responseStream)
        let reader = try await DockerPluginLogReader.open(
            client: DockerPluginProtocolClient(transport: transport),
            capabilities: DockerPluginCapabilities(readLogs: true),
            info: dockerPluginTestInfo(),
            request: ContainerLogReadRequest(follow: true)
        )
        let first = Task { try await reader.next() }
        await responseStream.waitUntilReading()

        await #expect(throws: ContainerLogReaderError.concurrentReadNotSupported) {
            try await reader.next()
        }

        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
    }
}

extension ContainerLogReaderEventV1 {
    fileprivate var record: ContainerLogReadRecordV1? {
        guard case .record(let record) = self else {
            return nil
        }
        return record
    }
}

func dockerPluginRecord(
    stream: ContainerLogStream = .stdout,
    payload: Data,
    seconds: Int64 = 1,
    nanoseconds: UInt32 = 2,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    try ContainerLogRecordV2(
        stream: stream,
        observation: ContainerLogObservation(
            wallClock: ContainerLogTimestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            ),
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: nil,
        sequence: sequence,
        processGeneration: 1
    )
}

private struct DockerPluginLifecycleFixture {
    let events: DockerPluginTestEventRecorder
    let transport: DockerPluginLifecycleTransport
    let fifo: DockerPluginLifecycleFIFO
    let lease: DockerPluginLifecycleLease
    let factory: DockerPluginLifecycleFIFOFactory

    init(
        readLogs: Bool,
        capabilityFailure: Bool = false,
        startResponses: [Data] = [Data("{}".utf8)],
        stopResponses: [Data] = [Data("{}".utf8)],
        blockFirstWrite: Bool = false,
        blockFirstStop: Bool = false,
        startTransportFailure: Bool = false,
        blockFIFOClosure: Bool = false
    ) throws {
        let events = DockerPluginTestEventRecorder()
        let transport = DockerPluginLifecycleTransport(
            events: events,
            readLogs: readLogs,
            capabilityFailure: capabilityFailure,
            startResponses: startResponses,
            stopResponses: stopResponses,
            blockFirstStop: blockFirstStop,
            startTransportFailure: startTransportFailure
        )
        let fifo = try DockerPluginLifecycleFIFO(
            events: events,
            blockFirstWrite: blockFirstWrite,
            blockClosure: blockFIFOClosure
        )
        self.events = events
        self.transport = transport
        self.fifo = fifo
        self.lease = DockerPluginLifecycleLease(transport: transport, events: events)
        self.factory = DockerPluginLifecycleFIFOFactory(fifo: fifo, events: events)
    }

    func start() async throws -> DockerPluginStartedSession {
        try await DockerPluginDriverSession.start(
            sessionID: "session-id",
            providerGeneration: 7,
            info: dockerPluginTestInfo(),
            lease: lease,
            fifoFactory: factory,
            deadline: ContinuousClock().now + .seconds(1)
        )
    }
}

actor DockerPluginTestEventRecorder {
    private(set) var values = [String]()

    func append(_ value: String) {
        values.append(value)
    }
}

private actor DockerPluginLifecycleTransport: DockerPluginRPCTransport {
    private let events: DockerPluginTestEventRecorder
    private let readLogs: Bool
    private let capabilityFailure: Bool
    private var startResponses: [Data]
    private var stopResponses: [Data]
    private var blockFirstStop: Bool
    private let startTransportFailure: Bool
    private var blockedStop: CheckedContinuation<Void, Never>?
    private var blockedStopWaiters = [CheckedContinuation<Void, Never>]()

    init(
        events: DockerPluginTestEventRecorder,
        readLogs: Bool,
        capabilityFailure: Bool,
        startResponses: [Data],
        stopResponses: [Data],
        blockFirstStop: Bool,
        startTransportFailure: Bool
    ) {
        self.events = events
        self.readLogs = readLogs
        self.capabilityFailure = capabilityFailure
        self.startResponses = startResponses
        self.stopResponses = stopResponses
        self.blockFirstStop = blockFirstStop
        self.startTransportFailure = startTransportFailure
    }

    func call(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant?
    ) async throws -> Data {
        switch endpoint {
        case .capabilities:
            await events.append("capabilities")
            if capabilityFailure {
                throw DockerPluginTestFailure.containsSensitiveBody
            }
            return Data("{\"Cap\":{\"ReadLogs\":\(readLogs)},\"Err\":\"\"}".utf8)
        case .startLogging:
            await events.append("start")
            if startTransportFailure {
                throw DockerPluginTestFailure.containsSensitiveBody
            }
            return startResponses.isEmpty ? Data("{}".utf8) : startResponses.removeFirst()
        case .stopLogging:
            await events.append("stop")
            if blockFirstStop {
                await withCheckedContinuation { continuation in
                    if blockFirstStop {
                        blockedStop = continuation
                        let waiters = blockedStopWaiters
                        blockedStopWaiters.removeAll()
                        for waiter in waiters {
                            waiter.resume()
                        }
                    } else {
                        continuation.resume()
                    }
                }
            }
            return stopResponses.isEmpty ? Data("{}".utf8) : stopResponses.removeFirst()
        case .readLogs:
            Issue.record("ReadLogs must use streaming transport")
            return Data()
        }
    }

    func openStream(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumChunkBytes: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> any DockerPluginResponseStream {
        throw DockerPluginTestFailure.containsSensitiveBody
    }

    func waitUntilFirstStopIsBlocked() async {
        if blockedStop != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedStopWaiters.append(continuation)
        }
    }

    func releaseFirstStop() {
        blockFirstStop = false
        let continuation = blockedStop
        blockedStop = nil
        continuation?.resume()
    }
}

private actor DockerPluginLifecycleFIFO: DockerPluginFIFO {
    nonisolated let reference: DockerPluginFIFOReference
    private let events: DockerPluginTestEventRecorder
    private(set) var frames = [Data]()
    private(set) var closeCount = 0
    private(set) var revokeCount = 0
    private var blockFirstWrite: Bool
    private var blockClosure: Bool
    private var blockedWrite: CheckedContinuation<Void, Never>?
    private var blockedWriteWaiters = [CheckedContinuation<Void, Never>]()
    private var blockedClosure: CheckedContinuation<Void, Never>?
    private var blockedClosureWaiters = [CheckedContinuation<Void, Never>]()

    init(
        events: DockerPluginTestEventRecorder,
        blockFirstWrite: Bool,
        blockClosure: Bool
    ) throws {
        self.events = events
        self.blockFirstWrite = blockFirstWrite
        self.blockClosure = blockClosure
        self.reference = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/session-id"
        )
    }

    func writeFrame(_ frame: Data) async throws {
        frames.append(frame)
        await events.append("fifo-write")
        if blockFirstWrite, frames.count == 1 {
            await withCheckedContinuation { continuation in
                if blockFirstWrite {
                    blockedWrite = continuation
                    let waiters = blockedWriteWaiters
                    blockedWriteWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func closeAndRemove() async {
        closeCount += 1
        await events.append("fifo-close")
        if blockClosure {
            await withCheckedContinuation { continuation in
                if blockClosure {
                    blockedClosure = continuation
                    let waiters = blockedClosureWaiters
                    blockedClosureWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func revokeAndRemove() async {
        revokeCount += 1
        await events.append("fifo-revoke")
        blockFirstWrite = false
        let continuation = blockedWrite
        blockedWrite = nil
        continuation?.resume()
    }

    func waitUntilFirstWriteIsBlocked() async {
        if blockedWrite != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWriteWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        blockFirstWrite = false
        let continuation = blockedWrite
        blockedWrite = nil
        continuation?.resume()
    }

    func waitUntilClosureIsBlocked() async {
        if blockedClosure != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedClosureWaiters.append(continuation)
        }
    }

    func releaseClosure() {
        blockClosure = false
        let continuation = blockedClosure
        blockedClosure = nil
        continuation?.resume()
    }
}

private actor DockerPluginLifecycleFIFOFactory: DockerPluginFIFOFactory {
    private let fifo: DockerPluginLifecycleFIFO
    private let events: DockerPluginTestEventRecorder

    init(fifo: DockerPluginLifecycleFIFO, events: DockerPluginTestEventRecorder) {
        self.fifo = fifo
        self.events = events
    }

    func createFIFO(
        sessionID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginFIFO {
        #expect(sessionID == "session-id")
        #expect(providerGeneration == 7)
        await events.append("fifo-create")
        return fifo
    }
}

private actor DockerPluginLifecycleLease: DockerPluginProviderLease {
    nonisolated let providerGeneration: UInt64 = 7
    nonisolated let transport: any DockerPluginRPCTransport
    private let events: DockerPluginTestEventRecorder
    private(set) var releaseCount = 0

    init(
        transport: any DockerPluginRPCTransport,
        events: DockerPluginTestEventRecorder
    ) {
        self.transport = transport
        self.events = events
    }

    func release() async {
        releaseCount += 1
        await events.append("lease-release")
    }
}

private actor CancellableDockerPluginTestResponseStream: DockerPluginResponseStream {
    private var readStarted = false
    private var readWaiters = [CheckedContinuation<Void, Never>]()
    private var pendingRead: CheckedContinuation<Data?, any Error>?
    private(set) var closeCount = 0

    func nextChunk(maximumBytes: Int) async throws -> Data? {
        readStarted = true
        for waiter in readWaiters {
            waiter.resume()
        }
        readWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            pendingRead = continuation
        }
    }

    func close() async {
        closeCount += 1
        let continuation = pendingRead
        pendingRead = nil
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilReading() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
        }
    }
}
