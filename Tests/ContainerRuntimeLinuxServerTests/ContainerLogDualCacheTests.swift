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

struct ContainerLogDualCacheTests {
    @Test
    func omittedModeKeepsPrimaryBlockingAndCacheNonBlocking() throws {
        let primary = DualCacheScriptedDestination()
        let cache = DualCacheScriptedDestination()
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration()
        )

        try destination.write(try record("one", sequence: 1))
        try cache.waitForWriteCount(1)
        try destination.close()

        #expect(destination.snapshot.primaryNonBlockingDelivery == nil)
        #expect(destination.snapshot.cacheNonBlockingDelivery != nil)
        #expect(primary.attemptedSequences == [1])
        #expect(cache.attemptedSequences == [1])
    }

    @Test
    func explicitBlockingUsesNoRing() throws {
        let primary = DualCacheScriptedDestination()
        let cache = DualCacheScriptedDestination()
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .blocking)
        )

        try destination.write(try record("one", sequence: 1))
        try destination.close()

        #expect(destination.snapshot.primaryNonBlockingDelivery == nil)
        #expect(destination.snapshot.cacheNonBlockingDelivery == nil)
        #expect(primary.attemptedSequences == [1])
        #expect(cache.attemptedSequences == [1])
    }

    @Test
    func explicitNonBlockingUsesIndependentPrimaryAndCacheRings() throws {
        let primary = DualCacheBlockingDestination()
        let cache = DualCacheBlockingDestination()
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(
                requestedMode: .nonBlocking,
                maxBufferSizeInBytes: 3
            )
        )

        try destination.write(try record("a", sequence: 1))
        try primary.waitUntilWriteStarted()
        try cache.waitUntilWriteStarted()
        try destination.write(try record("bbb", sequence: 2))
        try destination.write(try record("c", sequence: 3))

        let queued = destination.snapshot
        #expect(queued.primaryNonBlockingDelivery?.droppedRecordCount == 1)
        #expect(queued.cacheNonBlockingDelivery?.droppedRecordCount == 1)

        primary.releaseWrites()
        cache.releaseWrites()
        try destination.close()

        #expect(primary.attemptedSequences == [1, 2])
        #expect(cache.attemptedSequences == [1, 2])
    }

    @Test
    func blockingPrimaryFailureSkipsCache() throws {
        let primary = DualCacheScriptedDestination(failingWriteSequences: [1])
        let cache = DualCacheScriptedDestination()
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .blocking)
        )

        #expect(throws: DualCacheTestError.scripted) {
            try destination.write(try record("one", sequence: 1))
        }
        try destination.close()

        #expect(primary.attemptedSequences == [1])
        #expect(cache.attemptedSequences.isEmpty)
        #expect(destination.snapshot.primaryWriteFailureCount == 1)
        #expect(destination.snapshot.cacheWriteFailureCount == 0)
    }

    @Test
    func blockingCacheFailureOccursAfterPrimaryAndPropagates() throws {
        let primary = DualCacheScriptedDestination()
        let cache = DualCacheScriptedDestination(failingWriteSequences: [1])
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .blocking)
        )

        #expect(throws: DualCacheTestError.scripted) {
            try destination.write(try record("one", sequence: 1))
        }
        try destination.close()

        #expect(primary.attemptedSequences == [1])
        #expect(cache.attemptedSequences == [1])
        #expect(destination.snapshot.primaryWriteFailureCount == 0)
        #expect(destination.snapshot.cacheWriteFailureCount == 1)
    }

    @Test
    func asynchronousPrimaryFailureDoesNotSuppressCache() throws {
        let primary = DualCacheScriptedDestination(failingWriteSequences: [1])
        let cache = DualCacheScriptedDestination()
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .nonBlocking)
        )

        try destination.write(try record("one", sequence: 1))
        try primary.waitForWriteCount(1)
        try cache.waitForWriteCount(1)
        try destination.close()

        #expect(cache.attemptedSequences == [1])
        #expect(destination.snapshot.primaryNonBlockingDelivery?.deliveryFailureCount == 1)
    }

    @Test
    func closeAlwaysAttemptsCacheAndReportsOnlyStablePrimaryError() throws {
        let primary = DualCacheScriptedDestination(closeFails: true)
        let cache = DualCacheScriptedDestination(closeFails: true)
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .blocking)
        )

        #expect(throws: DualCacheTestError.scripted) {
            try destination.close()
        }
        #expect(throws: DualCacheTestError.scripted) {
            try destination.close()
        }

        #expect(primary.closeCount == 1)
        #expect(cache.closeCount == 1)
        #expect(destination.snapshot.primaryCloseFailureCount == 1)
        #expect(destination.snapshot.cacheCloseFailureCount == 1)
        #expect(destination.snapshot.closed)
    }

    @Test
    func cacheOnlyCloseFailureIsDiagnostic() throws {
        let primary = DualCacheScriptedDestination()
        let cache = DualCacheScriptedDestination(closeFails: true)
        let destination = ContainerLogDualCacheDestination(
            primary: primary,
            cache: cache,
            deliveryConfiguration: try LogDeliveryConfiguration(requestedMode: .blocking)
        )

        try destination.close()
        try destination.close()

        #expect(destination.snapshot.primaryCloseFailureCount == 0)
        #expect(destination.snapshot.cacheCloseFailureCount == 1)
        #expect(destination.snapshot.closed)
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
}

private enum DualCacheTestError: Error, Equatable {
    case scripted
    case timeout
}

private final class DualCacheScriptedDestination: ContainerLogRecordDestination,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private let failingWriteSequences: Set<UInt64>
    private let closeFails: Bool
    private var storedAttemptedSequences: [UInt64] = []
    private var storedCloseCount = 0

    init(failingWriteSequences: Set<UInt64> = [], closeFails: Bool = false) {
        self.failingWriteSequences = failingWriteSequences
        self.closeFails = closeFails
    }

    func write(_ record: ContainerLogRecordV2) throws {
        condition.withLock {
            storedAttemptedSequences.append(record.sequence)
            condition.broadcast()
        }
        if failingWriteSequences.contains(record.sequence) {
            throw DualCacheTestError.scripted
        }
    }

    func close() throws {
        condition.withLock {
            storedCloseCount += 1
        }
        if closeFails {
            throw DualCacheTestError.scripted
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
                throw DualCacheTestError.timeout
            }
        }
    }
}

private final class DualCacheBlockingDestination: ContainerLogRecordDestination,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var blocked = true
    private var writeStarted = false
    private var storedAttemptedSequences: [UInt64] = []

    func write(_ record: ContainerLogRecordV2) {
        condition.lock()
        writeStarted = true
        condition.broadcast()
        while blocked {
            condition.wait()
        }
        storedAttemptedSequences.append(record.sequence)
        condition.broadcast()
        condition.unlock()
    }

    func close() {}

    var attemptedSequences: [UInt64] {
        condition.withLock { storedAttemptedSequences }
    }

    func waitUntilWriteStarted(timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !writeStarted {
            guard condition.wait(until: deadline) else {
                throw DualCacheTestError.timeout
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
