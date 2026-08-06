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

import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ContainerLoggingProviders

@Suite(.serialized)
struct GELFTransportLoopbackTests {
    @Test func productionUDPTransportSendsIndependentGoldenDatagram() async throws {
        try await withGELFEventLoopGroup { group in
            try await withGELFUDPServer(group: group, expectedDatagrams: 1) {
                port,
                captured in
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .udp(
                        GELFNetworkAddress(host: "127.0.0.1", port: String(port))
                    )
                )
                do {
                    try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                    let datagrams = try await gelfTestBoundedValue(captured)
                    #expect(datagrams == [gelfLoopbackGoldenJSON])
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
            }
        }
    }

    @Test func productionUDPCompressionRoundTripsIndependentGolden() async throws {
        try await withGELFEventLoopGroup { group in
            for compression in [GELFCompressionType.gzip, .zlib] {
                try await withGELFUDPServer(group: group, expectedDatagrams: 1) {
                    port,
                    captured in
                    let session = try await makeGELFLoopbackSession(
                        group: group,
                        endpoint: .udp(
                            GELFNetworkAddress(host: "127.0.0.1", port: String(port))
                        ),
                        compressionType: compression
                    )
                    do {
                        try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                        let datagrams = try await gelfTestBoundedValue(captured)
                        let payload = try #require(datagrams.gelfOnly)
                        switch compression {
                        case .gzip:
                            #expect(payload.starts(with: [0x1f, 0x8b]))
                            #expect(
                                try gelfInflate(payload, windowBits: 15 + 16)
                                    == gelfLoopbackGoldenJSON
                            )
                        case .zlib:
                            #expect(payload.first == 0x78)
                            #expect(
                                try gelfInflate(payload, windowBits: 15)
                                    == gelfLoopbackGoldenJSON
                            )
                        case .none:
                            Issue.record("compression loop used the uncompressed domain")
                        }
                        try await session.closeUsingPolicy()
                    } catch {
                        try? await session.closeUsingPolicy()
                        throw error
                    }
                }
            }
        }
    }

    @Test func productionUDPChunksCarryGoldenHeadersAndReassemble() async throws {
        try await withGELFEventLoopGroup { group in
            let payload = String(repeating: "x", count: 3_000)
            var golden = Data(
                #"{"version":"1.1","host":"test-host","short_message":""#.utf8
            )
            golden.append(contentsOf: payload.utf8)
            golden.append(
                contentsOf:
                    #"","timestamp":1.234,"level":6,"_command":"/bin/server --listen :8080","_container_id":"container-id","_container_name":"web","_created":"1970-01-01T00:00:01.25Z","_image_id":"sha256:image-id","_image_name":"example/web:latest","_tag":"0123456789ab"}"#
                    .utf8
            )
            #expect(golden.count > 2 * GELFDatagramEncoder.chunkDataBytes)
            #expect(golden.count < 3 * GELFDatagramEncoder.chunkDataBytes)
            let goldenJSON = golden
            let chunkID = Data([0, 1, 2, 3, 4, 5, 6, 7])

            try await withGELFUDPServer(group: group, expectedDatagrams: 3) {
                port,
                captured in
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .udp(
                        GELFNetworkAddress(host: "127.0.0.1", port: String(port))
                    ),
                    chunkIDGenerator: FixedGELFChunkIDGenerator(bytes: chunkID)
                )
                do {
                    try await session.write(
                        gelfRecord(payload: Data(payload.utf8))
                    )
                    let datagrams = try await gelfTestBoundedValue(captured)
                    #expect(datagrams.count == 3)
                    for (sequence, datagram) in datagrams.enumerated() {
                        #expect(datagram.prefix(2) == Data([0x1e, 0x0f]))
                        #expect(datagram[2..<10] == chunkID)
                        #expect(datagram[10] == UInt8(sequence))
                        #expect(datagram[11] == 3)
                    }
                    let reassembled = datagrams.reduce(into: Data()) { result, datagram in
                        result.append(
                            datagram.dropFirst(GELFDatagramEncoder.chunkHeaderBytes)
                        )
                    }
                    #expect(reassembled == goldenJSON)
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
            }
        }
    }

    @Test func productionTCPTransportSendsIndependentGoldenNULFrame() async throws {
        try await withGELFEventLoopGroup { group in
            try await withGELFTCPServer(group: group) { port, captured in
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .tcp(
                        GELFNetworkAddress(host: "127.0.0.1", port: String(port))
                    )
                )
                do {
                    try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                    let frame = try await gelfTestBoundedValue(captured)
                    var golden = gelfLoopbackGoldenJSON
                    golden.append(0)
                    #expect(frame == golden)
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
            }
        }
    }

    @Test func productionDockerHostAliasRoutesTCPAndUDPToNativeLoopback() async throws {
        try await withGELFEventLoopGroup { group in
            try await withGELFUDPServer(group: group, expectedDatagrams: 1) {
                port,
                captured in
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .udp(
                        GELFNetworkAddress(host: "HOST.DOCKER.INTERNAL", port: String(port))
                    )
                )
                do {
                    try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                    #expect(try await gelfTestBoundedValue(captured) == [gelfLoopbackGoldenJSON])
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
            }

            try await withGELFTCPServer(group: group) { port, captured in
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .tcp(
                        GELFNetworkAddress(host: "host.docker.internal", port: String(port))
                    )
                )
                do {
                    try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                    var golden = gelfLoopbackGoldenJSON
                    golden.append(0)
                    #expect(try await gelfTestBoundedValue(captured) == golden)
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
            }
        }
    }

    @Test func productionTCPEOFReconnectsAndResendsSameGoldenFrame() async throws {
        try await withGELFEventLoopGroup { group in
            let framePromise = group.next().makePromise(of: Data.self)
            let frameCapture = GELFNULFrameCaptureHandler(promise: framePromise)
            let router = GELFTCPReconnectRouter(
                firstConnectionReady: group.next().makePromise(of: Void.self),
                subsequentHandler: frameCapture
            )
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    router.initialize(channel)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            do {
                let port = try #require(server.localAddress?.port)
                let session = try await makeGELFLoopbackSession(
                    group: group,
                    endpoint: .tcp(
                        GELFNetworkAddress(host: "127.0.0.1", port: String(port))
                    ),
                    maximumReconnects: 1,
                    reconnectDelay: .zero
                )
                do {
                    _ = try await gelfTestBoundedValue(router.firstConnectionReady)
                    try await router.closeFirstConnection()
                    try await Task.sleep(for: .milliseconds(20))

                    try await session.write(gelfRecord(payload: Data("loopback".utf8)))
                    let frame = try await gelfTestBoundedValue(framePromise.futureResult)
                    var golden = gelfLoopbackGoldenJSON
                    golden.append(0)
                    #expect(frame == golden)
                    #expect(router.connectionCount == 2)
                    try await session.closeUsingPolicy()
                } catch {
                    try? await session.closeUsingPolicy()
                    throw error
                }
                try await server.close().get()
                frameCapture.cancel()
            } catch {
                frameCapture.cancel()
                try? await server.close().get()
                throw error
            }
        }
    }

    @Test func productionConnectDeadlineCleansUpLateSuccessExactlyOnce() async throws {
        try await withGELFEventLoopGroup { group in
            let source = group.next().makePromise(of: Int.self)
            let lateValue = group.next().makePromise(of: Int.self)
            let bounded = source.futureResult.gelfConnectBounded(
                by: .milliseconds(10)
            ) { value in
                lateValue.succeed(value)
            }

            await #expect(throws: GELFProviderError.connectionTimedOut) {
                try await bounded.get()
            }
            source.succeed(42)
            let observedLateValue = try await gelfTestBoundedValue(
                lateValue.futureResult
            )
            #expect(observedLateValue == 42)
        }
    }

    @Test func productionTCPConnectionFailurePreservesConfiguredEndpoint() async throws {
        try await withGELFEventLoopGroup { group in
            let server = try await ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            try await server.close().get()

            let endpoint = GELFNetworkAddress(
                host: "host.docker.internal",
                port: String(port)
            )
            do {
                _ = try await NIOGELFTransportFactory(eventLoopGroup: group).connect(
                    to: .tcp(endpoint),
                    timeout: .seconds(1)
                )
                Issue.record("expected a refused TCP GELF connection")
            } catch let error as GELFProviderError {
                guard case let .connectionFailed(actualEndpoint, reason) = error else {
                    Issue.record("unexpected GELF connection error: \(error)")
                    return
                }
                #expect(actualEndpoint == endpoint)
                #expect(reason.localizedCaseInsensitiveContains("connection refused"))
            }
        }
    }

    @Test func productionFactoryRejectsServiceSignedAndEncodedPortsWithoutLookup() async throws {
        try await withGELFEventLoopGroup { group in
            let factory = NIOGELFTransportFactory(eventLoopGroup: group)
            for port in ["syslog", "+12201", "-1", "%31%32%32%30%31"] {
                await #expect(
                    throws: GELFProviderError.malformedAddress("invalid decimal port")
                ) {
                    try await factory.connect(
                        to: .udp(
                            GELFNetworkAddress(host: "127.0.0.1", port: port)
                        ),
                        timeout: .milliseconds(10)
                    )
                }
            }
        }
    }
}

private let gelfLoopbackGoldenJSON = Data(
    #"{"version":"1.1","host":"test-host","short_message":"loopback","timestamp":1.234,"level":6,"_command":"/bin/server --listen :8080","_container_id":"container-id","_container_name":"web","_created":"1970-01-01T00:00:01.25Z","_image_id":"sha256:image-id","_image_name":"example/web:latest","_tag":"0123456789ab"}"#
        .utf8
)

private func makeGELFLoopbackSession(
    group: MultiThreadedEventLoopGroup,
    endpoint: GELFEndpoint,
    compressionType: GELFCompressionType = .none,
    maximumReconnects: Int = 3,
    reconnectDelay: Duration = .milliseconds(10),
    chunkIDGenerator: any GELFChunkIDGenerating = FixedGELFChunkIDGenerator(
        bytes: Data(repeating: 0xa5, count: 8)
    )
) async throws -> GELFDriverSession {
    try await GELFDriverSession(
        configuration: gelfTestConfiguration(
            endpoint: endpoint,
            compressionType: compressionType,
            maximumReconnects: maximumReconnects,
            reconnectDelay: reconnectDelay,
            policy: GELFConnectionPolicy(
                connectTimeout: .seconds(1),
                writeTimeout: .seconds(1),
                closeTimeout: .seconds(1)
            )
        ),
        transportFactory: NIOGELFTransportFactory(eventLoopGroup: group),
        chunkIDGenerator: chunkIDGenerator
    )
}

private func gelfTestBoundedValue<Value: Sendable>(
    _ future: EventLoopFuture<Value>,
    timeout: Duration = .seconds(2)
) async throws -> Value {
    try await future.gelfConnectBounded(by: timeout) { _ in }.get()
}

private func withGELFUDPServer<Result: Sendable>(
    group: MultiThreadedEventLoopGroup,
    expectedDatagrams: Int,
    _ body: @escaping @Sendable (Int, EventLoopFuture<[Data]>) async throws -> Result
) async throws -> Result {
    let promise = group.next().makePromise(of: [Data].self)
    let capture = GELFDatagramCaptureHandler(
        expectedDatagrams: expectedDatagrams,
        promise: promise
    )
    let server = try await DatagramBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(capture)
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    do {
        let port = try #require(server.localAddress?.port)
        let result = try await body(port, promise.futureResult)
        try await server.close().get()
        capture.cancel()
        return result
    } catch {
        capture.cancel()
        try? await server.close().get()
        throw error
    }
}

private func withGELFTCPServer<Result: Sendable>(
    group: MultiThreadedEventLoopGroup,
    _ body: @escaping @Sendable (Int, EventLoopFuture<Data>) async throws -> Result
) async throws -> Result {
    let promise = group.next().makePromise(of: Data.self)
    let capture = GELFNULFrameCaptureHandler(promise: promise)
    let server = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(capture)
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    do {
        let port = try #require(server.localAddress?.port)
        let result = try await body(port, promise.futureResult)
        try await server.close().get()
        capture.cancel()
        return result
    } catch {
        capture.cancel()
        try? await server.close().get()
        throw error
    }
}

private final class GELFDatagramCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let expectedDatagrams: Int
    private let promise: EventLoopPromise<[Data]>
    private let completionLock = NSLock()
    private var datagrams = [Data]()
    private var completed = false

    init(expectedDatagrams: Int, promise: EventLoopPromise<[Data]>) {
        self.expectedDatagrams = expectedDatagrams
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        let bytes = envelope.data.readBytes(length: envelope.data.readableBytes) ?? []
        datagrams.append(Data(bytes))
        if datagrams.count == expectedDatagrams {
            complete(.success(datagrams))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(GELFTestFailure.exhausted))
    }

    private func complete(_ result: Result<[Data], any Error>) {
        let shouldComplete = completionLock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
        if shouldComplete {
            promise.completeWith(result)
        }
    }
}

private final class GELFNULFrameCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Data>
    private var bytes = [UInt8]()
    private let completionLock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let received = buffer.readBytes(length: buffer.readableBytes) {
            bytes.append(contentsOf: received)
        }
        if let terminator = bytes.firstIndex(of: 0) {
            complete(.success(Data(bytes[...terminator])))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(GELFTestFailure.exhausted))
    }

    private func complete(_ result: Result<Data, any Error>) {
        let shouldComplete = completionLock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
        if shouldComplete {
            promise.completeWith(result)
        }
    }
}

private final class GELFTCPReconnectRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadyPromise: EventLoopPromise<Void>
    private let subsequentHandler: GELFNULFrameCaptureHandler
    private var firstChannel: (any Channel)?
    private var connections = 0

    init(
        firstConnectionReady: EventLoopPromise<Void>,
        subsequentHandler: GELFNULFrameCaptureHandler
    ) {
        self.firstReadyPromise = firstConnectionReady
        self.subsequentHandler = subsequentHandler
    }

    var firstConnectionReady: EventLoopFuture<Void> {
        firstReadyPromise.futureResult
    }

    var connectionCount: Int {
        lock.withLock { connections }
    }

    func initialize(_ channel: any Channel) -> EventLoopFuture<Void> {
        let ordinal = lock.withLock {
            connections += 1
            if connections == 1 {
                firstChannel = channel
            }
            return connections
        }
        if ordinal == 1 {
            firstReadyPromise.succeed(())
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        return channel.pipeline.addHandler(subsequentHandler)
    }

    func closeFirstConnection() async throws {
        let channel = try #require(lock.withLock { firstChannel })
        try await channel.close().get()
    }
}
