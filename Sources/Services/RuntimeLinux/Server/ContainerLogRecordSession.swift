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
import Containerization
import Foundation

package enum ContainerLogRecordSessionError: Error, Equatable, Sendable {
    case invalidAttributes
    case invalidInitialSequence
    case invalidProcessGeneration
    case invalidStreams
}

package struct ContainerLogRecordSessionSnapshot: Equatable, Sendable {
    package let emittedRecordCount: UInt64
    package let blockingDeliveryFailureCount: UInt64
    package let blockingCloseFailureCount: UInt64
    package let constructionFailureCount: UInt64
    package let nonBlockingEnqueueFailureCount: UInt64
    package let closedStreams: Set<ContainerLogStream>
    package let closed: Bool
    package let nonBlockingDelivery: ContainerLogDeliverySnapshot?
}

/// One process-generation logging session shared by its stdout and stderr.
///
/// The session is the single linearization point for the two per-stream
/// splitters and the global record sequence. Blocking delivery deliberately
/// remains inside that critical section, reproducing Docker's application
/// backpressure. Driver errors are counted and isolated from live attach.
package final class ContainerLogRecordSession: @unchecked Sendable {
    private enum Delivery {
        case blocking(any ContainerLogRecordDestination)
        case nonBlocking(ContainerLogNonBlockingDelivery)
    }

    private struct State {
        var splitters: [ContainerLogStream: ContainerLogRecordSplitterV1]
        var historyEpoch: UInt64
        var nextSequence: UInt64
        var reservedUpperBound: UInt64
        var sequenceExhausted = false
        var closedStreams: Set<ContainerLogStream> = []
        var closed = false
        var emittedRecordCount: UInt64 = 0
        var blockingDeliveryFailureCount: UInt64 = 0
        var blockingCloseFailureCount: UInt64 = 0
        var constructionFailureCount: UInt64 = 0
        var nonBlockingEnqueueFailureCount: UInt64 = 0
    }

    private let lock = NSLock()
    private let expectedStreams: Set<ContainerLogStream>
    private let processGeneration: UInt64
    private let attributes: [String: String]
    private let observationProvider: @Sendable () -> ContainerLogObservation
    private let sequenceReservationProvider: (@Sendable () throws -> ContainerLogSequenceReservationV1)?
    private let readCoordinator: ContainerLogCanonicalReadCoordinator?
    private let delivery: Delivery
    private var state: State

    package init(
        destination: any ContainerLogRecordDestination,
        deliveryConfiguration: LogDeliveryConfiguration,
        streams: Set<ContainerLogStream>,
        processGeneration: UInt64,
        initialSequence: UInt64 = 1,
        sequenceReservation: ContainerLogSequenceReservationV1? = nil,
        sequenceReservationProvider:
            (@Sendable () throws -> ContainerLogSequenceReservationV1)? = nil,
        attributes: [String: String] = [:],
        maximumLiveReaderBufferSizeInBytes: Int = ContainerLogCanonicalReadCoordinator
            .defaultMaximumLiveBufferedBytes,
        maximumAggregateReaderBufferSizeInBytes: Int = ContainerLogCanonicalReadCoordinator
            .defaultMaximumAggregateBufferedBytes,
        maximumConcurrentReaders: Int = ContainerLogCanonicalReadCoordinator
            .defaultMaximumConcurrentReaders,
        observationProvider: @escaping @Sendable () -> ContainerLogObservation = {
            ContainerLogObservation.now()
        }
    ) throws {
        let effectiveInitialSequence =
            sequenceReservation?.lowerBound
            ?? initialSequence
        let effectiveUpperBound =
            sequenceReservation?.upperBoundInclusive
            ?? UInt64.max
        let effectiveHistoryEpoch = sequenceReservation?.historyEpoch ?? 1
        guard
            effectiveInitialSequence > 0,
            effectiveHistoryEpoch > 0,
            effectiveInitialSequence <= effectiveUpperBound
        else {
            throw ContainerLogRecordSessionError.invalidInitialSequence
        }
        guard processGeneration > 0 else {
            throw ContainerLogRecordSessionError.invalidProcessGeneration
        }
        guard !streams.isEmpty else {
            throw ContainerLogRecordSessionError.invalidStreams
        }
        guard attributes.count <= ContainerLogRecordV2.maximumAttributeCount else {
            throw ContainerLogRecordSessionError.invalidAttributes
        }
        var attributeBytes = 0
        for (key, value) in attributes {
            let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
            let (totalBytes, totalOverflow) = attributeBytes.addingReportingOverflow(entryBytes)
            guard
                !entryOverflow,
                !totalOverflow,
                totalBytes <= ContainerLogRecordV2.maximumAttributeUTF8Bytes
            else {
                throw ContainerLogRecordSessionError.invalidAttributes
            }
            attributeBytes = totalBytes
        }
        var splitters: [ContainerLogStream: ContainerLogRecordSplitterV1] = [:]
        for stream in streams {
            splitters[stream] = ContainerLogRecordSplitterV1(stream: stream)
        }
        expectedStreams = streams
        self.processGeneration = processGeneration
        self.attributes = attributes
        self.observationProvider = observationProvider
        self.sequenceReservationProvider = sequenceReservationProvider

        let effectiveDestination: any ContainerLogRecordDestination
        if let readableDestination = destination as? any ContainerLogCanonicalReadDestination {
            let coordinator = ContainerLogCanonicalReadCoordinator(
                destination: readableDestination,
                maximumLiveBufferedBytes: maximumLiveReaderBufferSizeInBytes,
                maximumAggregateBufferedBytes: maximumAggregateReaderBufferSizeInBytes,
                maximumConcurrentReaders: maximumConcurrentReaders
            )
            readCoordinator = coordinator
            effectiveDestination = coordinator
        } else {
            readCoordinator = nil
            effectiveDestination = destination
        }
        switch deliveryConfiguration.effectiveMode {
        case .blocking:
            delivery = .blocking(effectiveDestination)
        case .nonBlocking:
            delivery = .nonBlocking(
                ContainerLogNonBlockingDelivery(
                    destination: effectiveDestination,
                    capacityInBytes: deliveryConfiguration.effectiveMaxBufferSizeInBytes
                        ?? LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes
                ))
        }
        state = State(
            splitters: splitters,
            historyEpoch: effectiveHistoryEpoch,
            nextSequence: effectiveInitialSequence,
            reservedUpperBound: effectiveUpperBound
        )
    }

    deinit {
        closeAll()
    }

    package func writer(for stream: ContainerLogStream) -> any Writer {
        precondition(expectedStreams.contains(stream), "writer requested for an inactive log stream")
        return ContainerLogRecordStreamWriter(session: self, stream: stream)
    }

    package func write(_ data: Data, to stream: ContainerLogStream) {
        lock.withLock {
            guard
                !state.closed,
                !state.closedStreams.contains(stream),
                var splitter = state.splitters[stream]
            else {
                return
            }
            splitter.append(data, observationProvider: observationProvider) { fragment in
                emit(fragment)
            }
            state.splitters[stream] = splitter
        }
    }

    package func close(_ stream: ContainerLogStream) {
        lock.withLock {
            closeLocked(stream)
        }
    }

    package func closeAll() {
        lock.withLock {
            for stream in expectedStreams where !state.closedStreams.contains(stream) {
                closeLocked(stream)
            }
        }
    }

    /// Opens an atomic historical-plus-live reader on this exact generation.
    /// Records become visible only after the configured destination accepts
    /// them, including when delivery itself is non-blocking.
    package func makeReader(
        request: ContainerLogReadRequest
    ) throws -> any ContainerLogReader {
        guard let readCoordinator else {
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
        }
        return try readCoordinator.makeReader(request: request)
    }

    package var snapshot: ContainerLogRecordSessionSnapshot {
        lock.withLock {
            ContainerLogRecordSessionSnapshot(
                emittedRecordCount: state.emittedRecordCount,
                blockingDeliveryFailureCount: state.blockingDeliveryFailureCount,
                blockingCloseFailureCount: state.blockingCloseFailureCount,
                constructionFailureCount: state.constructionFailureCount,
                nonBlockingEnqueueFailureCount: state.nonBlockingEnqueueFailureCount,
                closedStreams: state.closedStreams,
                closed: state.closed,
                nonBlockingDelivery: nonBlockingSnapshot
            )
        }
    }

    private var nonBlockingSnapshot: ContainerLogDeliverySnapshot? {
        if case .nonBlocking(let delivery) = delivery {
            return delivery.snapshot
        }
        return nil
    }

    private func closeLocked(_ stream: ContainerLogStream) {
        guard
            !state.closed,
            !state.closedStreams.contains(stream),
            var splitter = state.splitters[stream]
        else {
            return
        }
        splitter.finish(observationProvider: observationProvider) { fragment in
            emit(fragment)
        }
        state.splitters[stream] = splitter
        state.closedStreams.insert(stream)
        guard state.closedStreams == expectedStreams else {
            return
        }
        state.closed = true
        switch delivery {
        case .blocking(let destination):
            do {
                try destination.close()
            } catch {
                saturatingIncrement(&state.blockingCloseFailureCount)
            }
        case .nonBlocking(let delivery):
            try? delivery.close()
        }
    }

    private func emit(_ fragment: ContainerLogRecordFragmentV1) {
        guard !state.sequenceExhausted else {
            saturatingIncrement(&state.constructionFailureCount)
            return
        }
        if state.nextSequence > state.reservedUpperBound {
            guard let sequenceReservationProvider else {
                state.sequenceExhausted = true
                saturatingIncrement(&state.constructionFailureCount)
                return
            }
            do {
                let reservation = try sequenceReservationProvider()
                guard
                    reservation.historyEpoch == state.historyEpoch,
                    reservation.lowerBound > state.reservedUpperBound,
                    reservation.lowerBound
                        <= reservation.upperBoundInclusive
                else {
                    state.sequenceExhausted = true
                    saturatingIncrement(&state.constructionFailureCount)
                    return
                }
                state.nextSequence = reservation.lowerBound
                state.reservedUpperBound = reservation.upperBoundInclusive
            } catch {
                state.sequenceExhausted = true
                saturatingIncrement(&state.constructionFailureCount)
                return
            }
        }
        let sequence = state.nextSequence
        if sequence == UInt64.max {
            state.sequenceExhausted = true
        } else {
            state.nextSequence = sequence + 1
        }

        let record: ContainerLogRecordV2
        do {
            record = try ContainerLogRecordV2(
                fragment: fragment,
                sequence: sequence,
                attributes: attributes,
                processGeneration: processGeneration
            )
        } catch {
            saturatingIncrement(&state.constructionFailureCount)
            return
        }
        saturatingIncrement(&state.emittedRecordCount)

        switch delivery {
        case .blocking(let destination):
            do {
                try destination.write(record)
            } catch {
                saturatingIncrement(&state.blockingDeliveryFailureCount)
            }
        case .nonBlocking(let delivery):
            do {
                _ = try delivery.enqueue(record)
            } catch {
                saturatingIncrement(&state.nonBlockingEnqueueFailureCount)
            }
        }
    }

    private func saturatingIncrement(_ value: inout UInt64) {
        let (result, overflow) = value.addingReportingOverflow(1)
        value = overflow ? UInt64.max : result
    }
}

private final class ContainerLogRecordStreamWriter: Writer, @unchecked Sendable {
    private let session: ContainerLogRecordSession
    private let stream: ContainerLogStream

    init(session: ContainerLogRecordSession, stream: ContainerLogStream) {
        self.session = session
        self.stream = stream
    }

    func write(_ data: Data) throws {
        session.write(data, to: stream)
    }

    func close() throws {
        session.close(stream)
    }
}

extension DockerJSONFileLogStore: ContainerLogRecordDestination {}
extension NativeLocalLogStore: ContainerLogRecordDestination {}
