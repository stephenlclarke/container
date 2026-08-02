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
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

@Suite(.serialized)
struct ContainerLogLiveReaderTests {
    @Test
    func jsonFileReplayToFollowIsGapFreeAcrossRotation() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try DockerJSONFileLogStore(
            directoryURL: directory,
            activeFileName: "container.log",
            configuration: DockerJSONFileLogConfiguration(
                maximumFileSize: 512,
                maximumFileCount: 32,
                compress: false
            )
        )
        let session = try ContainerLogRecordSession(
            destination: store,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout],
            processGeneration: 9,
            attributes: ["service": "reader"]
        )
        let stdout = session.writer(for: .stdout)

        for index in 0..<20 {
            try stdout.write(Data("history-\(index)\n".utf8))
        }
        let reader = try session.makeReader(
            request: ContainerLogReadRequest(follow: true)
        )
        for index in 0..<20 {
            try stdout.write(Data("live-\(index)\n".utf8))
        }
        try stdout.close()

        let records = try await drain(reader)
        let expected =
            (0..<20).map { Data("history-\($0)\n".utf8) }
            + (0..<20).map { Data("live-\($0)\n".utf8) }
        #expect(records.map(\.data) == expected)
        #expect(records.allSatisfy { $0.stream == .stdout })
        #expect(records.prefix(20).allSatisfy { $0.processGeneration == nil })
        #expect(records.suffix(20).allSatisfy { $0.processGeneration == 9 })
        await #expect(throws: ContainerLogReaderError.alreadyEnded) {
            try await reader.next()
        }
    }

    @Test
    func tailZeroSkipsHistoryButStillFollowsAcceptedRecords() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try NativeLocalLogStore(
            directoryURL: directory,
            activeFileName: "local.bin",
            configuration: NativeLocalLogConfiguration()
        )
        let session = try ContainerLogRecordSession(
            destination: store,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout, .stderr],
            processGeneration: 4
        )
        let stdout = session.writer(for: .stdout)
        let stderr = session.writer(for: .stderr)
        try stdout.write(Data("old\n".utf8))

        let reader = try session.makeReader(
            request: ContainerLogReadRequest(
                stdout: false,
                stderr: true,
                follow: true,
                tail: 0
            )
        )
        try stdout.write(Data("filtered\n".utf8))
        try stderr.write(Data("visible\n".utf8))
        try stdout.close()
        try stderr.close()

        let records = try await drain(reader)
        #expect(records.map(\.data) == [Data("visible\n".utf8)])
        #expect(records.map(\.stream) == [.stderr])
        #expect(records.map(\.processGeneration) == [4])
    }

    @Test
    func failedDestinationWriteNeverBecomesReadable() async throws {
        let destination = FailingReadableDestination(failingSequences: [1])
        let session = try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout],
            processGeneration: 1
        )
        let reader = try session.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let stdout = session.writer(for: .stdout)

        try stdout.write(Data("not-persisted\n".utf8))
        try stdout.close()

        #expect(try await reader.next() == .endOfStream)
        #expect(session.snapshot.blockingDeliveryFailureCount == 1)
        #expect(destination.persistedRecords.isEmpty)
    }

    @Test
    func nonBlockingEnqueueIsNotPublishedBeforeDestinationAcceptance() async throws {
        let destination = FailingReadableDestination(failingSequences: [1])
        let session = try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: LogDeliveryConfiguration(
                requestedMode: .nonBlocking,
                maxBufferSizeInBytes: 1_024
            ),
            streams: [.stdout],
            processGeneration: 1
        )
        let reader = try session.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let stdout = session.writer(for: .stdout)

        try stdout.write(Data("accepted-by-queue-only\n".utf8))
        try stdout.close()

        #expect(try await reader.next() == .endOfStream)
        let delivery = try #require(session.snapshot.nonBlockingDelivery)
        #expect(delivery.enqueuedRecordCount == 1)
        #expect(delivery.deliveryFailureCount == 1)
        #expect(destination.persistedRecords.isEmpty)
    }

    @Test
    func slowFollowerFailsWithinItsBoundWithoutBlockingTheWriter() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try NativeLocalLogStore(
            directoryURL: directory,
            activeFileName: "local.bin",
            configuration: NativeLocalLogConfiguration()
        )
        let session = try ContainerLogRecordSession(
            destination: store,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout],
            processGeneration: 1,
            maximumLiveReaderBufferSizeInBytes: 128
        )
        let reader = try session.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let stdout = session.writer(for: .stdout)

        try stdout.write(Data("first\nsecond\nthird\n".utf8))
        try stdout.close()

        await #expect(
            throws: ContainerLogReaderError.consumerTooSlow(
                maximumBufferedBytes: 128
            )
        ) {
            try await reader.next()
        }
        #expect(session.snapshot.blockingDeliveryFailureCount == 0)
        #expect(store.snapshot.closed)
    }

    @Test
    func explicitCancellationWakesOnePendingPull() async throws {
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: FailingReadableDestination(failingSequences: [])
        )
        let reader = try coordinator.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let pending = Task {
            try await reader.next()
        }
        try await waitUntil { coordinator.snapshot.waitingReaderCount == 1 }
        await reader.cancel()

        await #expect(throws: ContainerLogReaderError.cancelled) {
            try await pending.value
        }
        #expect(coordinator.snapshot.readerCount == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
        try coordinator.close()
    }

    @Test
    func taskCancellationThroughExistentialReleasesPendingSubscriber() async throws {
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: FailingReadableDestination(failingSequences: [])
        )
        let reader: any ContainerLogReader = try coordinator.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let pending = Task {
            try await reader.next()
        }
        try await waitUntil { coordinator.snapshot.waitingReaderCount == 1 }

        pending.cancel()

        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
        try await waitUntil { coordinator.snapshot.readerCount == 0 }
        #expect(coordinator.snapshot.waitingReaderCount == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
        try coordinator.close()
    }

    @Test
    func concurrentPullIsRejectedWithoutDisturbingTheFirstPull() async throws {
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: FailingReadableDestination(failingSequences: [])
        )
        let reader = try coordinator.makeReader(
            request: ContainerLogReadRequest(follow: true, tail: 0)
        )
        let first = Task {
            try await reader.next()
        }
        try await waitUntil { coordinator.snapshot.waitingReaderCount == 1 }

        await #expect(throws: ContainerLogReaderError.concurrentReadNotSupported) {
            try await reader.next()
        }
        #expect(coordinator.snapshot.waitingReaderCount == 1)
        try coordinator.close()
        #expect(try await first.value == .endOfStream)
    }

    @Test
    func bufferedHistoryRejectsConcurrentNextForTheEntireCall() async throws {
        let gate = AsyncLiveReaderGate()
        let destination = FailingReadableDestination(failingSequences: [])
        try destination.write(try record(payload: "history", sequence: 1))
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: destination,
            hooks: ContainerLogCanonicalReadCoordinatorHooks(
                nextCallAdmitted: { await gate.block() }
            )
        )
        let reader: any ContainerLogReader = try coordinator.makeReader(
            request: ContainerLogReadRequest()
        )
        let first = Task {
            try await reader.next()
        }
        await gate.waitUntilEntered()

        await #expect(throws: ContainerLogReaderError.concurrentReadNotSupported) {
            try await reader.next()
        }

        await gate.release()
        #expect(try await first.value == .record(try destination.presentationRecord(for: record(payload: "history", sequence: 1))))
        await reader.cancel()
        #expect(coordinator.snapshot.readerCount == 0)
    }

    @Test
    func readerAdmissionAndAggregateHistoryAccountingAreReleasedExactly() async throws {
        let destination = FailingReadableDestination(failingSequences: [])
        try destination.write(try record(payload: "history", sequence: 1))
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: destination,
            maximumLiveBufferedBytes: 100,
            maximumAggregateBufferedBytes: 100,
            maximumConcurrentReaders: 1
        )
        let first = try coordinator.makeReader(request: ContainerLogReadRequest())
        #expect(coordinator.snapshot.readerCount == 1)
        #expect(coordinator.snapshot.historyBufferedRecordCount == 1)
        #expect(coordinator.snapshot.historyBufferedBytes == 72)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 72)

        #expect(
            throws: ContainerLogReaderError.readerLimitExceeded(maximumReaders: 1)
        ) {
            try coordinator.makeReader(request: ContainerLogReadRequest())
        }

        #expect(try await first.next() == .record(try destination.presentationRecord(for: record(payload: "history", sequence: 1))))
        #expect(coordinator.snapshot.historyBufferedBytes == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
        #expect(try await first.next() == .endOfStream)
        #expect(coordinator.snapshot.readerCount == 0)

        let second = try coordinator.makeReader(request: ContainerLogReadRequest())
        #expect(destination.historicalMaximumBytes == [100, 100])
        await second.cancel()
        #expect(coordinator.snapshot.readerCount == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
    }

    @Test
    func historyAndLiveShareOneAggregateBudgetAndFailureReleasesBoth() async throws {
        let destination = FailingReadableDestination(failingSequences: [])
        try destination.write(try record(payload: "history", sequence: 1))
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: destination,
            maximumLiveBufferedBytes: 100,
            maximumAggregateBufferedBytes: 100
        )
        let reader = try coordinator.makeReader(
            request: ContainerLogReadRequest(follow: true)
        )
        #expect(coordinator.snapshot.historyBufferedBytes == 72)

        try coordinator.write(try record(payload: "live-value", sequence: 2))

        #expect(coordinator.snapshot.historyBufferedBytes == 0)
        #expect(coordinator.snapshot.liveBufferedBytes == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
        await #expect(
            throws: ContainerLogReaderError.aggregateBufferLimitExceeded(
                maximumBufferedBytes: 100
            )
        ) {
            try await reader.next()
        }
        #expect(coordinator.snapshot.readerCount == 0)
        try coordinator.close()
    }

    @Test
    func historyLimitReceivesRemainingBudgetAndCancellationReleasesIt() async throws {
        let destination = FailingReadableDestination(failingSequences: [])
        try destination.write(try record(payload: "history", sequence: 1))
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: destination,
            maximumLiveBufferedBytes: 100,
            maximumAggregateBufferedBytes: 100,
            maximumConcurrentReaders: 2
        )
        let first = try coordinator.makeReader(request: ContainerLogReadRequest())

        #expect(
            throws: ContainerLogReaderError.historyBufferLimitExceeded(
                maximumBufferedBytes: 100
            )
        ) {
            try coordinator.makeReader(request: ContainerLogReadRequest())
        }
        #expect(destination.historicalMaximumBytes == [100, 28])
        #expect(coordinator.snapshot.readerCount == 1)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 72)

        await first.cancel()
        #expect(coordinator.snapshot.readerCount == 0)
        #expect(coordinator.snapshot.aggregateBufferedBytes == 0)
    }

    @Test
    func liveSinceGateStaysOpenAfterFirstQualifyingTimestamp() async throws {
        let coordinator = ContainerLogCanonicalReadCoordinator(
            destination: FailingReadableDestination(failingSequences: [])
        )
        let reader = try coordinator.makeReader(
            request: ContainerLogReadRequest(
                follow: true,
                tail: 0,
                since: Date(timeIntervalSince1970: 10)
            )
        )
        try coordinator.write(try record(payload: "before", seconds: 9, sequence: 1))
        try coordinator.write(try record(payload: "qualifying", seconds: 12, sequence: 2))
        try coordinator.write(try record(payload: "regressed", seconds: 8, sequence: 3))
        try coordinator.close()

        let records = try await drain(reader)
        #expect(records.map(\.data) == [Data("qualifying\n".utf8), Data("regressed\n".utf8)])
    }

    @Test
    func concurrentWriteDuringSnapshotOpenIsDeliveredExactlyOnce() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let snapshotEntered = DispatchSemaphore(value: 0)
        let releaseSnapshot = DispatchSemaphore(value: 0)
        let writeStarted = DispatchSemaphore(value: 0)
        defer { releaseSnapshot.signal() }
        let store = try DockerJSONFileLogStore(
            directoryURL: directory,
            activeFileName: "container.log",
            configuration: DockerJSONFileLogConfiguration(),
            hooks: DockerJSONFileLogStoreHooks(
                readPinnedSnapshotWillBegin: {
                    snapshotEntered.signal()
                    releaseSnapshot.wait()
                }
            )
        )
        let session = try ContainerLogRecordSession(
            destination: store,
            deliveryConfiguration: LogDeliveryConfiguration(),
            streams: [.stdout],
            processGeneration: 12
        )
        let stdout = session.writer(for: .stdout)
        try stdout.write(Data("history\n".utf8))

        let opening = Task.detached {
            try session.makeReader(
                request: ContainerLogReadRequest(follow: true)
            )
        }
        let observedSnapshot = await wait(for: snapshotEntered)
        #expect(observedSnapshot)
        let writing = Task.detached {
            writeStarted.signal()
            try stdout.write(Data("live\n".utf8))
        }
        let observedWrite = await wait(for: writeStarted)
        #expect(observedWrite)
        releaseSnapshot.signal()

        let reader = try await opening.value
        try await writing.value
        try stdout.close()

        let records = try await drain(reader)
        #expect(records.map(\.data) == [Data("history\n".utf8), Data("live\n".utf8)])
        #expect(records.map(\.processGeneration) == [nil, 12])
    }

    private func drain(
        _ reader: any ContainerLogReader
    ) async throws -> [ContainerLogReadRecordV1] {
        var records: [ContainerLogReadRecordV1] = []
        while true {
            switch try await reader.next() {
            case .record(let record):
                records.append(record)
            case .endOfStream:
                return records
            }
        }
    }

    private func record(
        payload: String,
        seconds: Int64 = 1,
        sequence: UInt64
    ) throws -> ContainerLogRecordV2 {
        try ContainerLogRecordV2(
            stream: .stdout,
            observation: ContainerLogObservation(
                wallClock: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: seconds,
                    nanoseconds: 0
                ),
                monotonicInstant: ContinuousClock().now
            ),
            payload: Data(payload.utf8),
            partial: nil,
            sequence: sequence,
            processGeneration: 1
        )
    }

    private func temporaryDirectory() throws -> URL {
        let temporaryRootPath = FileManager.default.temporaryDirectory.path
        let canonicalPointer = temporaryRootPath.withCString { realpath($0, nil) }
        guard let canonicalPointer else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(canonicalPointer) }
        let temporaryRoot = URL(
            fileURLWithPath: String(cString: canonicalPointer),
            isDirectory: true
        )
        let root =
            temporaryRoot
            .appendingPathComponent("container-live-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root.appendingPathComponent("logs", isDirectory: true)
    }

    private func removeTemporaryDirectory(_ logDirectory: URL) {
        try? FileManager.default.removeItem(at: logDirectory.deletingLastPathComponent())
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
        throw LiveReaderTestError.timeout
    }

    private func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime = .now() + 2
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: semaphore.wait(timeout: timeout) == .success
                )
            }
        }
    }
}

private enum LiveReaderTestError: Error {
    case timeout
}

private enum FailingReadableDestinationError: Error {
    case write
}

private final class FailingReadableDestination: ContainerLogCanonicalReadDestination,
    @unchecked Sendable
{
    private struct State {
        var records: [ContainerLogRecordV2] = []
        var closed = false
        var historicalMaximumBytes: [Int] = []
    }

    private let state = Mutex(State())
    private let failingSequences: Set<UInt64>

    init(failingSequences: Set<UInt64>) {
        self.failingSequences = failingSequences
    }

    func write(_ record: ContainerLogRecordV2) throws {
        if failingSequences.contains(record.sequence) {
            throw FailingReadableDestinationError.write
        }
        state.withLock { $0.records.append(record) }
    }

    func close() throws {
        state.withLock { $0.closed = true }
    }

    func historicalRecords(
        for request: ContainerLogReadRequest,
        maximumBytes: Int
    ) throws -> [ContainerLogReadRecordV1] {
        let records = state.withLock { state in
            state.historicalMaximumBytes.append(maximumBytes)
            return state.records
        }
        let selected = records.filter { record in
            (record.stream == .stdout && request.stdout)
                || (record.stream == .stderr && request.stderr)
        }
        let tailed: ArraySlice<ContainerLogRecordV2>
        if let tail = request.tail {
            tailed = selected.suffix(tail)
        } else {
            tailed = selected[...]
        }
        return try tailed.map(presentationRecord)
    }

    func presentationRecord(
        for record: ContainerLogRecordV2
    ) throws -> ContainerLogReadRecordV1 {
        var data = record.payload
        if record.partial == nil || record.partial?.last == true {
            data.append(UInt8(ascii: "\n"))
        }
        return try ContainerLogReadRecordV1(
            stream: record.stream,
            timestamp: record.observation.wallClock,
            data: data,
            attributes: record.attributes,
            sequence: record.sequence,
            processGeneration: record.processGeneration
        )
    }

    var persistedRecords: [ContainerLogRecordV2] {
        state.withLock(\.records)
    }

    var historicalMaximumBytes: [Int] {
        state.withLock(\.historicalMaximumBytes)
    }
}

private actor AsyncLiveReaderGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
