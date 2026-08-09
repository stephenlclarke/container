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

/// Docker's `PartialLogEntryMetadata` protobuf message.
public struct DockerPluginPartialMetadata: Equatable, Sendable {
    public let last: Bool
    public let id: String
    public let ordinal: Int32

    public init(last: Bool, id: String, ordinal: Int32) {
        self.last = last
        self.id = id
        self.ordinal = ordinal
    }
}

/// Docker's binary-safe `LogEntry` protobuf message.
public struct DockerPluginLogEntry: Equatable, Sendable {
    public let source: String
    public let timeNano: Int64
    public let line: Data
    public let partial: Bool
    public let partialMetadata: DockerPluginPartialMetadata?

    public init(
        source: String,
        timeNano: Int64,
        line: Data,
        partial: Bool,
        partialMetadata: DockerPluginPartialMetadata?
    ) {
        self.source = source
        self.timeNano = timeNano
        self.line = line
        self.partial = partial
        self.partialMetadata = partialMetadata
    }

    public init(_ record: ContainerLogRecordV2) throws {
        let seconds = record.observation.wallClock.secondsSinceUnixEpoch
        let (secondsInNanoseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else {
            throw DockerPluginProtocolError.timestampOutOfRange
        }
        let (timeNano, additionOverflow) = secondsInNanoseconds.addingReportingOverflow(
            Int64(record.observation.wallClock.nanoseconds)
        )
        guard !additionOverflow else {
            throw DockerPluginProtocolError.timestampOutOfRange
        }

        let metadata: DockerPluginPartialMetadata?
        if let partial = record.partial {
            guard partial.ordinal <= UInt64(Int32.max) else {
                throw DockerPluginProtocolError.partialOrdinalOutOfRange
            }
            metadata = DockerPluginPartialMetadata(
                last: partial.last,
                id: partial.id,
                ordinal: Int32(partial.ordinal)
            )
        } else {
            metadata = nil
        }
        self.init(
            source: record.stream.rawValue,
            timeNano: timeNano,
            line: record.payload,
            partial: metadata != nil,
            partialMetadata: metadata
        )
    }
}

/// Exact four-byte big-endian length prefix and protobuf codec used by Docker
/// logging plugins. No generated protobuf runtime is required on this boundary.
public enum DockerPluginLogEntryCodec {
    public static let maximumLineBytes = ContainerLogReadRecordV1.maximumDataBytes
    public static let maximumMessageBytes = 64 * 1024

    public static func encodeFrame(_ entry: DockerPluginLogEntry) throws -> Data {
        let message = try encodeMessage(entry)
        guard message.count <= maximumMessageBytes else {
            throw DockerPluginProtocolError.frameTooLarge(maximumBytes: maximumMessageBytes)
        }
        var frame = Data()
        frame.reserveCapacity(4 + message.count)
        let length = UInt32(message.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(message)
        return frame
    }

    public static func decodeMessage(_ message: Data) throws -> DockerPluginLogEntry {
        guard message.count <= maximumMessageBytes else {
            throw DockerPluginProtocolError.frameTooLarge(maximumBytes: maximumMessageBytes)
        }
        var parser = ProtobufParser(message)
        var source = ""
        var timeNano: Int64 = 0
        var line = Data()
        var partial = false
        var metadata: DockerPluginPartialMetadata?

        while !parser.isAtEnd {
            let key = try parser.readVarint()
            let field = key >> 3
            let wireType = UInt8(key & 0x07)
            guard field != 0 else {
                throw DockerPluginProtocolError.malformedFrame
            }
            switch (field, wireType) {
            case (1, 2):
                let bytes = try parser.readLengthDelimited(maximumBytes: 64)
                guard let value = String(data: bytes, encoding: .utf8) else {
                    throw DockerPluginProtocolError.malformedFrame
                }
                source = value
            case (2, 0):
                timeNano = Int64(bitPattern: try parser.readVarint())
            case (3, 2):
                line = try parser.readLengthDelimited(maximumBytes: maximumLineBytes)
            case (4, 0):
                partial = try parser.readVarint() != 0
            case (5, 2):
                metadata = try decodePartialMetadata(
                    parser.readLengthDelimited(maximumBytes: maximumMessageBytes)
                )
            default:
                try parser.skip(wireType: wireType)
            }
        }

        guard line.count <= maximumLineBytes else {
            throw DockerPluginProtocolError.lineTooLarge(maximumBytes: maximumLineBytes)
        }
        return DockerPluginLogEntry(
            source: source,
            timeNano: timeNano,
            line: line,
            partial: partial,
            partialMetadata: metadata
        )
    }

    private static func encodeMessage(_ entry: DockerPluginLogEntry) throws -> Data {
        guard entry.line.count <= maximumLineBytes else {
            throw DockerPluginProtocolError.lineTooLarge(maximumBytes: maximumLineBytes)
        }
        var message = Data()
        if !entry.source.isEmpty {
            try appendLengthDelimited(field: 1, Data(entry.source.utf8), to: &message)
        }
        if entry.timeNano != 0 {
            appendKey(field: 2, wireType: 0, to: &message)
            appendVarint(UInt64(bitPattern: entry.timeNano), to: &message)
        }
        if !entry.line.isEmpty {
            try appendLengthDelimited(field: 3, entry.line, to: &message)
        }
        if entry.partial {
            appendKey(field: 4, wireType: 0, to: &message)
            appendVarint(1, to: &message)
        }
        if let metadata = entry.partialMetadata {
            try appendLengthDelimited(
                field: 5,
                encodePartialMetadata(metadata),
                to: &message
            )
        }
        return message
    }

    private static func encodePartialMetadata(
        _ metadata: DockerPluginPartialMetadata
    ) throws -> Data {
        var message = Data()
        if metadata.last {
            appendKey(field: 1, wireType: 0, to: &message)
            appendVarint(1, to: &message)
        }
        if !metadata.id.isEmpty {
            try appendLengthDelimited(field: 2, Data(metadata.id.utf8), to: &message)
        }
        if metadata.ordinal != 0 {
            appendKey(field: 3, wireType: 0, to: &message)
            appendVarint(UInt64(bitPattern: Int64(metadata.ordinal)), to: &message)
        }
        return message
    }

    private static func decodePartialMetadata(
        _ message: Data
    ) throws -> DockerPluginPartialMetadata {
        var parser = ProtobufParser(message)
        var last = false
        var id = ""
        var ordinal: Int32 = 0

        while !parser.isAtEnd {
            let key = try parser.readVarint()
            let field = key >> 3
            let wireType = UInt8(key & 0x07)
            guard field != 0 else {
                throw DockerPluginProtocolError.malformedFrame
            }
            switch (field, wireType) {
            case (1, 0):
                last = try parser.readVarint() != 0
            case (2, 2):
                let bytes = try parser.readLengthDelimited(maximumBytes: 128)
                guard let value = String(data: bytes, encoding: .utf8) else {
                    throw DockerPluginProtocolError.malformedFrame
                }
                id = value
            case (3, 0):
                ordinal = Int32(truncatingIfNeeded: try parser.readVarint())
            default:
                try parser.skip(wireType: wireType)
            }
        }
        return DockerPluginPartialMetadata(last: last, id: id, ordinal: ordinal)
    }

    private static func appendKey(
        field: UInt64,
        wireType: UInt64,
        to data: inout Data
    ) {
        appendVarint((field << 3) | wireType, to: &data)
    }

    private static func appendLengthDelimited(
        field: UInt64,
        _ bytes: Data,
        to data: inout Data
    ) throws {
        guard bytes.count <= maximumMessageBytes else {
            throw DockerPluginProtocolError.frameTooLarge(maximumBytes: maximumMessageBytes)
        }
        appendKey(field: field, wireType: 2, to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

/// Incremental, bounded decoder for a `ReadLogs` response stream.
public struct DockerPluginFrameDecoder: Sendable {
    private var buffer = Data()
    private var expectedMessageBytes: Int?

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [DockerPluginLogEntry] {
        let (newCount, overflow) = buffer.count.addingReportingOverflow(chunk.count)
        let maximumBufferedBytes = (DockerPluginLogEntryCodec.maximumMessageBytes * 2) + 4
        guard !overflow, newCount <= maximumBufferedBytes else {
            throw DockerPluginProtocolError.frameTooLarge(
                maximumBytes: DockerPluginLogEntryCodec.maximumMessageBytes
            )
        }
        buffer.append(chunk)

        var entries = [DockerPluginLogEntry]()
        while true {
            if expectedMessageBytes == nil {
                guard buffer.count >= 4 else {
                    break
                }
                let length =
                    (UInt32(buffer[buffer.startIndex]) << 24)
                    | (UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 1)]) << 16)
                    | (UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 2)]) << 8)
                    | UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
                guard length <= UInt32(DockerPluginLogEntryCodec.maximumMessageBytes) else {
                    throw DockerPluginProtocolError.frameTooLarge(
                        maximumBytes: DockerPluginLogEntryCodec.maximumMessageBytes
                    )
                }
                buffer.removeFirst(4)
                expectedMessageBytes = Int(length)
            }

            guard let expectedMessageBytes, buffer.count >= expectedMessageBytes else {
                break
            }
            let message = Data(buffer.prefix(expectedMessageBytes))
            buffer.removeFirst(expectedMessageBytes)
            self.expectedMessageBytes = nil
            entries.append(try DockerPluginLogEntryCodec.decodeMessage(message))
        }
        return entries
    }

    public mutating func finish() throws {
        guard buffer.isEmpty, expectedMessageBytes == nil else {
            throw DockerPluginProtocolError.malformedFrame
        }
    }
}

private struct ProtobufParser {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool {
        index == data.endIndex
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.endIndex else {
                throw DockerPluginProtocolError.malformedFrame
            }
            let byte = data[index]
            data.formIndex(after: &index)
            if shift == 63, byte > 1 {
                throw DockerPluginProtocolError.malformedFrame
            }
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw DockerPluginProtocolError.malformedFrame
    }

    mutating func readLengthDelimited(maximumBytes: Int) throws -> Data {
        let rawLength = try readVarint()
        guard rawLength <= UInt64(maximumBytes), rawLength <= UInt64(Int.max) else {
            throw DockerPluginProtocolError.frameTooLarge(maximumBytes: maximumBytes)
        }
        let length = Int(rawLength)
        guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else {
            throw DockerPluginProtocolError.malformedFrame
        }
        let value = Data(data[index..<end])
        index = end
        return value
    }

    mutating func skip(wireType: UInt8) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            try advance(8)
        case 2:
            let length = try readVarint()
            guard length <= UInt64(Int.max) else {
                throw DockerPluginProtocolError.malformedFrame
            }
            try advance(Int(length))
        case 5:
            try advance(4)
        default:
            throw DockerPluginProtocolError.malformedFrame
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard let end = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
            throw DockerPluginProtocolError.malformedFrame
        }
        index = end
    }
}
