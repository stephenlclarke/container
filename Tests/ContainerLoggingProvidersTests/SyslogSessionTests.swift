//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct SyslogSessionTests {
    @Test func eagerlyConnectsIgnoresEmptyRecordsAndClosesIdempotently() async throws {
        let transport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([.transport(transport)])
        let session = try await makeSession(factory: factory)

        #expect(await factory.connectCallCount == 1)
        try await session.write(try syslogRecord(payload: Data()))
        #expect(await transport.messages.isEmpty)

        try await session.write(try syslogRecord(payload: Data("one".utf8)))
        #expect(await transport.messages.count == 1)
        try await session.flush(deadline: ContinuousClock().now + .seconds(1))
        try await session.close(deadline: ContinuousClock().now + .seconds(1))
        try await session.close(deadline: ContinuousClock().now + .seconds(1))

        #expect(await transport.closeCallCount == 1)
        #expect(await session.currentState() == .closed)
        await #expect(throws: SyslogProviderError.transportClosed) {
            try await session.write(try syslogRecord(payload: Data("late".utf8)))
        }
    }

    @Test func reconnectsOnceAndRetriesTheIdenticalFramedBytes() async throws {
        let first = RecordingSyslogTransport(writeOutcomes: [.failure(.write)])
        let replacement = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let session = try await makeSession(factory: factory)

        try await session.write(try syslogRecord(payload: Data([0x00, 0xff])))

        #expect(await factory.connectCallCount == 2)
        #expect(await first.closeCallCount == 1)
        let firstMessage = try #require(await first.messages.first)
        let replacementMessage = try #require(await replacement.messages.first)
        #expect(firstMessage == replacementMessage)
        #expect(firstMessage.suffix(3) == Data([0x00, 0xff, 0x0a]))
    }

    @Test func reconnectFailureIsReturnedWithoutAnUnboundedRetryLoop() async throws {
        let first = RecordingSyslogTransport(writeOutcomes: [.failure(.write)])
        let recovered = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([
            .transport(first),
            .failure(.connect),
            .transport(recovered),
        ])
        let session = try await makeSession(factory: factory)

        await #expect(throws: SyslogTestFailure.connect) {
            try await session.write(try syslogRecord(payload: Data("one".utf8)))
        }
        #expect(await factory.connectCallCount == 2)
        #expect(await first.messages.count == 1)

        try await session.write(try syslogRecord(payload: Data("two".utf8)))
        #expect(await factory.connectCallCount == 3)
        #expect(await recovered.messages.count == 1)
    }

    @Test func secondWriteFailureKeepsMobyCurrentConnectionSemantics() async throws {
        let first = RecordingSyslogTransport(writeOutcomes: [.failure(.write)])
        let replacement = RecordingSyslogTransport(writeOutcomes: [
            .failure(.write),
            .success,
        ])
        let factory = ScriptedSyslogTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let session = try await makeSession(factory: factory)

        await #expect(throws: SyslogTestFailure.write) {
            try await session.write(try syslogRecord(payload: Data("one".utf8)))
        }
        try await session.write(try syslogRecord(payload: Data("two".utf8)))

        // srslog retains the replacement after its retry fails. The next
        // message first tries that same connection before reconnecting.
        #expect(await factory.connectCallCount == 2)
        #expect(await replacement.messages.count == 2)
    }

    @Test func serializesSuspendingWritesAndPreservesRecordOrder() async throws {
        let transport = RecordingSyslogTransport(blockFirstWrite: true)
        let factory = ScriptedSyslogTransportFactory([.transport(transport)])
        let session = try await makeSession(factory: factory)

        let first = Task {
            try await session.write(try syslogRecord(payload: Data("first".utf8), sequence: 1))
        }
        await transport.waitUntilFirstWriteIsBlocked()
        let second = Task {
            try await session.write(try syslogRecord(payload: Data("second".utf8), sequence: 2))
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.messages.count == 1)
        await transport.releaseFirstWrite()
        try await first.value
        try await second.value

        let messages = await transport.messages
        #expect(messages.count == 2)
        #expect(String(decoding: messages[0], as: UTF8.self).hasSuffix("first\n"))
        #expect(String(decoding: messages[1], as: UTF8.self).hasSuffix("second\n"))
    }

    @Test func fencingClosesTheTransportAndPermanentlyRejectsWrites() async throws {
        let transport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([.transport(transport)])
        let session = try await makeSession(factory: factory)

        try await session.fence(timeout: .milliseconds(25))
        #expect(await session.currentState() == .writerFenced)
        #expect(await transport.closeTimeouts == [.milliseconds(25)])
        await #expect(throws: SyslogProviderError.transportClosed) {
            try await session.write(try syslogRecord(payload: Data("late".utf8)))
        }

        try await session.closeUsingPolicy()
        #expect(await session.currentState() == .closed)
        #expect(await transport.closeCallCount == 1)
    }
}

private func makeSession(
    factory: any SyslogTransportFactory
) async throws -> SyslogDriverSession {
    try await SyslogDriverSession(
        configuration: try syslogTestConfiguration(),
        transportFactory: factory,
        clock: SyslogTestClock()
    )
}

func syslogTestConfiguration(
    endpoint: SyslogEndpoint = .tcp(
        SyslogNetworkAddress(host: "127.0.0.1", port: "514")
    ),
    format: SyslogMessageFormat = .unix,
    tls: SyslogTLSConfiguration? = nil,
    policy: SyslogConnectionPolicy = .dockerCompatible
) throws -> SyslogDriverConfiguration {
    try SyslogDriverConfiguration(
        endpoint: endpoint,
        facility: SyslogFacility(number: 3),
        format: format,
        tag: "0123456789ab",
        hostname: "engine-host",
        processID: 4_242,
        tls: tls,
        policy: policy
    )
}

func syslogRecord(
    stream: ContainerLogStream = .stdout,
    payload: Data,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    try ContainerLogRecordV2(
        stream: stream,
        observation: ContainerLogObservation(
            wallClock: ContainerLogTimestamp(
                secondsSinceUnixEpoch: 1,
                nanoseconds: 2
            ),
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: nil,
        sequence: sequence,
        processGeneration: 1
    )
}

struct SyslogTestClock: SyslogClock {
    func now() -> SyslogClockReading {
        let timestamp: ContainerLogTimestamp
        do {
            timestamp = try ContainerLogTimestamp(
                secondsSinceUnixEpoch: 1_785_587_696,
                nanoseconds: 123_456_789
            )
        } catch {
            preconditionFailure("invalid fixed test timestamp: \(error)")
        }
        return SyslogClockReading(
            timestamp: timestamp,
            timeZoneSecondsFromGMT: 0
        )
    }
}

enum SyslogTestFailure: Error, Equatable, Sendable {
    case connect
    case write
    case close
    case exhausted
}

enum SyslogWriteOutcome: Sendable {
    case success
    case failure(SyslogTestFailure)
}

actor RecordingSyslogTransport: SyslogTransport {
    private(set) var messages = [Data]()
    private(set) var writeTimeouts = [Duration]()
    private(set) var closeTimeouts = [Duration]()
    private var outcomes: [SyslogWriteOutcome]
    private var blockFirstWrite: Bool
    private var blockedWrite: CheckedContinuation<Void, Never>?
    private var blockedWaiters = [CheckedContinuation<Void, Never>]()

    init(
        writeOutcomes: [SyslogWriteOutcome] = [],
        blockFirstWrite: Bool = false
    ) {
        self.outcomes = writeOutcomes
        self.blockFirstWrite = blockFirstWrite
    }

    var closeCallCount: Int { closeTimeouts.count }

    func write(_ message: Data, timeout: Duration) async throws {
        messages.append(message)
        writeTimeouts.append(timeout)
        if blockFirstWrite, messages.count == 1 {
            await withCheckedContinuation { continuation in
                if blockFirstWrite {
                    blockedWrite = continuation
                    let waiters = blockedWaiters
                    blockedWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                } else {
                    continuation.resume()
                }
            }
        }
        guard !outcomes.isEmpty else {
            return
        }
        switch outcomes.removeFirst() {
        case .success: return
        case .failure(let error): throw error
        }
    }

    func close(timeout: Duration) async throws {
        closeTimeouts.append(timeout)
    }

    func waitUntilFirstWriteIsBlocked() async {
        if blockedWrite != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        blockFirstWrite = false
        let continuation = blockedWrite
        blockedWrite = nil
        continuation?.resume()
    }
}

enum SyslogConnectOutcome: Sendable {
    case transport(RecordingSyslogTransport)
    case failure(SyslogTestFailure)
}

struct SyslogConnectCall: Equatable, Sendable {
    let endpoint: SyslogEndpoint
    let tls: SyslogTLSConfiguration?
    let timeout: Duration
}

actor ScriptedSyslogTransportFactory: SyslogTransportFactory {
    private var outcomes: [SyslogConnectOutcome]
    private(set) var connectCalls = [SyslogConnectCall]()

    init(_ outcomes: [SyslogConnectOutcome]) {
        self.outcomes = outcomes
    }

    var connectCallCount: Int { connectCalls.count }

    func connect(
        to endpoint: SyslogEndpoint,
        tls: SyslogTLSConfiguration?,
        timeout: Duration
    ) async throws -> any SyslogTransport {
        connectCalls.append(
            SyslogConnectCall(endpoint: endpoint, tls: tls, timeout: timeout)
        )
        guard !outcomes.isEmpty else {
            throw SyslogTestFailure.exhausted
        }
        switch outcomes.removeFirst() {
        case .transport(let transport): return transport
        case .failure(let error): throw error
        }
    }
}
