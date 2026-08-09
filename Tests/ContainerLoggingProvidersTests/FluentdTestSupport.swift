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
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

enum FluentdTestFailure: Error, Equatable, Sendable {
    case connect
    case write
    case read
    case close
    case exhausted
    case timedOut
}

enum FluentdTestWriteOutcome: Sendable {
    case success
    case failure(FluentdTestFailure)
    case block
}

enum FluentdTestAcknowledgementOutcome: Sendable {
    case acknowledgement(String)
    case failure(FluentdTestFailure)
    case block
}

actor RecordingFluentdTransport: FluentdTransport {
    private(set) var messages = [Data]()
    private(set) var writeTimeouts = [Duration?]()
    private(set) var readTimeouts = [Duration?]()
    private(set) var acknowledgementLimits = [Int]()
    private(set) var closeTimeouts = [Duration]()
    private var writeOutcomes: [FluentdTestWriteOutcome]
    private var acknowledgementOutcomes: [FluentdTestAcknowledgementOutcome]
    private var blockedWrite: CheckedContinuation<Void, any Error>?
    private var blockedAcknowledgement: CheckedContinuation<String, any Error>?

    init(
        writeOutcomes: [FluentdTestWriteOutcome] = [],
        acknowledgementOutcomes: [FluentdTestAcknowledgementOutcome] = []
    ) {
        self.writeOutcomes = writeOutcomes
        self.acknowledgementOutcomes = acknowledgementOutcomes
    }

    var closeCallCount: Int { closeTimeouts.count }

    func write(_ message: Data, timeout: Duration?) async throws {
        messages.append(message)
        writeTimeouts.append(timeout)
        guard !writeOutcomes.isEmpty else {
            return
        }
        switch writeOutcomes.removeFirst() {
        case .success:
            return
        case .failure(let error):
            throw error
        case .block:
            try await withCheckedThrowingContinuation { continuation in
                blockedWrite = continuation
            }
        }
    }

    func readAcknowledgement(
        timeout: Duration?,
        maximumBytes: Int
    ) async throws -> String {
        readTimeouts.append(timeout)
        acknowledgementLimits.append(maximumBytes)
        guard !acknowledgementOutcomes.isEmpty else {
            throw FluentdTestFailure.exhausted
        }
        switch acknowledgementOutcomes.removeFirst() {
        case .acknowledgement(let value):
            return value
        case .failure(let error):
            throw error
        case .block:
            return try await withCheckedThrowingContinuation { continuation in
                blockedAcknowledgement = continuation
            }
        }
    }

    func close(timeout: Duration) async throws {
        closeTimeouts.append(timeout)
        let write = blockedWrite
        blockedWrite = nil
        write?.resume(throwing: FluentdProviderError.transportClosed)
        let acknowledgement = blockedAcknowledgement
        blockedAcknowledgement = nil
        acknowledgement?.resume(throwing: FluentdProviderError.transportClosed)
    }

    func waitUntilWriteBlocked(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock().now + timeout
        while blockedWrite == nil {
            guard ContinuousClock().now < deadline else {
                throw FluentdTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitUntilAcknowledgementBlocked(
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock().now + timeout
        while blockedAcknowledgement == nil {
            guard ContinuousClock().now < deadline else {
                throw FluentdTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseBlockedWrite() {
        let continuation = blockedWrite
        blockedWrite = nil
        continuation?.resume()
    }

    func releaseBlockedAcknowledgement(_ value: String) {
        let continuation = blockedAcknowledgement
        blockedAcknowledgement = nil
        continuation?.resume(returning: value)
    }
}

enum FluentdTestConnectOutcome: Sendable {
    case transport(RecordingFluentdTransport)
    case failure(FluentdTestFailure)
    case block(RecordingFluentdTransport)
}

struct FluentdTestConnectCall: Equatable, Sendable {
    let endpoint: FluentdEndpoint
    let timeout: Duration
}

actor ScriptedFluentdTransportFactory: FluentdTransportFactory {
    private var outcomes: [FluentdTestConnectOutcome]
    private(set) var connectCalls = [FluentdTestConnectCall]()
    private var blockedConnect: CheckedContinuation<any FluentdTransport, Never>?
    private var blockedConnectTransport: RecordingFluentdTransport?

    init(_ outcomes: [FluentdTestConnectOutcome]) {
        self.outcomes = outcomes
    }

    var connectCallCount: Int { connectCalls.count }

    func connect(
        to endpoint: FluentdEndpoint,
        timeout: Duration
    ) async throws -> any FluentdTransport {
        connectCalls.append(
            FluentdTestConnectCall(endpoint: endpoint, timeout: timeout)
        )
        guard !outcomes.isEmpty else {
            throw FluentdTestFailure.exhausted
        }
        switch outcomes.removeFirst() {
        case .transport(let transport): return transport
        case .failure(let error): throw error
        case .block(let transport):
            return await withCheckedContinuation { continuation in
                blockedConnect = continuation
                blockedConnectTransport = transport
            }
        }
    }

    func waitUntilConnectBlocked(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock().now + timeout
        while blockedConnect == nil {
            guard ContinuousClock().now < deadline else {
                throw FluentdTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseBlockedConnect() {
        let continuation = blockedConnect
        let transport = blockedConnectTransport
        blockedConnect = nil
        blockedConnectTransport = nil
        if let transport {
            continuation?.resume(returning: transport)
        }
    }
}

actor BlockingFluentdTransportFactory: FluentdTransportFactory {
    private let transport: RecordingFluentdTransport
    private var continuation: CheckedContinuation<any FluentdTransport, Never>?

    init(transport: RecordingFluentdTransport) {
        self.transport = transport
    }

    func connect(
        to endpoint: FluentdEndpoint,
        timeout: Duration
    ) async throws -> any FluentdTransport {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock().now + timeout
        while continuation == nil {
            guard ContinuousClock().now < deadline else {
                throw FluentdTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: transport)
    }
}

actor FluentdTestCompletion {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

final class FluentdTestClock: FluentdClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration
    private var recordedSleeps = [Duration]()

    init(now: Duration = .zero) {
        self.current = now
    }

    var sleeps: [Duration] {
        lock.withLock { recordedSleeps }
    }

    func now() -> Duration {
        lock.withLock { current }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock {
            recordedSleeps.append(duration)
            current += duration
        }
    }

    func advance(by duration: Duration) {
        lock.withLock { current += duration }
    }
}

final class BlockingFluentdClock: FluentdClock, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var recordedSleeps = [Duration]()

    var sleeps: [Duration] {
        lock.withLock { recordedSleeps }
    }

    func now() -> Duration {
        .zero
    }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                recordedSleeps.append(duration)
                self.continuation = continuation
            }
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock().now + timeout
        while !lock.withLock({ continuation != nil }) {
            guard ContinuousClock().now < deadline else {
                throw FluentdTestFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        let blocked = lock.withLock {
            let blocked = continuation
            self.continuation = nil
            return blocked
        }
        blocked?.resume()
    }
}

struct FixedFluentdChunkIDGenerator: FluentdChunkIDGenerating {
    let chunkID: String

    func makeChunkID(timestamp: ContainerLogTimestamp) throws -> String {
        chunkID
    }
}

func fluentdTestConfiguration(
    endpoint: FluentdEndpoint? = nil,
    async: Bool = false,
    asyncReconnectInterval: Duration? = nil,
    bufferLimit: Int = 16,
    maximumRetries: Int = 3,
    retryWait: Duration = .milliseconds(10),
    requestAcknowledgement: Bool = false,
    subSecondPrecision: Bool = false,
    readTimeout: Duration? = nil,
    writeTimeout: Duration? = nil,
    tag: String = "0123456789ab",
    containerID: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    containerName: String = "/web",
    metadata: [String: String] = [:],
    policy: FluentdConnectionPolicy = .dockerCompatible
) throws -> FluentdDriverConfiguration {
    try FluentdDriverConfiguration(
        endpoint: endpoint
            ?? .tcp(
                FluentdNetworkAddress(host: "127.0.0.1", port: 24_224)
            ),
        async: async,
        asyncReconnectInterval: asyncReconnectInterval,
        bufferLimit: bufferLimit,
        maximumRetries: maximumRetries,
        retryWait: retryWait,
        requestAcknowledgement: requestAcknowledgement,
        subSecondPrecision: subSecondPrecision,
        readTimeout: readTimeout,
        writeTimeout: writeTimeout,
        tag: Data(tag.utf8),
        containerID: containerID,
        containerName: containerName,
        metadata: metadata,
        policy: policy
    )
}

func fluentdRecord(
    stream: ContainerLogStream = .stdout,
    payload: Data,
    timestamp: ContainerLogTimestamp? = nil,
    partial: ContainerLogPartialMetadataV1? = nil,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    let resolvedTimestamp =
        try timestamp
        ?? ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1,
            nanoseconds: 2
        )
    return try ContainerLogRecordV2(
        stream: stream,
        observation: ContainerLogObservation(
            wallClock: resolvedTimestamp,
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: partial,
        sequence: sequence,
        processGeneration: 1
    )
}

func fluentdPartial(
    id: String = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
    ordinal: UInt64,
    last: Bool
) throws -> ContainerLogPartialMetadataV1 {
    try ContainerLogPartialMetadataV1(
        validatingID: id,
        ordinal: ordinal,
        last: last
    )
}

func waitForFluentdCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock().now + timeout
    while !(await condition()) {
        guard ContinuousClock().now < deadline else {
            throw FluentdTestFailure.timedOut
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

func waitForFluentdFuture<Value: Sendable>(
    _ future: EventLoopFuture<Value>,
    timeout: Duration = .seconds(2)
) async throws -> Value {
    let result = future.eventLoop.makePromise(of: Value.self)
    let gate = FluentdTestFutureGate()
    let timeoutTask = future.eventLoop.scheduleTask(
        in: .nanoseconds(timeout.fluentdTestNanoseconds)
    ) {
        if gate.claimCompletion() {
            result.fail(FluentdTestFailure.timedOut)
        }
    }
    future.whenComplete { value in
        if gate.claimCompletion() {
            timeoutTask.cancel()
            result.completeWith(value)
        }
    }
    return try await result.futureResult.get()
}

private final class FluentdTestFutureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claimCompletion() -> Bool {
        lock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
    }
}

extension Duration {
    fileprivate var fluentdTestNanoseconds: Int64 {
        let components = self.components
        let (seconds, secondsOverflow) = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        let (result, additionOverflow) = seconds.addingReportingOverflow(
            components.attoseconds / 1_000_000_000
        )
        guard !additionOverflow else {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        return max(result, 0)
    }
}

func withFluentdEventLoopGroup<Result: Sendable>(
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
