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
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Production transport adapter. The caller owns the event-loop group so the
/// separately versioned provider plane can share one bounded I/O pool across
/// every remote logging driver and shut it down in its service lifecycle.
public final class NIOSyslogTransportFactory: SyslogTransportFactory, @unchecked Sendable {
    private let eventLoopGroup: any EventLoopGroup

    public init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    public func connect(
        to endpoint: SyslogEndpoint,
        tls: SyslogTLSConfiguration?,
        timeout: Duration
    ) async throws -> any SyslogTransport {
        switch endpoint {
        case .system:
            return try await connectSystem(timeout: timeout)
        case .udp(let address):
            return try await connectDatagram(address: address)
        case .tcp(let address):
            guard tls == nil else {
                throw SyslogProviderError.invalidTLSConfiguration(
                    "TLS material supplied for a plain TCP endpoint"
                )
            }
            return try await connectStream(
                address: address,
                tls: nil,
                timeout: timeout
            )
        case .tcpTLS(let address):
            guard let tls else {
                throw SyslogProviderError.invalidTLSConfiguration(
                    "TLS endpoint is missing TLS material"
                )
            }
            return try await connectStream(
                address: address,
                tls: tls,
                timeout: timeout
            )
        case .unixStream(let path):
            guard tls == nil else {
                throw SyslogProviderError.invalidTLSConfiguration(
                    "TLS material supplied for a Unix endpoint"
                )
            }
            return try await connectUnixStream(path: path, timeout: timeout)
        case .unixDatagram(let path):
            guard tls == nil else {
                throw SyslogProviderError.invalidTLSConfiguration(
                    "TLS material supplied for a Unix datagram endpoint"
                )
            }
            return try await connectUnixDatagram(path: path)
        }
    }

    private func connectSystem(timeout: Duration) async throws -> any SyslogTransport {
        let paths = ["/dev/log", "/var/run/syslog", "/var/run/log"]
        var lastError: (any Error)?
        for path in paths {
            do {
                return try await connectUnixDatagram(path: path)
            } catch {
                lastError = error
            }
        }
        for path in paths {
            do {
                return try await connectUnixStream(path: path, timeout: timeout)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SyslogProviderError.malformedAddress("")
    }

    private func connectStream(
        address: SyslogNetworkAddress,
        tls: SyslogTLSConfiguration?,
        timeout: Duration
    ) async throws -> any SyslogTransport {
        let port = try Self.resolvePort(address.port, protocolName: "tcp")
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(timeout.nioTimeAmount)

        let configuredBootstrap: ClientBootstrap
        let handshakeCompletion: TLSHandshakeCompletion?
        if let tls {
            let context: NIOSSLContext
            do {
                context = try Self.makeTLSContext(tls)
            } catch {
                throw SyslogProviderError.invalidTLSConfiguration(
                    "could not load configured TLS material"
                )
            }
            // TLS SNI only permits DNS names. With a literal IP, NIOSSL's
            // nil hostname path deliberately verifies the leaf IP SAN against
            // the connected socket address, matching Go's tls.Dial behavior.
            let serverHostname = Self.tlsServerHostname(for: address.host)
            let promise = eventLoopGroup.next().makePromise(of: Void.self)
            let completion = TLSHandshakeCompletion(promise: promise)
            handshakeCompletion = completion
            configuredBootstrap = bootstrap.channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = try NIOSSLClientHandler(
                        context: context,
                        serverHostname: serverHostname
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(
                        TLSHandshakeObserver(completion: completion)
                    )
                }
            }
        } else {
            handshakeCompletion = nil
            configuredBootstrap = bootstrap
        }

        do {
            let channel =
                try await configuredBootstrap
                .connect(host: address.host.isEmpty ? "localhost" : address.host, port: port)
                .get()
            if let handshakeCompletion {
                do {
                    try await handshakeCompletion.futureResult
                        .bounded(
                            by: timeout,
                            timeoutError: SyslogProviderError.connectionTimedOut,
                            closing: channel
                        )
                        .get()
                } catch {
                    handshakeCompletion.complete(.failure(error))
                    try? await channel.close().get()
                    throw error
                }
            }
            return NIOConnectedSyslogTransport(channel: channel)
        } catch ChannelError.connectTimeout {
            handshakeCompletion?.complete(
                .failure(SyslogProviderError.connectionTimedOut)
            )
            throw SyslogProviderError.connectionTimedOut
        } catch {
            handshakeCompletion?.complete(.failure(error))
            throw error
        }
    }

    private func connectUnixStream(
        path: String,
        timeout: Duration
    ) async throws -> any SyslogTransport {
        do {
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(timeout.nioTimeAmount)
                .connect(unixDomainSocketPath: path)
                .get()
            return NIOConnectedSyslogTransport(channel: channel)
        } catch ChannelError.connectTimeout {
            throw SyslogProviderError.connectionTimedOut
        }
    }

    private func connectDatagram(
        address: SyslogNetworkAddress
    ) async throws -> any SyslogTransport {
        let port = try Self.resolvePort(address.port, protocolName: "udp")
        let host = address.host.isEmpty ? "localhost" : address.host
        let channel = try await DatagramBootstrap(group: eventLoopGroup)
            .connect(host: host, port: port)
            .get()
        return NIOConnectedSyslogTransport(channel: channel)
    }

    private func connectUnixDatagram(
        path: String
    ) async throws -> any SyslogTransport {
        let channel = try await DatagramBootstrap(group: eventLoopGroup)
            .connect(unixDomainSocketPath: path)
            .get()
        return NIOConnectedSyslogTransport(channel: channel)
    }

    private static func makeTLSContext(
        _ options: SyslogTLSConfiguration
    ) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.cipherSuites = [
            "ECDHE-ECDSA-AES256-GCM-SHA384",
            "ECDHE-RSA-AES256-GCM-SHA384",
            "ECDHE-ECDSA-AES128-GCM-SHA256",
            "ECDHE-RSA-AES128-GCM-SHA256",
            "ECDHE-ECDSA-CHACHA20-POLY1305",
            "ECDHE-RSA-CHACHA20-POLY1305",
        ].joined(separator: ":")
        configuration.certificateVerification =
            options.skipServerVerification
            ? .none
            : .fullVerification

        if !options.skipServerVerification, !options.caCertificatePath.isEmpty {
            configuration.additionalTrustRoots = [.file(options.caCertificatePath)]
        }

        if !options.clientCertificatePath.isEmpty || !options.clientPrivateKeyPath.isEmpty {
            configuration.certificateChain =
                try NIOSSLCertificate
                .fromPEMFile(options.clientCertificatePath)
                .map { .certificate($0) }
            configuration.privateKey = .privateKey(
                try NIOSSLPrivateKey(
                    file: options.clientPrivateKeyPath,
                    format: .pem
                )
            )
        }
        return try NIOSSLContext(configuration: configuration)
    }

    private static func resolvePort(
        _ value: String,
        protocolName: String
    ) throws -> Int {
        if let port = Int(value), (0...65_535).contains(port) {
            return port
        }
        guard !value.isEmpty else {
            throw SyslogProviderError.malformedAddress("empty port")
        }
        return try serviceLock.withLock {
            guard let service = getservbyname(value, protocolName) else {
                throw SyslogProviderError.malformedAddress("unknown service port")
            }
            return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: service.pointee.s_port)))
        }
    }

    private static func tlsServerHostname(for host: String) -> String? {
        guard !host.isEmpty else {
            return nil
        }

        let addressWithoutScope = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var ipv4 = in_addr()
        if addressWithoutScope.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return nil
        }
        var ipv6 = in6_addr()
        if addressWithoutScope.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return nil
        }
        return host
    }

    private static let serviceLock = NSLock()
}

/// `ClientBootstrap.connect` completes before a TLS handshake does. Moby's
/// `tls.Dial` is eager, so provider start must await the handshake as well.
private final class TLSHandshakeObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let completion: TLSHandshakeCompletion

    init(completion: TLSHandshakeCompletion) {
        self.completion = completion
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let event = event as? TLSUserEvent,
            case .handshakeCompleted = event
        {
            completion.complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: any Error
    ) {
        completion.complete(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.complete(.failure(SyslogProviderError.transportClosed))
        context.fireChannelInactive()
    }
}

private final class TLSHandshakeCompletion: @unchecked Sendable {
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    var futureResult: EventLoopFuture<Void> {
        promise.futureResult
    }

    func complete(_ result: Result<Void, any Error>) {
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
}

private actor NIOConnectedSyslogTransport: SyslogTransport {
    private var channel: (any Channel)?

    init(channel: any Channel) {
        self.channel = channel
    }

    func write(_ message: Data, timeout: Duration) async throws {
        guard let channel else {
            throw SyslogProviderError.transportClosed
        }
        var buffer = channel.allocator.buffer(capacity: message.count)
        buffer.writeBytes(message)
        try await channel.writeAndFlush(buffer)
            .bounded(
                by: timeout,
                timeoutError: SyslogProviderError.writeTimedOut,
                closing: channel
            )
            .get()
    }

    func close(timeout: Duration) async throws {
        guard let channel else {
            return
        }
        self.channel = nil
        try await channel.close()
            .bounded(
                by: timeout,
                timeoutError: SyslogProviderError.closeTimedOut,
                closing: channel
            )
            .get()
    }
}

extension EventLoopFuture where Value: Sendable {
    fileprivate func bounded(
        by timeout: Duration,
        timeoutError: any Error,
        closing channel: any Channel
    ) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        // Both callbacks execute on this future's event loop. The reference
        // box avoids a Sendable mutable-capture warning without adding a lock
        // to the hot path.
        let state = BoundedFutureState()
        let scheduled = eventLoop.scheduleTask(in: timeout.nioTimeAmount) {
            guard !state.completed else {
                return
            }
            state.completed = true
            channel.close(mode: .all, promise: nil)
            promise.fail(timeoutError)
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

private final class BoundedFutureState: @unchecked Sendable {
    var completed = false
}

extension Duration {
    fileprivate var nioTimeAmount: TimeAmount {
        .nanoseconds(clampedNanoseconds)
    }

    fileprivate var clampedNanoseconds: Int64 {
        let components = self.components
        let (secondsNanoseconds, overflow) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        if overflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        let attosecondNanoseconds = components.attoseconds / 1_000_000_000
        let (total, additionOverflow) = secondsNanoseconds.addingReportingOverflow(attosecondNanoseconds)
        if additionOverflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        return total
    }
}
