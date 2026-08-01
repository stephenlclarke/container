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

/// A stable, driver-neutral container output stream identifier.
public enum ContainerLogStream: String, CaseIterable, Equatable, Sendable {
    case stdout
    case stderr
}

/// Validation failures for an explicit wall-clock log timestamp.
public enum ContainerLogTimestampError: Error, Equatable, Sendable {
    case nanosecondsOutOfRange(UInt32)
}

/// A lossless wall-clock timestamp suitable for an explicit persistence codec.
public struct ContainerLogTimestamp: Comparable, Equatable, Sendable {
    public let secondsSinceUnixEpoch: Int64
    public let nanoseconds: UInt32

    public init(secondsSinceUnixEpoch: Int64, nanoseconds: UInt32) throws {
        guard nanoseconds < 1_000_000_000 else {
            throw ContainerLogTimestampError.nanosecondsOutOfRange(nanoseconds)
        }
        self.secondsSinceUnixEpoch = secondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.secondsSinceUnixEpoch != rhs.secondsSinceUnixEpoch {
            return lhs.secondsSinceUnixEpoch < rhs.secondsSinceUnixEpoch
        }
        return lhs.nanoseconds < rhs.nanoseconds
    }

    fileprivate init(validatedSecondsSinceUnixEpoch: Int64, nanoseconds: UInt32) {
        self.secondsSinceUnixEpoch = validatedSecondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
    }
}

/// Wall-clock and process-local monotonic observations sampled together.
///
/// Only `wallClock` is appropriate for persistence. `monotonicInstant` is useful
/// while ordering and measuring events in the current process.
public struct ContainerLogObservation: Equatable, Sendable {
    public let wallClock: ContainerLogTimestamp
    public let monotonicInstant: ContinuousClock.Instant

    public init(
        wallClock: ContainerLogTimestamp,
        monotonicInstant: ContinuousClock.Instant
    ) {
        self.wallClock = wallClock
        self.monotonicInstant = monotonicInstant
    }

    public static func now() -> Self {
        let monotonicInstant = ContinuousClock().now
        let interval = Date.now.timeIntervalSince1970
        var seconds = Int64(interval.rounded(.down))
        var nanoseconds = UInt32(
            ((interval - Double(seconds)) * 1_000_000_000).rounded()
        )
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        return Self(
            wallClock: ContainerLogTimestamp(
                validatedSecondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            ),
            monotonicInstant: monotonicInstant
        )
    }
}

/// Docker-compatible metadata for one chunk of a long logical log line.
public struct ContainerLogPartialMetadataV1: Equatable, Sendable {
    public let id: String
    public let ordinal: UInt64
    public let last: Bool

    fileprivate init(id: String, ordinal: UInt64, last: Bool) {
        self.id = id
        self.ordinal = ordinal
        self.last = last
    }

    /// Bounded persistence codecs use this package initializer after decoding
    /// partial metadata. It rejects values the authority splitter cannot emit.
    package init(validatingID id: String, ordinal: UInt64, last: Bool) throws {
        guard ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(id) else {
            throw ContainerLogPartialMetadataError.invalidID
        }
        guard ordinal > 0 else {
            throw ContainerLogPartialMetadataError.invalidOrdinal
        }
        self.init(id: id, ordinal: ordinal, last: last)
    }
}

package enum ContainerLogPartialMetadataError: Error, Equatable, Sendable {
    case invalidID
    case invalidOrdinal
}

/// A driver-neutral, binary-safe record supplied to logging-v2 drivers.
///
/// This core value intentionally has no generic persistence conformance. Each
/// storage or transport adapter must apply its own bounded, versioned codec.
public struct ContainerLogRecordV2: Equatable, Sendable {
    package static let maximumAttributeCount = 128
    package static let maximumAttributeUTF8Bytes = 64 * 1024

    public let stream: ContainerLogStream
    public let observation: ContainerLogObservation
    public let payload: Data
    public let partial: ContainerLogPartialMetadataV1?
    public let sequence: UInt64
    public let attributes: [String: String]
    public let processGeneration: UInt64

    /// Authority-only construction keeps sequence and generation assignment in
    /// the owning package and caps immutable metadata before driver delivery.
    package init(
        fragment: ContainerLogRecordFragmentV1,
        sequence: UInt64,
        attributes: [String: String] = [:],
        processGeneration: UInt64
    ) throws {
        try self.init(
            stream: fragment.stream,
            observation: fragment.observation,
            payload: fragment.payload,
            partial: fragment.partial,
            sequence: sequence,
            attributes: attributes,
            processGeneration: processGeneration
        )
    }

    /// Package-owned bounded codecs reconstruct records through this explicit
    /// initializer instead of generic `Codable` decoding.
    package init(
        stream: ContainerLogStream,
        observation: ContainerLogObservation,
        payload: Data,
        partial: ContainerLogPartialMetadataV1?,
        sequence: UInt64,
        attributes: [String: String] = [:],
        processGeneration: UInt64
    ) throws {
        guard attributes.count <= Self.maximumAttributeCount else {
            throw ContainerLogRecordV2ConstructionError.tooManyAttributes
        }

        var attributeBytes = 0
        for (key, value) in attributes {
            let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
            let (newTotal, totalOverflow) = attributeBytes.addingReportingOverflow(entryBytes)
            guard
                !entryOverflow,
                !totalOverflow,
                newTotal <= Self.maximumAttributeUTF8Bytes
            else {
                throw ContainerLogRecordV2ConstructionError.attributesTooLarge
            }
            attributeBytes = newTotal
        }

        self.stream = stream
        self.observation = observation
        self.payload = payload
        self.partial = partial
        self.sequence = sequence
        self.attributes = attributes
        self.processGeneration = processGeneration
    }
}

package enum ContainerLogRecordV2ConstructionError: Error, Equatable, Sendable {
    case tooManyAttributes
    case attributesTooLarge
}

/// A record fragment before the authority assigns global order and metadata.
public struct ContainerLogRecordFragmentV1: Equatable, Sendable {
    public let stream: ContainerLogStream
    public let observation: ContainerLogObservation
    public let payload: Data
    public let partial: ContainerLogPartialMetadataV1?

    fileprivate init(
        stream: ContainerLogStream,
        observation: ContainerLogObservation,
        payload: Data,
        partial: ContainerLogPartialMetadataV1?
    ) {
        self.stream = stream
        self.observation = observation
        self.payload = payload
        self.partial = partial
    }
}

/// Configuration failures for the bounded per-stream splitter.
public enum ContainerLogRecordSplitterError: Error, Equatable, Sendable {
    case invalidMaximumRecordBytes(Int)
}

/// Per-stream Docker-style line splitter with synchronous, bounded delivery.
public struct ContainerLogRecordSplitterV1: Sendable {
    public static let defaultMaximumRecordBytes = 16 * 1024
    public static let maximumSupportedRecordBytes = 16 * 1024

    public let stream: ContainerLogStream
    public let maximumRecordBytes: Int

    private var pending = Data()
    private var partialID: String?
    private var partialObservation: ContainerLogObservation?
    private var nextPartialOrdinal: UInt64 = 1

    public init(stream: ContainerLogStream) {
        self.init(stream: stream, validatedMaximumRecordBytes: Self.defaultMaximumRecordBytes)
    }

    public init(stream: ContainerLogStream, maximumRecordBytes: Int) throws {
        guard (1...Self.maximumSupportedRecordBytes).contains(maximumRecordBytes) else {
            throw ContainerLogRecordSplitterError.invalidMaximumRecordBytes(maximumRecordBytes)
        }
        self.init(stream: stream, validatedMaximumRecordBytes: maximumRecordBytes)
    }

    /// Consumes bytes and synchronously emits each complete or size-bounded
    /// fragment. The observation provider is sampled only when Docker would
    /// timestamp a record: at complete-line emission or first partial emission.
    ///
    /// If `emit` throws, the current logical-line state is dropped before the
    /// error is rethrown. Fragments accepted by earlier callbacks remain emitted.
    public mutating func append(
        _ data: Data,
        observationProvider: () -> ContainerLogObservation = {
            ContainerLogObservation.now()
        },
        emit: (ContainerLogRecordFragmentV1) throws -> Void
    ) rethrows {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let capacity = maximumRecordBytes - pending.count
            let searchEnd =
                data.index(
                    cursor,
                    offsetBy: capacity,
                    limitedBy: data.endIndex
                ) ?? data.endIndex

            if let lineFeed = data[cursor..<searchEnd].firstIndex(of: UInt8(ascii: "\n")) {
                pending.append(contentsOf: data[cursor..<lineFeed])
                if partialID == nil {
                    try emitCompleteLine(
                        observation: observationProvider(),
                        emit: emit
                    )
                } else {
                    try emitPartialChunk(
                        last: true,
                        completesLogicalLine: true,
                        observationProvider: observationProvider,
                        emit: emit
                    )
                }
                cursor = data.index(after: lineFeed)
                continue
            }

            pending.append(contentsOf: data[cursor..<searchEnd])
            cursor = searchEnd
            if pending.count == maximumRecordBytes {
                try emitPartialChunk(
                    last: false,
                    completesLogicalLine: false,
                    observationProvider: observationProvider,
                    emit: emit
                )
            }
        }
    }

    /// Ends the byte stream using Docker's EOF semantics.
    ///
    /// A non-empty remainder is emitted with partial metadata and `last == false`.
    /// An EOF exactly on a chunk boundary emits no synthetic terminal fragment.
    public mutating func finish(
        observationProvider: () -> ContainerLogObservation = {
            ContainerLogObservation.now()
        },
        emit: (ContainerLogRecordFragmentV1) throws -> Void
    ) rethrows {
        guard !pending.isEmpty else {
            resetLogicalLine()
            return
        }
        try emitPartialChunk(
            last: false,
            completesLogicalLine: true,
            observationProvider: observationProvider,
            emit: emit
        )
    }

    /// Drops incomplete state at a process-generation or driver-session fence.
    public mutating func reset() {
        resetLogicalLine()
    }

    static func isMobyCompatiblePartialID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 64 else {
            return false
        }
        guard bytes.allSatisfy(Self.isLowercaseHexDigit) else {
            return false
        }
        return !bytes.prefix(12).allSatisfy(Self.isDecimalDigit)
    }

    private init(stream: ContainerLogStream, validatedMaximumRecordBytes: Int) {
        self.stream = stream
        maximumRecordBytes = validatedMaximumRecordBytes
        pending.reserveCapacity(validatedMaximumRecordBytes)
    }

    private mutating func emitCompleteLine(
        observation: ContainerLogObservation,
        emit: (ContainerLogRecordFragmentV1) throws -> Void
    ) rethrows {
        let fragment = ContainerLogRecordFragmentV1(
            stream: stream,
            observation: observation,
            payload: pending,
            partial: nil
        )
        do {
            try emit(fragment)
        } catch {
            resetLogicalLine()
            throw error
        }
        resetLogicalLine()
    }

    private mutating func emitPartialChunk(
        last: Bool,
        completesLogicalLine: Bool,
        observationProvider: () -> ContainerLogObservation,
        emit: (ContainerLogRecordFragmentV1) throws -> Void
    ) rethrows {
        let context = partialContext(observationProvider: observationProvider)
        let fragment = ContainerLogRecordFragmentV1(
            stream: stream,
            observation: context.observation,
            payload: pending,
            partial: ContainerLogPartialMetadataV1(
                id: context.id,
                ordinal: nextPartialOrdinal,
                last: last
            )
        )
        do {
            try emit(fragment)
        } catch {
            resetLogicalLine()
            throw error
        }

        if completesLogicalLine {
            resetLogicalLine()
        } else {
            pending.removeAll(keepingCapacity: true)
            nextPartialOrdinal += 1
        }
    }

    private mutating func partialContext(
        observationProvider: () -> ContainerLogObservation
    ) -> (id: String, observation: ContainerLogObservation) {
        if let partialID, let partialObservation {
            return (partialID, partialObservation)
        }
        let context = (
            id: Self.generateMobyPartialID(),
            observation: observationProvider()
        )
        partialID = context.id
        partialObservation = context.observation
        return context
    }

    private mutating func resetLogicalLine() {
        pending.removeAll(keepingCapacity: true)
        partialID = nil
        partialObservation = nil
        nextPartialOrdinal = 1
    }

    private static func generateMobyPartialID() -> String {
        let hexadecimal = Array("0123456789abcdef".utf8)
        var generator = SystemRandomNumberGenerator()
        while true {
            var encoded = [UInt8]()
            encoded.reserveCapacity(64)
            for _ in 0..<4 {
                let random = generator.next()
                for shift in stride(from: 0, through: 56, by: 8) {
                    let byte = UInt8(truncatingIfNeeded: random >> UInt64(shift))
                    encoded.append(hexadecimal[Int(byte >> 4)])
                    encoded.append(hexadecimal[Int(byte & 0x0f)])
                }
            }
            let id = String(decoding: encoded, as: UTF8.self)
            if Self.isMobyCompatiblePartialID(id) {
                return id
            }
        }
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        isDecimalDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    private static func isDecimalDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
