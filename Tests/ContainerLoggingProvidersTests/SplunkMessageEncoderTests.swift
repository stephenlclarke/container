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

struct SplunkMessageEncoderTests {
    @Test func inlineShapeFieldOrderTimestampAndMetadataMatchMoby() throws {
        let encoder = SplunkMessageEncoder(
            configuration: try splunkTestConfiguration(
                metadata: ["z": "9", "a": "1"]
            )
        )
        let encoded = try #require(
            encoder.encode(
                try splunkRecord(
                    payload: Data("hello".utf8),
                    stream: .stderr
                )
            )
        )
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"event":{"line":"hello","source":"stderr","tag":"container-id","attrs":{"a":"1","z":"9"}},"time":"1.234568","host":"test-host","source":"source","sourcetype":"source-type","index":"index"}"#
        )
    }

    @Test func jsonPreservesValidFragmentsAndFallsBackToAString() throws {
        let encoder = SplunkMessageEncoder(
            configuration: try splunkTestConfiguration(format: .json)
        )
        let object = try #require(
            encoder.encode(
                try splunkRecord(payload: Data(#"{"b":2}"#.utf8))
            )
        )
        #expect(
            String(decoding: object, as: UTF8.self)
                .contains(#""line":{"b":2}"#)
        )
        let text = try #require(
            encoder.encode(
                try splunkRecord(payload: Data("not-json".utf8))
            )
        )
        #expect(
            String(decoding: text, as: UTF8.self)
                .contains(#""line":"not-json""#)
        )
    }

    @Test func rawPrefixesTagAndAttributesAndDropsWhitespaceOnlyRecords() throws {
        let encoder = SplunkMessageEncoder(
            configuration: try splunkTestConfiguration(
                format: .raw,
                metadata: ["b": "2", "a": "1"]
            )
        )
        let encoded = try #require(
            encoder.encode(try splunkRecord(payload: Data("line".utf8)))
        )
        #expect(
            String(decoding: encoded, as: UTF8.self)
                .contains(#""event":"container-id a=1 b=2 line""#)
        )
        #expect(
            try encoder.encode(
                splunkRecord(payload: Data(" \n\t".utf8))
            ) == nil
        )
    }

    @Test func concatenatesBatchObjectsAndUsesConfiguredGzipLevel() throws {
        let configuration = try splunkTestConfiguration(
            gzipEnabled: true,
            gzipLevel: 1
        )
        let encoder = SplunkMessageEncoder(configuration: configuration)
        let first = try #require(
            encoder.encode(try splunkRecord(payload: Data("one".utf8)))
        )
        let second = try #require(
            encoder.encode(try splunkRecord(payload: Data("two".utf8)))
        )
        let compressed = try encoder.encodeBatch([first, second])
        let inflated = try gelfInflate(compressed, windowBits: 15 + 16)
        #expect(inflated == first + second)
    }

    @Test func rejectsRecordsBeyondTheAuthoritySplitterBound() throws {
        let encoder = SplunkMessageEncoder(
            configuration: try splunkTestConfiguration()
        )
        let payload = Data(
            repeating: 0x61,
            count: SplunkMessageEncoder.maximumRecordPayloadBytes + 1
        )
        #expect(
            throws: SplunkProviderError.recordPayloadTooLarge(
                maximumBytes: SplunkMessageEncoder.maximumRecordPayloadBytes
            )
        ) {
            try encoder.encode(splunkRecord(payload: payload))
        }
    }
}
