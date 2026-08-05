//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineService
import ContainerLoggingStorage
import ContainerPersistence
import ContainerResource
import Darwin
import Foundation
import Security
import Testing

@testable import ContainerAPIService

struct LoggingHandoffControlResponderTests {
    @Test
    func `gateway coordinator aborts and compensates staged logging with exact replay`() async throws {
        let fixture = try LoggingPartStageFixture(
            preloadDestinationObject: false
        )
        defer { fixture.cleanup() }

        let evidence = try await fixture.gatewayAbort()

        #expect(
            evidence.terminal.gatewayState.transactions[0].token.phase
                == .aborted
        )
        #expect(evidence.terminal == evidence.replayedTerminal)
        #expect(evidence.counts.compensate == 2)
        #expect(evidence.loggingStagingState == .compensated)
        #expect(try fixture.protectedObjectCount() == 0)
    }

    @Test
    func `gateway coordinator transfers, promotes, and activates logging exactly once`() async throws {
        let fixture = try LoggingPartStageFixture(
            preloadDestinationObject: false,
            gatewayHistory: true
        )
        defer { fixture.cleanup() }

        let evidence = try await fixture.gatewayCutover()

        #expect(
            evidence.terminal.gatewayState.transactions[0].token.phase
                == .complete
        )
        #expect(evidence.terminal == evidence.replayedTerminal)
        #expect(evidence.destinationObject.state == .verified)
        #expect(evidence.counts.destinationPossession == 2)
        #expect(evidence.counts.sourceExport == 2)
        #expect(evidence.counts.sourceSign == 1)
        #expect(evidence.counts.objectRead > 0)
        #expect(evidence.counts.stage == 1)
        #expect(evidence.counts.promote == 1)
        #expect(evidence.counts.activate == 2)
        #expect(
            evidence.publicHistory.importedPayloads
                == [
                    Data("before-cutover-1\n".utf8),
                    Data("before-cutover-2\n".utf8),
                ]
        )
        #expect(
            evidence.publicHistory.payloadsAfterWriter
                == [
                    Data("before-cutover-1\n".utf8),
                    Data("before-cutover-2\n".utf8),
                    Data("after-cutover\n".utf8),
                ]
        )
        #expect(evidence.publicHistory.writerReservation.historyEpoch == 8)
        #expect(evidence.publicHistory.writerReservation.lowerBound == 42)
        #expect(await fixture.promotedEffectCount() == 1)
        #expect(await fixture.activatedEffectCount() == 1)
    }

    @Test
    func `source exports once, replays exactly, and signs only its durable contribution`() async throws {
        let fixture = try LoggingPartStageFixture()
        defer { fixture.cleanup() }

        let export = try fixture.sourceExportControlRequest()
        let first = await fixture.sourceResponder.respond(
            to: export.request,
            body: export.body,
            context: fixture.sourceControlContext
        )
        #expect(first.response.disposition == .completed)
        #expect(
            first.response.bodyMediaType
                == ProviderHandoffSourceControlCodec.contributionMediaType
        )
        #expect(first.body.range(of: Data("secret-value".utf8)) == nil)
        let contribution =
            try ProviderHandoffSourceControlCodec
            .decodeContribution(first.body)
        #expect(contribution.part.kind == .logging)
        #expect(contribution.sourceObjectRecord.state == .verified)

        let replay = await fixture.sourceResponder.respond(
            to: export.request,
            body: export.body,
            context: fixture.sourceControlContext
        )
        #expect(replay.response.disposition == .completed)
        #expect(replay.body == first.body)

        let signing = try fixture.sourceSignControlRequest(
            contribution: contribution
        )
        let signed = await fixture.sourceResponder.respond(
            to: signing.request,
            body: signing.body,
            context: fixture.sourceControlContext
        )
        #expect(signed.response.disposition == .completed)
        let receipt =
            try ProviderHandoffSourceControlCodec
            .decodeSignReceipt(signed.body)
        #expect(
            receipt.contributionDigestSHA256
                == contribution.contributionDigestSHA256
        )
        try fixture.verifySourceSignature(receipt)

        let changed = try fixture.sourceSignControlRequest(
            contribution: contribution,
            mutateManifest: { manifest in
                manifest.parts[0].requiredCapabilities.append("logging.changed")
            }
        )
        let rejected = await fixture.sourceResponder.respond(
            to: changed.request,
            body: changed.body,
            context: fixture.sourceControlContext
        )
        #expect(rejected.response.disposition == .rejected)
        #expect(rejected.body.isEmpty)
    }

    @Test
    func `provider stages signed logging payload and replays bounded receipt`() async throws {
        let fixture = try LoggingPartStageFixture()
        defer { fixture.cleanup() }

        let first = await fixture.responder.respond(
            to: fixture.controlRequest,
            body: fixture.requestBody,
            context: fixture.controlContext
        )
        #expect(first.response.disposition == .completed)
        #expect(
            first.response.bodyMediaType
                == ProviderHandoffPartControlCodec.stageReceiptMediaType
        )
        let receipt = try ProviderHandoffPartControlCodec.decodeStageReceipt(
            first.body
        )
        #expect(receipt.commonRecord.state == .imported)
        #expect(receipt.commonRecord.partKind == .logging)
        #expect(receipt.commonRecord.stagedImportReceiptDigestSHA256 != nil)
        #expect(first.body.range(of: Data("secret-value".utf8)) == nil)
        #expect(first.body.range(of: Data("source-protected-object".utf8)) == nil)
        #expect(try fixture.protectedObjectCount() == 1)

        let replay = await fixture.responder.respond(
            to: fixture.controlRequest,
            body: fixture.requestBody,
            context: fixture.controlContext
        )
        #expect(replay.response.disposition == .completed)
        #expect(replay.body == first.body)
        #expect(try fixture.protectedObjectCount() == 1)
    }

    @Test
    func `provider rejects a bootstrap not bound to authenticated gateway peer`() async throws {
        let fixture = try LoggingPartStageFixture()
        defer { fixture.cleanup() }
        let wrongContext = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: fixture.controlContext.providerFingerprint,
            authenticatedGatewayCodeIdentity: ProviderHandoffCodeIdentityV1(
                signingIdentifier: fixture.controlContext
                    .authenticatedGatewayCodeIdentity.signingIdentifier,
                teamIdentifier: fixture.controlContext
                    .authenticatedGatewayCodeIdentity.teamIdentifier,
                designatedRequirementDigestSHA256: String(
                    repeating: "f",
                    count: 64
                )
            )
        )

        let result = await fixture.responder.respond(
            to: fixture.controlRequest,
            body: fixture.requestBody,
            context: wrongContext
        )
        #expect(result.response.disposition == .rejected)
        #expect(result.body.isEmpty)
        #expect(try fixture.protectedObjectCount() == 0)
    }

    @Test
    func `provider promotes and activates only signed gateway transaction`() async throws {
        let fixture = try LoggingPartStageFixture()
        defer { fixture.cleanup() }
        let staged = try await fixture.stage()
        let reconciliation = try fixture.reconciliation(
            importedRecord: staged.commonRecord
        )

        let promote = try fixture.controlRequest(
            operation: .partPromote,
            mediaType: ProviderHandoffPartControlCodec.promoteRequestMediaType,
            body: ProviderHandoffPartControlCodec.encodePromoteRequest(
                ProviderHandoffPartPromoteRequestV1(
                    stage: fixture.stageRequest,
                    commitRecord: reconciliation.commitRecord,
                    gatewayState: reconciliation.gatewayState
                )
            )
        )
        let promoted = await fixture.responder.respond(
            to: promote.request,
            body: promote.body,
            context: fixture.controlContext
        )
        #expect(promoted.response.disposition == .completed)
        let opaque =
            try ProviderHandoffPartControlCodec
            .decodePromotionReceipt(promoted.body)
        #expect(opaque.partKind == .logging)
        #expect(
            opaque.mediaType == LoggingHandoffPromotionControlCodec.mediaType
        )
        #expect(promoted.body.range(of: Data("secret-value".utf8)) == nil)
        #expect(await fixture.promotedEffectCount() == 1)

        let complete = try fixture.complete(
            reconciliation: reconciliation,
            promotionReceipt: try LoggingHandoffPromotionControlCodec.decode(
                opaque.body
            )
        )
        let activate = try fixture.controlRequest(
            operation: .partActivate,
            mediaType: ProviderHandoffPartControlCodec.activateRequestMediaType,
            body: ProviderHandoffPartControlCodec.encodeActivateRequest(
                ProviderHandoffPartActivateRequestV1(
                    stage: fixture.stageRequest,
                    commitRecord: reconciliation.commitRecord,
                    terminalOutcome: complete.outcome,
                    gatewayState: complete.gatewayState,
                    promotionReceipt: opaque
                )
            )
        )
        let activated = await fixture.responder.respond(
            to: activate.request,
            body: activate.body,
            context: fixture.controlContext
        )
        #expect(activated.response.disposition == .completed)
        let activationReceipt =
            try ProviderHandoffPartControlCodec
            .decodeOperationReceipt(activated.body)
        #expect(activationReceipt.operation == .activate)
        #expect(
            activationReceipt.evidenceDigestSHA256
                == complete.outcome.outcomeDigestSHA256
        )
        #expect(await fixture.activatedEffectCount() == 1)
    }

    @Test
    func `provider compensates signed abort and replays exact receipt`() async throws {
        let fixture = try LoggingPartStageFixture()
        defer { fixture.cleanup() }
        let staged = try await fixture.stage()
        let aborted = try fixture.aborted(
            importedRecord: staged.commonRecord
        )
        let compensate = try fixture.controlRequest(
            operation: .partCompensate,
            mediaType:
                ProviderHandoffPartControlCodec.compensateRequestMediaType,
            body: ProviderHandoffPartControlCodec.encodeCompensateRequest(
                ProviderHandoffPartCompensateRequestV1(
                    stage: fixture.stageRequest,
                    terminalOutcome: aborted.outcome,
                    gatewayState: aborted.gatewayState
                )
            )
        )

        let first = await fixture.responder.respond(
            to: compensate.request,
            body: compensate.body,
            context: fixture.controlContext
        )
        #expect(first.response.disposition == .completed)
        let receipt =
            try ProviderHandoffPartControlCodec
            .decodeOperationReceipt(first.body)
        #expect(receipt.operation == .compensate)
        #expect(receipt.evidenceDigestSHA256 == aborted.outcome.outcomeDigestSHA256)
        #expect(try fixture.protectedObjectCount() == 0)

        let replay = await fixture.responder.respond(
            to: compensate.request,
            body: compensate.body,
            context: fixture.controlContext
        )
        #expect(replay.response.disposition == .completed)
        #expect(replay.body == first.body)
        #expect(try fixture.protectedObjectCount() == 0)
    }
}

private struct LoggingPartReconciliation {
    let commitRecord: ProviderHandoffCommitRecordV1
    let gatewayState: ProviderHandoffGatewayStateV1
}

private struct LoggingPartTerminalState {
    let outcome: ProviderHandoffTerminalOutcomeV1
    let gatewayState: ProviderHandoffGatewayStateV1
}

private struct LoggingGatewayCutoverEvidence: Sendable {
    let terminal: ProviderHandoffGatewayTerminalResultV1
    let replayedTerminal: ProviderHandoffGatewayTerminalResultV1
    let destinationObject: ProviderHandoffBundleObjectRecordV1
    let counts: LoggingGatewayTransport.Counts
    let publicHistory: LoggingGatewayPublicHistoryEvidence
}

private struct LoggingGatewayAbortEvidence: Sendable {
    let terminal: ProviderHandoffGatewayTerminalResultV1
    let replayedTerminal: ProviderHandoffGatewayTerminalResultV1
    let counts: LoggingGatewayTransport.Counts
    let loggingStagingState: ProviderHandoffPartStagingStateV1
}

private struct LoggingGatewayStagedContext: Sendable {
    let coordinator: ProviderHandoffGatewayCoordinator
    let destinationEndpoint: ProviderHandoffGatewayProviderEndpointV1
    let transport: LoggingGatewayTransport
    let token: ProviderHandoffTokenV1
    let contribution: ProviderHandoffSourceContributionV1
    let staged: ProviderHandoffGatewayStageResultV1
}

private struct LoggingGatewayPublicHistoryEvidence: Sendable {
    let importedPayloads: [Data]
    let payloadsAfterWriter: [Data]
    let writerReservation: ContainerLogSequenceReservationV1
}

private struct LoggingGatewayCommit: Sendable {
    let validated: ProviderHandoffValidatedCommitRecordV1
    let prepares: [ProviderHandoffRootPrepareRecordV1]
}

private actor LoggingGatewayTransport:
    ProviderHandoffGatewayControlTransport
{
    struct Counts: Equatable, Sendable {
        var activate = 0
        var compensate = 0
        var destinationPossession = 0
        var objectRead = 0
        var promote = 0
        var sourceExport = 0
        var sourceSign = 0
        var stage = 0
    }

    private let codeIdentity: ProviderHandoffCodeIdentityV1
    private let destination: ProviderHandoffGatewayProviderEndpointV1
    private let destinationService: ContainerEngineProviderHandoffControlService
    private let source: ProviderHandoffGatewayProviderEndpointV1
    private let sourceService: ContainerEngineProviderHandoffControlService
    private var operationCounts = Counts()

    init(
        source: ProviderHandoffGatewayProviderEndpointV1,
        destination: ProviderHandoffGatewayProviderEndpointV1,
        sourceStore: ProviderHandoffBundleObjectStore,
        destinationStore: ProviderHandoffBundleObjectStore,
        sourceResponder: LoggingHandoffSourceControlResponder,
        destinationResponder: LoggingHandoffControlResponder,
        destinationIdentity: ProviderHandoffProviderIdentityV1,
        destinationPossessionStore: ProviderHandoffPossessionProofStore,
        codeIdentity: ProviderHandoffCodeIdentityV1
    ) {
        self.source = source
        self.destination = destination
        self.codeIdentity = codeIdentity
        sourceService = ContainerEngineProviderHandoffControlService(
            objectStore: sourceStore,
            downstream: sourceResponder
        )
        destinationService = ContainerEngineProviderHandoffControlService(
            objectStore: destinationStore,
            downstream: ContainerEngineProviderIdentityControlResponder(
                identity: destinationIdentity,
                possessionProofStore: destinationPossessionStore,
                downstream: destinationResponder
            )
        )
    }

    func counts() -> Counts {
        operationCounts
    }

    func perform(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        switch request.operation {
        case .destinationKeyPossession:
            operationCounts.destinationPossession += 1
        case .objectRead:
            operationCounts.objectRead += 1
        case .partActivate:
            let value =
                try ProviderHandoffPartControlCodec
                .decodeActivateRequest(body)
            if value.stage.partKind != .logging {
                return try Self.activate(request, value: value)
            }
            operationCounts.activate += 1
        case .partCompensate:
            let value =
                try ProviderHandoffPartControlCodec
                .decodeCompensateRequest(body)
            if value.stage.partKind != .logging {
                return try Self.compensate(request, value: value)
            }
            operationCounts.compensate += 1
        case .partExport:
            operationCounts.sourceExport += 1
        case .partPromote:
            let value =
                try ProviderHandoffPartControlCodec
                .decodePromoteRequest(body)
            if value.stage.partKind != .logging {
                return try Self.promote(request, value: value)
            }
            operationCounts.promote += 1
        case .partStage:
            let value =
                try ProviderHandoffPartControlCodec
                .decodeStageRequest(body)
            if value.partKind != .logging {
                return try Self.stage(request, value: value)
            }
            operationCounts.stage += 1
        case .sourceSignManifest:
            operationCounts.sourceSign += 1
        case .destinationKeySnapshot, .objectAppend, .objectDeclare,
            .objectVerify, .rootApply, .rootPrepare,
            .rootRelease, .rootSnapshot:
            break
        }
        let context = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: endpoint.fingerprint,
            authenticatedGatewayCodeIdentity: codeIdentity
        )
        if endpoint == source {
            return await sourceService.respond(
                to: request,
                body: body,
                context: context
            )
        }
        guard endpoint == destination else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return await destinationService.respond(
            to: request,
            body: body,
            context: context
        )
    }

    private static func stage(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        value: ProviderHandoffPartStageRequestV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        let part = try #require(
            value.manifest.parts.first { $0.kind == value.partKind }
        )
        var record = try ProviderHandoffPartStagingStateMachine.declared(
            tokenID: value.manifest.tokenID,
            manifestID: value.manifest.manifestID,
            manifestDigest: value.manifest.manifestDigest,
            partKind: value.partKind,
            bundleObjectID: part.payload.bundleObjectID,
            payloadDescriptorDigestSHA256:
                ProviderHandoffProjections.payloadDescriptorDigest(
                    part.payload
                )
        )
        try ProviderHandoffPartStagingStateMachine.beginRetrieval(
            &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
            [
                ProviderHandoffByteRangeV1(
                    lowerBound: 0,
                    upperBoundExclusive: part.payload.transportByteLength
                )
            ],
            transportByteLength: part.payload.transportByteLength,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
            transportDigestSHA256: part.payload.transportDigestSHA256,
            transportByteLength: part.payload.transportByteLength,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordContentVerified(
            canonicalContentDigest: part.payload.canonicalContentDigest.digest,
            sourceDigestVerifications: [],
            protection: .authenticatedPlaintext,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordImported(
            receiptDigestSHA256: ProviderHandoffDigest.sha256(
                Data("empty:\(value.partKind.rawValue)".utf8)
            ),
            in: &record,
            expectedRevision: record.stagingRevision
        )
        return try result(
            requestID: request.requestID,
            body: ProviderHandoffPartControlCodec.encodeStageReceipt(
                ProviderHandoffPartStageReceiptV1(commonRecord: record)
            ),
            mediaType: ProviderHandoffPartControlCodec.stageReceiptMediaType
        )
    }

    private static func promote(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        value: ProviderHandoffPartPromoteRequestV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try result(
            requestID: request.requestID,
            body: ProviderHandoffPartControlCodec.encodePromotionReceipt(
                ProviderHandoffPartOpaqueControllerReceiptV1(
                    partKind: value.stage.partKind,
                    mediaType: "application/x.container-empty-handoff",
                    body: Data(value.stage.partKind.rawValue.utf8)
                )
            ),
            mediaType:
                ProviderHandoffPartControlCodec.promotionReceiptMediaType
        )
    }

    private static func activate(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        value: ProviderHandoffPartActivateRequestV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try result(
            requestID: request.requestID,
            body: ProviderHandoffPartControlCodec.encodeOperationReceipt(
                ProviderHandoffPartOperationReceiptV1(
                    operation: .activate,
                    partKind: value.stage.partKind,
                    tokenID: value.stage.manifest.tokenID,
                    manifestID: value.stage.manifest.manifestID,
                    evidenceDigestSHA256:
                        value.terminalOutcome.outcomeDigestSHA256
                )
            ),
            mediaType:
                ProviderHandoffPartControlCodec.operationReceiptMediaType
        )
    }

    private static func compensate(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        value: ProviderHandoffPartCompensateRequestV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try result(
            requestID: request.requestID,
            body: ProviderHandoffPartControlCodec.encodeOperationReceipt(
                ProviderHandoffPartOperationReceiptV1(
                    operation: .compensate,
                    partKind: value.stage.partKind,
                    tokenID: value.stage.manifest.tokenID,
                    manifestID: value.stage.manifest.manifestID,
                    evidenceDigestSHA256:
                        value.terminalOutcome.outcomeDigestSHA256
                )
            ),
            mediaType:
                ProviderHandoffPartControlCodec.operationReceiptMediaType
        )
    }

    private static func result(
        requestID: String,
        body: Data,
        mediaType: String
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: .completed,
                bodyMediaType: mediaType,
                body: body
            ),
            body: body
        )
    }
}

private final class LoggingPartStageFixture: @unchecked Sendable {
    private static let sourceRoot =
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let destinationRoot =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private static let sourceLineage =
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private static let destinationLineage =
        "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private static let resultingLineage =
        "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private static let tokenID = "token-logging-stage-1"
    private static let manifestID = "manifest-logging-stage-1"
    private static let useTime: UInt64 = 1_800_000_000
    private static let trustRevision: UInt64 = 1

    let root: URL
    let keychainService: String
    let responder: LoggingHandoffControlResponder
    let sourceResponder: LoggingHandoffSourceControlResponder
    let controlRequest: ContainerEngineProviderHandoffControlRequestV1
    let requestBody: Data
    let controlContext: ContainerEngineProviderHandoffControlContextV1
    let sourceControlContext: ContainerEngineProviderHandoffControlContextV1
    let stageRequest: ProviderHandoffPartStageRequestV1

    private let codeIdentity: ProviderHandoffCodeIdentityV1
    private let commonStore: ProviderHandoffPartStagingStore
    private let destinationIdentity: ProviderHandoffProviderIdentityV1
    private let destinationFingerprint: ContainerEngineProviderFingerprint
    private let destinationExpectation: ProviderHandoffHeaderExpectationV1
    private let destinationObjectStore: ProviderHandoffBundleObjectStore
    private let exportContainer: LoggingHandoffExportContainerV1
    private let gatewayIdentity: ProviderHandoffGatewayIdentityV1
    private let manifest: ProviderHandoffManifestV1
    private let possessionStore: ProviderHandoffPossessionProofStore
    private let promoter: LoggingPartControlPromoter
    private let protectedRoot: URL
    private let sourceIdentity: ProviderHandoffProviderIdentityV1
    private let sourceExpectation: ProviderHandoffHeaderExpectationV1
    private let sourceExportRequest: ProviderHandoffPartExportRequestV1
    private let sourceFingerprint: ContainerEngineProviderFingerprint
    private let sourceObjectStore: ProviderHandoffBundleObjectStore
    private let sourceSigningKey: ProviderHandoffTrustKeyV1
    private let trustRegistryStore: ProviderHandoffTrustRegistryStore
    private let validatedManifest: ProviderHandoffValidatedManifestV1
    private let validatedTrustRegistry: ProviderHandoffValidatedTrustRegistryV1

    init(
        preloadDestinationObject: Bool = true,
        gatewayHistory: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logging-handoff-control-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        keychainService =
            "io.github.stephenlclarke.container.tests.\(UUID().uuidString.lowercased())"
        protectedRoot = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )

        codeIdentity = try ProviderHandoffCodeIdentity.current()
        let declaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "test",
            runtimeRevisions: ["container": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                try ContainerEngineProviderCapability(
                    identifier: "engine.handoff.part.logging.v1",
                    status: .native
                )
            ]
        )
        sourceFingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: try #require(UUID(uuidString: Self.sourceRoot))
        )
        destinationFingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: try #require(UUID(uuidString: Self.destinationRoot))
        )
        sourceIdentity = try Self.providerIdentity(
            fingerprint: sourceFingerprint,
            codeIdentity: codeIdentity,
            service: keychainService,
            account: "source"
        )
        destinationIdentity = try Self.providerIdentity(
            fingerprint: destinationFingerprint,
            codeIdentity: codeIdentity,
            service: keychainService,
            account: "destination"
        )
        let gatewayContext = ProviderHandoffGatewayKeyEnrollmentContextV1(
            owningBundleIdentifier: codeIdentity.signingIdentifier,
            codeRequirementDigestSHA256:
                codeIdentity.designatedRequirementDigestSHA256,
            teamIdentifier: codeIdentity.teamIdentifier,
            gatewayRegistrationDigestSHA256:
                try ProviderHandoffGatewayKeyEnrollmentContextV1
                .registrationDigest(codeIdentity: codeIdentity),
            enrolledAtUnixSeconds: Self.useTime - 10,
            notBeforeUnixSeconds: Self.useTime - 10,
            notAfterUnixSeconds: Self.useTime + 10
        )
        gatewayIdentity = try ProviderHandoffGatewayKeyStore(
            service: keychainService,
            account: "gateway"
        ).loadOrCreate(context: gatewayContext)
        let registry = try gatewayIdentity.makeTrustRegistry(
            providerKeys: sourceIdentity.trustKeys
                + destinationIdentity.trustKeys,
            registryRevision: Self.trustRevision,
            issuedAtUnixSeconds: Self.useTime
        )
        validatedTrustRegistry = registry
        trustRegistryStore = ProviderHandoffTrustRegistryStore(
            service: keychainService,
            account: "trust"
        )
        _ = try trustRegistryStore.install(
            registry.registry,
            bootstrap: gatewayIdentity.bootstrap
        )

        let proofStore = ProviderHandoffPossessionProofStore(
            root: root.appendingPathComponent("proofs", isDirectory: true)
        )
        let destinationProofStore =
            preloadDestinationObject
            ? proofStore
            : ProviderHandoffPossessionProofStore(
                root: root.appendingPathComponent(
                    "live-proofs",
                    isDirectory: true
                )
            )
        possessionStore = destinationProofStore
        let possessionDigests = try Self.possessionDigests(
            destinationIdentity: destinationIdentity,
            possessionStore: proofStore
        )
        let driver: LogDriverDescriptor
        if gatewayHistory {
            driver = BuiltinLogDriverDescriptors.jsonFile
        } else {
            driver = try Self.remoteDescriptor()
        }
        let catalogDescriptors =
            gatewayHistory
            ? BuiltinLogDriverDescriptors.current.descriptors
            : BuiltinLogDriverDescriptors.current.descriptors + [driver]
        exportContainer = try Self.exportContainer(
            driver: driver,
            includeHistory: gatewayHistory
        )
        let sourceLineageKey = Data(repeating: 0x41, count: 32)
        let destinationPayloadKey = try destinationIdentity.trustKey(
            for: .destinationPayloadEncryption
        )
        let preparedLogging = try LoggingHandoffPayloadCodec.prepareSealed(
            containers: [exportContainer],
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            sourceStateRootUUID: Self.sourceRoot,
            sourceAuthorityLineageUUID: Self.sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: sourceLineageKey,
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationKeyID: destinationPayloadKey.keyID,
            destinationPublicKey: destinationPayloadKey.rawPublicKey,
            nonce: Data(0x00...0x17),
            ephemeralPrivateKey: Data(repeating: 0x31, count: 32)
        )
        let destinationLineageKey = try destinationIdentity.trustKey(
            for: .destinationLineageKeyEncryption
        )
        let sourceEnvelope = try sourceIdentity.sealLineageKey(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: Self.sourceRoot,
                authorityLineageUUID: Self.sourceLineage,
                keyVersion: 7,
                rawHMACSHA256Key: sourceLineageKey
            ),
            envelopeID: "source-lineage",
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationKeyID: destinationLineageKey.keyID,
            destinationPublicKey: destinationLineageKey.rawPublicKey,
            nonce: Data(0x20...0x37),
            trustRegistryRevision: Self.trustRevision,
            ephemeralPrivateKey: Data(repeating: 0x32, count: 32)
        )
        let resultingEnvelope = try gatewayIdentity.sealLineageKey(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: nil,
                authorityLineageUUID: Self.resultingLineage,
                keyVersion: 2,
                rawHMACSHA256Key: Data(repeating: 0x42, count: 32)
            ),
            envelopeID: "resulting-lineage",
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationKeyID: destinationLineageKey.keyID,
            destinationPublicKey: destinationLineageKey.rawPublicKey,
            nonce: Data(0x40...0x57),
            trustRegistryRevision: Self.trustRevision,
            ephemeralPrivateKey: Data(repeating: 0x33, count: 32)
        )
        sourceExpectation = try Self.expectation(
            role: .source,
            root: Self.sourceRoot,
            lineage: Self.sourceLineage,
            stagedLineage: nil,
            provider: sourceFingerprint.digest,
            state: .sourceQuiesced,
            abortState: .destinationActive,
            snapshot: "source-checkpoint"
        )
        destinationExpectation = try Self.expectation(
            role: .destination,
            root: Self.destinationRoot,
            lineage: Self.destinationLineage,
            stagedLineage: Self.resultingLineage,
            provider: nil,
            state: .destinationStaged,
            abortState: .none,
            snapshot: nil
        )
        sourceSigningKey = try sourceIdentity.trustKey(
            for: .sourceManifestSigning
        )
        sourceExportRequest = ProviderHandoffPartExportRequestV1(
            partKind: .logging,
            bootstrap: gatewayIdentity.bootstrap,
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            trustRegistryRevision: Self.trustRevision,
            sourceProviderFingerprint: sourceFingerprint.digest,
            sourceStateRootUUID: Self.sourceRoot,
            authorityLineageUUID: Self.sourceLineage,
            lineageDigestKeyVersion: 7,
            sourcePreCommitExpectation: sourceExpectation,
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: destinationExpectation,
            destinationPayloadEncryptionKey: destinationPayloadKey,
            destinationLineageKeyEncryptionKey: destinationLineageKey,
            destinationKeyPossessionProofs: try possessionDigests.map {
                try proofStore.load($0)
            }.sorted {
                $0.destinationKeyPurpose.rawValue.utf8
                    .lexicographicallyPrecedes(
                        $1.destinationKeyPurpose.rawValue.utf8
                    )
            },
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            selectedResourceIDs: [exportContainer.containerID]
        )
        let parts = try ProviderHandoffPartKindV1.allCases.map { kind in
            let payload: ProviderHandoffPayloadDescriptorV1
            let requiredCapabilities: [String]
            if kind == .logging {
                payload = preparedLogging.descriptor
                requiredCapabilities = ["engine.handoff.part.logging.v1"]
            } else {
                payload = try ProviderHandoffPayloadCodec.prepareAuthenticated(
                    ProviderHandoffPayloadPackageV1(
                        partKind: kind,
                        entries: [
                            ProviderHandoffPayloadPackageEntryV1(
                                entryID: "evidence-\(kind.rawValue)",
                                sourceStateRootUUID: Self.sourceRoot,
                                recordKind: "handoff-evidence",
                                schemaVersion: 1,
                                canonicalRecordBytes: try ProviderHandoffCanonicalCBOR.encode(
                                    .map([
                                        .init(
                                            "disposition",
                                            .textString("included")
                                        )
                                    ]))
                            )
                        ]
                    ),
                    mediaType:
                        "application/vnd.io.github.stephenlclarke.container.handoff-part.v1+cbor",
                    sourceOrder: [Self.sourceRoot]
                ).descriptor
                requiredCapabilities = []
            }
            return ProviderHandoffPartV1(
                kind: kind,
                schemaVersion: 1,
                disposition: .included,
                sourceStateRootUUIDs: [Self.sourceRoot],
                requiredCapabilities: requiredCapabilities,
                payload: payload
            )
        }
        var manifest = ProviderHandoffManifestV1(
            manifestID: Self.manifestID,
            tokenID: Self.tokenID,
            trustRegistryRevision: Self.trustRevision,
            destinationKeyPossessionProofDigestsSHA256: possessionDigests,
            sources: [
                ProviderHandoffSourceV1(
                    providerFingerprint: sourceFingerprint.digest,
                    stateRootUUID: Self.sourceRoot,
                    authorityLineageUUID: Self.sourceLineage,
                    lineageDigestKeyVersion: 7,
                    preCommitExpectation: sourceExpectation,
                    sourceSignature: Self.placeholderSignature(
                        purpose: .sourceManifestSigning,
                        role: .sourceProvider,
                        provider: sourceFingerprint.digest,
                        root: Self.sourceRoot
                    )
                )
            ],
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            destinationSealedLineageKeyEnvelopes: [
                sourceEnvelope,
                resultingEnvelope,
            ],
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: destinationExpectation,
            parts: parts,
            manifestDigest: String(repeating: "0", count: 64),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorManifestSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        manifest.sources[0].sourceSignature = try sourceIdentity.sign(
            projectionDigestSHA256:
                try ProviderHandoffProjections
                .sourceManifestDigest(
                    source: manifest.sources[0],
                    manifest: manifest
                ),
            purpose: .sourceManifestSigning,
            trustRegistryRevision: Self.trustRevision
        )
        manifest.manifestDigest =
            try ProviderHandoffProjections
            .manifestDigest(manifest)
        manifest.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256: manifest.manifestDigest,
            purpose: .coordinatorManifestSigning,
            trustRegistryRevision: Self.trustRevision
        )
        validatedManifest = try ProviderHandoffRecordValidator.validateManifest(
            manifest,
            possessionProofs: try possessionDigests.map {
                try ProviderHandoffPossessionProofCodec
                    .validateDestinationReceipt(
                        proofStore.load($0),
                        trustRegistry: registry,
                        atUnixSeconds: Self.useTime
                    )
            },
            trustRegistry: registry,
            atUnixSeconds: Self.useTime
        )

        sourceObjectStore = ProviderHandoffBundleObjectStore(
            root: root.appendingPathComponent(
                "source-objects",
                isDirectory: true
            )
        )
        destinationObjectStore = ProviderHandoffBundleObjectStore(
            root: root.appendingPathComponent(
                "destination-objects",
                isDirectory: true
            )
        )
        try Self.publish(preparedLogging, to: sourceObjectStore)
        if preloadDestinationObject {
            try Self.publish(preparedLogging, to: destinationObjectStore)
        }

        commonStore = ProviderHandoffPartStagingStore(
            root: root.appendingPathComponent("common", isDirectory: true)
        )
        let stagingController = LoggingHandoffStagingController(
            defaults: LoggingConfig(),
            commonStore: commonStore,
            protectedOptionsStore: try LoggingProtectedOptionsStore(
                rootURL: protectedRoot
            ),
            receiptStore: try LoggingHandoffProtectedReceiptStore(
                rootURL: root.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                )
            )
        )
        promoter = try LoggingPartControlPromoter(
            root: root.appendingPathComponent(
                "public-containers",
                isDirectory: true
            )
        )
        let destination = try LoggingHandoffDestinationReconciler(
            rootURL: root.appendingPathComponent(
                "promotions",
                isDirectory: true
            ),
            containerPromoter: promoter
        )
        let destinationResponder = LoggingHandoffControlResponder(
            objectStore: destinationObjectStore,
            possessionProofStore: destinationProofStore,
            trustRegistryStore: trustRegistryStore,
            commonStore: commonStore,
            providerIdentity: destinationIdentity,
            stagingController: stagingController,
            destination: destination,
            stagingContext: {
                (
                    catalog: try LogDriverCatalog(
                        descriptors: catalogDescriptors
                    ),
                    occupiedContainerIDs: []
                )
            },
            nowUnixSeconds: { Self.useTime }
        )
        responder = destinationResponder
        let exportedContainer = exportContainer
        sourceResponder = LoggingHandoffSourceControlResponder(
            objectStore: sourceObjectStore,
            contributionStore: ProviderHandoffSourceContributionStore(
                root: root.appendingPathComponent(
                    "source-contributions",
                    isDirectory: true
                )
            ),
            lineageKeyStore: ProviderHandoffLineageKeyStore(
                service: keychainService,
                accountPrefix: "source-lineage"
            ),
            trustRegistryStore: trustRegistryStore,
            providerIdentity: sourceIdentity,
            exportContainers: { request in
                guard
                    request.selectedResourceIDs
                        == [exportedContainer.containerID]
                else {
                    throw LoggingHandoffSourceControlResponderError
                        .invalidRequest
                }
                return [exportedContainer]
            },
            nowUnixSeconds: { Self.useTime },
            downstream: ContainerEngineProviderHandoffControlService(
                objectStore: sourceObjectStore
            )
        )
        self.manifest = manifest
        stageRequest = ProviderHandoffPartStageRequestV1(
            partKind: .logging,
            bootstrap: gatewayIdentity.bootstrap,
            manifest: manifest
        )
        requestBody = try ProviderHandoffPartControlCodec.encodeStageRequest(
            stageRequest
        )
        controlRequest = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: "stage-logging-1",
            operation: .partStage,
            bodyMediaType:
                ProviderHandoffPartControlCodec.stageRequestMediaType,
            body: requestBody
        )
        controlContext = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: destinationFingerprint,
            authenticatedGatewayCodeIdentity: codeIdentity
        )
        sourceControlContext = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: sourceFingerprint,
            authenticatedGatewayCodeIdentity: codeIdentity
        )
    }

    func sourceExportControlRequest() throws -> (
        request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data
    ) {
        let body = try ProviderHandoffSourceControlCodec.encodeExportRequest(
            sourceExportRequest
        )
        return (
            try ContainerEngineProviderHandoffControlRequestV1(
                requestID: "export-logging-1",
                operation: .partExport,
                bodyMediaType:
                    ProviderHandoffSourceControlCodec.exportRequestMediaType,
                body: body
            ),
            body
        )
    }

    func sourceSignControlRequest(
        contribution: ProviderHandoffSourceContributionV1,
        mutateManifest: (inout ProviderHandoffManifestV1) -> Void = { _ in }
    ) throws -> (
        request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data
    ) {
        var candidate = ProviderHandoffManifestV1(
            manifestID: Self.manifestID,
            tokenID: Self.tokenID,
            trustRegistryRevision: Self.trustRevision,
            destinationKeyPossessionProofDigestsSHA256:
                contribution.destinationKeyPossessionProofDigestsSHA256,
            sources: [
                ProviderHandoffSourceV1(
                    providerFingerprint: sourceFingerprint.digest,
                    stateRootUUID: Self.sourceRoot,
                    authorityLineageUUID: Self.sourceLineage,
                    lineageDigestKeyVersion: 7,
                    preCommitExpectation: sourceExpectation,
                    sourceSignature: Self.placeholderSignature(
                        purpose: .sourceManifestSigning,
                        role: .sourceProvider,
                        provider: sourceFingerprint.digest,
                        root: Self.sourceRoot
                    )
                )
            ],
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            destinationSealedLineageKeyEnvelopes: [
                contribution.destinationSealedLineageKeyEnvelope
            ],
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: destinationExpectation,
            parts: [contribution.part],
            manifestDigest: String(repeating: "0", count: 64),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorManifestSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        mutateManifest(&candidate)
        let body = try ProviderHandoffSourceControlCodec.encodeSignRequest(
            ProviderHandoffSourceManifestSignRequestV1(
                bootstrap: gatewayIdentity.bootstrap,
                partKind: .logging,
                contributionDigestSHA256:
                    contribution.contributionDigestSHA256,
                candidateManifest: candidate
            )
        )
        return (
            try ContainerEngineProviderHandoffControlRequestV1(
                requestID: "source-sign-logging-1",
                operation: .sourceSignManifest,
                bodyMediaType:
                    ProviderHandoffSourceControlCodec.signRequestMediaType,
                body: body
            ),
            body
        )
    }

    func verifySourceSignature(
        _ receipt: ProviderHandoffSourceManifestSignReceiptV1
    ) throws {
        try ProviderHandoffCrypto.verify(
            receipt.sourceSignature,
            publicKey: sourceSigningKey.rawPublicKey
        )
    }

    func stage() async throws -> ProviderHandoffPartStageReceiptV1 {
        let result = await responder.respond(
            to: controlRequest,
            body: requestBody,
            context: controlContext
        )
        guard result.response.disposition == .completed else {
            throw ContainerEngineProviderSessionError.providerFailure(
                result.response.message ?? "logging stage failed"
            )
        }
        return try ProviderHandoffPartControlCodec.decodeStageReceipt(
            result.body
        )
    }

    private func prepareGatewayStage() async throws
        -> LoggingGatewayStagedContext
    {
        let sourceEndpoint = ProviderHandoffGatewayProviderEndpointV1(
            socketPath: "source",
            fingerprint: sourceFingerprint
        )
        let destinationEndpoint = ProviderHandoffGatewayProviderEndpointV1(
            socketPath: "destination",
            fingerprint: destinationFingerprint
        )
        let transport = LoggingGatewayTransport(
            source: sourceEndpoint,
            destination: destinationEndpoint,
            sourceStore: sourceObjectStore,
            destinationStore: destinationObjectStore,
            sourceResponder: sourceResponder,
            destinationResponder: responder,
            destinationIdentity: destinationIdentity,
            destinationPossessionStore: possessionStore,
            codeIdentity: codeIdentity
        )
        let gatewayStore = ProviderHandoffGatewayStore(
            root: root.appendingPathComponent("gateway", isDirectory: true)
        )
        let selection = try selectionTransition()
        let socket = try socketTransition()
        _ = try gatewayStore.loadOrCreate(
            initial: try ProviderHandoffGatewayStateMachine.initialState(
                providerSelection: selection.expectedRecord,
                socketDiscovery: socket.expectedRecord
            )
        )
        let coordinator = ProviderHandoffGatewayCoordinator(
            store: gatewayStore,
            bootstrap: gatewayIdentity.bootstrap,
            manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1(
                gatewayIdentity: gatewayIdentity,
                trustRegistryStore: trustRegistryStore,
                possessionProofStore: ProviderHandoffPossessionProofStore(
                    root: root.appendingPathComponent(
                        "gateway-proofs",
                        isDirectory: true
                    )
                ),
                transactionSecretStore:
                    ProviderHandoffGatewayTransactionSecretStore(
                        service: keychainService,
                        accountPrefix: "gateway-secret"
                    ),
                nowUnixSeconds: { Self.useTime }
            ),
            transport: transport
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: Self.trustRevision,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: Self.manifestID
        )
        _ = try await coordinator.begin(token)
        _ = try await coordinator.quiesce(
            tokenID: token.tokenID,
            expectations: [sourceExpectation, destinationExpectation]
        )
        let possession =
            try await coordinator
            .proveDestinationKeyPossession(
                tokenID: token.tokenID,
                destination: destinationEndpoint
            )
        let exportRequest = ProviderHandoffPartExportRequestV1(
            partKind: .logging,
            bootstrap: gatewayIdentity.bootstrap,
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            trustRegistryRevision: Self.trustRevision,
            sourceProviderFingerprint: sourceFingerprint.digest,
            sourceStateRootUUID: Self.sourceRoot,
            authorityLineageUUID: Self.sourceLineage,
            lineageDigestKeyVersion: 7,
            sourcePreCommitExpectation: sourceExpectation,
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: destinationExpectation,
            destinationPayloadEncryptionKey: possession.payloadEncryptionKey,
            destinationLineageKeyEncryptionKey:
                possession.lineageEncryptionKey,
            destinationKeyPossessionProofs: possession.proofs,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            selectedResourceIDs: [exportContainer.containerID]
        )
        let contribution = try await coordinator.exportPart(
            exportRequest,
            source: sourceEndpoint
        )
        let replayedContribution = try await coordinator.exportPart(
            exportRequest,
            source: sourceEndpoint
        )
        guard contribution == replayedContribution else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        var parts: [ProviderHandoffPartV1] = []
        for kind in ProviderHandoffPartKindV1.allCases {
            if kind == .logging {
                parts.append(contribution.part)
                continue
            }
            let payload =
                try ProviderHandoffPayloadCodec
                .prepareAuthenticated(
                    ProviderHandoffPayloadPackageV1(
                        partKind: kind,
                        entries: [
                            ProviderHandoffPayloadPackageEntryV1(
                                entryID: "empty-\(kind.rawValue)",
                                sourceStateRootUUID: Self.sourceRoot,
                                recordKind: "empty-controller-evidence",
                                schemaVersion: 1,
                                canonicalRecordBytes:
                                    ProviderHandoffCanonicalCBOR.encode(
                                        .map([
                                            .init(
                                                "disposition",
                                                .textString("empty")
                                            )
                                        ])
                                    )
                            )
                        ]
                    ),
                    mediaType:
                        "application/vnd.io.github.stephenlclarke.container.handoff-empty.v1+cbor",
                    sourceOrder: [Self.sourceRoot]
                )
            try Self.publish(payload, to: sourceObjectStore)
            parts.append(
                ProviderHandoffPartV1(
                    kind: kind,
                    schemaVersion: 1,
                    disposition: .empty,
                    sourceStateRootUUIDs: [],
                    requiredCapabilities: [],
                    payload: payload.descriptor
                )
            )
        }
        let assembly = try await coordinator.assembleAndBindManifest(
            tokenID: token.tokenID,
            parts: parts,
            contributions: [contribution],
            sourceEndpoints: [Self.sourceRoot: sourceEndpoint],
            destinationPossession: possession
        )
        let replayedAssembly = try await coordinator.assembleAndBindManifest(
            tokenID: token.tokenID,
            parts: parts,
            contributions: [contribution],
            sourceEndpoints: [Self.sourceRoot: sourceEndpoint],
            destinationPossession: possession
        )
        guard
            replayedAssembly.validatedManifest.manifest
                == assembly.validatedManifest.manifest
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let sources = ProviderHandoffPartKindV1.allCases.map {
            ProviderHandoffGatewayPartSourceV1(
                partKind: $0,
                endpoint: sourceEndpoint
            )
        }
        let staged = try await coordinator.stage(
            assembly.validatedManifest,
            sources: sources,
            destination: destinationEndpoint
        )
        let replayedStage = try await coordinator.stage(
            assembly.validatedManifest,
            sources: sources,
            destination: destinationEndpoint
        )
        guard replayedStage.importedParts == staged.importedParts else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return LoggingGatewayStagedContext(
            coordinator: coordinator,
            destinationEndpoint: destinationEndpoint,
            transport: transport,
            token: token,
            contribution: contribution,
            staged: staged
        )
    }

    func gatewayCutover() async throws -> LoggingGatewayCutoverEvidence {
        let prepared = try await prepareGatewayStage()
        let coordinator = prepared.coordinator
        let destinationEndpoint = prepared.destinationEndpoint
        let transport = prepared.transport
        let token = prepared.token
        let contribution = prepared.contribution
        let staged = prepared.staged
        let commit = try gatewayCommit(state: staged.gatewayState)
        for prepare in commit.prepares {
            _ = try await coordinator.recordPreparedRoot(prepare)
        }
        _ = try await coordinator.commit(commit.validated)
        _ = try await coordinator.beginReconciliation(tokenID: token.tokenID)
        let promotion = try await coordinator.promote(
            tokenID: token.tokenID,
            destination: destinationEndpoint
        )
        let replayedPromotion = try await coordinator.promote(
            tokenID: token.tokenID,
            destination: destinationEndpoint
        )
        guard replayedPromotion.receipts == promotion.receipts else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let opaque = try #require(
            promotion.receipts.first { $0.partKind == .logging }
        )
        let loggingReceipt = try LoggingHandoffPromotionControlCodec.decode(
            opaque.body
        )
        let outcome = try completeOutcome(
            commitRecord: commit.validated.record,
            promotionReceipt: loggingReceipt
        )
        let terminal = try await coordinator.completeAndActivate(
            outcome,
            destination: destinationEndpoint
        )
        let replayedTerminal = try await coordinator.completeAndActivate(
            outcome,
            destination: destinationEndpoint
        )
        let publicHistory = try await promoter.provePublicHistoryAndWriter(
            containerID: exportContainer.containerID
        )
        return LoggingGatewayCutoverEvidence(
            terminal: terminal,
            replayedTerminal: replayedTerminal,
            destinationObject: try destinationObjectStore.load(
                bundleObjectID: contribution.part.payload.bundleObjectID
            ),
            counts: await transport.counts(),
            publicHistory: publicHistory
        )
    }

    func gatewayAbort() async throws -> LoggingGatewayAbortEvidence {
        let prepared = try await prepareGatewayStage()
        let outcome = try abortOutcome(state: prepared.staged.gatewayState)
        let terminal = try await prepared.coordinator.abortAndCompensate(
            outcome,
            destination: prepared.destinationEndpoint
        )
        let restartedCoordinator = restartedGatewayCoordinator(
            transport: prepared.transport
        )
        let replayedTerminal =
            try await restartedCoordinator.abortAndCompensate(
                outcome,
                destination: prepared.destinationEndpoint
            )
        return LoggingGatewayAbortEvidence(
            terminal: terminal,
            replayedTerminal: replayedTerminal,
            counts: await prepared.transport.counts(),
            loggingStagingState: try commonStore.load(
                tokenID: Self.tokenID,
                manifestID: Self.manifestID,
                partKind: .logging
            ).state
        )
    }

    private func restartedGatewayCoordinator(
        transport: LoggingGatewayTransport
    ) -> ProviderHandoffGatewayCoordinator {
        ProviderHandoffGatewayCoordinator(
            store: ProviderHandoffGatewayStore(
                root: root.appendingPathComponent(
                    "gateway",
                    isDirectory: true
                )
            ),
            bootstrap: gatewayIdentity.bootstrap,
            manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1(
                gatewayIdentity: gatewayIdentity,
                trustRegistryStore: trustRegistryStore,
                possessionProofStore: ProviderHandoffPossessionProofStore(
                    root: root.appendingPathComponent(
                        "gateway-proofs",
                        isDirectory: true
                    )
                ),
                transactionSecretStore:
                    ProviderHandoffGatewayTransactionSecretStore(
                        service: keychainService,
                        accountPrefix: "gateway-secret"
                    ),
                nowUnixSeconds: { Self.useTime }
            ),
            transport: transport
        )
    }

    func controlRequest(
        operation: ContainerEngineProviderHandoffOperationV1,
        mediaType: String,
        body: Data
    ) throws -> (
        request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data
    ) {
        (
            try ContainerEngineProviderHandoffControlRequestV1(
                requestID: "\(operation.rawValue)-logging-1",
                operation: operation,
                bodyMediaType: mediaType,
                body: body
            ),
            body
        )
    }

    private func gatewayCommit(
        state: ProviderHandoffGatewayStateV1
    ) throws -> LoggingGatewayCommit {
        let transaction = try #require(state.transactions.first)
        let manifest = try #require(transaction.manifest)
        let imported = try #require(transaction.token.importedParts)
        let intent = ProviderHandoffCommitIntentV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            trustRegistryRevision: Self.trustRevision,
            authoritativeCommitRevision:
                state.authoritativeCommitRevision + 1,
            preCommitRootExpectations:
                transaction.token.preCommitRootExpectations,
            importedParts: imported,
            destinationKeyPossessionProofDigestsSHA256:
                manifest.destinationKeyPossessionProofDigestsSHA256,
            providerSelection: try selectionTransition(),
            socketSelection: try socketTransition(),
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            resultingMinimumWriterSchemaVersion: 1
        )
        let commitDigest =
            try ProviderHandoffProjections
            .commitIntentDigest(intent)
        let chainHead = try ProviderHandoffProjections.chainHeadDigest(
            commitDigestSHA256: commitDigest,
            orderedPreCommitHeaders:
                intent.preCommitRootExpectations.map(\.expectedHeader)
        )
        let postRoots =
            try ProviderHandoffRecordValidator
            .derivePostCommitRoots(
                intent: intent,
                chainHeadDigestSHA256: chainHead
            )
        let prepares = zip(
            intent.preCommitRootExpectations,
            postRoots
        ).map { expectation, post in
            ProviderHandoffRootPrepareRecordV1(
                tokenID: Self.tokenID,
                manifestID: Self.manifestID,
                role: expectation.role,
                stateRootUUID: expectation.stateRootUUID,
                commitDigestSHA256: commitDigest,
                expectedHeaderDigestSHA256:
                    expectation.expectedHeaderDigestSHA256,
                preCommitRevisionVectorDigestSHA256:
                    expectation.preCommitRevisionVector
                    .revisionVectorDigestSHA256,
                postCommitHeaderDigestSHA256:
                    post.postCommitHeaderDigestSHA256,
                postCommitRevisionVectorDigestSHA256:
                    post.postCommitRevisionVector
                    .revisionVectorDigestSHA256,
                prepareRevision: 1
            )
        }
        var record = try ProviderHandoffCommitRecordV1(
            intent: intent,
            commitDigestSHA256: commitDigest,
            handoffChainHeadDigestSHA256: chainHead,
            postCommitRoots: postRoots,
            rootPrepareRecordDigestsSHA256:
                prepares.map(ProviderHandoffProjections.rootPrepareDigest),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorCommitSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        record.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256:
                try ProviderHandoffProjections.commitRecordDigest(record),
            purpose: .coordinatorCommitSigning,
            trustRegistryRevision: Self.trustRevision
        )
        return LoggingGatewayCommit(
            validated:
                try ProviderHandoffRecordValidator
                .validateCommitRecord(
                    record,
                    trustRegistry: validatedTrustRegistry,
                    atUnixSeconds: Self.useTime
                ),
            prepares: prepares
        )
    }

    private func completeOutcome(
        commitRecord: ProviderHandoffCommitRecordV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1
    ) throws -> ProviderHandoffValidatedTerminalOutcomeV1 {
        var roots: [ProviderHandoffTerminalRootV1] = []
        for (index, post) in commitRecord.postCommitRoots.enumerated() {
            var header = post.postCommitHeader
            var vector = post.postCommitRevisionVector
            header.activeHandoffTokenID = nil
            if index == commitRecord.postCommitRoots.count - 1 {
                header.handoffState = .destinationActive
                header.stagedAuthorityLineageUUID = nil
                header.writerEpoch += 1
                vector.rootStoreRevision += 1
                vector.controllerRevisions = [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: promotionReceipt.controllerRevision,
                        canonicalStateDigestSHA256:
                            promotionReceipt.controllerStateDigestSHA256
                    )
                ]
                vector.revisionVectorDigestSHA256 =
                    try ProviderHandoffProjections.revisionVectorDigest(vector)
            }
            roots.append(
                ProviderHandoffTerminalRootV1(
                    role: post.role,
                    stateRootUUID: post.stateRootUUID,
                    terminalHeader: header,
                    terminalHeaderDigestSHA256:
                        try ProviderHandoffProjections
                        .stateRootHeaderDigest(header),
                    terminalRevisionVector: vector
                )
            )
        }
        var outcome = ProviderHandoffTerminalOutcomeV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: commitRecord.intent.manifestDigest,
            phase: .complete,
            roots: roots,
            outcomeDigestSHA256: Self.digest("pending-complete"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        outcome.outcomeDigestSHA256 =
            try ProviderHandoffProjections.terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256: outcome.outcomeDigestSHA256,
            purpose: .coordinatorTerminalOutcomeSigning,
            trustRegistryRevision: Self.trustRevision
        )
        return try ProviderHandoffRecordValidator.validateTerminalOutcome(
            outcome,
            trustRegistry: validatedTrustRegistry,
            atUnixSeconds: Self.useTime
        )
    }

    private func abortOutcome(
        state: ProviderHandoffGatewayStateV1
    ) throws -> ProviderHandoffValidatedTerminalOutcomeV1 {
        let transaction = try #require(state.transactions.first)
        let boundManifest = try #require(transaction.manifest)
        let roots = transaction.token.preCommitRootExpectations.map {
            ProviderHandoffTerminalRootV1(
                role: $0.role,
                stateRootUUID: $0.stateRootUUID,
                terminalHeader: $0.abortHeader,
                terminalHeaderDigestSHA256: $0.abortHeaderDigestSHA256,
                terminalRevisionVector: $0.abortRevisionVector
            )
        }
        var outcome = ProviderHandoffTerminalOutcomeV1(
            tokenID: transaction.token.tokenID,
            manifestID: boundManifest.manifestID,
            manifestDigest: boundManifest.manifestDigest,
            phase: .aborted,
            roots: roots,
            outcomeDigestSHA256: Self.digest("pending-gateway-abort"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        outcome.outcomeDigestSHA256 =
            try ProviderHandoffProjections.terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256: outcome.outcomeDigestSHA256,
            purpose: .coordinatorTerminalOutcomeSigning,
            trustRegistryRevision: Self.trustRevision
        )
        return try ProviderHandoffRecordValidator.validateTerminalOutcome(
            outcome,
            trustRegistry: validatedTrustRegistry,
            atUnixSeconds: Self.useTime
        )
    }

    func reconciliation(
        importedRecord: ProviderHandoffPartStagingRecordV1
    ) throws -> LoggingPartReconciliation {
        let imported = try importedParts(importedRecord: importedRecord)
        let selection = try selectionTransition()
        let socket = try socketTransition()
        let intent = ProviderHandoffCommitIntentV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            trustRegistryRevision: Self.trustRevision,
            authoritativeCommitRevision: 1,
            preCommitRootExpectations: [
                sourceExpectation,
                destinationExpectation,
            ],
            importedParts: imported,
            destinationKeyPossessionProofDigestsSHA256:
                manifest.destinationKeyPossessionProofDigestsSHA256,
            providerSelection: selection,
            socketSelection: socket,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            resultingMinimumWriterSchemaVersion: 1
        )
        var record = ProviderHandoffCommitRecordV1(
            intent: intent,
            commitDigestSHA256: Self.digest("pending-commit"),
            handoffChainHeadDigestSHA256: Self.digest("pending-chain"),
            postCommitRoots: [],
            rootPrepareRecordDigestsSHA256: [
                Self.digest("prepare-source"),
                Self.digest("prepare-destination"),
            ],
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorCommitSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        record.commitDigestSHA256 =
            try ProviderHandoffProjections
            .commitIntentDigest(intent)
        record.handoffChainHeadDigestSHA256 =
            try ProviderHandoffProjections
            .chainHeadDigest(
                commitDigestSHA256: record.commitDigestSHA256,
                orderedPreCommitHeaders: intent.preCommitRootExpectations
                    .map(\.expectedHeader)
            )
        record.postCommitRoots =
            try ProviderHandoffRecordValidator
            .derivePostCommitRoots(
                intent: intent,
                chainHeadDigestSHA256: record.handoffChainHeadDigestSHA256
            )
        record.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256:
                try ProviderHandoffProjections
                .commitRecordDigest(record),
            purpose: .coordinatorCommitSigning,
            trustRegistryRevision: Self.trustRevision
        )
        _ = try ProviderHandoffRecordValidator.validateCommitRecord(
            record,
            trustRegistry: validatedTrustRegistry,
            atUnixSeconds: Self.useTime
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 8,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: Self.trustRevision,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .reconciling,
            preCommitRootExpectations: [
                sourceExpectation,
                destinationExpectation,
            ],
            destinationKeyPossessionProofDigestsSHA256:
                manifest.destinationKeyPossessionProofDigestsSHA256,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            importedParts: imported,
            authoritativeCommitRevision: 1,
            commitDigestSHA256: record.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                record.handoffChainHeadDigestSHA256,
            rootPrepareRecordDigestsSHA256:
                record.rootPrepareRecordDigestsSHA256
        )
        let state = ProviderHandoffGatewayStateV1(
            storeRevision: 9,
            authoritativeCommitRevision: 1,
            providerSelection: selection.resultingRecord,
            socketDiscovery: socket.resultingRecord,
            activeTokenID: Self.tokenID,
            transactions: [
                ProviderHandoffGatewayTransactionV1(
                    token: token,
                    manifest: manifest,
                    commitRecord: record
                )
            ]
        )
        try ProviderHandoffGatewayStateMachine.validate(state)
        return LoggingPartReconciliation(
            commitRecord: record,
            gatewayState: state
        )
    }

    func complete(
        reconciliation: LoggingPartReconciliation,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1
    ) throws -> LoggingPartTerminalState {
        var roots: [ProviderHandoffTerminalRootV1] = []
        for (index, post) in reconciliation.commitRecord.postCommitRoots
            .enumerated()
        {
            var header = post.postCommitHeader
            var vector = post.postCommitRevisionVector
            header.activeHandoffTokenID = nil
            if index == reconciliation.commitRecord.postCommitRoots.count - 1 {
                header.handoffState = .destinationActive
                header.stagedAuthorityLineageUUID = nil
                header.writerEpoch += 1
                vector.rootStoreRevision += 1
                vector.controllerRevisions = [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: promotionReceipt.controllerRevision,
                        canonicalStateDigestSHA256:
                            promotionReceipt.controllerStateDigestSHA256
                    )
                ]
                vector.revisionVectorDigestSHA256 =
                    try ProviderHandoffProjections.revisionVectorDigest(vector)
            }
            roots.append(
                ProviderHandoffTerminalRootV1(
                    role: post.role,
                    stateRootUUID: post.stateRootUUID,
                    terminalHeader: header,
                    terminalHeaderDigestSHA256:
                        try ProviderHandoffProjections
                        .stateRootHeaderDigest(header),
                    terminalRevisionVector: vector
                ))
        }
        var outcome = ProviderHandoffTerminalOutcomeV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            phase: .complete,
            roots: roots,
            outcomeDigestSHA256: Self.digest("pending-complete"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        outcome.outcomeDigestSHA256 =
            try ProviderHandoffProjections
            .terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256: outcome.outcomeDigestSHA256,
            purpose: .coordinatorTerminalOutcomeSigning,
            trustRegistryRevision: Self.trustRevision
        )
        let validated =
            try ProviderHandoffRecordValidator
            .validateTerminalOutcome(
                outcome,
                trustRegistry: validatedTrustRegistry,
                atUnixSeconds: Self.useTime
            )
        var state = reconciliation.gatewayState
        let tokenRevision = try #require(
            state.transactions.first?.token.tokenRevision
        )
        try ProviderHandoffGatewayStateMachine.complete(
            validated,
            tokenID: Self.tokenID,
            expectedTokenRevision: tokenRevision,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        return LoggingPartTerminalState(outcome: outcome, gatewayState: state)
    }

    func aborted(
        importedRecord: ProviderHandoffPartStagingRecordV1
    ) throws -> LoggingPartTerminalState {
        let imported = try importedParts(importedRecord: importedRecord)
        var state = try ProviderHandoffGatewayStateMachine.initialState(
            providerSelection: try selectionTransition().expectedRecord,
            socketDiscovery: try socketTransition().expectedRecord
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint: destinationFingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: Self.trustRevision,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: Self.manifestID
        )
        try ProviderHandoffGatewayStateMachine.begin(
            token,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        try ProviderHandoffGatewayStateMachine.quiesce(
            tokenID: Self.tokenID,
            expectedTokenRevision: state.transactions[0].token.tokenRevision,
            expectations: [sourceExpectation, destinationExpectation],
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        try ProviderHandoffGatewayStateMachine.bindManifest(
            validatedManifest,
            tokenID: Self.tokenID,
            expectedTokenRevision: state.transactions[0].token.tokenRevision,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        try ProviderHandoffGatewayStateMachine.stage(
            tokenID: Self.tokenID,
            expectedTokenRevision: state.transactions[0].token.tokenRevision,
            importedParts: imported,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        try ProviderHandoffGatewayStateMachine.beginAbort(
            tokenID: Self.tokenID,
            expectedTokenRevision: state.transactions[0].token.tokenRevision,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        let roots = [sourceExpectation, destinationExpectation].map {
            ProviderHandoffTerminalRootV1(
                role: $0.role,
                stateRootUUID: $0.stateRootUUID,
                terminalHeader: $0.abortHeader,
                terminalHeaderDigestSHA256: $0.abortHeaderDigestSHA256,
                terminalRevisionVector: $0.abortRevisionVector
            )
        }
        var outcome = ProviderHandoffTerminalOutcomeV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            phase: .aborted,
            roots: roots,
            outcomeDigestSHA256: Self.digest("pending-abort"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        outcome.outcomeDigestSHA256 =
            try ProviderHandoffProjections
            .terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = try gatewayIdentity.sign(
            projectionDigestSHA256: outcome.outcomeDigestSHA256,
            purpose: .coordinatorTerminalOutcomeSigning,
            trustRegistryRevision: Self.trustRevision
        )
        let validated =
            try ProviderHandoffRecordValidator
            .validateTerminalOutcome(
                outcome,
                trustRegistry: validatedTrustRegistry,
                atUnixSeconds: Self.useTime
            )
        try ProviderHandoffGatewayStateMachine.finishAbort(
            validated,
            tokenID: Self.tokenID,
            expectedTokenRevision: state.transactions[0].token.tokenRevision,
            in: &state,
            expectedStoreRevision: state.storeRevision
        )
        return LoggingPartTerminalState(outcome: outcome, gatewayState: state)
    }

    func promotedEffectCount() async -> Int {
        await promoter.promotedEffectCount()
    }

    func activatedEffectCount() async -> Int {
        await promoter.activatedEffectCount()
    }

    func protectedObjectCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: protectedRoot.path) else {
            return 0
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: protectedRoot.path
        ).count {
            $0.hasPrefix(LoggingProtectedOptionsStore.objectFilePrefix)
                && $0.hasSuffix(LoggingProtectedOptionsStore.objectFileSuffix)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
            ] as CFDictionary)
    }

    private func importedParts(
        importedRecord: ProviderHandoffPartStagingRecordV1
    ) throws -> [ProviderHandoffPartImportExpectationV1] {
        try manifest.parts.map { part in
            ProviderHandoffPartImportExpectationV1(
                partKind: part.kind,
                payloadDescriptorDigestSHA256:
                    try ProviderHandoffProjections
                    .payloadDescriptorDigest(part.payload),
                stagedImportReceiptDigestSHA256:
                    part.kind == .logging
                    ? try #require(
                        importedRecord.stagedImportReceiptDigestSHA256
                    )
                    : Self.digest("receipt-\(part.kind.rawValue)")
            )
        }
    }

    private func selectionTransition() throws
        -> ProviderHandoffProviderSelectionExpectationV1
    {
        let expected = ProviderHandoffProviderSelectionRecordV1(
            selectionRevision: 1,
            selectedProviderFingerprint: sourceFingerprint.digest,
            selectedStateRootUUID: Self.sourceRoot,
            providerRegistrationDigestSHA256: String(
                sourceFingerprint.digest.dropFirst("sha256:".count)
            ),
            trustRegistryRevision: Self.trustRevision
        )
        let resulting = ProviderHandoffProviderSelectionRecordV1(
            selectionRevision: 2,
            selectedProviderFingerprint: destinationFingerprint.digest,
            selectedStateRootUUID: Self.destinationRoot,
            providerRegistrationDigestSHA256: String(
                destinationFingerprint.digest.dropFirst("sha256:".count)
            ),
            trustRegistryRevision: Self.trustRevision
        )
        return ProviderHandoffProviderSelectionExpectationV1(
            expectedRecord: expected,
            expectedRecordDigestSHA256:
                try ProviderHandoffProjections
                .providerSelectionDigest(expected),
            resultingRecord: resulting,
            resultingRecordDigestSHA256:
                try ProviderHandoffProjections
                .providerSelectionDigest(resulting)
        )
    }

    private func socketTransition() throws
        -> ProviderHandoffSocketSelectionExpectationV1
    {
        let expected = ProviderHandoffSocketDiscoveryRecordV1(
            discoveryRevision: 1,
            socketInstanceUUID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            ownerUID: UInt32(getuid()),
            minimumEngineAPIVersion: "1.44",
            maximumEngineAPIVersion: "1.53",
            selectedProviderFingerprint: sourceFingerprint.digest,
            selectedStateRootUUID: Self.sourceRoot
        )
        let resulting = ProviderHandoffSocketDiscoveryRecordV1(
            discoveryRevision: 2,
            socketInstanceUUID: expected.socketInstanceUUID,
            ownerUID: expected.ownerUID,
            minimumEngineAPIVersion: expected.minimumEngineAPIVersion,
            maximumEngineAPIVersion: expected.maximumEngineAPIVersion,
            selectedProviderFingerprint: destinationFingerprint.digest,
            selectedStateRootUUID: Self.destinationRoot
        )
        return ProviderHandoffSocketSelectionExpectationV1(
            expectedRecord: expected,
            expectedRecordDigestSHA256:
                try ProviderHandoffProjections
                .socketDiscoveryDigest(expected),
            resultingRecord: resulting,
            resultingRecordDigestSHA256:
                try ProviderHandoffProjections
                .socketDiscoveryDigest(resulting)
        )
    }

    private static func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private static func publish(
        _ payload: ProviderHandoffPreparedPayloadV1,
        to store: ProviderHandoffBundleObjectStore
    ) throws {
        var object = try store.declare(
            bundleObjectID: payload.descriptor.bundleObjectID,
            transportByteLength: payload.descriptor.transportByteLength,
            transportDigestSHA256: payload.descriptor.transportDigestSHA256
        )
        object = try store.append(
            bundleObjectID: object.bundleObjectID,
            offset: 0,
            bytes: payload.transportBytes,
            expectedObjectRevision: object.objectRevision
        )
        _ = try store.verify(
            bundleObjectID: object.bundleObjectID,
            expectedObjectRevision: object.objectRevision
        )
    }

    private static func providerIdentity(
        fingerprint: ContainerEngineProviderFingerprint,
        codeIdentity: ProviderHandoffCodeIdentityV1,
        service: String,
        account: String
    ) throws -> ProviderHandoffProviderIdentityV1 {
        try ProviderHandoffProviderKeyStore(
            service: service,
            account: account
        ).loadOrCreate(
            context: ProviderHandoffProviderKeyEnrollmentContextV1(
                providerFingerprint: fingerprint.digest,
                stateRootUUID: fingerprint.stateRootUUID.uuidString.lowercased(),
                owningBundleIdentifier: codeIdentity.signingIdentifier,
                codeRequirementDigestSHA256:
                    codeIdentity.designatedRequirementDigestSHA256,
                teamIdentifier: codeIdentity.teamIdentifier,
                providerRegistrationDigestSHA256: String(
                    fingerprint.digest.dropFirst("sha256:".count)
                ),
                enrolledAtUnixSeconds: useTime - 10,
                notBeforeUnixSeconds: useTime - 10,
                notAfterUnixSeconds: useTime + 10
            ))
    }

    private static func possessionDigests(
        destinationIdentity: ProviderHandoffProviderIdentityV1,
        possessionStore: ProviderHandoffPossessionProofStore
    ) throws -> [String] {
        try [
            ProviderHandoffKeyPurposeV1.destinationLineageKeyEncryption,
            .destinationPayloadEncryption,
        ].map { purpose in
            let key = try destinationIdentity.trustKey(for: purpose)
            let challenge =
                try ProviderHandoffPossessionProofCodec
                .prepareChallenge(
                    proofID: "proof-\(purpose.rawValue)",
                    tokenID: tokenID,
                    manifestID: manifestID,
                    destinationProviderFingerprint:
                        destinationIdentity.context.providerFingerprint,
                    destinationStateRootUUID:
                        destinationIdentity.context.stateRootUUID,
                    destinationKeyPurpose: purpose,
                    destinationKeyID: key.keyID,
                    destinationPublicKey: key.rawPublicKey,
                    nonce: Data(
                        repeating:
                            purpose == .destinationLineageKeyEncryption
                            ? 0x61 : 0x62,
                        count: 24
                    ),
                    challengePlaintext: Data(
                        repeating:
                            purpose == .destinationLineageKeyEncryption
                            ? 0x71 : 0x72,
                        count: 32
                    ),
                    ephemeralPrivateKey: Data(
                        repeating:
                            purpose == .destinationLineageKeyEncryption
                            ? 0x51 : 0x52,
                        count: 32
                    )
                )
            return try possessionStore.store(
                destinationIdentity.respond(
                    to: challenge,
                    trustRegistryRevision: trustRevision
                )
            )
        }.sorted()
    }

    private static func exportContainer(
        driver: LogDriverDescriptor,
        includeHistory: Bool
    ) throws -> LoggingHandoffExportContainerV1 {
        if includeHistory {
            let histories = try ["before-cutover-1", "before-cutover-2"]
                .enumerated()
                .map { index, payload in
                    try LoggingHandoffHistoryStoreV1(
                        storeID:
                            ProviderHandoffPortableLoggingPayloadCodec
                            .historyChunkStoreID(index: UInt64(index), count: 2),
                        kind: .dockerJSONFile,
                        disposition: .importVerified,
                        formatVersion: 1,
                        rotationIndex: 0,
                        terminalHistoryEpoch: 7,
                        maximumInternalSequence: 41,
                        sourceDeviceID: nil,
                        sourceInode: nil,
                        bytes: try jsonHistoryBytes(
                            payload: payload,
                            seconds: Int64(Self.useTime - 2 + UInt64(index))
                        )
                    )
                }
            let resolved = try ResolvedContainerLogConfiguration(
                leaseGeneration: 41,
                driver: driver.driver,
                safeOptions: [:],
                protectedOptionNames: [],
                protectedOptionReference: nil,
                delivery: LogDeliveryConfiguration(),
                readPolicy: LogReadPolicy(source: .direct),
                providerIdentity: driver.providerIdentity,
                providerGenerationAtResolution: driver.providerGeneration,
                contractDigest: driver.optionContractDigest
            )
            return try LoggingHandoffExportContainerV1(
                containerID: "container-1",
                configuration: ContainerLogConfiguration(
                    requested: ContainerLogRequest(driver: driver.driver),
                    resolved: resolved
                ),
                protectedOptions: [:],
                historyStores: histories,
                lifecycleSnapshot:
                    ContainerLogLifecycleLedgerSnapshotV1(
                        owningControllerID: "logging-controller"
                    )
            )
        }
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 41,
            driver: driver.driver,
            safeOptions: ["endpoint": "collector.example.test:1234"],
            protectedOptionNames: ["token"],
            protectedOptionReference: LoggingProtectedOptionsReference(
                objectID: "source-protected-object",
                integrityDigest: "source-protected-integrity"
            ),
            delivery: try LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(
                source: .dualCache,
                cache: LogCacheConfiguration(
                    maxSizeInBytes: 20 * 1024 * 1024,
                    maxFileCount: 5,
                    compress: true
                )
            ),
            providerIdentity: driver.providerIdentity,
            providerGenerationAtResolution: 9,
            contractDigest: driver.optionContractDigest
        )
        return try LoggingHandoffExportContainerV1(
            containerID: "container-1",
            configuration: try ContainerLogConfiguration(
                requested: ContainerLogRequest(
                    driver: driver.driver,
                    options: [
                        "endpoint": "collector.example.test:1234",
                        "token": "secret-value",
                    ]
                ),
                resolved: resolved
            ),
            protectedOptions: ["token": "secret-value"],
            historyStores: [],
            lifecycleSnapshot: try ContainerLogLifecycleLedgerSnapshotV1(
                owningControllerID: "logging-controller"
            )
        )
    }

    private static func jsonHistoryBytes(
        payload: String,
        seconds: Int64
    ) throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "logging-handoff-json-source-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DockerJSONFileLogStore(
            directoryURL: root.appendingPathComponent(
                "json-file",
                isDirectory: true
            ),
            activeFileName: ContainerResource.Bundle.jsonFileLogName
        )
        try store.write(
            ContainerLogRecordV2(
                stream: .stdout,
                observation: ContainerLogObservation(
                    wallClock: try ContainerLogTimestamp(
                        secondsSinceUnixEpoch: seconds,
                        nanoseconds: 0
                    ),
                    monotonicInstant: ContinuousClock().now
                ),
                payload: Data(payload.utf8),
                partial: nil,
                sequence: 41,
                processGeneration: 9
            )
        )
        try store.close()
        return try Data(contentsOf: store.logURL)
    }

    private static func remoteDescriptor() throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: "acme-remote",
            providerIdentity: LogDriverProviderIdentity(
                id: "example.acme.logging",
                version: "1",
                kind: .native
            ),
            providerGeneration: 1,
            placement: .macOSHost,
            trust: .signed,
            options: [
                LogDriverOptionDescriptor(name: "endpoint", valueKind: .string),
                LogDriverOptionDescriptor(
                    name: "mode",
                    valueKind: .string,
                    allowedValues: ["blocking", "non-blocking"]
                ),
                LogDriverOptionDescriptor(
                    name: "token",
                    valueKind: .string,
                    isSecret: true
                ),
            ],
            capabilities: LogDriverCapabilities(
                deliveryModes: [.blocking, .nonBlocking],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: true,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: true,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    private static func expectation(
        role: ProviderHandoffRootRoleV1,
        root: String,
        lineage: String,
        stagedLineage: String?,
        provider: String?,
        state: StateRootHandoffStateV1,
        abortState: StateRootHandoffStateV1,
        snapshot: String?
    ) throws -> ProviderHandoffHeaderExpectationV1 {
        let expected = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: stagedLineage,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 4,
            selectedProviderFingerprint: provider,
            handoffState: state,
            activeHandoffTokenID: tokenID,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: role == .source ? 7 : 1
        )
        let abort = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: nil,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 5,
            selectedProviderFingerprint: provider,
            handoffState: abortState,
            activeHandoffTokenID: nil,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: role == .source ? 7 : 1
        )
        var preCommit = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 10,
            snapshotCheckpointID: snapshot,
            controllerRevisions: role == .source
                ? [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: 7,
                        canonicalStateDigestSHA256: String(
                            repeating: "8",
                            count: 64
                        )
                    )
                ] : [],
            revisionVectorDigestSHA256: String(repeating: "0", count: 64)
        )
        preCommit.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
            .revisionVectorDigest(preCommit)
        var abortVector = preCommit
        abortVector.rootStoreRevision += 1
        abortVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
            .revisionVectorDigest(abortVector)
        return ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expected,
            expectedHeaderDigestSHA256:
                try ProviderHandoffProjections
                .stateRootHeaderDigest(expected),
            preCommitRevisionVector: preCommit,
            abortHeader: abort,
            abortHeaderDigestSHA256:
                try ProviderHandoffProjections
                .stateRootHeaderDigest(abort),
            abortRevisionVector: abortVector
        )
    }

    private static func placeholderSignature(
        purpose: ProviderHandoffKeyPurposeV1,
        role: ProviderHandoffKeyRoleV1,
        provider: String?,
        root: String?
    ) -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: purpose,
            signerKeyID: "pending",
            signerRole: role,
            providerFingerprint: provider,
            stateRootUUID: root,
            trustRegistryRevision: trustRevision,
            signedProjectionDigestSHA256: String(repeating: "0", count: 64),
            signature: Data(repeating: 0, count: 64)
        )
    }
}

private actor LoggingPartControlPromoter: LoggingHandoffContainerPromoting {
    private let root: URL
    private var promoted = Set<String>()
    private var activated = Set<String>()
    private var containers: [String: LoggingHandoffStagedContainerV1] = [:]

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    func promoteContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffPromotedHistorySegmentV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws {
        let bundleURL = root.appendingPathComponent(
            container.containerID,
            isDirectory: true
        )
        if !FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions: NSNumber(value: Int16(0o700))
                ]
            )
        }
        let bundle = ContainerResource.Bundle(path: bundleURL)
        if !history.isEmpty {
            try LoggingHandoffBundleHistoryPublisher.publish(
                bundle: bundle,
                segments: history,
                transactionID:
                    "\(authorization.tokenID):\(authorization.manifestID):\(container.containerID)"
            )
            if let terminalEpoch = history.map(\.terminalHistoryEpoch).max(),
                let maximumSequence = history.map(\.maximumInternalSequence)
                    .max()
            {
                try ContainerLogProcessGenerationStore(
                    directoryURL: bundle.containerLoggingV2
                ).adoptHistoryCursor(
                    terminalHistoryEpoch: terminalEpoch,
                    maximumInternalSequence: maximumSequence
                )
            }
        }
        containers[container.containerID] = container
        promoted.insert(key(authorization, containerID: container.containerID))
    }

    func activateContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        promotionReceipt _: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws {
        activated.insert(key(authorization, containerID: container.containerID))
    }

    func provePublicHistoryAndWriter(
        containerID: String
    ) throws -> LoggingGatewayPublicHistoryEvidence {
        guard
            activated.contains(where: { $0.hasSuffix(":\(containerID)") }),
            let container = containers[containerID],
            container.configuration.resolved?.driver == "json-file"
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let bundle = ContainerResource.Bundle(
            path: root.appendingPathComponent(containerID, isDirectory: true)
        )
        let imported = try readPayloads(bundle: bundle)
        let cursor = try ContainerLogProcessGenerationStore(
            directoryURL: bundle.containerLoggingV2
        )
        let reservation = try cursor.reserveSequenceBlock(requestedCount: 1)
        let writer = try DockerJSONFileLogStore(
            directoryURL: bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName
        )
        try writer.write(
            ContainerLogRecordV2(
                stream: .stdout,
                observation: ContainerLogObservation(
                    wallClock: try ContainerLogTimestamp(
                        secondsSinceUnixEpoch: 1_800_000_001,
                        nanoseconds: 0
                    ),
                    monotonicInstant: ContinuousClock().now
                ),
                payload: Data("after-cutover".utf8),
                partial: nil,
                sequence: reservation.lowerBound,
                processGeneration: 10
            )
        )
        try writer.close()
        return LoggingGatewayPublicHistoryEvidence(
            importedPayloads: imported,
            payloadsAfterWriter: try readPayloads(bundle: bundle),
            writerReservation: reservation
        )
    }

    func promotedEffectCount() -> Int { promoted.count }

    func activatedEffectCount() -> Int { activated.count }

    private func key(
        _ authorization: LoggingHandoffPromotionAuthorizationV1,
        containerID: String
    ) -> String {
        "\(authorization.tokenID):\(authorization.manifestID):\(containerID)"
    }

    private func key(
        _ authorization: LoggingHandoffActivationAuthorizationV1,
        containerID: String
    ) -> String {
        "\(authorization.tokenID):\(authorization.manifestID):\(containerID)"
    }

    private func readPayloads(
        bundle: ContainerResource.Bundle
    ) throws -> [Data] {
        let result = try DockerJSONFileLogReader(
            directoryURL: bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            maximumFileCount: 5
        ).read(DockerJSONFileLogReadRequest())
        guard result.issues.isEmpty else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return result.records.map(\.log)
    }
}
