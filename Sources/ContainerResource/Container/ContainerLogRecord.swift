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

/// A timestamped chunk of container log output.
public struct ContainerLogRecord: Codable, Equatable, Sendable {
    private static let timestampCodec = ContainerLogRecordTimestampCodec()

    /// The output stream that produced the log data.
    public enum Stream: String, Codable, Equatable, Sendable {
        /// Standard output.
        case stdout

        /// Standard error.
        case stderr
    }

    /// The time at which the runtime observed the log data.
    public let timestamp: Date

    /// The output stream that produced the data.
    public let stream: Stream

    /// The raw log bytes produced by the stream.
    public let data: Data

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case stream
        case data
    }

    public init(timestamp: Date, stream: Stream, data: Data) {
        self.timestamp = timestamp
        self.stream = stream
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp: Date?
        if let timestampValue = try? container.decode(String.self, forKey: .timestamp) {
            timestamp = Self.timestamp(from: timestampValue)
        } else if let timeInterval = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSinceReferenceDate: timeInterval)
        } else {
            timestamp = nil
        }
        guard let timestamp else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "expected an ISO 8601 timestamp"
            )
        }
        self.timestamp = timestamp
        self.stream = try container.decode(Stream.self, forKey: .stream)
        self.data = try container.decode(Data.self, forKey: .data)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.string(from: timestamp), forKey: .timestamp)
        try container.encode(stream, forKey: .stream)
        try container.encode(data, forKey: .data)
    }

    private static func string(from date: Date) -> String {
        timestampCodec.string(from: date)
    }

    private static func timestamp(from value: String) -> Date? {
        timestampCodec.date(from: value)
    }
}

/// Reuses ISO 8601 formatters across structured log record encode/decode calls.
private final class ContainerLogRecordTimestampCodec: @unchecked Sendable {
    private let lock = NSLock()
    private let fractionalFormatter: ISO8601DateFormatter
    private let formatter: ISO8601DateFormatter

    init() {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalFormatter = fractionalFormatter

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer {
            lock.unlock()
        }
        return fractionalFormatter.string(from: date)
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return fractionalFormatter.date(from: value) ?? formatter.date(from: value)
    }
}
