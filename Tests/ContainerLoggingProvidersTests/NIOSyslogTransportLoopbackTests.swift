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
struct NIOSyslogTransportLoopbackTests {
    @Test func pinsDockerGoConnectionsTLS12CipherSuites() {
        #expect(
            NIOSyslogTransportFactory.dockerTLS12CipherSuites == [
                "ECDHE-ECDSA-AES256-GCM-SHA384",
                "ECDHE-RSA-AES256-GCM-SHA384",
                "ECDHE-ECDSA-AES128-GCM-SHA256",
                "ECDHE-RSA-AES128-GCM-SHA256",
            ]
        )
    }

    @Test func sendsExactUDPAndTCPPayloadsOverLoopback() async throws {
        try await withEventLoopGroup { group in
            let udpPromise = group.next().makePromise(of: Data.self)
            let udpServer = try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(
                        DatagramCaptureHandler(promise: udpPromise)
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { udpServer.close(promise: nil) }
            let udpPort = try #require(udpServer.localAddress?.port)
            let udpExpected = try encodedMessage(
                endpoint: .udp(
                    SyslogNetworkAddress(host: "127.0.0.1", port: UInt16(udpPort))
                ),
                payload: "udp-wire"
            )
            let udpTransport = try await NIOSyslogTransportFactory(eventLoopGroup: group)
                .connect(
                    to: .udp(
                        SyslogNetworkAddress(host: "127.0.0.1", port: UInt16(udpPort))
                    ),
                    tls: nil,
                    timeout: .seconds(2)
                )
            try await udpTransport.write(udpExpected, timeout: .seconds(2))
            #expect(try await udpPromise.futureResult.syslogTestBounded().get() == udpExpected)
            try await udpTransport.close(timeout: .seconds(2))

            let tcpPromise = group.next().makePromise(of: Data.self)
            let tcpExpected = try encodedMessage(
                endpoint: .tcp(
                    SyslogNetworkAddress(host: "127.0.0.1", port: 0)
                ),
                payload: "tcp-wire"
            )
            let tcpServer = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        StreamCaptureHandler(
                            byteCount: tcpExpected.count,
                            promise: tcpPromise
                        )
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { tcpServer.close(promise: nil) }
            let tcpPort = try #require(tcpServer.localAddress?.port)
            let tcpTransport = try await NIOSyslogTransportFactory(eventLoopGroup: group)
                .connect(
                    to: .tcp(
                        SyslogNetworkAddress(host: "127.0.0.1", port: UInt16(tcpPort))
                    ),
                    tls: nil,
                    timeout: .seconds(2)
                )
            try await tcpTransport.write(tcpExpected, timeout: .seconds(2))
            #expect(try await tcpPromise.futureResult.syslogTestBounded().get() == tcpExpected)
            try await tcpTransport.close(timeout: .seconds(2))
        }
    }

    @Test func sendsExactUnixStreamAndDatagramPayloads() async throws {
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cc-syslog-\(uniqueSuffix)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withEventLoopGroup { group in
            let streamPath = directory.appendingPathComponent("stream.sock").path
            let streamExpected = try encodedMessage(
                endpoint: .unixStream(path: Data(streamPath.utf8)),
                payload: "unix-stream"
            )
            let streamPromise = group.next().makePromise(of: Data.self)
            let streamCapture = StreamCaptureHandler(
                byteCount: streamExpected.count,
                promise: streamPromise
            )
            defer { streamCapture.cancel() }
            let streamServer = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(streamCapture)
                }
                .bind(unixDomainSocketPath: streamPath)
                .get()
            defer { streamServer.close(promise: nil) }
            let streamTransport = try await NIOSyslogTransportFactory(eventLoopGroup: group)
                .connect(
                    to: .unixStream(path: Data(streamPath.utf8)),
                    tls: nil,
                    timeout: .seconds(2)
                )
            try await streamTransport.write(streamExpected, timeout: .seconds(2))
            #expect(try await streamPromise.futureResult.syslogTestBounded().get() == streamExpected)
            try await streamTransport.close(timeout: .seconds(2))

            let datagramPath = directory.appendingPathComponent("datagram.sock").path
            let datagramExpected = try encodedMessage(
                endpoint: .unixDatagram(path: Data(datagramPath.utf8)),
                payload: "unix-datagram"
            )
            let datagramPromise = group.next().makePromise(of: Data.self)
            let datagramCapture = DatagramCaptureHandler(promise: datagramPromise)
            defer { datagramCapture.cancel() }
            let datagramServer = try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(datagramCapture)
                }
                .bind(
                    unixDomainSocketPath: datagramPath,
                    cleanupExistingSocketFile: true
                )
                .get()
            defer { datagramServer.close(promise: nil) }
            let datagramTransport = try await NIOSyslogTransportFactory(eventLoopGroup: group)
                .connect(
                    to: .unixDatagram(path: Data(datagramPath.utf8)),
                    tls: nil,
                    timeout: .seconds(2)
                )
            try await datagramTransport.write(datagramExpected, timeout: .seconds(2))
            #expect(try await datagramPromise.futureResult.syslogTestBounded().get() == datagramExpected)
            try await datagramTransport.close(timeout: .seconds(2))
        }
    }

    @Test func tlsHandshakeIsEagerVerifiedAndRFC5425FramingIsExact() async throws {
        let certificatePath = try fixturePath("syslog-server-cert.pem")
        let keyPath = try fixturePath("syslog-server-key.pem")
        let caPath = try fixturePath("syslog-test-ca.pem")

        try await withEventLoopGroup { group in
            let expected = try encodedMessage(
                endpoint: .tcpTLS(
                    SyslogNetworkAddress(host: "localhost", port: 0)
                ),
                format: .rfc5424Micro,
                tls: SyslogTLSConfiguration(
                    caCertificatePath: caPath,
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: false
                ),
                payload: "tls-wire"
            )
            let capturePromise = group.next().makePromise(of: Data.self)
            let capture = StreamCaptureHandler(
                byteCount: expected.count,
                promise: capturePromise
            )
            defer { capture.cancel() }
            let serverContext = try tlsServerContext(
                certificatePath: certificatePath,
                keyPath: keyPath
            )
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: serverContext)
                        )
                        try channel.pipeline.syncOperations.addHandler(capture)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)
            let endpoint = SyslogEndpoint.tcpTLS(
                SyslogNetworkAddress(host: "localhost", port: UInt16(port))
            )
            let factory = NIOSyslogTransportFactory(eventLoopGroup: group)

            let verified = try await factory.connect(
                to: endpoint,
                tls: SyslogTLSConfiguration(
                    caCertificatePath: caPath,
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: false
                ),
                timeout: .seconds(2)
            )
            try await verified.write(expected, timeout: .seconds(2))
            #expect(try await capturePromise.futureResult.syslogTestBounded().get() == expected)
            try await verified.close(timeout: .seconds(2))

            // Go omits SNI for an IP literal while still verifying the
            // originally requested IP SAN. The fixture is valid for both
            // localhost and 127.0.0.1.
            let verifiedIP = try await factory.connect(
                to: .tcpTLS(
                    SyslogNetworkAddress(host: "127.0.0.1", port: UInt16(port))
                ),
                tls: SyslogTLSConfiguration(
                    caCertificatePath: caPath,
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: false
                ),
                timeout: .seconds(2)
            )
            try await verifiedIP.close(timeout: .seconds(2))

            await #expect(throws: SyslogProviderError.tlsIdentityVerificationFailed) {
                try await factory.connect(
                    to: .tcpTLS(
                        // Darwin resolves this legacy numeric form to
                        // 127.0.0.1, but modern Go treats the original text as
                        // a DNS identity. The connection therefore reaches
                        // the loopback peer while SAN verification must reject
                        // the unmodified requested identity.
                        SyslogNetworkAddress(host: "2130706433", port: UInt16(port))
                    ),
                    tls: SyslogTLSConfiguration(
                        caCertificatePath: caPath,
                        clientCertificatePath: "",
                        clientPrivateKeyPath: "",
                        skipServerVerification: false
                    ),
                    timeout: .seconds(2)
                )
            }

            // A self-signed peer is rejected during connect, not deferred to
            // the first log write.
            await #expect(throws: (any Error).self) {
                try await factory.connect(
                    to: endpoint,
                    tls: SyslogTLSConfiguration(
                        caCertificatePath: "",
                        clientCertificatePath: "",
                        clientPrivateKeyPath: "",
                        skipServerVerification: false
                    ),
                    timeout: .seconds(2)
                )
            }

            // Moby ignores CA-file contents whenever skip verification is
            // enabled by option presence.
            let unverified = try await factory.connect(
                to: endpoint,
                tls: SyslogTLSConfiguration(
                    caCertificatePath: "/definitely/missing/ca.pem",
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: true
                ),
                timeout: .seconds(2)
            )
            try await unverified.close(timeout: .seconds(2))
        }
    }

    @Test func tlsHandshakeTimeoutClosesAStalledLoopbackPeer() async throws {
        try await withEventLoopGroup { group in
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { server.close(promise: nil) }
            let port = try #require(server.localAddress?.port)

            await #expect(throws: SyslogProviderError.connectionTimedOut) {
                try await NIOSyslogTransportFactory(eventLoopGroup: group)
                    .connect(
                        to: .tcpTLS(
                            SyslogNetworkAddress(
                                host: "127.0.0.1",
                                port: UInt16(port)
                            )
                        ),
                        tls: SyslogTLSConfiguration(
                            caCertificatePath: "",
                            clientCertificatePath: "",
                            clientPrivateKeyPath: "",
                            skipServerVerification: true
                        ),
                        timeout: .milliseconds(50)
                    )
            }
        }
    }
}

private func withEventLoopGroup<Result: Sendable>(
    _ body: @escaping @Sendable (MultiThreadedEventLoopGroup) async throws -> Result
) async throws -> Result {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let result = try await body(group)
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func encodedMessage(
    endpoint: SyslogEndpoint,
    format: SyslogMessageFormat = .unix,
    tls: SyslogTLSConfiguration? = nil,
    payload: String
) throws -> Data {
    let encoder = SyslogMessageEncoder(
        configuration: try syslogTestConfiguration(
            endpoint: endpoint,
            format: format,
            tls: tls
        ),
        clock: SyslogTestClock()
    )
    let record = try syslogRecord(payload: Data(payload.utf8))
    let encoded = try encoder.encode(record)
    return try #require(encoded)
}

private func fixturePath(_ name: String) throws -> String {
    try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        )?.path
    )
}

private func tlsServerContext(
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

private enum SyslogLoopbackTimeout: Error {
    case elapsed
}

private final class SyslogTestFutureState: @unchecked Sendable {
    var completed = false
}

extension EventLoopFuture where Value: Sendable {
    fileprivate func syslogTestBounded() -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        let state = SyslogTestFutureState()
        let scheduled = eventLoop.scheduleTask(in: .seconds(2)) {
            guard !state.completed else {
                return
            }
            state.completed = true
            promise.fail(SyslogLoopbackTimeout.elapsed)
        }
        whenComplete { result in
            guard !state.completed else {
                return
            }
            state.completed = true
            scheduled.cancel()
            promise.completeWith(result)
        }
        return promise.futureResult
    }
}

private final class StreamCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let byteCount: Int
    private let promise: EventLoopPromise<Data>
    private var bytes = [UInt8]()
    private let completionLock = NSLock()
    private var completed = false

    init(byteCount: Int, promise: EventLoopPromise<Data>) {
        self.byteCount = byteCount
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let received = buffer.readBytes(length: buffer.readableBytes) {
            bytes.append(contentsOf: received)
        }
        if bytes.count >= byteCount {
            complete(.success(Data(bytes)))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(SyslogTestFailure.exhausted))
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

private final class DatagramCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let promise: EventLoopPromise<Data>
    private let completionLock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        let bytes = envelope.data.readBytes(length: envelope.data.readableBytes) ?? []
        complete(.success(Data(bytes)))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(SyslogTestFailure.exhausted))
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
