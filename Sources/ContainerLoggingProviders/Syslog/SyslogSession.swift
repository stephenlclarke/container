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

import ContainerResource
import Foundation

public protocol SyslogTransport: AnyObject, Sendable {
    func write(_ message: Data, timeout: Duration) async throws
    func close(timeout: Duration) async throws
}

public protocol SyslogTransportFactory: Sendable {
    func connect(
        to endpoint: SyslogEndpoint,
        tls: SyslogTLSConfiguration?,
        timeout: Duration
    ) async throws -> any SyslogTransport
}

public enum SyslogSessionState: Equatable, Sendable {
    case active
    case writerFenced
    case closed
}

/// One eagerly connected Moby-compatible writer. Calls are serialized even
/// across suspension points so record order and close fencing remain exact.
public actor SyslogDriverSession: ContainerLogDriverSession {
    private let configuration: SyslogDriverConfiguration
    private let factory: any SyslogTransportFactory
    private let encoder: SyslogMessageEncoder
    private var transport: (any SyslogTransport)?
    private var state: SyslogSessionState = .active
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        configuration: SyslogDriverConfiguration,
        transportFactory: any SyslogTransportFactory,
        clock: any SyslogClock = SystemSyslogClock()
    ) async throws {
        self.configuration = configuration
        self.factory = transportFactory
        self.encoder = SyslogMessageEncoder(configuration: configuration, clock: clock)
        self.transport = try await transportFactory.connect(
            to: configuration.endpoint,
            tls: configuration.tls,
            timeout: configuration.policy.connectTimeout
        )
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            throw SyslogProviderError.transportClosed
        }
        guard let message = try encoder.encode(record) else {
            return
        }
        if let current = transport {
            do {
                try await current.write(message, timeout: configuration.policy.writeTimeout)
                return
            } catch {
                try? await current.close(timeout: configuration.policy.closeTimeout)
                transport = nil
                guard state == .active else {
                    throw SyslogProviderError.transportClosed
                }
            }
        }

        // srslog reconnects immediately once and retries the same framed bytes.
        // If that connect failed on a previous record, its connection remains
        // nil and the next record starts here with another single attempt.
        let replacement = try await factory.connect(
            to: configuration.endpoint,
            tls: configuration.tls,
            timeout: configuration.policy.connectTimeout
        )
        transport = replacement
        try await replacement.write(message, timeout: configuration.policy.writeTimeout)
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        // Every transport write is awaited. Acquiring the operation gate is
        // therefore the syslog flush barrier; there is no remote acknowledgement.
        releaseOperation()
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await close(
            terminalState: .closed,
            timeout: Self.timeout(until: deadline, maximum: configuration.policy.closeTimeout)
        )
    }

    public func fence(timeout: Duration? = nil) async throws {
        try await close(
            terminalState: .writerFenced,
            timeout: timeout ?? configuration.policy.closeTimeout
        )
    }

    public func closeUsingPolicy() async throws {
        try await close(
            terminalState: .closed,
            timeout: configuration.policy.closeTimeout
        )
    }

    public func currentState() -> SyslogSessionState {
        state
    }

    private func close(
        terminalState: SyslogSessionState,
        timeout: Duration
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            if state == .writerFenced, terminalState == .closed {
                state = .closed
            }
            return
        }
        state = terminalState
        let current = transport
        transport = nil
        if let current {
            try await current.close(timeout: timeout)
        }
    }

    private func acquireOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationActive = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private static func timeout(
        until deadline: ContinuousClock.Instant,
        maximum: Duration
    ) -> Duration {
        let remaining = ContinuousClock().now.duration(to: deadline)
        if remaining <= .zero {
            return .zero
        }
        return min(remaining, maximum)
    }
}
