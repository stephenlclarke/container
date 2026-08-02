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
import NIOSSL
import Testing

@testable import ContainerLoggingProviders

@Suite(.serialized)
struct FluentdNIOTransportLoopbackTests {
    @Test func tcpWritesExactBytesAndDrainsAFragmentedAckBeforeEOF() async throws {
        try await withFluentdEventLoopGroup { group in
            let chunkID = "tcp-fragmented-ack"
            let expected = try fluentdEncodedLoopbackEvent(chunkID: chunkID)
            let capturePromise = group.next().makePromise(of: Data.self)
            let capture = FluentdLoopbackPromise(capturePromise)
            let acknowledgement = FluentdForwardAcknowledgementCodec.encode(
                chunkID: chunkID
            )
            let split = max(1, acknowledgement.count / 2)
            let handler = FluentdCaptureAndRespondHandler(
                byteCount: expected.count,
                capture: capture,
                responseFragments: [
                    Data(acknowledgement.prefix(split)),
                    Data(acknowledgement.dropFirst(split)),
                ],
                closeAfterResponse: true
            )
            defer { handler.cancel() }
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)

            let transport = try await NIOFluentdTransportFactory(
                eventLoopGroup: group
            ).connect(
                to: .tcp(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )
            try await transport.write(expected, timeout: .seconds(2))
            #expect(try await waitForFluentdFuture(capturePromise.futureResult) == expected)
            #expect(
                try await transport.readAcknowledgement(
                    timeout: .seconds(2),
                    maximumBytes: 64 * 1_024
                ) == chunkID
            )
            try await transport.close(timeout: .seconds(2))
        }
    }

    @Test func unixStreamWritesExactBytesAndCloseDeactivatesPeer() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cc-fluentd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withFluentdEventLoopGroup { group in
            let socketPath = directory.appendingPathComponent("forward.sock").path
            let expected = try fluentdEncodedLoopbackEvent(chunkID: nil)
            let capturePromise = group.next().makePromise(of: Data.self)
            let inactivePromise = group.next().makePromise(of: Void.self)
            let handler = FluentdCaptureAndRespondHandler(
                byteCount: expected.count,
                capture: FluentdLoopbackPromise(capturePromise),
                inactive: FluentdLoopbackPromise(inactivePromise)
            )
            defer { handler.cancel() }
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .bind(unixDomainSocketPath: socketPath)
            )
            defer { server.close(promise: nil) }

            let transport = try await NIOFluentdTransportFactory(
                eventLoopGroup: group
            ).connect(
                to: .unix(path: Data(socketPath.utf8)),
                timeout: .seconds(2)
            )
            try await transport.write(expected, timeout: .seconds(2))
            #expect(try await waitForFluentdFuture(capturePromise.futureResult) == expected)
            try await transport.close(timeout: .seconds(2))
            try await waitForFluentdFuture(inactivePromise.futureResult)
        }
    }

    @Test func tlsVerifiesDNSAndIPSANAndRejectsTrustAndIdentityFailures() async throws {
        let certificatePath = try fluentdFixturePath("syslog-server-cert.pem")
        let keyPath = try fluentdFixturePath("syslog-server-key.pem")
        let caPath = try fluentdFixturePath("syslog-test-ca.pem")

        try await withFluentdEventLoopGroup { group in
            let serverContext = try fluentdTLSServerContext(
                certificatePath: certificatePath,
                keyPath: keyPath
            )
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLServerHandler(context: serverContext)
                            )
                        }
                    }
                    .bind(host: "0.0.0.0", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let trustedFactory = NIOFluentdTransportFactory(
                eventLoopGroup: group,
                additionalTrustRootPaths: [caPath]
            )

            let verifiedDNS = try await trustedFactory.connect(
                to: .tls(
                    FluentdNetworkAddress(
                        host: "localhost",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )
            try await verifiedDNS.close(timeout: .seconds(2))

            // IP literals omit SNI, but NIOSSL still verifies the peer's IP SAN.
            let verifiedIP = try await trustedFactory.connect(
                to: .tls(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )
            try await verifiedIP.close(timeout: .seconds(2))

            await #expect(throws: (any Error).self) {
                try await NIOFluentdTransportFactory(eventLoopGroup: group)
                    .connect(
                        to: .tls(
                            FluentdNetworkAddress(
                                host: "localhost",
                                port: UInt16(port)
                            )
                        ),
                        timeout: .seconds(2)
                    )
            }

            await #expect(throws: (any Error).self) {
                try await trustedFactory.connect(
                    to: .tls(
                        FluentdNetworkAddress(
                            host: "127.0.0.2",
                            port: UInt16(port)
                        )
                    ),
                    timeout: .seconds(2)
                )
            }
        }
    }

    @Test func tlsIdentityUsesOnlyRequestedSANTypeAndNeverLegacyCN() throws {
        let ipOnly = try #require(
            NIOSSLCertificate.fromPEMFile(
                fluentdFixturePath("fluentd-ip-only-cert.pem")
            ).first
        )
        #expect(DockerGoTLSIdentityVerifier.matches("127.0.0.1", certificate: ipOnly))
        #expect(!DockerGoTLSIdentityVerifier.matches("localhost", certificate: ipOnly))

        let dnsOnly = try #require(
            NIOSSLCertificate.fromPEMFile(
                fluentdFixturePath("fluentd-dns-only-cert.pem")
            ).first
        )
        #expect(DockerGoTLSIdentityVerifier.matches("localhost", certificate: dnsOnly))
        #expect(!DockerGoTLSIdentityVerifier.matches("127.0.0.1", certificate: dnsOnly))

        let commonNameOnly = try #require(
            NIOSSLCertificate.fromPEMFile(
                fluentdFixturePath("fluentd-cn-only-cert.pem")
            ).first
        )
        #expect(
            !DockerGoTLSIdentityVerifier.matches(
                "localhost",
                certificate: commonNameOnly
            )
        )
    }

    @Test func tlsIdentityMatchesModernGoWildcardAndInvalidHostRules() throws {
        let certificate = try #require(
            NIOSSLCertificate.fromPEMFile(
                fluentdFixturePath("docker-go-tls-dns-vectors-cert.pem")
            ).first
        )

        #expect(
            DockerGoTLSIdentityVerifier.matches(
                "ONE.EXAMPLE.TEST",
                certificate: certificate
            )
        )
        #expect(
            DockerGoTLSIdentityVerifier.matches(
                "one.example.test.",
                certificate: certificate
            )
        )
        #expect(
            !DockerGoTLSIdentityVerifier.matches(
                "one.two.example.test",
                certificate: certificate
            )
        )
        #expect(
            DockerGoTLSIdentityVerifier.matches(
                "odd_name.example.test",
                certificate: certificate
            )
        )
        #expect(
            DockerGoTLSIdentityVerifier.matches(
                "-invalid.example.test",
                certificate: certificate
            )
        )
        // The wildcard SAN covers the certificate's legacy Common Name too;
        // the preceding common-name-only fixture proves there is no CN fallback.
        #expect(
            DockerGoTLSIdentityVerifier.matches(
                "ignored.example.test",
                certificate: certificate
            )
        )
    }

    @Test func tlsServerHostnameOmitsEveryLiteralIPAddress() {
        #expect(
            DockerGoTLSIdentityVerifier.serverHostname(for: "logs.example.test")
                == "logs.example.test"
        )
        #expect(
            DockerGoTLSIdentityVerifier.serverHostname(for: "127.0.0.1")
                == nil
        )
        #expect(
            DockerGoTLSIdentityVerifier.serverHostname(for: "[2001:db8::1]")
                == nil
        )
        #expect(
            DockerGoTLSIdentityVerifier.serverHostname(for: "fe80::1%en0")
                == nil
        )
    }

    @Test func tlsWritesExactPayloadAndDrainsFragmentedAckBeforeEOF() async throws {
        let certificatePath = try fluentdFixturePath("syslog-server-cert.pem")
        let keyPath = try fluentdFixturePath("syslog-server-key.pem")
        let caPath = try fluentdFixturePath("syslog-test-ca.pem")

        try await withFluentdEventLoopGroup { group in
            let chunkID = "tls-fragmented-ack"
            let expected = try fluentdEncodedLoopbackEvent(chunkID: chunkID)
            let capturePromise = group.next().makePromise(of: Data.self)
            let inactivePromise = group.next().makePromise(of: Void.self)
            let acknowledgement = FluentdForwardAcknowledgementCodec.encode(
                chunkID: chunkID
            )
            let split = max(1, acknowledgement.count / 2)
            let captureHandler = FluentdCaptureAndRespondHandler(
                byteCount: expected.count,
                capture: FluentdLoopbackPromise(capturePromise),
                inactive: FluentdLoopbackPromise(inactivePromise),
                responseFragments: [
                    Data(acknowledgement.prefix(split)),
                    Data(acknowledgement.dropFirst(split)),
                ],
                closeAfterResponse: true
            )
            defer { captureHandler.cancel() }
            let context = try fluentdTLSServerContext(
                certificatePath: certificatePath,
                keyPath: keyPath
            )
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLServerHandler(context: context)
                            )
                            try channel.pipeline.syncOperations.addHandler(
                                captureHandler
                            )
                        }
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let transport = try await NIOFluentdTransportFactory(
                eventLoopGroup: group,
                additionalTrustRootPaths: [caPath]
            ).connect(
                to: .tls(
                    FluentdNetworkAddress(
                        host: "localhost",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )

            try await transport.write(expected, timeout: .seconds(2))
            #expect(try await waitForFluentdFuture(capturePromise.futureResult) == expected)
            #expect(
                try await transport.readAcknowledgement(
                    timeout: .seconds(2),
                    maximumBytes: 64 * 1_024
                ) == chunkID
            )
            try await waitForFluentdFuture(inactivePromise.futureResult)
            try await transport.close(timeout: .seconds(2))
        }
    }

    @Test func tlsHandshakeUsesOnlyTheRemainingAbsoluteConnectBudget() async throws {
        try await withFluentdEventLoopGroup { group in
            let acceptedPromise = group.next().makePromise(of: Void.self)
            let accepted = FluentdLoopbackPromise(acceptedPromise)
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        accepted.complete(.success(()))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer {
                accepted.cancel()
                server.close(promise: nil)
            }
            let port = try #require(server.localAddress?.port)
            let clock = FluentdScriptedConnectClock([
                .zero,
                .zero,
                .milliseconds(950),
            ])
            let started = ContinuousClock().now

            await #expect(throws: FluentdProviderError.connectionTimedOut) {
                try await NIOFluentdTransportFactory(
                    eventLoopGroup: group,
                    clock: clock
                ).connect(
                    to: .tls(
                        FluentdNetworkAddress(
                            host: "127.0.0.1",
                            port: UInt16(port)
                        )
                    ),
                    timeout: .seconds(1)
                )
            }
            try await waitForFluentdFuture(acceptedPromise.futureResult)
            #expect(clock.callCount >= 3)
            #expect(started.duration(to: ContinuousClock().now) < .milliseconds(500))
        }
    }

    @Test func readTimeoutClosesARealLoopbackConnection() async throws {
        try await withFluentdEventLoopGroup { group in
            let expected = try fluentdEncodedLoopbackEvent(chunkID: "no-response")
            let capturePromise = group.next().makePromise(of: Data.self)
            let inactivePromise = group.next().makePromise(of: Void.self)
            let handler = FluentdCaptureAndRespondHandler(
                byteCount: expected.count,
                capture: FluentdLoopbackPromise(capturePromise),
                inactive: FluentdLoopbackPromise(inactivePromise)
            )
            defer { handler.cancel() }
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let transport = try await NIOFluentdTransportFactory(
                eventLoopGroup: group
            ).connect(
                to: .tcp(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )

            try await transport.write(expected, timeout: .seconds(2))
            #expect(try await waitForFluentdFuture(capturePromise.futureResult) == expected)
            await #expect(throws: FluentdProviderError.readTimedOut) {
                try await transport.readAcknowledgement(
                    timeout: .milliseconds(50),
                    maximumBytes: 64 * 1_024
                )
            }
            try await waitForFluentdFuture(inactivePromise.futureResult)
            try await transport.close(timeout: .seconds(2))
        }
    }

    @Test func writeTimeoutClosesARealBackpressuredTransport() async throws {
        try await withFluentdEventLoopGroup { group in
            let acceptedPromise = group.next().makePromise(of: Void.self)
            let inactivePromise = group.next().makePromise(of: Void.self)
            let handler = FluentdInactiveHandler(
                accepted: FluentdLoopbackPromise(acceptedPromise),
                inactive: FluentdLoopbackPromise(inactivePromise)
            )
            defer { handler.cancel() }
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelOption(ChannelOptions.autoRead, value: false)
                    .childChannelOption(
                        ChannelOptions.socketOption(.so_rcvbuf),
                        value: 1_024
                    )
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let transport = try await NIOFluentdTransportFactory(
                eventLoopGroup: group
            ).connect(
                to: .tcp(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: UInt16(port)
                    )
                ),
                timeout: .seconds(2)
            )
            try await waitForFluentdFuture(acceptedPromise.futureResult)

            await #expect(throws: FluentdProviderError.writeTimedOut) {
                try await transport.write(
                    Data(repeating: 0x41, count: 8 * 1_024 * 1_024),
                    timeout: .milliseconds(50)
                )
            }
            await #expect(throws: FluentdProviderError.transportClosed) {
                try await transport.write(Data(), timeout: .seconds(1))
            }
            try await transport.close(timeout: .seconds(2))
        }
    }

    @Test func endOfFileReconnectsAndResendsIdenticalForwardEvent() async throws {
        try await withFluentdEventLoopGroup { group in
            let chunkID = "reconnect-after-eof"
            let endpointAddress = FluentdNetworkAddress(
                host: "127.0.0.1",
                port: 0
            )
            let provisional = try fluentdTestConfiguration(
                endpoint: .tcp(endpointAddress),
                maximumRetries: 2,
                retryWait: .zero,
                requestAcknowledgement: true,
                readTimeout: .seconds(1),
                writeTimeout: .seconds(1)
            )
            let record = try fluentdRecord(payload: Data("retry-wire".utf8))
            let expected = try FluentdForwardMessageEncoder(
                configuration: provisional,
                chunkIDGenerator: FixedFluentdChunkIDGenerator(chunkID: chunkID)
            ).encode(record).bytes
            let capturesPromise = group.next().makePromise(of: [Data].self)
            let state = FluentdReconnectServerState(
                byteCount: expected.count,
                acknowledgement: FluentdForwardAcknowledgementCodec.encode(
                    chunkID: chunkID
                ),
                captures: FluentdLoopbackPromise(capturesPromise)
            )
            defer { state.cancel() }
            let server = try await waitForFluentdFuture(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        let handler = state.makeHandler()
                        return channel.pipeline.addHandler(handler)
                    }
                    .bind(host: "127.0.0.1", port: 0)
            )
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let configuration = try fluentdTestConfiguration(
                endpoint: .tcp(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: UInt16(port)
                    )
                ),
                maximumRetries: 2,
                retryWait: .zero,
                requestAcknowledgement: true,
                readTimeout: .seconds(1),
                writeTimeout: .seconds(1)
            )
            let session = try await FluentdDriverSession(
                configuration: configuration,
                transportFactory: NIOFluentdTransportFactory(eventLoopGroup: group),
                chunkIDGenerator: FixedFluentdChunkIDGenerator(chunkID: chunkID)
            )

            try await session.write(record)
            let captures = try await waitForFluentdFuture(
                capturesPromise.futureResult
            )
            #expect(captures == [expected, expected])
            try await session.closeUsingPolicy()
        }
    }
}

private func fluentdEncodedLoopbackEvent(chunkID: String?) throws -> Data {
    let configuration = try fluentdTestConfiguration(
        maximumRetries: 2,
        requestAcknowledgement: chunkID != nil
    )
    let generator = FixedFluentdChunkIDGenerator(
        chunkID: chunkID ?? "unused"
    )
    return try FluentdForwardMessageEncoder(
        configuration: configuration,
        chunkIDGenerator: generator
    ).encode(
        fluentdRecord(payload: Data("loopback-wire".utf8))
    ).bytes
}

private func fluentdFixturePath(_ name: String) throws -> String {
    try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        )?.path
    )
}

private func fluentdTLSServerContext(
    certificatePath: String,
    keyPath: String
) throws -> NIOSSLContext {
    let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
    let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
    let configuration = TLSConfiguration.makeServerConfiguration(
        certificateChain: certificates.map { .certificate($0) },
        privateKey: .privateKey(key)
    )
    return try NIOSSLContext(configuration: configuration)
}

private final class FluentdScriptedConnectClock: FluentdClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [Duration]
    private var index = 0

    init(_ values: [Duration]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func now() -> Duration {
        lock.withLock {
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private final class FluentdLoopbackPromise<Value: Sendable>: @unchecked Sendable {
    private let promise: EventLoopPromise<Value>
    private let lock = NSLock()
    private var completed = false

    init(_ promise: EventLoopPromise<Value>) {
        self.promise = promise
    }

    func complete(_ result: Result<Value, any Error>) {
        let shouldComplete = lock.withLock {
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

    func cancel() {
        complete(.failure(FluentdTestFailure.exhausted))
    }
}

private final class FluentdCaptureAndRespondHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let byteCount: Int
    private let capture: FluentdLoopbackPromise<Data>
    private let inactive: FluentdLoopbackPromise<Void>?
    private let responseFragments: [Data]
    private let closeAfterResponse: Bool
    private var bytes = [UInt8]()
    private var responded = false

    init(
        byteCount: Int,
        capture: FluentdLoopbackPromise<Data>,
        inactive: FluentdLoopbackPromise<Void>? = nil,
        responseFragments: [Data] = [],
        closeAfterResponse: Bool = false
    ) {
        self.byteCount = byteCount
        self.capture = capture
        self.inactive = inactive
        self.responseFragments = responseFragments
        self.closeAfterResponse = closeAfterResponse
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes.append(
            contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? []
        )
        guard bytes.count >= byteCount, !responded else {
            return
        }
        responded = true
        capture.complete(.success(Data(bytes)))

        let channel = context.channel
        var response = context.eventLoop.makeSucceededVoidFuture()
        for fragment in responseFragments {
            response = response.flatMap {
                var buffer = channel.allocator.buffer(
                    capacity: fragment.count
                )
                buffer.writeBytes(fragment)
                return channel.writeAndFlush(buffer)
            }
        }
        if closeAfterResponse {
            response.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        capture.complete(.failure(error))
        inactive?.complete(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inactive?.complete(.success(()))
        context.fireChannelInactive()
    }

    func cancel() {
        capture.cancel()
        inactive?.cancel()
    }
}

private final class FluentdInactiveHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let accepted: FluentdLoopbackPromise<Void>
    private let inactive: FluentdLoopbackPromise<Void>
    private let lock = NSLock()
    private var channel: (any Channel)?

    init(
        accepted: FluentdLoopbackPromise<Void>,
        inactive: FluentdLoopbackPromise<Void>
    ) {
        self.accepted = accepted
        self.inactive = inactive
    }

    func channelActive(context: ChannelHandlerContext) {
        lock.withLock { channel = context.channel }
        accepted.complete(.success(()))
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        inactive.complete(.success(()))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        inactive.complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        let activeChannel: (any Channel)? = lock.withLock {
            let value = channel
            self.channel = nil
            return value
        }
        activeChannel?.close(promise: nil)
        accepted.cancel()
        inactive.cancel()
    }
}

private final class FluentdReconnectServerState: @unchecked Sendable {
    let byteCount: Int
    let acknowledgement: Data

    private let lock = NSLock()
    private let capturesPromise: FluentdLoopbackPromise<[Data]>
    private var connectionCount = 0
    private var captures = [Data]()

    init(
        byteCount: Int,
        acknowledgement: Data,
        captures: FluentdLoopbackPromise<[Data]>
    ) {
        self.byteCount = byteCount
        self.acknowledgement = acknowledgement
        self.capturesPromise = captures
    }

    func makeHandler() -> FluentdReconnectHandler {
        let ordinal = lock.withLock {
            connectionCount += 1
            return connectionCount
        }
        return FluentdReconnectHandler(ordinal: ordinal, state: self)
    }

    func record(_ data: Data) {
        let completedCaptures = lock.withLock { () -> [Data]? in
            captures.append(data)
            return captures.count == 2 ? captures : nil
        }
        if let completedCaptures {
            capturesPromise.complete(.success(completedCaptures))
        }
    }

    func cancel() {
        capturesPromise.cancel()
    }
}

private final class FluentdReconnectHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let ordinal: Int
    private let state: FluentdReconnectServerState
    private var bytes = [UInt8]()
    private var responded = false

    init(ordinal: Int, state: FluentdReconnectServerState) {
        self.ordinal = ordinal
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes.append(
            contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? []
        )
        guard bytes.count >= state.byteCount, !responded else {
            return
        }
        responded = true
        state.record(Data(bytes))
        if ordinal == 1 {
            context.close(promise: nil)
            return
        }
        var response = context.channel.allocator.buffer(
            capacity: state.acknowledgement.count
        )
        response.writeBytes(state.acknowledgement)
        context.channel.writeAndFlush(response, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
