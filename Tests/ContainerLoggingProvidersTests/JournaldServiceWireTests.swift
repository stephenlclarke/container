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

struct JournaldServiceWireTests {
    @Test func binaryEntryAndExplicitReaderEventRoundTrip() throws {
        let entry = try journaldWireEntry(
            message: Data([0x00, 0xff, 0x0a])
        )
        let request = try JournaldServiceWireRequestV1.write(
            sessionID: "writer-session",
            entry: entry
        )

        let requestData = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            JournaldServiceWireRequestV1.self,
            from: requestData
        )
        #expect(decoded == request)
        #expect(try decoded.entry?.entry() == entry)

        let response = try JournaldServiceWireResponseV1.reader(
            operationID: request.operationID,
            event: .endOfStream
        )
        let responseData = try JSONEncoder().encode(response)
        let responseJSON = try #require(
            String(data: responseData, encoding: .utf8)
        )
        #expect(responseJSON.contains("\"kind\":\"endOfStream\""))
        #expect(!responseJSON.contains("\"record\""))
        #expect(
            try JSONDecoder().decode(
                JournaldServiceWireResponseV1.self,
                from: responseData
            ) == response
        )
    }

    @Test func entryAndFrameLimitsFailClosed() throws {
        let oversized = try journaldWireEntry(
            message: Data(
                repeating: 0x61,
                count: 512 * 1_024 + 1
            )
        )
        do {
            _ = try JournaldServiceWireRequestV1.write(
                sessionID: "writer-session",
                entry: oversized
            )
            Issue.record("oversized journal message was accepted")
        } catch let error as JournaldServiceWireError {
            #expect(error == .frameTooLarge(512 * 1_024 + 1))
        }

        let handles = try journaldWireSocketPair()
        defer {
            try? handles.client.close()
            try? handles.server.close()
        }
        do {
            try JournaldServiceFrameCodecV1.write(
                Data(
                    repeating: 0x61,
                    count: JournaldServiceFrameCodecV1.maximumFrameBytes
                ),
                to: handles.client
            )
            Issue.record("oversized encoded frame was accepted")
        } catch let error as JournaldServiceWireError {
            guard case .frameTooLarge(let bytes) = error else {
                Issue.record("unexpected wire error: \(error)")
                return
            }
            #expect(bytes > JournaldServiceFrameCodecV1.maximumFrameBytes)
        }
    }

    @Test func clientProjectsLifecycleAndReaderOrdinals() async throws {
        let transport = JournaldWireRecordingTransport()
        let client = JournaldServiceWireClientV1(transport: transport)

        #expect(try await client.activeSandboxGeneration() == 9)
        try await client.openWriter(journaldWireWriterOpen())
        try await client.write(
            sessionID: "writer-session",
            entry: journaldWireEntry()
        )
        try await client.flushWriter(
            sessionID: "writer-session",
            deadline: ContinuousClock().now.advanced(by: .seconds(1))
        )
        try await client.closeWriter(
            sessionID: "writer-session",
            fenced: true,
            deadline: ContinuousClock().now.advanced(by: .seconds(1))
        )

        let reader = try await client.openReader(journaldWireReaderOpen())
        let expectedRecord = try journaldWireReadRecord()
        #expect(try await reader.next() == .record(expectedRecord))
        #expect(try await reader.next() == .endOfStream)

        let requests = await transport.requests()
        #expect(
            requests.map(\.operation) == [
                .activeSandboxGeneration,
                .openWriter,
                .write,
                .flushWriter,
                .closeWriter,
                .openReader,
                .nextReader,
                .nextReader,
            ]
        )
        #expect(
            requests.compactMap(\.readerSequence) == [1, 2]
        )
        #expect(requests[4].fenced == true)
        #expect(requests[3].timeoutNanoseconds != nil)
        #expect(requests[4].timeoutNanoseconds != nil)
    }

    @Test func responseLossReconnectsWithSameOperationID() async throws {
        let first = try journaldWireSocketPair()
        let second = try journaldWireSocketPair()
        let connector = JournaldWireSocketConnector(
            handles: [first.client, second.client]
        )
        let transport = JournaldServiceFileHandleTransportV1 {
            try await connector.connect()
        }
        let request = try JournaldServiceWireRequestV1.nextReader(
            sessionID: "reader-session",
            readerSequence: 41
        )

        let firstServer = Task.detached {
            defer { try? first.server.close() }
            return try JournaldServiceFrameCodecV1.read(
                JournaldServiceWireRequestV1.self,
                from: first.server
            )
        }
        let secondServer = Task.detached {
            defer { try? second.server.close() }
            let replay = try JournaldServiceFrameCodecV1.read(
                JournaldServiceWireRequestV1.self,
                from: second.server
            )
            try JournaldServiceFrameCodecV1.write(
                JournaldServiceWireResponseV1.reader(
                    operationID: replay.operationID,
                    event: .endOfStream
                ),
                to: second.server
            )
            return replay
        }

        let response = try await transport.call(request)
        let firstAttempt = try await firstServer.value
        let replay = try await secondServer.value
        await transport.close()

        #expect(response.readerEvent == .endOfStream)
        #expect(firstAttempt.operationID == request.operationID)
        #expect(replay.operationID == request.operationID)
        #expect(replay.readerSequence == 41)
        #expect(firstAttempt == replay)
        #expect(await connector.connectionCount == 2)
    }

    @Test func cancellationInterruptsOutstandingReadWithoutReconnect() async throws {
        let pair = try journaldWireSocketPair()
        let connector = JournaldWireSocketConnector(handles: [pair.client])
        let transport = JournaldServiceFileHandleTransportV1 {
            try await connector.connect()
        }
        let request = try JournaldServiceWireRequestV1.nextReader(
            sessionID: "reader-session",
            readerSequence: 1
        )
        let server = Task.detached {
            defer { try? pair.server.close() }
            return try JournaldServiceFrameCodecV1.read(
                JournaldServiceWireRequestV1.self,
                from: pair.server
            )
        }
        let call = Task {
            try await transport.call(request)
        }

        #expect(try await server.value == request)
        call.cancel()
        do {
            _ = try await call.value
            Issue.record("cancelled wire call returned a response")
        } catch is CancellationError {
            // Expected: cancellation shuts down the socket before closing it.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(await connector.connectionCount == 1)
    }
}

private actor JournaldWireRecordingTransport: JournaldServiceWireTransportV1 {
    private var recorded = [JournaldServiceWireRequestV1]()

    func call(
        _ request: JournaldServiceWireRequestV1
    ) throws -> JournaldServiceWireResponseV1 {
        recorded.append(request)
        switch request.operation {
        case .activeSandboxGeneration:
            return try .generation(
                operationID: request.operationID,
                sandboxGeneration: 9
            )
        case .nextReader:
            if request.readerSequence == 1 {
                return try .reader(
                    operationID: request.operationID,
                    event: .record(
                        ContainerLogReadRecordWireV1(
                            try journaldWireReadRecord()
                        )
                    )
                )
            }
            return try .reader(
                operationID: request.operationID,
                event: .endOfStream
            )
        case .openWriter, .write, .flushWriter, .closeWriter, .openReader,
            .cancelReader:
            return try .acknowledgement(operationID: request.operationID)
        }
    }

    func requests() -> [JournaldServiceWireRequestV1] {
        recorded
    }
}

private actor JournaldWireSocketConnector {
    private var handles: [FileHandle]
    private(set) var connectionCount = 0

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func connect() throws -> FileHandle {
        guard !handles.isEmpty else {
            throw JournaldServiceWireError.disconnected
        }
        connectionCount += 1
        return handles.removeFirst()
    }
}

private func journaldWireSocketPair() throws -> (
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

private func journaldWireWriterOpen() throws -> JournaldWriterOpenRequest {
    let request = try journaldWireWriterRequest()
    return try JournaldWriterOpenRequest(
        request: request,
        configuration: journaldWireConfiguration(),
        epoch: "epoch-1"
    )
}

private func journaldWireWriterRequest() throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: 1,
        idempotencyKey: "writer-operation",
        semanticRequestDigest: "sha256:writer",
        sessionID: "writer-session",
        containerID: String(repeating: "a", count: 64),
        leaseGeneration: 2,
        candidateProcessGeneration: 4,
        providerID: JournaldLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: 9
    )
}

private func journaldWireReaderOpen() throws -> LogDriverReaderOpenRequestV1 {
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

private func journaldWireConfiguration() throws -> JournaldDriverConfiguration {
    let identifier = String(repeating: "a", count: 64)
    return try JournaldDriverConfiguration(
        containerID: identifier,
        fields: [
            JournaldField.containerID: String(identifier.prefix(12)),
            JournaldField.containerIDFull: identifier,
            JournaldField.containerTag: "service",
            JournaldField.syslogIdentifier: "service",
        ]
    )
}

private func journaldWireEntry(
    message: Data = Data("line".utf8)
) throws -> JournaldEntry {
    try JournaldEntry(
        message: message,
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

private func journaldWireReadRecord() throws -> ContainerLogReadRecordV1 {
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
