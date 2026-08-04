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

import ContainerEngineRuntimeSPI
import ContainerLoggingStorage
import ContainerPersistence
import ContainerResource
import Foundation

enum LoggingHandoffStagingControllerError: Error, Equatable, Sendable {
    case containerCollision(String)
    case destinationSemanticsMismatch(String)
    case incompatibleHistory(String)
    case invalidCommonRecord
    case invalidProtectedValue(String)
    case privateStateMismatch
    case protectedReferenceMismatch(String)
    case providerHistoryPreflightUnavailable(String)
}

/// Destination-provider hook for provider-owned remote history.
///
/// Implementations perform capability/export-contract validation only. They
/// must not create a provider session or publish history; effectful import is
/// deferred to destination reconciliation after the signed commit decision.
protocol LoggingHandoffProviderHistoryPreflighting: Sendable {
    func preflightProviderHistory(
        containerID: String,
        history: LoggingHandoffHistoryStoreV1,
        destination: PreparedContainerLogResolution,
        handoffManifestDigestSHA256: String,
        destinationStateRootUUID: String
    ) async throws
}

struct LoggingHandoffStagingResultV1: Equatable, Sendable {
    let commonRecord: ProviderHandoffPartStagingRecordV1
    let receipt: LoggingProtectedOptionStagingReceiptV1
    let privateState: LoggingHandoffPrivateStagingStateV1
}

/// Logging controller participant for the common provider handoff protocol.
///
/// Validation is completed for the whole `.logging` package before the first
/// protected object is published. The controller then freezes one private
/// plan/receipt, publishes deterministic per-container protected objects, and
/// finally compare-and-swaps the common part from `contentVerified` to
/// `imported`. A crash at any point reuses the same plan and references.
actor LoggingHandoffStagingController {
    private static let destinationLeaseGeneration: UInt64 = 1
    private static let currentHistoryFormatVersion: UInt32 = 1

    private struct PreparedContainer: Sendable {
        let source: LoggingHandoffContainerRecordV1
        let prepared: PreparedContainerLogResolution
        let binding: LoggingProtectedOptionsBinding
        let protectedValues: [String: String]
        let protectedFrames: [LoggingHandoffProtectedValueFrameV1]
        let histories: [(entryID: String, value: LoggingHandoffHistoryStoreV1)]
        let idempotencyKey: Data
    }

    private struct FrozenPlan: Sendable {
        let preparedContainers: [PreparedContainer]
        let receipt: LoggingProtectedOptionStagingReceiptV1
        let privateState: LoggingHandoffPrivateStagingStateV1
    }

    private let defaults: LoggingConfig
    private let commonStore: ProviderHandoffPartStagingStore
    private let protectedOptionsStore: LoggingProtectedOptionsStore
    private let receiptStore: LoggingHandoffProtectedReceiptStore
    private let providerHistoryPreflight: (any LoggingHandoffProviderHistoryPreflighting)?
    private let destinationStateRootUUID: String?

    init(
        defaults: LoggingConfig,
        commonStore: ProviderHandoffPartStagingStore,
        protectedOptionsStore: LoggingProtectedOptionsStore,
        receiptStore: LoggingHandoffProtectedReceiptStore,
        providerHistoryPreflight:
            (any LoggingHandoffProviderHistoryPreflighting)? = nil,
        destinationStateRootUUID: String? = nil
    ) {
        self.defaults = defaults
        self.commonStore = commonStore
        self.protectedOptionsStore = protectedOptionsStore
        self.receiptStore = receiptStore
        self.providerHistoryPreflight = providerHistoryPreflight
        self.destinationStateRootUUID = destinationStateRootUUID
    }

    func stage(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        catalog: LogDriverCatalog,
        occupiedContainerIDs: Set<String> = []
    ) async throws -> LoggingHandoffStagingResultV1 {
        try Self.validateCommonRecord(commonRecord, allowing: [.contentVerified, .imported])
        if commonRecord.state == .imported {
            return try await loadImported(
                commonRecord: commonRecord,
                payload: payload
            )
        }

        let plan = try await freezePlan(
            commonRecord: commonRecord,
            payload: payload,
            catalog: catalog,
            occupiedContainerIDs: occupiedContainerIDs
        )
        _ = try await receiptStore.seal(
            plan.receipt,
            privateStagingState: plan.privateState.canonicalBytes()
        )

        for container in plan.preparedContainers
        where !container.protectedValues.isEmpty {
            let reference = try await protectedOptionsStore.storeForHandoff(
                container.protectedValues,
                boundTo: container.binding,
                idempotencyKey: container.idempotencyKey
            )
            guard
                reference
                    == plan.privateState.containers.first(where: {
                        $0.containerID == container.source.containerID
                    })?.configuration.resolved?.protectedOptionReference
            else {
                throw
                    LoggingHandoffStagingControllerError
                    .protectedReferenceMismatch(container.source.containerID)
            }
        }

        let imported: ProviderHandoffPartStagingRecordV1
        do {
            imported = try commonStore.update(
                tokenID: commonRecord.tokenID,
                manifestID: commonRecord.manifestID,
                partKind: .logging,
                expectedStagingRevision: commonRecord.stagingRevision
            ) {
                try ProviderHandoffPartStagingStateMachine.recordImported(
                    receiptDigestSHA256: plan.receipt.receiptDigestSHA256,
                    in: &$0,
                    expectedRevision: commonRecord.stagingRevision
                )
            }
        } catch ProviderHandoffPartStagingStoreError.revisionMismatch {
            let current = try commonStore.load(
                tokenID: commonRecord.tokenID,
                manifestID: commonRecord.manifestID,
                partKind: .logging
            )
            guard
                current.state == .imported,
                current.stagedImportReceiptDigestSHA256
                    == plan.receipt.receiptDigestSHA256
            else {
                throw ProviderHandoffPartStagingStoreError.revisionMismatch(
                    expected: commonRecord.stagingRevision,
                    actual: current.stagingRevision
                )
            }
            imported = current
        }
        return LoggingHandoffStagingResultV1(
            commonRecord: imported,
            receipt: plan.receipt,
            privateState: plan.privateState
        )
    }

    /// Idempotently removes every tentative protected effect before abort.
    /// The protected receipt is retained until the common record durably says
    /// `compensated`, so a crash after object deletion can resume exactly.
    func compensate(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        catalog: LogDriverCatalog
    ) async throws -> ProviderHandoffPartStagingRecordV1 {
        try Self.validateCommonRecord(
            commonRecord,
            allowing: [.contentVerified, .imported, .compensationRequired, .compensated]
        )
        if commonRecord.state == .compensated {
            if let receiptDigest = commonRecord.stagedImportReceiptDigestSHA256 {
                try await receiptStore.delete(receiptDigest)
            }
            return commonRecord
        }

        let sealed: LoggingHandoffSealedProtectedReceiptV1
        if let receiptDigest = commonRecord.stagedImportReceiptDigestSHA256 {
            sealed = try await receiptStore.loadSealed(receiptDigest)
        } else {
            let plan = try await freezePlan(
                commonRecord: commonRecord,
                payload: payload,
                catalog: catalog,
                occupiedContainerIDs: []
            )
            sealed = try await receiptStore.seal(
                plan.receipt,
                privateStagingState: plan.privateState.canonicalBytes()
            )
        }
        try sealed.receipt.validate(commonRecord: commonRecord)
        let privateState =
            try LoggingHandoffPrivateStagingStateV1
            .decodeCanonicalBytes(
                sealed.privateStagingState,
                receipt: sealed.receipt
            )

        let compensationRequired: ProviderHandoffPartStagingRecordV1
        if commonRecord.state == .compensationRequired {
            compensationRequired = commonRecord
        } else {
            compensationRequired = try commonStore.update(
                tokenID: commonRecord.tokenID,
                manifestID: commonRecord.manifestID,
                partKind: .logging,
                expectedStagingRevision: commonRecord.stagingRevision
            ) {
                try ProviderHandoffPartStagingStateMachine.requireCompensation(
                    receiptDigestSHA256: sealed.receipt.receiptDigestSHA256,
                    in: &$0,
                    expectedRevision: commonRecord.stagingRevision
                )
            }
        }

        for container in privateState.containers {
            guard
                let reference = container.configuration.resolved?
                    .protectedOptionReference
            else {
                continue
            }
            let binding = try LoggingProtectedOptionsBinding(
                containerID: container.containerID,
                configuration: container.configuration
            )
            try await protectedOptionsStore.delete(reference, boundTo: binding)
        }

        let compensated = try commonStore.update(
            tokenID: compensationRequired.tokenID,
            manifestID: compensationRequired.manifestID,
            partKind: .logging,
            expectedStagingRevision: compensationRequired.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.recordCompensated(
                in: &$0,
                expectedRevision: compensationRequired.stagingRevision
            )
        }
        try await receiptStore.delete(sealed.receipt.receiptDigestSHA256)
        return compensated
    }

    func loadImported(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1
    ) async throws -> LoggingHandoffStagingResultV1 {
        try Self.validateCommonRecord(commonRecord, allowing: [.imported])
        guard let receiptDigest = commonRecord.stagedImportReceiptDigestSHA256 else {
            throw LoggingHandoffStagingControllerError.invalidCommonRecord
        }
        let sealed = try await receiptStore.loadSealed(receiptDigest)
        try sealed.receipt.validate(commonRecord: commonRecord)
        let privateState =
            try LoggingHandoffPrivateStagingStateV1
            .decodeCanonicalBytes(
                sealed.privateStagingState,
                receipt: sealed.receipt
            )
        try Self.validate(privateState: privateState, against: payload)
        try await verifyProtectedObjects(
            privateState: privateState,
            receipt: sealed.receipt,
            payload: payload
        )
        return LoggingHandoffStagingResultV1(
            commonRecord: commonRecord,
            receipt: sealed.receipt,
            privateState: privateState
        )
    }

    /// Promotes the frozen logging import only while the verified gateway
    /// transaction is durably in `reconciling` after its signed commit.
    func reconcile(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        validatedCommit: ProviderHandoffValidatedCommitRecordV1,
        gatewayState: ProviderHandoffGatewayStateV1,
        destination: any LoggingHandoffDestinationReconciling
    ) async throws -> LoggingHandoffControllerPromotionReceiptV1 {
        let imported = try await loadImported(
            commonRecord: commonRecord,
            payload: payload
        )
        let authorization = try Self.promotionAuthorization(
            commonRecord: commonRecord,
            validatedCommit: validatedCommit,
            gatewayState: gatewayState,
            allowedPhase: .reconciling
        )
        let promotionReceipt = try await destination.promoteLogging(
            privateState: imported.privateState,
            payload: payload,
            authorization: authorization,
            protectedReceipt: imported.receipt
        )
        try promotionReceipt.validate(
            authorization: authorization,
            protectedStagingReceiptDigestSHA256:
                imported.receipt.receiptDigestSHA256,
            privateState: imported.privateState
        )
        return promotionReceipt
    }

    /// Makes promoted logging visible only after a verified signed Complete
    /// outcome and a matching destination-active root are durable.
    func activate(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        validatedCommit: ProviderHandoffValidatedCommitRecordV1,
        validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        gatewayState: ProviderHandoffGatewayStateV1,
        destination: any LoggingHandoffDestinationReconciling
    ) async throws {
        let imported = try await loadImported(
            commonRecord: commonRecord,
            payload: payload
        )
        let promotionAuthorization = try Self.promotionAuthorization(
            commonRecord: commonRecord,
            validatedCommit: validatedCommit,
            gatewayState: gatewayState,
            allowedPhase: .complete
        )
        try promotionReceipt.validate(
            authorization: promotionAuthorization,
            protectedStagingReceiptDigestSHA256:
                imported.receipt.receiptDigestSHA256,
            privateState: imported.privateState
        )
        let activationAuthorization = try Self.activationAuthorization(
            promotionAuthorization: promotionAuthorization,
            validatedOutcome: validatedOutcome,
            gatewayState: gatewayState
        )
        try await destination.activateLogging(
            privateState: imported.privateState,
            payload: payload,
            promotionReceipt: promotionReceipt,
            authorization: activationAuthorization
        )
    }

    private func freezePlan(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        catalog: LogDriverCatalog,
        occupiedContainerIDs: Set<String>
    ) async throws -> FrozenPlan {
        var preparedContainers: [PreparedContainer] = []
        var inodeOwners = Set<String>()
        for source in payload.containers {
            guard !occupiedContainerIDs.contains(source.containerID) else {
                throw
                    LoggingHandoffStagingControllerError
                    .containerCollision(source.containerID)
            }
            let frames = payload.protectedValues.filter {
                $0.descriptor.containerID == source.containerID
            }
            let protectedValues = try Self.protectedValues(frames)
            var requestOptions = source.requested.safeOptions
            for name in source.requested.protectedOptionNames {
                guard let value = protectedValues[name] else {
                    throw
                        LoggingHandoffStagingControllerError
                        .invalidProtectedValue(source.containerID)
                }
                requestOptions[name] = value
            }
            let request = ContainerLogRequest(
                driver: source.requested.driver,
                options: requestOptions
            )
            let prepared = try ContainerLogRequestResolver(
                defaults: defaults,
                catalog: catalog
            ).prepare(request)
            try Self.validateDestinationSemantics(
                source: source,
                prepared: prepared,
                protectedValues: protectedValues
            )
            let histories = try await validateHistories(
                source: source,
                payload: payload,
                destination: prepared,
                handoffTokenID: commonRecord.tokenID,
                handoffManifestID: commonRecord.manifestID,
                handoffManifestDigestSHA256: commonRecord.manifestDigest,
                inodeOwners: &inodeOwners
            )
            let binding = LoggingProtectedOptionsBinding(
                containerID: source.containerID,
                prepared: prepared,
                leaseGeneration: Self.destinationLeaseGeneration
            )
            preparedContainers.append(
                PreparedContainer(
                    source: source,
                    prepared: prepared,
                    binding: binding,
                    protectedValues: protectedValues,
                    protectedFrames: frames,
                    histories: histories,
                    idempotencyKey: try Self.idempotencyKey(
                        commonRecord: commonRecord,
                        containerID: source.containerID
                    )
                ))
        }

        var importedEntries: [ImportedProtectedLoggingOptionV1] = []
        var stagedContainers: [LoggingHandoffStagedContainerV1] = []
        for container in preparedContainers {
            let reference: LoggingProtectedOptionsReference?
            if container.protectedValues.isEmpty {
                reference = nil
            } else {
                reference = try await protectedOptionsStore.referenceForHandoff(
                    container.protectedValues,
                    boundTo: container.binding,
                    idempotencyKey: container.idempotencyKey
                )
            }
            let configuration = try container.prepared.finalizedConfiguration(
                protectedReference: reference,
                leaseGeneration: Self.destinationLeaseGeneration
            )
            if let reference {
                importedEntries.append(
                    contentsOf: try container.protectedFrames.map {
                        try LoggingProtectedOptionStagingReceiptV1.importedEntry(
                            frame: $0,
                            destinationReference: reference
                        )
                    })
            }
            stagedContainers.append(
                LoggingHandoffStagedContainerV1(
                    containerID: container.source.containerID,
                    configuration: configuration,
                    protectedEntryIDs: container.source.protectedEntryIDs,
                    histories: container.histories.map {
                        LoggingHandoffStagedHistoryV1(
                            entryID: $0.entryID,
                            containerID: container.source.containerID,
                            history: $0.value
                        )
                    },
                    sourceTerminalAudit: container.source.terminalAudit
                ))
        }
        importedEntries.sort { Self.utf8Less($0.entryID, $1.entryID) }
        stagedContainers.sort { Self.utf8Less($0.containerID, $1.containerID) }
        let contentDigest = try Self.verifiedContentDigest(commonRecord)
        let receipt = try LoggingProtectedOptionStagingReceiptV1(
            handoffTokenID: commonRecord.tokenID,
            handoffManifestID: commonRecord.manifestID,
            handoffManifestDigest: commonRecord.manifestDigest,
            bundleObjectID: commonRecord.bundleObjectID,
            payloadDescriptorDigestSHA256:
                commonRecord.payloadDescriptorDigestSHA256,
            verifiedCanonicalContentDigest: contentDigest,
            importedEntries: importedEntries
        )
        let privateState = try LoggingHandoffPrivateStagingStateV1(
            receipt: receipt,
            containers: stagedContainers
        )
        try Self.validate(privateState: privateState, against: payload)
        return FrozenPlan(
            preparedContainers: preparedContainers,
            receipt: receipt,
            privateState: privateState
        )
    }

    private func validateHistories(
        source: LoggingHandoffContainerRecordV1,
        payload: LoggingHandoffDecodedPayloadV1,
        destination: PreparedContainerLogResolution,
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigestSHA256: String,
        inodeOwners: inout Set<String>
    ) async throws -> [(entryID: String, value: LoggingHandoffHistoryStoreV1)] {
        var values: [(entryID: String, value: LoggingHandoffHistoryStoreV1)] = []
        var rotationOwners = Set<String>()
        var localRotationIndices: [String: Set<UInt64>] = [:]
        var historyEpochs = Set<UInt64>()
        var nativeSequenceRanges: [(rotationIndex: UInt64, minimum: UInt64, maximum: UInt64)] = []
        for entryID in source.historyEntryIDs {
            guard let history = payload.historyStores[entryID] else {
                throw LoggingHandoffStagingControllerError.incompatibleHistory(
                    entryID
                )
            }
            guard history.formatVersion == Self.currentHistoryFormatVersion else {
                throw LoggingHandoffStagingControllerError.incompatibleHistory(
                    entryID
                )
            }
            switch history.disposition {
            case .explicitResolutionRequired, .retainOffline:
                throw LoggingHandoffStagingControllerError.incompatibleHistory(
                    entryID
                )
            case .importVerified:
                guard
                    history.kind != .providerOwned,
                    let bytes = history.bytes,
                    Self.historyKind(
                        history.kind,
                        matches: destination
                    ),
                    Self.historyRotation(
                        history.rotationIndex,
                        compressed: history.compressed,
                        fits: destination
                    )
                else {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
                do {
                    if let range = try Self.validateImportedHistory(
                        history,
                        bytes: bytes
                    ) {
                        nativeSequenceRanges.append(
                            (
                                history.rotationIndex,
                                range.minimum,
                                range.maximum
                            ))
                    }
                } catch {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
            case .providerExportVerified:
                guard
                    history.kind == .providerOwned,
                    let export = history.providerExportReceipt,
                    history.providerExportDigestSHA256
                        == export.exportReceiptDigestSHA256,
                    export.request.containerID == source.containerID,
                    export.request.tokenID == handoffTokenID,
                    export.request.manifestID == handoffManifestID,
                    destination.readPolicy.source == .direct
                else {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
                guard let providerHistoryPreflight else {
                    throw
                        LoggingHandoffStagingControllerError
                        .providerHistoryPreflightUnavailable(entryID)
                }
                guard
                    let destinationStateRootUUID,
                    export.request.destinationStateRootUUID
                        == destinationStateRootUUID
                else {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
                try await providerHistoryPreflight.preflightProviderHistory(
                    containerID: source.containerID,
                    history: history,
                    destination: destination,
                    handoffManifestDigestSHA256:
                        handoffManifestDigestSHA256,
                    destinationStateRootUUID: destinationStateRootUUID
                )
            case .empty:
                guard
                    history.bytes == nil,
                    Self.historyKind(history.kind, matches: destination)
                        || (history.kind == .providerOwned
                            && destination.readPolicy.source == .direct
                            && destination.descriptor.capabilities
                                .requiresDeliverySession)
                else {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
            }
            if history.disposition == .importVerified
                || history.disposition == .empty,
                Self.isLocalHistoryKind(history.kind)
            {
                localRotationIndices[history.kind.rawValue, default: []]
                    .insert(history.rotationIndex)
            }
            historyEpochs.insert(history.terminalHistoryEpoch)
            let rotationKey = "\(history.kind.rawValue):\(history.rotationIndex)"
            guard rotationOwners.insert(rotationKey).inserted else {
                throw LoggingHandoffStagingControllerError.incompatibleHistory(
                    entryID
                )
            }
            if let device = history.sourceDeviceID, let inode = history.sourceInode {
                let inodeKey = "\(device):\(inode)"
                guard inodeOwners.insert(inodeKey).inserted else {
                    throw
                        LoggingHandoffStagingControllerError
                        .incompatibleHistory(entryID)
                }
            }
            values.append((entryID, history))
        }
        guard historyEpochs.count <= 1 else {
            throw LoggingHandoffStagingControllerError.incompatibleHistory(
                source.containerID
            )
        }
        for rotations in localRotationIndices.values {
            let ordered = rotations.sorted()
            guard
                ordered.first == 0,
                ordered.enumerated().allSatisfy({ offset, value in
                    value == UInt64(offset)
                })
            else {
                throw LoggingHandoffStagingControllerError.incompatibleHistory(
                    source.containerID
                )
            }
        }
        let orderedRanges = nativeSequenceRanges.sorted {
            $0.rotationIndex > $1.rotationIndex
        }
        for pair in zip(orderedRanges, orderedRanges.dropFirst())
        where pair.0.maximum >= pair.1.minimum {
            throw LoggingHandoffStagingControllerError.incompatibleHistory(
                source.containerID
            )
        }
        return values
    }

    private func verifyProtectedObjects(
        privateState: LoggingHandoffPrivateStagingStateV1,
        receipt: LoggingProtectedOptionStagingReceiptV1,
        payload: LoggingHandoffDecodedPayloadV1
    ) async throws {
        for container in privateState.containers {
            let frames = payload.protectedValues.filter {
                $0.descriptor.containerID == container.containerID
            }
            let expected = try Self.protectedValues(frames)
            guard
                let reference = container.configuration.resolved?
                    .protectedOptionReference
            else {
                guard expected.isEmpty else {
                    throw
                        LoggingHandoffStagingControllerError
                        .protectedReferenceMismatch(container.containerID)
                }
                continue
            }
            let binding = try LoggingProtectedOptionsBinding(
                containerID: container.containerID,
                configuration: container.configuration
            )
            let actual = try await protectedOptionsStore.load(
                reference,
                boundTo: binding
            )
            guard actual == expected else {
                throw
                    LoggingHandoffStagingControllerError
                    .protectedReferenceMismatch(container.containerID)
            }
            let receiptReferences = receipt.importedEntries.filter {
                container.protectedEntryIDs.contains($0.entryID)
            }.map(\.destinationReference)
            guard receiptReferences.allSatisfy({ $0 == reference }) else {
                throw
                    LoggingHandoffStagingControllerError
                    .protectedReferenceMismatch(container.containerID)
            }
        }
    }

    private static func validateDestinationSemantics(
        source: LoggingHandoffContainerRecordV1,
        prepared: PreparedContainerLogResolution,
        protectedValues: [String: String]
    ) throws {
        let sourceResolved = source.sourceResolved
        let destinationProtectedValues = prepared.protectedOptions.withValues { $0 }
        guard
            prepared.requestedDriver == source.requested.driver,
            prepared.requestedSafeOptions == source.requested.safeOptions,
            prepared.requestedProtectedOptionNames
                == source.requested.protectedOptionNames,
            prepared.descriptor.driver == sourceResolved.driver,
            prepared.safeOptions == sourceResolved.safeOptions,
            prepared.protectedOptions.names
                == sourceResolved.protectedOptionNames,
            destinationProtectedValues == protectedValues,
            prepared.delivery == sourceResolved.delivery,
            prepared.readPolicy == sourceResolved.readPolicy
        else {
            throw
                LoggingHandoffStagingControllerError
                .destinationSemanticsMismatch(source.containerID)
        }
    }

    private static func validate(
        privateState: LoggingHandoffPrivateStagingStateV1,
        against payload: LoggingHandoffDecodedPayloadV1
    ) throws {
        guard
            privateState.containers.map(\.containerID)
                == payload.containers.map(\.containerID)
        else {
            throw LoggingHandoffStagingControllerError.privateStateMismatch
        }
        for staged in privateState.containers {
            guard
                let source = payload.containers.first(where: {
                    $0.containerID == staged.containerID
                }),
                staged.configuration.requested == source.requested,
                staged.protectedEntryIDs == source.protectedEntryIDs,
                staged.sourceTerminalAudit == source.terminalAudit,
                staged.histories.map(\.entryID) == source.historyEntryIDs
            else {
                throw LoggingHandoffStagingControllerError.privateStateMismatch
            }
            for history in staged.histories {
                guard
                    let payloadHistory = payload.historyStores[history.entryID],
                    history.matches(payloadHistory)
                else {
                    throw LoggingHandoffStagingControllerError.privateStateMismatch
                }
            }
        }
    }

    private static func protectedValues(
        _ frames: [LoggingHandoffProtectedValueFrameV1]
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        for frame in frames {
            guard
                let value = String(data: frame.value, encoding: .utf8),
                Data(value.utf8) == frame.value,
                values[frame.optionName] == nil
            else {
                throw
                    LoggingHandoffStagingControllerError
                    .invalidProtectedValue(frame.descriptor.entryID)
            }
            values[frame.optionName] = value
        }
        return values
    }

    private static func historyKind(
        _ kind: LoggingHandoffHistoryKindV1,
        matches destination: PreparedContainerLogResolution
    ) -> Bool {
        switch kind {
        case .dockerJSONFile:
            destination.descriptor.driver == "json-file"
                && destination.readPolicy.source == .direct
        case .nativeLocal:
            destination.descriptor.driver == "local"
                && destination.readPolicy.source == .direct
        case .dualCache:
            destination.readPolicy.source == .dualCache
        case .legacyLocalV1:
            false
        case .providerOwned:
            false
        }
    }

    private static func isLocalHistoryKind(
        _ kind: LoggingHandoffHistoryKindV1
    ) -> Bool {
        switch kind {
        case .dockerJSONFile, .nativeLocal, .dualCache:
            true
        case .legacyLocalV1, .providerOwned:
            false
        }
    }

    private static func validateImportedHistory(
        _ history: LoggingHandoffHistoryStoreV1,
        bytes: Data
    ) throws -> (minimum: UInt64, maximum: UInt64)? {
        switch history.kind {
        case .dockerJSONFile:
            _ = try DockerJSONFileHandoffSegmentValidator.inspect(
                bytes,
                compressed: history.compressed
            )
            return nil
        case .nativeLocal, .dualCache:
            let inspection = try NativeLocalLogHandoffSegmentValidator.inspect(
                bytes,
                compressed: history.compressed
            )
            guard
                inspection.maximumInternalSequence
                    == history.maximumInternalSequence
            else {
                throw
                    LoggingHandoffStagingControllerError
                    .incompatibleHistory(history.storeID)
            }
            return inspection.minimumInternalSequence.map {
                ($0, inspection.maximumInternalSequence)
            }
        case .legacyLocalV1, .providerOwned:
            throw
                LoggingHandoffStagingControllerError
                .incompatibleHistory(history.storeID)
        }
    }

    private static func historyRotation(
        _ rotationIndex: UInt64,
        compressed: Bool,
        fits destination: PreparedContainerLogResolution
    ) -> Bool {
        let maximumFileCount: Int
        let compressionEnabled: Bool
        if destination.readPolicy.source == .dualCache,
            let cache = destination.readPolicy.cache
        {
            maximumFileCount = cache.maxFileCount
            compressionEnabled = cache.compress
        } else {
            maximumFileCount =
                destination.safeOptions["max-file"]
                .flatMap(Int.init)
                ?? destination.descriptor.capabilities.fileDefaults?
                .maxFileCount
                ?? 0
            compressionEnabled =
                destination.safeOptions["compress"]
                .flatMap(ContainerLogOptionValueParser.boolean)
                ?? destination.descriptor.capabilities.fileDefaults?
                .compress
                ?? false
        }
        return
            maximumFileCount > 0
            && rotationIndex < UInt64(maximumFileCount)
            && (!compressed || (rotationIndex > 0 && compressionEnabled))
    }

    private static func idempotencyKey(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        containerID: String
    ) throws -> Data {
        let digest = try ProviderHandoffDigest.domain(
            "container-handoff-logging-protected-object-idempotency-v1",
            projection: .map([
                .init("bundleObjectID", .textString(commonRecord.bundleObjectID)),
                .init("containerID", .textString(containerID)),
                .init(
                    "manifestDigest",
                    .byteString(
                        try ProviderHandoffDigest.parseSHA256(commonRecord.manifestDigest)
                    )),
                .init("manifestID", .textString(commonRecord.manifestID)),
                .init(
                    "payloadDescriptorDigest",
                    .byteString(
                        try ProviderHandoffDigest.parseSHA256(
                            commonRecord.payloadDescriptorDigestSHA256
                        )
                    )),
                .init("tokenID", .textString(commonRecord.tokenID)),
                .init(
                    "verifiedCanonicalContentDigest",
                    .byteString(
                        try ProviderHandoffDigest.parseSHA256(
                            verifiedContentDigest(commonRecord)
                        )
                    )),
            ])
        )
        return try ProviderHandoffDigest.parseSHA256(digest)
    }

    private static func validateCommonRecord(
        _ record: ProviderHandoffPartStagingRecordV1,
        allowing states: [ProviderHandoffPartStagingStateV1]
    ) throws {
        guard
            record.partKind == .logging,
            states.contains(record.state),
            record.verifiedCanonicalContentDigest != nil
        else {
            throw LoggingHandoffStagingControllerError.invalidCommonRecord
        }
        try ProviderHandoffPartStagingStateMachine.validate(record)
    }

    private static func promotionAuthorization(
        commonRecord: ProviderHandoffPartStagingRecordV1,
        validatedCommit: ProviderHandoffValidatedCommitRecordV1,
        gatewayState: ProviderHandoffGatewayStateV1,
        allowedPhase: ProviderHandoffPhaseV1
    ) throws -> LoggingHandoffPromotionAuthorizationV1 {
        try ProviderHandoffGatewayStateMachine.validate(gatewayState)
        let record = validatedCommit.record
        let intent = record.intent
        guard
            allowedPhase == .reconciling || allowedPhase == .complete,
            let transaction = gatewayState.transactions.first(where: {
                $0.token.tokenID == commonRecord.tokenID
            }),
            transaction.token.phase == allowedPhase,
            transaction.commitRecord == record,
            transaction.token.manifestID == commonRecord.manifestID,
            transaction.token.manifestDigest == commonRecord.manifestDigest,
            transaction.token.commitDigestSHA256 == record.commitDigestSHA256,
            transaction.token.handoffChainHeadDigestSHA256
                == record.handoffChainHeadDigestSHA256,
            intent.tokenID == commonRecord.tokenID,
            intent.manifestID == commonRecord.manifestID,
            intent.manifestDigest == commonRecord.manifestDigest,
            intent.importedParts.contains(where: {
                $0.partKind == .logging
                    && $0.payloadDescriptorDigestSHA256
                        == commonRecord.payloadDescriptorDigestSHA256
                    && $0.stagedImportReceiptDigestSHA256
                        == commonRecord.stagedImportReceiptDigestSHA256
            }),
            let destinationRoot = record.postCommitRoots.first(where: {
                $0.role == .destination
                    && $0.stateRootUUID
                        == transaction.token.destinationStateRootUUID
            }),
            destinationRoot.postCommitHeader.handoffState
                == .destinationReconciling,
            destinationRoot.postCommitHeader.activeHandoffTokenID
                == commonRecord.tokenID,
            destinationRoot.postCommitHeader.handoffChainHeadDigest
                == record.handoffChainHeadDigestSHA256,
            destinationRoot.postCommitHeader.selectedProviderFingerprint
                == transaction.token.destinationProviderFingerprint,
            gatewayState.providerSelection.selectedProviderFingerprint
                == transaction.token.destinationProviderFingerprint,
            gatewayState.providerSelection.selectedStateRootUUID
                == transaction.token.destinationStateRootUUID,
            gatewayState.socketDiscovery.selectedProviderFingerprint
                == transaction.token.destinationProviderFingerprint,
            gatewayState.socketDiscovery.selectedStateRootUUID
                == transaction.token.destinationStateRootUUID,
            allowedPhase == .reconciling
                ? gatewayState.activeTokenID == commonRecord.tokenID
                : gatewayState.activeTokenID == nil
        else {
            throw LoggingHandoffPromotionError.promotionNotAuthorized
        }
        return LoggingHandoffPromotionAuthorizationV1(
            tokenID: commonRecord.tokenID,
            manifestID: commonRecord.manifestID,
            manifestDigest: commonRecord.manifestDigest,
            commitDigestSHA256: record.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                record.handoffChainHeadDigestSHA256,
            destinationProviderFingerprint:
                transaction.token.destinationProviderFingerprint,
            destinationStateRootUUID:
                transaction.token.destinationStateRootUUID
        )
    }

    private static func activationAuthorization(
        promotionAuthorization: LoggingHandoffPromotionAuthorizationV1,
        validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        gatewayState: ProviderHandoffGatewayStateV1
    ) throws -> LoggingHandoffActivationAuthorizationV1 {
        let outcome = validatedOutcome.outcome
        guard
            let transaction = gatewayState.transactions.first(where: {
                $0.token.tokenID == promotionAuthorization.tokenID
            }),
            transaction.token.phase == .complete,
            transaction.terminalOutcome == outcome,
            transaction.token.terminalOutcomeDigestSHA256
                == outcome.outcomeDigestSHA256,
            outcome.phase == .complete,
            outcome.tokenID == promotionAuthorization.tokenID,
            outcome.manifestID == promotionAuthorization.manifestID,
            outcome.manifestDigest == promotionAuthorization.manifestDigest,
            let destinationRoot = outcome.roots.first(where: {
                $0.role == .destination
                    && $0.stateRootUUID
                        == promotionAuthorization.destinationStateRootUUID
            }),
            destinationRoot.terminalHeader.handoffState == .destinationActive,
            destinationRoot.terminalHeader.activeHandoffTokenID == nil,
            destinationRoot.terminalHeader.handoffChainHeadDigest
                == promotionAuthorization.handoffChainHeadDigestSHA256,
            destinationRoot.terminalHeader.selectedProviderFingerprint
                == promotionAuthorization.destinationProviderFingerprint
        else {
            throw LoggingHandoffPromotionError.activationNotAuthorized
        }
        return LoggingHandoffActivationAuthorizationV1(
            tokenID: promotionAuthorization.tokenID,
            manifestID: promotionAuthorization.manifestID,
            manifestDigest: promotionAuthorization.manifestDigest,
            commitDigestSHA256: promotionAuthorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                promotionAuthorization.handoffChainHeadDigestSHA256,
            terminalOutcomeDigestSHA256: outcome.outcomeDigestSHA256,
            destinationProviderFingerprint:
                promotionAuthorization.destinationProviderFingerprint,
            destinationStateRootUUID:
                promotionAuthorization.destinationStateRootUUID
        )
    }

    private static func verifiedContentDigest(
        _ record: ProviderHandoffPartStagingRecordV1
    ) throws -> String {
        guard let value = record.verifiedCanonicalContentDigest else {
            throw LoggingHandoffStagingControllerError.invalidCommonRecord
        }
        return value
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
