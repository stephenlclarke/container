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
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIService

struct LoggingHandoffPayloadTests {
    private let sourceRoot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sourceLineage = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let destinationRoot = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let lineageKey = Data(repeating: 0x41, count: 32)
    private let sourceObjectID = "source-protected-object-must-not-leak"
    private let sourceIntegrityDigest = "source-protected-integrity-must-not-leak"

    @Test
    func `sealed payload round trips protected options and history without source reference`() throws {
        let destinationPrivateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
        let prepared = try LoggingHandoffPayloadCodec.prepareSealed(
            containers: [try exportContainer()],
            tokenID: "token-logging-1",
            manifestID: "manifest-logging-1",
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey,
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: "destination-payload-key-1",
            destinationPublicKey: try ProviderHandoffCrypto.x25519PublicKey(
                for: destinationPrivateKey
            ),
            nonce: Data(0x00...0x17)
        )
        let lineage = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: sourceRoot,
            authorityLineageUUID: sourceLineage,
            keyVersion: 7,
            rawHMACSHA256Key: lineageKey
        )
        let package = try ProviderHandoffPayloadCodec.openSealed(
            prepared,
            expectedPartKind: .logging,
            tokenID: "token-logging-1",
            manifestID: "manifest-logging-1",
            sourceOrder: [sourceRoot],
            lineageKeys: [lineage],
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationPrivateKey: destinationPrivateKey
        )
        let decoded = try LoggingHandoffPayloadCodec.decodeVerified(
            package,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey
        )

        let container = try #require(decoded.containers.first)
        #expect(decoded.containers.count == 1)
        #expect(container.containerID == "container-1")
        #expect(container.requested.driver == "custom")
        #expect(container.sourceResolved.driver == "custom")
        #expect(container.sourceResolved.leaseGeneration == 3)
        #expect(container.sourceResolved.providerGenerationAtResolution == 9)
        #expect(container.terminalAudit.terminalWriterCount == 0)
        #expect(container.terminalAudit.terminalReaderCount == 0)
        #expect(container.terminalAudit.terminalDetachedCleanupCount == 0)
        #expect(
            Dictionary(
                uniqueKeysWithValues: decoded.protectedValues.map {
                    ($0.optionName, String(decoding: $0.value, as: UTF8.self))
                }) == ["password": "correct horse", "token": "battery staple"]
        )
        let history = try #require(decoded.historyStores.values.first)
        #expect(decoded.historyStores.count == 1)
        #expect(history.storeID == "json-file:0")
        #expect(history.bytes == Data("preserved docker log\n".utf8))
        #expect(history.terminalHistoryEpoch == 5)
        #expect(history.maximumInternalSequence == 11)

        let canonicalRecords = package.entries.reduce(into: Data()) {
            $0.append($1.canonicalRecordBytes)
        }
        #expect(canonicalRecords.range(of: Data(sourceObjectID.utf8)) == nil)
        #expect(canonicalRecords.range(of: Data(sourceIntegrityDigest.utf8)) == nil)

        #expect(throws: LoggingHandoffPayloadError.protectedDigestMismatch(container.protectedEntryIDs[0])) {
            _ = try LoggingHandoffPayloadCodec.decodeVerified(
                package,
                sourceStateRootUUID: sourceRoot,
                sourceAuthorityLineageUUID: sourceLineage,
                sourceLineageKeyVersion: 7,
                sourceLineageHMACSHA256Key: Data(repeating: 0x42, count: 32)
            )
        }
    }

    @Test
    func `framed payload keeps decoded history file backed`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logging-handoff-file-decode-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationPrivateKey =
            ProviderHandoffCrypto.generateX25519PrivateKey()
        let tokenID = "token-logging-file-1"
        let manifestID = "manifest-logging-file-1"
        let originalContainer = try exportContainer()
        let originalHistory = try #require(originalContainer.historyStores.first)
        let historyBytes = try #require(originalHistory.bytes)
        let sourceHistoryURL = root.appendingPathComponent("source-history")
        try historyBytes.write(to: sourceHistoryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sourceHistoryURL.path
        )
        let fileHistory = try LoggingHandoffHistoryStoreV1(
            fileBackedStoreID: originalHistory.storeID,
            kind: originalHistory.kind,
            disposition: originalHistory.disposition,
            formatVersion: originalHistory.formatVersion,
            rotationIndex: originalHistory.rotationIndex,
            compressed: originalHistory.compressed,
            terminalHistoryEpoch: originalHistory.terminalHistoryEpoch,
            maximumInternalSequence:
                originalHistory.maximumInternalSequence,
            sourceDeviceID: originalHistory.sourceDeviceID,
            sourceInode: originalHistory.sourceInode,
            byteLength: originalHistory.byteLength,
            contentDigestSHA256: try #require(
                originalHistory.contentDigestSHA256
            )
        )
        let fileContainer = try LoggingHandoffExportContainerV1(
            containerID: originalContainer.containerID,
            configuration: originalContainer.configuration,
            protectedOptions: [
                "password": "correct horse",
                "token": "battery staple",
            ],
            historyStores: [fileHistory],
            lifecycleSnapshot: emptyLifecycleSnapshot()
        )
        let recordDirectory = root.appendingPathComponent(
            "records",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recordDirectory,
            withIntermediateDirectories: false
        )
        let entryID = LoggingHandoffPayloadCodec.historyEntryID(
            containerID: fileContainer.containerID,
            storeID: fileHistory.storeID
        )
        let prepared = try LoggingHandoffPayloadCodec.prepareSealedFile(
            payload: LoggingHandoffExportPayloadV2(
                containers: [fileContainer],
                historyFiles: [
                    entryID: LoggingHandoffHistoryFileV2(
                        url: sourceHistoryURL,
                        byteLength: fileHistory.byteLength,
                        contentDigestSHA256: try #require(
                            fileHistory.contentDigestSHA256
                        )
                    )
                ]
            ),
            transportFileURL: root.appendingPathComponent("transport"),
            recordDirectoryURL: recordDirectory,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey,
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: "destination-payload-key-1",
            destinationPublicKey: try ProviderHandoffCrypto.x25519PublicKey(
                for: destinationPrivateKey
            )
        )
        let historyDirectory = root.appendingPathComponent(
            "history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: false
        )
        let lineage = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: sourceRoot,
            authorityLineageUUID: sourceLineage,
            keyVersion: 7,
            rawHMACSHA256Key: lineageKey
        )
        let source = try ProviderHandoffPayloadCodec.openSealedFileSource(
            prepared,
            canonicalFileURL: root.appendingPathComponent("canonical"),
            recordDirectoryURL: recordDirectory,
            expectedPartKind: .logging,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: [sourceRoot],
            lineageKeys: [lineage],
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationPrivateKey: destinationPrivateKey
        )
        let decoded = try LoggingHandoffPayloadCodec.decodeVerified(
            source,
            lineageKeys: [lineage],
            historyDirectoryURL: historyDirectory,
            privateFileOwner: LoggingHandoffPrivateFileOwner(rootURL: root)
        )
        let container = try #require(decoded.containers.first)
        let decodedEntryID = try #require(container.historyEntryIDs.first)
        let history = try #require(decoded.historyStores[decodedEntryID])
        let file = try #require(decoded.historyFiles[decodedEntryID])
        #expect(history.bytes == nil)
        #expect(file.byteLength == history.byteLength)
        #expect(file.contentDigestSHA256 == history.contentDigestSHA256)
        #expect(
            try decoded.withHistoryBytes(entryID: decodedEntryID) { bytes in
                bytes == Data("preserved docker log\n".utf8)
            }
        )
    }

    @Test
    func `provider neutral portable history decodes as native logging handoff`() throws {
        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "portable-container",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    records: [
                        ProviderHandoffPortableLogRecordV1(
                            secondsSinceUnixEpoch: 1_786_000_000,
                            nanoseconds: 123_000_000,
                            stream: .stderr,
                            data: Data("portable history\n".utf8)
                        )
                    ]
                )
            ],
            sourceStateRootUUID: sourceRoot
        )

        let decoded = try LoggingHandoffPayloadCodec.decodeVerified(
            package,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey
        )

        let container = try #require(decoded.containers.first)
        let history = try #require(decoded.historyStores.values.first)
        #expect(container.containerID == "portable-container")
        #expect(container.requested.driver == nil)
        #expect(container.sourceResolved.driver == "json-file")
        #expect(container.sourceResolved.delivery.effectiveMode == .blocking)
        #expect(container.sourceResolved.readPolicy.source == .direct)
        #expect(history.kind == .dockerJSONFile)
        #expect(history.disposition == .importVerified)
        #expect(
            history.bytes?.range(of: Data("portable history\\n".utf8))
                != nil
        )
    }

    @Test
    func `portable history above legacy bound decodes as ordered chunks`() throws {
        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "large-portable-container",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    terminalHistoryEpoch: 9,
                    records: [
                        ProviderHandoffPortableLogRecordV1(
                            secondsSinceUnixEpoch: 1_786_000_000,
                            nanoseconds: 0,
                            stream: .stdout,
                            data: Data(
                                repeating: UInt8(ascii: "a"),
                                count:
                                    ProviderHandoffPortableLoggingPayloadCodec
                                    .maximumHistoryBytes + 1
                            )
                        )
                    ]
                )
            ],
            sourceStateRootUUID: sourceRoot
        )

        let decoded = try LoggingHandoffPayloadCodec.decodeVerified(
            package,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey
        )
        let histories = decoded.historyStores.values.sorted {
            $0.storeID.utf8.lexicographicallyPrecedes($1.storeID.utf8)
        }
        #expect(histories.count > 1)
        #expect(
            histories.reduce(0) { $0 + Int($1.byteLength) }
                > ProviderHandoffPortableLoggingPayloadCodec.maximumHistoryBytes
        )
        for (index, history) in histories.enumerated() {
            #expect(
                ProviderHandoffPortableLoggingPayloadCodec
                    .parseHistoryChunkStoreID(history.storeID)
                    == ProviderHandoffPortableLoggingHistoryChunkV1(
                        index: UInt64(index),
                        count: UInt64(histories.count)
                    )
            )
        }
    }

    @Test
    func `legacy logging requires explicit resolution before export`() throws {
        let configuration = ContainerLogConfiguration(
            storage: .local,
            maxSizeInBytes: 4_096,
            maxFileCount: 2
        )
        #expect(throws: LoggingHandoffPayloadError.legacyRequiresResolution("legacy")) {
            _ = try LoggingHandoffExportContainerV1(
                containerID: "legacy",
                configuration: configuration,
                protectedOptions: [:],
                historyStores: [],
                lifecycleSnapshot: try emptyLifecycleSnapshot()
            )
        }
    }

    @Test
    func `provider history export receipt survives the sealed payload exactly`() throws {
        let destinationPrivateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
        let exportRequest = try LogDriverHistoryHandoffExportRequestV1(
            tokenID: "token-provider-history",
            manifestID: "manifest-provider-history",
            containerID: "provider-container",
            sourceStateRootUUID: sourceRoot,
            destinationStateRootUUID: destinationRoot,
            sourceLeaseGeneration: 3,
            sourceProviderID: "example.logging.provider",
            sourceProviderGeneration: 9,
            sourceContractDigest:
                "sha256:" + String(repeating: "a", count: 64),
            terminalHistoryDigestSHA256:
                "sha256:" + String(repeating: "b", count: 64)
        )
        let exportReceipt = try LogDriverHistoryHandoffExportReceiptV1(
            request: exportRequest,
            providerOutcomeDigestSHA256:
                "sha256:" + String(repeating: "c", count: 64)
        )
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 3,
            driver: "custom",
            delivery: LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: LogDriverProviderIdentity(
                id: exportRequest.sourceProviderID,
                version: "1",
                kind: .dockerPlugin
            ),
            providerGenerationAtResolution:
                exportRequest.sourceProviderGeneration,
            contractDigest: exportRequest.sourceContractDigest
        )
        let history = try LoggingHandoffHistoryStoreV1(
            storeID: "provider:0",
            kind: .providerOwned,
            disposition: .providerExportVerified,
            formatVersion: 1,
            rotationIndex: 0,
            terminalHistoryEpoch: 5,
            maximumInternalSequence: 11,
            sourceDeviceID: nil,
            sourceInode: nil,
            bytes: nil,
            providerExportReceipt: exportReceipt
        )
        let container = try LoggingHandoffExportContainerV1(
            containerID: exportRequest.containerID,
            configuration: ContainerLogConfiguration(
                requested: ContainerLogRequest(driver: "custom"),
                resolved: resolved
            ),
            protectedOptions: [:],
            historyStores: [history],
            lifecycleSnapshot: emptyLifecycleSnapshot()
        )
        let prepared = try LoggingHandoffPayloadCodec.prepareSealed(
            containers: [container],
            tokenID: exportRequest.tokenID,
            manifestID: exportRequest.manifestID,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey,
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: "destination-key",
            destinationPublicKey: try ProviderHandoffCrypto.x25519PublicKey(
                for: destinationPrivateKey
            ),
            nonce: Data(0x00...0x17)
        )
        let package = try ProviderHandoffPayloadCodec.openSealed(
            prepared,
            expectedPartKind: .logging,
            tokenID: exportRequest.tokenID,
            manifestID: exportRequest.manifestID,
            sourceOrder: [sourceRoot],
            lineageKeys: [
                ProviderHandoffLineageKeyV1(
                    sourceStateRootUUID: sourceRoot,
                    authorityLineageUUID: sourceLineage,
                    keyVersion: 7,
                    rawHMACSHA256Key: lineageKey
                )
            ],
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            destinationPrivateKey: destinationPrivateKey
        )
        let decoded = try LoggingHandoffPayloadCodec.decodeVerified(
            package,
            sourceStateRootUUID: sourceRoot,
            sourceAuthorityLineageUUID: sourceLineage,
            sourceLineageKeyVersion: 7,
            sourceLineageHMACSHA256Key: lineageKey
        )
        let decodedHistory = try #require(decoded.historyStores.values.first)
        #expect(decodedHistory.providerExportReceipt == exportReceipt)
        #expect(
            decodedHistory.providerExportDigestSHA256
                == exportReceipt.exportReceiptDigestSHA256
        )
    }

    @Test
    func `terminal audit rejects a reserved writer operation`() throws {
        let request = try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "start-1",
            semanticRequestDigest: "sha256:start",
            sessionID: "session-1",
            containerID: "container-1",
            leaseGeneration: 3,
            candidateProcessGeneration: 4,
            providerID: "example.logging.provider",
            providerGeneration: 9,
            candidateSandboxGeneration: nil
        )
        let snapshot = try ContainerLogLifecycleLedgerSnapshotV1(
            owningControllerID: "logging-controller",
            writerOperations: [
                try LoggingWriterOperationRecordV1(
                    request: request,
                    result: .reserved
                )
            ]
        )

        #expect(throws: LoggingHandoffTerminalAuditError.nonTerminalWriter) {
            _ = try LoggingHandoffTerminalAuditBuilder.build(
                containerID: "container-1",
                snapshot: snapshot,
                historyStores: []
            )
        }
    }

    private func exportContainer() throws -> LoggingHandoffExportContainerV1 {
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 3,
            driver: "custom",
            safeOptions: ["tag": "service"],
            protectedOptionNames: ["password", "token"],
            protectedOptionReference: LoggingProtectedOptionsReference(
                objectID: sourceObjectID,
                integrityDigest: sourceIntegrityDigest
            ),
            delivery: LogDeliveryConfiguration(
                requestedMode: .nonBlocking,
                maxBufferSizeInBytes: 2_000_000
            ),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: LogDriverProviderIdentity(
                id: "example.logging.provider",
                version: "2.0.0",
                kind: .native
            ),
            providerGenerationAtResolution: 9,
            contractDigest: "sha256:source-contract"
        )
        let configuration = try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: "custom",
                options: [
                    "password": "correct horse",
                    "tag": "service",
                    "token": "battery staple",
                ]
            ),
            resolved: resolved
        )
        let history = try LoggingHandoffHistoryStoreV1(
            storeID: "json-file:0",
            kind: .dockerJSONFile,
            disposition: .importVerified,
            formatVersion: 1,
            rotationIndex: 0,
            terminalHistoryEpoch: 5,
            maximumInternalSequence: 11,
            sourceDeviceID: 17,
            sourceInode: 29,
            bytes: Data("preserved docker log\n".utf8)
        )
        return try LoggingHandoffExportContainerV1(
            containerID: "container-1",
            configuration: configuration,
            protectedOptions: [
                "password": "correct horse",
                "token": "battery staple",
            ],
            historyStores: [history],
            lifecycleSnapshot: emptyLifecycleSnapshot()
        )
    }

    private func emptyLifecycleSnapshot() throws
        -> ContainerLogLifecycleLedgerSnapshotV1
    {
        try ContainerLogLifecycleLedgerSnapshotV1(
            owningControllerID: "logging-controller"
        )
    }
}
