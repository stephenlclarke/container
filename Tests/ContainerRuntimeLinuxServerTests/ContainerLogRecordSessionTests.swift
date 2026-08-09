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
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct ContainerLogRecordSessionTests {
    @Test
    func sharesGlobalSequenceAcrossIndependentStreamSplitters() throws {
        let destination = CapturingRecordDestination()
        let session = try makeSession(destination: destination)
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)

        try stdout.write(Data("out-1\npartial".utf8))
        try stderr.write(Data("err-1\n".utf8))
        try stdout.close()
        try stderr.close()

        let records = destination.records
        #expect(records.map(\.sequence) == [1, 2, 3])
        #expect(records.map(\.stream) == [.stdout, .stderr, .stdout])
        #expect(
            records.map(\.payload) == [
                Data("out-1".utf8),
                Data("err-1".utf8),
                Data("partial".utf8),
            ])
        #expect(records[2].partial?.last == false)
        #expect(records.allSatisfy { $0.processGeneration == 7 })
        #expect(destination.closeCount == 1)
        #expect(session.snapshot.closed)
    }

    @Test
    func blockingDriverErrorsAreCountedWithoutClosingTheStream() throws {
        let destination = CapturingRecordDestination(failingWrites: [1])
        let session = try makeSession(destination: destination)
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)

        try stdout.write(Data("first\nsecond\n".utf8))
        try stderr.write(Data("third\n".utf8))
        try stdout.close()
        try stderr.close()

        #expect(destination.attemptedSequences == [1, 2, 3])
        #expect(destination.records.map(\.sequence) == [2, 3])
        #expect(session.snapshot.emittedRecordCount == 3)
        #expect(session.snapshot.blockingDeliveryFailureCount == 1)
    }

    @Test
    func closeWaitsForEveryExpectedStreamAndIsIdempotent() throws {
        let destination = CapturingRecordDestination()
        let session = try makeSession(destination: destination)
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)

        try stdout.close()
        try stdout.close()
        #expect(destination.closeCount == 0)
        try stderr.close()
        try stderr.close()

        #expect(destination.closeCount == 1)
        #expect(session.snapshot.closedStreams == Set([.stdout, .stderr]))
    }

    @Test
    func blockingCloseFailureIsCountedAndDoesNotEscapeTheStreamWriter() throws {
        let destination = CapturingRecordDestination(closeFails: true)
        let session = try makeSession(destination: destination)
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)

        try stdout.close()
        try stderr.close()

        #expect(session.snapshot.blockingDeliveryFailureCount == 0)
        #expect(session.snapshot.blockingCloseFailureCount == 1)
        #expect(session.snapshot.closed)
    }

    @Test
    func concurrentStreamsReceiveOneContiguousGlobalSequence() async throws {
        let destination = CapturingRecordDestination()
        let session = try makeSession(destination: destination)
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<200 {
                    try stdout.write(Data("out-\(index)\n".utf8))
                }
            }
            group.addTask {
                for index in 0..<200 {
                    try stderr.write(Data("err-\(index)\n".utf8))
                }
            }
            try await group.waitForAll()
        }
        try stdout.close()
        try stderr.close()

        let records = destination.records
        #expect(records.count == 400)
        #expect(records.map(\.sequence) == Array(1...400).map(UInt64.init))
        #expect(records.filter { $0.stream == .stdout }.count == 200)
        #expect(records.filter { $0.stream == .stderr }.count == 200)
    }

    @Test
    func nonBlockingSessionUsesConfiguredPayloadCapacity() throws {
        let destination = GateRecordDestination()
        let configuration = try LogDeliveryConfiguration(
            requestedMode: .nonBlocking,
            maxBufferSizeInBytes: 1
        )
        let session = try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: configuration,
            streams: [.stdout],
            processGeneration: 1,
            observationProvider: { ContainerLogObservation.now() }
        )
        let stdout = session.writer(for: .stdout)

        try stdout.write(Data("a\nb\nc\n".utf8))
        destination.release()
        try stdout.close()

        let delivery = try #require(session.snapshot.nonBlockingDelivery)
        #expect(delivery.enqueuedRecordCount >= 1)
        #expect(delivery.droppedRecordCount >= 1)
        #expect(delivery.closed)
    }

    @Test
    func continuesAfterImportedSequenceAcrossDurableBlocks() throws {
        let destination = CapturingRecordDestination()
        let reservations = Mutex([
            ContainerLogSequenceReservationV1(
                historyEpoch: 13,
                lowerBound: 102,
                upperBoundInclusive: 103
            )
        ])
        let session = try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout],
            processGeneration: 7,
            sequenceReservation: ContainerLogSequenceReservationV1(
                historyEpoch: 13,
                lowerBound: 100,
                upperBoundInclusive: 101
            ),
            sequenceReservationProvider: {
                try reservations.withLock { values in
                    guard !values.isEmpty else {
                        throw ExpectedRecordDestinationError.write
                    }
                    return values.removeFirst()
                }
            }
        )
        let stdout = session.writer(for: .stdout)
        try stdout.write(Data("one\ntwo\nthree\n".utf8))
        try stdout.close()

        #expect(destination.records.map(\.sequence) == [100, 101, 102])
    }

    @Test
    func rejectsInvalidGenerationAndInitialSequence() throws {
        let destination = CapturingRecordDestination()
        let delivery = try LogDeliveryConfiguration()
        #expect(throws: ContainerLogRecordSessionError.invalidProcessGeneration) {
            try ContainerLogRecordSession(
                destination: destination,
                deliveryConfiguration: delivery,
                streams: [.stdout],
                processGeneration: 0
            )
        }
        #expect(throws: ContainerLogRecordSessionError.invalidInitialSequence) {
            try ContainerLogRecordSession(
                destination: destination,
                deliveryConfiguration: delivery,
                streams: [.stdout],
                processGeneration: 1,
                initialSequence: 0
            )
        }
        #expect(throws: ContainerLogRecordSessionError.invalidStreams) {
            try ContainerLogRecordSession(
                destination: destination,
                deliveryConfiguration: delivery,
                streams: [],
                processGeneration: 1
            )
        }
        #expect(throws: ContainerLogRecordSessionError.invalidAttributes) {
            try ContainerLogRecordSession(
                destination: destination,
                deliveryConfiguration: delivery,
                streams: [.stdout],
                processGeneration: 1,
                attributes: [String(repeating: "k", count: 65 * 1024): "value"]
            )
        }
    }

    private func makeSession(
        destination: any ContainerLogRecordDestination
    ) throws -> ContainerLogRecordSession {
        try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout, .stderr],
            processGeneration: 7,
            attributes: ["service": "oracle"],
            observationProvider: { ContainerLogObservation.now() }
        )
    }
}

private enum ExpectedRecordDestinationError: Error {
    case write
}

private final class CapturingRecordDestination: ContainerLogRecordDestination, @unchecked Sendable {
    private struct State {
        var attemptedSequences: [UInt64] = []
        var records: [ContainerLogRecordV2] = []
        var closeCount = 0
    }

    private let state = Mutex(State())
    private let failingWrites: Set<UInt64>
    private let closeFails: Bool

    init(failingWrites: Set<UInt64> = [], closeFails: Bool = false) {
        self.failingWrites = failingWrites
        self.closeFails = closeFails
    }

    func write(_ record: ContainerLogRecordV2) throws {
        let shouldFail = state.withLock { state in
            state.attemptedSequences.append(record.sequence)
            return failingWrites.contains(record.sequence)
        }
        if shouldFail {
            throw ExpectedRecordDestinationError.write
        }
        state.withLock { $0.records.append(record) }
    }

    func close() throws {
        state.withLock { $0.closeCount += 1 }
        if closeFails {
            throw ExpectedRecordDestinationError.write
        }
    }

    var attemptedSequences: [UInt64] {
        state.withLock(\.attemptedSequences)
    }

    var records: [ContainerLogRecordV2] {
        state.withLock(\.records)
    }

    var closeCount: Int {
        state.withLock(\.closeCount)
    }
}

private final class GateRecordDestination: ContainerLogRecordDestination, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let firstWrite = Mutex(true)

    func write(_ record: ContainerLogRecordV2) throws {
        let shouldWait = firstWrite.withLock { firstWrite in
            defer { firstWrite = false }
            return firstWrite
        }
        if shouldWait {
            gate.wait()
        }
    }

    func close() throws {}

    func release() {
        gate.signal()
    }
}
