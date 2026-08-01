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

import ContainerResource
import Foundation

package enum DockerJSONFileLogError: Error, Equatable, Sendable {
    case invalidActiveFileName
    case invalidConfiguration
    case invalidReadRequest
    case timestampOutsideRFC3339Range
    case malformedTimestamp
    case recordTooLarge
    case malformedRecord
    case unsafeStorage
    case storageLimitExceeded
    case readQuotaExceeded
    case compressionFailed
    case closed
    case writePoisoned
    case io(DockerJSONFileLogIOOperation, Int32)
}

package enum DockerJSONFileLogIOOperation: String, Equatable, Sendable {
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

/// The observable rotation contract frozen for the first native json-file
/// implementation.
///
/// Engine 29.2.1 evidence fixes pre-write threshold checks, one-record
/// overshoot, numeric suffix order, retained-file count, gzip eligibility, and
/// asynchronous atomic gzip publication after replacement-active creation.
/// The next rotation and close fence on outstanding compression, matching
/// Moby's rotate-lock lifecycle.
package enum DockerJSONFileRotationContract: String, Equatable, Sendable {
    case dockerEngine2921AtomicAsynchronousGzipV1 = "engine-29.2.1-atomic-asynchronous-gzip-v1"
}

package struct DockerJSONFileLogConfiguration: Equatable, Sendable {
    package static let defaultMaximumFileCount = 1

    package let maximumFileSize: UInt64?
    package let maximumFileCount: Int
    package let compress: Bool
    package let rotationContract: DockerJSONFileRotationContract

    package init(
        maximumFileSize: UInt64? = nil,
        maximumFileCount: Int = Self.defaultMaximumFileCount,
        compress: Bool = false,
        rotationContract: DockerJSONFileRotationContract = .dockerEngine2921AtomicAsynchronousGzipV1
    ) throws {
        guard maximumFileSize != 0, maximumFileCount >= 1 else {
            throw DockerJSONFileLogError.invalidConfiguration
        }
        guard !compress || (maximumFileSize != nil && maximumFileCount >= 2) else {
            throw DockerJSONFileLogError.invalidConfiguration
        }
        self.maximumFileSize = maximumFileSize
        self.maximumFileCount = maximumFileCount
        self.compress = compress
        self.rotationContract = rotationContract
    }
}

/// A decoded public json-file record.
///
/// `log` retains the exact bytes represented by Docker's public `log` string,
/// including its presentation line feed when present. json-file does not store
/// partial IDs, ordinals, or `last`, so decoding it into
/// `ContainerLogRecordV2` would invent metadata and can mis-render a non-final
/// partial chunk.
package struct DockerJSONFileLogReadRecord: Equatable, Sendable {
    package let stream: ContainerLogStream
    package let timestamp: ContainerLogTimestamp
    package let log: Data
    package let attributes: [String: String]
    package let storageSequence: UInt64
}

package enum DockerJSONFileLogReadIssue: Equatable, Sendable {
    case truncatedFinalRecord(fileIndex: Int)
    case malformedRecord(fileIndex: Int, byteOffset: UInt64)
}

package struct DockerJSONFileLogReadRequest: Equatable, Sendable {
    package static let defaultMaximumDecodedBytes = 64 * 1024 * 1024
    package static let defaultMaximumRecords = 100_000
    /// Process-owned readers never accept caller-inflated resource limits.
    ///
    /// These ceilings bound both stopped-container reads and future API input,
    /// even when a caller constructs the request directly rather than through
    /// an HTTP decoder.
    package static let hardMaximumDecodedBytes = defaultMaximumDecodedBytes
    package static let hardMaximumRecords = defaultMaximumRecords

    package let stdout: Bool
    package let stderr: Bool
    package let tail: Int?
    package let since: ContainerLogTimestamp?
    package let until: ContainerLogTimestamp?
    package let maximumDecodedBytes: Int
    package let maximumRecords: Int

    package init(
        stdout: Bool = true,
        stderr: Bool = true,
        tail: Int? = nil,
        since: ContainerLogTimestamp? = nil,
        until: ContainerLogTimestamp? = nil,
        maximumDecodedBytes: Int = Self.defaultMaximumDecodedBytes,
        maximumRecords: Int = Self.defaultMaximumRecords
    ) throws {
        guard
            tail.map({ $0 >= 0 }) ?? true,
            (1...Self.hardMaximumDecodedBytes).contains(maximumDecodedBytes),
            (1...Self.hardMaximumRecords).contains(maximumRecords),
            tail.map({ $0 <= maximumRecords }) ?? true
        else {
            throw DockerJSONFileLogError.invalidReadRequest
        }
        self.stdout = stdout
        self.stderr = stderr
        self.tail = tail
        self.since = since
        self.until = until
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumRecords = maximumRecords
    }
}

package struct DockerJSONFileLogReadResult: Equatable, Sendable {
    package let records: [DockerJSONFileLogReadRecord]
    package let issues: [DockerJSONFileLogReadIssue]
}

enum DockerJSONFileLogCodec {
    static let maximumEncodedRecordBytes = 1 * 1024 * 1024
    static let maximumPayloadBytes = ContainerLogRecordSplitterV1.maximumSupportedRecordBytes

    static func encode(_ record: ContainerLogRecordV2) throws -> Data {
        guard record.payload.count <= maximumPayloadBytes else {
            throw DockerJSONFileLogError.recordTooLarge
        }

        var publicLog = record.payload
        if record.partial == nil || record.partial?.last == true {
            publicLog.append(UInt8(ascii: "\n"))
        }

        var output = Data()
        output.reserveCapacity(min(maximumEncodedRecordBytes, publicLog.count + 256))
        output.append(UInt8(ascii: "{"))
        if !publicLog.isEmpty {
            output.append(contentsOf: "\"log\":".utf8)
            appendJSONString(publicLog, to: &output)
            output.append(UInt8(ascii: ","))
        }
        output.append(contentsOf: "\"stream\":".utf8)
        appendJSONString(Data(record.stream.rawValue.utf8), to: &output)

        if !record.attributes.isEmpty {
            output.append(contentsOf: ",\"attrs\":{".utf8)
            let sortedAttributes = record.attributes.sorted { lhs, rhs in
                utf8LexicographicallyPrecedes(lhs.key, rhs.key)
            }
            for (index, attribute) in sortedAttributes.enumerated() {
                if index != 0 {
                    output.append(UInt8(ascii: ","))
                }
                appendJSONString(Data(attribute.key.utf8), to: &output)
                output.append(UInt8(ascii: ":"))
                appendJSONString(Data(attribute.value.utf8), to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }

        output.append(contentsOf: ",\"time\":\"".utf8)
        output.append(contentsOf: try DockerRFC3339Nano.format(record.observation.wallClock).utf8)
        output.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: "}"), UInt8(ascii: "\n")])

        guard output.count <= maximumEncodedRecordBytes else {
            throw DockerJSONFileLogError.recordTooLarge
        }
        return output
    }

    static func decode(_ encodedLine: Data, storageSequence: UInt64) throws -> DockerJSONFileLogReadRecord {
        guard !encodedLine.isEmpty, encodedLine.count <= maximumEncodedRecordBytes else {
            throw DockerJSONFileLogError.malformedRecord
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: encodedLine)
        } catch {
            throw DockerJSONFileLogError.malformedRecord
        }
        guard let dictionary = object as? [String: Any] else {
            throw DockerJSONFileLogError.malformedRecord
        }
        let log: String
        if let value = dictionary["log"] {
            guard let string = value as? String else {
                throw DockerJSONFileLogError.malformedRecord
            }
            log = string
        } else {
            log = ""
        }
        guard
            let streamName = dictionary["stream"] as? String,
            let stream = ContainerLogStream(rawValue: streamName),
            let timestampText = dictionary["time"] as? String
        else {
            throw DockerJSONFileLogError.malformedRecord
        }

        let attributes: [String: String]
        if let rawAttributes = dictionary["attrs"] {
            guard let values = rawAttributes as? [String: Any] else {
                throw DockerJSONFileLogError.malformedRecord
            }
            guard values.count <= ContainerLogRecordV2.maximumAttributeCount else {
                throw DockerJSONFileLogError.malformedRecord
            }
            var decoded: [String: String] = [:]
            decoded.reserveCapacity(values.count)
            var decodedBytes = 0
            for (key, rawValue) in values {
                guard let value = rawValue as? String else {
                    throw DockerJSONFileLogError.malformedRecord
                }
                let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
                let (totalBytes, totalOverflow) = decodedBytes.addingReportingOverflow(entryBytes)
                guard
                    !entryOverflow,
                    !totalOverflow,
                    totalBytes <= ContainerLogRecordV2.maximumAttributeUTF8Bytes
                else {
                    throw DockerJSONFileLogError.malformedRecord
                }
                decodedBytes = totalBytes
                decoded[key] = value
            }
            attributes = decoded
        } else {
            attributes = [:]
        }

        return DockerJSONFileLogReadRecord(
            stream: stream,
            timestamp: try DockerRFC3339Nano.parse(timestampText),
            log: Data(log.utf8),
            attributes: attributes,
            storageSequence: storageSequence
        )
    }

    private static func appendJSONString(_ bytes: Data, to output: inout Data) {
        output.append(UInt8(ascii: "\""))
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte < 0x80 {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                    output.append(UInt8(ascii: "\\"))
                    output.append(byte)
                case UInt8(ascii: "\n"):
                    output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
                case UInt8(ascii: "\r"):
                    output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
                case 0x20...0x7e
                where byte != UInt8(ascii: "<") && byte != UInt8(ascii: ">")
                    && byte != UInt8(ascii: "&"):
                    output.append(byte)
                case 0x7f:
                    output.append(byte)
                default:
                    appendUnicodeEscape(UInt16(byte), to: &output)
                }
                index = bytes.index(after: index)
                continue
            }

            guard let scalar = decodeUTF8Scalar(bytes, at: index) else {
                output.append(contentsOf: #"\ufffd"#.utf8)
                index = bytes.index(after: index)
                continue
            }
            if scalar.value == 0x2028 || scalar.value == 0x2029 {
                appendUnicodeEscape(UInt16(scalar.value), to: &output)
            } else {
                let end = bytes.index(index, offsetBy: scalar.length)
                output.append(contentsOf: bytes[index..<end])
            }
            index = bytes.index(index, offsetBy: scalar.length)
        }
        output.append(UInt8(ascii: "\""))
    }

    private static func appendUnicodeEscape(_ value: UInt16, to output: inout Data) {
        let hexadecimal = Array("0123456789abcdef".utf8)
        output.append(contentsOf: #"\u"#.utf8)
        output.append(hexadecimal[Int((value >> 12) & 0xf)])
        output.append(hexadecimal[Int((value >> 8) & 0xf)])
        output.append(hexadecimal[Int((value >> 4) & 0xf)])
        output.append(hexadecimal[Int(value & 0xf)])
    }

    private static func decodeUTF8Scalar(_ bytes: Data, at index: Data.Index) -> (value: UInt32, length: Int)? {
        let first = bytes[index]
        let remaining = bytes.distance(from: index, to: bytes.endIndex)
        let length: Int
        let minimum: UInt32
        var value: UInt32
        switch first {
        case 0xc2...0xdf:
            length = 2
            minimum = 0x80
            value = UInt32(first & 0x1f)
        case 0xe0...0xef:
            length = 3
            minimum = 0x800
            value = UInt32(first & 0x0f)
        case 0xf0...0xf4:
            length = 4
            minimum = 0x10000
            value = UInt32(first & 0x07)
        default:
            return nil
        }
        guard remaining >= length else {
            return nil
        }
        for offset in 1..<length {
            let continuation = bytes[bytes.index(index, offsetBy: offset)]
            guard (0x80...0xbf).contains(continuation) else {
                return nil
            }
            value = (value << 6) | UInt32(continuation & 0x3f)
        }
        guard
            value >= minimum,
            value <= 0x10ffff,
            !(0xd800...0xdfff).contains(value)
        else {
            return nil
        }
        return (value, length)
    }

    private static func utf8LexicographicallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

enum DockerRFC3339Nano {
    static func format(_ timestamp: ContainerLogTimestamp) throws -> String {
        let dayAndSecond = floorQuotientAndRemainder(timestamp.secondsSinceUnixEpoch, divisor: 86_400)
        let civil = civilDate(daysSinceUnixEpoch: dayAndSecond.quotient)
        guard (0...9999).contains(civil.year) else {
            throw DockerJSONFileLogError.timestampOutsideRFC3339Range
        }

        let hour = dayAndSecond.remainder / 3_600
        let minute = (dayAndSecond.remainder % 3_600) / 60
        let second = dayAndSecond.remainder % 60
        var formatted = String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld",
            civil.year,
            civil.month,
            civil.day,
            hour,
            minute,
            second
        )
        if timestamp.nanoseconds != 0 {
            var fraction = String(format: "%09u", timestamp.nanoseconds)
            while fraction.last == "0" {
                fraction.removeLast()
            }
            formatted += ".\(fraction)"
        }
        return formatted + "Z"
    }

    static func parse(_ text: String) throws -> ContainerLogTimestamp {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20 else {
            throw DockerJSONFileLogError.malformedTimestamp
        }
        guard
            bytes[safe: 4] == UInt8(ascii: "-"),
            bytes[safe: 7] == UInt8(ascii: "-"),
            bytes[safe: 10] == UInt8(ascii: "T"),
            bytes[safe: 13] == UInt8(ascii: ":"),
            bytes[safe: 16] == UInt8(ascii: ":")
        else {
            throw DockerJSONFileLogError.malformedTimestamp
        }
        let year = try decimal(bytes, 0..<4)
        let month = try decimal(bytes, 5..<7)
        let day = try decimal(bytes, 8..<10)
        let hour = try decimal(bytes, 11..<13)
        let minute = try decimal(bytes, 14..<16)
        let second = try decimal(bytes, 17..<19)
        guard
            (1...12).contains(month),
            (1...daysInMonth(year: year, month: month)).contains(day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second)
        else {
            throw DockerJSONFileLogError.malformedTimestamp
        }

        var cursor = 19
        var nanoseconds = 0
        if bytes[safe: cursor] == UInt8(ascii: ".") {
            cursor += 1
            let fractionStart = cursor
            while cursor < bytes.count, isDecimalDigit(bytes[cursor]) {
                cursor += 1
            }
            let digitCount = cursor - fractionStart
            guard digitCount >= 1 else {
                throw DockerJSONFileLogError.malformedTimestamp
            }
            // Go's time parser, used by Moby's json-file decoder, accepts an
            // arbitrarily long fractional part and truncates it to nanosecond
            // precision. Validate every digit above, but only accumulate the
            // first nine so a long hostile fraction cannot overflow Int.
            let parsedDigitCount = min(digitCount, 9)
            nanoseconds = try decimal(
                bytes,
                fractionStart..<(fractionStart + parsedDigitCount)
            )
            for _ in parsedDigitCount..<9 {
                nanoseconds *= 10
            }
        }

        let offsetSeconds: Int
        if bytes[safe: cursor] == UInt8(ascii: "Z"), cursor + 1 == bytes.count {
            offsetSeconds = 0
        } else {
            guard
                let signByte = bytes[safe: cursor],
                signByte == UInt8(ascii: "+") || signByte == UInt8(ascii: "-"),
                cursor + 6 == bytes.count,
                bytes[safe: cursor + 3] == UInt8(ascii: ":")
            else {
                throw DockerJSONFileLogError.malformedTimestamp
            }
            let offsetHour = try decimal(bytes, (cursor + 1)..<(cursor + 3))
            let offsetMinute = try decimal(bytes, (cursor + 4)..<(cursor + 6))
            guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else {
                throw DockerJSONFileLogError.malformedTimestamp
            }
            let magnitude = offsetHour * 3_600 + offsetMinute * 60
            offsetSeconds = signByte == UInt8(ascii: "+") ? magnitude : -magnitude
        }

        let days = daysSinceUnixEpoch(year: year, month: month, day: day)
        let seconds =
            days * 86_400
            + Int64(hour * 3_600 + minute * 60 + second - offsetSeconds)
        return try ContainerLogTimestamp(
            secondsSinceUnixEpoch: seconds,
            nanoseconds: UInt32(nanoseconds)
        )
    }

    private static func decimal(_ bytes: [UInt8], _ range: Range<Int>) throws -> Int {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw DockerJSONFileLogError.malformedTimestamp
        }
        var value = 0
        for byte in bytes[range] {
            guard isDecimalDigit(byte) else {
                throw DockerJSONFileLogError.malformedTimestamp
            }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func isDecimalDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int64 {
        var adjustedYear = Int64(year)
        if month <= 2 {
            adjustedYear -= 1
        }
        let era = floorQuotientAndRemainder(adjustedYear, divisor: 400).quotient
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = Int64(month + (month > 2 ? -3 : 9))
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilDate(daysSinceUnixEpoch: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shiftedDays = daysSinceUnixEpoch + 719_468
        let era = floorQuotientAndRemainder(shiftedDays, divisor: 146_097).quotient
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        if month <= 2 {
            year += 1
        }
        return (year, month, day)
    }

    private static func floorQuotientAndRemainder(
        _ dividend: Int64,
        divisor: Int64
    ) -> (quotient: Int64, remainder: Int64) {
        var quotient = dividend / divisor
        var remainder = dividend % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }
}

extension Collection where Index == Int {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
