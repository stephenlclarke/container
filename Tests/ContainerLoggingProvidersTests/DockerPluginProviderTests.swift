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

struct DockerPluginProviderTests {
    @Test func descriptorPublishesDockerPluginRoutingContract() throws {
        let readable = try DockerPluginLogDriverContract.descriptor(
            driver: "example",
            aliases: ["example:latest"],
            providerIdentity: dockerPluginProviderIdentity,
            providerGeneration: dockerPluginProviderGeneration,
            readLogs: true
        )

        #expect(readable.driver == "example")
        #expect(readable.aliases == ["example:latest"])
        #expect(readable.providerIdentity.kind == .dockerPlugin)
        #expect(readable.placement == .engineLinuxSandbox)
        #expect(readable.trust == .signed)
        #expect(readable.acceptsUnknownOptions)
        #expect(readable.capabilities.nativeRead)
        #expect(readable.capabilities.supportsDualCache)
        #expect(readable.capabilities.supportsDockerPluginProtocol)
        #expect(readable.capabilities.requiresDeliverySession)
        #expect(readable.capabilities.logPathVisibility == .none)
        #expect(Set(readable.options.map(\.name)) == ["max-buffer-size", "mode"])

        let writeOnly = try DockerPluginLogDriverContract.descriptor(
            driver: "write-only",
            providerIdentity: dockerPluginProviderIdentity,
            providerGeneration: dockerPluginProviderGeneration,
            readLogs: false
        )
        #expect(!writeOnly.capabilities.nativeRead)
        #expect(writeOnly.capabilities.readFilters.isEmpty)
        #expect(writeOnly.capabilities.supportsDualCache)
    }

    @Test func responseLossReconcilesExactWriterWithoutDuplicateEffect() async throws {
        let fixture = try DockerPluginProviderFixture(
            declaredReadLogs: false,
            actualReadLogs: false,
            startResponses: [
                .failure(.containsSensitiveBody),
                .success(Data("{}".utf8)),
            ]
        )
        let request = try dockerPluginWriterRequest()

        await #expect(
            throws: DockerPluginProtocolError.transportFailure(endpoint: .startLogging)
        ) {
            try await fixture.provider.start(request)
        }
        let conflicting = try dockerPluginWriterRequest(
            semanticRequestDigest: "sha256:conflict"
        )
        await #expect(throws: DockerPluginProtocolError.idempotencyConflict) {
            try await fixture.provider.start(conflicting)
        }

        let recovered = try await preparedSession(
            fixture.provider.reconcileStart(request)
        )
        let replay = try await preparedSession(
            fixture.provider.reconcileStart(request)
        )
        #expect(
            recovered.receipt.effectTokenMaterial.isByteIdentical(
                to: replay.receipt.effectTokenMaterial
            )
        )
        #expect(await fixture.configurationResolver.writerCallCount == 1)
        #expect(await fixture.providerAcquirer.acquireCount == 1)
        #expect(await fixture.fifoFactory.createCount == 1)
        #expect(
            await fixture.transport.calls.map(\.endpoint)
                == [.capabilities, .startLogging, .startLogging]
        )

        let call = try dockerPluginSessionCall(
            request: request,
            token: recovered.receipt.effectTokenMaterial
        )
        #expect(try await fixture.provider.reconcileSession(call).observation == .active)
        let firstFence = try await fixture.provider.fenceSession(call)
        let replayedFence = try await fixture.provider.fenceSession(call)
        #expect(firstFence.observation == .writerFenced)
        #expect(firstFence.writerFenceReceiptDigest?.hasPrefix("sha256:") == true)
        #expect(
            firstFence.writerFenceReceiptDigest
                == replayedFence.writerFenceReceiptDigest
        )
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)

        let invalidTokenCall = try dockerPluginSessionCall(
            request: request,
            token: try LogDriverOpaqueEffectTokenV1(
                validating: Data(repeating: 0x99, count: 32)
            )
        )
        await #expect(throws: DockerPluginProtocolError.invalidEffectToken) {
            try await fixture.provider.reconcileSession(invalidTokenCall)
        }
        let staleFenceCall = try LogDriverSessionCallV1(
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            fence: LogDriverSessionFenceV1(
                activeProcessGeneration: request.candidateProcessGeneration + 1,
                sandboxGeneration: request.candidateSandboxGeneration
            ),
            effectTokenMaterial: recovered.receipt.effectTokenMaterial
        )
        await #expect(throws: DockerPluginProtocolError.invalidSessionFence) {
            try await fixture.provider.reconcileSession(staleFenceCall)
        }

        try await fixture.provider.reclaimTerminalEffect(
            LogDriverTerminalEffectReclaimV1(
                kind: .detachedCleanup,
                effectID: request.sessionID,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
        )
        #expect(try await fixture.provider.reconcileSession(call).observation == .absent)
    }

    @Test func readablePluginOwnsStableDirectReaderAndLease() async throws {
        let frame = try DockerPluginLogEntryCodec.encodeFrame(
            DockerPluginLogEntry(
                source: "stdout",
                timeNano: 12_250_000_000,
                line: Data("plugin history\n".utf8),
                partial: false,
                partialMetadata: nil
            )
        )
        let stream = DockerPluginTestResponseStream(chunks: [frame])
        let fixture = try DockerPluginProviderFixture(
            declaredReadLogs: true,
            actualReadLogs: true,
            stream: stream
        )
        let request = try dockerPluginReaderRequest()

        let started = try await fixture.provider.openReader(request)
        let replay = try await fixture.provider.openReader(request)
        #expect(
            started.receipt.effectTokenMaterial.isByteIdentical(
                to: replay.receipt.effectTokenMaterial
            )
        )
        #expect(await fixture.configurationResolver.readerCallCount == 1)
        #expect(await fixture.providerAcquirer.acquireCount == 1)
        #expect(await fixture.transport.streamCalls.map(\.endpoint) == [.readLogs])
        #expect(
            try await started.reader.next()
                == .record(
                    try ContainerLogReadRecordV1(
                        stream: .stdout,
                        timestamp: ContainerLogTimestamp(
                            secondsSinceUnixEpoch: 12,
                            nanoseconds: 250_000_000
                        ),
                        data: Data("plugin history\n".utf8),
                        sequence: 1
                    )
                )
        )
        #expect(try await started.reader.next() == .endOfStream)
        #expect(await stream.closeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)

        let call = try dockerPluginReaderCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        let observed = try await fixture.provider.reconcileReader(call)
        let closed = try await fixture.provider.closeReader(call)
        #expect(observed.observation == .closed)
        #expect(observed.terminalOutcomeDigest?.hasPrefix("sha256:") == true)
        #expect(observed.terminalOutcomeDigest == closed.terminalOutcomeDigest)

        try await fixture.provider.reclaimTerminalEffect(
            LogDriverTerminalEffectReclaimV1(
                kind: .readerSession,
                effectID: request.readerSessionID,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
        )
        #expect(try await fixture.provider.reconcileReader(call).observation == .absent)
    }

    @Test func writeOnlyPluginRefusesReaderBeforeAnyAcquisition() async throws {
        let fixture = try DockerPluginProviderFixture(
            declaredReadLogs: false,
            actualReadLogs: false
        )

        await #expect(
            throws: ContainerLogReaderError.configuredDriverDoesNotSupportReading
        ) {
            try await fixture.provider.openReader(
                dockerPluginReaderRequest()
            )
        }

        #expect(await fixture.configurationResolver.readerCallCount == 0)
        #expect(await fixture.providerAcquirer.acquireCount == 0)
        #expect(await fixture.transport.calls.isEmpty)
        #expect(await fixture.transport.streamCalls.isEmpty)
    }

    @Test func capabilityMismatchRevokesPreparedFIFOAndLease() async throws {
        let fixture = try DockerPluginProviderFixture(
            declaredReadLogs: false,
            actualReadLogs: true
        )

        await #expect(throws: DockerPluginProtocolError.capabilityMismatch) {
            try await fixture.provider.start(dockerPluginWriterRequest())
        }

        #expect(await fixture.providerAcquirer.acquireCount == 1)
        #expect(await fixture.fifoFactory.createCount == 1)
        #expect(await fixture.fifo.revokeCount == 1)
        #expect(await fixture.lease.releaseCount == 1)
        #expect(
            await fixture.transport.calls.map(\.endpoint)
                == [.capabilities, .stopLogging]
        )
    }

    private func preparedSession(
        _ reconciliation: LogDriverStartReconciliationV1
    ) throws -> StartedLogDriverSessionV1 {
        switch reconciliation {
        case .prepared(let started):
            return started
        case .absent:
            Issue.record("expected prepared writer, got absent")
        case .conflict:
            Issue.record("expected prepared writer, got conflict")
        case .uncertain:
            Issue.record("expected prepared writer, got uncertain")
        }
        throw DockerPluginProtocolError.stopOutcomeUncertain
    }
}

private let dockerPluginProviderGeneration: UInt64 = 7
private let dockerPluginSandboxGeneration: UInt64 = 9
private let dockerPluginContainerID = String(repeating: "a", count: 64)
private let dockerPluginProviderIdentity = LogDriverProviderIdentity(
    id: "io.container.logging.plugin.example",
    version: "1.0.0",
    kind: .dockerPlugin
)

private func dockerPluginWriterRequest(
    semanticRequestDigest: String = "sha256:writer"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: 1,
        idempotencyKey: "plugin-writer-operation",
        semanticRequestDigest: semanticRequestDigest,
        sessionID: "plugin-writer-session",
        containerID: dockerPluginContainerID,
        leaseGeneration: 2,
        candidateProcessGeneration: 4,
        providerID: dockerPluginProviderIdentity.id,
        providerGeneration: dockerPluginProviderGeneration,
        candidateSandboxGeneration: dockerPluginSandboxGeneration
    )
}

private func dockerPluginReaderRequest() throws -> LogDriverReaderOpenRequestV1 {
    try LogDriverReaderOpenRequestV1(
        operationGeneration: 3,
        idempotencyKey: "plugin-reader-operation",
        semanticRequestDigest: "sha256:reader",
        readerSessionID: "plugin-reader-session",
        containerID: dockerPluginContainerID,
        leaseGeneration: 2,
        providerID: dockerPluginProviderIdentity.id,
        providerGeneration: dockerPluginProviderGeneration,
        source: .stoppedContainer,
        read: ContainerLogReadRequest(tail: 10)
    )
}

private func dockerPluginSessionCall(
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

private func dockerPluginReaderCall(
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

private struct DockerPluginProviderFixture {
    let transport: DockerPluginTestTransport
    let fifo: DockerPluginProviderFIFO
    let lease: DockerPluginProviderLeaseFixture
    let fifoFactory: DockerPluginProviderFIFOFactory
    let providerAcquirer: DockerPluginProviderAcquirerFixture
    let configurationResolver: DockerPluginProviderConfigurationResolver
    let provider: DockerPluginLogDriverProvider

    init(
        declaredReadLogs: Bool,
        actualReadLogs: Bool,
        startResponses: [Result<Data, DockerPluginTestFailure>] = [],
        stream: (any DockerPluginResponseStream)? = nil
    ) throws {
        let transport = DockerPluginTestTransport(
            responses: [
                .capabilities: [
                    .success(
                        Data(
                            "{\"Cap\":{\"ReadLogs\":\(actualReadLogs)},\"Err\":\"\"}"
                                .utf8
                        )
                    )
                ],
                .startLogging: startResponses,
                .stopLogging: [.success(Data("{}".utf8))],
            ],
            stream: stream
        )
        let fifo = try DockerPluginProviderFIFO()
        let lease = DockerPluginProviderLeaseFixture(transport: transport)
        let fifoFactory = DockerPluginProviderFIFOFactory(fifo: fifo)
        let providerAcquirer = DockerPluginProviderAcquirerFixture(
            lease: lease
        )
        let configurationResolver = try DockerPluginProviderConfigurationResolver()
        self.transport = transport
        self.fifo = fifo
        self.lease = lease
        self.fifoFactory = fifoFactory
        self.providerAcquirer = providerAcquirer
        self.configurationResolver = configurationResolver
        self.provider = try DockerPluginLogDriverProvider(
            driver: "example",
            providerIdentity: dockerPluginProviderIdentity,
            providerGeneration: dockerPluginProviderGeneration,
            readLogs: declaredReadLogs,
            configurationResolver: configurationResolver,
            providerAcquirer: providerAcquirer,
            fifoFactory: fifoFactory,
            random: FixedDockerPluginProviderRandomBytes()
        )
    }
}

private actor DockerPluginProviderConfigurationResolver:
    DockerPluginConfigurationResolving
{
    private let info: DockerPluginInfo
    private(set) var writerCallCount = 0
    private(set) var readerCallCount = 0

    init() throws {
        self.info = try DockerPluginInfo(
            config: ["plugin-option": "value"],
            containerID: dockerPluginContainerID,
            containerName: "/project-service-1",
            containerEntrypoint: "/bin/service",
            containerArgs: ["--serve"],
            containerImageID: "sha256:image",
            containerImageName: "example/image:latest",
            containerCreated: Date(timeIntervalSince1970: 1_785_587_696.125),
            containerEnv: ["ENV=value"],
            containerLabels: ["label": "value"],
            logPath: "",
            daemonName: "docker"
        )
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> DockerPluginConfigurationBinding {
        writerCallCount += 1
        return DockerPluginConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            info: info
        )
    }

    func configuration(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginConfigurationBinding {
        readerCallCount += 1
        return DockerPluginConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            info: info
        )
    }
}

private actor DockerPluginProviderAcquirerFixture:
    DockerPluginProviderAcquiring
{
    private let lease: DockerPluginProviderLeaseFixture
    private(set) var acquireCount = 0

    init(lease: DockerPluginProviderLeaseFixture) {
        self.lease = lease
    }

    func activeSandboxGeneration(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> UInt64 {
        guard
            providerID == dockerPluginProviderIdentity.id,
            providerGeneration == dockerPluginProviderGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        return dockerPluginSandboxGeneration
    }

    func acquire(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginProviderLease {
        guard
            providerID == dockerPluginProviderIdentity.id,
            providerGeneration == dockerPluginProviderGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        acquireCount += 1
        return lease
    }
}

private actor DockerPluginProviderLeaseFixture: DockerPluginProviderLease {
    nonisolated let providerGeneration = dockerPluginProviderGeneration
    nonisolated let transport: any DockerPluginRPCTransport
    private(set) var releaseCount = 0

    init(transport: any DockerPluginRPCTransport) {
        self.transport = transport
    }

    func release() async {
        releaseCount += 1
    }
}

private actor DockerPluginProviderFIFOFactory: DockerPluginFIFOFactory {
    private let fifo: DockerPluginProviderFIFO
    private(set) var createCount = 0

    init(fifo: DockerPluginProviderFIFO) {
        self.fifo = fifo
    }

    func createFIFO(
        sessionID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginFIFO {
        guard
            sessionID == "plugin-writer-session",
            providerGeneration == dockerPluginProviderGeneration
        else {
            throw DockerPluginProtocolError.invalidFIFOReference
        }
        createCount += 1
        return fifo
    }
}

private actor DockerPluginProviderFIFO: DockerPluginFIFO {
    nonisolated let reference: DockerPluginFIFOReference
    private(set) var frames = [Data]()
    private(set) var closeCount = 0
    private(set) var revokeCount = 0

    init() throws {
        self.reference = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/plugin-writer-session"
        )
    }

    func writeFrame(_ frame: Data) async throws {
        frames.append(frame)
    }

    func closeAndRemove() async {
        closeCount += 1
    }

    func revokeAndRemove() async {
        revokeCount += 1
    }
}

private struct FixedDockerPluginProviderRandomBytes:
    DockerPluginRandomBytesGenerating
{
    func makeBytes(count: Int) throws -> Data {
        Data(repeating: 0x42, count: count)
    }
}
