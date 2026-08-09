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

func splunkTestConfiguration(
    format: SplunkEventFormat = .inline,
    gzipEnabled: Bool = false,
    gzipLevel: Int32 = -1,
    indexAcknowledgement: Bool = false,
    verifyConnection: Bool = false,
    tag: String = "container-id",
    metadata: [String: String] = [:],
    policy: SplunkConnectionPolicy? = nil
) throws -> SplunkDriverConfiguration {
    try SplunkDriverConfiguration(
        endpoint: SplunkEndpoint("https://collector.example:8088"),
        token: "protected-token",
        source: "source",
        sourceType: "source-type",
        index: "index",
        format: format,
        gzipEnabled: gzipEnabled,
        gzipLevel: gzipLevel,
        indexAcknowledgement: indexAcknowledgement,
        verifyConnection: verifyConnection,
        tag: tag,
        hostname: "test-host",
        metadata: metadata,
        tls: SplunkTLSConfiguration(
            caCertificatePath: nil,
            serverName: nil,
            insecureSkipVerify: false
        ),
        policy: try policy
            ?? SplunkConnectionPolicy(
                postFrequency: .seconds(60),
                postBatchSize: 2,
                bufferMaximum: 4,
                streamCapacity: 4,
                requestTimeout: .seconds(1),
                closeTimeout: .seconds(1),
                maximumResponseBytes: 1_024
            )
    )
}

func splunkRecord(
    payload: Data,
    stream: ContainerLogStream = .stdout,
    seconds: Int64 = 1,
    nanoseconds: UInt32 = 234_567_890,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    try ContainerLogRecordV2(
        stream: stream,
        observation: ContainerLogObservation(
            wallClock: ContainerLogTimestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            ),
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: nil,
        sequence: sequence,
        processGeneration: 1
    )
}

actor RecordingSplunkTransport: SplunkHTTPTransport {
    struct RecordedRequest: Sendable {
        let request: SplunkHTTPRequest
        let timeout: Duration
    }

    private var results: [Result<SplunkHTTPResponse, SplunkProviderError>]
    private(set) var requests = [RecordedRequest]()
    private(set) var closeCount = 0

    init(
        _ results: [Result<SplunkHTTPResponse, SplunkProviderError>] = []
    ) {
        self.results = results
    }

    func execute(
        _ request: SplunkHTTPRequest,
        timeout: Duration
    ) async throws -> SplunkHTTPResponse {
        requests.append(RecordedRequest(request: request, timeout: timeout))
        guard !results.isEmpty else {
            return SplunkHTTPResponse(statusCode: 200, body: Data())
        }
        return try results.removeFirst().get()
    }

    func close() async {
        closeCount += 1
    }
}

struct FixedSplunkTransportFactory: SplunkHTTPTransportFactory {
    let transport: RecordingSplunkTransport

    func makeTransport(
        configuration: SplunkDriverConfiguration
    ) throws -> any SplunkHTTPTransport {
        transport
    }
}

actor FixedSplunkConfigurationResolver: SplunkConfigurationResolving {
    let binding: SplunkConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: SplunkConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> SplunkConfigurationBinding {
        callCount += 1
        return binding
    }
}

struct FixedSplunkTokenGenerator: SplunkEffectTokenGenerating {
    let bytes: Data

    func makeEffectToken() throws -> Data {
        bytes
    }
}

func splunkStartRequest(
    operationGeneration: UInt64 = 1,
    idempotencyKey: String = "start-key",
    semanticRequestDigest: String = "sha256:request",
    sessionID: String = "splunk-session"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: operationGeneration,
        idempotencyKey: idempotencyKey,
        semanticRequestDigest: semanticRequestDigest,
        sessionID: sessionID,
        containerID: "container-id",
        leaseGeneration: 3,
        candidateProcessGeneration: 4,
        providerID: SplunkLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: nil
    )
}

func splunkBinding(
    for request: LogDriverStartRequestV1,
    configuration: SplunkDriverConfiguration? = nil
) throws -> SplunkConfigurationBinding {
    SplunkConfigurationBinding(
        semanticRequestDigest: request.semanticRequestDigest,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        configuration: try configuration ?? splunkTestConfiguration()
    )
}

func splunkSessionCall(
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
