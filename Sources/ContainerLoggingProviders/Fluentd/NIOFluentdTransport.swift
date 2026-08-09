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
import NIOTLS

public protocol FluentdTransport: AnyObject, Sendable {
    func write(_ message: Data, timeout: Duration?) async throws
    func readAcknowledgement(
        timeout: Duration?,
        maximumBytes: Int
    ) async throws -> String
    func close(timeout: Duration) async throws
}

public protocol FluentdTransportFactory: Sendable {
    func connect(
        to endpoint: FluentdEndpoint,
        timeout: Duration
    ) async throws -> any FluentdTransport
}

/// SwiftNIO transport for TCP, verified TLS, and Unix stream endpoints. The
/// provider service owns the group so all remote drivers share a bounded I/O
/// pool. Additional trust roots model host-installed trust and are not a
/// Docker-visible fluentd option.
public final class NIOFluentdTransportFactory: FluentdTransportFactory,
    @unchecked Sendable
{
    private let eventLoopGroup: any EventLoopGroup
    private let additionalTrustRootPaths: [String]
    private let clock: any FluentdClock

    public init(
        eventLoopGroup: any EventLoopGroup,
        additionalTrustRootPaths: [String] = [],
        clock: any FluentdClock = SystemFluentdClock()
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.additionalTrustRootPaths = additionalTrustRootPaths
        self.clock = clock
    }

    public func connect(
        to endpoint: FluentdEndpoint,
        timeout: Duration
    ) async throws -> any FluentdTransport {
        let deadline = clock.now() + max(timeout, .zero)
        switch endpoint {
        case .tcp(let address):
            return try await connectNetwork(
                address: address,
                useTLS: false,
                deadline: deadline
            )
        case .tls(let address):
            return try await connectNetwork(
                address: address,
                useTLS: true,
                deadline: deadline
            )
        case .unix(let path):
            return try await connectUnix(path: path, deadline: deadline)
        }
    }

    private func connectNetwork(
        address: FluentdNetworkAddress,
        useTLS: Bool,
        deadline: Duration
    ) async throws -> any FluentdTransport {
        let decodedHost: String
        do {
            decodedHost = try DockerSocketAddress.host(address.host)
        } catch {
            throw FluentdProviderError.malformedAddress(
                "network host is not valid UTF-8"
            )
        }
        let configuredHost =
            decodedHost.isEmpty
            ? FluentdEndpoint.defaultHost
            : decodedHost
        let host = Self.nativeConnectionHost(configuredHost)
        let inbound = FluentdInboundByteHandler()
        let handshakeCompletion: FluentdTLSHandshakeCompletion?
        let initializer: @Sendable (any Channel) -> EventLoopFuture<Void>

        if useTLS {
            let requestedIdentity = configuredHost
            let context: NIOSSLContext
            do {
                var configuration = TLSConfiguration.makeClientConfiguration()
                configuration.minimumTLSVersion = .tlsv12
                // BoringSSL still verifies the chain. Identity is checked
                // separately below to match modern Go: only the requested
                // DNS/IP identity, SAN-only, with no connected-IP or CN fallback.
                configuration.certificateVerification = .noHostnameVerification
                if !additionalTrustRootPaths.isEmpty {
                    configuration.additionalTrustRoots = additionalTrustRootPaths.map {
                        .file($0)
                    }
                }
                context = try NIOSSLContext(configuration: configuration)
            } catch {
                throw FluentdProviderError.malformedAddress(
                    "could not load fluentd TLS trust roots"
                )
            }
            let completion = FluentdTLSHandshakeCompletion(
                promise: eventLoopGroup.next().makePromise(of: Void.self)
            )
            handshakeCompletion = completion
            initializer = { channel in
                channel.eventLoop.makeCompletedFuture {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: context,
                        serverHostname: DockerGoTLSIdentityVerifier.serverHostname(
                            for: requestedIdentity
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        FluentdTLSHandshakeObserver(
                            completion: completion,
                            tlsHandler: tlsHandler,
                            requestedIdentity: requestedIdentity
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(inbound)
                }
            }
        } else {
            handshakeCompletion = nil
            initializer = { channel in
                channel.pipeline.addHandler(inbound)
            }
        }

        do {
            let connectBudget = try remaining(until: deadline)
            let channel =
                try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(connectBudget.fluentdNIOTimeAmount)
                .channelInitializer(initializer)
                .connect(
                    host: host,
                    port: Int(address.port)
                )
                .get()
            if let handshakeCompletion {
                do {
                    let handshakeBudget = try remaining(until: deadline)
                    try await handshakeCompletion.futureResult
                        .fluentdBounded(
                            by: handshakeBudget,
                            timeoutError: FluentdProviderError.connectionTimedOut,
                            closing: channel
                        )
                        .get()
                } catch {
                    handshakeCompletion.complete(.failure(error))
                    try? await channel.close().get()
                    throw error
                }
            }
            return NIOConnectedFluentdTransport(
                channel: channel,
                inbound: inbound
            )
        } catch ChannelError.connectTimeout {
            handshakeCompletion?.complete(
                .failure(FluentdProviderError.connectionTimedOut)
            )
            throw FluentdProviderError.connectionTimedOut
        } catch {
            handshakeCompletion?.complete(.failure(error))
            throw error
        }
    }

    private func connectUnix(
        path: Data,
        deadline: Duration
    ) async throws -> any FluentdTransport {
        let inbound = FluentdInboundByteHandler()
        let address: SocketAddress
        do {
            address = try DockerSocketAddress.unix(path: path)
        } catch {
            throw FluentdProviderError.malformedAddress(
                "invalid Unix socket path"
            )
        }
        do {
            let connectBudget = try remaining(until: deadline)
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(connectBudget.fluentdNIOTimeAmount)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(inbound)
                }
                .connect(to: address)
                .get()
            return NIOConnectedFluentdTransport(
                channel: channel,
                inbound: inbound
            )
        } catch ChannelError.connectTimeout {
            throw FluentdProviderError.connectionTimedOut
        }
    }

    /// Converts Docker's VM host alias only at the native macOS transport boundary.
    ///
    /// Persisted Fluentd configuration retains the Docker host alias for Docker
    /// API parity, while the provider connects from the macOS host rather than the
    /// Linux VM. TLS verification continues to use the originally requested identity.
    private static func nativeConnectionHost(_ configuredHost: String) -> String {
        #if os(macOS)
        if configuredHost.caseInsensitiveCompare("host.docker.internal") == .orderedSame {
            return "127.0.0.1"
        }
        #endif
        return configuredHost
    }

    private func remaining(until deadline: Duration) throws -> Duration {
        let remaining = deadline - clock.now()
        guard remaining > .zero else {
            throw FluentdProviderError.connectionTimedOut
        }
        return remaining
    }

}

private final class FluentdTLSHandshakeObserver: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = Any

    private let completion: FluentdTLSHandshakeCompletion
    private let tlsHandler: NIOSSLHandler
    private let requestedIdentity: String

    init(
        completion: FluentdTLSHandshakeCompletion,
        tlsHandler: NIOSSLHandler,
        requestedIdentity: String
    ) {
        self.completion = completion
        self.tlsHandler = tlsHandler
        self.requestedIdentity = requestedIdentity
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let event = event as? TLSUserEvent,
            case .handshakeCompleted = event
        {
            guard
                let certificate = tlsHandler.peerCertificate,
                DockerGoTLSIdentityVerifier.matches(
                    requestedIdentity,
                    certificate: certificate
                )
            else {
                completion.complete(
                    .failure(FluentdProviderError.tlsIdentityVerificationFailed)
                )
                context.close(promise: nil)
                return
            }
            completion.complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let mappedError = FluentdTLSHandshakeErrorMapper.map(error)
        completion.complete(.failure(mappedError))
        context.fireErrorCaught(mappedError)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.complete(.failure(FluentdProviderError.transportClosed))
        context.fireChannelInactive()
    }
}

enum FluentdTLSHandshakeErrorMapper {
    /// Normalizes BoringSSL's public trust-verification signal without
    /// reclassifying transport, protocol, or post-handshake identity failures.
    static func map(_ error: any Error) -> any Error {
        guard
            let tlsError = error as? NIOSSLError,
            case .handshakeFailed(.sslError(let errorStack)) = tlsError,
            errorStack.contains(where: {
                $0.description.contains("CERTIFICATE_VERIFY_FAILED")
            })
        else {
            return error
        }
        return FluentdProviderError.tlsTrustVerificationFailed
    }
}

private final class FluentdTLSHandshakeCompletion: @unchecked Sendable {
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    var futureResult: EventLoopFuture<Void> { promise.futureResult }

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

private actor NIOConnectedFluentdTransport: FluentdTransport {
    private var channel: (any Channel)?
    private let inbound: FluentdInboundByteHandler
    private var acknowledgementBuffer = Data()

    init(channel: any Channel, inbound: FluentdInboundByteHandler) {
        self.channel = channel
        self.inbound = inbound
    }

    func write(_ message: Data, timeout: Duration?) async throws {
        guard let channel else {
            throw FluentdProviderError.transportClosed
        }
        var buffer = channel.allocator.buffer(capacity: message.count)
        buffer.writeBytes(message)
        let future: EventLoopFuture<Void> = channel.writeAndFlush(buffer)
        do {
            if let timeout {
                try await future
                    .fluentdBounded(
                        by: timeout,
                        timeoutError: FluentdProviderError.writeTimedOut,
                        closing: channel
                    )
                    .get()
            } else {
                try await future.get()
            }
        } catch FluentdProviderError.writeTimedOut {
            self.channel = nil
            throw FluentdProviderError.writeTimedOut
        }
    }

    func readAcknowledgement(
        timeout: Duration?,
        maximumBytes: Int
    ) async throws -> String {
        guard maximumBytes > 0 else {
            throw FluentdProviderError.acknowledgementTooLarge(maximumBytes: maximumBytes)
        }
        let deadline = timeout.map { ContinuousClock().now + $0 }
        while true {
            if acknowledgementBuffer.count > maximumBytes {
                throw FluentdProviderError.acknowledgementTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            if let decoded = try FluentdForwardAcknowledgementCodec.decode(
                acknowledgementBuffer
            ) {
                acknowledgementBuffer.removeFirst(decoded.consumedBytes)
                return decoded.chunkID
            }
            guard let channel else {
                throw FluentdProviderError.transportClosed
            }
            let remaining: Duration?
            if let deadline {
                let value = ContinuousClock().now.duration(to: deadline)
                guard value > .zero else {
                    throw FluentdProviderError.readTimedOut
                }
                remaining = value
            } else {
                remaining = nil
            }
            let next = inbound.next(on: channel.eventLoop)
            let fragment: Data
            if let remaining {
                do {
                    fragment =
                        try await next
                        .fluentdBounded(
                            by: remaining,
                            timeoutError: FluentdProviderError.readTimedOut,
                            closing: channel
                        )
                        .get()
                } catch FluentdProviderError.readTimedOut {
                    self.channel = nil
                    throw FluentdProviderError.readTimedOut
                }
            } else {
                fragment = try await next.get()
            }
            acknowledgementBuffer.append(fragment)
        }
    }

    func close(timeout: Duration) async throws {
        guard let channel else {
            return
        }
        self.channel = nil
        do {
            try await channel.close()
                .fluentdBounded(
                    by: timeout,
                    timeoutError: FluentdProviderError.closeTimedOut,
                    closing: channel
                )
                .get()
        } catch ChannelError.alreadyClosed {
            // A Forward receiver may close immediately after its final ACK.
            // Closing an already-inactive transport remains idempotent.
        }
    }
}

final class FluentdInboundByteHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private static let maximumQueuedBytes = 64 * 1024

    private var queued = [Data]()
    private var queuedHead = 0
    private var queuedBytes = 0
    private var waiters = [EventLoopPromise<Data>]()
    private var terminalError: (any Error)?

    func next(on eventLoop: any EventLoop) -> EventLoopFuture<Data> {
        let promise = eventLoop.makePromise(of: Data.self)
        eventLoop.execute {
            // A peer is allowed to send its final acknowledgement and close
            // immediately. NIO delivers channelRead before channelInactive,
            // so drain bytes already accepted by the handler before surfacing
            // the terminal state.
            if self.queuedHead < self.queued.count {
                let value = self.queued[self.queuedHead]
                self.queuedHead += 1
                self.queuedBytes -= value.count
                if self.queuedHead == self.queued.count {
                    self.queued.removeAll(keepingCapacity: true)
                    self.queuedHead = 0
                }
                promise.succeed(value)
            } else if let terminalError = self.terminalError {
                promise.fail(terminalError)
            } else {
                self.waiters.append(promise)
            }
        }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let value = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        guard !value.isEmpty else {
            return
        }
        if let error = enqueue(value) {
            finish(error)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(FluentdProviderError.transportClosed)
        context.fireChannelInactive()
    }

    /// Event-loop-confined entry point shared with deterministic queue-order
    /// tests. Returns the terminal error when the bounded queue rejects data.
    func enqueue(_ value: Data) -> FluentdProviderError? {
        guard value.count <= Self.maximumQueuedBytes else {
            return .acknowledgementTooLarge(
                maximumBytes: Self.maximumQueuedBytes
            )
        }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.succeed(value)
            return nil
        }
        guard queuedBytes <= Self.maximumQueuedBytes - value.count else {
            return .acknowledgementTooLarge(
                maximumBytes: Self.maximumQueuedBytes
            )
        }
        queued.append(value)
        queuedBytes += value.count
        return nil
    }

    func finish(_ error: any Error) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.fail(error)
        }
    }
}

extension EventLoopFuture where Value: Sendable {
    fileprivate func fluentdBounded(
        by timeout: Duration,
        timeoutError: any Error,
        closing channel: any Channel
    ) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        let state = FluentdBoundedFutureState()
        let scheduled = eventLoop.scheduleTask(in: timeout.fluentdNIOTimeAmount) {
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

private final class FluentdBoundedFutureState: @unchecked Sendable {
    var completed = false
}

extension Duration {
    fileprivate var fluentdNIOTimeAmount: TimeAmount {
        .nanoseconds(fluentdClampedNanoseconds)
    }
}
