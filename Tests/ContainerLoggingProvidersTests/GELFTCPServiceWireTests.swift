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

@Suite(.serialized)
struct GELFTCPServiceWireTests {
    @Test func serviceClientRelaysTheExactTCPFrameWithoutReplay() async throws {
        let handles = try gelfServiceWireSocketPair()
        let connector = GELFServiceWireSocketConnector(handles: [handles.client])
        let client = GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
        let expectedFrame = Data([0x7b, 0x7d, 0x00, 0xff])
        let server = Task.detached {
            defer { try? handles.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: handles.server
            )
            let write = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.write(
                    operationID: write.operationID,
                    writtenBytes: try #require(write.frame?.count)
                ),
                to: handles.server
            )
            let close = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: close.operationID
                ),
                to: handles.server
            )
            return (open, write, close)
        }

        let transport = try await client.connect(
            to: GELFNetworkAddress(host: "host.docker.internal", port: "12201"),
            timeout: .seconds(1)
        )
        #expect(try await transport.write(expectedFrame, timeout: .seconds(1)) == expectedFrame.count)
        try await transport.close(timeout: .seconds(1))

        let requests = try await server.value
        #expect(requests.0.operation == .open)
        #expect(requests.0.endpoint?.host == "host.docker.internal")
        #expect(requests.1.operation == .write)
        #expect(requests.1.frame == expectedFrame)
        #expect(requests.2.operation == .close)
        #expect(await connector.connectionCount == 1)
    }

    @Test func serviceClientDoesNotReplayAVSOCKWriteFailure() async throws {
        let handles = try gelfServiceWireSocketPair()
        let connector = GELFServiceWireSocketConnector(handles: [handles.client])
        let client = GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
        let server = Task.detached {
            defer { try? handles.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: handles.server
            )
        }

        let transport = try await client.connect(
            to: GELFNetworkAddress(host: "127.0.0.1", port: "12201"),
            timeout: .seconds(1)
        )
        try await server.value
        await #expect(throws: GELFProviderError.transportClosed) {
            _ = try await transport.write(Data([0x7b, 0x7d, 0x00]), timeout: .seconds(1))
        }
        #expect(await connector.connectionCount == 1)
    }

    @Test func serviceClientFailsClosedOnAPartialServiceWriteReceipt() async throws {
        let handles = try gelfServiceWireSocketPair()
        let connector = GELFServiceWireSocketConnector(handles: [handles.client])
        let client = GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
        let frame = Data([0x7b, 0x7d, 0x00])
        let server = Task.detached {
            defer { try? handles.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: handles.server
            )
            let write = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.write(
                    operationID: write.operationID,
                    writtenBytes: frame.count - 1
                ),
                to: handles.server
            )
        }

        let transport = try await client.connect(
            to: GELFNetworkAddress(host: "host.docker.internal", port: "12201"),
            timeout: .seconds(1)
        )
        await #expect(throws: GELFProviderError.transportClosed) {
            _ = try await transport.write(frame, timeout: .seconds(1))
        }
        try await server.value
        #expect(await connector.connectionCount == 1)
    }

    @Test func serviceClientMapsServiceTimeoutsWithoutNativeFallback() async throws {
        let openHandles = try gelfServiceWireSocketPair()
        let openConnector = GELFServiceWireSocketConnector(handles: [openHandles.client])
        let openClient = GELFTCPServiceWireClientV1 {
            try await openConnector.connect()
        }
        let openServer = Task.detached {
            defer { try? openHandles.server.close() }
            let request = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: openHandles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.failure(
                    operationID: request.operationID,
                    failure: .timedOut
                ),
                to: openHandles.server
            )
        }
        await #expect(throws: GELFProviderError.connectionTimedOut) {
            _ = try await openClient.connect(
                to: GELFNetworkAddress(host: "host.docker.internal", port: "12201"),
                timeout: .seconds(1)
            )
        }
        try await openServer.value

        let writeHandles = try gelfServiceWireSocketPair()
        let writeConnector = GELFServiceWireSocketConnector(handles: [writeHandles.client])
        let writeClient = GELFTCPServiceWireClientV1 {
            try await writeConnector.connect()
        }
        let writeServer = Task.detached {
            defer { try? writeHandles.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: writeHandles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: writeHandles.server
            )
            let write = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: writeHandles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.failure(
                    operationID: write.operationID,
                    failure: .timedOut
                ),
                to: writeHandles.server
            )
        }
        let transport = try await writeClient.connect(
            to: GELFNetworkAddress(host: "127.0.0.1", port: "12201"),
            timeout: .seconds(1)
        )
        await #expect(throws: GELFProviderError.writeTimedOut) {
            _ = try await transport.write(Data("delayed-write".utf8), timeout: .seconds(1))
        }
        try await writeServer.value
        #expect(await openConnector.connectionCount == 1)
        #expect(await writeConnector.connectionCount == 1)
    }

    @Test func serviceClientMapsServiceOpenFailureToEndpointDiagnostic()
        async throws
    {
        let handles = try gelfServiceWireSocketPair()
        let connector = GELFServiceWireSocketConnector(handles: [handles.client])
        let client = GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
        let address = GELFNetworkAddress(
            host: "host.docker.internal",
            port: "12201"
        )
        let server = Task.detached {
            defer { try? handles.server.close() }
            let request = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: handles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.failure(
                    operationID: request.operationID,
                    failure: .connectionFailed
                ),
                to: handles.server
            )
        }

        await #expect(
            throws: GELFProviderError.connectionFailed(
                endpoint: address,
                reason: "Engine-Linux GELF service could not connect"
            )
        ) {
            _ = try await client.connect(to: address, timeout: .seconds(1))
        }
        try await server.value
        #expect(await connector.connectionCount == 1)
    }

    @Test func serviceClientPreservesTypedBootstrapFailuresAsEndpointDiagnostics()
        async
    {
        let address = GELFNetworkAddress(
            host: "host.docker.internal",
            port: "12201"
        )
        let failures: [(GELFTCPServiceBootstrapError, String)] = [
            (
                .serviceStartFailed,
                "Engine-Linux GELF TCP service startup failed"
            ),
            (
                .serviceReadinessTimedOut,
                "Engine-Linux GELF TCP service readiness timed out"
            ),
            (
                .serviceIdentityRejected,
                "Engine-Linux GELF TCP service identity verification failed"
            ),
        ]

        for (failure, reason) in failures {
            let client = GELFTCPServiceWireClientV1 {
                throw failure
            }
            await #expect(
                throws: GELFProviderError.connectionFailed(
                    endpoint: address,
                    reason: reason
                )
            ) {
                _ = try await client.connect(to: address, timeout: .seconds(1))
            }
        }
    }

    @Test func serviceClientInvalidatesFailedWriteBeforeTheNextSession() async throws {
        let failed = try gelfServiceWireSocketPair()
        let recovered = try gelfServiceWireSocketPair()
        let connector = GELFServiceWireSocketConnector(
            handles: [failed.client, recovered.client]
        )
        let client = GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
        let address = GELFNetworkAddress(host: "host.docker.internal", port: "12201")
        let failedServer = Task.detached {
            defer { try? failed.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: failed.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: failed.server
            )
            let write = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: failed.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.failure(
                    operationID: write.operationID,
                    failure: .writeFailed
                ),
                to: failed.server
            )
        }
        let recoveredServer = Task.detached {
            defer { try? recovered.server.close() }
            let open = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: recovered.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: open.operationID
                ),
                to: recovered.server
            )
            let close = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: recovered.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: close.operationID
                ),
                to: recovered.server
            )
            return (open, close)
        }

        let first = try await client.connect(to: address, timeout: .seconds(1))
        await #expect(
            throws: GELFProviderError.connectionFailed(
                endpoint: address,
                reason: "Engine-Linux GELF service write failed"
            )
        ) {
            _ = try await first.write(Data("failed-write".utf8), timeout: .seconds(1))
        }
        try await failedServer.value

        let second = try await client.connect(to: address, timeout: .seconds(1))
        try await second.close(timeout: .seconds(1))
        let recoveredRequests = try await recoveredServer.value
        #expect(recoveredRequests.0.operation == .open)
        #expect(recoveredRequests.1.operation == .close)
        #expect(await connector.connectionCount == 2)
    }

    @Test func serviceGenerationHandshakeRejectsMismatchedReplies() async throws {
        let successHandles = try gelfServiceWireSocketPair()
        let successServer = Task.detached {
            defer { try? successHandles.server.close() }
            let request = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: successHandles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.generation(
                    operationID: request.operationID,
                    sandboxGeneration: 17
                ),
                to: successHandles.server
            )
            return request
        }
        #expect(
            try await GELFTCPServiceWireClientV1.activeSandboxGeneration(
                on: successHandles.client
            ) == 17
        )
        #expect(try await successServer.value.operation == .activeSandboxGeneration)

        let mismatchHandles = try gelfServiceWireSocketPair()
        let mismatchServer = Task.detached {
            defer { try? mismatchHandles.server.close() }
            _ = try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireRequestV1.self,
                from: mismatchHandles.server
            )
            try GELFTCPServiceFrameCodecV1.write(
                GELFTCPServiceWireResponseV1.acknowledgement(
                    operationID: UUID().uuidString.lowercased()
                ),
                to: mismatchHandles.server
            )
        }
        await #expect(throws: GELFTCPServiceWireError.invalidEnvelope) {
            _ = try await GELFTCPServiceWireClientV1.activeSandboxGeneration(
                on: mismatchHandles.client
            )
        }
        try await mismatchServer.value
    }

    @Test func wireEnvelopeRejectsInvalidAddressesAndOversizedFrames() throws {
        #expect(throws: GELFTCPServiceWireError.invalidAddress) {
            _ = try GELFTCPServiceEndpointWireV1(host: "host", port: "65536")
        }
        #expect(throws: GELFTCPServiceWireError.invalidAddress) {
            _ = try GELFTCPServiceEndpointWireV1(
                host: String(repeating: "h", count: 1_025),
                port: "12201"
            )
        }
        let oversized = Data(
            repeating: 0x61,
            count: GELFMessageEncoder.maximumEncodedMessageBytes + 1
        )
        #expect(throws: GELFTCPServiceWireError.frameTooLarge(oversized.count)) {
            _ = try GELFTCPServiceWireRequestV1.write(
                oversized,
                timeout: .seconds(1)
            )
        }
    }

    @Test func serviceFactoryUsesLinuxOnlyForTCPAndNeverFallsBack() async throws {
        let native = GELFServiceFactoryRecordingNative()
        let service = GELFServiceFactoryRecordingService()
        let factory = GELFServiceTransportFactory(
            nativeTransportFactory: native,
            tcpService: service
        )
        let udpAddress = GELFNetworkAddress(host: "127.0.0.1", port: "12201")
        let tcpAddress = GELFNetworkAddress(
            host: "host.docker.internal",
            port: "12201"
        )

        _ = try await factory.connect(
            to: .udp(udpAddress),
            timeout: .seconds(1)
        )
        _ = try await factory.connect(
            to: .tcp(tcpAddress),
            timeout: .seconds(1)
        )

        #expect(await native.endpoints == [.udp(udpAddress)])
        #expect(await service.addresses == [tcpAddress])

        let failingService = GELFServiceFactoryRecordingService(fail: true)
        let failClosedFactory = GELFServiceTransportFactory(
            nativeTransportFactory: native,
            tcpService: failingService
        )
        await #expect(throws: GELFProviderError.transportClosed) {
            _ = try await failClosedFactory.connect(
                to: .tcp(tcpAddress),
                timeout: .seconds(1)
            )
        }
        #expect(await native.endpoints == [.udp(udpAddress)])
        #expect(await failingService.addresses == [tcpAddress])
    }
}

private actor GELFServiceFactoryRecordingNative: GELFTransportFactory {
    private(set) var endpoints = [GELFEndpoint]()

    func connect(
        to endpoint: GELFEndpoint,
        timeout: Duration
    ) throws -> any GELFTransport {
        _ = timeout
        endpoints.append(endpoint)
        return GELFServiceFactoryNoopTransport()
    }
}

private actor GELFServiceFactoryRecordingService: GELFTCPService {
    private let fail: Bool
    private(set) var addresses = [GELFNetworkAddress]()

    init(fail: Bool = false) {
        self.fail = fail
    }

    func connect(
        to address: GELFNetworkAddress,
        timeout: Duration
    ) throws -> any GELFTransport {
        _ = timeout
        addresses.append(address)
        if fail {
            throw GELFProviderError.transportClosed
        }
        return GELFServiceFactoryNoopTransport()
    }
}

private actor GELFServiceFactoryNoopTransport: GELFTransport {
    func write(_ message: Data, timeout: Duration) -> Int {
        _ = timeout
        return message.count
    }

    func close(timeout: Duration) {
        _ = timeout
    }
}

private actor GELFServiceWireSocketConnector {
    private var handles: [FileHandle]
    private(set) var connectionCount = 0

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func connect() throws -> FileHandle {
        guard !handles.isEmpty else {
            throw GELFTCPServiceWireError.disconnected
        }
        connectionCount += 1
        return handles.removeFirst()
    }
}

private func gelfServiceWireSocketPair() throws -> (
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
