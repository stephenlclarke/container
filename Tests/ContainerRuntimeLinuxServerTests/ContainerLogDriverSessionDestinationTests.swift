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

struct ContainerLogDriverSessionDestinationTests {
    @Test
    func synchronouslyBackpressuresUntilProviderAcceptsRecord() async throws {
        let session = ScriptedDriverSession(blockWrites: true)
        let destination = try ContainerLogDriverSessionDestination(session: session)
        let write = Task.detached {
            try destination.write(try Self.record("blocked", sequence: 1))
        }

        try session.waitForWriteAttemptCount(1)
        #expect(!write.isCancelled)
        #expect(destination.snapshot.writeSuccessCount == 0)

        session.releaseWrites()
        try await write.value

        #expect(session.attemptedSequences == [1])
        #expect(destination.snapshot.writeAttemptCount == 1)
        #expect(destination.snapshot.writeSuccessCount == 1)
        #expect(destination.snapshot.writeFailureCount == 0)
        try destination.close()
    }

    @Test
    func serializesConcurrentWritesAtProviderBoundary() throws {
        let session = ScriptedDriverSession(writeDelay: .milliseconds(2))
        let destination = try ContainerLogDriverSessionDestination(session: session)
        let errors = ConcurrentDriverSessionErrorBox()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let sequence = index + 1
                try destination.write(
                    try Self.record("record-\(sequence)", sequence: UInt64(sequence))
                )
            } catch {
                errors.record(error)
            }
        }
        if let error = errors.first {
            throw error
        }
        try destination.close()

        #expect(session.maximumConcurrentWriteCount == 1)
        #expect(Set(session.attemptedSequences) == Set((1...32).map(UInt64.init)))
        #expect(destination.snapshot.writeSuccessCount == 32)
    }

    @Test
    func writeFailureDoesNotPoisonLaterRecords() throws {
        let session = ScriptedDriverSession(failingWriteSequences: [1])
        let destination = try ContainerLogDriverSessionDestination(session: session)

        #expect(throws: DriverSessionTestError.write) {
            try destination.write(try Self.record("first", sequence: 1))
        }
        try destination.write(try Self.record("second", sequence: 2))
        try destination.close()

        #expect(session.attemptedSequences == [1, 2])
        #expect(destination.snapshot.writeFailureCount == 1)
        #expect(destination.snapshot.writeSuccessCount == 1)
    }

    @Test
    func closeFlushesThenClosesOnceAndRejectsLateWrites() throws {
        let session = ScriptedDriverSession()
        let destination = try ContainerLogDriverSessionDestination(
            session: session,
            closeTimeout: .seconds(3)
        )

        try destination.write(try Self.record("one", sequence: 1))
        try destination.close()
        try destination.close()

        #expect(session.events == [.write(1), .flush, .close])
        #expect(session.flushDeadlines.count == 1)
        #expect(session.closeDeadlines == session.flushDeadlines)
        #expect(destination.snapshot.flushAttemptCount == 1)
        #expect(destination.snapshot.closeAttemptCount == 1)
        #expect(destination.snapshot.closed)
        #expect(throws: ContainerLogDriverSessionDestinationError.closed) {
            try destination.write(try Self.record("late", sequence: 2))
        }
    }

    @Test
    func flushFailureStillClosesAndIsStableAcrossReplay() throws {
        let session = ScriptedDriverSession(flushFails: true, closeFails: true)
        let destination = try ContainerLogDriverSessionDestination(session: session)

        #expect(throws: DriverSessionTestError.flush) {
            try destination.close()
        }
        #expect(throws: DriverSessionTestError.flush) {
            try destination.close()
        }

        #expect(session.events == [.flush, .close])
        #expect(destination.snapshot.flushFailureCount == 1)
        #expect(destination.snapshot.closeFailureCount == 1)
        #expect(destination.snapshot.closed)
    }

    @Test
    func validatesCloseTimeout() {
        let session = ScriptedDriverSession()

        #expect(throws: ContainerLogDriverSessionDestinationError.invalidCloseTimeout) {
            try ContainerLogDriverSessionDestination(session: session, closeTimeout: .zero)
        }
        #expect(throws: ContainerLogDriverSessionDestinationError.invalidCloseTimeout) {
            try ContainerLogDriverSessionDestination(session: session, closeTimeout: .seconds(-1))
        }
    }

    private static func record(_ payload: String, sequence: UInt64) throws -> ContainerLogRecordV2 {
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

private final class ConcurrentDriverSessionErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    var first: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: any Error) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }
}

private enum DriverSessionTestError: Error, Equatable {
    case write
    case flush
    case close
    case timeout
}

private enum DriverSessionEvent: Equatable {
    case write(UInt64)
    case flush
    case close
}

private final class ScriptedDriverSession: ContainerLogDriverSession, @unchecked Sendable {
    private struct State {
        var events: [DriverSessionEvent] = []
        var activeWriteCount = 0
        var maximumConcurrentWriteCount = 0
        var writesReleased: Bool
        var flushDeadlines: [ContinuousClock.Instant] = []
        var closeDeadlines: [ContinuousClock.Instant] = []
    }

    private let condition = NSCondition()
    private let failingWriteSequences: Set<UInt64>
    private let writeDelay: Duration?
    private let flushFails: Bool
    private let closeFails: Bool
    private var state: State

    init(
        blockWrites: Bool = false,
        failingWriteSequences: Set<UInt64> = [],
        writeDelay: Duration? = nil,
        flushFails: Bool = false,
        closeFails: Bool = false
    ) {
        self.failingWriteSequences = failingWriteSequences
        self.writeDelay = writeDelay
        self.flushFails = flushFails
        self.closeFails = closeFails
        self.state = State(writesReleased: !blockWrites)
    }

    func write(_ record: ContainerLogRecordV2) async throws {
        beginWrite(record.sequence)
        defer { endWrite() }

        if let writeDelay {
            try await Task.sleep(for: writeDelay)
        }

        if failingWriteSequences.contains(record.sequence) {
            throw DriverSessionTestError.write
        }
    }

    private func beginWrite(_ sequence: UInt64) {
        condition.lock()
        state.events.append(.write(sequence))
        state.activeWriteCount += 1
        state.maximumConcurrentWriteCount = max(
            state.maximumConcurrentWriteCount,
            state.activeWriteCount
        )
        condition.broadcast()
        while !state.writesReleased {
            condition.wait()
        }
        condition.unlock()
    }

    private func endWrite() {
        withState { state in
            state.activeWriteCount -= 1
        }
    }

    func flush(deadline: ContinuousClock.Instant) async throws {
        withState { state in
            state.events.append(.flush)
            state.flushDeadlines.append(deadline)
        }
        if flushFails {
            throw DriverSessionTestError.flush
        }
    }

    func close(deadline: ContinuousClock.Instant) async throws {
        withState { state in
            state.events.append(.close)
            state.closeDeadlines.append(deadline)
        }
        if closeFails {
            throw DriverSessionTestError.close
        }
    }

    var events: [DriverSessionEvent] {
        withState { $0.events }
    }

    var attemptedSequences: [UInt64] {
        withState { state in
            state.events.compactMap { event in
                if case .write(let sequence) = event {
                    sequence
                } else {
                    nil
                }
            }
        }
    }

    var maximumConcurrentWriteCount: Int {
        withState { $0.maximumConcurrentWriteCount }
    }

    var flushDeadlines: [ContinuousClock.Instant] {
        withState { $0.flushDeadlines }
    }

    var closeDeadlines: [ContinuousClock.Instant] {
        withState { $0.closeDeadlines }
    }

    func releaseWrites() {
        withState { state in
            state.writesReleased = true
            condition.broadcast()
        }
    }

    func waitForWriteAttemptCount(
        _ count: Int,
        timeout: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while state.events.lazy.filter({
            if case .write = $0 { true } else { false }
        }).count < count {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw DriverSessionTestError.timeout
            }
        }
        condition.unlock()
    }

    private func withState<Result>(
        _ body: (inout State) throws -> Result
    ) rethrows -> Result {
        condition.lock()
        defer { condition.unlock() }
        return try body(&state)
    }
}
