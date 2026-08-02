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

package enum NativeLocalLogError: Error, Equatable, Sendable {
    case invalidActiveFileName
    case invalidConfiguration
    case invalidReadRequest
    case recordTooLarge
    case malformedHeader
    case malformedFrame
    case unsafeStorage
    case storageLimitExceeded
    case compressionFailed
    case closed
    case writePoisoned
    case io(NativeLocalLogIOOperation, Int32)
}

package enum NativeLocalLogIOOperation: String, Equatable, Sendable {
    case close
    case createDirectory
    case enumerate
    case metadata
    case open
    case read
    case remove
    case rename
    case sync
    case truncate
    case write
}

/// Container-owned defaults matching Docker's visible `local` driver policy.
package struct NativeLocalLogConfiguration: Equatable, Sendable {
    package static let defaultMaximumFileSize: UInt64 = 20 * 1024 * 1024
    package static let defaultMaximumFileCount = 5

    package let maximumFileSize: UInt64
    package let maximumFileCount: Int
    package let compress: Bool

    package init(
        maximumFileSize: UInt64 = Self.defaultMaximumFileSize,
        maximumFileCount: Int = Self.defaultMaximumFileCount,
        compress: Bool = true
    ) throws {
        guard
            maximumFileSize > 0,
            maximumFileSize <= UInt64(Int64.max),
            maximumFileCount > 0,
            !compress || maximumFileCount >= 2
        else {
            throw NativeLocalLogError.invalidConfiguration
        }
        self.maximumFileSize = maximumFileSize
        self.maximumFileCount = maximumFileCount
        self.compress = compress
    }
}

package enum NativeLocalLogReadIssue: Equatable, Sendable {
    case truncatedFinalFrame(fileIndex: Int, byteOffset: UInt64)
    case corruptFrame(fileIndex: Int, byteOffset: UInt64)
    case corruptCompressedFile(fileIndex: Int)
}

package struct NativeLocalLogReadRequest: Equatable, Sendable {
    package static let defaultMaximumDecodedBytes = 128 * 1024 * 1024
    package static let defaultMaximumStoredBytes = 128 * 1024 * 1024
    package static let defaultMaximumRecords = 100_000
    package static let hardMaximumDecodedBytes = 128 * 1024 * 1024
    package static let hardMaximumStoredBytes = 128 * 1024 * 1024
    package static let hardMaximumAggregateBytes = 256 * 1024 * 1024
    package static let hardMaximumRecords = 100_000

    package let stdout: Bool
    package let stderr: Bool
    package let tail: Int?
    package let since: ContainerLogTimestamp?
    package let until: ContainerLogTimestamp?
    package let maximumDecodedBytes: Int
    package let maximumStoredBytes: Int
    package let maximumRecords: Int

    package init(
        stdout: Bool = true,
        stderr: Bool = true,
        tail: Int? = nil,
        since: ContainerLogTimestamp? = nil,
        until: ContainerLogTimestamp? = nil,
        maximumDecodedBytes: Int = Self.defaultMaximumDecodedBytes,
        maximumStoredBytes: Int = Self.defaultMaximumStoredBytes,
        maximumRecords: Int = Self.defaultMaximumRecords
    ) throws {
        guard
            maximumDecodedBytes > 0,
            maximumDecodedBytes <= Self.hardMaximumDecodedBytes,
            maximumStoredBytes > 0,
            maximumStoredBytes <= Self.hardMaximumStoredBytes,
            maximumRecords > 0,
            maximumRecords <= Self.hardMaximumRecords,
            tail.map({ $0 < 0 || $0 <= maximumRecords }) ?? true,
            maximumDecodedBytes <= Self.hardMaximumAggregateBytes - maximumStoredBytes
        else {
            throw NativeLocalLogError.invalidReadRequest
        }
        self.stdout = stdout
        self.stderr = stderr
        self.tail = tail
        self.since = since
        self.until = until
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumStoredBytes = maximumStoredBytes
        self.maximumRecords = maximumRecords
    }

    package var effectiveTail: Int? {
        guard let tail, tail >= 0 else {
            return nil
        }
        return tail
    }
}

package struct NativeLocalLogReadResult: Equatable, Sendable {
    package let records: [ContainerLogRecordV2]
    package let issues: [NativeLocalLogReadIssue]
}

/// Versioned private codec for the native `local` driver.
///
/// Every frame has a CRC-protected body and repeats its body length in a
/// footer. The footer permits bounded backward tail traversal while the prefix
/// keeps forward replay and crash-tail recovery simple. This encoding is a
/// Container implementation detail and does not claim Docker byte parity.
enum NativeLocalLogCodec {
    static let fileHeaderSize = 16
    static let framePrefixSize = 16
    static let frameFooterSize = 4
    static let maximumFrameBodyBytes = 128 * 1024
    static let maximumEncodedFrameBytes =
        framePrefixSize + maximumFrameBodyBytes + frameFooterSize

    private static let fileMagic: [UInt8] = [
        0x43, 0x4c, 0x4f, 0x43, 0x41, 0x4c, 0x01, 0x00,
    ]
    static let frameMagic: [UInt8] = [0x43, 0x4c, 0x46, 0x01]
    private static let bodyVersion = UInt8(1)
    private static let fixedBodySize = 52
    private static let partialPresentFlag = UInt8(1 << 0)
    private static let partialLastFlag = UInt8(1 << 1)

    static let fileHeader: Data = {
        var header = Data(fileMagic)
        appendLittleEndian(UInt16(fileHeaderSize), to: &header)
        appendLittleEndian(UInt16(0), to: &header)
        appendLittleEndian(NativeLocalCRC32.checksum(header), to: &header)
        return header
    }()

    static func validateFileHeader(_ data: Data) throws {
        guard data.count == fileHeaderSize else {
            throw NativeLocalLogError.malformedHeader
        }
        let content = Data(data.prefix(12))
        guard
            Array(data.prefix(fileMagic.count)) == fileMagic,
            readLittleEndianUInt16(data, at: 8) == fileHeaderSize,
            readLittleEndianUInt16(data, at: 10) == 0,
            readLittleEndianUInt32(data, at: 12) == NativeLocalCRC32.checksum(content)
        else {
            throw NativeLocalLogError.malformedHeader
        }
    }

    static func encode(_ record: ContainerLogRecordV2) throws -> Data {
        guard record.payload.count <= ContainerLogRecordSplitterV1.maximumSupportedRecordBytes else {
            throw NativeLocalLogError.recordTooLarge
        }

        let partialID = record.partial.map { Data($0.id.utf8) } ?? Data()
        guard partialID.count <= Int(UInt16.max) else {
            throw NativeLocalLogError.recordTooLarge
        }

        let sortedAttributes = record.attributes.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        var attributeSection = Data()
        for attribute in sortedAttributes {
            let key = Data(attribute.key.utf8)
            let value = Data(attribute.value.utf8)
            guard key.count <= Int(UInt32.max), value.count <= Int(UInt32.max) else {
                throw NativeLocalLogError.recordTooLarge
            }
            appendLittleEndian(UInt32(key.count), to: &attributeSection)
            appendLittleEndian(UInt32(value.count), to: &attributeSection)
            attributeSection.append(key)
            attributeSection.append(value)
        }
        guard
            sortedAttributes.count <= Int(UInt16.max),
            attributeSection.count <= Int(UInt32.max)
        else {
            throw NativeLocalLogError.recordTooLarge
        }

        var flags = UInt8(0)
        if let partial = record.partial {
            flags |= partialPresentFlag
            if partial.last {
                flags |= partialLastFlag
            }
        }

        var body = Data()
        body.reserveCapacity(fixedBodySize + record.payload.count + partialID.count + attributeSection.count)
        body.append(bodyVersion)
        body.append(record.stream == .stdout ? 0 : 1)
        body.append(flags)
        body.append(0)
        appendLittleEndian(UInt64(bitPattern: record.observation.wallClock.secondsSinceUnixEpoch), to: &body)
        appendLittleEndian(record.observation.wallClock.nanoseconds, to: &body)
        appendLittleEndian(UInt32(record.payload.count), to: &body)
        appendLittleEndian(record.sequence, to: &body)
        appendLittleEndian(record.processGeneration, to: &body)
        appendLittleEndian(record.partial?.ordinal ?? 0, to: &body)
        appendLittleEndian(UInt16(partialID.count), to: &body)
        appendLittleEndian(UInt16(sortedAttributes.count), to: &body)
        appendLittleEndian(UInt32(attributeSection.count), to: &body)
        body.append(record.payload)
        body.append(partialID)
        body.append(attributeSection)

        guard body.count <= maximumFrameBodyBytes else {
            throw NativeLocalLogError.recordTooLarge
        }

        var frame = Data(frameMagic)
        appendLittleEndian(UInt32(body.count), to: &frame)
        appendLittleEndian(NativeLocalCRC32.checksum(body), to: &frame)
        appendLittleEndian(UInt32(0), to: &frame)
        frame.append(body)
        appendLittleEndian(UInt32(body.count), to: &frame)
        return frame
    }

    static func decode(_ frame: Data) throws -> ContainerLogRecordV2 {
        guard frame.count >= framePrefixSize + fixedBodySize + frameFooterSize else {
            throw NativeLocalLogError.malformedFrame
        }
        guard Array(frame.prefix(frameMagic.count)) == frameMagic else {
            throw NativeLocalLogError.malformedFrame
        }
        let bodyLength = Int(readLittleEndianUInt32(frame, at: 4))
        guard
            bodyLength <= maximumFrameBodyBytes,
            frame.count == framePrefixSize + bodyLength + frameFooterSize,
            readLittleEndianUInt32(frame, at: 12) == 0,
            Int(readLittleEndianUInt32(frame, at: frame.count - frameFooterSize)) == bodyLength
        else {
            throw NativeLocalLogError.malformedFrame
        }

        let body = Data(frame[framePrefixSize..<(framePrefixSize + bodyLength)])
        guard NativeLocalCRC32.checksum(body) == readLittleEndianUInt32(frame, at: 8) else {
            throw NativeLocalLogError.malformedFrame
        }
        var cursor = NativeLocalDataCursor(data: body)
        guard
            try cursor.readUInt8() == bodyVersion,
            let stream = try decodeStream(cursor.readUInt8()),
            case let flags = try cursor.readUInt8(),
            flags & ~(partialPresentFlag | partialLastFlag) == 0,
            try cursor.readUInt8() == 0
        else {
            throw NativeLocalLogError.malformedFrame
        }

        let seconds = Int64(bitPattern: try cursor.readUInt64())
        let nanoseconds = try cursor.readUInt32()
        let payloadLength = Int(try cursor.readUInt32())
        let sequence = try cursor.readUInt64()
        let processGeneration = try cursor.readUInt64()
        let partialOrdinal = try cursor.readUInt64()
        let partialIDLength = Int(try cursor.readUInt16())
        let attributeCount = Int(try cursor.readUInt16())
        let attributeSectionLength = Int(try cursor.readUInt32())

        let hasPartial = flags & partialPresentFlag != 0
        guard
            payloadLength <= ContainerLogRecordSplitterV1.maximumSupportedRecordBytes,
            attributeCount <= ContainerLogRecordV2.maximumAttributeCount,
            attributeSectionLength <= maximumFrameBodyBytes,
            hasPartial == (partialIDLength > 0),
            hasPartial == (partialOrdinal > 0),
            hasPartial || flags & partialLastFlag == 0,
            cursor.remaining == payloadLength + partialIDLength + attributeSectionLength
        else {
            throw NativeLocalLogError.malformedFrame
        }

        let payload = try cursor.readData(count: payloadLength)
        let partialIDData = try cursor.readData(count: partialIDLength)
        let attributeData = try cursor.readData(count: attributeSectionLength)
        guard cursor.remaining == 0 else {
            throw NativeLocalLogError.malformedFrame
        }

        let partial: ContainerLogPartialMetadataV1?
        if hasPartial {
            guard let partialID = String(data: partialIDData, encoding: .utf8) else {
                throw NativeLocalLogError.malformedFrame
            }
            do {
                partial = try ContainerLogPartialMetadataV1(
                    validatingID: partialID,
                    ordinal: partialOrdinal,
                    last: flags & partialLastFlag != 0
                )
            } catch {
                throw NativeLocalLogError.malformedFrame
            }
        } else {
            partial = nil
        }

        let attributes = try decodeAttributes(attributeData, count: attributeCount)
        let timestamp: ContainerLogTimestamp
        do {
            timestamp = try ContainerLogTimestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            )
        } catch {
            throw NativeLocalLogError.malformedFrame
        }

        do {
            return try ContainerLogRecordV2(
                stream: stream,
                observation: ContainerLogObservation(
                    wallClock: timestamp,
                    monotonicInstant: ContinuousClock().now
                ),
                payload: payload,
                partial: partial,
                sequence: sequence,
                attributes: attributes,
                processGeneration: processGeneration
            )
        } catch {
            throw NativeLocalLogError.malformedFrame
        }
    }

    static func frameLength(bodyLength: Int) throws -> Int {
        guard bodyLength >= fixedBodySize, bodyLength <= maximumFrameBodyBytes else {
            throw NativeLocalLogError.malformedFrame
        }
        return framePrefixSize + bodyLength + frameFooterSize
    }

    static func bodyLength(fromFramePrefix prefix: Data) throws -> Int {
        guard
            prefix.count == framePrefixSize,
            Array(prefix.prefix(frameMagic.count)) == frameMagic,
            readLittleEndianUInt32(prefix, at: 12) == 0
        else {
            throw NativeLocalLogError.malformedFrame
        }
        return Int(readLittleEndianUInt32(prefix, at: 4))
    }

    static func bodyLength(fromFrameFooter footer: Data) throws -> Int {
        guard footer.count == frameFooterSize else {
            throw NativeLocalLogError.malformedFrame
        }
        return Int(readLittleEndianUInt32(footer, at: 0))
    }

    static func hasFrameMagic(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, data.count - offset >= frameMagic.count else {
            return false
        }
        return frameMagic.indices.allSatisfy { data[offset + $0] == frameMagic[$0] }
    }

    static func isTruncatedFramePrefix(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return false
        }
        if data.count < frameMagic.count {
            return data.indices.allSatisfy { data[$0] == frameMagic[$0] }
        }
        guard hasFrameMagic(data, at: 0) else {
            return false
        }
        if data.count < framePrefixSize {
            return true
        }
        guard
            let bodyLength = try? bodyLength(
                fromFramePrefix: Data(data.prefix(framePrefixSize))
            ),
            let frameLength = try? frameLength(bodyLength: bodyLength)
        else {
            return false
        }
        return data.count < frameLength
    }

    private static func decodeStream(_ byte: UInt8) -> ContainerLogStream? {
        switch byte {
        case 0:
            .stdout
        case 1:
            .stderr
        default:
            nil
        }
    }

    private static func decodeAttributes(_ data: Data, count: Int) throws -> [String: String] {
        var cursor = NativeLocalDataCursor(data: data)
        var attributes: [String: String] = [:]
        attributes.reserveCapacity(count)
        for _ in 0..<count {
            let keyLength = Int(try cursor.readUInt32())
            let valueLength = Int(try cursor.readUInt32())
            guard keyLength <= cursor.remaining, valueLength <= cursor.remaining - keyLength else {
                throw NativeLocalLogError.malformedFrame
            }
            let keyData = try cursor.readData(count: keyLength)
            let valueData = try cursor.readData(count: valueLength)
            guard
                let key = String(data: keyData, encoding: .utf8),
                let value = String(data: valueData, encoding: .utf8),
                attributes.updateValue(value, forKey: key) == nil
            else {
                throw NativeLocalLogError.malformedFrame
            }
        }
        guard cursor.remaining == 0 else {
            throw NativeLocalLogError.malformedFrame
        }
        return attributes
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readLittleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private struct NativeLocalDataCursor {
    let data: Data
    private(set) var offset = 0

    var remaining: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw NativeLocalLogError.malformedFrame
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        var value = UInt64(0)
        for index in 0..<8 {
            value |= UInt64(bytes[index]) << UInt64(index * 8)
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw NativeLocalLogError.malformedFrame
        }
        let end = offset + count
        defer { offset = end }
        return Data(data[offset..<end])
    }
}

private enum NativeLocalCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return ~crc
    }
}
