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

public protocol FluentdChunkIDGenerating: Sendable {
    func makeChunkID(timestamp: ContainerLogTimestamp) throws -> String
}

/// Docker's fluent-logger client uses 16 bytes: little-endian event seconds
/// followed by one random UInt64, then standard padded Base64.
public struct RandomFluentdChunkIDGenerator: FluentdChunkIDGenerating {
    public init() {}

    public func makeChunkID(timestamp: ContainerLogTimestamp) throws -> String {
        var seconds = timestamp.secondsSinceUnixEpoch.littleEndian
        var generator = SystemRandomNumberGenerator()
        var random = generator.next().littleEndian
        var material = Data()
        material.reserveCapacity(16)
        withUnsafeBytes(of: &seconds) { material.append(contentsOf: $0) }
        withUnsafeBytes(of: &random) { material.append(contentsOf: $0) }
        return material.base64EncodedString()
    }
}

public struct FluentdEncodedEvent: Equatable, Sendable {
    public let bytes: Data
    public let chunkID: String?

    public init(bytes: Data, chunkID: String?) {
        self.bytes = bytes
        self.chunkID = chunkID
    }
}

/// Encodes Forward protocol Message mode as the pinned Docker fluent logger:
/// `[tag, time, record, option]`, with EventTime extension type zero when
/// sub-second precision is requested.
public struct FluentdForwardMessageEncoder: Sendable {
    public static let maximumRecordPayloadBytes =
        ContainerLogRecordSplitterV1.maximumSupportedRecordBytes

    private let configuration: FluentdDriverConfiguration
    private let chunkIDGenerator: any FluentdChunkIDGenerating

    public init(
        configuration: FluentdDriverConfiguration,
        chunkIDGenerator: any FluentdChunkIDGenerating = RandomFluentdChunkIDGenerator()
    ) {
        self.configuration = configuration
        self.chunkIDGenerator = chunkIDGenerator
    }

    public func encode(_ record: ContainerLogRecordV2) throws -> FluentdEncodedEvent {
        guard record.payload.count <= Self.maximumRecordPayloadBytes else {
            throw FluentdProviderError.recordPayloadTooLarge(
                maximumBytes: Self.maximumRecordPayloadBytes
            )
        }

        let chunkID =
            configuration.requestAcknowledgement
            ? try chunkIDGenerator.makeChunkID(timestamp: record.observation.wallClock)
            : nil
        var fields: [String: FluentdMessagePackString] = [
            "container_id": .utf8(configuration.containerID),
            "container_name": .utf8(configuration.containerName),
            "log": .raw(record.payload),
            "source": .utf8(record.stream.rawValue),
        ]
        for (key, value) in configuration.metadata {
            fields[key] = .utf8(value)
        }
        if let partial = record.partial {
            fields["partial_message"] = .utf8("true")
            fields["partial_id"] = .utf8(partial.id)
            fields["partial_ordinal"] = .utf8(String(partial.ordinal))
            fields["partial_last"] = .utf8(String(partial.last))
        }

        var writer = FluentdMessagePackWriter()
        writer.appendArrayHeader(count: 4)
        writer.appendStringBytes(configuration.tag)
        if configuration.subSecondPrecision {
            writer.appendEventTime(record.observation.wallClock)
        } else {
            writer.appendSignedInteger(record.observation.wallClock.secondsSinceUnixEpoch)
        }
        writer.appendStringMap(fields)
        if let chunkID {
            writer.appendStringMap(["chunk": .utf8(chunkID)])
        } else {
            writer.appendMapHeader(count: 0)
        }
        return FluentdEncodedEvent(bytes: writer.data, chunkID: chunkID)
    }
}

public enum FluentdForwardAcknowledgementCodec {
    public struct Decoded: Equatable, Sendable {
        public let chunkID: String
        public let consumedBytes: Int

        public init(chunkID: String, consumedBytes: Int) {
            self.chunkID = chunkID
            self.consumedBytes = consumedBytes
        }
    }

    /// Returns nil only when another transport fragment is required.
    public static func decode(_ data: Data) throws -> Decoded? {
        var parser = FluentdMessagePackParser(bytes: Array(data))
        do {
            let count = try parser.readMapHeader()
            guard count <= 1_024 else {
                throw FluentdProviderError.invalidAcknowledgement
            }
            var acknowledgement: String?
            for _ in 0..<count {
                let key = try parser.readString()
                if key == "ack" {
                    acknowledgement = try parser.readString()
                } else {
                    try parser.skipValue(depth: 0)
                }
            }
            guard let acknowledgement else {
                throw FluentdProviderError.invalidAcknowledgement
            }
            return Decoded(
                chunkID: acknowledgement,
                consumedBytes: parser.consumedBytes
            )
        } catch FluentdMessagePackParserError.incomplete {
            return nil
        } catch let error as FluentdProviderError {
            throw error
        } catch {
            throw FluentdProviderError.invalidAcknowledgement
        }
    }

    /// Useful to small Forward receivers and deterministic loopback fixtures.
    public static func encode(chunkID: String) -> Data {
        var writer = FluentdMessagePackWriter()
        writer.appendStringMap(["ack": .utf8(chunkID)])
        return writer.data
    }
}

private enum FluentdMessagePackString {
    case utf8(String)
    case raw(Data)
}

private struct FluentdMessagePackWriter {
    private(set) var data = Data()

    mutating func appendArrayHeader(count: Int) {
        if count <= 15 {
            data.append(0x90 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xdc)
            append(UInt16(count))
        } else {
            data.append(0xdd)
            append(UInt32(count))
        }
    }

    mutating func appendMapHeader(count: Int) {
        if count <= 15 {
            data.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xde)
            append(UInt16(count))
        } else {
            data.append(0xdf)
            append(UInt32(count))
        }
    }

    mutating func appendUTF8String(_ value: String) {
        appendStringBytes(Data(value.utf8))
    }

    mutating func appendStringBytes(_ value: Data) {
        switch value.count {
        case 0...31:
            data.append(0xa0 | UInt8(value.count))
        case 32...Int(UInt8.max):
            data.append(0xd9)
            data.append(UInt8(value.count))
        case (Int(UInt8.max) + 1)...Int(UInt16.max):
            data.append(0xda)
            append(UInt16(value.count))
        default:
            data.append(0xdb)
            append(UInt32(value.count))
        }
        data.append(value)
    }

    mutating func appendSignedInteger(_ value: Int64) {
        switch value {
        case 0...127:
            data.append(UInt8(value))
        case 128...Int64(Int16.max):
            data.append(0xd1)
            append(UInt16(bitPattern: Int16(value)))
        case (Int64(Int16.max) + 1)...Int64(Int32.max):
            data.append(0xd2)
            append(UInt32(bitPattern: Int32(value)))
        case (Int64(Int32.max) + 1)...Int64.max:
            data.append(0xd3)
            append(UInt64(bitPattern: value))
        case -32 ... -1:
            data.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int8.min)...(-33):
            data.append(0xd0)
            data.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int16.min)...(Int64(Int8.min) - 1):
            data.append(0xd1)
            append(UInt16(bitPattern: Int16(value)))
        case Int64(Int32.min)...(Int64(Int16.min) - 1):
            data.append(0xd2)
            append(UInt32(bitPattern: Int32(value)))
        default:
            data.append(0xd3)
            append(UInt64(bitPattern: value))
        }
    }

    mutating func appendEventTime(_ timestamp: ContainerLogTimestamp) {
        data.append(0xd7)  // fixext 8
        data.append(0x00)  // Forward EventTime extension type
        append(UInt32(truncatingIfNeeded: timestamp.secondsSinceUnixEpoch))
        append(timestamp.nanoseconds)
    }

    mutating func appendStringMap(_ fields: [String: FluentdMessagePackString]) {
        appendMapHeader(count: fields.count)
        for key in fields.keys.sorted() {
            appendUTF8String(key)
            switch fields[key] {
            case .utf8(let value): appendUTF8String(value)
            case .raw(let value): appendStringBytes(value)
            case nil: preconditionFailure("sorted MessagePack key disappeared")
            }
        }
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

private enum FluentdMessagePackParserError: Error {
    case incomplete
    case malformed
}

private struct FluentdMessagePackParser {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var consumedBytes: Int { index }

    mutating func readMapHeader() throws -> Int {
        let marker = try readByte()
        if marker & 0xf0 == 0x80 {
            return Int(marker & 0x0f)
        }
        switch marker {
        case 0xde: return Int(try readInteger(UInt16.self))
        case 0xdf:
            let count = try readInteger(UInt32.self)
            return Int(count)
        default: throw FluentdMessagePackParserError.malformed
        }
    }

    mutating func readString() throws -> String {
        let marker = try readByte()
        let count = try stringOrBinaryLength(marker: marker)
        let value = try readBytes(count: count)
        guard let string = String(bytes: value, encoding: .utf8) else {
            throw FluentdMessagePackParserError.malformed
        }
        return string
    }

    mutating func skipValue(depth: Int) throws {
        guard depth <= 32 else {
            throw FluentdMessagePackParserError.malformed
        }
        let marker = try readByte()
        switch marker {
        case 0x00...0x7f, 0xc0, 0xc2, 0xc3, 0xe0...0xff:
            return
        case 0x80...0x8f:
            try skipElements(Int(marker & 0x0f) * 2, depth: depth)
        case 0x90...0x9f:
            try skipElements(Int(marker & 0x0f), depth: depth)
        case 0xa0...0xbf:
            _ = try readBytes(count: Int(marker & 0x1f))
        case 0xc4, 0xd9:
            _ = try readBytes(count: Int(try readByte()))
        case 0xc5, 0xda:
            _ = try readBytes(count: Int(try readInteger(UInt16.self)))
        case 0xc6, 0xdb:
            let count = try readInteger(UInt32.self)
            _ = try readBytes(count: Int(count))
        case 0xc7:
            let count = Int(try readByte())
            _ = try readByte()
            _ = try readBytes(count: count)
        case 0xc8:
            let count = Int(try readInteger(UInt16.self))
            _ = try readByte()
            _ = try readBytes(count: count)
        case 0xc9:
            let count = try readInteger(UInt32.self)
            _ = try readByte()
            _ = try readBytes(count: Int(count))
        case 0xca: _ = try readBytes(count: 4)
        case 0xcb: _ = try readBytes(count: 8)
        case 0xcc, 0xd0: _ = try readByte()
        case 0xcd, 0xd1: _ = try readBytes(count: 2)
        case 0xce, 0xd2: _ = try readBytes(count: 4)
        case 0xcf, 0xd3: _ = try readBytes(count: 8)
        case 0xd4:
            _ = try readByte()
            _ = try readByte()
        case 0xd5:
            _ = try readByte()
            _ = try readBytes(count: 2)
        case 0xd6:
            _ = try readByte()
            _ = try readBytes(count: 4)
        case 0xd7:
            _ = try readByte()
            _ = try readBytes(count: 8)
        case 0xd8:
            _ = try readByte()
            _ = try readBytes(count: 16)
        case 0xdc:
            try skipElements(Int(try readInteger(UInt16.self)), depth: depth)
        case 0xdd:
            let count = try readInteger(UInt32.self)
            try skipElements(Int(count), depth: depth)
        case 0xde:
            try skipElements(Int(try readInteger(UInt16.self)) * 2, depth: depth)
        case 0xdf:
            let count = try readInteger(UInt32.self)
            try skipElements(Int(count) * 2, depth: depth)
        default:
            throw FluentdMessagePackParserError.malformed
        }
    }

    private mutating func stringOrBinaryLength(marker: UInt8) throws -> Int {
        if marker & 0xe0 == 0xa0 {
            return Int(marker & 0x1f)
        }
        switch marker {
        case 0xc4, 0xd9: return Int(try readByte())
        case 0xc5, 0xda: return Int(try readInteger(UInt16.self))
        case 0xc6, 0xdb:
            let count = try readInteger(UInt32.self)
            return Int(count)
        default: throw FluentdMessagePackParserError.malformed
        }
    }

    private mutating func skipElements(_ count: Int, depth: Int) throws {
        guard count <= 2_048 else {
            throw FluentdMessagePackParserError.malformed
        }
        for _ in 0..<count {
            try skipValue(depth: depth + 1)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < bytes.count else {
            throw FluentdMessagePackParserError.incomplete
        }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func readBytes(count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - index else {
            throw FluentdMessagePackParserError.incomplete
        }
        let start = index
        index += count
        return bytes[start..<index]
    }

    private mutating func readInteger<T: FixedWidthInteger>(
        _ type: T.Type
    ) throws -> T {
        let value = try readBytes(count: MemoryLayout<T>.size)
        return value.reduce(into: T.zero) { result, byte in
            result = result << 8 | T(byte)
        }
    }
}
