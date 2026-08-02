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

public protocol FluentdClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

public struct SystemFluentdClock: FluentdClock {
    private let origin = ContinuousClock().now

    public init() {}

    public func now() -> Duration {
        origin.duration(to: ContinuousClock().now)
    }

    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: duration)
    }
}

public enum FluentdSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

/// One Forward client. Synchronous sessions eagerly connect and preserve
/// caller backpressure. Async sessions accept into the Docker-compatible
/// event-count buffer and connect on a background task.
public actor FluentdDriverSession: ContainerLogDriverSession {
    private struct PendingEvent: Sendable {
        let id: UInt64
        let event: FluentdEncodedEvent
    }

    private struct ActiveSynchronousOperation: Sendable {
        let id: UInt64
        let task: Task<Void, any Error>
    }

    private let configuration: FluentdDriverConfiguration
    private let factory: any FluentdTransportFactory
    private let encoder: FluentdForwardMessageEncoder
    private let clock: any FluentdClock
    private var transport: (any FluentdTransport)?
    private var lastConnectedAt: Duration?
    private var state: FluentdSessionState = .active
    private var closingTerminalState: FluentdSessionState?
    private var pending = [PendingEvent]()
    private var pendingHead = 0
    private var nextPendingID: UInt64 = 1
    private var inFlightID: UInt64?
    private var workerTask: Task<Void, Never>?
    private var activeSynchronousOperation: ActiveSynchronousOperation?
    private var nextSynchronousOperationID: UInt64 = 1
    private var asyncDeliveryFailureCount = 0
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        configuration: FluentdDriverConfiguration,
        transportFactory: any FluentdTransportFactory,
        chunkIDGenerator: any FluentdChunkIDGenerating = RandomFluentdChunkIDGenerator(),
        clock: any FluentdClock = SystemFluentdClock()
    ) async throws {
        self.configuration = configuration
        self.factory = transportFactory
        self.encoder = FluentdForwardMessageEncoder(
            configuration: configuration,
            chunkIDGenerator: chunkIDGenerator
        )
        self.clock = clock
        if configuration.async {
            self.transport = nil
            self.lastConnectedAt = nil
        } else {
            let connected = try await transportFactory.connect(
                to: configuration.endpoint,
                timeout: configuration.policy.connectTimeout
            )
            self.transport = connected
            self.lastConnectedAt = clock.now()
        }
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            throw FluentdProviderError.transportClosed
        }
        let event = try encoder.encode(record)
        if configuration.async {
            guard pendingCount < configuration.bufferLimit else {
                throw FluentdProviderError.bufferFull(limit: configuration.bufferLimit)
            }
            let pendingEvent = PendingEvent(id: nextPendingID, event: event)
            nextPendingID &+= 1
            pending.append(pendingEvent)
            ensureWorker()
            return
        }
        try await performSynchronousSend(event)
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        if !configuration.async {
            return
        }
        while pendingCount > 0 || inFlightID != nil {
            let remaining = ContinuousClock().now.duration(to: deadline)
            guard remaining > .zero else {
                throw FluentdProviderError.flushTimedOut
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(5)))
            } catch is CancellationError {
                throw FluentdProviderError.flushTimedOut
            }
        }
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await close(
            terminalState: .closed,
            timeout: Self.timeout(
                until: deadline,
                maximum: configuration.policy.closeTimeout
            )
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

    public func currentState() -> FluentdSessionState {
        state
    }

    public func bufferedEventCount() -> Int {
        pendingCount
    }

    public func deliveryFailureCount() -> Int {
        asyncDeliveryFailureCount
    }

    private func ensureWorker() {
        guard workerTask == nil else {
            return
        }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func performSynchronousSend(
        _ event: FluentdEncodedEvent
    ) async throws {
        let id = nextSynchronousOperationID
        nextSynchronousOperationID &+= 1
        let task = Task<Void, any Error> {
            try await self.sendWithRetry(event)
        }
        activeSynchronousOperation = ActiveSynchronousOperation(
            id: id,
            task: task
        )
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearSynchronousOperation(id: id)
        } catch {
            clearSynchronousOperation(id: id)
            throw error
        }
    }

    private func clearSynchronousOperation(id: UInt64) {
        if activeSynchronousOperation?.id == id {
            activeSynchronousOperation = nil
        }
    }

    private func runWorker() async {
        while !Task.isCancelled, state == .active {
            guard let next = popPending() else {
                workerTask = nil
                return
            }
            inFlightID = next.id
            do {
                try await reconnectIfIntervalElapsed()
                try await sendWithRetry(next.event)
            } catch {
                if state == .active, !Task.isCancelled {
                    asyncDeliveryFailureCount += 1
                }
            }
            if inFlightID == next.id {
                inFlightID = nil
            }
        }
        inFlightID = nil
        workerTask = nil
    }

    private func reconnectIfIntervalElapsed() async throws {
        guard let interval = configuration.asyncReconnectInterval else {
            return
        }
        let intervalElapsed =
            lastConnectedAt.map { $0 + interval < clock.now() }
            ?? true
        guard intervalElapsed else {
            return
        }
        await closeCurrentTransport()
        // The pinned fluent-logger performs and ignores one complete reconnect
        // cycle here; writeWithRetry then performs the ordinary cycle if it
        // exhausted without replacing the connection.
        try? await ensureConnectedWithRetry()
    }

    private func sendWithRetry(_ event: FluentdEncodedEvent) async throws {
        var writeAttempt = 0
        while writeAttempt < configuration.maximumRetries {
            try await ensureConnectedWithRetry()
            guard state == .active, !Task.isCancelled else {
                throw FluentdProviderError.transportClosed
            }
            guard let current = transport else {
                throw FluentdProviderError.transportClosed
            }
            do {
                try await current.write(
                    event.bytes,
                    timeout: configuration.writeTimeout
                )
                guard state == .active, !Task.isCancelled else {
                    throw FluentdProviderError.transportClosed
                }
                if let expected = event.chunkID {
                    let actual = try await current.readAcknowledgement(
                        timeout: configuration.readTimeout,
                        maximumBytes: configuration.policy.maximumAcknowledgementBytes
                    )
                    guard state == .active, !Task.isCancelled else {
                        throw FluentdProviderError.transportClosed
                    }
                    if actual != expected {
                        throw FluentdProviderError.acknowledgementMismatch(
                            expected: expected,
                            actual: actual
                        )
                    }
                }
                return
            } catch {
                await closeCurrentTransport(ifIdenticalTo: current)
                guard state == .active, !Task.isCancelled else {
                    throw FluentdProviderError.transportClosed
                }
                writeAttempt += 1
                if writeAttempt == configuration.maximumRetries {
                    throw FluentdProviderError.writeRetriesExhausted(
                        attempts: configuration.maximumRetries
                    )
                }
            }
        }
        throw FluentdProviderError.writeRetriesExhausted(
            attempts: configuration.maximumRetries
        )
    }

    private func ensureConnectedWithRetry() async throws {
        guard transport == nil else {
            return
        }
        for attempt in 0..<configuration.maximumRetries {
            guard state == .active, !Task.isCancelled else {
                throw FluentdProviderError.transportClosed
            }
            let delay = retryDelay(beforeConnectionAttempt: attempt)
            if delay > .zero {
                try await clock.sleep(for: delay)
                guard state == .active, !Task.isCancelled else {
                    throw FluentdProviderError.transportClosed
                }
            }
            do {
                let connected = try await factory.connect(
                    to: configuration.endpoint,
                    timeout: configuration.policy.connectTimeout
                )
                guard state == .active, !Task.isCancelled else {
                    try? await connected.close(
                        timeout: configuration.policy.closeTimeout
                    )
                    throw FluentdProviderError.transportClosed
                }
                transport = connected
                lastConnectedAt = clock.now()
                return
            } catch FluentdProviderError.transportClosed {
                throw FluentdProviderError.transportClosed
            } catch {
                if attempt + 1 == configuration.maximumRetries {
                    throw FluentdProviderError.connectionRetriesExhausted(
                        attempts: configuration.maximumRetries
                    )
                }
            }
        }
        throw FluentdProviderError.connectionRetriesExhausted(
            attempts: configuration.maximumRetries
        )
    }

    private func retryDelay(beforeConnectionAttempt attempt: Int) -> Duration {
        Self.retryDelay(
            retryWait: configuration.retryWait,
            beforeConnectionAttempt: attempt
        )
    }

    // Engine 29.2.1 commit 6bc6209 vendors fluent-logger's
    // RetryWait * int(pow(1.5, i - 1)) reconnect formula.
    static func retryDelay(
        retryWait: Duration,
        beforeConnectionAttempt attempt: Int
    ) -> Duration {
        guard attempt >= 2, retryWait > .zero else {
            return .zero
        }
        let exponent = Double(attempt - 2)
        let multiplier = pow(1.5, exponent).rounded(.towardZero)
        let baseNanoseconds = retryWait.fluentdClampedNanoseconds
        guard baseNanoseconds > 0 else {
            return .zero
        }
        let maximumNanoseconds =
            FluentdDriverConfiguration.maximumReconnectWait
            .fluentdClampedNanoseconds
        guard
            multiplier.isFinite,
            multiplier < Double(maximumNanoseconds) / Double(baseNanoseconds)
        else {
            return FluentdDriverConfiguration.maximumReconnectWait
        }
        let (scaled, overflow) = baseNanoseconds.multipliedReportingOverflow(
            by: Int64(multiplier)
        )
        guard !overflow, scaled < maximumNanoseconds else {
            return FluentdDriverConfiguration.maximumReconnectWait
        }
        return .nanoseconds(scaled)
    }

    private func close(
        terminalState: FluentdSessionState,
        timeout: Duration
    ) async throws {
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
        pending.removeAll(keepingCapacity: false)
        pendingHead = 0
        workerTask?.cancel()
        activeSynchronousOperation?.task.cancel()
        let deadline = ContinuousClock().now + max(timeout, .zero)
        let current = transport
        transport = nil
        lastConnectedAt = nil
        var closeError: (any Error)?
        if let current {
            do {
                try await current.close(timeout: max(timeout, .zero))
            } catch {
                closeError = error
            }
        }
        let quiesced: Bool
        do {
            try await waitForWorkerTermination(until: deadline)
            quiesced = true
        } catch {
            quiesced = false
            if closeError == nil {
                closeError = error
            }
        }
        if quiesced {
            state = closingTerminalState ?? terminalState
            closingTerminalState = nil
        }
        if let closeError {
            throw closeError
        }
    }

    private func waitForWorkerTermination(
        until deadline: ContinuousClock.Instant
    ) async throws {
        while workerTask != nil || activeSynchronousOperation != nil {
            let remaining = Self.remaining(until: deadline)
            guard remaining > .zero else {
                throw FluentdProviderError.closeTimedOut
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(5)))
            } catch {
                throw FluentdProviderError.closeTimedOut
            }
        }
    }

    private func closeCurrentTransport(
        ifIdenticalTo expected: (any FluentdTransport)? = nil
    ) async {
        guard let current = transport else {
            return
        }
        if let expected, current !== expected {
            return
        }
        transport = nil
        try? await current.close(timeout: configuration.policy.closeTimeout)
    }

    private var pendingCount: Int {
        pending.count - pendingHead
    }

    private func popPending() -> PendingEvent? {
        guard pendingHead < pending.count else {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
            return nil
        }
        let value = pending[pendingHead]
        pendingHead += 1
        if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 4_096, pendingHead >= pending.count / 2 {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        return value
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
        min(remaining(until: deadline), maximum)
    }

    private static func remaining(
        until deadline: ContinuousClock.Instant
    ) -> Duration {
        let value = ContinuousClock().now.duration(to: deadline)
        if value <= .zero {
            return .zero
        }
        return value
    }
}
