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

@testable import ContainerLoggingProviders

func awsLogsTestConfiguration(
    createGroup: Bool = false,
    createStream: Bool = true,
    multilinePattern: String? = nil,
    nonBlocking: Bool = false,
    forceFlushInterval: Duration = .seconds(60),
    maximumBufferedEvents: Int = 4_096
) throws -> AWSLogsDriverConfiguration {
    try AWSLogsDriverConfiguration(
        region: "eu-west-2",
        endpoint: "http://127.0.0.1:4566",
        logGroup: "group",
        logStream: "stream",
        createGroup: createGroup,
        createStream: createStream,
        multilinePattern: multilinePattern,
        credentialsEndpointURI: nil,
        logFormat: nil,
        nonBlocking: nonBlocking,
        policy: AWSLogsConnectionPolicy(
            forceFlushInterval: forceFlushInterval,
            maximumBufferedEvents: maximumBufferedEvents,
            maximumCreationBackoff: .seconds(32),
            closeTimeout: .seconds(2)
        )
    )
}

func awsLogsRecord(
    _ bytes: Data,
    milliseconds: Int64 = 1_000,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    try ContainerLogRecordV2(
        stream: .stdout,
        observation: ContainerLogObservation(
            wallClock: ContainerLogTimestamp(
                secondsSinceUnixEpoch: milliseconds / 1_000,
                nanoseconds: UInt32(milliseconds % 1_000) * 1_000_000
            ),
            monotonicInstant: ContinuousClock().now
        ),
        payload: bytes,
        partial: nil,
        sequence: sequence,
        processGeneration: 1
    )
}

actor RecordingAWSLogsClient: AWSLogsClient {
    enum Call: Equatable, Sendable {
        case createGroup(String)
        case createStream(group: String, stream: String)
        case put(
            group: String,
            stream: String,
            events: [AWSLogsInputEvent],
            token: String?
        )
        case close
    }

    private var createGroupResults: [Result<Void, AWSLogsClientError>]
    private var createStreamResults: [Result<Void, AWSLogsClientError>]
    private var putResults: [Result<AWSLogsPutResult, AWSLogsClientError>]
    private(set) var calls = [Call]()

    init(
        createGroupResults: [Result<Void, AWSLogsClientError>] = [],
        createStreamResults: [Result<Void, AWSLogsClientError>] = [],
        putResults: [Result<AWSLogsPutResult, AWSLogsClientError>] = []
    ) {
        self.createGroupResults = createGroupResults
        self.createStreamResults = createStreamResults
        self.putResults = putResults
    }

    func createLogGroup(name: String) throws {
        calls.append(.createGroup(name))
        if !createGroupResults.isEmpty {
            try createGroupResults.removeFirst().get()
        }
    }

    func createLogStream(group: String, stream: String) throws {
        calls.append(.createStream(group: group, stream: stream))
        if !createStreamResults.isEmpty {
            try createStreamResults.removeFirst().get()
        }
    }

    func putLogEvents(
        group: String,
        stream: String,
        events: [AWSLogsInputEvent],
        sequenceToken: String?
    ) throws -> AWSLogsPutResult {
        calls.append(
            .put(
                group: group,
                stream: stream,
                events: events,
                token: sequenceToken
            )
        )
        guard !putResults.isEmpty else {
            return AWSLogsPutResult(nextSequenceToken: nil)
        }
        return try putResults.removeFirst().get()
    }

    func close() {
        calls.append(.close)
    }
}

struct FixedAWSLogsClientFactory: AWSLogsClientFactory {
    let client: RecordingAWSLogsClient

    func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient {
        client
    }
}

struct NeverMatchingAWSLogsMatcher: AWSLogsMultilineMatching {
    func matches(pattern: Data, candidate: Data) throws -> Bool { false }
}

struct PrefixAWSLogsMatcher: AWSLogsMultilineMatching {
    let prefix: Data

    func matches(pattern: Data, candidate: Data) throws -> Bool {
        candidate.starts(with: prefix)
    }
}

struct SuspendedAWSLogsClock: AWSLogsClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

actor FixedAWSLogsConfigurationResolver: AWSLogsConfigurationResolving {
    let binding: AWSLogsConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: AWSLogsConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> AWSLogsConfigurationBinding {
        callCount += 1
        return binding
    }
}

struct FixedAWSLogsTokenGenerator: AWSLogsEffectTokenGenerating {
    let bytes: Data

    func makeEffectToken() throws -> Data { bytes }
}

func awsLogsStartRequest(
    operationGeneration: UInt64 = 1,
    idempotencyKey: String = "start-key",
    semanticRequestDigest: String = "sha256:request",
    sessionID: String = "awslogs-session"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: operationGeneration,
        idempotencyKey: idempotencyKey,
        semanticRequestDigest: semanticRequestDigest,
        sessionID: sessionID,
        containerID: "container-id",
        leaseGeneration: 3,
        candidateProcessGeneration: 4,
        providerID: AWSLogsLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: nil
    )
}

func awsLogsBinding(
    for request: LogDriverStartRequestV1,
    configuration: AWSLogsDriverConfiguration? = nil
) throws -> AWSLogsConfigurationBinding {
    AWSLogsConfigurationBinding(
        semanticRequestDigest: request.semanticRequestDigest,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        configuration: try configuration ?? awsLogsTestConfiguration(),
        multilineMatcher: NeverMatchingAWSLogsMatcher()
    )
}

func awsLogsSessionCall(
    request: LogDriverStartRequestV1,
    token: LogDriverOpaqueEffectTokenV1
) throws -> LogDriverSessionCallV1 {
    try LogDriverSessionCallV1(
        sessionID: request.sessionID,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        fence: LogDriverSessionFenceV1(
            activeProcessGeneration: request.candidateProcessGeneration,
            sandboxGeneration: request.candidateSandboxGeneration
        ),
        effectTokenMaterial: token
    )
}
