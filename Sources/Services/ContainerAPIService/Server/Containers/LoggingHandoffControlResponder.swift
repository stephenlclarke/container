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
import ContainerResource
import Foundation

enum LoggingHandoffControlResponderError: Error, Equatable, Sendable {
    case destinationUnavailable
    case invalidGatewayIdentity
    case invalidGatewayState
    case invalidManifest
    case invalidPayload
    case invalidPromotionReceipt
    case unsupportedOperation
}

/// Production destination endpoint for logging part stage, compensation,
/// promotion, and activation.
///
/// The gateway supplies only signed bounded metadata. This responder loads the
/// exact archived registry and destination-created possession receipts, opens
/// lineage keys and payload with provider-private keys, verifies the logging
/// package, and then delegates protected publication to the logging staging
/// controller. No key or controller-private reference is returned.
struct LoggingHandoffControlResponder:
    ContainerEngineProviderHandoffControlResponder,
    Sendable
{
    typealias StagingContext =
        @Sendable () async throws -> (
            catalog: LogDriverCatalog,
            occupiedContainerIDs: Set<String>
        )

    private struct ValidatedMetadata: Sendable {
        let trustRegistry: ProviderHandoffValidatedTrustRegistryV1
        let part: ProviderHandoffPartV1
        let atUnixSeconds: UInt64
    }

    private static let requiredCapability =
        "engine.handoff.part.logging.v1"

    private let objectStore: ProviderHandoffBundleObjectStore
    private let possessionProofStore: ProviderHandoffPossessionProofStore
    private let trustRegistryStore: ProviderHandoffTrustRegistryStore
    private let commonStore: ProviderHandoffPartStagingStore
    private let providerIdentity: ProviderHandoffProviderIdentityV1
    private let stagingController: LoggingHandoffStagingController
    private let destination: (any LoggingHandoffDestinationReconciling)?
    private let stagingContext: StagingContext
    private let nowUnixSeconds: @Sendable () throws -> UInt64
    private let downstream: (any ContainerEngineProviderHandoffControlResponder)?

    init(
        objectStore: ProviderHandoffBundleObjectStore,
        possessionProofStore: ProviderHandoffPossessionProofStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        commonStore: ProviderHandoffPartStagingStore,
        providerIdentity: ProviderHandoffProviderIdentityV1,
        stagingController: LoggingHandoffStagingController,
        destination: (any LoggingHandoffDestinationReconciling)? = nil,
        stagingContext: @escaping StagingContext,
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw LoggingHandoffControlResponderError.invalidManifest
            }
            return UInt64(value.rounded(.down))
        },
        downstream:
            (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) {
        self.objectStore = objectStore
        self.possessionProofStore = possessionProofStore
        self.trustRegistryStore = trustRegistryStore
        self.commonStore = commonStore
        self.providerIdentity = providerIdentity
        self.stagingController = stagingController
        self.destination = destination
        self.stagingContext = stagingContext
        self.nowUnixSeconds = nowUnixSeconds
        self.downstream = downstream
    }

    func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        guard
            [.partStage, .partCompensate, .partPromote, .partActivate]
                .contains(request.operation)
        else {
            guard let downstream else {
                return Self.failure(
                    requestID: request.requestID,
                    disposition: .rejected,
                    message: "selected provider does not implement this handoff operation"
                )
            }
            return await downstream.respond(
                to: request,
                body: body,
                context: context
            )
        }
        do {
            switch request.operation {
            case .partStage:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffPartControlCodec.stageRequestMediaType
                )
                let commonRecord = try await stage(
                    ProviderHandoffPartControlCodec.decodeStageRequest(body),
                    context: context
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body: ProviderHandoffPartControlCodec.encodeStageReceipt(
                        ProviderHandoffPartStageReceiptV1(
                            commonRecord: commonRecord
                        )
                    ),
                    mediaType:
                        ProviderHandoffPartControlCodec.stageReceiptMediaType
                )
            case .partPromote:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffPartControlCodec.promoteRequestMediaType
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body:
                        ProviderHandoffPartControlCodec
                        .encodePromotionReceipt(
                            try await promote(
                                ProviderHandoffPartControlCodec
                                    .decodePromoteRequest(body),
                                context: context
                            )
                        ),
                    mediaType: ProviderHandoffPartControlCodec
                        .promotionReceiptMediaType
                )
            case .partActivate:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffPartControlCodec.activateRequestMediaType
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body:
                        ProviderHandoffPartControlCodec
                        .encodeOperationReceipt(
                            try await activate(
                                ProviderHandoffPartControlCodec
                                    .decodeActivateRequest(body),
                                context: context
                            )
                        ),
                    mediaType:
                        ProviderHandoffPartControlCodec.operationReceiptMediaType
                )
            case .partCompensate:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffPartControlCodec.compensateRequestMediaType
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body:
                        ProviderHandoffPartControlCodec
                        .encodeOperationReceipt(
                            try await compensate(
                                ProviderHandoffPartControlCodec
                                    .decodeCompensateRequest(body),
                                context: context
                            )
                        ),
                    mediaType:
                        ProviderHandoffPartControlCodec.operationReceiptMediaType
                )
            case .destinationKeyPossession, .destinationKeySnapshot,
                .objectAppend, .objectDeclare, .objectRead, .objectVerify,
                .partExport, .sourceSignManifest,
                .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
                throw LoggingHandoffControlResponderError.unsupportedOperation
            }
        } catch {
            return Self.failure(
                requestID: request.requestID,
                disposition: Self.disposition(for: error),
                message: Self.message(for: error)
            )
        }
    }

    private func stage(
        _ request: ProviderHandoffPartStageRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffPartStagingRecordV1 {
        let metadata = try validatedMetadata(request, context: context)
        var commonRecord: ProviderHandoffPartStagingRecordV1?
        do {
            let declared = try ProviderHandoffPartStagingStateMachine.declared(
                tokenID: request.manifest.tokenID,
                manifestID: request.manifest.manifestID,
                manifestDigest: request.manifest.manifestDigest,
                partKind: .logging,
                bundleObjectID: metadata.part.payload.bundleObjectID,
                payloadDescriptorDigestSHA256:
                    try ProviderHandoffProjections
                    .payloadDescriptorDigest(metadata.part.payload)
            )
            var current = try commonStore.declare(declared)
            commonRecord = current
            current = try recordVerifiedTransport(
                current,
                descriptor: metadata.part.payload
            )
            commonRecord = current
            let payload = try openPayload(
                request,
                metadata: metadata
            )
            current = try recordVerifiedContent(
                current,
                descriptor: metadata.part.payload
            )
            commonRecord = current
            let staging = try await stagingContext()
            return try await stagingController.stage(
                commonRecord: current,
                payload: payload,
                catalog: staging.catalog,
                occupiedContainerIDs: staging.occupiedContainerIDs
            ).commonRecord
        } catch {
            if let commonRecord {
                try? recordFailure(
                    Self.failureClass(for: error),
                    in: commonRecord
                )
            }
            throw error
        }
    }

    private func validatedMetadata(
        _ request: ProviderHandoffPartStageRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws -> ValidatedMetadata {
        guard
            request.partKind == .logging,
            request.bootstrap.codeRequirementDigestSHA256
                == context.authenticatedGatewayCodeIdentity
                .designatedRequirementDigestSHA256,
            context.providerFingerprint.digest
                == providerIdentity.context.providerFingerprint,
            context.providerFingerprint.stateRootUUID.uuidString.lowercased()
                == providerIdentity.context.stateRootUUID,
            request.manifest.destinationProviderFingerprint
                == providerIdentity.context.providerFingerprint,
            request.manifest.destinationStateRootUUID
                == providerIdentity.context.stateRootUUID
        else {
            throw LoggingHandoffControlResponderError.invalidGatewayIdentity
        }

        let now = try nowUnixSeconds()
        let trustRegistry = try trustRegistryStore.loadRevision(
            request.manifest.trustRegistryRevision,
            bootstrap: request.bootstrap
        )
        let possessionProofs = try request.manifest
            .destinationKeyPossessionProofDigestsSHA256.map { digest in
                try ProviderHandoffPossessionProofCodec
                    .validateDestinationReceipt(
                        possessionProofStore.load(digest),
                        trustRegistry: trustRegistry,
                        atUnixSeconds: now
                    )
            }
        _ = try ProviderHandoffRecordValidator.validateManifest(
            request.manifest,
            possessionProofs: possessionProofs,
            trustRegistry: trustRegistry,
            atUnixSeconds: now
        )

        guard
            let part = request.manifest.parts.first(where: {
                $0.kind == .logging
            }),
            part.disposition == .included,
            part.requiredCapabilities.contains(Self.requiredCapability),
            part.payload.mediaType == LoggingHandoffPayloadCodec.mediaType,
            part.payload.protection
                == .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1
                || part.payload.protection
                    == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2,
            !part.sourceStateRootUUIDs.isEmpty
        else {
            throw LoggingHandoffControlResponderError.invalidManifest
        }
        let object = try objectStore.load(
            bundleObjectID: part.payload.bundleObjectID
        )
        guard
            object.state == .verified,
            object.transportByteLength == part.payload.transportByteLength,
            object.transportDigestSHA256
                == part.payload.transportDigestSHA256,
            object.bundleObjectID == part.payload.bundleObjectID
        else {
            throw LoggingHandoffControlResponderError.invalidPayload
        }

        return ValidatedMetadata(
            trustRegistry: trustRegistry,
            part: part,
            atUnixSeconds: now
        )
    }

    private func openPayload(
        _ request: ProviderHandoffPartStageRequestV1,
        metadata: ValidatedMetadata
    ) throws -> LoggingHandoffDecodedPayloadV1 {
        let lineageKeys = try openLineageKeys(
            for: metadata.part,
            manifest: request.manifest,
            trustRegistry: metadata.trustRegistry,
            atUnixSeconds: metadata.atUnixSeconds
        )
        let package: ProviderHandoffPayloadPackageV1
        switch metadata.part.payload.protection {
        case .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1:
            let transport = try objectStore.readVerifiedObject(
                bundleObjectID: metadata.part.payload.bundleObjectID
            )
            package = try providerIdentity.open(
                ProviderHandoffPreparedPayloadV1(
                    descriptor: metadata.part.payload,
                    transportBytes: transport
                ),
                expectedPartKind: .logging,
                tokenID: request.manifest.tokenID,
                manifestID: request.manifest.manifestID,
                sourceOrder: metadata.part.sourceStateRootUUIDs,
                lineageKeys: lineageKeys
            )
        case .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2:
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "logging-handoff-open-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            package = try providerIdentity.openFile(
                ProviderHandoffPreparedPayloadFileV2(
                    descriptor: metadata.part.payload,
                    transportFileURL: try objectStore.verifiedObjectFileURL(
                        bundleObjectID: metadata.part.payload.bundleObjectID
                    )
                ),
                canonicalFileURL: stagingRoot.appendingPathComponent("canonical"),
                expectedPartKind: .logging,
                tokenID: request.manifest.tokenID,
                manifestID: request.manifest.manifestID,
                sourceOrder: metadata.part.sourceStateRootUUIDs,
                lineageKeys: lineageKeys
            )
        case .authenticatedPlaintext:
            throw LoggingHandoffControlResponderError.invalidPayload
        }
        return try LoggingHandoffPayloadCodec.decodeVerified(
            package,
            lineageKeys: lineageKeys
        )
    }

    private func promote(
        _ request: ProviderHandoffPartPromoteRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffPartOpaqueControllerReceiptV1 {
        let metadata = try validatedMetadata(request.stage, context: context)
        let payload = try openPayload(request.stage, metadata: metadata)
        let commonRecord = try commonStore.load(
            tokenID: request.stage.manifest.tokenID,
            manifestID: request.stage.manifest.manifestID,
            partKind: .logging
        )
        let validatedCommit =
            try ProviderHandoffRecordValidator
            .validateCommitRecord(
                request.commitRecord,
                trustRegistry: metadata.trustRegistry,
                atUnixSeconds: metadata.atUnixSeconds
            )
        guard let destination else {
            throw LoggingHandoffControlResponderError.destinationUnavailable
        }
        let receipt = try await stagingController.reconcile(
            commonRecord: commonRecord,
            payload: payload,
            validatedCommit: validatedCommit,
            gatewayState: request.gatewayState,
            destination: destination
        )
        return ProviderHandoffPartOpaqueControllerReceiptV1(
            partKind: .logging,
            mediaType: LoggingHandoffPromotionControlCodec.mediaType,
            body: try LoggingHandoffPromotionControlCodec.encode(receipt)
        )
    }

    private func activate(
        _ request: ProviderHandoffPartActivateRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffPartOperationReceiptV1 {
        let metadata = try validatedMetadata(request.stage, context: context)
        let payload = try openPayload(request.stage, metadata: metadata)
        let commonRecord = try commonStore.load(
            tokenID: request.stage.manifest.tokenID,
            manifestID: request.stage.manifest.manifestID,
            partKind: .logging
        )
        let validatedCommit =
            try ProviderHandoffRecordValidator
            .validateCommitRecord(
                request.commitRecord,
                trustRegistry: metadata.trustRegistry,
                atUnixSeconds: metadata.atUnixSeconds
            )
        let validatedOutcome =
            try ProviderHandoffRecordValidator
            .validateTerminalOutcome(
                request.terminalOutcome,
                trustRegistry: metadata.trustRegistry,
                atUnixSeconds: metadata.atUnixSeconds
            )
        guard
            request.terminalOutcome.phase == .complete,
            request.promotionReceipt.partKind == .logging,
            request.promotionReceipt.mediaType
                == LoggingHandoffPromotionControlCodec.mediaType,
            let destination
        else {
            throw LoggingHandoffControlResponderError.invalidPromotionReceipt
        }
        let promotionReceipt = try LoggingHandoffPromotionControlCodec.decode(
            request.promotionReceipt.body
        )
        try await stagingController.activate(
            commonRecord: commonRecord,
            payload: payload,
            promotionReceipt: promotionReceipt,
            validatedCommit: validatedCommit,
            validatedOutcome: validatedOutcome,
            gatewayState: request.gatewayState,
            destination: destination
        )
        return ProviderHandoffPartOperationReceiptV1(
            operation: .activate,
            partKind: .logging,
            tokenID: request.stage.manifest.tokenID,
            manifestID: request.stage.manifest.manifestID,
            evidenceDigestSHA256: request.terminalOutcome.outcomeDigestSHA256
        )
    }

    private func compensate(
        _ request: ProviderHandoffPartCompensateRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffPartOperationReceiptV1 {
        let metadata = try validatedMetadata(request.stage, context: context)
        let payload = try openPayload(request.stage, metadata: metadata)
        let commonRecord = try commonStore.load(
            tokenID: request.stage.manifest.tokenID,
            manifestID: request.stage.manifest.manifestID,
            partKind: .logging
        )
        let validatedOutcome =
            try ProviderHandoffRecordValidator
            .validateTerminalOutcome(
                request.terminalOutcome,
                trustRegistry: metadata.trustRegistry,
                atUnixSeconds: metadata.atUnixSeconds
            )
        try Self.validateCompensationAuthorization(
            commonRecord: commonRecord,
            validatedOutcome: validatedOutcome,
            gatewayState: request.gatewayState
        )
        let staging = try await stagingContext()
        _ = try await stagingController.compensate(
            commonRecord: commonRecord,
            payload: payload,
            catalog: staging.catalog
        )
        return ProviderHandoffPartOperationReceiptV1(
            operation: .compensate,
            partKind: .logging,
            tokenID: request.stage.manifest.tokenID,
            manifestID: request.stage.manifest.manifestID,
            evidenceDigestSHA256: request.terminalOutcome.outcomeDigestSHA256
        )
    }

    private static func validateCompensationAuthorization(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        gatewayState: ProviderHandoffGatewayStateV1
    ) throws {
        try ProviderHandoffGatewayStateMachine.validate(gatewayState)
        let outcome = validatedOutcome.outcome
        guard
            gatewayState.activeTokenID == nil,
            let transaction = gatewayState.transactions.first(where: {
                $0.token.tokenID == commonRecord.tokenID
            }),
            transaction.token.phase == .aborted,
            transaction.token.manifestID == commonRecord.manifestID,
            transaction.token.manifestDigest == commonRecord.manifestDigest,
            transaction.token.terminalOutcomeDigestSHA256
                == outcome.outcomeDigestSHA256,
            transaction.terminalOutcome == outcome,
            outcome.phase == .aborted,
            outcome.tokenID == commonRecord.tokenID,
            outcome.manifestID == commonRecord.manifestID,
            outcome.manifestDigest == commonRecord.manifestDigest
        else {
            throw LoggingHandoffControlResponderError.invalidGatewayState
        }
    }

    private func recordVerifiedTransport(
        _ record: ProviderHandoffPartStagingRecordV1,
        descriptor: ProviderHandoffPayloadDescriptorV1
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        var current = record
        if current.state == .declared {
            current = try commonStore.update(
                tokenID: current.tokenID,
                manifestID: current.manifestID,
                partKind: current.partKind,
                expectedStagingRevision: current.stagingRevision
            ) {
                try ProviderHandoffPartStagingStateMachine.beginRetrieval(
                    &$0,
                    expectedRevision: current.stagingRevision
                )
            }
        }
        if current.state == .retrieving,
            current.receivedRanges
                != [
                    ProviderHandoffByteRangeV1(
                        lowerBound: 0,
                        upperBoundExclusive: descriptor.transportByteLength
                    )
                ]
        {
            let revision = current.stagingRevision
            current = try commonStore.update(
                tokenID: current.tokenID,
                manifestID: current.manifestID,
                partKind: current.partKind,
                expectedStagingRevision: revision
            ) {
                try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
                    [
                        ProviderHandoffByteRangeV1(
                            lowerBound: 0,
                            upperBoundExclusive: descriptor.transportByteLength
                        )
                    ],
                    transportByteLength: descriptor.transportByteLength,
                    in: &$0,
                    expectedRevision: revision
                )
            }
        }
        if current.state == .retrieving {
            let revision = current.stagingRevision
            current = try commonStore.update(
                tokenID: current.tokenID,
                manifestID: current.manifestID,
                partKind: current.partKind,
                expectedStagingRevision: revision
            ) {
                try ProviderHandoffPartStagingStateMachine
                    .recordTransportVerified(
                        transportDigestSHA256:
                            descriptor.transportDigestSHA256,
                        transportByteLength: descriptor.transportByteLength,
                        in: &$0,
                        expectedRevision: revision
                    )
            }
        }
        guard
            [.transportVerified, .decrypted, .contentVerified, .imported]
                .contains(current.state)
        else {
            throw LoggingHandoffControlResponderError.invalidPayload
        }
        return current
    }

    private func recordVerifiedContent(
        _ record: ProviderHandoffPartStagingRecordV1,
        descriptor: ProviderHandoffPayloadDescriptorV1
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        var current = record
        if current.state == .transportVerified {
            let revision = current.stagingRevision
            current = try commonStore.update(
                tokenID: current.tokenID,
                manifestID: current.manifestID,
                partKind: current.partKind,
                expectedStagingRevision: revision
            ) {
                try ProviderHandoffPartStagingStateMachine.recordDecrypted(
                    in: &$0,
                    expectedRevision: revision
                )
            }
        }
        if current.state == .decrypted {
            let revision = current.stagingRevision
            let sourceVerifications = descriptor.canonicalContentDigest
                .orderedSourceDigests.map {
                    ProviderHandoffSourceDigestVerificationV1(
                        sourceStateRootUUID: $0.sourceStateRootUUID,
                        authorityLineageUUID: $0.authorityLineageUUID,
                        lineageDigestKeyVersion:
                            $0.lineageDigestKeyVersion,
                        computedSourceDigestHMACSHA256:
                            $0.sourceDigestHMACSHA256
                    )
                }
            current = try commonStore.update(
                tokenID: current.tokenID,
                manifestID: current.manifestID,
                partKind: current.partKind,
                expectedStagingRevision: revision
            ) {
                try ProviderHandoffPartStagingStateMachine
                    .recordContentVerified(
                        canonicalContentDigest:
                            descriptor.canonicalContentDigest.digest,
                        sourceDigestVerifications: sourceVerifications,
                        protection: descriptor.protection,
                        in: &$0,
                        expectedRevision: revision
                    )
            }
        }
        guard [.contentVerified, .imported].contains(current.state) else {
            throw LoggingHandoffControlResponderError.invalidPayload
        }
        return current
    }

    private func openLineageKeys(
        for part: ProviderHandoffPartV1,
        manifest: ProviderHandoffManifestV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> [ProviderHandoffLineageKeyV1] {
        try part.sourceStateRootUUIDs.map { sourceRoot in
            guard
                let source = manifest.sources.first(where: {
                    $0.stateRootUUID == sourceRoot
                })
            else {
                throw LoggingHandoffControlResponderError.invalidManifest
            }
            let matches = manifest.destinationSealedLineageKeyEnvelopes.filter {
                $0.sourceStateRootUUID == sourceRoot
                    && $0.authorityLineageUUID
                        == source.authorityLineageUUID
                    && $0.keyVersion == source.lineageDigestKeyVersion
            }
            guard matches.count == 1, let envelope = matches.first else {
                throw LoggingHandoffControlResponderError.invalidManifest
            }
            let opened = try providerIdentity.open(
                envelope,
                tokenID: manifest.tokenID,
                manifestID: manifest.manifestID,
                sourceProviderFingerprint: source.providerFingerprint,
                trustRegistry: trustRegistry,
                atUnixSeconds: atUnixSeconds
            )
            guard
                opened.sourceStateRootUUID == sourceRoot,
                opened.authorityLineageUUID == source.authorityLineageUUID,
                opened.keyVersion == source.lineageDigestKeyVersion
            else {
                throw LoggingHandoffControlResponderError.invalidManifest
            }
            return ProviderHandoffLineageKeyV1(
                sourceStateRootUUID: sourceRoot,
                authorityLineageUUID: opened.authorityLineageUUID,
                keyVersion: opened.keyVersion,
                rawHMACSHA256Key: opened.rawHMACSHA256Key
            )
        }
    }

    private func recordFailure(
        _ failure: ProviderHandoffPartStagingFailureClassV1,
        in record: ProviderHandoffPartStagingRecordV1
    ) throws {
        _ = try commonStore.update(
            tokenID: record.tokenID,
            manifestID: record.manifestID,
            partKind: record.partKind,
            expectedStagingRevision: record.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.recordFailure(
                failure,
                in: &$0,
                expectedRevision: record.stagingRevision
            )
        }
    }

    private static func failureClass(
        for error: any Error
    ) -> ProviderHandoffPartStagingFailureClassV1 {
        switch error {
        case LoggingHandoffStagingControllerError.containerCollision:
            .collision
        case LoggingHandoffStagingControllerError.destinationSemanticsMismatch,
            LoggingHandoffStagingControllerError.incompatibleHistory,
            LoggingHandoffStagingControllerError.providerHistoryPreflightUnavailable:
            .capability
        case is ProviderHandoffPayloadCodecError,
            is ProviderHandoffCryptoError,
            is ProviderHandoffEnvelopeCodecError:
            .authentication
        case is LoggingHandoffPayloadError:
            .canonicalContent
        default:
            .importEffect
        }
    }

    private static func disposition(
        for error: any Error
    ) -> ContainerEngineProviderHandoffDispositionV1 {
        switch error {
        case LoggingHandoffControlResponderError.destinationUnavailable:
            .recoveryRequired
        case LoggingHandoffStagingControllerError.containerCollision,
            ProviderHandoffPartStagingStoreError.duplicateRecord,
            ProviderHandoffPartStagingStoreError.revisionMismatch:
            .conflict
        case ProviderHandoffBundleObjectStoreError.notFound,
            ProviderHandoffPartStagingStoreError.notFound:
            .retryableFailure
        case ProviderHandoffBundleObjectStoreError.integrityMismatch,
            ProviderHandoffBundleObjectStoreError.invalidMetadata,
            ProviderHandoffPartStagingStoreError.integrityMismatch,
            ProviderHandoffPartStagingStoreError.invalidMetadata,
            ProviderHandoffPossessionProofStoreError.invalidMetadata:
            .recoveryRequired
        case is ProviderHandoffBundleObjectStoreError,
            is ProviderHandoffPartStagingStoreError:
            .retryableFailure
        default:
            .rejected
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case LoggingHandoffStagingControllerError.containerCollision:
            "logging handoff conflicts with an existing destination container"
        case LoggingHandoffControlResponderError.destinationUnavailable:
            "provider handoff logging destination is unavailable"
        case is ProviderHandoffPartControlCodecError:
            "provider handoff logging part request is invalid"
        case is ProviderHandoffTrustError,
            is ProviderHandoffRecordValidationError,
            is ProviderHandoffEnvelopeCodecError,
            is ProviderHandoffCryptoError:
            "provider handoff logging authentication failed"
        case is ProviderHandoffBundleObjectStoreError:
            "provider handoff logging object is unavailable or invalid"
        case is LoggingHandoffPayloadError:
            "provider handoff logging payload is invalid"
        case is LoggingHandoffPromotionControlCodecError,
            LoggingHandoffControlResponderError.invalidPromotionReceipt:
            "provider handoff logging promotion receipt is invalid"
        case LoggingHandoffControlResponderError.invalidGatewayState,
            is ProviderHandoffGatewayStateError,
            is LoggingHandoffPromotionError:
            "provider handoff logging gateway state is not authorized"
        case is LoggingHandoffStagingControllerError:
            "provider handoff logging destination cannot apply the signed request"
        default:
            "provider handoff logging part operation failed"
        }
    }

    private static func requireMediaType(
        _ actual: String,
        _ expected: String
    ) throws {
        guard actual == expected else {
            throw ProviderHandoffPartControlCodecError.invalidRequest
        }
    }

    private static func completed(
        requestID: String,
        body: Data,
        mediaType: String
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        ContainerEngineProviderHandoffControlResultV1(
            response: try ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: .completed,
                bodyMediaType: mediaType,
                body: body
            ),
            body: body
        )
    }

    private static func failure(
        requestID: String,
        disposition: ContainerEngineProviderHandoffDispositionV1,
        message: String
    ) -> ContainerEngineProviderHandoffControlResultV1 {
        let body = Data()
        guard
            let response = try? ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: disposition,
                bodyMediaType:
                    "application/vnd.io.github.stephenlclarke.container.handoff-error.v1+json",
                body: body,
                message: String(
                    decoding: message.utf8.prefix(1_024),
                    as: UTF8.self
                )
            )
        else {
            preconditionFailure("validated provider request produced an invalid response")
        }
        return ContainerEngineProviderHandoffControlResultV1(
            response: response,
            body: body
        )
    }
}
