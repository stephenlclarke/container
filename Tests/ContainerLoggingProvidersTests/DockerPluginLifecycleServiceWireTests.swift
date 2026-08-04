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

struct DockerPluginLifecycleServiceWireTests {
    @Test func authenticationMatchesTheLinuxServiceFixture() throws {
        let unsigned = Data(
            #"{"operation":"activeSandboxGeneration","operationID":"123e4567-e89b-12d3-a456-426614174000","schemaVersion":1}"#
                .utf8
        )
        let request = try JSONDecoder().decode(
            DockerPluginLifecycleServiceWireRequestV1.self,
            from: unsigned
        )
        let authenticated = try request.authenticated(
            using: Data(repeating: 0x5a, count: 32)
        )
        #expect(
            authenticated.authentication?.map {
                String(format: "%02x", $0)
            }.joined()
                == "97dea1d206ae8a20fe40a00b63c6398aca7026ad6e443945799898b6d34965ff"
        )
    }

    @Test func requestJSONMatchesTheLinuxServiceContract() throws {
        let request = DockerPluginLifecycleServiceWireRequestV1.startWriter(
            try DockerPluginWriterOpenRequest(
                request: dockerPluginWireWriterRequest(),
                info: dockerPluginWireInfo()
            ),
            expectedReadLogs: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["operation"] as? String == "startWriter")
        #expect((object["operationID"] as? String)?.isEmpty == false)
        let open = try #require(object["writerOpen"] as? [String: Any])
        #expect(open["expectedReadLogs"] as? Bool == true)
        let start = try #require(open["request"] as? [String: Any])
        #expect(start["sessionID"] as? String == "plugin-writer-session")
        #expect(start["candidateSandboxGeneration"] as? Int == 9)
        let info = try #require(open["info"] as? [String: Any])
        #expect(info["ContainerID"] as? String == dockerPluginWireContainerID)
        #expect((info["Config"] as? [String: String]) == ["key": "value"])
        #expect(object["token"] == nil)
        #expect(object["frame"] == nil)
        #expect(object["authentication"] == nil)
    }

    @Test func clientProjectsWriterReaderAndDockerFrames() async throws {
        let transport = DockerPluginWireRecordingTransport()
        let client = DockerPluginLifecycleServiceWireClientV1(
            expectedReadLogs: true,
            transport: transport
        )
        #expect(try await client.activeSandboxGeneration() == 9)

        let historyMigration = try dockerPluginWireHistoryMigrationRequest()
        let migrationReceipt = try await client.migrateHistory(
            historyMigration
        )
        #expect(migrationReceipt.request == historyMigration)
        try await client.reclaimGeneration(
            LogDriverProviderGenerationReclaimV1(
                providerID: dockerPluginWireProviderID,
                providerGeneration: 7
            )
        )

        let writerRequest = try dockerPluginWireWriterRequest()
        let started = try await client.startWriter(
            DockerPluginWriterOpenRequest(
                request: writerRequest,
                info: dockerPluginWireInfo()
            )
        )
        try await started.started.session.write(
            dockerPluginWireRecord(payload: Data([0x00, 0xff]))
        )
        try await started.started.session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )
        try await started.started.session.close(
            deadline: ContinuousClock().now + .seconds(1)
        )

        let readerRequest = try dockerPluginWireReaderRequest()
        let reader = try await client.openReader(
            DockerPluginReaderOpenRequest(
                request: readerRequest,
                info: dockerPluginWireInfo()
            )
        ).started.reader
        let event = try await reader.next()
        switch event {
        case .record(let record):
            #expect(record.stream == .stderr)
            #expect(record.data == Data("history".utf8))
            #expect(record.sequence == 1)
            #expect(record.processGeneration == nil)
        case .endOfStream:
            Issue.record("expected the service-owned reader frame")
        }
        #expect(try await reader.next() == .endOfStream)

        let requests = await transport.requests
        #expect(
            requests.map(\.operation) == [
                .activeSandboxGeneration,
                .migrateHistory,
                .reclaimGeneration,
                .startWriter,
                .writeWriter,
                .flushWriter,
                .finishWriter,
                .openReader,
                .nextReader,
                .nextReader,
                .cancelReader,
            ]
        )
        let encodedFrame = try #require(requests[4].frame)
        #expect(requests[4].sequence == 1)
        var decoder = DockerPluginFrameDecoder()
        let entries = try decoder.append(encodedFrame)
        try decoder.finish()
        #expect(entries.count == 1)
        #expect(entries[0].source == "stdout")
        #expect(entries[0].line == Data([0x00, 0xff]))
    }

    @Test func writerSerializesSuspendingWritesAndAdvancesSequence() async throws {
        let transport = DockerPluginWireSerializingTransport()
        let client = DockerPluginLifecycleServiceWireClientV1(
            expectedReadLogs: true,
            transport: transport
        )
        let writer = try await client.startWriter(
            DockerPluginWriterOpenRequest(
                request: dockerPluginWireWriterRequest(),
                info: dockerPluginWireInfo()
            )
        ).started.session

        let first = Task {
            try await writer.write(
                dockerPluginWireRecord(
                    payload: Data("first".utf8),
                    sequence: 1
                )
            )
        }
        await transport.waitUntilFirstWriteIsBlocked()
        let second = Task {
            try await writer.write(
                dockerPluginWireRecord(
                    payload: Data("second".utf8),
                    sequence: 2
                )
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.writeRequestCount == 1)
        await transport.releaseFirstWrite()
        try await first.value
        try await second.value

        let requests = await transport.writeRequests
        #expect(requests.map(\.sequence) == [1, 2])
        let payloads = try requests.map { request in
            var decoder = DockerPluginFrameDecoder()
            let entries = try decoder.append(try #require(request.frame))
            try decoder.finish()
            return try #require(entries.first).line
        }
        #expect(payloads == [Data("first".utf8), Data("second".utf8)])
    }

    @Test func responseLossReconnectsWithByteIdenticalOperation() async throws {
        let first = try dockerPluginWireSocketPair()
        let second = try dockerPluginWireSocketPair()
        let connector = DockerPluginWireSocketConnector(
            handles: [first.client, second.client]
        )
        let authenticationKey = Data(repeating: 0x5a, count: 32)
        let transport = try DockerPluginLifecycleServiceFileHandleTransportV1(
            authenticationKey: authenticationKey
        ) {
            try await connector.connect()
        }
        let request = DockerPluginLifecycleServiceWireRequestV1.generation()
        let authenticated = try request.authenticated(
            using: authenticationKey
        )

        let firstServer = Task.detached {
            defer { try? first.server.close() }
            return try DockerPluginLifecycleServiceFrameCodecV1.read(
                DockerPluginLifecycleServiceWireRequestV1.self,
                from: first.server
            )
        }
        let secondServer = Task.detached {
            defer { try? second.server.close() }
            let replay = try DockerPluginLifecycleServiceFrameCodecV1.read(
                DockerPluginLifecycleServiceWireRequestV1.self,
                from: second.server
            )
            try DockerPluginLifecycleServiceFrameCodecV1.write(
                DockerPluginLifecycleServiceWireResponseV1(
                    operationID: replay.operationID,
                    sandboxGeneration: 9
                ),
                to: second.server
            )
            return replay
        }

        let response = try await transport.call(request)
        let firstAttempt = try await firstServer.value
        let replay = try await secondServer.value
        await transport.close()

        #expect(response.sandboxGeneration == 9)
        #expect(firstAttempt == authenticated)
        #expect(replay == authenticated)
        #expect(await connector.connectionCount == 2)
    }

    @Test func independentOperationsUseConcurrentPersistentLanes() async throws {
        let first = try dockerPluginWireSocketPair()
        let second = try dockerPluginWireSocketPair()
        let connector = DockerPluginWireSocketConnector(
            handles: [first.client, second.client]
        )
        let barrier = DockerPluginWireBarrier(target: 2)
        let transport = try DockerPluginLifecycleServiceFileHandleTransportV1(
            authenticationKey: Data(repeating: 0x5a, count: 32),
            maximumConnections: 2
        ) {
            try await connector.connect()
        }
        let servers = [first.server, second.server].map { handle in
            Task.detached {
                defer { try? handle.close() }
                let request =
                    try DockerPluginLifecycleServiceFrameCodecV1
                    .read(
                        DockerPluginLifecycleServiceWireRequestV1.self,
                        from: handle
                    )
                await barrier.arriveAndWait()
                try DockerPluginLifecycleServiceFrameCodecV1.write(
                    DockerPluginLifecycleServiceWireResponseV1(
                        operationID: request.operationID,
                        sandboxGeneration: 9
                    ),
                    to: handle
                )
            }
        }

        async let firstResponse = transport.call(.generation())
        async let secondResponse = transport.call(.generation())
        #expect(try await firstResponse.sandboxGeneration == 9)
        #expect(try await secondResponse.sandboxGeneration == 9)
        for server in servers {
            try await server.value
        }
        #expect(await connector.connectionCount == 2)
        await transport.close()
    }

    @Test func cancelledLaneWaiterDoesNotWaitForTheActiveOperation() async throws {
        let pair = try dockerPluginWireSocketPair()
        let connector = DockerPluginWireSocketConnector(handles: [pair.client])
        let gate = DockerPluginWireGate()
        let transport = try DockerPluginLifecycleServiceFileHandleTransportV1(
            authenticationKey: Data(repeating: 0x5a, count: 32),
            maximumConnections: 1
        ) {
            try await connector.connect()
        }
        let server = Task.detached {
            defer { try? pair.server.close() }
            let request = try DockerPluginLifecycleServiceFrameCodecV1.read(
                DockerPluginLifecycleServiceWireRequestV1.self,
                from: pair.server
            )
            await gate.arriveAndWait()
            try DockerPluginLifecycleServiceFrameCodecV1.write(
                DockerPluginLifecycleServiceWireResponseV1(
                    operationID: request.operationID,
                    sandboxGeneration: 9
                ),
                to: pair.server
            )
        }
        let active = Task {
            try await transport.call(.generation())
        }
        await gate.waitForArrival()

        let waiting = Task {
            try await transport.call(.generation())
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        let clock = ContinuousClock()
        let started = clock.now
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(clock.now - started < .milliseconds(250))

        await gate.release()
        #expect(try await active.value.sandboxGeneration == 9)
        try await server.value
        await transport.close()
    }

    @Test func responsePayloadSmugglingFailsClosed() async throws {
        let request = DockerPluginLifecycleServiceWireRequestV1.generation()
        let response = DockerPluginLifecycleServiceWireResponseV1(
            operationID: request.operationID,
            sandboxGeneration: 9,
            token: Data(repeating: 0x41, count: 32)
        )
        let transport = DockerPluginWireFixedTransport(response: response)
        let client = DockerPluginLifecycleServiceWireClientV1(
            expectedReadLogs: false,
            transport: transport
        )
        await #expect(
            throws: DockerPluginLifecycleServiceWireError.invalidEnvelope
        ) {
            try await client.activeSandboxGeneration()
        }
    }

    @Test func writerStartProjectsDefinitivePluginRejection() async throws {
        let client = DockerPluginLifecycleServiceWireClientV1(
            expectedReadLogs: true,
            transport: DockerPluginWireFailureTransport(
                failure: .pluginRejected
            )
        )
        await #expect(
            throws: DockerPluginProtocolError.endpointRejected(
                endpoint: .startLogging
            )
        ) {
            try await client.startWriter(
                DockerPluginWriterOpenRequest(
                    request: dockerPluginWireWriterRequest(),
                    info: dockerPluginWireInfo()
                )
            )
        }
    }
}

private actor DockerPluginWireRecordingTransport:
    DockerPluginLifecycleServiceWireTransportV1
{
    private(set) var requests = [DockerPluginLifecycleServiceWireRequestV1]()
    private var readerSequence = 0

    func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) throws -> DockerPluginLifecycleServiceWireResponseV1 {
        requests.append(request)
        let capabilities = DockerPluginCapabilitiesWireV1(
            DockerPluginCapabilities(readLogs: true)
        )
        switch request.operation {
        case .activeSandboxGeneration:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                sandboxGeneration: 9
            )
        case .migrateHistory:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                historyMigrationReceipt: try LogDriverHistoryMigrationReceiptV1(
                    request: request.historyMigration!,
                    providerOutcomeDigest: "sha256:provider-history"
                )
            )
        case .reclaimGeneration:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID
            )
        case .startWriter:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                capabilities: capabilities,
                token: Data(repeating: 0x41, count: 32),
                sequence: 1
            )
        case .openReader:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                capabilities: capabilities,
                token: Data(repeating: 0x42, count: 32),
                sequence: 1
            )
        case .nextReader:
            readerSequence += 1
            if readerSequence == 1 {
                return DockerPluginLifecycleServiceWireResponseV1(
                    operationID: request.operationID,
                    frame: try DockerPluginLogEntryCodec.encodeFrame(
                        DockerPluginLogEntry(
                            source: "stderr",
                            timeNano: 2_000_000_003,
                            line: Data("history".utf8),
                            partial: false,
                            partialMetadata: nil
                        )
                    ),
                    endOfStream: false
                )
            }
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                endOfStream: true
            )
        case .writeWriter, .flushWriter, .finishWriter, .cancelReader,
            .reclaimTerminalEffect:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID
            )
        case .reconcileWriterOpen:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                openObservation: .absent
            )
        case .reconcileReaderOpen:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                openObservation: .absent
            )
        case .reconcileWriter, .fenceWriter, .closeWriter:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                writerObservation: .active
            )
        case .reconcileReader, .closeReader:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                readerObservation: .active
            )
        }
    }
}

private actor DockerPluginWireSerializingTransport:
    DockerPluginLifecycleServiceWireTransportV1
{
    private(set) var writeRequests = [
        DockerPluginLifecycleServiceWireRequestV1
    ]()
    private var firstWriteBlocked = true
    private var firstWriteArrived = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    var writeRequestCount: Int {
        writeRequests.count
    }

    func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        switch request.operation {
        case .startWriter:
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                capabilities: DockerPluginCapabilitiesWireV1(
                    DockerPluginCapabilities(readLogs: true)
                ),
                token: Data(repeating: 0x41, count: 32),
                sequence: 1
            )
        case .writeWriter:
            writeRequests.append(request)
            if firstWriteBlocked {
                firstWriteBlocked = false
                firstWriteArrived = true
                for waiter in arrivalWaiters {
                    waiter.resume()
                }
                arrivalWaiters.removeAll()
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
            return DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID
            )
        default:
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
    }

    func waitUntilFirstWriteIsBlocked() async {
        guard !firstWriteArrived else {
            return
        }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private struct DockerPluginWireFixedTransport:
    DockerPluginLifecycleServiceWireTransportV1
{
    let response: DockerPluginLifecycleServiceWireResponseV1

    func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        response
    }
}

private struct DockerPluginWireFailureTransport:
    DockerPluginLifecycleServiceWireTransportV1
{
    let failure: DockerPluginLifecycleServiceWireFailureV1

    func call(
        _ request: DockerPluginLifecycleServiceWireRequestV1
    ) async throws -> DockerPluginLifecycleServiceWireResponseV1 {
        DockerPluginLifecycleServiceWireResponseV1(
            operationID: request.operationID,
            failure: failure
        )
    }
}

private actor DockerPluginWireSocketConnector {
    private var handles: [FileHandle]
    private(set) var connectionCount = 0

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func connect() throws -> FileHandle {
        guard !handles.isEmpty else {
            throw DockerPluginLifecycleServiceWireError.disconnected
        }
        connectionCount += 1
        return handles.removeFirst()
    }
}

private actor DockerPluginWireBarrier {
    private let target: Int
    private var arrivals = 0
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(target: Int) {
        self.target = target
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == target {
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor DockerPluginWireGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func arriveAndWait() async {
        arrived = true
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private func dockerPluginWireSocketPair() throws -> (
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

private let dockerPluginWireContainerID = String(repeating: "a", count: 64)
private let dockerPluginWireProviderID = "io.container.logging.plugin.example"

private func dockerPluginWireWriterRequest() throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: 1,
        idempotencyKey: "plugin-writer-operation",
        semanticRequestDigest: "sha256:writer",
        sessionID: "plugin-writer-session",
        containerID: dockerPluginWireContainerID,
        leaseGeneration: 2,
        candidateProcessGeneration: 4,
        providerID: dockerPluginWireProviderID,
        providerGeneration: 7,
        candidateSandboxGeneration: 9
    )
}

private func dockerPluginWireReaderRequest() throws
    -> LogDriverReaderOpenRequestV1
{
    try LogDriverReaderOpenRequestV1(
        operationGeneration: 3,
        idempotencyKey: "plugin-reader-operation",
        semanticRequestDigest: "sha256:reader",
        readerSessionID: "plugin-reader-session",
        containerID: dockerPluginWireContainerID,
        leaseGeneration: 2,
        providerID: dockerPluginWireProviderID,
        providerGeneration: 7,
        source: .stoppedContainer,
        read: ContainerLogReadRequest(tail: 10)
    )
}

private func dockerPluginWireHistoryMigrationRequest() throws
    -> LogDriverHistoryMigrationRequestV1
{
    try LogDriverHistoryMigrationRequestV1(
        containerID: dockerPluginWireContainerID,
        sourceLeaseGeneration: 2,
        targetLeaseGeneration: 3,
        providerID: dockerPluginWireProviderID,
        sourceProviderGeneration: 6,
        targetProviderGeneration: 7,
        contractDigest: "sha256:plugin-contract",
        terminalHistoryDigest: "sha256:terminal-history"
    )
}

private func dockerPluginWireInfo() throws -> DockerPluginInfo {
    try DockerPluginInfo(
        config: ["key": "value"],
        containerID: dockerPluginWireContainerID,
        containerName: "/service",
        containerEntrypoint: "/bin/service",
        containerArgs: ["--flag"],
        containerImageID: "sha256:image",
        containerImageName: "example:latest",
        containerCreated: Date(timeIntervalSince1970: 2),
        containerEnv: ["SECRET=value"],
        containerLabels: ["label": "value"],
        logPath: "",
        daemonName: "container"
    )
}

private func dockerPluginWireRecord(
    payload: Data,
    sequence: UInt64 = 1
) throws
    -> ContainerLogRecordV2
{
    try ContainerLogRecordV2(
        stream: .stdout,
        observation: ContainerLogObservation(
            wallClock: ContainerLogTimestamp(
                secondsSinceUnixEpoch: 2,
                nanoseconds: 3
            ),
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: nil,
        sequence: sequence,
        processGeneration: 4
    )
}
