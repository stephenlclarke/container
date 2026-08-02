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

struct FluentdSessionTests {
    @Test func synchronousStartConnectsEagerlyAndForwardsSubSecondTimeouts() async throws {
        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let policy = try FluentdConnectionPolicy(
            connectTimeout: .milliseconds(25),
            closeTimeout: .milliseconds(30),
            maximumAcknowledgementBytes: 512
        )
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                maximumRetries: 1,
                writeTimeout: .microseconds(750),
                policy: policy
            ),
            transportFactory: factory
        )

        #expect(await factory.connectCallCount == 1)
        #expect(await factory.connectCalls.first?.timeout == .milliseconds(25))
        try await session.write(fluentdRecord(payload: Data()))
        #expect(await transport.messages.count == 1)
        #expect(await transport.writeTimeouts == [.microseconds(750)])

        try await session.close(deadline: ContinuousClock().now + .seconds(1))
        try await session.close(deadline: ContinuousClock().now + .seconds(1))
        #expect(await transport.closeTimeouts == [.milliseconds(30)])
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await session.write(
                fluentdRecord(payload: Data("late".utf8))
            )
        }
    }

    @Test func ackMismatchReconnectsAndRetriesIdenticalBytesAndChunk() async throws {
        let first = RecordingFluentdTransport(
            acknowledgementOutcomes: [.acknowledgement("wrong")]
        )
        let replacement = RecordingFluentdTransport(
            acknowledgementOutcomes: [.acknowledgement("chunk-1")]
        )
        let factory = ScriptedFluentdTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let configuration = try fluentdTestConfiguration(
            maximumRetries: 2,
            requestAcknowledgement: true,
            readTimeout: .microseconds(500),
            writeTimeout: .microseconds(750)
        )
        let session = try await FluentdDriverSession(
            configuration: configuration,
            transportFactory: factory,
            chunkIDGenerator: FixedFluentdChunkIDGenerator(
                chunkID: "chunk-1"
            )
        )

        try await session.write(
            fluentdRecord(payload: Data([0x00, 0xff]))
        )

        #expect(await factory.connectCallCount == 2)
        #expect(await first.closeCallCount == 1)
        #expect(await first.messages == replacement.messages)
        #expect(await first.readTimeouts == [.microseconds(500)])
        #expect(await replacement.readTimeouts == [.microseconds(500)])
        #expect(
            await replacement.acknowledgementLimits
                == [configuration.policy.maximumAcknowledgementBytes]
        )
    }

    @Test func repeatedAckMismatchExhaustsWritesWithoutChangingBytes() async throws {
        let first = RecordingFluentdTransport(
            acknowledgementOutcomes: [.acknowledgement("wrong-1")]
        )
        let second = RecordingFluentdTransport(
            acknowledgementOutcomes: [.acknowledgement("wrong-2")]
        )
        let factory = ScriptedFluentdTransportFactory([
            .transport(first),
            .transport(second),
        ])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                maximumRetries: 2,
                requestAcknowledgement: true
            ),
            transportFactory: factory,
            chunkIDGenerator: FixedFluentdChunkIDGenerator(
                chunkID: "stable-chunk"
            )
        )

        await #expect(
            throws: FluentdProviderError.writeRetriesExhausted(attempts: 2)
        ) {
            try await session.write(
                fluentdRecord(payload: Data("same-event".utf8))
            )
        }

        #expect(await factory.connectCallCount == 2)
        #expect(await first.closeCallCount == 1)
        #expect(await second.closeCallCount == 1)
        #expect(await first.messages == second.messages)
    }

    @Test func reconnectHonorsMaxRetriesAndDockerBackoffSequence() async throws {
        let retryWait = Duration.milliseconds(10)
        #expect(
            (0...7).map {
                FluentdDriverSession.retryDelay(
                    retryWait: retryWait,
                    beforeConnectionAttempt: $0
                )
            }
                == [
                    .zero,
                    .zero,
                    .milliseconds(10),
                    .milliseconds(10),
                    .milliseconds(20),
                    .milliseconds(30),
                    .milliseconds(50),
                    .milliseconds(70),
                ]
        )

        let initial = RecordingFluentdTransport(
            writeOutcomes: [.failure(.write)]
        )
        let replacement = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(initial),
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .transport(replacement),
        ])
        let clock = FluentdTestClock()
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                maximumRetries: 6,
                retryWait: retryWait
            ),
            transportFactory: factory,
            clock: clock
        )

        try await session.write(
            fluentdRecord(payload: Data("retry".utf8))
        )

        #expect(await factory.connectCallCount == 7)
        #expect(
            clock.sleeps
                == [
                    .milliseconds(10),
                    .milliseconds(10),
                    .milliseconds(20),
                    .milliseconds(30),
                ]
        )
        #expect(await initial.closeCallCount == 1)
        #expect(await replacement.messages.count == 1)
    }

    @Test func acknowledgementQueuedBeforePeerCloseIsDrainedFirst() async throws {
        try await withFluentdEventLoopGroup { group in
            let eventLoop = group.next()
            let inbound = FluentdInboundByteHandler()
            let acknowledgement = FluentdForwardAcknowledgementCodec.encode(
                chunkID: "chunk-before-close"
            )

            try await waitForFluentdFuture(
                eventLoop.submit {
                    #expect(inbound.enqueue(acknowledgement) == nil)
                    inbound.finish(FluentdProviderError.transportClosed)
                }
            )

            let drained = try await waitForFluentdFuture(
                inbound.next(on: eventLoop)
            )
            #expect(
                try FluentdForwardAcknowledgementCodec.decode(drained)?.chunkID
                    == "chunk-before-close"
            )
            await #expect(throws: FluentdProviderError.transportClosed) {
                _ = try await waitForFluentdFuture(
                    inbound.next(on: eventLoop)
                )
            }
        }
    }

    @Test func asyncStartDoesNotConnectAndBufferDrainsInOrder() async throws {
        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                maximumRetries: 1
            ),
            transportFactory: factory
        )

        #expect(await factory.connectCallCount == 0)
        try await session.write(
            fluentdRecord(payload: Data("first".utf8), sequence: 1)
        )
        try await session.write(
            fluentdRecord(payload: Data("second".utf8), sequence: 2)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(2)
        )

        #expect(await factory.connectCallCount == 1)
        #expect(await transport.messages.count == 2)
        #expect(await session.bufferedEventCount() == 0)
        try await session.closeUsingPolicy()
    }

    @Test func asyncBufferCountsQueuedEventsAndFailsWhenFull() async throws {
        let transport = RecordingFluentdTransport(writeOutcomes: [.block])
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                bufferLimit: 1,
                maximumRetries: 1
            ),
            transportFactory: factory
        )

        try await session.write(
            fluentdRecord(payload: Data("in-flight".utf8), sequence: 1)
        )
        try await transport.waitUntilWriteBlocked()
        try await session.write(
            fluentdRecord(payload: Data("queued".utf8), sequence: 2)
        )
        await #expect(throws: FluentdProviderError.bufferFull(limit: 1)) {
            try await session.write(
                fluentdRecord(payload: Data("rejected".utf8), sequence: 3)
            )
        }

        try await session.fence(timeout: .milliseconds(20))
        #expect(await session.currentState() == .writerFenced)
        #expect(await session.bufferedEventCount() == 0)
    }

    @Test func asyncReconnectIntervalReplacesConnectionBeforeNextEvent() async throws {
        let first = RecordingFluentdTransport()
        let replacement = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let clock = FluentdTestClock()
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                asyncReconnectInterval: .milliseconds(100),
                maximumRetries: 1
            ),
            transportFactory: factory,
            clock: clock
        )

        try await session.write(
            fluentdRecord(payload: Data("one".utf8), sequence: 1)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )
        clock.advance(by: .milliseconds(101))
        try await session.write(
            fluentdRecord(payload: Data("two".utf8), sequence: 2)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )

        #expect(await factory.connectCallCount == 2)
        #expect(await first.closeCallCount == 1)
        #expect(await first.messages.count == 1)
        #expect(await replacement.messages.count == 1)
    }

    @Test func asyncReconnectIntervalRunsPinnedCycleBeforeFirstWrite() async throws {
        let replacement = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .transport(replacement),
        ])
        let clock = FluentdTestClock()
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                asyncReconnectInterval: .milliseconds(100),
                maximumRetries: 3,
                retryWait: .milliseconds(10)
            ),
            transportFactory: factory,
            clock: clock
        )

        try await session.write(
            fluentdRecord(payload: Data("first".utf8), sequence: 1)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )

        #expect(await factory.connectCallCount == 4)
        #expect(clock.sleeps == [.milliseconds(10)])
        #expect(await replacement.messages.count == 1)
    }

    @Test func asyncReconnectIntervalRepeatsPinnedCycleAfterExhaustion() async throws {
        let first = RecordingFluentdTransport()
        let replacement = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(first),
            .failure(.connect),
            .failure(.connect),
            .failure(.connect),
            .transport(replacement),
        ])
        let clock = FluentdTestClock()
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                asyncReconnectInterval: .milliseconds(100),
                maximumRetries: 3,
                retryWait: .milliseconds(10)
            ),
            transportFactory: factory,
            clock: clock
        )

        try await session.write(
            fluentdRecord(payload: Data("one".utf8), sequence: 1)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )
        clock.advance(by: .milliseconds(101))
        try await session.write(
            fluentdRecord(payload: Data("two".utf8), sequence: 2)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )

        #expect(await factory.connectCallCount == 5)
        #expect(clock.sleeps == [.milliseconds(10)])
        #expect(await first.closeCallCount == 1)
        #expect(await replacement.messages.count == 1)
    }

    @Test func fenceInterruptsAnUnboundedAckReadAndPermanentlyStopsWrites() async throws {
        let transport = RecordingFluentdTransport(
            acknowledgementOutcomes: [.block]
        )
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                maximumRetries: 2,
                requestAcknowledgement: true,
                readTimeout: nil
            ),
            transportFactory: factory,
            chunkIDGenerator: FixedFluentdChunkIDGenerator(chunkID: "chunk")
        )
        let write = Task {
            try await session.write(
                fluentdRecord(payload: Data("waiting".utf8))
            )
        }
        try await transport.waitUntilAcknowledgementBlocked()

        try await session.fence(timeout: .milliseconds(20))
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await write.value
        }
        #expect(await session.currentState() == .writerFenced)
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await session.write(
                fluentdRecord(payload: Data("late".utf8))
            )
        }
        try await session.closeUsingPolicy()
        #expect(await session.currentState() == .closed)
    }

    @Test func asyncFenceWaitsForConnectingWorkerAndClosesLateConnection() async throws {
        let transport = RecordingFluentdTransport()
        let factory = BlockingFluentdTransportFactory(transport: transport)
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                maximumRetries: 1
            ),
            transportFactory: factory
        )
        try await session.write(
            fluentdRecord(payload: Data("connecting".utf8))
        )
        try await factory.waitUntilBlocked()

        let completion = FluentdTestCompletion()
        let fence = Task {
            do {
                try await session.fence(timeout: .seconds(1))
                await completion.markCompleted()
            } catch {
                await completion.markCompleted()
                throw error
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.completed == false)

        await factory.release()
        try await fence.value

        #expect(await completion.completed)
        #expect(await transport.closeCallCount == 1)
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func synchronousFenceWaitsForBlockedConnectAndClosesLateTransport() async throws {
        let initial = RecordingFluentdTransport(
            writeOutcomes: [.failure(.write)]
        )
        let late = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(initial),
            .block(late),
        ])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(maximumRetries: 2),
            transportFactory: factory
        )
        let write = Task {
            try await session.write(
                fluentdRecord(payload: Data("blocked-connect".utf8))
            )
        }
        try await factory.waitUntilConnectBlocked()

        let completion = FluentdTestCompletion()
        let fence = Task {
            do {
                try await session.fence(timeout: .seconds(1))
                await completion.markCompleted()
            } catch {
                await completion.markCompleted()
                throw error
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.completed == false)

        await factory.releaseBlockedConnect()
        try await fence.value
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await write.value
        }

        #expect(await late.closeCallCount == 1)
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func timedOutFenceStaysClosingUntilBlockedConnectQuiesces() async throws {
        let late = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.block(late)])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                maximumRetries: 1
            ),
            transportFactory: factory
        )
        try await session.write(
            fluentdRecord(payload: Data("blocked-connect".utf8))
        )
        try await factory.waitUntilConnectBlocked()

        await #expect(throws: FluentdProviderError.closeTimedOut) {
            try await session.fence(timeout: .milliseconds(10))
        }
        #expect(await session.currentState() == .closing)
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await session.write(
                fluentdRecord(payload: Data("late-write".utf8))
            )
        }

        await factory.releaseBlockedConnect()
        try await waitForFluentdCondition {
            await late.closeCallCount == 1
        }
        #expect(await session.currentState() == .closing)

        try await session.fence(timeout: .seconds(1))
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func synchronousFenceWaitsForRetrySleepAndPreventsLateConnect() async throws {
        let initial = RecordingFluentdTransport(
            writeOutcomes: [.failure(.write)]
        )
        let unused = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(initial),
            .failure(.connect),
            .failure(.connect),
            .transport(unused),
        ])
        let clock = BlockingFluentdClock()
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                maximumRetries: 3,
                retryWait: .milliseconds(10)
            ),
            transportFactory: factory,
            clock: clock
        )
        let write = Task {
            try await session.write(
                fluentdRecord(payload: Data("retry-sleep".utf8))
            )
        }
        try await clock.waitUntilBlocked()

        let completion = FluentdTestCompletion()
        let fence = Task {
            do {
                try await session.fence(timeout: .seconds(1))
                await completion.markCompleted()
            } catch {
                await completion.markCompleted()
                throw error
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.completed == false)

        clock.release()
        try await fence.value
        await #expect(throws: FluentdProviderError.transportClosed) {
            try await write.value
        }

        #expect(await factory.connectCallCount == 3)
        #expect(await unused.closeCallCount == 0)
        #expect(await session.currentState() == .writerFenced)
    }

    @Test func serializesSuspendingSynchronousWrites() async throws {
        let transport = RecordingFluentdTransport(writeOutcomes: [.block, .success])
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(maximumRetries: 1),
            transportFactory: factory
        )
        let first = Task {
            try await session.write(
                fluentdRecord(payload: Data("first".utf8), sequence: 1)
            )
        }
        try await transport.waitUntilWriteBlocked()
        let second = Task {
            try await session.write(
                fluentdRecord(payload: Data("second".utf8), sequence: 2)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.messages.count == 1)

        await transport.releaseBlockedWrite()
        try await first.value
        try await second.value
        #expect(await transport.messages.count == 2)
    }

    @Test func asyncFailureDropsOnlyFailedEventAndContinues() async throws {
        let first = RecordingFluentdTransport(
            writeOutcomes: [.failure(.write)]
        )
        let replacement = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .transport(first),
            .transport(replacement),
        ])
        let session = try await FluentdDriverSession(
            configuration: fluentdTestConfiguration(
                async: true,
                maximumRetries: 1
            ),
            transportFactory: factory
        )

        try await session.write(
            fluentdRecord(payload: Data("dropped".utf8), sequence: 1)
        )
        try await waitForFluentdCondition {
            await session.deliveryFailureCount() == 1
        }
        try await session.write(
            fluentdRecord(payload: Data("delivered".utf8), sequence: 2)
        )
        try await session.flush(
            deadline: ContinuousClock().now + .seconds(1)
        )

        #expect(await replacement.messages.count == 1)
        #expect(await session.deliveryFailureCount() == 1)
    }
}
