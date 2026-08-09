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

import DockerSemanticHelper
import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct JournaldProviderTests {
    @Test func descriptorPublishesLinuxNativeReadContract() {
        let descriptor = JournaldLogDriverContract.descriptor(
            providerGeneration: 7
        )

        #expect(descriptor.driver == "journald")
        #expect(descriptor.providerIdentity.kind == .linuxService)
        #expect(descriptor.providerGeneration == 7)
        #expect(descriptor.placement == .engineLinuxSandbox)
        #expect(descriptor.trust == .signed)
        #expect(descriptor.capabilities.nativeRead)
        #expect(!descriptor.capabilities.supportsDualCache)
        #expect(descriptor.capabilities.requiresDeliverySession)
        #expect(
            Set(descriptor.capabilities.readFilters)
                == Set(
                    [
                        .stdout,
                        .stderr,
                        .follow,
                        .tail,
                        .since,
                        .until,
                        .timestamps,
                        .details,
                    ] as [LogDriverReadFilter])
        )
        #expect(
            Set(descriptor.options.map(\.name))
                == JournaldDriverConfiguration.knownOptionNames
        )
    }

    @Test func keySanitizationMatchesPinnedMobyVectors() {
        let vectors = [
            "io.kubernetes.pod.name": "IO_KUBERNETES_POD_NAME",
            "io?.kubernetes.pod.name": "IO__KUBERNETES_POD_NAME",
            "?io.kubernetes.pod.name": "IO_KUBERNETES_POD_NAME",
            "io123.kubernetes.pod.name": "IO123_KUBERNETES_POD_NAME",
            "_io123.kubernetes.pod.name": "IO123_KUBERNETES_POD_NAME",
            "__io123_kubernetes.pod.name": "IO123_KUBERNETES_POD_NAME",
        ]
        for (source, expected) in vectors {
            #expect(
                JournaldDriverConfiguration.sanitizeFieldName(source)
                    == expected
            )
        }
    }

    @Test func configurationUsesDockerTagAndEnvironmentOverridesLabels() throws {
        let semantic = JournaldSemanticStub()
        let identifier = String(repeating: "a", count: 64)
        let configuration = try JournaldDriverConfiguration.resolve(
            options: [
                "env": "shared,selected.env",
                "labels": "shared,io.kubernetes.pod.name",
                "labels-regex": "^io\\.",
                "tag": "{{.Name}}",
            ],
            info: SyslogContainerInfo(
                containerID: identifier,
                containerName: "/service",
                containerImageName: "example/image:latest",
                containerEnvironment: [
                    "shared=environment",
                    "selected.env=value",
                ],
                containerLabels: [
                    "shared": "label",
                    "io.kubernetes.pod.name": "pod",
                ]
            ),
            semanticService: semantic
        )

        #expect(configuration.fields[JournaldField.containerID] == String(identifier.prefix(12)))
        #expect(configuration.fields[JournaldField.containerName] == "service")
        #expect(configuration.fields[JournaldField.containerTag] == "rendered-tag")
        #expect(configuration.fields[JournaldField.syslogIdentifier] == "rendered-tag")
        #expect(configuration.fields["SHARED"] == "environment")
        #expect(configuration.fields["SELECTED_ENV"] == "value")
        #expect(configuration.fields["IO_KUBERNETES_POD_NAME"] == "pod")
    }

    @Test func entryProjectionPreservesMobyFieldsPriorityAndPartialPresentation() throws {
        let configuration = try journaldConfiguration()
        var encoder = try JournaldEntryEncoder(
            configuration: configuration,
            epoch: "epoch-1"
        )
        let entry = try encoder.encode(
            record(
                stream: .stderr,
                payload: Data("partial".utf8),
                partial: try ContainerLogPartialMetadataV1(
                    validatingID: String(repeating: "b", count: 64),
                    ordinal: 1,
                    last: false
                )
            )
        )

        #expect(entry.priority == .error)
        #expect(entry.fields[JournaldField.logEpoch] == "epoch-1")
        #expect(entry.fields[JournaldField.logOrdinal] == "1")
        #expect(entry.fields[JournaldField.partialOrdinal] == "1")
        #expect(entry.fields[JournaldField.partialLast] == "false")
        #expect(entry.fields[JournaldField.partialMessage] == "true")
        #expect(entry.fields[JournaldField.syslogTimestamp] == "2026-08-03T10:11:12.123456789Z")

        let projected = try entry.readRecord(sequence: 9)
        #expect(projected.stream == .stderr)
        #expect(projected.data == Data("partial".utf8))
        #expect(projected.sequence == 9)
        #expect(projected.processGeneration == 4)
        #expect(projected.attributes == ["SELECTED": "value"])

        let complete = try encoder.encode(
            record(stream: .stdout, payload: Data("line".utf8))
        )
        #expect(complete.priority == .informational)
        #expect(complete.fields[JournaldField.logOrdinal] == "2")
        #expect(try complete.readRecord(sequence: 10).data == Data("line\n".utf8))
    }

    @Test func providerHistoryHandoffIsBoundAndReplayStable() async throws {
        let writer = try writerRequest()
        let descriptor = JournaldLogDriverContract.descriptor()
        let provider = JournaldLogDriverProvider(
            configurationResolver: FixedJournaldConfigurationResolver(
                JournaldConfigurationBinding(
                    semanticRequestDigest: writer.semanticRequestDigest,
                    containerID: writer.containerID,
                    leaseGeneration: writer.leaseGeneration,
                    providerID: writer.providerID,
                    providerGeneration: writer.providerGeneration,
                    configuration: try journaldConfiguration()
                )
            ),
            service: RecordingJournaldService(readerRecords: [])
        )
        let exportRequest = try LogDriverHistoryHandoffExportRequestV1(
            tokenID: "token",
            manifestID: "manifest",
            containerID: writer.containerID,
            sourceStateRootUUID: "source-root",
            destinationStateRootUUID: "destination-root",
            sourceLeaseGeneration: writer.leaseGeneration,
            sourceProviderID: descriptor.providerIdentity.id,
            sourceProviderGeneration: descriptor.providerGeneration,
            sourceContractDigest: descriptor.optionContractDigest,
            terminalHistoryDigestSHA256: "sha256:" + String(repeating: "a", count: 64)
        )
        let export = try await provider.exportHistoryForHandoff(exportRequest)
        #expect(try await provider.exportHistoryForHandoff(exportRequest) == export)

        let destination = try LogDriverHistoryHandoffDestinationRequestV1(
            exportReceipt: export,
            manifestDigestSHA256: "sha256:" + String(repeating: "b", count: 64),
            destinationLeaseGeneration: 1,
            destinationProviderID: descriptor.providerIdentity.id,
            destinationProviderGeneration: descriptor.providerGeneration,
            destinationContractDigest: descriptor.optionContractDigest
        )
        try await provider.preflightHistoryHandoff(destination)
        let promotionRequest = try LogDriverHistoryHandoffPromotionRequestV1(
            destination: destination,
            commitDigestSHA256: "sha256:" + String(repeating: "c", count: 64),
            handoffChainHeadDigestSHA256: "sha256:" + String(repeating: "d", count: 64)
        )
        let promotion = try await provider.promoteHistoryHandoff(promotionRequest)
        #expect(try await provider.promoteHistoryHandoff(promotionRequest) == promotion)
        try await provider.activateHistoryHandoff(
            LogDriverHistoryHandoffActivationRequestV1(
                promotionReceipt: promotion,
                terminalOutcomeDigestSHA256: "sha256:" + String(repeating: "e", count: 64)
            )
        )
    }

    @Test func providerFencesWriterAndOwnsIdempotentReadableSessions() async throws {
        let request = try writerRequest()
        let configuration = try journaldConfiguration()
        let binding = JournaldConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            configuration: configuration
        )
        let resolver = FixedJournaldConfigurationResolver(binding)
        let service = RecordingJournaldService(
            readerRecords: [
                try ContainerLogReadRecordV1(
                    stream: .stdout,
                    timestamp: timestamp(),
                    data: Data("history\n".utf8),
                    sequence: 1,
                    processGeneration: 4
                )
            ]
        )
        let provider = JournaldLogDriverProvider(
            configurationResolver: resolver,
            service: service,
            random: FixedJournaldRandomBytesGenerator()
        )

        let first = try await provider.start(request)
        let replay = try await provider.start(request)
        #expect(
            first.receipt.effectTokenMaterial.isByteIdentical(
                to: replay.receipt.effectTokenMaterial
            )
        )
        #expect(await resolver.callCount == 1)
        #expect(await service.writerOpenCount == 1)

        try await first.session.write(
            record(stream: .stdout, payload: Data("written".utf8))
        )
        #expect(await service.entries.count == 1)

        let sessionCall = try LogDriverSessionCallV1(
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            fence: LogDriverSessionFenceV1(
                activeProcessGeneration: request.candidateProcessGeneration,
                sandboxGeneration: request.candidateSandboxGeneration
            ),
            effectTokenMaterial: first.receipt.effectTokenMaterial
        )
        #expect(try await provider.reconcileSession(sessionCall).observation == .active)
        let fenced = try await provider.fenceSession(sessionCall)
        #expect(fenced.observation == LogDriverSessionObservationV1.writerFenced)
        #expect(fenced.writerFenceReceiptDigest?.hasPrefix("sha256:") == true)
        #expect(await service.closeCalls == [true])
        try await provider.reclaimTerminalEffect(
            LogDriverTerminalEffectReclaimV1(
                kind: .detachedCleanup,
                effectID: request.sessionID,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
        )
        #expect(try await provider.reconcileSession(sessionCall).observation == .absent)
        #expect(await service.reclaimedWriters == [request.sessionID])

        let readerRequest = try LogDriverReaderOpenRequestV1(
            operationGeneration: 1,
            idempotencyKey: "reader-operation",
            semanticRequestDigest: "sha256:reader",
            readerSessionID: "reader-session",
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            source: .stoppedContainer,
            read: try ContainerLogReadRequest(tail: 10)
        )
        let reader = try await provider.openReader(readerRequest)
        let readerReplay = try await provider.openReader(readerRequest)
        #expect(
            reader.receipt.effectTokenMaterial.isByteIdentical(
                to: readerReplay.receipt.effectTokenMaterial
            )
        )
        #expect(await service.readerOpenCount == 1)
        #expect(
            try await reader.reader.next()
                == .record(
                    try ContainerLogReadRecordV1(
                        stream: .stdout,
                        timestamp: timestamp(),
                        data: Data("history\n".utf8),
                        sequence: 1,
                        processGeneration: 4
                    )
                )
        )
        #expect(try await reader.reader.next() == .endOfStream)

        let readerCall = try LogDriverReaderCallV1(
            readerSessionID: readerRequest.readerSessionID,
            containerID: readerRequest.containerID,
            leaseGeneration: readerRequest.leaseGeneration,
            providerID: readerRequest.providerID,
            providerGeneration: readerRequest.providerGeneration,
            source: readerRequest.source,
            effectTokenMaterial: reader.receipt.effectTokenMaterial
        )
        let observed = try await provider.reconcileReader(readerCall)
        #expect(observed.observation == .closed)
        #expect(observed.terminalOutcomeDigest?.hasPrefix("sha256:") == true)
        try await provider.reclaimTerminalEffect(
            LogDriverTerminalEffectReclaimV1(
                kind: .readerSession,
                effectID: readerRequest.readerSessionID,
                providerID: readerRequest.providerID,
                providerGeneration: readerRequest.providerGeneration
            )
        )
        #expect(try await provider.reconcileReader(readerCall).observation == .absent)
        #expect(await service.reclaimedReaders == [readerRequest.readerSessionID])
    }

    private func writerRequest() throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "writer-operation",
            semanticRequestDigest: "sha256:writer",
            sessionID: "writer-session",
            containerID: String(repeating: "a", count: 64),
            leaseGeneration: 2,
            candidateProcessGeneration: 4,
            providerID: JournaldLogDriverContract.providerIdentity.id,
            providerGeneration: 1,
            candidateSandboxGeneration: 3
        )
    }

    private func journaldConfiguration() throws -> JournaldDriverConfiguration {
        let identifier = String(repeating: "a", count: 64)
        return try JournaldDriverConfiguration(
            containerID: identifier,
            fields: [
                JournaldField.containerID: String(identifier.prefix(12)),
                JournaldField.containerIDFull: identifier,
                JournaldField.containerName: "service",
                JournaldField.containerTag: "service",
                JournaldField.imageName: "example/image:latest",
                JournaldField.syslogIdentifier: "service",
                "SELECTED": "value",
            ]
        )
    }

    private func timestamp() throws -> ContainerLogTimestamp {
        try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_785_751_872,
            nanoseconds: 123_456_789
        )
    }

    private func record(
        stream: ContainerLogStream,
        payload: Data,
        partial: ContainerLogPartialMetadataV1? = nil
    ) throws -> ContainerLogRecordV2 {
        try ContainerLogRecordV2(
            stream: stream,
            observation: ContainerLogObservation(
                wallClock: timestamp(),
                monotonicInstant: ContinuousClock().now
            ),
            payload: payload,
            partial: partial,
            sequence: 1,
            processGeneration: 4
        )
    }
}

private actor FixedJournaldConfigurationResolver: JournaldConfigurationResolving {
    let binding: JournaldConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: JournaldConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) -> JournaldConfigurationBinding {
        callCount += 1
        return binding
    }
}

private struct FixedJournaldRandomBytesGenerator: JournaldRandomBytesGenerating {
    func makeBytes(count: Int) throws -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}

private actor RecordingJournaldService: JournaldService {
    private let readerRecords: [ContainerLogReadRecordV1]
    private var writers = [String: JournaldWriterOpenRequest]()
    private(set) var entries = [JournaldEntry]()
    private(set) var writerOpenCount = 0
    private(set) var readerOpenCount = 0
    private(set) var closeCalls = [Bool]()
    private(set) var reclaimedWriters = [String]()
    private(set) var reclaimedReaders = [String]()

    init(readerRecords: [ContainerLogReadRecordV1]) {
        self.readerRecords = readerRecords
    }

    func activeSandboxGeneration() -> UInt64 {
        3
    }

    func openWriter(_ request: JournaldWriterOpenRequest) throws {
        if let existing = writers[request.request.sessionID] {
            guard existing == request else {
                throw JournaldProviderError.idempotencyConflict
            }
            return
        }
        writers[request.request.sessionID] = request
        writerOpenCount += 1
    }

    func write(sessionID: String, entry: JournaldEntry) throws {
        guard writers[sessionID] != nil else {
            throw JournaldProviderError.unknownSession
        }
        entries.append(entry)
    }

    func flushWriter(
        sessionID: String,
        deadline: ContinuousClock.Instant
    ) throws {
        guard writers[sessionID] != nil, ContinuousClock().now < deadline else {
            throw JournaldProviderError.deadlineExceeded
        }
    }

    func closeWriter(
        sessionID: String,
        fenced: Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        guard writers[sessionID] != nil, ContinuousClock().now < deadline else {
            throw JournaldProviderError.deadlineExceeded
        }
        closeCalls.append(fenced)
    }

    func reclaimWriter(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) {
        _ = providerID
        _ = providerGeneration
        writers.removeValue(forKey: sessionID)
        reclaimedWriters.append(sessionID)
    }

    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) -> any ContainerLogReader {
        readerOpenCount += 1
        return JournaldTestReader(records: readerRecords)
    }

    func reclaimReader(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) {
        _ = sessionID
        _ = providerID
        _ = providerGeneration
        reclaimedReaders.append(sessionID)
    }
}

private actor JournaldTestReader: ContainerLogReader {
    private var records: [ContainerLogReadRecordV1]
    private var ended = false

    init(records: [ContainerLogReadRecordV1]) {
        self.records = records
    }

    func next() throws -> ContainerLogReaderEventV1 {
        guard !ended else {
            throw ContainerLogReaderError.alreadyEnded
        }
        if !records.isEmpty {
            return .record(records.removeFirst())
        }
        ended = true
        return .endOfStream
    }

    func cancel() {
        ended = true
        records.removeAll()
    }
}

private struct JournaldSemanticStub: DockerSemanticServicing {
    func matchRegularExpression(
        pattern: Data,
        candidates: [Data],
        timeout: Duration
    ) throws -> [Bool] {
        let source = String(decoding: pattern, as: UTF8.self)
        guard source == "^io\\." else {
            throw DockerSemanticHelperRemoteError(
                category: .parse,
                messageBytes: Data("invalid test expression".utf8)
            )
        }
        return candidates.map {
            String(decoding: $0, as: UTF8.self).hasPrefix("io.")
        }
    }

    func renderLogTemplate(
        template: Data,
        info: DockerLogTemplateInfo,
        configuration: [DockerSemanticBytePair],
        timeout: Duration
    ) throws -> Data {
        Data("rendered-tag".utf8)
    }

    func parseURL(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerParsedURL {
        throw JournaldProviderError.invalidTagTemplate("unused")
    }

    func parseFluentdAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerFluentdAddress {
        throw JournaldProviderError.invalidTagTemplate("unused")
    }

    func parseGELFAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerGELFAddress {
        throw JournaldProviderError.invalidTagTemplate("unused")
    }

    func parseSyslogAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerSyslogAddress {
        throw JournaldProviderError.invalidTagTemplate("unused")
    }
}
