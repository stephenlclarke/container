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

public struct SyslogClockReading: Equatable, Sendable {
    public let timestamp: ContainerLogTimestamp
    public let timeZoneSecondsFromGMT: Int

    public init(
        timestamp: ContainerLogTimestamp,
        timeZoneSecondsFromGMT: Int
    ) {
        self.timestamp = timestamp
        self.timeZoneSecondsFromGMT = timeZoneSecondsFromGMT
    }
}

public protocol SyslogClock: Sendable {
    func now() -> SyslogClockReading
}

public struct SystemSyslogClock: SyslogClock {
    public init() {}

    public func now() -> SyslogClockReading {
        let date = Date.now
        let interval = date.timeIntervalSince1970
        var seconds = Int64(interval.rounded(.down))
        var nanoseconds = UInt32(((interval - Double(seconds)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        let timestamp: ContainerLogTimestamp
        do {
            timestamp = try ContainerLogTimestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            )
        } catch {
            preconditionFailure("system clock produced an invalid timestamp: \(error)")
        }
        return SyslogClockReading(
            timestamp: timestamp,
            // The maintained Engine Linux sandbox runs its daemon clock in
            // UTC. Reading the macOS user's local zone would make identical
            // records differ from Docker whenever the host is not on UTC.
            timeZoneSecondsFromGMT: 0
        )
    }
}

public struct SyslogMessageEncoder: Sendable {
    public static let maximumRecordPayloadBytes = ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
    public static let maximumEncodedMessageBytes = 4 * 1024 * 1024

    private let configuration: SyslogDriverConfiguration
    private let clock: any SyslogClock

    public init(
        configuration: SyslogDriverConfiguration,
        clock: any SyslogClock = SystemSyslogClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Encodes one Moby-compatible syslog write. Empty payloads are ignored,
    /// and binary bytes are never forced through a Unicode conversion.
    public func encode(_ record: ContainerLogRecordV2) throws -> Data? {
        guard !record.payload.isEmpty else {
            return nil
        }
        guard record.payload.count <= Self.maximumRecordPayloadBytes else {
            throw SyslogProviderError.recordPayloadTooLarge(
                maximumBytes: Self.maximumRecordPayloadBytes
            )
        }

        let reading = clock.now()
        let priority = configuration.facility.priority(for: record.stream)
        var message = Data()
        switch configuration.format {
        case .unix:
            message.append(Data("<\(priority)>\(Self.stamp(reading)) ".utf8))
            message.append(configuration.tag)
            message.append(Data("[\(configuration.processID)]: ".utf8))
        case .rfc3164:
            message.append(
                Data(
                    "<\(priority)>\(Self.stamp(reading)) \(configuration.hostname) "
                        .utf8
                )
            )
            message.append(configuration.tag)
            message.append(Data("[\(configuration.processID)]: ".utf8))
        case .rfc5424:
            message.append(
                Self.rfc5424Prefix(
                    priority: priority,
                    timestamp: Self.rfc3339(reading, microseconds: false),
                    configuration: configuration
                )
            )
        case .rfc5424Micro:
            message.append(
                Self.rfc5424Prefix(
                    priority: priority,
                    timestamp: Self.rfc3339(reading, microseconds: true),
                    configuration: configuration
                )
            )
        }

        message.append(record.payload)
        if record.payload.last != UInt8(ascii: "\n") {
            message.append(UInt8(ascii: "\n"))
        }
        guard message.count <= Self.maximumEncodedMessageBytes else {
            throw SyslogProviderError.encodedMessageTooLarge(
                maximumBytes: Self.maximumEncodedMessageBytes
            )
        }

        if configuration.endpoint.usesTLS,
            configuration.format == .rfc5424 || configuration.format == .rfc5424Micro
        {
            var framed = Data("\(message.count) ".utf8)
            framed.append(message)
            guard framed.count <= Self.maximumEncodedMessageBytes else {
                throw SyslogProviderError.encodedMessageTooLarge(
                    maximumBytes: Self.maximumEncodedMessageBytes
                )
            }
            return framed
        }
        return message
    }

    private static func rfc5424Prefix(
        priority: Int,
        timestamp: String,
        configuration: SyslogDriverConfiguration
    ) -> Data {
        var result = Data(
            "<\(priority)>1 \(timestamp) \(configuration.hostname) ".utf8
        )
        result.append(configuration.tag)
        result.append(Data(" \(configuration.processID) ".utf8))
        result.append(configuration.tag)
        result.append(Data(" - ".utf8))
        return result
    }

    private static func stamp(_ reading: SyslogClockReading) -> String {
        let components = dateComponents(reading)
        let month = monthNames[components.month - 1]
        return "\(month) \(leftPad(components.day, width: 2, character: " ")) "
            + "\(twoDigits(components.hour)):\(twoDigits(components.minute)):\(twoDigits(components.second))"
    }

    private static func rfc3339(
        _ reading: SyslogClockReading,
        microseconds: Bool
    ) -> String {
        let components = dateComponents(reading)
        var value =
            "\(leftPad(components.year, width: 4, character: "0"))-"
            + "\(twoDigits(components.month))-\(twoDigits(components.day))T"
            + "\(twoDigits(components.hour)):\(twoDigits(components.minute)):\(twoDigits(components.second))"
        if microseconds {
            value += ".\(leftPad(Int(reading.timestamp.nanoseconds / 1_000), width: 6, character: "0"))"
        }
        value += offset(reading.timeZoneSecondsFromGMT)
        return value
    }

    private static func dateComponents(
        _ reading: SyslogClockReading
    ) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: reading.timeZoneSecondsFromGMT) ?? .gmt
        let date = Date(timeIntervalSince1970: Double(reading.timestamp.secondsSinceUnixEpoch))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return (
            components.year ?? 0,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private static func offset(_ secondsFromGMT: Int) -> String {
        guard secondsFromGMT != 0 else {
            return "Z"
        }
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let magnitude = abs(secondsFromGMT)
        return "\(sign)\(twoDigits(magnitude / 3_600)):\(twoDigits(magnitude % 3_600 / 60))"
    }

    private static func twoDigits(_ value: Int) -> String {
        leftPad(value, width: 2, character: "0")
    }

    private static func leftPad(
        _ value: Int,
        width: Int,
        character: Character
    ) -> String {
        let rendered = String(value)
        guard rendered.count < width else {
            return rendered
        }
        return String(repeating: String(character), count: width - rendered.count) + rendered
    }

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
}
