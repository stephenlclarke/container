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

/// Builds the concatenated HEC event objects emitted by Moby 29.2.1.
public struct SplunkMessageEncoder: Sendable {
    public static let maximumRecordPayloadBytes =
        ContainerLogRecordSplitterV1.maximumSupportedRecordBytes

    private let configuration: SplunkDriverConfiguration

    public init(configuration: SplunkDriverConfiguration) {
        self.configuration = configuration
    }

    public func encode(_ record: ContainerLogRecordV2) throws -> Data? {
        guard record.payload.count <= Self.maximumRecordPayloadBytes else {
            throw SplunkProviderError.recordPayloadTooLarge(
                maximumBytes: Self.maximumRecordPayloadBytes
            )
        }
        let event = try encodeEvent(record)
        guard let event else {
            return nil
        }

        var result = Data("{\"event\":".utf8)
        result.append(event)
        appendStringField("time", value: timestamp(record.observation.wallClock), to: &result)
        appendStringField("host", value: configuration.hostname, to: &result)
        appendOptionalStringField("source", value: configuration.source, to: &result)
        appendOptionalStringField(
            "sourcetype",
            value: configuration.sourceType,
            to: &result
        )
        appendOptionalStringField("index", value: configuration.index, to: &result)
        result.append(UInt8(ascii: "}"))
        return result
    }

    public func encodeBatch(_ records: [Data]) throws -> Data {
        var body = Data()
        body.reserveCapacity(records.reduce(0) { $0 + $1.count })
        for record in records {
            body.append(record)
        }
        guard configuration.gzipEnabled else {
            return body
        }
        return try SplunkGzip.compress(body, level: configuration.gzipLevel)
    }

    private func encodeEvent(_ record: ContainerLogRecordV2) throws -> Data? {
        switch configuration.format {
        case .inline:
            return try inlineEvent(record, preservingJSON: false)
        case .json:
            return try inlineEvent(record, preservingJSON: true)
        case .raw:
            let line = String(decoding: record.payload, as: UTF8.self)
            guard
                !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            var raw =
                configuration.tag.isEmpty
                ? "" : configuration.tag + " "
            for (key, value) in configuration.metadata.sorted(by: {
                $0.key < $1.key
            }) {
                raw += "\(key)=\(value) "
            }
            raw += line
            return try jsonString(raw)
        }
    }

    private func inlineEvent(
        _ record: ContainerLogRecordV2,
        preservingJSON: Bool
    ) throws -> Data {
        var result = Data("{\"line\":".utf8)
        if preservingJSON, isValidJSONFragment(record.payload) {
            result.append(record.payload)
        } else {
            result.append(
                try jsonString(String(decoding: record.payload, as: UTF8.self))
            )
        }
        appendStringField("source", value: record.stream.rawValue, to: &result)
        appendOptionalStringField("tag", value: configuration.tag, to: &result)
        if !configuration.metadata.isEmpty {
            result.append(Data(",\"attrs\":{".utf8))
            for (index, entry) in configuration.metadata.sorted(by: {
                $0.key < $1.key
            }).enumerated() {
                if index > 0 {
                    result.append(UInt8(ascii: ","))
                }
                result.append(try jsonString(entry.key))
                result.append(UInt8(ascii: ":"))
                result.append(try jsonString(entry.value))
            }
            result.append(UInt8(ascii: "}"))
        }
        result.append(UInt8(ascii: "}"))
        return result
    }

    private func timestamp(_ value: ContainerLogTimestamp) -> String {
        let seconds =
            Double(value.secondsSinceUnixEpoch)
            + Double(value.nanoseconds) / 1_000_000_000
        return String(
            format: "%f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    private func appendStringField(
        _ name: String,
        value: String,
        to result: inout Data
    ) {
        result.append(Data(",\"\(name)\":".utf8))
        result.append(try! jsonString(value))
    }

    private func appendOptionalStringField(
        _ name: String,
        value: String,
        to result: inout Data
    ) {
        guard !value.isEmpty else {
            return
        }
        appendStringField(name, value: value, to: &result)
    }

    private func jsonString(_ value: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
    }

    private func isValidJSONFragment(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return false
        }
        return
            (try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )) != nil
    }
}

private enum SplunkGzip {
    static func compress(_ input: Data, level: Int32) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw SplunkProviderError.gzipFailed
        }
        defer { deflateEnd(&stream) }

        return try input.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(inputBuffer.count)
            var output = Data()
            var scratch = [UInt8](repeating: 0, count: 16 * 1024)
            repeat {
                let status = scratch.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw SplunkProviderError.gzipFailed
                }
                output.append(
                    scratch,
                    count: scratch.count - Int(stream.avail_out)
                )
                if status == Z_STREAM_END {
                    return output
                }
            } while true
        }
    }
}
