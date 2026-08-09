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
import Testing

@testable import ContainerLoggingProviders

struct GELFSessionTests {
    @Test func eagerlyConnectsAndSendsEachUDPDatagramExactlyOnce() async throws {
        let transport = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let configuration = try gelfTestConfiguration()
        let session = try await GELFDriverSession(
            configuration: configuration,
            transportFactory: factory
        )

        #expect(
            await factory.connectCalls
                == [
                    GELFTestConnectCall(
                        endpoint: configuration.endpoint,
                        timeout: .milliseconds(20)
                    )
                ]
        )
        try await session.write(gelfRecord(payload: Data()))
        #expect(await transport.messages.isEmpty)

        try await session.write(gelfRecord(payload: Data("udp".utf8)))
        #expect(await transport.messages.count == 1)
        #expect(await transport.writeTimeouts == [.milliseconds(30)])
        let received = try #require(await transport.messages.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: received) as? [String: Any]
        )
        #expect(object["short_message"] as? String == "udp")
    }

    @Test func UDPFailureAndPartialWriteNeverReconnect() async throws {
        let failed = RecordingGELFTransport(outcomes: [.failure(.write)])
        let failureFactory = ScriptedGELFTransportFactory([.transport(failed)])
        let failedSession = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: failureFactory
        )
        await #expect(throws: GELFTestFailure.write) {
            try await failedSession.write(gelfRecord(payload: Data("one".utf8)))
        }
        #expect(await failureFactory.connectCallCount == 1)
        #expect(await failed.closeCallCount == 0)

        let partial = RecordingGELFTransport(outcomes: [.partial(1)])
        let partialFactory = ScriptedGELFTransportFactory([.transport(partial)])
        let partialSession = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: partialFactory
        )
        await #expect(throws: (any Error).self) {
            try await partialSession.write(gelfRecord(payload: Data("two".utf8)))
        }
        #expect(await partialFactory.connectCallCount == 1)
        #expect(await partial.closeCallCount == 0)
    }

    @Test func TCPFramesWithNULAndSerializesSuspendingWrites() async throws {
        let transport = RecordingGELFTransport(outcomes: [.block, .success])
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                )
            ),
            transportFactory: factory
        )
        let first = Task {
            try await session.write(
                gelfRecord(payload: Data("first".utf8), sequence: 1)
            )
        }
        await transport.waitUntilWriteBlocked()
        let second = Task {
            try await session.write(
                gelfRecord(payload: Data("second".utf8), sequence: 2)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.messages.count == 1)

        await transport.releaseBlockedWrite()
        try await first.value
        try await second.value
        let messages = await transport.messages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.last == 0 })
        #expect(String(decoding: messages[0].dropLast(), as: UTF8.self).contains("first"))
        #expect(String(decoding: messages[1].dropLast(), as: UTF8.self).contains("second"))
    }

    @Test func tcpDropsFailedAndRecoverySettlementFramesWithoutReplay() async throws {
        let first = RecordingGELFTransport(outcomes: [.failure(.write)])
        let replacement = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let clock = GELFTestClock()
        let configuration = try gelfTestConfiguration(
            endpoint: .tcp(
                GELFNetworkAddress(host: "127.0.0.1", port: "12201")
            ),
            maximumReconnects: 2,
            reconnectDelay: .milliseconds(7)
        )
        let session = try await GELFDriverSession(
            configuration: configuration,
            transportFactory: factory,
            clock: clock
        )

        try await session.write(gelfRecord(payload: Data("dropped".utf8)))

        #expect(await factory.connectCallCount == 2)
        #expect(clock.sleeps == [.milliseconds(7)])
        #expect(await first.closeCallCount == 1)
        #expect(await replacement.messages.isEmpty)

        try await session.write(
            gelfRecord(payload: Data("settlement".utf8), sequence: 2)
        )
        #expect(await factory.connectCallCount == 2)
        #expect(await replacement.messages.isEmpty)

        try await session.write(
            gelfRecord(payload: Data("next".utf8), sequence: 3)
        )
        #expect(await replacement.messages.count == 1)
        let replacementFrame = try #require(await replacement.messages.first)
        #expect(String(decoding: replacementFrame.dropLast(), as: UTF8.self).contains("next"))
    }

    @Test func systemClockPermitsDockerStyleZeroReconnectDelay() async throws {
        try await SystemGELFClock().sleep(for: .zero)
    }

    @Test func tcpZeroReconnectDropsFailedAndSettlementFramesBeforeLaterDelivery() async throws {
        let first = RecordingGELFTransport(outcomes: [.failure(.write)])
        let replacement = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let clock = GELFTestClock()
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                ),
                maximumReconnects: 0,
                reconnectDelay: .milliseconds(9)
            ),
            transportFactory: factory,
            clock: clock
        )

        try await session.write(gelfRecord(payload: Data("lost".utf8)))
        #expect(await factory.connectCallCount == 2)
        #expect(clock.sleeps == [.milliseconds(9)])
        #expect(await replacement.messages.isEmpty)

        try await session.write(
            gelfRecord(payload: Data("settlement".utf8), sequence: 2)
        )
        #expect(await factory.connectCallCount == 2)
        #expect(await replacement.messages.isEmpty)

        try await session.write(
            gelfRecord(payload: Data("next".utf8), sequence: 3)
        )
        #expect(await replacement.messages.count == 1)
    }

    @Test func tcpReconnectExhaustionBoundsReplacementAttempts() async throws {
        let first = RecordingGELFTransport(outcomes: [.failure(.write)])
        let retainedFinalReplacement = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([
            .transport(first),
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .transport(retainedFinalReplacement),
        ])
        let clock = GELFTestClock()
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                ),
                maximumReconnects: 2,
                reconnectDelay: .milliseconds(7)
            ),
            transportFactory: factory,
            clock: clock
        )

        await #expect(throws: GELFProviderError.reconnectAttemptsExhausted(attempts: 3)) {
            try await session.write(gelfRecord(payload: Data("lost".utf8)))
        }
        #expect(await factory.connectCallCount == 4)
        #expect(
            clock.sleeps
                == [.milliseconds(7), .milliseconds(7), .milliseconds(7)]
        )
        #expect(await retainedFinalReplacement.messages.isEmpty)

        try await session.write(gelfRecord(payload: Data("next".utf8), sequence: 2))
        #expect(await factory.connectCallCount == 5)
        #expect(
            clock.sleeps
                == [.milliseconds(7), .milliseconds(7), .milliseconds(7), .milliseconds(7)]
        )
        #expect(await retainedFinalReplacement.messages.count == 1)
    }

    @Test func TCPPartialWriteDoesNotReconnect() async throws {
        let transport = RecordingGELFTransport(outcomes: [.partial(4)])
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                )
            ),
            transportFactory: factory
        )

        await #expect(throws: (any Error).self) {
            try await session.write(gelfRecord(payload: Data("partial".utf8)))
        }
        #expect(await factory.connectCallCount == 1)
        #expect(await transport.closeCallCount == 0)
    }

    @Test func cancellationDuringReconnectDelayPropagatesWithoutConnecting() async throws {
        let transport = RecordingGELFTransport(outcomes: [.failure(.write)])
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let clock = CancellingGELFTestClock()
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                )
            ),
            transportFactory: factory,
            clock: clock
        )

        await #expect(throws: CancellationError.self) {
            try await session.write(gelfRecord(payload: Data("cancel".utf8)))
        }
        #expect(clock.sleeps == [.milliseconds(10)])
        #expect(await factory.connectCallCount == 1)
        #expect(await transport.closeCallCount == 1)
    }

    @Test func fenceInterruptsBlockedWriteAndPermanentlyStopsDelivery() async throws {
        let transport = RecordingGELFTransport(outcomes: [.block])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(
                endpoint: .tcp(
                    GELFNetworkAddress(host: "127.0.0.1", port: "12201")
                )
            ),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )
        let write = Task {
            try await session.write(gelfRecord(payload: Data("blocked".utf8)))
        }
        await transport.waitUntilWriteBlocked()

        try await session.fence(timeout: .milliseconds(11))
        await #expect(throws: GELFProviderError.transportClosed) {
            try await write.value
        }
        #expect(await transport.closeTimeouts == [.milliseconds(11)])
        #expect(await session.currentState() == .writerFenced)
        await #expect(throws: GELFProviderError.transportClosed) {
            try await session.write(gelfRecord(payload: Data("late".utf8)))
        }
    }

    @Test func closeFailureRetainsRetryableNonterminalState() async throws {
        let transport = RecordingGELFTransport(
            closeOutcomes: [.failure(.close), .success]
        )
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )

        await #expect(throws: GELFTestFailure.close) {
            try await session.closeUsingPolicy()
        }
        #expect(await session.currentState() == .closing)
        #expect(await transport.closeCallCount == 1)
        await #expect(throws: GELFProviderError.transportClosed) {
            try await session.write(gelfRecord(payload: Data("late".utf8)))
        }

        try await session.closeUsingPolicy()
        #expect(await session.currentState() == .closed)
        #expect(await transport.closeCallCount == 2)
    }

    @Test func terminalCloseCancelsAndJoinsActiveAndQueuedWrites() async throws {
        let transport = RecordingGELFTransport(outcomes: [.block, .success])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )
        let first = Task {
            try await session.write(
                gelfRecord(payload: Data("first".utf8), sequence: 1)
            )
        }
        await transport.waitUntilWriteBlocked()
        let second = Task {
            try await session.write(
                gelfRecord(payload: Data("second".utf8), sequence: 2)
            )
        }

        try await session.fence(timeout: .milliseconds(40))
        await #expect(throws: GELFProviderError.transportClosed) {
            try await first.value
        }
        await #expect(throws: GELFProviderError.transportClosed) {
            try await second.value
        }
        #expect(await transport.messages.count == 1)
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func concurrentFenceAndCloseSerializeCleanupAndPublishClosed() async throws {
        let transport = RecordingGELFTransport(closeOutcomes: [.block])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )
        let fence = Task {
            try await session.fence(timeout: .milliseconds(40))
        }
        await transport.waitUntilCloseBlocked()
        let close = Task {
            try await session.closeUsingPolicy()
        }

        await Task.yield()
        #expect(await transport.closeCallCount == 1)
        await transport.releaseBlockedClose()
        try await fence.value
        try await close.value
        #expect(await transport.closeCallCount == 1)
        #expect(await session.currentState() == .closed)
    }

    @Test func closeDeadlineDoesNotPublishTerminalBeforeOperationJoins() async throws {
        let transport = RecordingGELFTransport(
            outcomes: [.block],
            closeOutcomes: [.successKeepingWriteBlocked]
        )
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )
        let write = Task {
            try await session.write(gelfRecord(payload: Data("blocked".utf8)))
        }
        await transport.waitUntilWriteBlocked()

        await #expect(throws: GELFProviderError.closeTimedOut) {
            try await session.fence(timeout: .milliseconds(5))
        }
        #expect(await session.currentState() == .closing)
        await transport.releaseBlockedWrite()
        await #expect(throws: GELFProviderError.transportClosed) {
            try await write.value
        }

        try await session.fence(timeout: .milliseconds(40))
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func flushFenceCloseAndDeadlineTransitionsArePermanent() async throws {
        let transport = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: factory
        )

        await #expect(throws: GELFProviderError.flushTimedOut) {
            try await session.flush(deadline: ContinuousClock().now - .milliseconds(1))
        }
        try await session.flush(deadline: ContinuousClock().now + .seconds(1))
        try await session.fence(timeout: .milliseconds(12))
        #expect(await session.currentState() == .writerFenced)
        #expect(await transport.closeTimeouts == [.milliseconds(12)])
        await #expect(throws: GELFProviderError.transportClosed) {
            try await session.write(gelfRecord(payload: Data("late".utf8)))
        }

        try await session.fence(timeout: .milliseconds(13))
        #expect(await transport.closeCallCount == 1)
        try await session.closeUsingPolicy()
        #expect(await session.currentState() == .closed)
        #expect(await transport.closeCallCount == 1)
    }

    @Test func closeClampsTransportTimeoutToExpiredDeadline() async throws {
        let transport = RecordingGELFTransport()
        let session = try await GELFDriverSession(
            configuration: gelfTestConfiguration(),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)])
        )

        try await session.close(deadline: ContinuousClock().now - .seconds(1))
        #expect(await transport.closeTimeouts == [.zero])
        #expect(await session.currentState() == .closed)
    }
}
