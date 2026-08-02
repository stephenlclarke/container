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

struct FluentdForwardCodecTests {
    @Test func messageModeEncodingIsExactAndBinarySafe() throws {
        let configuration = try fluentdTestConfiguration(
            maximumRetries: 1,
            tag: "abc",
            containerID: "id",
            containerName: "/web"
        )
        let encoder = FluentdForwardMessageEncoder(
            configuration: configuration
        )
        let encoded = try encoder.encode(
            fluentdRecord(payload: Data([0xff, 0x00]))
        )

        var expected = Data([0x94, 0xa3])
        expected.append(Data("abc".utf8))
        expected.append(0x01)
        expected.append(0x84)
        expected.append(messagePackString("container_id"))
        expected.append(messagePackString("id"))
        expected.append(messagePackString("container_name"))
        expected.append(messagePackString("/web"))
        expected.append(messagePackString("log"))
        expected.append(contentsOf: [0xa2, 0xff, 0x00])
        expected.append(messagePackString("source"))
        expected.append(messagePackString("stdout"))
        expected.append(0x80)

        #expect(encoded.bytes == expected)
        #expect(encoded.chunkID == nil)
    }

    @Test func eventTimeAndChunkOptionMatchForwardProtocol() throws {
        let configuration = try fluentdTestConfiguration(
            maximumRetries: 1,
            requestAcknowledgement: true,
            subSecondPrecision: true,
            tag: "abc",
            containerID: "id",
            containerName: "name"
        )
        let encoder = FluentdForwardMessageEncoder(
            configuration: configuration,
            chunkIDGenerator: FixedFluentdChunkIDGenerator(
                chunkID: "chunk-1"
            )
        )
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 0x0102_0304,
            nanoseconds: 0x0506_0708
        )
        let encoded = try encoder.encode(
            fluentdRecord(payload: Data("event".utf8), timestamp: timestamp)
        )

        #expect(
            encoded.bytes.prefix(14)
                == Data([
                    0x94,
                    0xa3, 0x61, 0x62, 0x63,
                    0xd7, 0x00,
                    0x01, 0x02, 0x03, 0x04,
                    0x05, 0x06, 0x07,
                ])
        )
        #expect(encoded.bytes[encoded.bytes.startIndex + 14] == 0x08)
        #expect(encoded.bytes.suffix(15) == messagePackChunkOption("chunk-1"))
        #expect(encoded.chunkID == "chunk-1")
    }

    @Test func integerTimestampEncodingMatchesFluentLoggerInt64() throws {
        let encoder = FluentdForwardMessageEncoder(
            configuration: try fluentdTestConfiguration(
                maximumRetries: 1,
                tag: "t"
            )
        )
        let cases: [(Int64, [UInt8])] = [
            (127, [0x7f]),
            (128, [0xd1, 0x00, 0x80]),
            (32_767, [0xd1, 0x7f, 0xff]),
            (32_768, [0xd2, 0x00, 0x00, 0x80, 0x00]),
            (2_147_483_648, [0xd3, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00]),
            (-33, [0xd0, 0xdf]),
        ]

        for (seconds, expected) in cases {
            let encoded = try encoder.encode(
                fluentdRecord(
                    payload: Data(),
                    timestamp: ContainerLogTimestamp(
                        secondsSinceUnixEpoch: seconds,
                        nanoseconds: 0
                    )
                )
            )
            #expect(
                Array(encoded.bytes.dropFirst(3).prefix(expected.count))
                    == expected
            )
        }
    }

    @Test func metadataOverridesBaseFieldsAndPartialFieldsOverrideMetadata() throws {
        let configuration = try fluentdTestConfiguration(
            maximumRetries: 1,
            containerID: "base-id",
            containerName: "base-name",
            metadata: [
                "container_id": "metadata-id",
                "partial_last": "metadata-last",
            ]
        )
        let encoded = try FluentdForwardMessageEncoder(
            configuration: configuration
        ).encode(
            fluentdRecord(
                stream: .stderr,
                payload: Data("part".utf8),
                partial: fluentdPartial(ordinal: 7, last: false)
            )
        )

        #expect(
            encoded.bytes.range(
                of: messagePackPair("container_id", "metadata-id")
            ) != nil
        )
        #expect(
            encoded.bytes.range(of: messagePackPair("partial_last", "false"))
                != nil
        )
        #expect(
            encoded.bytes.range(of: messagePackPair("partial_ordinal", "7"))
                != nil
        )
        #expect(
            encoded.bytes.range(of: messagePackPair("source", "stderr"))
                != nil
        )
        #expect(encoded.bytes.range(of: Data("base-id".utf8)) == nil)
        #expect(encoded.bytes.range(of: Data("metadata-last".utf8)) == nil)
    }

    @Test func blankLinesRemainEventsAndOversizedRecordsAreRejected() throws {
        let encoder = FluentdForwardMessageEncoder(
            configuration: try fluentdTestConfiguration(maximumRetries: 1)
        )
        let blank = try encoder.encode(fluentdRecord(payload: Data()))
        #expect(blank.bytes.range(of: messagePackPair("log", "")) != nil)

        let oversized = Data(
            repeating: 0x41,
            count: FluentdForwardMessageEncoder.maximumRecordPayloadBytes + 1
        )
        #expect(
            throws: FluentdProviderError.recordPayloadTooLarge(
                maximumBytes: FluentdForwardMessageEncoder.maximumRecordPayloadBytes
            )
        ) {
            try encoder.encode(fluentdRecord(payload: oversized))
        }
    }

    @Test func acknowledgementCodecHandlesFragmentsUnknownFieldsAndBounds() throws {
        let encoded = FluentdForwardAcknowledgementCodec.encode(
            chunkID: "chunk-ack"
        )
        #expect(try FluentdForwardAcknowledgementCodec.decode(Data()) == nil)
        #expect(
            try FluentdForwardAcknowledgementCodec.decode(encoded.dropLast())
                == nil
        )
        #expect(
            try FluentdForwardAcknowledgementCodec.decode(encoded)
                == .init(
                    chunkID: "chunk-ack",
                    consumedBytes: encoded.count
                )
        )

        var withUnknown = Data([0x82])
        withUnknown.append(messagePackString("ignored"))
        withUnknown.append(contentsOf: [0x92, 0x01, 0x02])
        withUnknown.append(messagePackString("ack"))
        withUnknown.append(messagePackString("chunk-ack"))
        #expect(
            try FluentdForwardAcknowledgementCodec.decode(withUnknown)?.chunkID
                == "chunk-ack"
        )

        #expect(throws: FluentdProviderError.invalidAcknowledgement) {
            try FluentdForwardAcknowledgementCodec.decode(Data([0x80]))
        }
        #expect(throws: FluentdProviderError.invalidAcknowledgement) {
            var malformed = Data([0x81])
            malformed.append(messagePackString("ack"))
            malformed.append(0xc0)
            _ = try FluentdForwardAcknowledgementCodec.decode(malformed)
        }
    }

    @Test func randomChunkMaterialIsPaddedBase64OfSixteenBytes() throws {
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 42,
            nanoseconds: 7
        )
        let value = try RandomFluentdChunkIDGenerator().makeChunkID(
            timestamp: timestamp
        )
        let material = try #require(Data(base64Encoded: value))
        #expect(material.count == 16)
        #expect(material.prefix(8) == Data([42, 0, 0, 0, 0, 0, 0, 0]))
    }
}

private func messagePackPair(_ key: String, _ value: String) -> Data {
    var data = messagePackString(key)
    data.append(messagePackString(value))
    return data
}

private func messagePackChunkOption(_ chunk: String) -> Data {
    var data = Data([0x81])
    data.append(messagePackString("chunk"))
    data.append(messagePackString(chunk))
    return data
}

private func messagePackString(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    precondition(bytes.count <= 31)
    var data = Data([0xa0 | UInt8(bytes.count)])
    data.append(bytes)
    return data
}
