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
import ContainerPersistence
import ContainerResource
import Darwin
import Foundation
import Security
import Testing

@testable import ContainerAPIService

struct LoggingHandoffControlResponderTests {
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
    let controlRequest: ContainerEngineProviderHandoffControlRequestV1
    let requestBody: Data
    let controlContext: ContainerEngineProviderHandoffControlContextV1
    let stageRequest: ProviderHandoffPartStageRequestV1

    private let commonStore: ProviderHandoffPartStagingStore
    private let destinationFingerprint: ContainerEngineProviderFingerprint
    private let destinationExpectation: ProviderHandoffHeaderExpectationV1
    private let gatewayIdentity: ProviderHandoffGatewayIdentityV1
    private let manifest: ProviderHandoffManifestV1
    private let promoter: LoggingPartControlPromoter
    private let protectedRoot: URL
    private let sourceExpectation: ProviderHandoffHeaderExpectationV1
    private let sourceFingerprint: ContainerEngineProviderFingerprint
    private let validatedManifest: ProviderHandoffValidatedManifestV1
    private let validatedTrustRegistry: ProviderHandoffValidatedTrustRegistryV1

    init() throws {
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

        let codeIdentity = try ProviderHandoffCodeIdentity.current()
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
        let sourceIdentity = try Self.providerIdentity(
            fingerprint: sourceFingerprint,
            codeIdentity: codeIdentity,
            service: keychainService,
            account: "source"
        )
        let destinationIdentity = try Self.providerIdentity(
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
        let trustStore = ProviderHandoffTrustRegistryStore(
            service: keychainService,
            account: "trust"
        )
        _ = try trustStore.install(
            registry.registry,
            bootstrap: gatewayIdentity.bootstrap
        )

        let possessionStore = ProviderHandoffPossessionProofStore(
            root: root.appendingPathComponent("proofs", isDirectory: true)
        )
        let possessionDigests = try Self.possessionDigests(
            destinationIdentity: destinationIdentity,
            possessionStore: possessionStore
        )
        let driver = try Self.remoteDescriptor()
        let sourceLineageKey = Data(repeating: 0x41, count: 32)
        let destinationPayloadKey = try destinationIdentity.trustKey(
            for: .destinationPayloadEncryption
        )
        let preparedLogging = try LoggingHandoffPayloadCodec.prepareSealed(
            containers: [try Self.exportContainer(driver: driver)],
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
                        possessionStore.load($0),
                        trustRegistry: registry,
                        atUnixSeconds: Self.useTime
                    )
            },
            trustRegistry: registry,
            atUnixSeconds: Self.useTime
        )

        let objectStore = ProviderHandoffBundleObjectStore(
            root: root.appendingPathComponent("objects", isDirectory: true)
        )
        var object = try objectStore.declare(
            bundleObjectID: preparedLogging.descriptor.bundleObjectID,
            transportByteLength: preparedLogging.descriptor.transportByteLength,
            transportDigestSHA256:
                preparedLogging.descriptor.transportDigestSHA256
        )
        object = try objectStore.append(
            bundleObjectID: object.bundleObjectID,
            offset: 0,
            bytes: preparedLogging.transportBytes,
            expectedObjectRevision: object.objectRevision
        )
        _ = try objectStore.verify(
            bundleObjectID: object.bundleObjectID,
            expectedObjectRevision: object.objectRevision
        )

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
        promoter = LoggingPartControlPromoter()
        let destination = try LoggingHandoffDestinationReconciler(
            rootURL: root.appendingPathComponent(
                "promotions",
                isDirectory: true
            ),
            containerPromoter: promoter
        )
        responder = LoggingHandoffControlResponder(
            objectStore: objectStore,
            possessionProofStore: possessionStore,
            trustRegistryStore: trustStore,
            commonStore: commonStore,
            providerIdentity: destinationIdentity,
            stagingController: stagingController,
            destination: destination,
            stagingContext: {
                (
                    catalog: try LogDriverCatalog(
                        descriptors: BuiltinLogDriverDescriptors.current
                            .descriptors + [driver]
                    ),
                    occupiedContainerIDs: []
                )
            },
            nowUnixSeconds: { Self.useTime }
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
        }
    }

    private static func exportContainer(
        driver: LogDriverDescriptor
    ) throws -> LoggingHandoffExportContainerV1 {
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
    private var promoted = Set<String>()
    private var activated = Set<String>()

    func promoteContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        history _: [LoggingHandoffPromotedHistorySegmentV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws {
        promoted.insert(
            "\(authorization.tokenID):\(authorization.manifestID):"
                + container.containerID
        )
    }

    func activateContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        promotionReceipt _: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws {
        activated.insert(
            "\(authorization.tokenID):\(authorization.manifestID):"
                + container.containerID
        )
    }

    func promotedEffectCount() -> Int { promoted.count }

    func activatedEffectCount() -> Int { activated.count }
}
