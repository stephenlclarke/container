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
import Testing

@testable import ContainerRuntimeLinuxServer

struct ContainerLogDeliveryTests {
    @Test
    func dropsNewRecordWithoutEvictingQueuedRecord() throws {
        let destination = BlockingRecordDestination()
        let delivery = ContainerLogNonBlockingDelivery(
            destination: destination,
            capacityInBytes: 3
        )

        #expect(try delivery.enqueue(record("a", sequence: 1)) == .enqueued)
        try destination.waitUntilWriteStarted()
        #expect(try delivery.enqueue(record("bbb", sequence: 2)) == .enqueued)
        #expect(try delivery.enqueue(record("c", sequence: 3)) == .dropped)
        destination.releaseWrites()
        try delivery.close()

        #expect(destination.payloads == ["a", "bbb"])
        #expect(delivery.snapshot.enqueuedRecordCount == 2)
        #expect(delivery.snapshot.droppedRecordCount == 1)
        #expect(delivery.snapshot.deliveredRecordCount == 2)
    }

    @Test
    func admitsOneOversizedRecordWhenQueueIsEmpty() throws {
        let destination = BlockingRecordDestination()
        let delivery = ContainerLogNonBlockingDelivery(
            destination: destination,
            capacityInBytes: 1
        )

        _ = try delivery.enqueue(record("first", sequence: 1))
        try destination.waitUntilWriteStarted()
        #expect(try delivery.enqueue(record("oversized", sequence: 2)) == .enqueued)
        #expect(try delivery.enqueue(record("drop", sequence: 3)) == .dropped)
        destination.releaseWrites()
        try delivery.close()

        #expect(destination.payloads == ["first", "oversized"])
    }

    @Test
    func boundsZeroPayloadFloodByRecordCountAfterDockerByteAccounting() throws {
        let destination = BlockingRecordDestination()
        let delivery = try ContainerLogNonBlockingDelivery(
            destination: destination,
            maximumQueuedRecordCount: 3
        )

        #expect(try delivery.enqueue(record("", sequence: 1)) == .enqueued)
        try destination.waitUntilWriteStarted()
        #expect(try delivery.enqueue(record("", sequence: 2)) == .enqueued)
        #expect(try delivery.enqueue(record("", sequence: 3)) == .enqueued)
        #expect(try delivery.enqueue(record("", sequence: 4)) == .enqueued)
        #expect(try delivery.enqueue(record("", sequence: 5)) == .dropped)

        let bounded = delivery.snapshot
        #expect(bounded.queuedRecordCount == 3)
        #expect(bounded.queuedPayloadBytes == 0)
        #expect(bounded.payloadLimitDroppedRecordCount == 0)
        #expect(bounded.recordLimitDroppedRecordCount == 1)

        destination.releaseWrites()
        try delivery.close()
        #expect(destination.payloads == ["", "", "", ""])
    }

    @Test
    func zeroPayloadQueueDoesNotConsumeDockerOversizedAllowance() throws {
        let destination = BlockingRecordDestination()
        let delivery = try ContainerLogNonBlockingDelivery(
            destination: destination,
            capacityInBytes: 1,
            maximumQueuedRecordCount: 4
        )

        #expect(try delivery.enqueue(record("", sequence: 1)) == .enqueued)
        try destination.waitUntilWriteStarted()
        #expect(try delivery.enqueue(record("", sequence: 2)) == .enqueued)
        #expect(try delivery.enqueue(record("oversized", sequence: 3)) == .enqueued)
        #expect(try delivery.enqueue(record("", sequence: 4)) == .dropped)

        destination.releaseWrites()
        try delivery.close()

        #expect(destination.payloads == ["", "", "oversized"])
        #expect(delivery.snapshot.payloadLimitDroppedRecordCount == 1)
    }

    @Test
    func validatesMaximumQueuedRecordCountAtConstruction() {
        let destination = ScriptedRecordDestination()

        #expect(throws: ContainerLogDeliveryError.invalidMaximumQueuedRecordCount(0)) {
            try ContainerLogNonBlockingDelivery(
                destination: destination,
                maximumQueuedRecordCount: 0
            )
        }
        #expect(
            throws: ContainerLogDeliveryError.invalidMaximumQueuedRecordCount(
                ContainerLogNonBlockingDelivery.maximumSupportedQueuedRecordCount + 1
            )
        ) {
            try ContainerLogNonBlockingDelivery(
                destination: destination,
                maximumQueuedRecordCount:
                    ContainerLogNonBlockingDelivery.maximumSupportedQueuedRecordCount + 1
            )
        }
    }

    @Test
    func backgroundDriverFailureDoesNotStopLaterDelivery() throws {
        let destination = ScriptedRecordDestination(failingSequences: [1])
        let delivery = ContainerLogNonBlockingDelivery(destination: destination)

        _ = try delivery.enqueue(record("first", sequence: 1))
        _ = try delivery.enqueue(record("second", sequence: 2))
        try destination.waitForWriteCount(2)
        try delivery.close()

        #expect(destination.attemptedSequences == [1, 2])
        #expect(delivery.snapshot.deliveryFailureCount == 1)
        #expect(delivery.snapshot.deliveredRecordCount == 1)
    }

    @Test
    func closeDrainsUntilFirstFailureThenDiscardsRemainder() async throws {
        let destination = BlockingRecordDestination(failingSequences: [2])
        let delivery = ContainerLogNonBlockingDelivery(destination: destination)

        _ = try delivery.enqueue(record("first", sequence: 1))
        try destination.waitUntilWriteStarted()
        _ = try delivery.enqueue(record("second", sequence: 2))
        _ = try delivery.enqueue(record("third", sequence: 3))

        let closeTask = Task {
            try delivery.close()
        }
        try await waitUntil { delivery.snapshot.closing }
        destination.releaseWrites()
        try await closeTask.value

        #expect(destination.attemptedSequences == [1, 2])
        #expect(destination.closeCount == 1)
        #expect(delivery.snapshot.deliveryFailureCount == 1)
        #expect(delivery.snapshot.discardedDuringCloseCount == 1)
        #expect(delivery.snapshot.closed)
    }

    @Test
    func closeIsIdempotentAndRejectsLaterRecords() throws {
        let destination = ScriptedRecordDestination()
        let delivery = ContainerLogNonBlockingDelivery(destination: destination)

        try delivery.close()
        try delivery.close()

        #expect(destination.closeCount == 1)
        #expect(throws: ContainerLogDeliveryError.closed) {
            try delivery.enqueue(record("late", sequence: 1))
        }
    }

    @Test
    func closeFailureIsStableAndObservable() throws {
        let destination = ScriptedRecordDestination(closeFails: true)
        let delivery = ContainerLogNonBlockingDelivery(destination: destination)

        #expect(throws: DestinationError.scripted) {
            try delivery.close()
        }
        #expect(throws: DestinationError.scripted) {
            try delivery.close()
        }

        #expect(delivery.snapshot.closeFailureCount == 1)
        #expect(delivery.snapshot.closed)
        #expect(destination.closeCount == 1)
    }

    @Test
    func releasingIdleDeliveryClosesDestination() throws {
        let destination = ScriptedRecordDestination()
        var delivery: ContainerLogNonBlockingDelivery? = ContainerLogNonBlockingDelivery(
            destination: destination
        )

        delivery = nil

        #expect(delivery == nil)
        #expect(destination.closeCount == 1)
    }

    private func record(_ payload: String, sequence: UInt64) throws -> ContainerLogRecordV2 {
        let timestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)
        var splitter = ContainerLogRecordSplitterV1(stream: .stdout)
        var fragments: [ContainerLogRecordFragmentV1] = []
        splitter.append(
            Data(payload.utf8) + Data([UInt8(ascii: "\n")]),
            observationProvider: {
                ContainerLogObservation(
                    wallClock: timestamp,
                    monotonicInstant: ContinuousClock().now
                )
            },
            emit: { fragments.append($0) }
        )
        return try ContainerLogRecordV2(
            fragment: #require(fragments.first),
            sequence: sequence,
            processGeneration: 1
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DestinationError.timeout
    }
}

private enum DestinationError: Error, Equatable {
    case scripted
    case timeout
}

private final class ScriptedRecordDestination: ContainerLogRecordDestination, @unchecked Sendable {
    private let condition = NSCondition()
    private let failingSequences: Set<UInt64>
    private let closeFails: Bool
    private var storedAttemptedSequences: [UInt64] = []
    private var storedCloseCount = 0

    init(failingSequences: Set<UInt64> = [], closeFails: Bool = false) {
        self.failingSequences = failingSequences
        self.closeFails = closeFails
    }

    func write(_ record: ContainerLogRecordV2) throws {
        condition.lock()
        storedAttemptedSequences.append(record.sequence)
        condition.broadcast()
        condition.unlock()
        if failingSequences.contains(record.sequence) {
            throw DestinationError.scripted
        }
    }

    func close() throws {
        condition.lock()
        storedCloseCount += 1
        condition.broadcast()
        condition.unlock()
        if closeFails {
            throw DestinationError.scripted
        }
    }

    var attemptedSequences: [UInt64] {
        condition.withLock { storedAttemptedSequences }
    }

    var closeCount: Int {
        condition.withLock { storedCloseCount }
    }

    func waitForWriteCount(_ count: Int, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while storedAttemptedSequences.count < count {
            guard condition.wait(until: deadline) else {
                throw DestinationError.timeout
            }
        }
    }
}

private final class BlockingRecordDestination: ContainerLogRecordDestination, @unchecked Sendable {
    private let condition = NSCondition()
    private let failingSequences: Set<UInt64>
    private var blocked = true
    private var writeStarted = false
    private var storedPayloads: [String] = []
    private var storedAttemptedSequences: [UInt64] = []
    private var storedCloseCount = 0

    init(failingSequences: Set<UInt64> = []) {
        self.failingSequences = failingSequences
    }

    func write(_ record: ContainerLogRecordV2) throws {
        condition.lock()
        writeStarted = true
        condition.broadcast()
        while blocked {
            condition.wait()
        }
        storedAttemptedSequences.append(record.sequence)
        if !failingSequences.contains(record.sequence) {
            storedPayloads.append(String(decoding: record.payload, as: UTF8.self))
        }
        condition.broadcast()
        condition.unlock()
        if failingSequences.contains(record.sequence) {
            throw DestinationError.scripted
        }
    }

    func close() {
        condition.withLock {
            storedCloseCount += 1
        }
    }

    var payloads: [String] {
        condition.withLock { storedPayloads }
    }

    var attemptedSequences: [UInt64] {
        condition.withLock { storedAttemptedSequences }
    }

    var closeCount: Int {
        condition.withLock { storedCloseCount }
    }

    func waitUntilWriteStarted(timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !writeStarted {
            guard condition.wait(until: deadline) else {
                throw DestinationError.timeout
            }
        }
    }

    func releaseWrites() {
        condition.withLock {
            blocked = false
            condition.broadcast()
        }
    }
}

extension NSCondition {
    fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
