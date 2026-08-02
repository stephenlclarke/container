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
import zlib

public struct GELFMessageEncoder: Sendable {
    public static let maximumRecordPayloadBytes =
        ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
    public static let maximumEncodedMessageBytes = 4 * 1024 * 1024

    private let configuration: GELFDriverConfiguration

    public init(configuration: GELFDriverConfiguration) {
        self.configuration = configuration
    }

    /// Encodes the exact GELF 1.1 object Moby builds before go-gelf applies its
    /// transport framing. Empty records are intentionally dropped.
    public func encode(_ record: ContainerLogRecordV2) throws -> Data? {
        guard !record.payload.isEmpty else {
            return nil
        }
        guard record.payload.count <= Self.maximumRecordPayloadBytes else {
            throw GELFProviderError.recordPayloadTooLarge(
                maximumBytes: Self.maximumRecordPayloadBytes
            )
        }

        var json = Data()
        json.reserveCapacity(record.payload.count + 512)
        json.append(UInt8(ascii: "{"))
        appendField(name: "version", value: "1.1", to: &json, first: true)
        appendField(name: "host", value: configuration.hostname, to: &json)
        appendField(
            name: "short_message",
            value: String(decoding: record.payload, as: UTF8.self),
            to: &json
        )
        appendName("timestamp", to: &json)
        json.append(contentsOf: try Self.timestamp(record.observation.wallClock).utf8)
        appendName("level", to: &json)
        json.append(contentsOf: (record.stream == .stderr ? "3" : "6").utf8)

        var extra: [String: String] = [
            "_command": configuration.command,
            "_container_id": configuration.containerID,
            "_container_name": configuration.containerName,
            "_created": Self.created(configuration.created),
            "_image_id": configuration.imageID,
            "_image_name": configuration.imageName,
            "_tag": configuration.tag,
        ]
        // Docker applies selected labels/environment after its built-in fields,
        // so a selected key such as `container_id` deliberately overrides it.
        for (key, value) in configuration.metadata {
            extra[key.hasPrefix("_") ? key : "_" + key] = value
        }
        for key in extra.keys.sorted(by: Self.utf8Less) {
            appendField(name: key, value: extra[key] ?? "", to: &json)
        }
        json.append(UInt8(ascii: "}"))
        guard json.count <= Self.maximumEncodedMessageBytes else {
            throw GELFProviderError.encodedMessageTooLarge(
                maximumBytes: Self.maximumEncodedMessageBytes
            )
        }
        return json
    }

    public static func tcpFrame(_ json: Data) throws -> Data {
        guard json.count < maximumEncodedMessageBytes else {
            throw GELFProviderError.encodedMessageTooLarge(
                maximumBytes: maximumEncodedMessageBytes
            )
        }
        var framed = json
        framed.append(0)
        return framed
    }

    private func appendField(
        name: String,
        value: String,
        to data: inout Data,
        first: Bool = false
    ) {
        if !first {
            data.append(UInt8(ascii: ","))
        }
        Self.appendJSONString(name, to: &data)
        data.append(UInt8(ascii: ":"))
        Self.appendJSONString(value, to: &data)
    }

    private func appendName(_ name: String, to data: inout Data) {
        data.append(UInt8(ascii: ","))
        Self.appendJSONString(name, to: &data)
        data.append(UInt8(ascii: ":"))
    }

    private static func appendJSONString(_ value: String, to data: inout Data) {
        data.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: data.append(contentsOf: "\\b".utf8)
            case 0x09: data.append(contentsOf: "\\t".utf8)
            case 0x0a: data.append(contentsOf: "\\n".utf8)
            case 0x0c: data.append(contentsOf: "\\f".utf8)
            case 0x0d: data.append(contentsOf: "\\r".utf8)
            case 0x22: data.append(contentsOf: "\\\"".utf8)
            case 0x5c: data.append(contentsOf: "\\\\".utf8)
            case 0x00...0x1f, 0x26, 0x3c, 0x3e, 0x2028, 0x2029:
                data.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            default:
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        data.append(UInt8(ascii: "\""))
    }

    private static func timestamp(_ value: ContainerLogTimestamp) throws -> String {
        // Moby first forms time.Time.UnixNano(), then divides the combined
        // signed value by time.Millisecond. Combining before division matters
        // before the epoch because Go integer division truncates toward zero.
        let unixNanoseconds: Int64
        if value.secondsSinceUnixEpoch >= 0 {
            let (secondsNanoseconds, multiplicationOverflow) =
                value.secondsSinceUnixEpoch.multipliedReportingOverflow(
                    by: 1_000_000_000
                )
            let (combined, additionOverflow) = secondsNanoseconds.addingReportingOverflow(
                Int64(value.nanoseconds)
            )
            guard !multiplicationOverflow, !additionOverflow else {
                throw GELFProviderError.timestampOutOfRange
            }
            unixNanoseconds = combined
        } else {
            // Shift one whole second toward zero before multiplying so the
            // exactly representable Int64.minimum boundary has no overflowing
            // intermediate value.
            let shiftedSeconds = value.secondsSinceUnixEpoch + 1
            let (secondsNanoseconds, multiplicationOverflow) =
                shiftedSeconds.multipliedReportingOverflow(by: 1_000_000_000)
            let negativeSubsecond = 1_000_000_000 - Int64(value.nanoseconds)
            let (combined, subtractionOverflow) =
                secondsNanoseconds
                .subtractingReportingOverflow(negativeSubsecond)
            guard !multiplicationOverflow, !subtractionOverflow else {
                throw GELFProviderError.timestampOutOfRange
            }
            unixNanoseconds = combined
        }
        let milliseconds = unixNanoseconds / 1_000_000
        let whole = milliseconds / 1_000
        let fraction = abs(milliseconds % 1_000)
        guard fraction != 0 else {
            return String(whole)
        }
        let sign = milliseconds < 0 && whole == 0 ? "-" : ""
        var fractionText = String(format: "%03lld", fraction)
        while fractionText.last == "0" {
            fractionText.removeLast()
        }
        return "\(sign)\(whole).\(fractionText)"
    }

    private static func created(_ value: Date) -> String {
        let interval = value.timeIntervalSince1970
        var seconds = Int64(interval.rounded(.down))
        var nanoseconds = Int(((interval - Double(seconds)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        let date = Date(timeIntervalSince1970: Double(seconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        var result = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            components.year ?? 1,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
        if nanoseconds != 0 {
            var fraction = String(format: "%09d", nanoseconds)
            while fraction.last == "0" {
                fraction.removeLast()
            }
            result += "." + fraction
        }
        return result + "Z"
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

public protocol GELFChunkIDGenerating: Sendable {
    func makeChunkID() throws -> Data
}

public struct RandomGELFChunkIDGenerator: GELFChunkIDGenerating {
    public init() {}

    public func makeChunkID() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var random = generator.next()
        return withUnsafeBytes(of: &random) { Data($0) }
    }
}

public struct GELFDatagramEncoder: Sendable {
    public static let chunkSize = 1_420
    public static let chunkHeaderBytes = 12
    public static let chunkDataBytes = chunkSize - chunkHeaderBytes
    public static let maximumChunks = 128

    private let compressionType: GELFCompressionType
    private let compressionLevel: Int32
    private let chunkIDGenerator: any GELFChunkIDGenerating

    public init(
        compressionType: GELFCompressionType,
        compressionLevel: Int32,
        chunkIDGenerator: any GELFChunkIDGenerating = RandomGELFChunkIDGenerator()
    ) {
        self.compressionType = compressionType
        self.compressionLevel = compressionLevel
        self.chunkIDGenerator = chunkIDGenerator
    }

    public func encode(_ json: Data) throws -> [Data] {
        let payload = try GELFCompressionCodec.compress(
            json,
            type: compressionType,
            level: compressionLevel
        )
        let chunkCount = Self.numberOfChunks(forPayloadBytes: payload.count)
        guard chunkCount <= Self.maximumChunks else {
            throw GELFProviderError.tooManyChunks(
                maximum: Self.maximumChunks,
                actual: chunkCount
            )
        }
        guard chunkCount > 1 else {
            return [payload]
        }
        let chunkID = try chunkIDGenerator.makeChunkID()
        guard chunkID.count == 8 else {
            throw GELFProviderError.chunkIdentifierInvalid
        }

        var chunks = [Data]()
        chunks.reserveCapacity(chunkCount)
        var bytesLeft = payload.count
        for sequence in 0..<chunkCount {
            let count = min(Self.chunkDataBytes, bytesLeft)
            let offset = sequence * Self.chunkDataBytes
            var chunk = Data([0x1e, 0x0f])
            chunk.append(chunkID)
            chunk.append(UInt8(sequence))
            chunk.append(UInt8(chunkCount))
            if count > 0 {
                chunk.append(payload[offset..<(offset + count)])
            }
            chunks.append(chunk)
            bytesLeft -= count
        }
        return chunks
    }

    static func numberOfChunks(forPayloadBytes count: Int) -> Int {
        guard count > chunkSize else {
            return 1
        }
        // Preserve the pinned go-gelf formula, including its empty trailing
        // chunk when the payload is an exact multiple of 1408 bytes.
        return count / chunkDataBytes + 1
    }
}

enum GELFCompressionCodec {
    static func compress(
        _ input: Data,
        type: GELFCompressionType,
        level: Int32
    ) throws -> Data {
        switch type {
        case .none:
            return input
        case .gzip:
            return try deflate(input, level: level, windowBits: 15 + 16)
        case .zlib:
            return try deflate(input, level: level, windowBits: 15)
        }
    }

    private static func deflate(
        _ input: Data,
        level: Int32,
        windowBits: Int32
    ) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw GELFProviderError.compressionFailed
        }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var output = [UInt8](repeating: 0, count: max(bound, 64))
        let outputCapacity = output.count
        let status: Int32 = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw GELFProviderError.compressionFailed
        }
        return Data(output.prefix(Int(stream.total_out)))
    }
}
