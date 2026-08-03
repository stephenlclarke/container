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

struct SplunkSessionTests {
    @Test func verifiesConnectionBatchesWithProtectedHeadersAndCloses() async throws {
        let transport = RecordingSplunkTransport([
            .success(SplunkHTTPResponse(statusCode: 200, body: Data())),
            .success(SplunkHTTPResponse(statusCode: 200, body: Data())),
        ])
        let configuration = try splunkTestConfiguration(
            indexAcknowledgement: true,
            verifyConnection: true
        )
        let session = try await SplunkDriverSession(
            configuration: configuration,
            transportFactory: FixedSplunkTransportFactory(
                transport: transport
            )
        )
        try await session.write(
            splunkRecord(payload: Data("one".utf8), sequence: 1)
        )
        try await session.write(
            splunkRecord(payload: Data("two".utf8), sequence: 2)
        )
        try await session.closeUsingPolicy()

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].request.method == .options)
        #expect(requests[0].request.headers.isEmpty)
        #expect(requests[1].request.method == .post)
        #expect(
            requests[1].request.headers["Authorization"]
                == "Splunk protected-token"
        )
        #expect(
            requests[1].request.headers["X-Splunk-Request-Channel"] != nil
        )
        let body = String(decoding: requests[1].request.body, as: UTF8.self)
        #expect(body.contains(#""line":"one""#))
        #expect(body.contains(#""line":"two""#))
        #expect(await transport.closeCount == 1)
        #expect(await session.currentState() == .closed)
    }

    @Test func failedBatchesAreRetriedAndOldestBatchDropsAtDockerBound() async throws {
        let transport = RecordingSplunkTransport([
            .failure(.connectionFailed),
            .failure(.connectionFailed),
            .success(SplunkHTTPResponse(statusCode: 200, body: Data())),
        ])
        let session = try await SplunkDriverSession(
            configuration: splunkTestConfiguration(),
            transportFactory: FixedSplunkTransportFactory(
                transport: transport
            )
        )
        for value in 1...4 {
            try await session.write(
                splunkRecord(
                    payload: Data("event-\(value)".utf8),
                    sequence: UInt64(value)
                )
            )
        }
        try await session.closeUsingPolicy()

        let requests = await transport.requests
        #expect(requests.count == 3)
        let first = String(decoding: requests[0].request.body, as: UTF8.self)
        let retry = String(decoding: requests[1].request.body, as: UTF8.self)
        let retained = String(decoding: requests[2].request.body, as: UTF8.self)
        #expect(first == retry)
        #expect(first.contains("event-1"))
        #expect(first.contains("event-2"))
        #expect(retained.contains("event-3"))
        #expect(retained.contains("event-4"))
        #expect(!retained.contains("event-1"))
    }

    @Test func closeSwallowsLastChanceDeliveryFailureAndFencesWrites() async throws {
        let transport = RecordingSplunkTransport([
            .failure(.connectionFailed)
        ])
        let session = try await SplunkDriverSession(
            configuration: splunkTestConfiguration(),
            transportFactory: FixedSplunkTransportFactory(
                transport: transport
            )
        )
        try await session.write(
            splunkRecord(payload: Data("event".utf8))
        )
        try await session.fence()
        #expect(await session.currentState() == .writerFenced)
        await #expect(throws: SplunkProviderError.transportClosed) {
            try await session.write(
                splunkRecord(payload: Data("late".utf8))
            )
        }
    }

    @Test func verificationFailureClosesTransportWithoutPublishingSession() async throws {
        let transport = RecordingSplunkTransport([
            .success(
                SplunkHTTPResponse(
                    statusCode: 503,
                    body: Data("must-not-leak".utf8)
                )
            )
        ])
        await #expect(
            throws: SplunkProviderError.verificationFailed(statusCode: 503)
        ) {
            try await SplunkDriverSession(
                configuration: splunkTestConfiguration(
                    verifyConnection: true
                ),
                transportFactory: FixedSplunkTransportFactory(
                    transport: transport
                )
            )
        }
        #expect(await transport.closeCount == 1)
    }
}
