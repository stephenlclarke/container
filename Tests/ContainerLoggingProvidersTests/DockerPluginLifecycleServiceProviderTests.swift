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

struct DockerPluginLifecycleServiceProviderTests {
    @Test func reconstructedProviderRecoversServiceOwnedWriterReceipt() async throws {
        let resolver = try LifecycleConfigurationResolver()
        let service = LifecycleServiceFixture(readLogs: false)
        let request = try lifecycleWriterRequest()
        let firstProvider = try makeProvider(
            readLogs: false,
            resolver: resolver,
            service: service
        )

        let first = try await firstProvider.start(request)
        let reconstructed = try makeProvider(
            readLogs: false,
            resolver: resolver,
            service: service
        )
        let recovered = try prepared(
            await reconstructed.reconcileStart(request)
        )

        #expect(
            first.receipt.effectTokenMaterial.isByteIdentical(
                to: recovered.receipt.effectTokenMaterial
            )
        )
        #expect(await service.writerEffectCount == 1)
        #expect(await resolver.writerCallCount == 1)

        let conflict = try lifecycleWriterRequest(
            semanticRequestDigest: "sha256:conflict"
        )
        switch try await reconstructed.reconcileStart(conflict) {
        case .conflict:
            break
        case .absent, .prepared, .uncertain:
            Issue.record("conflicting writer identity was not rejected")
        }
        #expect(await service.writerEffectCount == 1)

        let call = try lifecycleSessionCall(
            request: request,
            token: recovered.receipt.effectTokenMaterial
        )
        #expect(
            try await reconstructed.reconcileSession(call).observation
                == .active
        )
        let fenced = try await reconstructed.fenceSession(call)
        #expect(fenced.observation == .writerFenced)
        #expect(fenced.writerFenceReceiptDigest == "sha256:fixture-fence")
    }

    @Test func reconstructedProviderRecoversServiceOwnedReaderReceipt() async throws {
        let resolver = try LifecycleConfigurationResolver()
        let service = LifecycleServiceFixture(readLogs: true)
        let request = try lifecycleReaderRequest()
        let firstProvider = try makeProvider(
            readLogs: true,
            resolver: resolver,
            service: service
        )

        let first = try await firstProvider.openReader(request)
        let reconstructed = try makeProvider(
            readLogs: true,
            resolver: resolver,
            service: service
        )
        let recovered = try preparedReader(
            await reconstructed.reconcileReaderOpen(request)
        )

        #expect(
            first.receipt.effectTokenMaterial.isByteIdentical(
                to: recovered.receipt.effectTokenMaterial
            )
        )
        #expect(await service.readerEffectCount == 1)
        #expect(await resolver.readerCallCount == 1)
        #expect(
            try await recovered.reader.next()
                == .record(
                    try ContainerLogReadRecordV1(
                        stream: .stdout,
                        timestamp: ContainerLogTimestamp(
                            secondsSinceUnixEpoch: 17,
                            nanoseconds: 0
                        ),
                        data: Data("persisted reader\n".utf8),
                        sequence: 1
                    )
                )
        )

        let call = try lifecycleReaderCall(
            request: request,
            token: recovered.receipt.effectTokenMaterial
        )
        let closed = try await reconstructed.closeReader(call)
        #expect(closed.observation == .closed)
        #expect(closed.terminalOutcomeDigest == "sha256:fixture-reader")
    }

    @Test func descriptorCapabilityMismatchFailsClosed() async throws {
        let provider = try makeProvider(
            readLogs: false,
            resolver: try LifecycleConfigurationResolver(),
            service: LifecycleServiceFixture(readLogs: true)
        )

        await #expect(throws: DockerPluginProtocolError.capabilityMismatch) {
            try await provider.start(lifecycleWriterRequest())
        }
    }

    @Test func generationReclaimSkipsStoppedServiceOnResponseReplay() async throws {
        let service = LifecycleServiceFixture(readLogs: true)
        let reclaimer = LifecycleGenerationReclaimer()
        let provider = try makeProvider(
            readLogs: true,
            resolver: try LifecycleConfigurationResolver(),
            service: service,
            generationReclaimer: reclaimer
        )
        let request = try LogDriverProviderGenerationReclaimV1(
            providerID: lifecycleProviderIdentity.id,
            providerGeneration: lifecycleProviderGeneration
        )

        try await provider.reclaimGeneration(request)
        #expect(await service.generationReclaimCount == 1)
        #expect(await reclaimer.reclaimCount == 1)

        try await provider.reclaimGeneration(request)
        #expect(await service.generationReclaimCount == 1)
        #expect(await reclaimer.reclaimCount == 1)
    }

    private func makeProvider(
        readLogs: Bool,
        resolver: LifecycleConfigurationResolver,
        service: LifecycleServiceFixture,
        generationReclaimer:
            (any DockerPluginProviderGenerationReclaiming)? = nil
    ) throws -> DockerPluginServiceLogDriverProvider {
        try DockerPluginServiceLogDriverProvider(
            driver: "durable-plugin",
            providerIdentity: lifecycleProviderIdentity,
            providerGeneration: lifecycleProviderGeneration,
            readLogs: readLogs,
            configurationResolver: resolver,
            service: service,
            generationReclaimer: generationReclaimer
        )
    }

    private func prepared(
        _ reconciliation: LogDriverStartReconciliationV1
    ) throws -> StartedLogDriverSessionV1 {
        switch reconciliation {
        case .prepared(let started):
            return started
        case .absent, .conflict, .uncertain:
            Issue.record("expected a prepared writer")
            throw DockerPluginProtocolError.stopOutcomeUncertain
        }
    }

    private func preparedReader(
        _ reconciliation: LogDriverReaderOpenReconciliationV1
    ) throws -> StartedLogDriverReaderV1 {
        switch reconciliation {
        case .prepared(let started):
            return started
        case .absent, .conflict, .uncertain:
            Issue.record("expected a prepared reader")
            throw DockerPluginProtocolError.stopOutcomeUncertain
        }
    }
}

private let lifecycleProviderGeneration: UInt64 = 11
private let lifecycleSandboxGeneration: UInt64 = 13
private let lifecycleContainerID = String(repeating: "b", count: 64)
private let lifecycleProviderIdentity = LogDriverProviderIdentity(
    id: "io.container.logging.plugin.durable",
    version: "2.0.0",
    kind: .dockerPlugin
)

private func lifecycleWriterRequest(
    semanticRequestDigest: String = "sha256:durable-writer"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: 1,
        idempotencyKey: "durable-writer-operation",
        semanticRequestDigest: semanticRequestDigest,
        sessionID: "durable-writer-session",
        containerID: lifecycleContainerID,
        leaseGeneration: 2,
        candidateProcessGeneration: 3,
        providerID: lifecycleProviderIdentity.id,
        providerGeneration: lifecycleProviderGeneration,
        candidateSandboxGeneration: lifecycleSandboxGeneration
    )
}

private func lifecycleReaderRequest() throws -> LogDriverReaderOpenRequestV1 {
    try LogDriverReaderOpenRequestV1(
        operationGeneration: 4,
        idempotencyKey: "durable-reader-operation",
        semanticRequestDigest: "sha256:durable-reader",
        readerSessionID: "durable-reader-session",
        containerID: lifecycleContainerID,
        leaseGeneration: 2,
        providerID: lifecycleProviderIdentity.id,
        providerGeneration: lifecycleProviderGeneration,
        source: .stoppedContainer,
        read: ContainerLogReadRequest(tail: 1)
    )
}

private func lifecycleSessionCall(
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

private func lifecycleReaderCall(
    request: LogDriverReaderOpenRequestV1,
    token: LogDriverOpaqueEffectTokenV1
) throws -> LogDriverReaderCallV1 {
    try LogDriverReaderCallV1(
        readerSessionID: request.readerSessionID,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        source: request.source,
        effectTokenMaterial: token
    )
}

private actor LifecycleConfigurationResolver:
    DockerPluginConfigurationResolving
{
    private let info: DockerPluginInfo
    private(set) var writerCallCount = 0
    private(set) var readerCallCount = 0

    init() throws {
        self.info = try DockerPluginInfo(
            config: ["secret-option": "protected"],
            containerID: lifecycleContainerID,
            containerName: "/durable-service-1",
            containerEntrypoint: "/bin/service",
            containerArgs: ["--serve"],
            containerImageID: "sha256:image",
            containerImageName: "example/image:latest",
            containerCreated: Date(timeIntervalSince1970: 1_785_587_696),
            containerEnv: ["SECRET=protected"],
            containerLabels: ["label": "value"],
            logPath: "",
            daemonName: "docker"
        )
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> DockerPluginConfigurationBinding {
        writerCallCount += 1
        return binding(
            digest: request.semanticRequestDigest,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
    }

    func configuration(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginConfigurationBinding {
        readerCallCount += 1
        return binding(
            digest: request.semanticRequestDigest,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
    }

    private func binding(
        digest: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64
    ) -> DockerPluginConfigurationBinding {
        DockerPluginConfigurationBinding(
            semanticRequestDigest: digest,
            containerID: lifecycleContainerID,
            leaseGeneration: leaseGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            info: info
        )
    }
}

private actor LifecycleServiceFixture: DockerPluginLifecycleService {
    private let capabilities: DockerPluginCapabilities
    private let token: LogDriverOpaqueEffectTokenV1
    private var writerRequest: LogDriverStartRequestV1?
    private var readerRequest: LogDriverReaderOpenRequestV1?
    private var writerObservation: LogDriverSessionObservationV1 = .active
    private var readerObservation: LogDriverReaderObservationV1 = .active
    private(set) var writerEffectCount = 0
    private(set) var readerEffectCount = 0
    private(set) var generationReclaimCount = 0

    init(readLogs: Bool) {
        self.capabilities = DockerPluginCapabilities(readLogs: readLogs)
        self.token = try! LogDriverOpaqueEffectTokenV1(
            validating: Data(repeating: 0x5a, count: 32)
        )
    }

    func activeSandboxGeneration() async throws -> UInt64 {
        lifecycleSandboxGeneration
    }

    func startWriter(
        _ open: DockerPluginWriterOpenRequest
    ) async throws -> DockerPluginServiceStartedWriter {
        if let writerRequest {
            guard writerRequest == open.request else {
                throw DockerPluginProtocolError.idempotencyConflict
            }
        } else {
            writerRequest = open.request
            writerEffectCount += 1
        }
        return writer(open.request)
    }

    func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) async throws -> DockerPluginServiceWriterReconciliation {
        guard let writerRequest else {
            return .absent
        }
        switch writerRequest.idempotencyComparison(to: request) {
        case .identicalReplay:
            return .prepared(writer(request))
        case .conflict, .distinctScope:
            return .conflict
        }
    }

    func reconcileWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validate(request)
        return try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: writerObservation,
            writerFenceReceiptDigest:
                writerObservation == .writerFenced
                ? "sha256:fixture-fence" : nil
        )
    }

    func fenceWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validate(request)
        writerObservation = .writerFenced
        return try await reconcileWriter(request)
    }

    func closeWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validate(request)
        writerObservation = .closed
        return try await reconcileWriter(request)
    }

    func openReader(
        _ open: DockerPluginReaderOpenRequest
    ) async throws -> DockerPluginServiceStartedReader {
        guard capabilities.readLogs else {
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
        }
        if let readerRequest {
            guard readerRequest == open.request else {
                throw DockerPluginProtocolError.idempotencyConflict
            }
        } else {
            readerRequest = open.request
            readerEffectCount += 1
        }
        return reader(open.request)
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginServiceReaderReconciliation {
        guard let readerRequest else {
            return .absent
        }
        switch readerRequest.idempotencyComparison(to: request) {
        case .identicalReplay:
            return .prepared(reader(request))
        case .conflict, .distinctScope:
            return .conflict
        }
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try validate(request)
        return try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: readerObservation,
            terminalOutcomeDigest:
                readerObservation == .closed
                ? "sha256:fixture-reader" : nil
        )
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try validate(request)
        readerObservation = .closed
        return try await reconcileReader(request)
    }

    func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async throws {
        switch request.kind {
        case .writerCandidate, .writerSession, .detachedCleanup:
            writerRequest = nil
        case .readerCandidate, .readerSession:
            readerRequest = nil
        }
    }

    func reclaimGeneration(
        _ request: LogDriverProviderGenerationReclaimV1
    ) async throws {
        guard
            request.providerID == lifecycleProviderIdentity.id,
            request.providerGeneration == lifecycleProviderGeneration
        else {
            throw LogDriverProviderGenerationReclaimError.invalidRequest
        }
        generationReclaimCount += 1
    }

    private func writer(
        _ request: LogDriverStartRequestV1
    ) -> DockerPluginServiceStartedWriter {
        DockerPluginServiceStartedWriter(
            capabilities: capabilities,
            started: StartedLogDriverSessionV1(
                receipt: LogDriverStartReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                session: LifecycleNoopWriter()
            )
        )
    }

    private func reader(
        _ request: LogDriverReaderOpenRequestV1
    ) -> DockerPluginServiceStartedReader {
        DockerPluginServiceStartedReader(
            capabilities: capabilities,
            started: StartedLogDriverReaderV1(
                receipt: LogDriverReaderOpenReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                reader: LifecycleSingleRecordReader()
            )
        )
    }

    private func validate(_ call: LogDriverSessionCallV1) throws {
        guard
            let writerRequest,
            call.sessionID == writerRequest.sessionID,
            call.containerID == writerRequest.containerID,
            call.providerID == writerRequest.providerID,
            call.providerGeneration == writerRequest.providerGeneration,
            call.effectTokenMaterial.isByteIdentical(to: token)
        else {
            throw DockerPluginProtocolError.invalidEffectToken
        }
    }

    private func validate(_ call: LogDriverReaderCallV1) throws {
        guard
            let readerRequest,
            call.readerSessionID == readerRequest.readerSessionID,
            call.containerID == readerRequest.containerID,
            call.providerID == readerRequest.providerID,
            call.providerGeneration == readerRequest.providerGeneration,
            call.effectTokenMaterial.isByteIdentical(to: token)
        else {
            throw DockerPluginProtocolError.invalidEffectToken
        }
    }
}

private actor LifecycleGenerationReclaimer:
    DockerPluginProviderGenerationReclaiming
{
    private var reclaimed = false
    private(set) var reclaimCount = 0

    func isProviderGenerationReclaimed(
        _: LogDriverProviderGenerationReclaimV1
    ) -> Bool {
        reclaimed
    }

    func reclaimProviderGeneration(
        _: LogDriverProviderGenerationReclaimV1
    ) {
        reclaimCount += 1
        reclaimed = true
    }
}

private actor LifecycleNoopWriter: ContainerLogDriverSession {
    func write(_ record: ContainerLogRecordV2) async throws {}

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {}
}

private actor LifecycleSingleRecordReader: ContainerLogReader {
    private var sequence = 0

    func next() async throws -> ContainerLogReaderEventV1 {
        sequence += 1
        if sequence == 1 {
            return .record(
                try ContainerLogReadRecordV1(
                    stream: .stdout,
                    timestamp: ContainerLogTimestamp(
                        secondsSinceUnixEpoch: 17,
                        nanoseconds: 0
                    ),
                    data: Data("persisted reader\n".utf8),
                    sequence: 1
                )
            )
        }
        return .endOfStream
    }

    func cancel() async {}
}
