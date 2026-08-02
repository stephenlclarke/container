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

public protocol GELFClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemGELFClock: GELFClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: duration)
    }
}

public enum GELFSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

/// One eagerly connected GELF writer. UDP sends each go-gelf datagram once;
/// TCP serializes records and reproduces go-gelf's reconnect loop.
public actor GELFDriverSession: ContainerLogDriverSession {
    private struct ActiveOperation: Sendable {
        let id: UInt64
        let task: Task<Void, any Error>
    }

    private let configuration: GELFDriverConfiguration
    private let factory: any GELFTransportFactory
    private let messageEncoder: GELFMessageEncoder
    private let datagramEncoder: GELFDatagramEncoder
    private let clock: any GELFClock
    private var transport: (any GELFTransport)?
    private var state: GELFSessionState = .active
    private var closingTerminalState: GELFSessionState?
    private var activeOperation: ActiveOperation?
    private var nextOperationID: UInt64 = 1
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()
    private var closeAttemptActive = false
    private var closeAttemptWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        configuration: GELFDriverConfiguration,
        transportFactory: any GELFTransportFactory,
        chunkIDGenerator: any GELFChunkIDGenerating = RandomGELFChunkIDGenerator(),
        clock: any GELFClock = SystemGELFClock()
    ) async throws {
        self.configuration = configuration
        self.factory = transportFactory
        self.messageEncoder = GELFMessageEncoder(configuration: configuration)
        self.datagramEncoder = GELFDatagramEncoder(
            compressionType: configuration.compressionType,
            compressionLevel: configuration.compressionLevel,
            chunkIDGenerator: chunkIDGenerator
        )
        self.clock = clock
        self.transport = try await transportFactory.connect(
            to: configuration.endpoint,
            timeout: configuration.policy.connectTimeout
        )
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard state == .active else {
            throw GELFProviderError.transportClosed
        }
        guard let json = try messageEncoder.encode(record) else {
            return
        }
        let id = nextOperationID
        nextOperationID &+= 1
        let task = Task<Void, any Error> {
            try await self.writeEncoded(json)
        }
        activeOperation = ActiveOperation(id: id, task: task)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearOperation(id: id)
        } catch {
            clearOperation(id: id)
            throw error
        }
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard ContinuousClock().now <= deadline else {
            throw GELFProviderError.flushTimedOut
        }
        // Writes are awaited and serialized, so acquiring this gate is the
        // complete GELF flush barrier. GELF has no response acknowledgement.
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        let remaining = ContinuousClock().now.duration(to: deadline)
        try await close(
            terminalState: .closed,
            timeout: min(max(remaining, .zero), configuration.policy.closeTimeout)
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

    public func currentState() -> GELFSessionState {
        state
    }

    private func writeEncoded(_ json: Data) async throws {
        switch configuration.endpoint {
        case .udp:
            try await writeDatagrams(try datagramEncoder.encode(json))
        case .tcp:
            try await writeTCP(try GELFMessageEncoder.tcpFrame(json))
        }
    }

    private func clearOperation(id: UInt64) {
        if activeOperation?.id == id {
            activeOperation = nil
        }
    }

    private func writeDatagrams(_ datagrams: [Data]) async throws {
        guard let current = transport else {
            throw GELFProviderError.transportClosed
        }
        for datagram in datagrams {
            guard state == .active else {
                throw GELFProviderError.transportClosed
            }
            let written = try await current.write(
                datagram,
                timeout: configuration.policy.writeTimeout
            )
            guard state == .active else {
                throw GELFProviderError.transportClosed
            }
            try Task.checkCancellation()
            guard written == datagram.count else {
                throw GELFProviderError.partialWrite(
                    expected: datagram.count,
                    actual: written
                )
            }
        }
    }

    private func writeTCP(_ frame: Data) async throws {
        var reconnectsConsumed = 0
        while true {
            guard state == .active else {
                throw GELFProviderError.transportClosed
            }
            try Task.checkCancellation()

            if let current = transport {
                let written: Int
                do {
                    written = try await current.write(
                        frame,
                        timeout: configuration.policy.writeTimeout
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard state == .active else {
                        throw GELFProviderError.transportClosed
                    }
                    transport = nil
                    try? await current.close(timeout: configuration.policy.closeTimeout)
                    guard state == .active else {
                        throw GELFProviderError.transportClosed
                    }
                    try await reconnectAfterFailure()
                    if reconnectsConsumed >= configuration.maximumReconnects {
                        throw reconnectAttemptsExhausted(
                            reconnectsConsumedBeforeFinalAttempt: reconnectsConsumed
                        )
                    }
                    reconnectsConsumed += 1
                    continue
                }
                guard state == .active else {
                    throw GELFProviderError.transportClosed
                }
                try Task.checkCancellation()
                guard written == frame.count else {
                    throw GELFProviderError.partialWrite(
                        expected: frame.count,
                        actual: written
                    )
                }
                return
            }

            try await reconnectAfterFailure()
            if reconnectsConsumed >= configuration.maximumReconnects {
                throw reconnectAttemptsExhausted(
                    reconnectsConsumedBeforeFinalAttempt: reconnectsConsumed
                )
            }
            reconnectsConsumed += 1
        }
    }

    private func reconnectAttemptsExhausted(
        reconnectsConsumedBeforeFinalAttempt: Int
    ) -> GELFProviderError {
        .reconnectAttemptsExhausted(
            attempts:
                reconnectsConsumedBeforeFinalAttempt == Int.max
                ? Int.max : reconnectsConsumedBeforeFinalAttempt + 1
        )
    }

    private func reconnectAfterFailure() async throws {
        try await clock.sleep(for: configuration.reconnectDelay)
        guard state == .active else {
            throw GELFProviderError.transportClosed
        }
        let replacement: any GELFTransport
        do {
            replacement = try await factory.connect(
                to: configuration.endpoint,
                timeout: configuration.policy.connectTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transport = nil
            return
        }
        guard state == .active else {
            try? await replacement.close(timeout: configuration.policy.closeTimeout)
            throw GELFProviderError.transportClosed
        }
        transport = replacement
    }

    private func close(
        terminalState: GELFSessionState,
        timeout: Duration
    ) async throws {
        await acquireCloseAttempt()
        defer { releaseCloseAttempt() }
        switch state {
        case .closed:
            return
        case .writerFenced where terminalState == .writerFenced:
            return
        case .active:
            state = .closing
            closingTerminalState = terminalState
        case .closing:
            if terminalState == .closed {
                closingTerminalState = .closed
            }
        case .writerFenced:
            state = .closing
            closingTerminalState = .closed
        }

        activeOperation?.task.cancel()
        let boundedTimeout = max(timeout, .zero)
        let deadline = ContinuousClock().now + boundedTimeout
        let current = transport
        var closeError: (any Error)?
        if let current {
            do {
                try await current.close(timeout: boundedTimeout)
                if transport === current {
                    transport = nil
                }
            } catch {
                closeError = error
            }
        }

        do {
            try await waitForOperationTermination(until: deadline)
        } catch {
            if closeError == nil {
                closeError = error
            }
        }

        if closeError == nil, transport == nil, !operationActive {
            state = closingTerminalState ?? terminalState
            closingTerminalState = nil
        }
        if let closeError {
            throw closeError
        }
    }

    private func waitForOperationTermination(
        until deadline: ContinuousClock.Instant
    ) async throws {
        while activeOperation != nil || operationActive {
            let remaining = Self.remaining(until: deadline)
            guard remaining > .zero else {
                throw GELFProviderError.closeTimedOut
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(1)))
            } catch {
                throw GELFProviderError.closeTimedOut
            }
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

    private func acquireCloseAttempt() async {
        if !closeAttemptActive {
            closeAttemptActive = true
            return
        }
        await withCheckedContinuation { continuation in
            closeAttemptWaiters.append(continuation)
        }
    }

    private func releaseCloseAttempt() {
        if closeAttemptWaiters.isEmpty {
            closeAttemptActive = false
        } else {
            closeAttemptWaiters.removeFirst().resume()
        }
    }

    private static func remaining(
        until deadline: ContinuousClock.Instant
    ) -> Duration {
        let value = ContinuousClock().now.duration(to: deadline)
        return value > .zero ? value : .zero
    }
}
