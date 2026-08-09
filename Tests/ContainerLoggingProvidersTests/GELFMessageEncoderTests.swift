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

import CryptoKit
import DockerSemanticHelper
import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct GELFMessageEncoderTests {
    @Test func emitsExactGELF11ShapeTimestampPriorityAndDockerExtras() throws {
        let configuration = try gelfTestConfiguration(
            tag: "tag",
            hostname: "host",
            containerID: "built-in-id",
            containerName: "web",
            imageID: "image-id",
            imageName: "image-name",
            command: "command",
            metadata: [
                "container_id": "selected-id",
                "_z": "last",
            ]
        )
        let encoder = GELFMessageEncoder(configuration: configuration)
        let record = try gelfRecord(
            stream: .stderr,
            payload: Data("hello<&>\n".utf8)
        )
        let optionalEncoded = try encoder.encode(record)
        let encoded = try #require(optionalEncoded)

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"version":"1.1","host":"host","short_message":"hello\u003c\u0026\u003e\n","timestamp":1.234,"level":3,"_command":"command","_container_id":"selected-id","_container_name":"web","_created":"1970-01-01T00:00:01.25Z","_image_id":"image-id","_image_name":"image-name","_tag":"tag","_z":"last"}"#
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["version"] as? String == "1.1")
        #expect(object["timestamp"] as? Double == 1.234)
        #expect(object["level"] as? Int == 3)
        #expect(object["_container_id"] as? String == "selected-id")
    }

    @Test func dropsEmptyRecordsReplacesInvalidUTF8AndIgnoresPartialMetadata() throws {
        let encoder = GELFMessageEncoder(
            configuration: try gelfTestConfiguration()
        )
        #expect(try encoder.encode(gelfRecord(payload: Data())) == nil)

        let partial = try ContainerLogPartialMetadataV1(
            validatingID: "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            ordinal: 4,
            last: false
        )
        let partialRecord = try gelfRecord(payload: Data([0xff]), partial: partial)
        let completeRecord = try gelfRecord(payload: Data([0xff]))
        let optionalWithPartial = try encoder.encode(partialRecord)
        let optionalWithoutPartial = try encoder.encode(completeRecord)
        let withPartial = try #require(optionalWithPartial)
        let withoutPartial = try #require(optionalWithoutPartial)
        #expect(withPartial == withoutPartial)
        let object = try #require(
            JSONSerialization.jsonObject(with: withPartial) as? [String: Any]
        )
        #expect(object["short_message"] as? String == "\u{fffd}")
        #expect(object["level"] as? Int == 6)
    }

    @Test func tcpFrameIsNULTerminatedAndBounded() throws {
        let json = Data("{\"version\":\"1.1\"}".utf8)
        let frame = try GELFMessageEncoder.tcpFrame(json)
        #expect(frame.dropLast() == json)
        #expect(frame.last == 0)

        #expect(
            throws: GELFProviderError.encodedMessageTooLarge(
                maximumBytes: GELFMessageEncoder.maximumEncodedMessageBytes
            )
        ) {
            try GELFMessageEncoder.tcpFrame(
                Data(
                    repeating: 0,
                    count: GELFMessageEncoder.maximumEncodedMessageBytes
                )
            )
        }
    }

    @Test func timestampUsesCombinedSignedUnixNanoBeforeMillisecondTruncation() throws {
        let encoder = GELFMessageEncoder(
            configuration: try gelfTestConfiguration()
        )

        for testCase in try gelfOracleFixture().timestamps.prefix(6) {
            let optionalEncoded = try encoder.encode(
                gelfRecord(
                    payload: Data("timestamp".utf8),
                    timestamp: ContainerLogTimestamp(
                        secondsSinceUnixEpoch: testCase.seconds,
                        nanoseconds: testCase.nanoseconds
                    )
                )
            )
            let encoded = try #require(optionalEncoded)
            #expect(
                String(decoding: encoded, as: UTF8.self)
                    .contains(#""timestamp":\#(testCase.jsonNumber),"level""#)
            )
        }
    }

    @Test func timestampArithmeticIsCheckedAtSignedUnixNanoBoundaries() throws {
        let encoder = GELFMessageEncoder(
            configuration: try gelfTestConfiguration()
        )
        let maximumSafeSeconds: Int64 = 9_223_372_036
        let minimumSafeSeconds: Int64 = -9_223_372_037

        let optionalMaximum = try encoder.encode(
            gelfRecord(
                payload: Data("maximum".utf8),
                timestamp: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: maximumSafeSeconds,
                    nanoseconds: 854_775_807
                )
            )
        )
        let maximum = try #require(optionalMaximum)
        #expect(
            String(decoding: maximum, as: UTF8.self)
                .contains(#""timestamp":9223372036.854,"level""#)
        )

        let optionalMinimum = try encoder.encode(
            gelfRecord(
                payload: Data("minimum".utf8),
                timestamp: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: minimumSafeSeconds,
                    nanoseconds: 145_224_192
                )
            )
        )
        let minimum = try #require(optionalMinimum)
        #expect(
            String(decoding: minimum, as: UTF8.self)
                .contains(#""timestamp":-9223372036.854,"level""#)
        )

        for timestamp in [
            try ContainerLogTimestamp(
                secondsSinceUnixEpoch: maximumSafeSeconds,
                nanoseconds: 854_775_808
            ),
            try ContainerLogTimestamp(
                secondsSinceUnixEpoch: minimumSafeSeconds,
                nanoseconds: 145_224_191
            ),
        ] {
            #expect(throws: GELFProviderError.timestampOutOfRange) {
                try encoder.encode(
                    gelfRecord(payload: Data("overflow".utf8), timestamp: timestamp)
                )
            }
        }
    }

    @Test func supportsPinnedGzipZlibAndNoneCompressionDomains() throws {
        let input = Data("the quick brown fox jumps over the lazy dog".utf8)
        for level in -1...9 {
            for type in GELFCompressionType.allCases {
                let datagrams = try GELFDatagramEncoder(
                    compressionType: type,
                    compressionLevel: Int32(level),
                    chunkIDGenerator: FixedGELFChunkIDGenerator(
                        bytes: Data(repeating: 0xa5, count: 8)
                    )
                ).encode(input)
                let payload = try #require(datagrams.gelfOnly)
                switch type {
                case .none:
                    #expect(payload == input)
                case .gzip:
                    #expect(payload.starts(with: [0x1f, 0x8b]))
                    #expect(try gelfInflate(payload, windowBits: 15 + 16) == input)
                case .zlib:
                    #expect(payload.first == 0x78)
                    #expect(try gelfInflate(payload, windowBits: 15) == input)
                }
            }
        }
    }

    @Test func consumesPinnedGoGELFCompressionFixtures() throws {
        let fixture = try gelfOracleFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.provenance.goVersion == DockerSemanticHelperProvenance.goVersion)
        #expect(fixture.provenance.goPlatform == "darwin/arm64")
        #expect(fixture.provenance.mobyTag == DockerSemanticHelperProvenance.mobyTag)
        #expect(fixture.provenance.mobyCommit == DockerSemanticHelperProvenance.mobyCommit)
        #expect(fixture.provenance.mobySourcePath == "daemon/logger/gelf/gelf.go")
        #expect(
            fixture.provenance.mobySourceSHA256
                == "2280ae369a98e887e9775890cb517fe6c61c59f0d09d986290d5e145e28ded2d"
        )
        #expect(
            fixture.provenance.mobyTimestampExpression
                == "float64(msg.Timestamp.UnixNano()/int64(time.Millisecond)) / 1000.0"
        )
        let oracleSource = try Data(
            contentsOf: gelfFixtureURL("gelf-moby-29.2.1-oracle.go.txt")
        )
        #expect(
            SHA256.hash(data: oracleSource).map { String(format: "%02x", $0) }.joined()
                == fixture.provenance.oracleSourceSHA256
        )

        // Deflate byte streams are not producer-golden across Go and system
        // zlib, so parity compares their decoded bytes to the pinned payload.
        let expected = try #require(Data(base64Encoded: fixture.compression.payloadBase64))
        let none = try #require(Data(base64Encoded: fixture.compression.noneBase64))
        let gzip = try #require(Data(base64Encoded: fixture.compression.gzipBase64))
        let zlib = try #require(Data(base64Encoded: fixture.compression.zlibBase64))

        #expect(none == expected)
        #expect(try gelfInflate(gzip, windowBits: 15 + 16) == expected)
        #expect(try gelfInflate(zlib, windowBits: 15) == expected)
    }

    @Test func reproducesGoGELFChunkBoundariesHeadersAndTrailingEmptyChunk() throws {
        let chunkID = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let encoder = GELFDatagramEncoder(
            compressionType: .none,
            compressionLevel: 1,
            chunkIDGenerator: FixedGELFChunkIDGenerator(bytes: chunkID)
        )

        #expect(try encoder.encode(Data(repeating: 1, count: 1_420)).count == 1)
        #expect(try encoder.encode(Data(repeating: 1, count: 1_421)).count == 2)

        let payload = Data(repeating: 0x5a, count: 2 * 1_408)
        let chunks = try encoder.encode(payload)
        #expect(chunks.count == 3)
        #expect(chunks[0].prefix(2) == Data([0x1e, 0x0f]))
        #expect(chunks[0][2..<10] == chunkID)
        #expect(chunks[0][10] == 0)
        #expect(chunks[0][11] == 3)
        #expect(chunks[1][10] == 1)
        #expect(chunks[2][10] == 2)
        #expect(chunks[2].count == GELFDatagramEncoder.chunkHeaderBytes)
        let reassembled = chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk.dropFirst(GELFDatagramEncoder.chunkHeaderBytes))
        }
        #expect(reassembled == payload)

        #expect(try encoder.encode(Data(repeating: 1, count: 180_223)).count == 128)
        #expect(
            throws: GELFProviderError.tooManyChunks(maximum: 128, actual: 129)
        ) {
            try encoder.encode(Data(repeating: 1, count: 180_224))
        }
    }

    @Test func validatesChunkIdentifierOnlyWhenChunking() throws {
        let encoder = GELFDatagramEncoder(
            compressionType: .none,
            compressionLevel: 1,
            chunkIDGenerator: FixedGELFChunkIDGenerator(bytes: Data([1]))
        )
        #expect(try encoder.encode(Data([1])).count == 1)
        #expect(throws: GELFProviderError.chunkIdentifierInvalid) {
            try encoder.encode(Data(repeating: 1, count: 1_421))
        }
    }
}

private struct GELFOracleFixture: Decodable {
    struct Provenance: Decodable {
        let goVersion: String
        let goPlatform: String
        let mobyTag: String
        let mobyCommit: String
        let mobySourcePath: String
        let mobySourceSHA256: String
        let mobyTimestampExpression: String
        let oracleSourceSHA256: String
    }

    struct Compression: Decodable {
        let payloadBase64: String
        let noneBase64: String
        let gzipBase64: String
        let zlibBase64: String
    }

    struct Timestamp: Decodable {
        let seconds: Int64
        let nanoseconds: UInt32
        let jsonNumber: String
    }

    let schemaVersion: UInt32
    let provenance: Provenance
    let compression: Compression
    let timestamps: [Timestamp]
}

private func gelfOracleFixture() throws -> GELFOracleFixture {
    try JSONDecoder().decode(
        GELFOracleFixture.self,
        from: Data(contentsOf: gelfFixtureURL("gelf-moby-29.2.1-oracle.json"))
    )
}

private func gelfFixtureURL(_ name: String) throws -> URL {
    try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        )
    )
}
