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

@testable import ContainerResource

struct ContainerLogRecordV2Tests {
    private let monotonicInstant = ContinuousClock().now

    @Test func completeEmptyAndCRLFLinesRemoveOnlyLineFeed() throws {
        let observation = try makeObservation(seconds: 10)

        for stream in ContainerLogStream.allCases {
            let fragments = try capture(
                stream: stream,
                chunks: [Data("one\n\nthree\r\n".utf8)],
                observation: observation
            )

            #expect(fragments.map(\.payload) == [Data("one".utf8), Data(), Data("three\r".utf8)])
            #expect(fragments.allSatisfy { $0.stream == stream })
            #expect(fragments.allSatisfy { $0.observation == observation })
            #expect(fragments.allSatisfy { $0.partial == nil })
        }
    }

    @Test func timestampSamplingMatchesMobyEmissionTiming() throws {
        let early = try makeObservation(seconds: 20)
        let partialStart = try makeObservation(seconds: 21, nanoseconds: 123_456_789)
        let later = try makeObservation(seconds: 22)
        var splitter = try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: 4)
        var fragments: [ContainerLogRecordFragmentV1] = []
        var earlyCalls = 0
        var partialCalls = 0
        var laterCalls = 0

        splitter.append(
            Data("hel".utf8),
            observationProvider: {
                earlyCalls += 1
                return early
            },
            emit: { fragments.append($0) }
        )
        #expect(earlyCalls == 0)

        splitter.append(
            Data("l".utf8),
            observationProvider: {
                partialCalls += 1
                return partialStart
            },
            emit: { fragments.append($0) }
        )
        splitter.append(
            Data("o\n".utf8),
            observationProvider: {
                laterCalls += 1
                return later
            },
            emit: { fragments.append($0) }
        )

        #expect(partialCalls == 1)
        #expect(laterCalls == 0)
        #expect(fragments.map(\.payload) == [Data("hell".utf8), Data("o".utf8)])
        #expect(fragments.allSatisfy { $0.observation == partialStart })

        var ordinary: [ContainerLogRecordFragmentV1] = []
        var observations = [early, later]
        splitter.append(
            Data("a\nb\n".utf8),
            observationProvider: { observations.removeFirst() },
            emit: { ordinary.append($0) }
        )
        #expect(ordinary.map(\.observation) == [early, later])

        var eofSplitter = try ContainerLogRecordSplitterV1(stream: .stderr, maximumRecordBytes: 4)
        var eofFragments: [ContainerLogRecordFragmentV1] = []
        var eofAppendCalls = 0
        var eofFinishCalls = 0
        eofSplitter.append(
            Data("eof".utf8),
            observationProvider: {
                eofAppendCalls += 1
                return early
            },
            emit: { eofFragments.append($0) }
        )
        eofSplitter.finish(
            observationProvider: {
                eofFinishCalls += 1
                return later
            },
            emit: { eofFragments.append($0) }
        )
        #expect(eofAppendCalls == 0)
        #expect(eofFinishCalls == 1)
        #expect(eofFragments.first?.observation == later)
    }

    @Test func lineFeedBoundariesMatchDockerForBothStreams() throws {
        let observation = try makeObservation(seconds: 30)
        let cases: [(size: Int, payloadSizes: [Int], lasts: [Bool]?)] = [
            (16_383, [16_383], nil),
            (16_384, [16_384, 0], [false, true]),
            (16_385, [16_384, 1], [false, true]),
            (32_768, [16_384, 16_384, 0], [false, false, true]),
        ]

        for stream in ContainerLogStream.allCases {
            for testCase in cases {
                var input = Data(repeating: 0x78, count: testCase.size)
                input.append(UInt8(ascii: "\n"))
                let fragments = try capture(
                    stream: stream,
                    chunks: [input],
                    observation: observation
                )

                #expect(fragments.map(\.payload.count) == testCase.payloadSizes)
                #expect(fragments.allSatisfy { $0.stream == stream })
                if let lasts = testCase.lasts {
                    try expectPartialChain(
                        fragments,
                        ordinals: Array(1...UInt64(lasts.count)),
                        lasts: lasts
                    )
                } else {
                    #expect(fragments.count == 1)
                    #expect(fragments.first?.partial == nil)
                }
            }
        }
    }

    @Test func eofBoundariesMatchDockerForBothStreams() throws {
        let observation = try makeObservation(seconds: 40)
        let cases: [(size: Int, payloadSizes: [Int])] = [
            (3, [3]),
            (16_383, [16_383]),
            (16_384, [16_384]),
            (16_385, [16_384, 1]),
            (32_768, [16_384, 16_384]),
        ]

        for stream in ContainerLogStream.allCases {
            for testCase in cases {
                let fragments = try capture(
                    stream: stream,
                    chunks: [Data(repeating: 0x79, count: testCase.size)],
                    observation: observation
                )

                #expect(fragments.map(\.payload.count) == testCase.payloadSizes)
                try expectPartialChain(
                    fragments,
                    ordinals: Array(1...UInt64(testCase.payloadSizes.count)),
                    lasts: Array(repeating: false, count: testCase.payloadSizes.count)
                )
            }
        }
    }

    @Test func segmentationDoesNotChangeFraming() throws {
        let observation = try makeObservation(seconds: 50)
        let input = Data([
            0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x0a,
            0x61, 0x0a,
            0x62, 0x63,
        ])
        let segmentations = [
            [input],
            input.map { Data([$0]) },
            chunks(of: input, sizes: [2, 1, 5, 3]),
        ]

        for stream in ContainerLogStream.allCases {
            var shapes: [[FragmentShape]] = []
            for chunks in segmentations {
                let fragments = try capture(
                    stream: stream,
                    maximumRecordBytes: 4,
                    chunks: chunks,
                    observation: observation
                )
                #expect(
                    fragments.compactMap(\.partial).allSatisfy { partial in
                        ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(partial.id)
                    })
                #expect(Set(fragments.compactMap(\.partial?.id)).count == 2)
                shapes.append(fragments.map(FragmentShape.init))
            }
            #expect(shapes.dropFirst().allSatisfy { $0 == shapes.first })
        }
    }

    @Test func binaryPayloadsRemainByteExact() throws {
        let observation = try makeObservation(seconds: 60)
        let bytes = Data([0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a])

        for stream in ContainerLogStream.allCases {
            let fragments = try capture(
                stream: stream,
                maximumRecordBytes: 4,
                chunks: [bytes],
                observation: observation
            )
            #expect(
                fragments.map(\.payload)
                    == [Data(bytes[0..<4]), Data(bytes[4..<8]), Data([0x07])]
            )
            try expectPartialChain(
                fragments,
                ordinals: [1, 2, 3],
                lasts: [false, false, true]
            )
        }
    }

    @Test func partialIdentifiersUseMobyFormatAndRemainStreamLocal() throws {
        let observation = try makeObservation(seconds: 70)
        var identifiers: [String] = []

        for stream in ContainerLogStream.allCases {
            let fragments = try capture(
                stream: stream,
                maximumRecordBytes: 4,
                chunks: [Data("abcd\n".utf8)],
                observation: observation
            )
            let partials = try fragments.map { try #require($0.partial) }
            let id = try #require(partials.first?.id)
            #expect(partials.allSatisfy { $0.id == id })
            #expect(ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(id))
            identifiers.append(id)
        }

        #expect(Set(identifiers).count == ContainerLogStream.allCases.count)
        #expect(
            !ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(
                "123456789012" + String(repeating: "a", count: 52)
            )
        )
        #expect(
            ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(
                "12345678901a" + String(repeating: "b", count: 52)
            )
        )
        #expect(
            !ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(
                "12345678901A" + String(repeating: "b", count: 52)
            )
        )
    }

    @Test func resetAndFinishAreIdempotent() throws {
        let observation = try makeObservation(seconds: 80)
        var splitter = try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: 4)
        var fragments: [ContainerLogRecordFragmentV1] = []

        splitter.append(
            Data("abc".utf8),
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        splitter.reset()
        splitter.reset()
        splitter.finish(
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        splitter.finish(
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        #expect(fragments.isEmpty)

        splitter.append(
            Data("x\n".utf8),
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        splitter.finish(
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        splitter.finish(
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        #expect(fragments.map(\.payload) == [Data("x".utf8)])
        #expect(fragments.first?.partial == nil)
    }

    @Test func callbackFailurePropagatesAndFencesPartialState() throws {
        let observation = try makeObservation(seconds: 90)
        var splitter = try ContainerLogRecordSplitterV1(stream: .stderr, maximumRecordBytes: 4)
        var attempts = 0

        #expect(throws: SinkFailure.rejected) {
            try splitter.append(
                Data("abcd".utf8),
                observationProvider: { observation },
                emit: { _ in
                    attempts += 1
                    throw SinkFailure.rejected
                }
            )
        }
        #expect(attempts == 1)

        var recovered: [ContainerLogRecordFragmentV1] = []
        splitter.append(
            Data("ok\n".utf8),
            observationProvider: { observation },
            emit: { recovered.append($0) }
        )
        #expect(recovered.map(\.payload) == [Data("ok".utf8)])
        #expect(recovered.first?.partial == nil)
    }

    @Test func callbackDeliveryKeepsEachFragmentWithinTheHardBound() throws {
        let observation = try makeObservation(seconds: 100)
        let maximum = ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
        var splitter = ContainerLogRecordSplitterV1(stream: .stdout)
        var emitted = 0

        splitter.append(
            Data(repeating: 0x7a, count: maximum * 64),
            observationProvider: { observation },
            emit: { fragment in
                emitted += 1
                #expect(fragment.payload.count <= maximum)
            }
        )
        splitter.finish(
            observationProvider: { observation },
            emit: { _ in
                Issue.record("exact-boundary EOF must not synthesize a fragment")
            }
        )
        #expect(emitted == 64)
    }

    @Test func strictTimestampAndAuthorityConstructionPreserveFractionalTime() throws {
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_700_000_000,
            nanoseconds: 123_456_789
        )
        let observation = ContainerLogObservation(
            wallClock: timestamp,
            monotonicInstant: monotonicInstant
        )
        let fragment = try #require(
            try capture(
                stream: .stderr,
                chunks: [Data("bytes\n".utf8)],
                observation: observation
            ).first
        )
        let record = try ContainerLogRecordV2(
            fragment: fragment,
            sequence: 42,
            attributes: ["label": "value"],
            processGeneration: 7
        )

        #expect(record.stream == .stderr)
        #expect(record.observation.wallClock.secondsSinceUnixEpoch == 1_700_000_000)
        #expect(record.observation.wallClock.nanoseconds == 123_456_789)
        #expect(record.payload == Data("bytes".utf8))
        #expect(record.sequence == 42)
        #expect(record.attributes == ["label": "value"])
        #expect(record.processGeneration == 7)
        #expect(throws: ContainerLogTimestampError.nanosecondsOutOfRange(1_000_000_000)) {
            try ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 1_000_000_000)
        }
    }

    @Test func authorityAttributeBudgetsAreEnforced() throws {
        let fragment = try #require(
            try capture(
                stream: .stdout,
                chunks: [Data("x\n".utf8)],
                observation: makeObservation(seconds: 110)
            ).first
        )
        let exactValue = String(
            repeating: "v",
            count: ContainerLogRecordV2.maximumAttributeUTF8Bytes - 1
        )
        _ = try ContainerLogRecordV2(
            fragment: fragment,
            sequence: 1,
            attributes: ["k": exactValue],
            processGeneration: 1
        )

        #expect(throws: ContainerLogRecordV2ConstructionError.attributesTooLarge) {
            try ContainerLogRecordV2(
                fragment: fragment,
                sequence: 1,
                attributes: ["kk": exactValue],
                processGeneration: 1
            )
        }
        let tooMany = Dictionary(
            uniqueKeysWithValues: (0...ContainerLogRecordV2.maximumAttributeCount).map {
                (String($0), "")
            }
        )
        #expect(throws: ContainerLogRecordV2ConstructionError.tooManyAttributes) {
            try ContainerLogRecordV2(
                fragment: fragment,
                sequence: 1,
                attributes: tooMany,
                processGeneration: 1
            )
        }
    }

    @Test func boundedCodecsCanReconstructValidatedRecords() throws {
        let partialID = try #require(
            try capture(
                stream: .stdout,
                maximumRecordBytes: 1,
                chunks: [Data("x\n".utf8)],
                observation: makeObservation(seconds: 120)
            ).first?.partial?.id
        )
        let partial = try ContainerLogPartialMetadataV1(
            validatingID: partialID,
            ordinal: 1,
            last: true
        )
        let observation = try makeObservation(seconds: 120, nanoseconds: 7)
        let record = try ContainerLogRecordV2(
            stream: .stdout,
            observation: observation,
            payload: Data("x".utf8),
            partial: partial,
            sequence: 9,
            attributes: ["label": "value"],
            processGeneration: 3
        )

        #expect(record.partial == partial)
        #expect(record.observation == observation)
        #expect(record.sequence == 9)
        #expect(throws: ContainerLogPartialMetadataError.invalidID) {
            try ContainerLogPartialMetadataV1(
                validatingID: "not-a-partial-id",
                ordinal: 1,
                last: false
            )
        }
        #expect(throws: ContainerLogPartialMetadataError.invalidOrdinal) {
            try ContainerLogPartialMetadataV1(
                validatingID: partialID,
                ordinal: 0,
                last: false
            )
        }
    }

    @Test func splitterRejectsSizesOutsideItsHardBound() throws {
        #expect(throws: ContainerLogRecordSplitterError.invalidMaximumRecordBytes(-1)) {
            try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: -1)
        }
        #expect(throws: ContainerLogRecordSplitterError.invalidMaximumRecordBytes(0)) {
            try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: 0)
        }
        let overMaximum = ContainerLogRecordSplitterV1.maximumSupportedRecordBytes + 1
        #expect(throws: ContainerLogRecordSplitterError.invalidMaximumRecordBytes(overMaximum)) {
            try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: overMaximum)
        }

        #expect(try ContainerLogRecordSplitterV1(stream: .stdout, maximumRecordBytes: 1).maximumRecordBytes == 1)
        #expect(
            try ContainerLogRecordSplitterV1(
                stream: .stdout,
                maximumRecordBytes: ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
            ).maximumRecordBytes == ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
        )
    }

    private func capture(
        stream: ContainerLogStream,
        maximumRecordBytes: Int = ContainerLogRecordSplitterV1.defaultMaximumRecordBytes,
        chunks: [Data],
        observation: ContainerLogObservation
    ) throws -> [ContainerLogRecordFragmentV1] {
        var splitter = try ContainerLogRecordSplitterV1(
            stream: stream,
            maximumRecordBytes: maximumRecordBytes
        )
        var fragments: [ContainerLogRecordFragmentV1] = []
        for chunk in chunks {
            splitter.append(
                chunk,
                observationProvider: { observation },
                emit: { fragments.append($0) }
            )
        }
        splitter.finish(
            observationProvider: { observation },
            emit: { fragments.append($0) }
        )
        splitter.finish(
            observationProvider: { observation },
            emit: { _ in Issue.record("finish must be idempotent") }
        )
        return fragments
    }

    private func makeObservation(
        seconds: Int64,
        nanoseconds: UInt32 = 0
    ) throws -> ContainerLogObservation {
        ContainerLogObservation(
            wallClock: try ContainerLogTimestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            ),
            monotonicInstant: monotonicInstant
        )
    }

    private func expectPartialChain(
        _ fragments: [ContainerLogRecordFragmentV1],
        ordinals: [UInt64],
        lasts: [Bool]
    ) throws {
        let partials = try fragments.map { try #require($0.partial) }
        let id = try #require(partials.first?.id)
        #expect(partials.map(\.ordinal) == ordinals)
        #expect(partials.map(\.last) == lasts)
        #expect(partials.allSatisfy { $0.id == id })
        #expect(ContainerLogRecordSplitterV1.isMobyCompatiblePartialID(id))
    }

    private func chunks(of data: Data, sizes: [Int]) -> [Data] {
        var chunks: [Data] = []
        var cursor = data.startIndex
        var sizeIndex = 0
        while cursor < data.endIndex {
            let size = sizes[sizeIndex % sizes.count]
            let end = data.index(cursor, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(Data(data[cursor..<end]))
            cursor = end
            sizeIndex += 1
        }
        return chunks
    }
}

private enum SinkFailure: Error {
    case rejected
}

private struct FragmentShape: Equatable {
    let stream: ContainerLogStream
    let observation: ContainerLogObservation
    let payload: Data
    let partialOrdinal: UInt64?
    let partialLast: Bool?

    init(_ fragment: ContainerLogRecordFragmentV1) {
        stream = fragment.stream
        observation = fragment.observation
        payload = fragment.payload
        partialOrdinal = fragment.partial?.ordinal
        partialLast = fragment.partial?.last
    }
}
