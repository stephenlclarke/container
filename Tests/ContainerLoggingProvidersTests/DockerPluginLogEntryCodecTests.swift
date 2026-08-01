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

import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct DockerPluginLogEntryCodecTests {
    @Test func frameBytesMatchDockerEntryProtoExactly() throws {
        let entry = DockerPluginLogEntry(
            source: "stdout",
            timeNano: 2,
            line: Data([0x00, 0xff]),
            partial: true,
            partialMetadata: DockerPluginPartialMetadata(
                last: true,
                id: "id",
                ordinal: 3
            )
        )

        let frame = try DockerPluginLogEntryCodec.encodeFrame(entry)

        #expect(
            frame
                == Data([
                    0x00, 0x00, 0x00, 0x1a,
                    0x0a, 0x06, 0x73, 0x74, 0x64, 0x6f, 0x75, 0x74,
                    0x10, 0x02,
                    0x1a, 0x02, 0x00, 0xff,
                    0x20, 0x01,
                    0x2a, 0x08,
                    0x08, 0x01,
                    0x12, 0x02, 0x69, 0x64,
                    0x18, 0x03,
                ])
        )
    }

    @Test func incrementalDecoderHandlesEveryByteBoundaryAndConsecutiveFrames() throws {
        let first = DockerPluginLogEntry(
            source: "stdout",
            timeNano: -1,
            line: Data([0x00, 0xff, 0x0a]),
            partial: false,
            partialMetadata: nil
        )
        let second = DockerPluginLogEntry(
            source: "stderr",
            timeNano: Int64.max,
            line: Data("second".utf8),
            partial: true,
            partialMetadata: DockerPluginPartialMetadata(
                last: false,
                id: "0123456789abcdef",
                ordinal: Int32.max
            )
        )
        var bytes = try DockerPluginLogEntryCodec.encodeFrame(first)
        bytes.append(try DockerPluginLogEntryCodec.encodeFrame(second))
        var decoder = DockerPluginFrameDecoder()
        var decoded = [DockerPluginLogEntry]()

        for byte in bytes {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }
        try decoder.finish()

        #expect(decoded == [first, second])
    }

    @Test func unknownProtobufFieldsAreSkippedWithoutChangingKnownData() throws {
        let entry = DockerPluginLogEntry(
            source: "stdout",
            timeNano: 123,
            line: Data("line".utf8),
            partial: false,
            partialMetadata: nil
        )
        let frame = try DockerPluginLogEntryCodec.encodeFrame(entry)
        var message = Data(frame.dropFirst(4))
        message.append(contentsOf: [0x98, 0x06, 0x2a])

        #expect(try DockerPluginLogEntryCodec.decodeMessage(message) == entry)
    }

    @Test func truncatedAndOversizedFramesFailDeterministically() throws {
        var decoder = DockerPluginFrameDecoder()
        _ = try decoder.append(Data([0x00, 0x00, 0x00, 0x02, 0x0a]))
        #expect(throws: DockerPluginProtocolError.malformedFrame) {
            try decoder.finish()
        }

        var oversized = DockerPluginFrameDecoder()
        let length = UInt32(DockerPluginLogEntryCodec.maximumMessageBytes + 1)
        let prefix = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        #expect(
            throws: DockerPluginProtocolError.frameTooLarge(
                maximumBytes: DockerPluginLogEntryCodec.maximumMessageBytes
            )
        ) {
            try oversized.append(prefix)
        }
    }

    @Test func lineBoundAndMalformedVarintAreRejected() throws {
        let tooLarge = DockerPluginLogEntry(
            source: "stdout",
            timeNano: 0,
            line: Data(
                repeating: 0x41,
                count: DockerPluginLogEntryCodec.maximumLineBytes + 1
            ),
            partial: false,
            partialMetadata: nil
        )
        #expect(
            throws: DockerPluginProtocolError.lineTooLarge(
                maximumBytes: DockerPluginLogEntryCodec.maximumLineBytes
            )
        ) {
            try DockerPluginLogEntryCodec.encodeFrame(tooLarge)
        }

        #expect(throws: DockerPluginProtocolError.malformedFrame) {
            try DockerPluginLogEntryCodec.decodeMessage(Data(repeating: 0x80, count: 11))
        }
    }

    @Test func recordConversionPreservesTimestampStreamPayloadAndPartialMetadata() throws {
        let partial = try ContainerLogPartialMetadataV1(
            validatingID: "a" + String(repeating: "0", count: 63),
            ordinal: 7,
            last: true
        )
        let record = try ContainerLogRecordV2(
            stream: .stderr,
            observation: ContainerLogObservation(
                wallClock: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: -2,
                    nanoseconds: 500_000_000
                ),
                monotonicInstant: ContinuousClock().now
            ),
            payload: Data([0x00, 0xfe]),
            partial: partial,
            sequence: 9,
            processGeneration: 3
        )

        let entry = try DockerPluginLogEntry(record)

        #expect(entry.source == "stderr")
        #expect(entry.timeNano == -1_500_000_000)
        #expect(entry.line == Data([0x00, 0xfe]))
        #expect(entry.partial)
        #expect(
            entry.partialMetadata
                == DockerPluginPartialMetadata(
                    last: true,
                    id: "a" + String(repeating: "0", count: 63),
                    ordinal: 7
                )
        )
    }
}
