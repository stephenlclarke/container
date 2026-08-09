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
import DockerSemanticHelper
import Foundation

public protocol AWSLogsMultilineMatching: Sendable {
    func matches(pattern: Data, candidate: Data) throws -> Bool
}

public struct DockerSemanticAWSLogsMultilineMatcher:
    AWSLogsMultilineMatching
{
    private let semanticService: any DockerSemanticServicing

    public init(semanticService: any DockerSemanticServicing) {
        self.semanticService = semanticService
    }

    public func matches(pattern: Data, candidate: Data) throws -> Bool {
        let result = try semanticService.matchRegularExpression(
            pattern: pattern,
            candidates: [candidate],
            timeout: .seconds(2)
        )
        guard result.count == 1 else {
            throw DockerSemanticHelperError.protocolViolation
        }
        return result[0]
    }
}

public protocol AWSLogsClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemAWSLogsClock: AWSLogsClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum AWSLogsSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

/// Moby 29.2.1-compatible CloudWatch event assembly and publication.
public actor AWSLogsDriverSession: ContainerLogDriverSession {
    public static let perEventBytes = 26
    public static let maximumBytesPerPut = 1_048_576
    public static let maximumEventsPerPut = 10_000
    public static let maximumBytesPerEvent = 262_144 - perEventBytes

    private let configuration: AWSLogsDriverConfiguration
    private let client: any AWSLogsClient
    private let matcher: any AWSLogsMultilineMatching
    private let clock: any AWSLogsClock
    private var state: AWSLogsSessionState = .active
    private var created = false
    private var queued = [ContainerLogRecordV2]()
    private var queueWaiters = [CheckedContinuation<Void, any Error>]()
    private var eventBuffer = Data()
    private var eventBufferEffectiveBytes = 0
    private var eventBufferTimestamp: Int64 = 0
    private var batch = [AWSLogsInputEvent]()
    private var batchBytes = 0
    private var sequenceToken: String?
    private var timerTask: Task<Void, Never>?
    private var creationTask: Task<Void, Never>?
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        configuration: AWSLogsDriverConfiguration,
        clientFactory: any AWSLogsClientFactory,
        matcher: any AWSLogsMultilineMatching,
        clock: any AWSLogsClock = SystemAWSLogsClock()
    ) async throws {
        self.configuration = configuration
        self.client = try await clientFactory.makeClient(
            configuration: configuration
        )
        self.matcher = matcher
        self.clock = clock
        if configuration.nonBlocking {
            creationTask = Task { [weak self] in
                await self?.runCreationRetry()
            }
        } else {
            try await create()
            created = true
        }
        timerTask = Task { [weak self] in
            await self?.runTimer()
        }
    }

    deinit {
        timerTask?.cancel()
        creationTask?.cancel()
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        while true {
            await acquireOperation()
            do { try Task.checkCancellation() } catch {
                releaseOperation()
                throw error
            }
            guard state == .active else {
                releaseOperation()
                throw AWSLogsProviderError.transportClosed
            }
            if created {
                do {
                    try await process(record)
                    releaseOperation()
                    return
                } catch {
                    releaseOperation()
                    throw error
                }
            }
            if queued.count < configuration.policy.maximumBufferedEvents {
                queued.append(record)
                releaseOperation()
                return
            }
            releaseOperation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                queueWaiters.append(continuation)
            }
        }
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else {
            throw AWSLogsProviderError.transportClosed
        }
        guard ContinuousClock().now <= deadline else {
            throw AWSLogsProviderError.flushTimedOut
        }
        if created {
            try await drainQueued()
            try await flushEventBuffer()
            await publishBatch()
        }
        guard ContinuousClock().now <= deadline else {
            throw AWSLogsProviderError.flushTimedOut
        }
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await close(terminalState: .closed, deadline: deadline)
    }

    public func closeUsingPolicy() async throws {
        try await close(
            terminalState: .closed,
            deadline: ContinuousClock().now.advanced(
                by: configuration.policy.closeTimeout
            )
        )
    }

    public func fence() async throws {
        try await close(
            terminalState: .writerFenced,
            deadline: ContinuousClock().now.advanced(
                by: configuration.policy.closeTimeout
            )
        )
    }

    public func currentState() -> AWSLogsSessionState { state }

    package var pendingEventCount: Int {
        queued.count + batch.count + (eventBuffer.isEmpty ? 0 : 1)
    }

    package var currentSequenceToken: String? { sequenceToken }

    private func close(
        terminalState: AWSLogsSessionState,
        deadline: ContinuousClock.Instant
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        switch state {
        case .closed:
            return
        case .writerFenced:
            if terminalState == .closed { state = .closed }
            return
        case .closing:
            throw AWSLogsProviderError.transportClosed
        case .active:
            break
        }
        guard ContinuousClock().now <= deadline else {
            throw AWSLogsProviderError.closeTimedOut
        }
        state = .closing
        timerTask?.cancel()
        timerTask = nil
        creationTask?.cancel()
        creationTask = nil
        // Moby releases creationDone on close and then drains its queue even
        // when remote stream creation never succeeded.
        created = true
        do {
            try await drainQueued()
            try await flushEventBuffer()
            await publishBatch()
        } catch {
            // Moby logs and drops terminal delivery failures.
        }
        resumeQueueWaiters(with: AWSLogsProviderError.transportClosed)
        await client.close()
        state = terminalState
        guard ContinuousClock().now <= deadline else {
            throw AWSLogsProviderError.closeTimedOut
        }
    }

    private func runCreationRetry() async {
        var backoff = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                try await create()
                await creationSucceeded()
                return
            } catch {
                do {
                    try await clock.sleep(for: backoff)
                } catch {
                    return
                }
                backoff = min(
                    backoff * 2,
                    configuration.policy.maximumCreationBackoff
                )
            }
        }
    }

    private func creationSucceeded() async {
        await acquireOperation()
        defer { releaseOperation() }
        guard state == .active else { return }
        created = true
        try? await drainQueued()
    }

    private func create() async throws {
        guard configuration.createStream else { return }
        do {
            try await client.createLogStream(
                group: configuration.logGroup,
                stream: configuration.logStream
            )
            return
        } catch AWSLogsClientError.resourceAlreadyExists {
            return
        } catch AWSLogsClientError.resourceNotFound
            where configuration.createGroup
        {
            do {
                try await client.createLogGroup(name: configuration.logGroup)
            } catch AWSLogsClientError.resourceAlreadyExists {
                // Existing group is success, matching Moby.
            } catch {
                throw AWSLogsProviderError.createLogGroupFailed
            }
            do {
                try await client.createLogStream(
                    group: configuration.logGroup,
                    stream: configuration.logStream
                )
            } catch AWSLogsClientError.resourceAlreadyExists {
                return
            } catch {
                throw AWSLogsProviderError.createLogStreamFailed
            }
        } catch {
            throw AWSLogsProviderError.createLogStreamFailed
        }
    }

    private func runTimer() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(
                    for: configuration.policy.forceFlushInterval
                )
            } catch {
                return
            }
            await acquireOperation()
            if state == .active, created {
                try? await drainQueued()
                try? await flushEventBufferIfExpired()
                await publishBatch()
            }
            releaseOperation()
        }
    }

    private func drainQueued() async throws {
        while !queued.isEmpty {
            let record = queued.removeFirst()
            resumeOneQueueWaiter()
            try await process(record)
        }
    }

    private func process(_ record: ContainerLogRecordV2) async throws {
        let timestamp = Self.milliseconds(record.observation.wallClock)
        guard let pattern = configuration.multilinePattern else {
            await processEvent(record.payload, timestamp: timestamp)
            return
        }

        if eventBufferTimestamp == 0 {
            eventBufferTimestamp = timestamp
        }
        let lineEffectiveBytes = Self.effectiveLength(record.payload)
        let startsEvent = try matcher.matches(
            pattern: Data(pattern.utf8),
            candidate: record.payload
        )
        if startsEvent
            || eventBufferEffectiveBytes + lineEffectiveBytes
                > Self.maximumBytesPerEvent
        {
            await processEvent(
                eventBuffer,
                timestamp: eventBufferTimestamp
            )
            eventBuffer.removeAll(keepingCapacity: true)
            eventBufferEffectiveBytes = 0
            eventBufferTimestamp = timestamp
        }
        eventBuffer.append(record.payload)
        eventBufferEffectiveBytes += lineEffectiveBytes
        if lineEffectiveBytes < Self.maximumBytesPerEvent {
            eventBuffer.append(UInt8(ascii: "\n"))
            eventBufferEffectiveBytes += 1
        }
    }

    private func flushEventBufferIfExpired() async throws {
        guard !eventBuffer.isEmpty, eventBufferTimestamp != 0 else { return }
        let now = Date.now.timeIntervalSince1970 * 1_000
        let age = Int64(now) - eventBufferTimestamp
        let interval = configuration.policy.forceFlushInterval.milliseconds
        if age >= interval || age < 0 {
            try await flushEventBuffer()
        }
    }

    private func flushEventBuffer() async throws {
        guard !eventBuffer.isEmpty else { return }
        await processEvent(eventBuffer, timestamp: eventBufferTimestamp)
        eventBuffer.removeAll(keepingCapacity: true)
        eventBufferEffectiveBytes = 0
        eventBufferTimestamp = 0
    }

    private func processEvent(_ bytes: Data, timestamp: Int64) async {
        let normalized = Data(String(decoding: bytes, as: UTF8.self).utf8)
        var offset = 0
        while offset < normalized.count {
            let upper = Self.validUTF8Split(
                normalized,
                startingAt: offset,
                maximumBytes: Self.maximumBytesPerEvent
            )
            let message = String(
                decoding: normalized[offset..<upper],
                as: UTF8.self
            )
            let eventBytes = upper - offset + Self.perEventBytes
            if batch.count >= Self.maximumEventsPerPut
                || batchBytes + eventBytes > Self.maximumBytesPerPut
            {
                await publishBatch()
                continue
            }
            batch.append(
                AWSLogsInputEvent(
                    message: message,
                    timestampMilliseconds: timestamp,
                    insertionOrder: batch.count
                )
            )
            batchBytes += eventBytes
            offset = upper
        }
    }

    private func publishBatch() async {
        guard !batch.isEmpty else { return }
        let events = batch.sorted {
            if $0.timestampMilliseconds == $1.timestampMilliseconds {
                return $0.insertionOrder < $1.insertionOrder
            }
            return $0.timestampMilliseconds < $1.timestampMilliseconds
        }
        batch.removeAll(keepingCapacity: true)
        batchBytes = 0
        do {
            let result = try await client.putLogEvents(
                group: configuration.logGroup,
                stream: configuration.logStream,
                events: events,
                sequenceToken: sequenceToken
            )
            sequenceToken = result.nextSequenceToken
        } catch AWSLogsClientError.dataAlreadyAccepted(let expected) {
            sequenceToken = expected
        } catch AWSLogsClientError.invalidSequenceToken(let expected) {
            do {
                let result = try await client.putLogEvents(
                    group: configuration.logGroup,
                    stream: configuration.logStream,
                    events: events,
                    sequenceToken: expected
                )
                sequenceToken = result.nextSequenceToken
            } catch {
                // Moby logs and drops the failed batch.
            }
        } catch {
            // Moby logs and drops the failed batch.
        }
    }

    private func resumeOneQueueWaiter() {
        guard !queueWaiters.isEmpty else { return }
        queueWaiters.removeFirst().resume()
    }

    private func resumeQueueWaiters(with error: any Error) {
        let waiters = queueWaiters
        queueWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(throwing: error) }
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

    public static func effectiveLength(_ bytes: Data) -> Int {
        String(decoding: bytes, as: UTF8.self).utf8.count
    }

    private static func validUTF8Split(
        _ bytes: Data,
        startingAt start: Int,
        maximumBytes: Int
    ) -> Int {
        let proposed = min(start + maximumBytes, bytes.count)
        guard proposed < bytes.count else { return proposed }
        var split = proposed
        while split > start && (bytes[split] & 0b1100_0000) == 0b1000_0000 {
            split -= 1
        }
        return split == start ? proposed : split
    }

    private static func milliseconds(_ timestamp: ContainerLogTimestamp) -> Int64 {
        timestamp.secondsSinceUnixEpoch * 1_000
            + Int64(timestamp.nanoseconds / 1_000_000)
    }
}

extension Duration {
    fileprivate var milliseconds: Int64 {
        let components = self.components
        return components.seconds * 1_000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}
