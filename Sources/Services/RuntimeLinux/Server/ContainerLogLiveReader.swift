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

import ContainerLoggingStorage
import ContainerResource
import Foundation

/// A canonical destination which can reconstruct the exact public record form
/// after persistence and can pin one bounded historical snapshot.
package protocol ContainerLogCanonicalReadDestination: ContainerLogRecordDestination {
    func historicalRecords(
        for request: ContainerLogReadRequest,
        maximumBytes: Int
    ) throws -> [ContainerLogReadRecordV1]

    func presentationRecord(
        for record: ContainerLogRecordV2
    ) throws -> ContainerLogReadRecordV1
}

private enum ContainerLogCanonicalReadDestinationError: Error {
    case historyLimitExceeded
}

package struct ContainerLogCanonicalReadCoordinatorHooks: Sendable {
    package let nextCallAdmitted: (@Sendable () async -> Void)?

    package init(
        nextCallAdmitted: (@Sendable () async -> Void)? = nil
    ) {
        self.nextCallAdmitted = nextCallAdmitted
    }
}

package struct ContainerLogCanonicalReadCoordinatorSnapshot: Equatable, Sendable {
    package let readerCount: Int
    package let waitingReaderCount: Int
    package let historyBufferedRecordCount: Int
    package let historyBufferedBytes: Int
    package let liveBufferedRecordCount: Int
    package let liveBufferedBytes: Int
    package let aggregateBufferedBytes: Int
    package let closed: Bool
}

/// Serializes persistence, snapshot acquisition, and live publication.
///
/// The destination is written before a record is published. This is important
/// for non-blocking delivery: enqueueing a record does not make it readable;
/// only the delivery worker's successful destination write does. Opening a
/// reader pins history and registers its live subscription under this same
/// lock, which makes the replay-to-follow handoff gap- and duplicate-free even
/// while files rotate.
///
/// The current store interfaces return materialized arrays, so snapshot decode
/// remains synchronous under this lock and briefly pauses publication. Passing
/// the remaining aggregate budget into each store bounds that transient work;
/// eliminating the pause requires a future streaming snapshot interface.
package final class ContainerLogCanonicalReadCoordinator: ContainerLogRecordDestination,
    @unchecked Sendable
{
    package static let defaultMaximumLiveBufferedBytes = 1 * 1024 * 1024
    package static let defaultMaximumAggregateBufferedBytes = 64 * 1024 * 1024
    package static let defaultMaximumConcurrentReaders = 32
    package static let maximumLiveBufferedRecords = 100_000

    private typealias ReadContinuation = CheckedContinuation<ContainerLogReaderEventV1, any Error>

    private enum Terminal {
        case endOfStream
        case failure(ContainerLogReaderError)
    }

    private struct Filter {
        let stdout: Bool
        let stderr: Bool
        var sinceGate: ContainerLogTimestamp?
        let until: ContainerLogTimestamp?

        mutating func includes(_ record: ContainerLogReadRecordV1) -> Bool {
            if let sinceGate {
                guard record.timestamp >= sinceGate else {
                    return false
                }
                self.sinceGate = nil
            }
            if let until, record.timestamp > until {
                return false
            }
            if record.stream == .stdout, !stdout {
                return false
            }
            if record.stream == .stderr, !stderr {
                return false
            }
            return true
        }
    }

    private struct Subscriber {
        var filter: Filter
        var history: [ContainerLogReadRecordV1]
        var historyIndex = 0
        var historyBufferedBytes: Int
        var liveRecords: [ContainerLogReadRecordV1] = []
        var liveIndex = 0
        var liveBufferedBytes = 0
        var waiter: ReadContinuation?
        var terminal: Terminal?
        var deadlineTask: Task<Void, Never>?

        var bufferedLiveRecordCount: Int {
            liveRecords.count - liveIndex
        }

        var bufferedHistoryRecordCount: Int {
            history.count - historyIndex
        }

        mutating func takeHistoryRecord() -> (ContainerLogReadRecordV1, Int)? {
            guard historyIndex < history.count else {
                return nil
            }
            let record = history[historyIndex]
            let size = Self.bufferedSize(of: record)
            historyIndex += 1
            historyBufferedBytes -= size
            if historyIndex == history.count {
                history.removeAll(keepingCapacity: false)
                historyIndex = 0
            }
            return (record, size)
        }

        mutating func takeLiveRecord() -> (ContainerLogReadRecordV1, Int)? {
            guard liveIndex < liveRecords.count else {
                return nil
            }
            let record = liveRecords[liveIndex]
            let size = Self.bufferedSize(of: record)
            liveIndex += 1
            liveBufferedBytes -= size
            if liveIndex >= 1_024, liveIndex * 2 >= liveRecords.count {
                liveRecords.removeFirst(liveIndex)
                liveIndex = 0
            }
            return (record, size)
        }

        static func bufferedSize(of record: ContainerLogReadRecordV1) -> Int {
            var total = record.data.count + 64
            for (key, value) in record.attributes {
                let (entry, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
                let (next, totalOverflow) = total.addingReportingOverflow(entry)
                if entryOverflow || totalOverflow {
                    return .max
                }
                total = next
            }
            return total
        }
    }

    private enum NextAction {
        case suspend
        case event(ContainerLogReaderEventV1)
        case failure(ContainerLogReaderError)
    }

    private let destination: any ContainerLogCanonicalReadDestination
    private let maximumLiveBufferedBytes: Int
    private let maximumAggregateBufferedBytes: Int
    private let maximumConcurrentReaders: Int
    private let hooks: ContainerLogCanonicalReadCoordinatorHooks
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var historyBufferedBytes = 0
    private var liveBufferedBytes = 0
    private var closed = false

    package init(
        destination: any ContainerLogCanonicalReadDestination,
        maximumLiveBufferedBytes: Int = defaultMaximumLiveBufferedBytes,
        maximumAggregateBufferedBytes: Int = defaultMaximumAggregateBufferedBytes,
        maximumConcurrentReaders: Int = defaultMaximumConcurrentReaders,
        hooks: ContainerLogCanonicalReadCoordinatorHooks = ContainerLogCanonicalReadCoordinatorHooks()
    ) {
        precondition(
            maximumLiveBufferedBytes > 0
                && maximumLiveBufferedBytes <= maximumAggregateBufferedBytes
                && maximumConcurrentReaders > 0
        )
        self.destination = destination
        self.maximumLiveBufferedBytes = maximumLiveBufferedBytes
        self.maximumAggregateBufferedBytes = maximumAggregateBufferedBytes
        self.maximumConcurrentReaders = maximumConcurrentReaders
        self.hooks = hooks
    }

    package func write(_ record: ContainerLogRecordV2) throws {
        var resumptions: [(ReadContinuation, ContainerLogReaderEventV1)] = []
        var failures: [(ReadContinuation, ContainerLogReaderError)] = []

        lock.lock()
        guard !closed else {
            lock.unlock()
            throw ContainerLogDeliveryError.closed
        }
        do {
            try destination.write(record)
        } catch {
            lock.unlock()
            throw error
        }

        do {
            let presented = try destination.presentationRecord(for: record)
            publishLocked(presented, resumptions: &resumptions, failures: &failures)
        } catch {
            failAllLocked(.presentationFailed, failures: &failures)
        }
        lock.unlock()

        resume(resumptions)
        resume(failures)
    }

    package func close() throws {
        var resumptions: [(ReadContinuation, ContainerLogReaderEventV1)] = []
        var closeError: (any Error)?

        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        do {
            try destination.close()
        } catch {
            closeError = error
        }
        endAllLocked(resumptions: &resumptions)
        lock.unlock()

        resume(resumptions)
        if let closeError {
            throw closeError
        }
    }

    package func makeReader(
        request: ContainerLogReadRequest
    ) throws -> ContainerLogCoordinatedReader {
        let since = try request.since.map(Self.timestamp)
        let until = try request.until.map(Self.timestamp)
        let identifier = UUID()

        lock.lock()
        guard subscribers.count < maximumConcurrentReaders else {
            lock.unlock()
            throw ContainerLogReaderError.readerLimitExceeded(
                maximumReaders: maximumConcurrentReaders
            )
        }
        let remainingBufferedBytes = maximumAggregateBufferedBytes - aggregateBufferedBytesLocked
        let history: [ContainerLogReadRecordV1]
        if request.tail == 0 || (!request.stdout && !request.stderr) {
            history = []
        } else {
            guard remainingBufferedBytes > 0 else {
                lock.unlock()
                throw ContainerLogReaderError.historyBufferLimitExceeded(
                    maximumBufferedBytes: maximumAggregateBufferedBytes
                )
            }
            do {
                history = try destination.historicalRecords(
                    for: request,
                    maximumBytes: remainingBufferedBytes
                )
            } catch ContainerLogCanonicalReadDestinationError.historyLimitExceeded {
                lock.unlock()
                throw ContainerLogReaderError.historyBufferLimitExceeded(
                    maximumBufferedBytes: maximumAggregateBufferedBytes
                )
            } catch {
                lock.unlock()
                throw error
            }
        }
        guard
            let retainedHistoryBytes = Self.bufferedSize(of: history),
            retainedHistoryBytes <= remainingBufferedBytes
        else {
            lock.unlock()
            throw ContainerLogReaderError.historyBufferLimitExceeded(
                maximumBufferedBytes: maximumAggregateBufferedBytes
            )
        }
        let followsUntilFuture = request.until.map { $0 > Date.now } ?? true
        let shouldFollow = request.follow && followsUntilFuture && !closed
        subscribers[identifier] = Subscriber(
            filter: Filter(
                stdout: request.stdout,
                stderr: request.stderr,
                sinceGate: since,
                until: until
            ),
            history: history,
            historyBufferedBytes: retainedHistoryBytes,
            terminal: shouldFollow ? nil : .endOfStream
        )
        historyBufferedBytes += retainedHistoryBytes
        lock.unlock()

        if shouldFollow, let untilDate = request.until {
            installDeadline(for: identifier, at: untilDate)
        }
        return ContainerLogCoordinatedReader(
            coordinator: self,
            identifier: identifier,
            nextCallAdmitted: hooks.nextCallAdmitted
        )
    }

    package var snapshot: ContainerLogCanonicalReadCoordinatorSnapshot {
        lock.withLock {
            ContainerLogCanonicalReadCoordinatorSnapshot(
                readerCount: subscribers.count,
                waitingReaderCount: subscribers.values.count { $0.waiter != nil },
                historyBufferedRecordCount: subscribers.values.reduce(0) {
                    Self.saturatingAdd($0, $1.bufferedHistoryRecordCount)
                },
                historyBufferedBytes: historyBufferedBytes,
                liveBufferedRecordCount: subscribers.values.reduce(0) {
                    Self.saturatingAdd($0, $1.bufferedLiveRecordCount)
                },
                liveBufferedBytes: liveBufferedBytes,
                aggregateBufferedBytes: aggregateBufferedBytesLocked,
                closed: closed
            )
        }
    }

    fileprivate func next(
        for identifier: UUID
    ) async throws -> ContainerLogReaderEventV1 {
        try await withCheckedThrowingContinuation { continuation in
            let action: NextAction
            var deadlineTask: Task<Void, Never>?

            lock.lock()
            guard var subscriber = subscribers[identifier] else {
                lock.unlock()
                continuation.resume(throwing: ContainerLogReaderError.alreadyEnded)
                return
            }
            if subscriber.waiter != nil {
                action = .failure(.concurrentReadNotSupported)
            } else if let (record, retainedSize) = subscriber.takeHistoryRecord() {
                precondition(retainedSize <= historyBufferedBytes)
                historyBufferedBytes -= retainedSize
                subscribers[identifier] = subscriber
                action = .event(.record(record))
            } else if let (record, retainedSize) = subscriber.takeLiveRecord() {
                precondition(retainedSize <= liveBufferedBytes)
                liveBufferedBytes -= retainedSize
                subscribers[identifier] = subscriber
                action = .event(.record(record))
            } else if let terminal = subscriber.terminal {
                deadlineTask = subscriber.deadlineTask
                releaseBuffersLocked(&subscriber)
                subscribers.removeValue(forKey: identifier)
                switch terminal {
                case .endOfStream:
                    action = .event(.endOfStream)
                case .failure(let error):
                    action = .failure(error)
                }
            } else {
                subscriber.waiter = continuation
                subscribers[identifier] = subscriber
                action = .suspend
            }
            lock.unlock()

            deadlineTask?.cancel()
            switch action {
            case .suspend:
                break
            case .event(let event):
                continuation.resume(returning: event)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    fileprivate func cancel(_ identifier: UUID) {
        let cleanup = lock.withLock { () -> (Task<Void, Never>?, ReadContinuation?)? in
            guard var subscriber = subscribers.removeValue(forKey: identifier) else {
                return nil
            }
            releaseBuffersLocked(&subscriber)
            return (subscriber.deadlineTask, subscriber.waiter)
        }
        cleanup?.0?.cancel()
        cleanup?.1?.resume(throwing: ContainerLogReaderError.cancelled)
    }

    private func installDeadline(for identifier: UUID, at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow)
        let task = Task.detached { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.end(identifier)
        }
        let accepted = lock.withLock { () -> Bool in
            guard var subscriber = subscribers[identifier], subscriber.terminal == nil else {
                return false
            }
            subscriber.deadlineTask = task
            subscribers[identifier] = subscriber
            return true
        }
        if !accepted {
            task.cancel()
        }
    }

    private func end(_ identifier: UUID) {
        var waiter: ReadContinuation?
        var deadlineTask: Task<Void, Never>?
        lock.withLock {
            guard var subscriber = subscribers[identifier], subscriber.terminal == nil else {
                return
            }
            subscriber.terminal = .endOfStream
            deadlineTask = subscriber.deadlineTask
            subscriber.deadlineTask = nil
            if subscriber.history.isEmpty, subscriber.bufferedLiveRecordCount == 0 {
                waiter = subscriber.waiter
                subscriber.waiter = nil
                if waiter != nil {
                    releaseBuffersLocked(&subscriber)
                    subscribers.removeValue(forKey: identifier)
                    return
                }
            }
            subscribers[identifier] = subscriber
        }
        deadlineTask?.cancel()
        waiter?.resume(returning: .endOfStream)
    }

    private func publishLocked(
        _ record: ContainerLogReadRecordV1,
        resumptions: inout [(ReadContinuation, ContainerLogReaderEventV1)],
        failures: inout [(ReadContinuation, ContainerLogReaderError)]
    ) {
        for identifier in Array(subscribers.keys) {
            guard var subscriber = subscribers[identifier], subscriber.terminal == nil else {
                continue
            }
            guard subscriber.filter.includes(record) else {
                subscribers[identifier] = subscriber
                continue
            }
            if let waiter = subscriber.waiter {
                subscriber.waiter = nil
                subscribers[identifier] = subscriber
                resumptions.append((waiter, .record(record)))
                continue
            }

            let recordSize = Subscriber.bufferedSize(of: record)
            let (nextSize, overflow) = subscriber.liveBufferedBytes.addingReportingOverflow(recordSize)
            if overflow || nextSize > maximumLiveBufferedBytes
                || subscriber.bufferedLiveRecordCount >= Self.maximumLiveBufferedRecords
            {
                failLocked(
                    identifier: identifier,
                    subscriber: &subscriber,
                    error: .consumerTooSlow(maximumBufferedBytes: maximumLiveBufferedBytes),
                    failures: &failures
                )
                continue
            }
            guard recordSize <= maximumAggregateBufferedBytes - aggregateBufferedBytesLocked else {
                failLocked(
                    identifier: identifier,
                    subscriber: &subscriber,
                    error: .aggregateBufferLimitExceeded(
                        maximumBufferedBytes: maximumAggregateBufferedBytes
                    ),
                    failures: &failures
                )
                continue
            }
            subscriber.liveRecords.append(record)
            subscriber.liveBufferedBytes = nextSize
            liveBufferedBytes += recordSize
            subscribers[identifier] = subscriber
        }
    }

    private func failAllLocked(
        _ error: ContainerLogReaderError,
        failures: inout [(ReadContinuation, ContainerLogReaderError)]
    ) {
        for identifier in Array(subscribers.keys) {
            guard var subscriber = subscribers[identifier], subscriber.terminal == nil else {
                continue
            }
            failLocked(
                identifier: identifier,
                subscriber: &subscriber,
                error: error,
                failures: &failures
            )
        }
    }

    private func endAllLocked(
        resumptions: inout [(ReadContinuation, ContainerLogReaderEventV1)]
    ) {
        for identifier in Array(subscribers.keys) {
            guard var subscriber = subscribers[identifier], subscriber.terminal == nil else {
                continue
            }
            subscriber.terminal = .endOfStream
            subscriber.deadlineTask?.cancel()
            subscriber.deadlineTask = nil
            if subscriber.history.isEmpty, subscriber.bufferedLiveRecordCount == 0,
                let waiter = subscriber.waiter
            {
                subscriber.waiter = nil
                releaseBuffersLocked(&subscriber)
                subscribers.removeValue(forKey: identifier)
                resumptions.append((waiter, .endOfStream))
            } else {
                subscribers[identifier] = subscriber
            }
        }
    }

    private var aggregateBufferedBytesLocked: Int {
        historyBufferedBytes + liveBufferedBytes
    }

    private func failLocked(
        identifier: UUID,
        subscriber: inout Subscriber,
        error: ContainerLogReaderError,
        failures: inout [(ReadContinuation, ContainerLogReaderError)]
    ) {
        releaseBuffersLocked(&subscriber)
        subscriber.terminal = .failure(error)
        subscriber.deadlineTask?.cancel()
        subscriber.deadlineTask = nil
        if let waiter = subscriber.waiter {
            subscriber.waiter = nil
            subscribers.removeValue(forKey: identifier)
            failures.append((waiter, error))
        } else {
            subscribers[identifier] = subscriber
        }
    }

    private func releaseBuffersLocked(_ subscriber: inout Subscriber) {
        precondition(subscriber.historyBufferedBytes <= historyBufferedBytes)
        precondition(subscriber.liveBufferedBytes <= liveBufferedBytes)
        historyBufferedBytes -= subscriber.historyBufferedBytes
        liveBufferedBytes -= subscriber.liveBufferedBytes
        subscriber.history.removeAll(keepingCapacity: false)
        subscriber.liveRecords.removeAll(keepingCapacity: false)
        subscriber.historyIndex = 0
        subscriber.liveIndex = 0
        subscriber.historyBufferedBytes = 0
        subscriber.liveBufferedBytes = 0
    }

    private func resume(
        _ resumptions: [(ReadContinuation, ContainerLogReaderEventV1)]
    ) {
        for (continuation, event) in resumptions {
            continuation.resume(returning: event)
        }
    }

    private func resume(
        _ failures: [(ReadContinuation, ContainerLogReaderError)]
    ) {
        for (continuation, error) in failures {
            continuation.resume(throwing: error)
        }
    }

    package static func timestamp(_ date: Date) throws -> ContainerLogTimestamp {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else {
            throw ContainerLogNativeReaderFactoryError.invalidTimestamp
        }
        let wholeSeconds = interval.rounded(.down)
        guard var seconds = Int64(exactly: wholeSeconds) else {
            throw ContainerLogNativeReaderFactoryError.invalidTimestamp
        }
        let fractional = interval - wholeSeconds
        guard fractional >= 0, fractional < 1 else {
            throw ContainerLogNativeReaderFactoryError.invalidTimestamp
        }
        var nanoseconds = UInt32((fractional * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            let (incremented, overflow) = seconds.addingReportingOverflow(1)
            guard !overflow else {
                throw ContainerLogNativeReaderFactoryError.invalidTimestamp
            }
            seconds = incremented
            nanoseconds = 0
        }
        return try ContainerLogTimestamp(
            secondsSinceUnixEpoch: seconds,
            nanoseconds: nanoseconds
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func bufferedSize(
        of records: [ContainerLogReadRecordV1]
    ) -> Int? {
        var total = 0
        for record in records {
            let (next, overflow) = total.addingReportingOverflow(Subscriber.bufferedSize(of: record))
            guard !overflow else {
                return nil
            }
            total = next
        }
        return total
    }
}

package final class ContainerLogCoordinatedReader: ContainerLogReader, @unchecked Sendable {
    private let coordinator: ContainerLogCanonicalReadCoordinator
    private let identifier: UUID
    private let nextCallAdmitted: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var nextInFlight = false
    private var explicitlyCancelled = false

    fileprivate init(
        coordinator: ContainerLogCanonicalReadCoordinator,
        identifier: UUID,
        nextCallAdmitted: (@Sendable () async -> Void)?
    ) {
        self.coordinator = coordinator
        self.identifier = identifier
        self.nextCallAdmitted = nextCallAdmitted
    }

    deinit {
        coordinator.cancel(identifier)
    }

    package func next() async throws -> ContainerLogReaderEventV1 {
        try beginNext()
        defer { finishNext() }

        return try await withTaskCancellationHandler {
            do {
                if let nextCallAdmitted {
                    await nextCallAdmitted()
                }
                try Task.checkCancellation()
                if isExplicitlyCancelled {
                    throw ContainerLogReaderError.cancelled
                }
                let event = try await coordinator.next(for: identifier)
                try Task.checkCancellation()
                if isExplicitlyCancelled {
                    throw ContainerLogReaderError.cancelled
                }
                return event
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            self.coordinator.cancel(self.identifier)
        }
    }

    package func cancel() async {
        lock.withLock {
            explicitlyCancelled = true
        }
        coordinator.cancel(identifier)
    }

    private var isExplicitlyCancelled: Bool {
        lock.withLock { explicitlyCancelled }
    }

    private func beginNext() throws {
        try lock.withLock {
            guard !explicitlyCancelled else {
                throw ContainerLogReaderError.alreadyEnded
            }
            guard !nextInFlight else {
                throw ContainerLogReaderError.concurrentReadNotSupported
            }
            nextInFlight = true
        }
    }

    private func finishNext() {
        lock.withLock {
            precondition(nextInFlight)
            nextInFlight = false
        }
    }
}

extension DockerJSONFileLogStore: ContainerLogCanonicalReadDestination {
    package func historicalRecords(
        for request: ContainerLogReadRequest,
        maximumBytes: Int
    ) throws -> [ContainerLogReadRecordV1] {
        guard maximumBytes > 0 else {
            throw ContainerLogCanonicalReadDestinationError.historyLimitExceeded
        }
        let result: DockerJSONFileLogReadResult
        do {
            result = try makeReader().read(
                DockerJSONFileLogReadRequest(
                    stdout: request.stdout,
                    stderr: request.stderr,
                    tail: request.tail,
                    since: try request.since.map(ContainerLogCanonicalReadCoordinator.timestamp),
                    until: try request.until.map(ContainerLogCanonicalReadCoordinator.timestamp),
                    maximumDecodedBytes: min(
                        maximumBytes,
                        DockerJSONFileLogReadRequest.hardMaximumDecodedBytes
                    )
                )
            )
        } catch DockerJSONFileLogError.storageLimitExceeded {
            throw ContainerLogCanonicalReadDestinationError.historyLimitExceeded
        }
        return try result.records.map { record in
            try ContainerLogReadRecordV1(
                stream: record.stream,
                timestamp: record.timestamp,
                data: record.log,
                attributes: record.attributes,
                sequence: record.storageSequence
            )
        }
    }

    package func presentationRecord(
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
}

extension NativeLocalLogStore: ContainerLogCanonicalReadDestination {
    package func historicalRecords(
        for request: ContainerLogReadRequest,
        maximumBytes: Int
    ) throws -> [ContainerLogReadRecordV1] {
        guard maximumBytes > 0 else {
            throw ContainerLogCanonicalReadDestinationError.historyLimitExceeded
        }
        let result: NativeLocalLogReadResult
        do {
            result = try makeReader().read(
                NativeLocalLogReadRequest(
                    stdout: request.stdout,
                    stderr: request.stderr,
                    tail: request.tail,
                    since: try request.since.map(ContainerLogCanonicalReadCoordinator.timestamp),
                    until: try request.until.map(ContainerLogCanonicalReadCoordinator.timestamp),
                    maximumDecodedBytes: min(
                        maximumBytes,
                        NativeLocalLogReadRequest.hardMaximumDecodedBytes
                    ),
                    maximumStoredBytes: min(
                        maximumBytes,
                        NativeLocalLogReadRequest.hardMaximumStoredBytes
                    )
                )
            )
        } catch NativeLocalLogError.storageLimitExceeded {
            throw ContainerLogCanonicalReadDestinationError.historyLimitExceeded
        }
        return try result.records.map(presentationRecord)
    }

    package func presentationRecord(
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
}
