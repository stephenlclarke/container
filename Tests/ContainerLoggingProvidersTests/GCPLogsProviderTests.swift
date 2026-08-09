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
import DockerSemanticHelper
import Foundation
import Testing

@testable import ContainerLoggingProviders

private final class RecordingGCPLoggingService: DockerGCPLoggingServicing,
    @unchecked Sendable
{
    enum Call: Equatable {
        case start(
            sessionID: String,
            configuration: [DockerSemanticBytePair],
            info: DockerLogTemplateInfo
        )
        case log(
            sessionID: String,
            seconds: Int64,
            nanoseconds: UInt32,
            line: Data
        )
        case flush(String)
        case close(String)
    }

    private let lock = NSLock()
    private var recorded = [Call]()

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func startGCPLoggingSession(
        sessionID: String,
        configuration: [DockerSemanticBytePair],
        info: DockerLogTemplateInfo,
        timeout: Duration
    ) throws {
        lock.withLock {
            recorded.append(
                .start(
                    sessionID: sessionID,
                    configuration: configuration,
                    info: info
                )
            )
        }
    }

    func logGCPRecord(
        sessionID: String,
        timestampSeconds: Int64,
        timestampNanoseconds: UInt32,
        line: Data,
        timeout: Duration
    ) throws {
        lock.withLock {
            recorded.append(
                .log(
                    sessionID: sessionID,
                    seconds: timestampSeconds,
                    nanoseconds: timestampNanoseconds,
                    line: line
                )
            )
        }
    }

    func flushGCPLoggingSession(
        sessionID: String,
        timeout: Duration
    ) throws {
        lock.withLock { recorded.append(.flush(sessionID)) }
    }

    func closeGCPLoggingSession(
        sessionID: String,
        timeout: Duration
    ) throws {
        lock.withLock { recorded.append(.close(sessionID)) }
    }
}

private actor FixedGCPLogsConfigurationResolver:
    GCPLogsConfigurationResolving
{
    let binding: GCPLogsConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: GCPLogsConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> GCPLogsConfigurationBinding {
        callCount += 1
        return binding
    }
}

private struct FixedGCPLogsTokenGenerator:
    GCPLogsEffectTokenGenerating
{
    let bytes: Data

    func makeEffectToken() throws -> Data { bytes }
}

struct GCPLogsProviderTests {
    @Test func configurationAndDescriptorMatchPinnedMobySurface() throws {
        let options = [
            "gcp-project": "project",
            "gcp-log-cmd": "anything-is-valid",
            "labels-regex": "^com\\.example\\.",
            "mode": "non-blocking",
        ]
        let configuration = try GCPLogsDriverConfiguration.resolve(
            options: options,
            info: containerInfo()
        )
        #expect(configuration.options == options)

        let descriptor = GCPLogsLogDriverContract.descriptor(
            providerGeneration: 7
        )
        #expect(descriptor.providerGeneration == 7)
        #expect(descriptor.driver == "gcplogs")
        #expect(descriptor.capabilities.supportsDualCache)
        #expect(!descriptor.capabilities.nativeRead)
        #expect(
            Set(descriptor.options.map(\.name))
                == GCPLogsDriverConfiguration.knownOptionNames
        )
    }

    @Test func configurationRejectsUnknownOptionWithoutEffects() throws {
        #expect(throws: GCPLogsProviderError.unknownOption("future")) {
            try GCPLogsDriverConfiguration.resolve(
                options: ["future": "value"],
                info: containerInfo()
            )
        }
    }

    @Test func sessionForwardsExactTimestampBytesFlushAndClose() async throws {
        let service = RecordingGCPLoggingService()
        let configuration = try GCPLogsDriverConfiguration(
            options: ["gcp-project": "project", "gcp-log-cmd": "true"],
            info: containerInfo()
        )
        let session = try GCPLogsDriverSession(
            sessionID: "gcp-session",
            configuration: configuration,
            service: service
        )
        let record = try ContainerLogRecordV2(
            stream: .stderr,
            observation: ContainerLogObservation(
                wallClock: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1_700_000_000,
                    nanoseconds: 123_456_789
                ),
                monotonicInstant: ContinuousClock().now
            ),
            payload: Data([0xff, 0x00, 0x41]),
            partial: nil,
            sequence: 1,
            processGeneration: 1
        )

        try await session.write(record)
        try await session.flush(
            deadline: ContinuousClock().now.advanced(by: .seconds(2))
        )
        try await session.close(
            deadline: ContinuousClock().now.advanced(by: .seconds(2))
        )

        let calls = service.calls
        #expect(calls.count == 4)
        guard case .start(let sessionID, let options, let info) = calls[0]
        else {
            Issue.record("expected start call")
            return
        }
        #expect(sessionID == "gcp-session")
        let sortedOptions = options.sorted {
            $0.key.lexicographicallyPrecedes($1.key)
        }
        let sortedConfiguration = configuration.semanticConfiguration.sorted {
            $0.key.lexicographicallyPrecedes($1.key)
        }
        #expect(sortedOptions == sortedConfiguration)
        #expect(info == configuration.dockerInfo)
        #expect(
            calls[1]
                == .log(
                    sessionID: "gcp-session",
                    seconds: 1_700_000_000,
                    nanoseconds: 123_456_789,
                    line: Data([0xff, 0x00, 0x41])
                )
        )
        #expect(calls[2] == .flush("gcp-session"))
        #expect(calls[3] == .close("gcp-session"))
        #expect(await session.currentState() == .closed)
    }

    @Test func providerReplaysAndFencesOneExactSession() async throws {
        let request = try startRequest()
        let service = RecordingGCPLoggingService()
        let binding = GCPLogsConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            configuration: try GCPLogsDriverConfiguration(
                options: ["gcp-project": "project"],
                info: containerInfo()
            ),
            loggingService: service
        )
        let resolver = FixedGCPLogsConfigurationResolver(binding)
        let provider = GCPLogsLogDriverProvider(
            configurationResolver: resolver,
            tokenGenerator: FixedGCPLogsTokenGenerator(
                bytes: Data(repeating: 9, count: 32)
            )
        )

        let started = try await provider.start(request)
        let replay = try await provider.start(request)
        #expect(
            replay.receipt.effectTokenMaterial.isByteIdentical(
                to: started.receipt.effectTokenMaterial
            )
        )
        #expect(await resolver.callCount == 1)
        let call = try sessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        #expect(
            try await provider.reconcileSession(call).observation == .active
        )
        #expect(
            try await provider.fenceSession(call).observation == .writerFenced
        )
        #expect(
            try await provider.closeSession(call).observation == .closed
        )
        #expect(service.calls.filter { if case .start = $0 { true } else { false } }.count == 1)
        #expect(service.calls.filter { if case .close = $0 { true } else { false } }.count == 1)
    }

    private func containerInfo() -> GCPLogsContainerInfo {
        GCPLogsContainerInfo(
            containerID: "0123456789abcdef0123456789abcdef",
            containerName: "/web",
            containerEntrypoint: "/bin/server",
            containerArguments: ["--listen", ":8080"],
            containerImageID: "sha256:image",
            containerImageName: "example/web:latest",
            containerCreated: Date(timeIntervalSince1970: 1_700_000_000.125),
            containerEnvironment: ["PORT=8080"],
            containerLabels: ["com.example.role": "web"],
            hostname: "host"
        )
    }

    private func startRequest() throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "start-key",
            semanticRequestDigest: "sha256:request",
            sessionID: "gcp-session",
            containerID: "container-id",
            leaseGeneration: 3,
            candidateProcessGeneration: 4,
            providerID: GCPLogsLogDriverContract.providerIdentity.id,
            providerGeneration: 1,
            candidateSandboxGeneration: nil
        )
    }

    private func sessionCall(
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
}
