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

public protocol GELFTransport: AnyObject, Sendable {
    func write(_ message: Data, timeout: Duration) async throws -> Int
    func close(timeout: Duration) async throws
}

public protocol GELFTransportFactory: Sendable {
    func connect(
        to endpoint: GELFEndpoint,
        timeout: Duration
    ) async throws -> any GELFTransport
}

public final class NIOGELFTransportFactory: GELFTransportFactory, @unchecked Sendable {
    private let eventLoopGroup: any EventLoopGroup

    public init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    public func connect(
        to endpoint: GELFEndpoint,
        timeout: Duration
    ) async throws -> any GELFTransport {
        switch endpoint {
        case .udp(let address):
            return try await connectDatagram(address: address, timeout: timeout)
        case .tcp(let address):
            return try await connectStream(address: address, timeout: timeout)
        }
    }

    private func connectStream(
        address: GELFNetworkAddress,
        timeout: Duration
    ) async throws -> any GELFTransport {
        let port = try Self.resolvePort(address.port)
        do {
            let connection = ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(timeout.gelfNIOTimeAmount)
                .connect(host: Self.nativeConnectionHost(address.host), port: port)
            let channel =
                try await connection
                .gelfConnectBounded(by: timeout) { channel in
                    channel.close(mode: .all, promise: nil)
                }
                .get()
            return NIOConnectedGELFTransport(channel: channel)
        } catch ChannelError.connectTimeout {
            throw GELFProviderError.connectionTimedOut
        } catch {
            throw GELFProviderError.connectionFailed(
                endpoint: address,
                reason: String(describing: error)
            )
        }
    }

    private func connectDatagram(
        address: GELFNetworkAddress,
        timeout: Duration
    ) async throws -> any GELFTransport {
        let port = try Self.resolvePort(address.port)
        do {
            let connection = DatagramBootstrap(group: eventLoopGroup)
                .connect(host: Self.nativeConnectionHost(address.host), port: port)
            let channel =
                try await connection
                .gelfConnectBounded(by: timeout) { channel in
                    channel.close(mode: .all, promise: nil)
                }
                .get()
            return NIOConnectedGELFTransport(channel: channel)
        } catch ChannelError.connectTimeout {
            throw GELFProviderError.connectionTimedOut
        }
    }

    private static func resolvePort(_ value: String) throws -> Int {
        guard
            !value.isEmpty,
            value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let port = Int(value),
            (0...65_535).contains(port)
        else {
            throw GELFProviderError.malformedAddress("invalid decimal port")
        }
        return port
    }

    /// Converts Docker's VM host alias only at the native macOS transport boundary.
    ///
    /// The persisted GELF endpoint must retain `host.docker.internal` for Docker API
    /// parity, but this provider connects from the macOS host rather than the Linux VM.
    private static func nativeConnectionHost(_ configuredHost: String) -> String {
        let host = configuredHost.isEmpty ? "localhost" : configuredHost
        #if os(macOS)
        if host.caseInsensitiveCompare("host.docker.internal") == .orderedSame {
            return "127.0.0.1"
        }
        #endif
        return host
    }
}

private actor NIOConnectedGELFTransport: GELFTransport {
    private var channel: (any Channel)?

    init(channel: any Channel) {
        self.channel = channel
    }

    func write(_ message: Data, timeout: Duration) async throws -> Int {
        guard let channel else {
            throw GELFProviderError.transportClosed
        }
        var buffer = channel.allocator.buffer(capacity: message.count)
        buffer.writeBytes(message)
        try await channel.writeAndFlush(buffer)
            .gelfBounded(
                by: timeout,
                timeoutError: GELFProviderError.writeTimedOut,
                closing: channel
            )
            .get()
        return message.count
    }

    func close(timeout: Duration) async throws {
        guard let channel else {
            return
        }
        self.channel = nil
        try await channel.close()
            .gelfBounded(
                by: timeout,
                timeoutError: GELFProviderError.closeTimedOut,
                closing: channel
            )
            .get()
    }
}

extension EventLoopFuture where Value: Sendable {
    func gelfConnectBounded(
        by timeout: Duration,
        closeLateValue: @escaping @Sendable (Value) -> Void
    ) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        let state = GELFBoundedFutureState()
        let scheduled = eventLoop.scheduleTask(in: timeout.gelfNIOTimeAmount) {
            guard !state.completed else {
                return
            }
            state.completed = true
            promise.fail(GELFProviderError.connectionTimedOut)
        }
        whenComplete { result in
            guard !state.completed else {
                if case .success(let value) = result {
                    closeLateValue(value)
                }
                return
            }
            state.completed = true
            scheduled.cancel()
            promise.completeWith(result)
        }
        return promise.futureResult
    }

    fileprivate func gelfBounded(
        by timeout: Duration,
        timeoutError: any Error,
        closing channel: any Channel
    ) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        let state = GELFBoundedFutureState()
        let scheduled = eventLoop.scheduleTask(in: timeout.gelfNIOTimeAmount) {
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

private final class GELFBoundedFutureState: @unchecked Sendable {
    var completed = false
}

extension Duration {
    fileprivate var gelfNIOTimeAmount: TimeAmount {
        .nanoseconds(gelfClampedNanoseconds)
    }

    fileprivate var gelfClampedNanoseconds: Int64 {
        let components = self.components
        let (secondsNanoseconds, overflow) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        if overflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        let attosecondNanoseconds = components.attoseconds / 1_000_000_000
        let (total, additionOverflow) = secondsNanoseconds.addingReportingOverflow(
            attosecondNanoseconds
        )
        if additionOverflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        return total
    }
}
