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

struct AWSLogsSessionTests {
    @Test func createsMissingGroupThenStreamLikeMoby() async throws {
        let client = RecordingAWSLogsClient(
            createGroupResults: [.success(())],
            createStreamResults: [
                .failure(.resourceNotFound),
                .success(()),
            ]
        )
        let session = try await makeSession(
            client: client,
            configuration: awsLogsTestConfiguration(createGroup: true)
        )
        #expect(
            await client.calls == [
                .createStream(group: "group", stream: "stream"),
                .createGroup("group"),
                .createStream(group: "group", stream: "stream"),
            ]
        )
        try await session.closeUsingPolicy()
    }

    @Test func sortsStableBatchesAndAdvancesSequenceToken() async throws {
        let client = RecordingAWSLogsClient(
            putResults: [
                .success(AWSLogsPutResult(nextSequenceToken: "next"))
            ]
        )
        let session = try await makeSession(client: client)
        try await session.write(
            awsLogsRecord(Data("later".utf8), milliseconds: 2_000)
        )
        try await session.write(
            awsLogsRecord(Data("first".utf8), milliseconds: 1_000, sequence: 2)
        )
        try await session.write(
            awsLogsRecord(Data("second".utf8), milliseconds: 1_000, sequence: 3)
        )
        try await session.flush(
            deadline: ContinuousClock().now.advanced(by: .seconds(2))
        )
        let put = try #require(
            await client.calls.first {
                if case .put = $0 { return true }
                return false
            }
        )
        guard case .put(_, _, let events, let token) = put else {
            Issue.record("expected PutLogEvents")
            return
        }
        #expect(events.map(\.message) == ["first", "second", "later"])
        #expect(token == nil)
        #expect(await session.currentSequenceToken == "next")
        try await session.closeUsingPolicy()
    }

    @Test func retriesInvalidSequenceOnceAndAcceptsExpectedToken() async throws {
        let client = RecordingAWSLogsClient(
            putResults: [
                .failure(.invalidSequenceToken(expectedSequenceToken: "expected")),
                .success(AWSLogsPutResult(nextSequenceToken: "next")),
            ]
        )
        let session = try await makeSession(client: client)
        try await session.write(awsLogsRecord(Data("line".utf8)))
        try await session.flush(
            deadline: ContinuousClock().now.advanced(by: .seconds(2))
        )
        let puts = await client.calls.compactMap { call -> String?? in
            if case .put(_, _, _, let token) = call { return .some(token) }
            return nil
        }
        #expect(puts.count == 2)
        #expect(puts[0] == nil)
        #expect(puts[1] == "expected")
        #expect(await session.currentSequenceToken == "next")
        try await session.closeUsingPolicy()
    }

    @Test func assemblesMultilineAndStartsNewMatchingEvent() async throws {
        let client = RecordingAWSLogsClient()
        let session = try await makeSession(
            client: client,
            configuration: awsLogsTestConfiguration(
                multilinePattern: "^START"
            ),
            matcher: PrefixAWSLogsMatcher(prefix: Data("START".utf8))
        )
        try await session.write(awsLogsRecord(Data("one".utf8)))
        try await session.write(awsLogsRecord(Data("two".utf8), sequence: 2))
        try await session.write(awsLogsRecord(Data("START three".utf8), sequence: 3))
        try await session.flush(
            deadline: ContinuousClock().now.advanced(by: .seconds(2))
        )
        let messages = await client.calls.flatMap { call -> [String] in
            if case .put(_, _, let events, _) = call {
                return events.map(\.message)
            }
            return []
        }
        #expect(messages == ["one\ntwo\n", "START three\n"])
        try await session.closeUsingPolicy()
    }

    @Test func normalizesInvalidUTF8SplitsAtEventLimitAndCloses() async throws {
        #expect(
            AWSLogsDriverSession.effectiveLength(Data([0xff, 0xff])) == 6
        )
        let client = RecordingAWSLogsClient()
        let session = try await makeSession(client: client)
        let bytes = Data(
            repeating: UInt8(ascii: "x"),
            count: AWSLogsDriverSession.maximumBytesPerEvent + 1
        )
        try await session.write(awsLogsRecord(bytes))
        try await session.closeUsingPolicy()
        let events = await client.calls.flatMap { call -> [AWSLogsInputEvent] in
            if case .put(_, _, let events, _) = call { return events }
            return []
        }
        #expect(
            events.map { $0.message.utf8.count } == [
                AWSLogsDriverSession.maximumBytesPerEvent,
                1,
            ])
        #expect(await session.currentState() == .closed)
    }

    private func makeSession(
        client: RecordingAWSLogsClient,
        configuration: AWSLogsDriverConfiguration? = nil,
        matcher: any AWSLogsMultilineMatching =
            NeverMatchingAWSLogsMatcher()
    ) async throws -> AWSLogsDriverSession {
        try await AWSLogsDriverSession(
            configuration: configuration ?? awsLogsTestConfiguration(),
            clientFactory: FixedAWSLogsClientFactory(client: client),
            matcher: matcher,
            clock: SuspendedAWSLogsClock()
        )
    }
}
