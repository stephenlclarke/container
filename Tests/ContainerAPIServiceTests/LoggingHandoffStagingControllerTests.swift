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
import ContainerPersistence
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIService
@testable import ContainerLoggingStorage

struct LoggingHandoffStagingControllerTests {
    @Test
    func `stage is idempotent and compensation removes exact protected effects`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors
                    + [descriptor]
            )
            let common = try contentVerifiedRecord(store: stores.common)
            let payload = try decodedPayload(descriptor: descriptor)
            let controller = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )

            let staged = try await controller.stage(
                commonRecord: common,
                payload: payload,
                catalog: catalog
            )
            #expect(staged.commonRecord.state == .imported)
            #expect(staged.receipt.importedEntries.count == 1)
            let container = try #require(staged.privateState.containers.first)
            let resolved = try #require(container.configuration.resolved)
            #expect(resolved.leaseGeneration == 1)
            #expect(resolved.providerGenerationAtResolution == 1)
            #expect(resolved.protectedOptionNames == ["token"])
            #expect(try protectedObjectCount(stores.protectedRoot) == 1)
            #expect(try receiptCount(stores.receiptRoot) == 1)

            let replay = try await controller.stage(
                commonRecord: staged.commonRecord,
                payload: payload,
                catalog: catalog
            )
            #expect(replay == staged)
            #expect(try protectedObjectCount(stores.protectedRoot) == 1)

            let compensated = try await controller.compensate(
                commonRecord: replay.commonRecord,
                payload: payload,
                catalog: catalog
            )
            #expect(compensated.state == .compensated)
            #expect(try protectedObjectCount(stores.protectedRoot) == 0)
            #expect(try receiptCount(stores.receiptRoot) == 0)

            let repeated = try await controller.compensate(
                commonRecord: compensated,
                payload: payload,
                catalog: catalog
            )
            #expect(repeated == compensated)
        }
    }

    @Test
    func `destination semantic mismatch fails before staging effects`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors
                    + [descriptor]
            )
            let common = try contentVerifiedRecord(store: stores.common)
            let payload = try decodedPayload(
                descriptor: descriptor,
                sourceAddsNonBlockingDefault: true
            )
            let controller = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )

            await #expect(
                throws:
                    LoggingHandoffStagingControllerError
                    .destinationSemanticsMismatch("container-1")
            ) {
                _ = try await controller.stage(
                    commonRecord: common,
                    payload: payload,
                    catalog: catalog
                )
            }
            #expect(try protectedObjectCount(stores.protectedRoot) == 0)
            #expect(try receiptCount(stores.receiptRoot) == 0)
            #expect(
                try stores.common.load(
                    tokenID: common.tokenID,
                    manifestID: common.manifestID,
                    partKind: .logging
                ).state == .contentVerified
            )
        }
    }

    @Test
    func `local history requires a contiguous rotation set beginning at active`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor()
            let common = try contentVerifiedRecord(store: stores.common)
            let missingActive = try LoggingHandoffHistoryStoreV1(
                storeID: "dual-cache:1",
                kind: .dualCache,
                disposition: .importVerified,
                formatVersion: 1,
                rotationIndex: 1,
                compressed: false,
                terminalHistoryEpoch: 12,
                maximumInternalSequence: 99,
                sourceDeviceID: 17,
                sourceInode: 30,
                bytes: try nativeHistory(sequence: 99)
            )
            let payload = try decodedPayload(
                descriptor: descriptor,
                historyStores: ["missing-active": missingActive]
            )
            let controller = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )

            await #expect(
                throws:
                    LoggingHandoffStagingControllerError
                    .incompatibleHistory("container-1")
            ) {
                _ = try await controller.stage(
                    commonRecord: common,
                    payload: payload,
                    catalog: try LogDriverCatalog(
                        descriptors: BuiltinLogDriverDescriptors.current
                            .descriptors + [descriptor]
                    )
                )
            }
            #expect(try protectedObjectCount(stores.protectedRoot) == 0)
            #expect(try receiptCount(stores.receiptRoot) == 0)
        }
    }

    @Test
    func `direct remote driver accepts an explicitly empty provider history`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor(
                nativeRead: true,
                supportsDualCache: false
            )
            let common = try contentVerifiedRecord(store: stores.common)
            let empty = try LoggingHandoffHistoryStoreV1(
                storeID: "provider:0",
                kind: .providerOwned,
                disposition: .empty,
                formatVersion: 1,
                rotationIndex: 0,
                terminalHistoryEpoch: 12,
                maximumInternalSequence: 0,
                sourceDeviceID: nil,
                sourceInode: nil,
                bytes: nil
            )
            let payload = try decodedPayload(
                descriptor: descriptor,
                readPolicy: try LogReadPolicy(source: .direct),
                historyStores: ["empty-provider": empty]
            )
            let controller = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )

            let staged = try await controller.stage(
                commonRecord: common,
                payload: payload,
                catalog: try LogDriverCatalog(
                    descriptors: BuiltinLogDriverDescriptors.current.descriptors
                        + [descriptor]
                )
            )
            #expect(staged.commonRecord.state == .imported)
            #expect(staged.privateState.containers.first?.histories.first?.kind == .providerOwned)
            #expect(staged.privateState.containers.first?.histories.first?.disposition == .empty)
        }
    }

    @Test
    func `provider history requires and preflights the exact export receipt`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor(
                nativeRead: true,
                supportsDualCache: false
            )
            let common = try contentVerifiedRecord(store: stores.common)
            let destinationRoot =
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
            let export = try LogDriverHistoryHandoffExportReceiptV1(
                request: LogDriverHistoryHandoffExportRequestV1(
                    tokenID: common.tokenID,
                    manifestID: common.manifestID,
                    containerID: "container-1",
                    sourceStateRootUUID:
                        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                    destinationStateRootUUID: destinationRoot,
                    sourceLeaseGeneration: 41,
                    sourceProviderID: descriptor.providerIdentity.id,
                    sourceProviderGeneration: 9,
                    sourceContractDigest: descriptor.optionContractDigest,
                    terminalHistoryDigestSHA256: digest("terminal-history")
                ),
                providerOutcomeDigestSHA256: digest("provider-export")
            )
            let history = try LoggingHandoffHistoryStoreV1(
                storeID: "provider:0",
                kind: .providerOwned,
                disposition: .providerExportVerified,
                formatVersion: 1,
                rotationIndex: 0,
                terminalHistoryEpoch: 12,
                maximumInternalSequence: 99,
                sourceDeviceID: nil,
                sourceInode: nil,
                bytes: nil,
                providerExportReceipt: export
            )
            let preflight = RecordingLoggingProviderHistoryPreflight()
            let controller = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts,
                providerHistoryPreflight: preflight,
                destinationStateRootUUID: destinationRoot
            )
            let staged = try await controller.stage(
                commonRecord: common,
                payload: try decodedPayload(
                    descriptor: descriptor,
                    readPolicy: LogReadPolicy(source: .direct),
                    historyStores: ["provider-history": history]
                ),
                catalog: LogDriverCatalog(
                    descriptors:
                        BuiltinLogDriverDescriptors.current.descriptors
                        + [descriptor]
                )
            )
            #expect(staged.commonRecord.state == .imported)
            #expect(await preflight.callCount == 1)
        }
    }

    @Test
    func `destination promotion is durable exact replay and activates once`() async throws {
        try await withStores { stores in
            let descriptor = try remoteDescriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors
                    + [descriptor]
            )
            let common = try contentVerifiedRecord(store: stores.common)
            let payload = try decodedPayload(descriptor: descriptor)
            let staging = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )
            let imported = try await staging.stage(
                commonRecord: common,
                payload: payload,
                catalog: catalog
            )
            let promoter = TestLoggingHandoffContainerPromoter()
            let promotionRoot = stores.root.appendingPathComponent("promotions")
            let destination = try LoggingHandoffDestinationReconciler(
                rootURL: promotionRoot,
                containerPromoter: promoter
            )
            let authorization = LoggingHandoffPromotionAuthorizationV1(
                tokenID: imported.privateState.handoffTokenID,
                manifestID: imported.privateState.handoffManifestID,
                manifestDigest: imported.privateState.handoffManifestDigest,
                commitDigestSHA256: digest("commit"),
                handoffChainHeadDigestSHA256: digest("chain"),
                destinationProviderFingerprint: "sha256:destination-provider",
                destinationStateRootUUID:
                    "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
            )

            let first = try await destination.promoteLogging(
                privateState: imported.privateState,
                payload: payload,
                authorization: authorization,
                protectedReceipt: imported.receipt
            )
            let replay = try await destination.promoteLogging(
                privateState: imported.privateState,
                payload: payload,
                authorization: authorization,
                protectedReceipt: imported.receipt
            )
            #expect(first == replay)
            #expect(first.controllerRevision == 1)
            let firstControllerRevision =
                try await destination
                .controllerRevision()
            #expect(firstControllerRevision.revision == 1)
            #expect(try historyObjectCount(promotionRoot) == 1)
            #expect(await promoter.promotedEffectCount() == 1)

            let secondCommon = try contentVerifiedRecord(
                store: stores.common,
                tokenID: "token-2",
                manifestID: "manifest-2",
                bundleLabel: "bundle-2"
            )
            let secondImported = try await staging.stage(
                commonRecord: secondCommon,
                payload: payload,
                catalog: catalog
            )
            let secondAuthorization = LoggingHandoffPromotionAuthorizationV1(
                tokenID: secondImported.privateState.handoffTokenID,
                manifestID: secondImported.privateState.handoffManifestID,
                manifestDigest:
                    secondImported.privateState.handoffManifestDigest,
                commitDigestSHA256: digest("commit-2"),
                handoffChainHeadDigestSHA256: digest("chain-2"),
                destinationProviderFingerprint:
                    authorization.destinationProviderFingerprint,
                destinationStateRootUUID:
                    authorization.destinationStateRootUUID
            )
            let second = try await destination.promoteLogging(
                privateState: secondImported.privateState,
                payload: payload,
                authorization: secondAuthorization,
                protectedReceipt: secondImported.receipt
            )
            #expect(second.controllerRevision == 2)
            #expect(
                second.controllerStateDigestSHA256
                    != (try second.expectedControllerStateDigest(
                        previousControllerStateDigestSHA256:
                            LoggingHandoffControllerPromotionReceiptV1
                            .emptyControllerStateDigest()
                    ))
            )
            let aggregateControllerRevision =
                try await destination
                .controllerRevision()
            #expect(aggregateControllerRevision.revision == 2)
            #expect(
                aggregateControllerRevision.canonicalStateDigestSHA256
                    == second.controllerStateDigestSHA256
            )

            let recovered = try LoggingHandoffDestinationReconciler(
                rootURL: promotionRoot,
                containerPromoter: promoter
            )
            #expect(
                try await recovered.promoteLogging(
                    privateState: imported.privateState,
                    payload: payload,
                    authorization: authorization,
                    protectedReceipt: imported.receipt
                ) == first
            )
            let recoveredControllerRevision =
                try await recovered
                .controllerRevision()
            #expect(recoveredControllerRevision.revision == 2)
            #expect(
                recoveredControllerRevision.canonicalStateDigestSHA256
                    == second.controllerStateDigestSHA256
            )

            let activation = LoggingHandoffActivationAuthorizationV1(
                tokenID: authorization.tokenID,
                manifestID: authorization.manifestID,
                manifestDigest: authorization.manifestDigest,
                commitDigestSHA256: authorization.commitDigestSHA256,
                handoffChainHeadDigestSHA256:
                    authorization.handoffChainHeadDigestSHA256,
                terminalOutcomeDigestSHA256: digest("complete"),
                destinationProviderFingerprint:
                    authorization.destinationProviderFingerprint,
                destinationStateRootUUID:
                    authorization.destinationStateRootUUID
            )
            try await recovered.activateLogging(
                privateState: imported.privateState,
                payload: payload,
                promotionReceipt: first,
                authorization: activation
            )
            try await recovered.activateLogging(
                privateState: imported.privateState,
                payload: payload,
                promotionReceipt: first,
                authorization: activation
            )
            #expect(await promoter.activatedEffectCount() == 1)
        }
    }

    @Test
    func `signed gateway phases gate promotion and activation`() async throws {
        try await withStores { stores in
            let gateway = try SignedLoggingGatewayFixture()
            let descriptor = try remoteDescriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors
                    + [descriptor]
            )
            let common = try contentVerifiedRecord(
                store: stores.common,
                manifestDigest: gateway.manifest.manifestDigest,
                payloadDescriptorDigestSHA256:
                    gateway.loggingPayloadDescriptorDigestSHA256
            )
            let payload = try decodedPayload(descriptor: descriptor)
            let staging = LoggingHandoffStagingController(
                defaults: LoggingConfig(),
                commonStore: stores.common,
                protectedOptionsStore: stores.protected,
                receiptStore: stores.receipts
            )
            let imported = try await staging.stage(
                commonRecord: common,
                payload: payload,
                catalog: catalog
            )
            let signed = try gateway.reconciliation(
                importedRecord: imported.commonRecord
            )
            let promoter = TestLoggingHandoffContainerPromoter()
            let destination = try LoggingHandoffDestinationReconciler(
                rootURL: stores.root.appendingPathComponent("signed-promotion"),
                containerPromoter: promoter
            )

            var committed = signed.gatewayState
            committed.transactions[0].token.phase = .committed
            try ProviderHandoffGatewayStateMachine.validate(committed)
            await #expect(
                throws: LoggingHandoffPromotionError.promotionNotAuthorized
            ) {
                _ = try await staging.reconcile(
                    commonRecord: imported.commonRecord,
                    payload: payload,
                    validatedCommit: signed.validatedCommit,
                    gatewayState: committed,
                    destination: destination
                )
            }
            #expect(await promoter.promotedEffectCount() == 0)

            let promotion = try await staging.reconcile(
                commonRecord: imported.commonRecord,
                payload: payload,
                validatedCommit: signed.validatedCommit,
                gatewayState: signed.gatewayState,
                destination: destination
            )
            await #expect(
                throws: LoggingHandoffPromotionError.promotionNotAuthorized
            ) {
                try await staging.activate(
                    commonRecord: imported.commonRecord,
                    payload: payload,
                    promotionReceipt: promotion,
                    validatedCommit: signed.validatedCommit,
                    validatedOutcome: try gateway.validatedCompleteOutcome(
                        reconciliation: signed,
                        promotionReceipt: promotion
                    ),
                    gatewayState: signed.gatewayState,
                    destination: destination
                )
            }
            #expect(await promoter.activatedEffectCount() == 0)

            let validatedOutcome = try gateway.validatedCompleteOutcome(
                reconciliation: signed,
                promotionReceipt: promotion
            )
            var complete = signed.gatewayState
            let tokenRevision = try #require(
                complete.transactions.first?.token.tokenRevision
            )
            try ProviderHandoffGatewayStateMachine.complete(
                validatedOutcome,
                tokenID: imported.commonRecord.tokenID,
                expectedTokenRevision: tokenRevision,
                in: &complete,
                expectedStoreRevision: complete.storeRevision
            )
            try ProviderHandoffGatewayStateMachine.validate(complete)
            try await staging.activate(
                commonRecord: imported.commonRecord,
                payload: payload,
                promotionReceipt: promotion,
                validatedCommit: signed.validatedCommit,
                validatedOutcome: validatedOutcome,
                gatewayState: complete,
                destination: destination
            )
            #expect(await promoter.promotedEffectCount() == 1)
            #expect(await promoter.activatedEffectCount() == 1)
        }
    }

    private struct Stores: Sendable {
        let root: URL
        let commonRoot: URL
        let protectedRoot: URL
        let receiptRoot: URL
        let common: ProviderHandoffPartStagingStore
        let protected: LoggingProtectedOptionsStore
        let receipts: LoggingHandoffProtectedReceiptStore
    }

    private func withStores(
        _ body: (Stores) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logging-handoff-staging-controller-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let commonRoot = root.appendingPathComponent("common")
        let protectedRoot = root.appendingPathComponent("protected")
        let receiptRoot = root.appendingPathComponent("receipts")
        try await body(
            Stores(
                root: root,
                commonRoot: commonRoot,
                protectedRoot: protectedRoot,
                receiptRoot: receiptRoot,
                common: ProviderHandoffPartStagingStore(root: commonRoot),
                protected: try LoggingProtectedOptionsStore(rootURL: protectedRoot),
                receipts: try LoggingHandoffProtectedReceiptStore(rootURL: receiptRoot)
            ))
    }

    private func contentVerifiedRecord(
        store: ProviderHandoffPartStagingStore,
        manifestDigest: String? = nil,
        payloadDescriptorDigestSHA256: String? = nil,
        tokenID: String = "token-1",
        manifestID: String = "manifest-1",
        bundleLabel: String = "bundle"
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        var record = try ProviderHandoffPartStagingStateMachine.declared(
            tokenID: tokenID,
            manifestID: manifestID,
            manifestDigest: manifestDigest ?? digest("manifest"),
            partKind: .logging,
            bundleObjectID: "sha256:\(digest(bundleLabel))",
            payloadDescriptorDigestSHA256:
                payloadDescriptorDigestSHA256 ?? digest("descriptor")
        )
        record = try store.declare(record)
        record = try store.update(
            tokenID: record.tokenID,
            manifestID: record.manifestID,
            partKind: record.partKind,
            expectedStagingRevision: record.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.beginRetrieval(
                &$0,
                expectedRevision: record.stagingRevision
            )
        }
        record = try store.update(
            tokenID: record.tokenID,
            manifestID: record.manifestID,
            partKind: record.partKind,
            expectedStagingRevision: record.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
                [
                    ProviderHandoffByteRangeV1(
                        lowerBound: 0,
                        upperBoundExclusive: 128
                    )
                ],
                transportByteLength: 128,
                in: &$0,
                expectedRevision: record.stagingRevision
            )
        }
        record = try store.update(
            tokenID: record.tokenID,
            manifestID: record.manifestID,
            partKind: record.partKind,
            expectedStagingRevision: record.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
                transportDigestSHA256: digest("transport"),
                transportByteLength: 128,
                in: &$0,
                expectedRevision: record.stagingRevision
            )
        }
        return try store.update(
            tokenID: record.tokenID,
            manifestID: record.manifestID,
            partKind: record.partKind,
            expectedStagingRevision: record.stagingRevision
        ) {
            try ProviderHandoffPartStagingStateMachine.recordContentVerified(
                canonicalContentDigest: digest("content"),
                sourceDigestVerifications: [],
                protection: .authenticatedPlaintext,
                in: &$0,
                expectedRevision: record.stagingRevision
            )
        }
    }

    private func decodedPayload(
        descriptor: LogDriverDescriptor,
        sourceAddsNonBlockingDefault: Bool = false,
        readPolicy: LogReadPolicy? = nil,
        historyStores: [String: LoggingHandoffHistoryStoreV1]? = nil
    ) throws -> LoggingHandoffDecodedPayloadV1 {
        var safeOptions = ["endpoint": "collector.example.test:1234"]
        let delivery: LogDeliveryConfiguration
        if sourceAddsNonBlockingDefault {
            safeOptions["mode"] = "non-blocking"
            delivery = try LogDeliveryConfiguration(requestedMode: .nonBlocking)
        } else {
            delivery = try LogDeliveryConfiguration()
        }
        let readPolicy =
            try readPolicy
            ?? LogReadPolicy(
                source: .dualCache,
                cache: LogCacheConfiguration(
                    maxSizeInBytes: 20 * 1024 * 1024,
                    maxFileCount: 5,
                    compress: true
                )
            )
        let sourceResolved = try LoggingSourceResolvedConfigurationV1(
            leaseGeneration: 41,
            driver: descriptor.driver,
            safeOptions: safeOptions,
            protectedOptionNames: ["token"],
            delivery: delivery,
            readPolicy: readPolicy,
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: 9,
            contractDigest: descriptor.optionContractDigest,
            providerHistoryMigrationReceipt: nil
        )
        let protectedEntryID = "logging:container-1:token"
        let historyEntryID = "logging:container-1:history-0"
        let terminalAudit = try LoggingTerminalAuditV1(
            terminalWriterCount: 0,
            terminalReaderCount: 0,
            terminalDetachedCleanupCount: 0,
            terminalCategoryDigestSHA256: digest("terminal"),
            historyRetentionDigestSHA256: digest("history-retention")
        )
        let defaultHistory = try LoggingHandoffHistoryStoreV1(
            storeID: "dual-cache:0",
            kind: .dualCache,
            disposition: .importVerified,
            formatVersion: 1,
            rotationIndex: 0,
            terminalHistoryEpoch: 12,
            maximumInternalSequence: 99,
            sourceDeviceID: 17,
            sourceInode: 29,
            bytes: try nativeHistory(sequence: 99)
        )
        let effectiveHistoryStores =
            historyStores
            ?? [historyEntryID: defaultHistory]
        let container = LoggingHandoffContainerRecordV1(
            schemaVersion: 1,
            containerID: "container-1",
            requested: try PersistedContainerLogRequest(
                driver: descriptor.driver,
                safeOptions: ["endpoint": "collector.example.test:1234"],
                protectedOptionNames: ["token"]
            ),
            sourceResolved: sourceResolved,
            protectedEntryIDs: [protectedEntryID],
            historyEntryIDs: effectiveHistoryStores.keys.sorted(),
            terminalAudit: terminalAudit
        )
        let frame = LoggingHandoffProtectedValueFrameV1(
            descriptor: ProtectedLoggingOptionHandoffEntryV1(
                entryID: protectedEntryID,
                containerID: container.containerID,
                sourceStateRootUUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                sourceAuthorityLineageUUID:
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                sourceLineageKeyVersion: 7,
                sourceBlobIdentityDigest: digest("source-blob"),
                sourceProtectedContentDigest: digest("source-content"),
                boundedValueByteLength: UInt64(Data("secret-value".utf8).count)
            ),
            optionName: "token",
            value: Data("secret-value".utf8)
        )
        return LoggingHandoffDecodedPayloadV1(
            containers: [container],
            protectedValues: [frame],
            historyStores: effectiveHistoryStores
        )
    }

    private func remoteDescriptor(
        nativeRead: Bool = false,
        supportsDualCache: Bool = true
    ) throws -> LogDriverDescriptor {
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
                nativeRead: nativeRead,
                readFilters: [],
                supportsDualCache: supportsDualCache,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: true,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    private func protectedObjectCount(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path).count {
            $0.hasPrefix(LoggingProtectedOptionsStore.objectFilePrefix)
                && $0.hasSuffix(LoggingProtectedOptionsStore.objectFileSuffix)
        }
    }

    private func receiptCount(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path).count {
            $0.hasPrefix(LoggingHandoffProtectedReceiptStore.receiptFilePrefix)
                && $0.hasSuffix(LoggingHandoffProtectedReceiptStore.receiptFileSuffix)
        }
    }

    private func historyObjectCount(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path).count {
            $0.hasPrefix(
                LoggingHandoffDestinationReconciler.historyObjectPrefix
            )
                && $0.hasSuffix(
                    LoggingHandoffDestinationReconciler.historyObjectSuffix
                )
        }
    }

    private func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private func nativeHistory(sequence: UInt64) throws -> Data {
        let record = try ContainerLogRecordV2(
            stream: .stdout,
            observation: ContainerLogObservation(
                wallClock: try ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1_700_000_000,
                    nanoseconds: 123
                ),
                monotonicInstant: ContinuousClock().now
            ),
            payload: Data("preserved-cache-history".utf8),
            partial: nil,
            sequence: sequence,
            processGeneration: 1
        )
        var bytes = NativeLocalLogCodec.fileHeader
        bytes.append(try NativeLocalLogCodec.encode(record))
        return bytes
    }
}

private actor RecordingLoggingProviderHistoryPreflight:
    LoggingHandoffProviderHistoryPreflighting
{
    private(set) var callCount = 0

    func preflightProviderHistory(
        containerID _: String,
        history _: LoggingHandoffHistoryStoreV1,
        destination _: PreparedContainerLogResolution,
        handoffManifestDigestSHA256 _: String,
        destinationStateRootUUID _: String
    ) {
        callCount += 1
    }
}

private struct SignedLoggingReconciliation {
    let gatewayState: ProviderHandoffGatewayStateV1
    let validatedCommit: ProviderHandoffValidatedCommitRecordV1
}

private struct SignedLoggingGatewayFixture {
    private static let tokenID = "token-1"
    private static let manifestID = "manifest-1"
    private static let sourceRoot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let destinationRoot = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private static let sourceLineage = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private static let resultingLineage = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private static let destinationLineage = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private static let sourceProvider = "sha256:source-provider"
    private static let destinationProvider = "sha256:destination-provider"

    let manifest: ProviderHandoffManifestV1
    let loggingPayloadDescriptorDigestSHA256: String

    private let trust: SignedLoggingGatewayTrust
    private let expectations: [ProviderHandoffHeaderExpectationV1]
    private let providerSelection: ProviderHandoffProviderSelectionExpectationV1
    private let socketSelection: ProviderHandoffSocketSelectionExpectationV1

    init() throws {
        trust = try SignedLoggingGatewayTrust()
        let source = try Self.expectation(
            role: .source,
            root: Self.sourceRoot,
            lineage: Self.sourceLineage,
            stagedLineage: nil,
            provider: Self.sourceProvider,
            state: .sourceQuiesced,
            abortState: .destinationActive,
            snapshot: "source-checkpoint"
        )
        let destination = try Self.expectation(
            role: .destination,
            root: Self.destinationRoot,
            lineage: Self.destinationLineage,
            stagedLineage: Self.resultingLineage,
            provider: nil,
            state: .destinationStaged,
            abortState: .none,
            snapshot: nil
        )
        expectations = [source, destination]

        let parts = try ProviderHandoffPartKindV1.allCases.map { kind in
            let prepared = try ProviderHandoffPayloadCodec.prepareAuthenticated(
                ProviderHandoffPayloadPackageV1(
                    partKind: kind,
                    entries: [
                        ProviderHandoffPayloadPackageEntryV1(
                            entryID: "evidence-\(kind.rawValue)",
                            sourceStateRootUUID: Self.sourceRoot,
                            recordKind: "handoff-evidence",
                            schemaVersion: 1,
                            canonicalRecordBytes:
                                try ProviderHandoffCanonicalCBOR
                                .encode(
                                    .map([
                                        .init("disposition", .textString("included"))
                                    ]))
                        )
                    ]
                ),
                mediaType:
                    "application/vnd.io.github.stephenlclarke.container.handoff-part.v1+cbor",
                sourceOrder: [Self.sourceRoot]
            )
            return ProviderHandoffPartV1(
                kind: kind,
                schemaVersion: 1,
                disposition: .included,
                sourceStateRootUUIDs: [Self.sourceRoot],
                requiredCapabilities: [],
                payload: prepared.descriptor
            )
        }
        let loggingPart = try #require(
            parts.first(where: {
                $0.kind == .logging
            }))
        loggingPayloadDescriptorDigestSHA256 =
            try ProviderHandoffProjections
            .payloadDescriptorDigest(loggingPart.payload)

        var envelope = DestinationSealedLineageKeyEnvelopeV1(
            envelopeID: "resulting-lineage-key",
            sourceStateRootUUID: nil,
            authorityLineageUUID: Self.resultingLineage,
            keyVersion: 2,
            destinationKeyPurpose: .destinationLineageKeyEncryption,
            destinationKeyID: "destination-lineage-key",
            encryptionAlgorithm:
                .x25519HKDFSHA256XChaCha20Poly1305V1,
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 24),
            canonicalPlaintextByteLength: 32,
            associatedDataDigestSHA256: Self.digest("envelope-associated"),
            ciphertext: Data(repeating: 0x33, count: 48),
            envelopeSignature: Self.placeholderSignature(
                purpose: .lineageKeyEnvelopeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        envelope.envelopeSignature = Self.placeholderSignature(
            purpose: .lineageKeyEnvelopeSigning,
            role: .gatewayCoordinator,
            provider: nil,
            root: nil,
            signedDigest:
                try ProviderHandoffProjections
                .lineageKeyEnvelopeDigest(envelope)
        )
        var value = ProviderHandoffManifestV1(
            manifestID: Self.manifestID,
            tokenID: Self.tokenID,
            trustRegistryRevision: trust.registryRevision,
            destinationKeyPossessionProofDigestsSHA256: [],
            sources: [
                ProviderHandoffSourceV1(
                    providerFingerprint: Self.sourceProvider,
                    stateRootUUID: Self.sourceRoot,
                    authorityLineageUUID: Self.sourceLineage,
                    lineageDigestKeyVersion: 4,
                    preCommitExpectation: source,
                    sourceSignature: Self.placeholderSignature(
                        purpose: .sourceManifestSigning,
                        role: .sourceProvider,
                        provider: Self.sourceProvider,
                        root: Self.sourceRoot
                    )
                )
            ],
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            destinationSealedLineageKeyEnvelopes: [envelope],
            destinationProviderFingerprint: Self.destinationProvider,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: destination,
            parts: parts,
            manifestDigest: Self.digest("pending-manifest"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorManifestSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        value.sources[0].sourceSignature = Self.placeholderSignature(
            purpose: .sourceManifestSigning,
            role: .sourceProvider,
            provider: Self.sourceProvider,
            root: Self.sourceRoot,
            signedDigest: try ProviderHandoffProjections.sourceManifestDigest(
                source: value.sources[0],
                manifest: value
            )
        )
        value.manifestDigest = try ProviderHandoffProjections.manifestDigest(
            value
        )
        value.coordinatorSignature = Self.placeholderSignature(
            purpose: .coordinatorManifestSigning,
            role: .gatewayCoordinator,
            provider: nil,
            root: nil,
            signedDigest: value.manifestDigest
        )
        manifest = value

        let expectedProvider = ProviderHandoffProviderSelectionRecordV1(
            selectionRevision: 1,
            selectedProviderFingerprint: Self.sourceProvider,
            selectedStateRootUUID: Self.sourceRoot,
            providerRegistrationDigestSHA256: Self.digest("source-registration"),
            trustRegistryRevision: trust.registryRevision
        )
        let resultingProvider = ProviderHandoffProviderSelectionRecordV1(
            selectionRevision: 2,
            selectedProviderFingerprint: Self.destinationProvider,
            selectedStateRootUUID: Self.destinationRoot,
            providerRegistrationDigestSHA256:
                Self.digest("destination-registration"),
            trustRegistryRevision: trust.registryRevision
        )
        providerSelection = ProviderHandoffProviderSelectionExpectationV1(
            expectedRecord: expectedProvider,
            expectedRecordDigestSHA256:
                try ProviderHandoffProjections
                .providerSelectionDigest(expectedProvider),
            resultingRecord: resultingProvider,
            resultingRecordDigestSHA256:
                try ProviderHandoffProjections
                .providerSelectionDigest(resultingProvider)
        )
        let expectedSocket = ProviderHandoffSocketDiscoveryRecordV1(
            discoveryRevision: 1,
            socketInstanceUUID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            ownerUID: 501,
            minimumEngineAPIVersion: "1.44",
            maximumEngineAPIVersion: "1.53",
            selectedProviderFingerprint: Self.sourceProvider,
            selectedStateRootUUID: Self.sourceRoot
        )
        let resultingSocket = ProviderHandoffSocketDiscoveryRecordV1(
            discoveryRevision: 2,
            socketInstanceUUID: expectedSocket.socketInstanceUUID,
            ownerUID: expectedSocket.ownerUID,
            minimumEngineAPIVersion: expectedSocket.minimumEngineAPIVersion,
            maximumEngineAPIVersion: expectedSocket.maximumEngineAPIVersion,
            selectedProviderFingerprint: Self.destinationProvider,
            selectedStateRootUUID: Self.destinationRoot
        )
        socketSelection = ProviderHandoffSocketSelectionExpectationV1(
            expectedRecord: expectedSocket,
            expectedRecordDigestSHA256:
                try ProviderHandoffProjections
                .socketDiscoveryDigest(expectedSocket),
            resultingRecord: resultingSocket,
            resultingRecordDigestSHA256:
                try ProviderHandoffProjections
                .socketDiscoveryDigest(resultingSocket)
        )
    }

    func reconciliation(
        importedRecord: ProviderHandoffPartStagingRecordV1
    ) throws -> SignedLoggingReconciliation {
        let imported = try manifest.parts.map { part in
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
        let intent = ProviderHandoffCommitIntentV1(
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            manifestDigest: manifest.manifestDigest,
            trustRegistryRevision: trust.registryRevision,
            authoritativeCommitRevision: 1,
            preCommitRootExpectations: expectations,
            importedParts: imported,
            destinationKeyPossessionProofDigestsSHA256: [],
            providerSelection: providerSelection,
            socketSelection: socketSelection,
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
        try ProviderHandoffRecordSigner.signCommitRecord(
            &record,
            signerKeyID: trust.commitKeyID,
            privateKey: trust.commitPrivateKey
        )
        let validated = try ProviderHandoffRecordValidator.validateCommitRecord(
            record,
            trustRegistry: trust.validatedRegistry,
            atUnixSeconds: trust.useTime
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 8,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint: Self.destinationProvider,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: trust.registryRevision,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .reconciling,
            preCommitRootExpectations: expectations,
            destinationKeyPossessionProofDigestsSHA256: [],
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
            providerSelection: providerSelection.resultingRecord,
            socketDiscovery: socketSelection.resultingRecord,
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
        return SignedLoggingReconciliation(
            gatewayState: state,
            validatedCommit: validated
        )
    }

    func validatedCompleteOutcome(
        reconciliation: SignedLoggingReconciliation,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1
    ) throws -> ProviderHandoffValidatedTerminalOutcomeV1 {
        let record = reconciliation.validatedCommit.record
        var roots: [ProviderHandoffTerminalRootV1] = []
        for (index, post) in record.postCommitRoots.enumerated() {
            var header = post.postCommitHeader
            var vector = post.postCommitRevisionVector
            header.activeHandoffTokenID = nil
            if index == record.postCommitRoots.count - 1 {
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
                    try ProviderHandoffProjections
                    .revisionVectorDigest(vector)
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
            outcomeDigestSHA256: Self.digest("pending-outcome"),
            coordinatorSignature: Self.placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        try ProviderHandoffRecordSigner.signTerminalOutcome(
            &outcome,
            trustRegistryRevision: trust.registryRevision,
            signerKeyID: trust.outcomeKeyID,
            privateKey: trust.outcomePrivateKey
        )
        return try ProviderHandoffRecordValidator.validateTerminalOutcome(
            outcome,
            trustRegistry: trust.validatedRegistry,
            atUnixSeconds: trust.useTime
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
            activeHandoffTokenID: Self.tokenID,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: role == .source ? 4 : 1
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
            lineageDigestKeyVersion: role == .source ? 4 : 1
        )
        var vector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 10,
            snapshotCheckpointID: snapshot,
            controllerRevisions: role == .source
                ? [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: 7,
                        canonicalStateDigestSHA256: digest("source-logging")
                    )
                ] : [],
            revisionVectorDigestSHA256: digest("pending-vector")
        )
        vector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
            .revisionVectorDigest(vector)
        var abortVector = vector
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
            preCommitRevisionVector: vector,
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
        root: String?,
        signedDigest: String = digest("pending-signature")
    ) -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: purpose,
            signerKeyID: "projection-bound-placeholder",
            signerRole: role,
            providerFingerprint: provider,
            stateRootUUID: root,
            trustRegistryRevision: 1,
            signedProjectionDigestSHA256: signedDigest,
            signature: Data(repeating: 0, count: 64)
        )
    }

    private static func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }
}

private struct SignedLoggingGatewayTrust {
    let useTime: UInt64 = 1_800_000_000
    let registryRevision: UInt64 = 1
    let commitPrivateKey: Data
    let commitKeyID: String
    let outcomePrivateKey: Data
    let outcomeKeyID: String
    let validatedRegistry: ProviderHandoffValidatedTrustRegistryV1

    init() throws {
        let bootstrapPrivate = ProviderHandoffCrypto.generateEd25519PrivateKey()
        let bootstrapPublic = try ProviderHandoffCrypto.ed25519PublicKey(
            for: bootstrapPrivate
        )
        let bootstrapID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .trustRegistrySigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: bootstrapPublic
        )
        let bootstrap = ProviderHandoffPinnedBootstrapKeyV1(
            keyID: bootstrapID,
            rawPublicKey: bootstrapPublic,
            codeRequirementDigestSHA256: Self.digest("bootstrap-code")
        )
        let bootstrapKey = ProviderHandoffTrustKeyV1(
            keyID: bootstrapID,
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .trustRegistrySigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: bootstrapPublic,
            provenance: Self.provenance(
                suffix: "bootstrap",
                codeRequirementDigest: bootstrap.codeRequirementDigestSHA256
            ),
            notBeforeUnixSeconds: useTime - 100,
            notAfterUnixSeconds: useTime + 100,
            rotationPredecessorKeyID: nil,
            revokedAtUnixSeconds: nil,
            revocationReason: nil
        )

        commitPrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        var commit = try Self.coordinatorKey(
            privateKey: commitPrivateKey,
            purpose: .coordinatorCommitSigning,
            suffix: "commit",
            useTime: useTime
        )
        commit.provenance.enrollmentProofSignature =
            try ProviderHandoffTrustRegistryValidator
            .enrollmentProofSignature(
                for: commit,
                privateKey: commitPrivateKey
            )
        commitKeyID = commit.keyID

        outcomePrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        var outcome = try Self.coordinatorKey(
            privateKey: outcomePrivateKey,
            purpose: .coordinatorTerminalOutcomeSigning,
            suffix: "outcome",
            useTime: useTime
        )
        outcome.provenance.enrollmentProofSignature =
            try ProviderHandoffTrustRegistryValidator
            .enrollmentProofSignature(
                for: outcome,
                privateKey: outcomePrivateKey
            )
        outcomeKeyID = outcome.keyID

        let keys = [bootstrapKey, commit, outcome].sorted {
            $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
        }
        var registry = ProviderHandoffTrustRegistryV1(
            registryRevision: registryRevision,
            issuedAtUnixSeconds: useTime,
            keys: keys,
            registryDigestSHA256: Self.digest("pending-registry"),
            registrySignature: ProviderHandoffSignatureV1(
                purpose: .trustRegistrySigning,
                signerKeyID: bootstrapID,
                signerRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                trustRegistryRevision: registryRevision,
                signedProjectionDigestSHA256:
                    Self.digest("pending-registry-signature"),
                signature: Data(repeating: 0, count: 64)
            )
        )
        registry.registryDigestSHA256 =
            try ProviderHandoffProjections
            .trustRegistryDigest(registry)
        registry.registrySignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: registry.registryDigestSHA256,
            purpose: .trustRegistrySigning,
            signerKeyID: bootstrapID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: registryRevision,
            privateKey: bootstrapPrivate
        )
        validatedRegistry = try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap
        )
    }

    private static func coordinatorKey(
        privateKey: Data,
        purpose: ProviderHandoffKeyPurposeV1,
        suffix: String,
        useTime: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        let publicKey = try ProviderHandoffCrypto.ed25519PublicKey(
            for: privateKey
        )
        let identifier = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: purpose,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: publicKey
        )
        return ProviderHandoffTrustKeyV1(
            keyID: identifier,
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: purpose,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: publicKey,
            provenance: provenance(suffix: suffix),
            notBeforeUnixSeconds: useTime - 100,
            notAfterUnixSeconds: useTime + 100,
            rotationPredecessorKeyID: nil,
            revokedAtUnixSeconds: nil,
            revocationReason: nil
        )
    }

    private static func provenance(
        suffix: String,
        codeRequirementDigest: String = digest("coordinator-code")
    ) -> ProviderHandoffPublicKeyProvenanceV1 {
        ProviderHandoffPublicKeyProvenanceV1(
            enrollmentID: "enrollment-\(suffix)",
            owningBundleIdentifier:
                "io.github.stephenlclarke.handoff.\(suffix)",
            codeRequirementDigestSHA256: codeRequirementDigest,
            teamIdentifier: nil,
            providerRegistrationDigestSHA256: digest("registration-\(suffix)"),
            enrolledAtUnixSeconds: 1_799_999_900,
            enrollmentProofSignature: nil
        )
    }

    private static func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }
}

private actor TestLoggingHandoffContainerPromoter:
    LoggingHandoffContainerPromoting
{
    private var promoted = Set<String>()
    private var activated = Set<String>()

    func promoteContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffPromotedHistorySegmentV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) throws {
        #expect(history.map(\.destinationFileName) == ["cache.bin"])
        #expect(history.map(\.maximumInternalSequence) == [99])
        promoted.insert("\(authorization.tokenID):\(container.containerID)")
    }

    func activateContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) throws {
        #expect(
            promotionReceipt.handoffTokenID == authorization.tokenID
        )
        activated.insert("\(authorization.tokenID):\(container.containerID)")
    }

    func promotedEffectCount() -> Int { promoted.count }

    func activatedEffectCount() -> Int { activated.count }
}
