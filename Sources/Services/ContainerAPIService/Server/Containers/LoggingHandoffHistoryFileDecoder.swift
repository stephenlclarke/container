//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import CryptoKit
import Darwin
import Foundation

struct LoggingHandoffExtractedHistoryRecordV2: Sendable {
    let canonicalRecordByteLength: UInt64
    let metadataRecordBytes: Data
    let historyFile: LoggingHandoffHistoryFileV2?
}

/// Extracts the one potentially large `bytes` value from a deterministic CBOR
/// history record. The input stays mapped and only 64 KiB is copied at a time;
/// the small metadata projection is decoded by the common canonical decoder.
enum LoggingHandoffHistoryFileDecoder {
    private static let copyChunkBytes = 64 * 1024

    static func extract(
        canonicalRecordURL: URL,
        historyDirectoryURL: URL
    ) throws -> LoggingHandoffExtractedHistoryRecordV2 {
        let record = try Data(
            contentsOf: canonicalRecordURL,
            options: .mappedIfSafe
        )
        var scanner = Scanner(data: record)
        let location = try scanner.historyBytesLocation()
        guard scanner.isAtEnd else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        guard let location else {
            return LoggingHandoffExtractedHistoryRecordV2(
                canonicalRecordByteLength: UInt64(record.count),
                metadataRecordBytes: record,
                historyFile: nil
            )
        }

        let target = historyDirectoryURL.appendingPathComponent(
            "history-\(UUID().uuidString).bin",
            isDirectory: false
        )
        let descriptor = target.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed {
                _ = target.path.withCString(Darwin.unlink)
            }
        }

        var digest = SHA256()
        var offset = location.payloadRange.lowerBound
        while offset < location.payloadRange.upperBound {
            let upper = min(
                location.payloadRange.upperBound,
                offset + copyChunkBytes
            )
            let chunk = record.subdata(in: offset..<upper)
            try output.write(contentsOf: chunk)
            digest.update(data: chunk)
            offset = upper
        }
        try output.synchronize()
        try output.close()

        var metadata = Data()
        metadata.reserveCapacity(
            record.count - location.encodedRange.count + 1
        )
        metadata.append(record.subdata(in: 0..<location.encodedRange.lowerBound))
        metadata.append(0xf6)
        metadata.append(
            record.subdata(
                in: location.encodedRange.upperBound..<record.count
            )
        )
        let digestHex = ProviderHandoffDigest.hex(Data(digest.finalize()))
        completed = true
        return LoggingHandoffExtractedHistoryRecordV2(
            canonicalRecordByteLength: UInt64(record.count),
            metadataRecordBytes: metadata,
            historyFile: LoggingHandoffHistoryFileV2(
                url: target,
                byteLength: UInt64(location.payloadRange.count),
                contentDigestSHA256: digestHex
            )
        )
    }

    private struct ByteLocation {
        let encodedRange: Range<Int>
        let payloadRange: Range<Int>
    }

    private struct Scanner {
        private static let maximumDepth = 64
        private static let maximumCollectionEntries = 1_000_000
        private static let maximumTextBytes = 1024 * 1024
        private static let maximumByteStringBytes =
            LoggingHandoffHistoryStoreV1.maximumStoredBytesPerSegment

        let data: Data
        var offset = 0
        var totalCollectionEntries = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func historyBytesLocation() throws -> ByteLocation? {
            let count = try collectionCount(argument(major: 5))
            var result: ByteLocation?
            for _ in 0..<count {
                let key = try text()
                if key == "bytes" {
                    guard result == nil else {
                        throw LoggingHandoffPayloadError.invalidPackage
                    }
                    result = try byteStringLocation()
                } else {
                    try skipValue(depth: 1)
                }
            }
            return result
        }

        private mutating func byteStringLocation() throws -> ByteLocation? {
            let encodedStart = offset
            let initial = try byte()
            if initial == 0xf6 {
                return nil
            }
            let length = try argument(initial: initial, major: 2)
            guard
                length <= UInt64(Self.maximumByteStringBytes),
                let count = Int(exactly: length),
                offset <= data.count - count
            else {
                throw LoggingHandoffPayloadError.boundsExceeded
            }
            let payloadStart = offset
            offset += count
            return ByteLocation(
                encodedRange: encodedStart..<offset,
                payloadRange: payloadStart..<offset
            )
        }

        private mutating func skipValue(depth: Int) throws {
            guard depth <= Self.maximumDepth else {
                throw LoggingHandoffPayloadError.boundsExceeded
            }
            let initial = try byte()
            let major = initial >> 5
            switch major {
            case 0, 1:
                _ = try argument(initial: initial, major: major)
            case 2:
                let count = try boundedCount(
                    argument(initial: initial, major: 2),
                    maximum: Self.maximumByteStringBytes
                )
                try advance(count)
            case 3:
                let count = try boundedCount(
                    argument(initial: initial, major: 3),
                    maximum: Self.maximumTextBytes
                )
                let bytes = try read(count)
                guard
                    let value = String(data: bytes, encoding: .utf8),
                    value.precomposedStringWithCanonicalMapping == value
                else {
                    throw LoggingHandoffPayloadError.invalidPackage
                }
            case 4:
                let count = try collectionCount(
                    argument(initial: initial, major: 4)
                )
                for _ in 0..<count {
                    try skipValue(depth: depth + 1)
                }
            case 5:
                let count = try collectionCount(
                    argument(initial: initial, major: 5)
                )
                for _ in 0..<count {
                    try skipValue(depth: depth + 1)
                    try skipValue(depth: depth + 1)
                }
            case 7 where initial == 0xf4 || initial == 0xf5 || initial == 0xf6:
                break
            default:
                throw LoggingHandoffPayloadError.invalidPackage
            }
        }

        private mutating func text() throws -> String {
            let count = try boundedCount(
                argument(major: 3),
                maximum: Self.maximumTextBytes
            )
            let bytes = try read(count)
            guard
                let value = String(data: bytes, encoding: .utf8),
                value.precomposedStringWithCanonicalMapping == value
            else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            return value
        }

        private mutating func collectionCount(_ value: UInt64) throws -> Int {
            let count = try boundedCount(
                value,
                maximum: Self.maximumCollectionEntries
            )
            guard
                totalCollectionEntries
                    <= Self.maximumCollectionEntries - count
            else {
                throw LoggingHandoffPayloadError.boundsExceeded
            }
            totalCollectionEntries += count
            return count
        }

        private func boundedCount(_ value: UInt64, maximum: Int) throws -> Int {
            guard
                value <= UInt64(maximum),
                let result = Int(exactly: value)
            else {
                throw LoggingHandoffPayloadError.boundsExceeded
            }
            return result
        }

        private mutating func argument(major: UInt8) throws -> UInt64 {
            try argument(initial: byte(), major: major)
        }

        private mutating func argument(
            initial: UInt8,
            major: UInt8
        ) throws -> UInt64 {
            guard initial >> 5 == major else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            let additional = initial & 0x1f
            switch additional {
            case 0..<24:
                return UInt64(additional)
            case 24:
                let value = UInt64(try byte())
                guard value >= 24 else {
                    throw LoggingHandoffPayloadError.invalidPackage
                }
                return value
            case 25:
                let value = UInt64(try integer(UInt16.self))
                guard value > UInt8.max else {
                    throw LoggingHandoffPayloadError.invalidPackage
                }
                return value
            case 26:
                let value = UInt64(try integer(UInt32.self))
                guard value > UInt16.max else {
                    throw LoggingHandoffPayloadError.invalidPackage
                }
                return value
            case 27:
                let value = try integer(UInt64.self)
                guard value > UInt32.max else {
                    throw LoggingHandoffPayloadError.invalidPackage
                }
                return value
            default:
                throw LoggingHandoffPayloadError.invalidPackage
            }
        }

        private mutating func byte() throws -> UInt8 {
            guard offset < data.count else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            defer { offset += 1 }
            return data[offset]
        }

        private mutating func integer<T: FixedWidthInteger>(
            _ type: T.Type
        ) throws -> T {
            let bytes = try read(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes {
                $0.loadUnaligned(as: T.self).bigEndian
            }
        }

        private mutating func read(_ count: Int) throws -> Data {
            guard count >= 0, offset <= data.count - count else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        private mutating func advance(_ count: Int) throws {
            guard count >= 0, offset <= data.count - count else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            offset += count
        }
    }
}
