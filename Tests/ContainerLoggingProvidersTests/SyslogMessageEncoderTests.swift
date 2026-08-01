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
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct SyslogMessageEncoderTests {
    @Test func defaultUnixAndRFC3164PayloadsMatchMoby() throws {
        let unix = SyslogMessageEncoder(
            configuration: try configuration(format: .unix),
            clock: FixedSyslogClock()
        )
        let rfc3164 = SyslogMessageEncoder(
            configuration: try configuration(format: .rfc3164),
            clock: FixedSyslogClock()
        )

        #expect(
            try text(unix.encode(record(stream: .stdout, payload: Data("hello".utf8))))
                == "<30>Aug  1 12:34:56 0123456789ab[4242]: hello\n"
        )
        #expect(
            try text(rfc3164.encode(record(stream: .stderr, payload: Data("failure".utf8))))
                == "<27>Aug  1 12:34:56 engine-host 0123456789ab[4242]: failure\n"
        )
    }

    @Test func rfc5424SecondAndMicrosecondPayloadsMatchMoby() throws {
        let seconds = SyslogMessageEncoder(
            configuration: try configuration(format: .rfc5424),
            clock: FixedSyslogClock()
        )
        let micros = SyslogMessageEncoder(
            configuration: try configuration(format: .rfc5424Micro),
            clock: FixedSyslogClock()
        )

        #expect(
            try text(seconds.encode(record(stream: .stdout, payload: Data("hello".utf8))))
                == "<30>1 2026-08-01T12:34:56Z engine-host 0123456789ab 4242 0123456789ab - hello\n"
        )
        #expect(
            try text(micros.encode(record(stream: .stderr, payload: Data("failure".utf8))))
                == "<27>1 2026-08-01T12:34:56.123456Z engine-host 0123456789ab 4242 0123456789ab - failure\n"
        )
    }

    @Test func tlsUsesRFC5425OctetCountingOnlyForRFC5424Formats() throws {
        let tlsRFC5424 = SyslogMessageEncoder(
            configuration: try configuration(format: .rfc5424, tls: true),
            clock: FixedSyslogClock()
        )
        let tlsRFC3164 = SyslogMessageEncoder(
            configuration: try configuration(format: .rfc3164, tls: true),
            clock: FixedSyslogClock()
        )
        let expected =
            "<30>1 2026-08-01T12:34:56Z engine-host 0123456789ab 4242 0123456789ab - hello\n"

        #expect(
            try text(tlsRFC5424.encode(record(stream: .stdout, payload: Data("hello".utf8))))
                == "\(expected.utf8.count) \(expected)"
        )
        #expect(
            try text(tlsRFC3164.encode(record(stream: .stdout, payload: Data("hello".utf8))))
                == "<30>Aug  1 12:34:56 engine-host 0123456789ab[4242]: hello\n"
        )
    }

    @Test func preservesBinaryBytesAndDoesNotDuplicateExistingNewline() throws {
        let encoder = SyslogMessageEncoder(
            configuration: try configuration(format: .unix),
            clock: FixedSyslogClock()
        )
        let prefix = Data("<30>Aug  1 12:34:56 0123456789ab[4242]: ".utf8)
        let payload = Data([0x00, 0xff, 0x0a])
        var expected = prefix
        expected.append(payload)

        #expect(try encoder.encode(record(stream: .stdout, payload: payload)) == expected)
    }

    @Test func ignoresEmptyPayloadBeforeSamplingClock() throws {
        let clock = CountingSyslogClock()
        let encoder = SyslogMessageEncoder(
            configuration: try configuration(format: .unix),
            clock: clock
        )

        #expect(try encoder.encode(record(stream: .stdout, payload: Data())) == nil)
        #expect(clock.callCount == 0)
    }

    @Test func rejectsRecordsLargerThanTheAuthoritySplitterBound() throws {
        let encoder = SyslogMessageEncoder(
            configuration: try configuration(format: .unix),
            clock: FixedSyslogClock()
        )
        let payload = Data(
            repeating: 0x41,
            count: SyslogMessageEncoder.maximumRecordPayloadBytes + 1
        )

        #expect(
            throws: SyslogProviderError.recordPayloadTooLarge(
                maximumBytes: SyslogMessageEncoder.maximumRecordPayloadBytes
            )
        ) {
            try encoder.encode(record(stream: .stdout, payload: payload))
        }
    }

    private func configuration(
        format: SyslogMessageFormat,
        tls: Bool = false
    ) throws -> SyslogDriverConfiguration {
        let endpoint: SyslogEndpoint =
            tls
            ? .tcpTLS(SyslogNetworkAddress(host: "logs.example", port: "6514"))
            : .tcp(SyslogNetworkAddress(host: "logs.example", port: "514"))
        return try SyslogDriverConfiguration(
            endpoint: endpoint,
            facility: SyslogFacility(number: 3),
            format: format,
            tag: "0123456789ab",
            hostname: "engine-host",
            processID: 4_242,
            tls: tls
                ? SyslogTLSConfiguration(
                    caCertificatePath: "",
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: false
                )
                : nil,
            policy: .dockerCompatible
        )
    }

    private func record(
        stream: ContainerLogStream,
        payload: Data
    ) throws -> ContainerLogRecordV2 {
        try ContainerLogRecordV2(
            stream: stream,
            observation: ContainerLogObservation(
                wallClock: ContainerLogTimestamp(secondsSinceUnixEpoch: 1, nanoseconds: 2),
                monotonicInstant: ContinuousClock().now
            ),
            payload: payload,
            partial: nil,
            sequence: 1,
            processGeneration: 1
        )
    }

    private func text(_ data: Data?) throws -> String {
        let data = try #require(data)
        return try #require(String(data: data, encoding: .utf8))
    }
}

private struct FixedSyslogClock: SyslogClock {
    func now() -> SyslogClockReading {
        let timestamp: ContainerLogTimestamp
        do {
            timestamp = try ContainerLogTimestamp(
                secondsSinceUnixEpoch: 1_785_587_696,
                nanoseconds: 123_456_789
            )
        } catch {
            preconditionFailure("invalid fixed test timestamp: \(error)")
        }
        return SyslogClockReading(
            timestamp: timestamp,
            timeZoneSecondsFromGMT: 0
        )
    }
}

private final class CountingSyslogClock: SyslogClock, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func now() -> SyslogClockReading {
        lock.withLock { calls += 1 }
        return FixedSyslogClock().now()
    }
}
