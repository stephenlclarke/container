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

public protocol SplunkClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemSplunkClock: SplunkClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum SplunkSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

/// Docker-compatible HEC batching, retry retention, and bounded overflow.
public actor SplunkDriverSession: ContainerLogDriverSession {
    private let configuration: SplunkDriverConfiguration
    private let transport: any SplunkHTTPTransport
    private let encoder: SplunkMessageEncoder
    private let clock: any SplunkClock
    private var pending = [Data]()
    private var state: SplunkSessionState = .active
    private var timerTask: Task<Void, Never>?
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        configuration: SplunkDriverConfiguration,
        transportFactory: any SplunkHTTPTransportFactory,
        clock: any SplunkClock = SystemSplunkClock()
    ) async throws {
        self.configuration = configuration
        self.transport = try transportFactory.makeTransport(
            configuration: configuration
        )
        self.encoder = SplunkMessageEncoder(configuration: configuration)
        self.clock = clock
        if configuration.verifyConnection {
            let response = try await transport.execute(
                SplunkHTTPRequest(
                    url: configuration.endpoint.eventURL,
                    method: .options,
                    maximumResponseBytes:
                        configuration.policy.maximumResponseBytes
                ),
                timeout: configuration.policy.requestTimeout
            )
            guard response.statusCode == 200 else {
                await transport.close()
                throw SplunkProviderError.verificationFailed(
                    statusCode: response.statusCode
                )
            }
        }
        self.timerTask = Task { [weak self] in
            await self?.runTimer()
        }
    }

    deinit {
        timerTask?.cancel()
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard state == .active else {
            throw SplunkProviderError.transportClosed
        }
        guard let message = try encoder.encode(record) else {
            return
        }
        pending.append(message)
        if pending.count.isMultiple(of: configuration.policy.postBatchSize) {
            try await postPending(lastChance: false, deadline: nil)
        }
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            throw SplunkProviderError.transportClosed
        }
        guard ContinuousClock().now <= deadline else {
            throw SplunkProviderError.flushTimedOut
        }
        try await postPending(lastChance: false, deadline: deadline)
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await close(terminalState: .closed, deadline: deadline)
    }

    public func closeUsingPolicy() async throws {
        try await close(
            terminalState: .closed,
            deadline: ContinuousClock().now
                .advanced(by: configuration.policy.closeTimeout)
        )
    }

    public func fence() async throws {
        try await close(
            terminalState: .writerFenced,
            deadline: ContinuousClock().now
                .advanced(by: configuration.policy.closeTimeout)
        )
    }

    public func currentState() -> SplunkSessionState {
        state
    }

    private func close(
        terminalState: SplunkSessionState,
        deadline: ContinuousClock.Instant
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        switch state {
        case .closed:
            return
        case .writerFenced:
            if terminalState == .closed {
                state = .closed
            }
            return
        case .closing:
            throw SplunkProviderError.transportClosed
        case .active:
            break
        }
        guard ContinuousClock().now <= deadline else {
            throw SplunkProviderError.closeTimedOut
        }
        state = .closing
        timerTask?.cancel()
        timerTask = nil
        do {
            try await postPending(lastChance: true, deadline: deadline)
            await transport.close()
            state = terminalState
        } catch {
            await transport.close()
            state = terminalState
            if ContinuousClock().now > deadline {
                throw SplunkProviderError.closeTimedOut
            }
            throw error
        }
    }

    private func runTimer() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: configuration.policy.postFrequency)
            } catch {
                return
            }
            await acquireOperation()
            if state == .active {
                try? await postPending(lastChance: false, deadline: nil)
            }
            releaseOperation()
        }
    }

    private func postPending(
        lastChance: Bool,
        deadline: ContinuousClock.Instant?
    ) async throws {
        var firstFailure: (any Error)?
        while !pending.isEmpty {
            let batchCount = min(
                configuration.policy.postBatchSize,
                pending.count
            )
            let batch = Array(pending.prefix(batchCount))
            do {
                let timeout = try requestTimeout(deadline: deadline)
                let body = try encoder.encodeBatch(batch)
                var headers = [
                    "Authorization": "Splunk \(configuration.token)"
                ]
                if configuration.gzipEnabled {
                    headers["Content-Encoding"] = "gzip"
                }
                if configuration.indexAcknowledgement {
                    headers["X-Splunk-Request-Channel"] = UUID().uuidString
                }
                let response = try await transport.execute(
                    SplunkHTTPRequest(
                        url: configuration.endpoint.eventURL,
                        method: .post,
                        headers: headers,
                        body: body,
                        maximumResponseBytes:
                            configuration.policy.maximumResponseBytes
                    ),
                    timeout: timeout
                )
                guard response.statusCode == 200 else {
                    throw SplunkProviderError.deliveryFailed(
                        statusCode: response.statusCode
                    )
                }
                pending.removeFirst(batchCount)
            } catch {
                firstFailure = firstFailure ?? error
                if lastChance {
                    pending.removeAll(keepingCapacity: false)
                } else if pending.count >= configuration.policy.bufferMaximum {
                    pending.removeFirst(batchCount)
                }
                break
            }
        }
        if let firstFailure, lastChance {
            // Moby logs and discards its last-chance failure. The error is
            // deliberately swallowed here as well; no token, payload, or
            // remote response body is surfaced through provider diagnostics.
            _ = firstFailure
        }
    }

    private func requestTimeout(
        deadline: ContinuousClock.Instant?
    ) throws -> Duration {
        guard let deadline else {
            return configuration.policy.requestTimeout
        }
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else {
            throw state == .closing
                ? SplunkProviderError.closeTimedOut
                : SplunkProviderError.flushTimedOut
        }
        return min(remaining, configuration.policy.requestTimeout)
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
}
