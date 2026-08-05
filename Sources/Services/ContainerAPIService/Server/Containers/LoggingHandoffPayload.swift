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

import ContainerEngineRuntimeSPI
import ContainerResource
import Foundation

enum LoggingHandoffHistoryDispositionV1: String, Codable, Equatable, Sendable {
    case importVerified
    case providerExportVerified
    case retainOffline
    case empty
    case explicitResolutionRequired
}

enum LoggingHandoffHistoryKindV1: String, Codable, Equatable, Sendable {
    case dockerJSONFile
    case nativeLocal
    case dualCache
    case legacyLocalV1
    case providerOwned
}

struct LoggingHandoffHistoryStoreV1: Codable, Equatable, Sendable {
    static let maximumStoredBytesPerSegment = 128 * 1024 * 1024

    let schemaVersion: UInt32
    let storeID: String
    let kind: LoggingHandoffHistoryKindV1
    let disposition: LoggingHandoffHistoryDispositionV1
    let formatVersion: UInt32
    let rotationIndex: UInt64
    let compressed: Bool
    let terminalHistoryEpoch: UInt64
    let maximumInternalSequence: UInt64
    let sourceDeviceID: UInt64?
    let sourceInode: UInt64?
    let byteLength: UInt64
    let contentDigestSHA256: String?
    let providerExportDigestSHA256: String?
    let providerExportReceipt: LogDriverHistoryHandoffExportReceiptV1?
    let bytes: Data?

    init(
        storeID: String,
        kind: LoggingHandoffHistoryKindV1,
        disposition: LoggingHandoffHistoryDispositionV1,
        formatVersion: UInt32,
        rotationIndex: UInt64,
        compressed: Bool = false,
        terminalHistoryEpoch: UInt64,
        maximumInternalSequence: UInt64,
        sourceDeviceID: UInt64?,
        sourceInode: UInt64?,
        bytes: Data?,
        providerExportReceipt: LogDriverHistoryHandoffExportReceiptV1? = nil
    ) throws {
        guard
            !storeID.isEmpty,
            storeID.precomposedStringWithCanonicalMapping == storeID,
            formatVersion > 0,
            rotationIndex > 0 || !compressed,
            (sourceDeviceID == nil) == (sourceInode == nil)
        else {
            throw LoggingHandoffPayloadError.invalidHistory(storeID)
        }
        let contentDigest = bytes.map(ProviderHandoffDigest.sha256)
        let providerExportDigestSHA256 =
            providerExportReceipt?.exportReceiptDigestSHA256
        guard (bytes?.count ?? 0) <= Self.maximumStoredBytesPerSegment else {
            throw LoggingHandoffPayloadError.boundsExceeded
        }
        switch disposition {
        case .importVerified, .retainOffline:
            guard bytes != nil, providerExportDigestSHA256 == nil else {
                throw LoggingHandoffPayloadError.invalidHistory(storeID)
            }
        case .providerExportVerified:
            guard
                bytes == nil,
                providerExportDigestSHA256 != nil,
                rotationIndex == 0,
                !compressed
            else {
                throw LoggingHandoffPayloadError.invalidHistory(storeID)
            }
        case .empty:
            guard
                bytes == nil,
                providerExportDigestSHA256 == nil,
                rotationIndex == 0,
                maximumInternalSequence == 0,
                !compressed
            else {
                throw LoggingHandoffPayloadError.invalidHistory(storeID)
            }
        case .explicitResolutionRequired:
            guard
                bytes == nil,
                providerExportDigestSHA256 == nil,
                rotationIndex == 0,
                !compressed
            else {
                throw LoggingHandoffPayloadError.invalidHistory(storeID)
            }
        }
        if let providerExportDigestSHA256 {
            _ = try ProviderHandoffDigest.parseSHA256(providerExportDigestSHA256)
        }
        self.schemaVersion = 1
        self.storeID = storeID
        self.kind = kind
        self.disposition = disposition
        self.formatVersion = formatVersion
        self.rotationIndex = rotationIndex
        self.compressed = compressed
        self.terminalHistoryEpoch = terminalHistoryEpoch
        self.maximumInternalSequence = maximumInternalSequence
        self.sourceDeviceID = sourceDeviceID
        self.sourceInode = sourceInode
        self.byteLength = UInt64(bytes?.count ?? 0)
        self.contentDigestSHA256 = contentDigest
        self.providerExportDigestSHA256 = providerExportDigestSHA256
        self.providerExportReceipt = providerExportReceipt
        self.bytes = bytes
    }
}

struct LoggingTerminalAuditV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let terminalWriterCount: UInt64
    let terminalReaderCount: UInt64
    let terminalDetachedCleanupCount: UInt64
    let terminalCategoryDigestSHA256: String
    let historyRetentionDigestSHA256: String

    init(
        terminalWriterCount: UInt64,
        terminalReaderCount: UInt64,
        terminalDetachedCleanupCount: UInt64,
        terminalCategoryDigestSHA256: String,
        historyRetentionDigestSHA256: String
    ) throws {
        _ = try ProviderHandoffDigest.parseSHA256(terminalCategoryDigestSHA256)
        _ = try ProviderHandoffDigest.parseSHA256(historyRetentionDigestSHA256)
        self.schemaVersion = 1
        self.terminalWriterCount = terminalWriterCount
        self.terminalReaderCount = terminalReaderCount
        self.terminalDetachedCleanupCount = terminalDetachedCleanupCount
        self.terminalCategoryDigestSHA256 = terminalCategoryDigestSHA256
        self.historyRetentionDigestSHA256 = historyRetentionDigestSHA256
    }
}

struct LoggingSourceResolvedConfigurationV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let leaseGeneration: UInt64
    let driver: String
    let safeOptions: [String: String]
    let protectedOptionNames: [String]
    let delivery: LogDeliveryConfiguration
    let readPolicy: LogReadPolicy
    let providerIdentity: LogDriverProviderIdentity
    let providerGenerationAtResolution: UInt64
    let contractDigest: String
    let providerHistoryMigrationReceipt: LogDriverHistoryMigrationReceiptV1?

    init(_ resolved: ResolvedContainerLogConfiguration) {
        schemaVersion = 1
        leaseGeneration = resolved.leaseGeneration
        driver = resolved.driver
        safeOptions = resolved.safeOptions
        protectedOptionNames = resolved.protectedOptionNames
        delivery = resolved.delivery
        readPolicy = resolved.readPolicy
        providerIdentity = resolved.providerIdentity
        providerGenerationAtResolution = resolved.providerGenerationAtResolution
        contractDigest = resolved.contractDigest
        providerHistoryMigrationReceipt = resolved.providerHistoryMigrationReceipt
    }

    init(
        leaseGeneration: UInt64,
        driver: String,
        safeOptions: [String: String],
        protectedOptionNames: [String],
        delivery: LogDeliveryConfiguration,
        readPolicy: LogReadPolicy,
        providerIdentity: LogDriverProviderIdentity,
        providerGenerationAtResolution: UInt64,
        contractDigest: String,
        providerHistoryMigrationReceipt: LogDriverHistoryMigrationReceiptV1?
    ) throws {
        let protectedNames = Set(protectedOptionNames)
        guard
            leaseGeneration > 0,
            !driver.isEmpty,
            protectedNames.count == protectedOptionNames.count,
            protectedNames.isDisjoint(with: safeOptions.keys),
            !providerIdentity.id.isEmpty,
            !providerIdentity.version.isEmpty,
            providerGenerationAtResolution > 0,
            !contractDigest.isEmpty
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        if let receipt = providerHistoryMigrationReceipt {
            let request = receipt.request
            guard
                readPolicy.source == .direct,
                request.targetLeaseGeneration == leaseGeneration,
                request.providerID == providerIdentity.id,
                request.targetProviderGeneration == providerGenerationAtResolution,
                request.contractDigest == contractDigest
            else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
        }
        self.schemaVersion = 1
        self.leaseGeneration = leaseGeneration
        self.driver = driver
        self.safeOptions = safeOptions
        self.protectedOptionNames = protectedOptionNames.sorted()
        self.delivery = delivery
        self.readPolicy = readPolicy
        self.providerIdentity = providerIdentity
        self.providerGenerationAtResolution = providerGenerationAtResolution
        self.contractDigest = contractDigest
        self.providerHistoryMigrationReceipt = providerHistoryMigrationReceipt
    }
}

struct ProtectedLoggingOptionHandoffEntryV1: Codable, Equatable, Sendable {
    let entryID: String
    let containerID: String
    let sourceStateRootUUID: String
    let sourceAuthorityLineageUUID: String
    let sourceLineageKeyVersion: UInt64
    let sourceBlobIdentityDigest: String
    let sourceProtectedContentDigest: String
    let boundedValueByteLength: UInt64
}

struct LoggingHandoffContainerRecordV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let containerID: String
    let requested: PersistedContainerLogRequest
    let sourceResolved: LoggingSourceResolvedConfigurationV1
    let protectedEntryIDs: [String]
    let historyEntryIDs: [String]
    let terminalAudit: LoggingTerminalAuditV1
}

struct LoggingHandoffProtectedValueFrameV1: Equatable, Sendable {
    let descriptor: ProtectedLoggingOptionHandoffEntryV1
    let optionName: String
    let value: Data
}

struct LoggingHandoffDecodedPayloadV1: Equatable, Sendable {
    let containers: [LoggingHandoffContainerRecordV1]
    let protectedValues: [LoggingHandoffProtectedValueFrameV1]
    let historyStores: [String: LoggingHandoffHistoryStoreV1]
}

struct LoggingHandoffExportContainerV1: Equatable, Sendable {
    let containerID: String
    let configuration: ContainerLogConfiguration
    let protectedOptions: [String: String]
    let historyStores: [LoggingHandoffHistoryStoreV1]
    let terminalAudit: LoggingTerminalAuditV1

    init(
        containerID: String,
        configuration: ContainerLogConfiguration,
        protectedOptions: [String: String],
        historyStores: [LoggingHandoffHistoryStoreV1],
        lifecycleSnapshot: ContainerLogLifecycleLedgerSnapshotV1
    ) throws {
        guard
            !containerID.isEmpty,
            containerID.precomposedStringWithCanonicalMapping == containerID,
            !configuration.isLegacy,
            let resolved = configuration.resolved,
            Set(protectedOptions.keys) == Set(resolved.protectedOptionNames),
            historyStores.map(\.storeID).count == Set(historyStores.map(\.storeID)).count
        else {
            throw configuration.isLegacy
                ? LoggingHandoffPayloadError.legacyRequiresResolution(containerID)
                : LoggingHandoffPayloadError.invalidContainer(containerID)
        }
        self.containerID = containerID
        self.configuration = configuration
        self.protectedOptions = protectedOptions
        self.historyStores = historyStores.sorted {
            $0.storeID.utf8.lexicographicallyPrecedes($1.storeID.utf8)
        }
        self.terminalAudit = try LoggingHandoffTerminalAuditBuilder.build(
            containerID: containerID,
            snapshot: lifecycleSnapshot,
            historyStores: self.historyStores
        )
    }
}

enum LoggingHandoffPayloadError: Error, Equatable, Sendable {
    case boundsExceeded
    case duplicateContainer(String)
    case invalidContainer(String)
    case invalidEntry(String)
    case invalidHistory(String)
    case invalidPackage
    case legacyRequiresResolution(String)
    case protectedDigestMismatch(String)
}

enum LoggingHandoffPayloadCodec {
    static let mediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-logging.v1+cbor"

    static func prepareSealed(
        containers: [LoggingHandoffExportContainerV1],
        tokenID: String,
        manifestID: String,
        sourceStateRootUUID: String,
        sourceAuthorityLineageUUID: String,
        sourceLineageKeyVersion: UInt64,
        sourceLineageHMACSHA256Key: Data,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce: Data? = nil,
        ephemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPreparedPayloadV1 {
        try ProviderHandoffPayloadCodec.prepareSealed(
            package(
                containers: containers,
                tokenID: tokenID,
                manifestID: manifestID,
                sourceStateRootUUID: sourceStateRootUUID,
                sourceAuthorityLineageUUID: sourceAuthorityLineageUUID,
                sourceLineageKeyVersion: sourceLineageKeyVersion,
                sourceLineageHMACSHA256Key: sourceLineageHMACSHA256Key,
                destinationStateRootUUID: destinationStateRootUUID
            ),
            mediaType: mediaType,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: [sourceStateRootUUID],
            lineageKeys: [
                ProviderHandoffLineageKeyV1(
                    sourceStateRootUUID: sourceStateRootUUID,
                    authorityLineageUUID: sourceAuthorityLineageUUID,
                    keyVersion: sourceLineageKeyVersion,
                    rawHMACSHA256Key: sourceLineageHMACSHA256Key
                )
            ],
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
    }

    static func prepareSealedFile(
        containers: [LoggingHandoffExportContainerV1],
        transportFileURL: URL,
        tokenID: String,
        manifestID: String,
        sourceStateRootUUID: String,
        sourceAuthorityLineageUUID: String,
        sourceLineageKeyVersion: UInt64,
        sourceLineageHMACSHA256Key: Data,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce: Data? = nil,
        ephemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPreparedPayloadFileV2 {
        try ProviderHandoffPayloadCodec.prepareSealedFile(
            package(
                containers: containers,
                tokenID: tokenID,
                manifestID: manifestID,
                sourceStateRootUUID: sourceStateRootUUID,
                sourceAuthorityLineageUUID: sourceAuthorityLineageUUID,
                sourceLineageKeyVersion: sourceLineageKeyVersion,
                sourceLineageHMACSHA256Key: sourceLineageHMACSHA256Key,
                destinationStateRootUUID: destinationStateRootUUID
            ),
            transportFileURL: transportFileURL,
            mediaType: mediaType,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: [sourceStateRootUUID],
            lineageKeys: [
                ProviderHandoffLineageKeyV1(
                    sourceStateRootUUID: sourceStateRootUUID,
                    authorityLineageUUID: sourceAuthorityLineageUUID,
                    keyVersion: sourceLineageKeyVersion,
                    rawHMACSHA256Key: sourceLineageHMACSHA256Key
                )
            ],
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
    }

    private static func package(
        containers: [LoggingHandoffExportContainerV1],
        tokenID: String,
        manifestID: String,
        sourceStateRootUUID: String,
        sourceAuthorityLineageUUID: String,
        sourceLineageKeyVersion: UInt64,
        sourceLineageHMACSHA256Key: Data,
        destinationStateRootUUID: String
    ) throws -> ProviderHandoffPayloadPackageV1 {
        guard
            !containers.isEmpty,
            sourceLineageHMACSHA256Key.count == 32,
            sourceLineageKeyVersion > 0
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let ordered = containers.sorted {
            $0.containerID.utf8.lexicographicallyPrecedes($1.containerID.utf8)
        }
        guard Set(ordered.map(\.containerID)).count == ordered.count else {
            throw LoggingHandoffPayloadError.duplicateContainer(
                ordered.first?.containerID ?? "unknown"
            )
        }
        var entries: [ProviderHandoffPayloadPackageEntryV1] = []
        for container in ordered {
            guard
                let requested = container.configuration.requested,
                let resolved = container.configuration.resolved
            else {
                throw LoggingHandoffPayloadError.invalidContainer(container.containerID)
            }
            for history in container.historyStores
            where history.disposition == .providerExportVerified {
                guard
                    let export = history.providerExportReceipt,
                    export.request.tokenID == tokenID,
                    export.request.manifestID == manifestID,
                    export.request.containerID == container.containerID,
                    export.request.sourceStateRootUUID == sourceStateRootUUID,
                    export.request.destinationStateRootUUID
                        == destinationStateRootUUID,
                    export.request.sourceLeaseGeneration
                        == resolved.leaseGeneration,
                    export.request.sourceProviderID
                        == resolved.providerIdentity.id,
                    export.request.sourceProviderGeneration
                        == resolved.providerGenerationAtResolution,
                    export.request.sourceContractDigest
                        == resolved.contractDigest
                else {
                    throw LoggingHandoffPayloadError.invalidHistory(
                        history.storeID
                    )
                }
            }
            let optionNames = container.protectedOptions.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            let sourceReference: LoggingProtectedOptionsReference?
            if optionNames.isEmpty {
                guard resolved.protectedOptionReference == nil else {
                    throw LoggingHandoffPayloadError.invalidContainer(container.containerID)
                }
                sourceReference = nil
            } else {
                guard let reference = resolved.protectedOptionReference else {
                    throw LoggingHandoffPayloadError.invalidContainer(container.containerID)
                }
                sourceReference = reference
            }
            var frames: [LoggingHandoffProtectedValueFrameV1] = []
            for optionName in optionNames {
                guard
                    let value = container.protectedOptions[optionName],
                    let sourceReference
                else {
                    throw LoggingHandoffPayloadError.invalidContainer(container.containerID)
                }
                let valueBytes = Data(value.utf8)
                guard
                    valueBytes.count <= LoggingProtectedOptionsStore.maximumOptionValueBytes
                else {
                    throw LoggingHandoffPayloadError.boundsExceeded
                }
                let entryID = protectedEntryID(
                    containerID: container.containerID,
                    optionName: optionName
                )
                let blobIdentity = try ProviderHandoffDigest.domain(
                    "container-handoff-logging-source-blob-identity-v1",
                    projection: .map([
                        .init("containerID", .textString(container.containerID)),
                        .init("optionName", .textString(optionName)),
                        .init("sourceIntegrityDigest", .textString(sourceReference.integrityDigest)),
                        .init("sourceObjectID", .textString(sourceReference.objectID)),
                    ])
                )
                let descriptor = ProtectedLoggingOptionHandoffEntryV1(
                    entryID: entryID,
                    containerID: container.containerID,
                    sourceStateRootUUID: sourceStateRootUUID,
                    sourceAuthorityLineageUUID: sourceAuthorityLineageUUID,
                    sourceLineageKeyVersion: sourceLineageKeyVersion,
                    sourceBlobIdentityDigest: blobIdentity,
                    sourceProtectedContentDigest: "",
                    boundedValueByteLength: UInt64(valueBytes.count)
                )
                var frame = LoggingHandoffProtectedValueFrameV1(
                    descriptor: descriptor,
                    optionName: optionName,
                    value: valueBytes
                )
                frame = LoggingHandoffProtectedValueFrameV1(
                    descriptor: ProtectedLoggingOptionHandoffEntryV1(
                        entryID: descriptor.entryID,
                        containerID: descriptor.containerID,
                        sourceStateRootUUID: descriptor.sourceStateRootUUID,
                        sourceAuthorityLineageUUID: descriptor.sourceAuthorityLineageUUID,
                        sourceLineageKeyVersion: descriptor.sourceLineageKeyVersion,
                        sourceBlobIdentityDigest: descriptor.sourceBlobIdentityDigest,
                        sourceProtectedContentDigest: try protectedContentDigest(
                            frame,
                            sourceLineageHMACSHA256Key: sourceLineageHMACSHA256Key
                        ),
                        boundedValueByteLength: descriptor.boundedValueByteLength
                    ),
                    optionName: frame.optionName,
                    value: frame.value
                )
                frames.append(frame)
            }
            let record = LoggingHandoffContainerRecordV1(
                schemaVersion: 1,
                containerID: container.containerID,
                requested: requested,
                sourceResolved: LoggingSourceResolvedConfigurationV1(resolved),
                protectedEntryIDs: frames.map(\.descriptor.entryID),
                historyEntryIDs: container.historyStores.map {
                    historyEntryID(containerID: container.containerID, storeID: $0.storeID)
                },
                terminalAudit: container.terminalAudit
            )
            entries.append(
                contentsOf: try containerEntries(
                    record: record,
                    protectedFrames: frames,
                    histories: container.historyStores,
                    sourceStateRootUUID: sourceStateRootUUID
                ))
        }
        entries.sort { $0.entryID.utf8.lexicographicallyPrecedes($1.entryID.utf8) }
        let package = ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: entries
        )
        return package
    }

    static func decodeVerified(
        _ package: ProviderHandoffPayloadPackageV1,
        sourceStateRootUUID: String,
        sourceAuthorityLineageUUID: String,
        sourceLineageKeyVersion: UInt64,
        sourceLineageHMACSHA256Key: Data
    ) throws -> LoggingHandoffDecodedPayloadV1 {
        try decodeVerified(
            package,
            lineageKeys: [
                ProviderHandoffLineageKeyV1(
                    sourceStateRootUUID: sourceStateRootUUID,
                    authorityLineageUUID: sourceAuthorityLineageUUID,
                    keyVersion: sourceLineageKeyVersion,
                    rawHMACSHA256Key: sourceLineageHMACSHA256Key
                )
            ]
        )
    }

    /// Decodes a manifest-ordered payload after the common handoff layer has
    /// authenticated and opened it with the same source lineage keys.
    ///
    /// Each logging record remains bound to exactly one source root. A
    /// multi-source bundle is accepted only when every entry has a matching
    /// lineage key and every container's protected values and history remain
    /// in that same source partition.
    static func decodeVerified(
        _ package: ProviderHandoffPayloadPackageV1,
        lineageKeys: [ProviderHandoffLineageKeyV1]
    ) throws -> LoggingHandoffDecodedPayloadV1 {
        let keysBySource = Dictionary(
            grouping: lineageKeys,
            by: \.sourceStateRootUUID
        )
        guard
            package.partKind == .logging,
            !lineageKeys.isEmpty,
            keysBySource.count == lineageKeys.count,
            lineageKeys.allSatisfy({
                !$0.sourceStateRootUUID.isEmpty
                    && !$0.authorityLineageUUID.isEmpty
                    && $0.keyVersion > 0
                    && $0.rawHMACSHA256Key.count == 32
            })
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let exactKeysBySource = keysBySource.mapValues { $0[0] }
        var containers: [LoggingHandoffContainerRecordV1] = []
        var protectedValues: [LoggingHandoffProtectedValueFrameV1] = []
        var histories: [String: LoggingHandoffHistoryStoreV1] = [:]
        var containerSources: [String: String] = [:]
        var historySources: [String: String] = [:]
        for entry in package.entries {
            guard
                let sourceStateRootUUID = entry.sourceStateRootUUID,
                let lineageKey = exactKeysBySource[sourceStateRootUUID],
                entry.schemaVersion == 1
            else {
                throw LoggingHandoffPayloadError.invalidEntry(entry.entryID)
            }
            switch entry.recordKind {
            case "logging-container-v1":
                let container = try decodeContainer(entry.canonicalRecordBytes)
                guard entry.entryID == containerEntryID(container.containerID) else {
                    throw LoggingHandoffPayloadError.invalidEntry(entry.entryID)
                }
                containers.append(container)
                guard containerSources[container.containerID] == nil else {
                    throw LoggingHandoffPayloadError.duplicateContainer(
                        container.containerID
                    )
                }
                containerSources[container.containerID] = sourceStateRootUUID
            case "logging-protected-option-v1":
                let frame = try decodeProtectedFrame(entry.canonicalRecordBytes)
                guard
                    frame.descriptor.entryID == entry.entryID,
                    entry.entryID
                        == protectedEntryID(
                            containerID: frame.descriptor.containerID,
                            optionName: frame.optionName
                        ),
                    frame.descriptor.sourceStateRootUUID == sourceStateRootUUID,
                    frame.descriptor.sourceAuthorityLineageUUID
                        == lineageKey.authorityLineageUUID,
                    frame.descriptor.sourceLineageKeyVersion
                        == lineageKey.keyVersion
                else {
                    throw LoggingHandoffPayloadError.invalidEntry(entry.entryID)
                }
                try verifyProtectedFrame(
                    frame,
                    sourceLineageHMACSHA256Key:
                        lineageKey.rawHMACSHA256Key
                )
                protectedValues.append(frame)
            case "logging-history-store-v1":
                let history = try decodeHistory(entry.canonicalRecordBytes)
                guard histories[entry.entryID] == nil else {
                    throw LoggingHandoffPayloadError.invalidEntry(entry.entryID)
                }
                histories[entry.entryID] = history
                historySources[entry.entryID] = sourceStateRootUUID
            default:
                throw LoggingHandoffPayloadError.invalidEntry(entry.entryID)
            }
        }
        containers.sort {
            $0.containerID.utf8.lexicographicallyPrecedes($1.containerID.utf8)
        }
        protectedValues.sort {
            if $0.descriptor.containerID != $1.descriptor.containerID {
                return $0.descriptor.containerID.utf8.lexicographicallyPrecedes(
                    $1.descriptor.containerID.utf8
                )
            }
            return $0.descriptor.entryID.utf8.lexicographicallyPrecedes(
                $1.descriptor.entryID.utf8
            )
        }
        guard
            !containers.isEmpty,
            Set(containers.map(\.containerID)).count == containers.count
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let protectedEntryIDs = protectedValues.map(\.descriptor.entryID)
        let historyEntryIDs = Array(histories.keys)
        var referencedProtectedEntryIDs: [String] = []
        var referencedHistoryEntryIDs: [String] = []
        var sourceBlobBindings = Set<String>()
        for container in containers {
            guard let containerSource = containerSources[container.containerID]
            else {
                throw LoggingHandoffPayloadError.invalidContainer(
                    container.containerID
                )
            }
            let frames = protectedValues.filter {
                $0.descriptor.containerID == container.containerID
                    && $0.descriptor.sourceStateRootUUID == containerSource
            }
            let requestedProtectedNames = Set(container.requested.protectedOptionNames)
            let resolvedProtectedNames = Set(container.sourceResolved.protectedOptionNames)
            guard
                !container.containerID.isEmpty,
                container.containerID.precomposedStringWithCanonicalMapping
                    == container.containerID,
                container.schemaVersion == 1,
                container.protectedEntryIDs.count
                    == Set(container.protectedEntryIDs).count,
                container.historyEntryIDs.count == Set(container.historyEntryIDs).count,
                container.protectedEntryIDs == container.protectedEntryIDs.sorted(by: utf8Less),
                container.historyEntryIDs == container.historyEntryIDs.sorted(by: utf8Less),
                requestedProtectedNames.isSubset(of: resolvedProtectedNames),
                container.requested.safeOptions.allSatisfy({
                    container.sourceResolved.safeOptions[$0.key] == $0.value
                }),
                Set(frames.map(\.optionName)) == resolvedProtectedNames,
                frames.map(\.descriptor.entryID) == container.protectedEntryIDs
            else {
                throw LoggingHandoffPayloadError.invalidContainer(container.containerID)
            }
            for frame in frames {
                let binding =
                    "\(frame.descriptor.containerID.utf8.count):"
                    + frame.descriptor.containerID
                    + frame.descriptor.sourceBlobIdentityDigest
                guard sourceBlobBindings.insert(binding).inserted else {
                    throw LoggingHandoffPayloadError.invalidEntry(
                        frame.descriptor.entryID
                    )
                }
            }
            for entryID in container.historyEntryIDs {
                guard
                    let history = histories[entryID],
                    historySources[entryID] == containerSource,
                    entryID
                        == historyEntryID(
                            containerID: container.containerID,
                            storeID: history.storeID
                        )
                else {
                    throw LoggingHandoffPayloadError.invalidContainer(
                        container.containerID
                    )
                }
                if let export = history.providerExportReceipt {
                    guard
                        export.request.containerID == container.containerID,
                        export.request.sourceStateRootUUID == containerSource
                    else {
                        throw LoggingHandoffPayloadError.invalidContainer(
                            container.containerID
                        )
                    }
                }
            }
            referencedProtectedEntryIDs.append(contentsOf: container.protectedEntryIDs)
            referencedHistoryEntryIDs.append(contentsOf: container.historyEntryIDs)
        }
        guard
            referencedProtectedEntryIDs.count
                == Set(referencedProtectedEntryIDs).count,
            referencedHistoryEntryIDs.count == Set(referencedHistoryEntryIDs).count,
            Set(referencedProtectedEntryIDs) == Set(protectedEntryIDs),
            Set(referencedHistoryEntryIDs) == Set(historyEntryIDs)
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return LoggingHandoffDecodedPayloadV1(
            containers: containers,
            protectedValues: protectedValues,
            historyStores: histories
        )
    }

    private static func containerEntries(
        record: LoggingHandoffContainerRecordV1,
        protectedFrames: [LoggingHandoffProtectedValueFrameV1],
        histories: [LoggingHandoffHistoryStoreV1],
        sourceStateRootUUID: String
    ) throws -> [ProviderHandoffPayloadPackageEntryV1] {
        var values = [
            ProviderHandoffPayloadPackageEntryV1(
                entryID: containerEntryID(record.containerID),
                sourceStateRootUUID: sourceStateRootUUID,
                recordKind: "logging-container-v1",
                schemaVersion: 1,
                canonicalRecordBytes: try encodeContainer(record)
            )
        ]
        values.append(
            contentsOf: try protectedFrames.map { frame in
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: frame.descriptor.entryID,
                    sourceStateRootUUID: sourceStateRootUUID,
                    recordKind: "logging-protected-option-v1",
                    schemaVersion: 1,
                    canonicalRecordBytes: try encodeProtectedFrame(frame)
                )
            })
        values.append(
            contentsOf: try histories.map { history in
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: historyEntryID(
                        containerID: record.containerID,
                        storeID: history.storeID
                    ),
                    sourceStateRootUUID: sourceStateRootUUID,
                    recordKind: "logging-history-store-v1",
                    schemaVersion: 1,
                    canonicalRecordBytes: try encodeHistory(history)
                )
            })
        return values
    }

    private static func encodeContainer(
        _ value: LoggingHandoffContainerRecordV1
    ) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(
            .map([
                .init("containerID", .textString(value.containerID)),
                .init("historyEntryIDs", .array(value.historyEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
                .init("protectedEntryIDs", .array(value.protectedEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
                .init("requested", requested(value.requested)),
                .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
                .init("sourceResolved", sourceResolved(value.sourceResolved)),
                .init("terminalAudit", try terminalAudit(value.terminalAudit)),
            ]))
    }

    private static func encodeProtectedFrame(
        _ value: LoggingHandoffProtectedValueFrameV1
    ) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(
            .map([
                .init("boundedValueByteLength", .unsigned(value.descriptor.boundedValueByteLength)),
                .init("containerID", .textString(value.descriptor.containerID)),
                .init("entryID", .textString(value.descriptor.entryID)),
                .init("optionName", .textString(value.optionName)),
                .init("sourceAuthorityLineageUUID", .textString(value.descriptor.sourceAuthorityLineageUUID)),
                .init("sourceBlobIdentityDigest", try digest(value.descriptor.sourceBlobIdentityDigest)),
                .init("sourceLineageKeyVersion", .unsigned(value.descriptor.sourceLineageKeyVersion)),
                .init("sourceProtectedContentDigest", try digest(value.descriptor.sourceProtectedContentDigest)),
                .init("sourceStateRootUUID", .textString(value.descriptor.sourceStateRootUUID)),
                .init("value", .byteString(value.value)),
            ]))
    }

    private static func encodeHistory(
        _ value: LoggingHandoffHistoryStoreV1
    ) throws -> Data {
        let entries: [ProviderHandoffCanonicalMapEntry] = [
            .init("byteLength", .unsigned(value.byteLength)),
            .init("bytes", value.bytes.map(ProviderHandoffCanonicalValue.byteString) ?? .null),
            .init("contentDigestSHA256", try optionalDigest(value.contentDigestSHA256)),
            .init("compressed", .boolean(value.compressed)),
            .init("disposition", .textString(value.disposition.rawValue)),
            .init("formatVersion", .unsigned(UInt64(value.formatVersion))),
            .init("kind", .textString(value.kind.rawValue)),
            .init("maximumInternalSequence", .unsigned(value.maximumInternalSequence)),
            .init("providerExportDigestSHA256", try optionalDigest(value.providerExportDigestSHA256)),
            .init(
                "providerExportReceipt",
                value.providerExportReceipt.map(historyHandoffExportReceipt)
                    ?? .null
            ),
            .init("rotationIndex", .unsigned(value.rotationIndex)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("sourceDeviceID", .optional(value.sourceDeviceID)),
            .init("sourceInode", .optional(value.sourceInode)),
            .init("storeID", .textString(value.storeID)),
            .init("terminalHistoryEpoch", .unsigned(value.terminalHistoryEpoch)),
        ]
        return try ProviderHandoffCanonicalCBOR.encode(.map(entries))
    }

    private static func requested(
        _ value: PersistedContainerLogRequest
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("driver", .optional(value.driver)),
            .init("protectedOptionNames", .array(value.protectedOptionNames.map(ProviderHandoffCanonicalValue.textString))),
            .init("safeOptions", stringMap(value.safeOptions)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func sourceResolved(
        _ value: LoggingSourceResolvedConfigurationV1
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("contractDigest", .textString(value.contractDigest)),
            .init("delivery", delivery(value.delivery)),
            .init("driver", .textString(value.driver)),
            .init("leaseGeneration", .unsigned(value.leaseGeneration)),
            .init("protectedOptionNames", .array(value.protectedOptionNames.map(ProviderHandoffCanonicalValue.textString))),
            .init("providerGenerationAtResolution", .unsigned(value.providerGenerationAtResolution)),
            .init("providerHistoryMigrationReceipt", value.providerHistoryMigrationReceipt.map(historyReceipt) ?? .null),
            .init("providerIdentity", providerIdentity(value.providerIdentity)),
            .init("readPolicy", readPolicy(value.readPolicy)),
            .init("safeOptions", stringMap(value.safeOptions)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func delivery(
        _ value: LogDeliveryConfiguration
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("effectiveMaxBufferSizeInBytes", .optional(value.effectiveMaxBufferSizeInBytes)),
            .init("effectiveMode", .textString(value.effectiveMode.rawValue)),
            .init("maxBufferSizeInBytes", .optional(value.maxBufferSizeInBytes)),
            .init("requestedMode", value.requestedMode.map { .textString($0.rawValue) } ?? .null),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func readPolicy(
        _ value: LogReadPolicy
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("cache", value.cache.map(cache) ?? .null),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("source", .textString(value.source.rawValue)),
        ])
    }

    private static func cache(_ value: LogCacheConfiguration) -> ProviderHandoffCanonicalValue {
        .map([
            .init("compress", .boolean(value.compress)),
            .init("maxFileCount", .unsigned(UInt64(value.maxFileCount))),
            .init("maxSizeInBytes", .unsigned(value.maxSizeInBytes)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func providerIdentity(
        _ value: LogDriverProviderIdentity
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("id", .textString(value.id)),
            .init("kind", .textString(value.kind.rawValue)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("version", .textString(value.version)),
        ])
    }

    private static func historyReceipt(
        _ value: LogDriverHistoryMigrationReceiptV1
    ) -> ProviderHandoffCanonicalValue {
        let request = value.request
        return .map([
            .init("providerOutcomeDigest", .textString(value.providerOutcomeDigest)),
            .init(
                "request",
                .map([
                    .init("containerID", .textString(request.containerID)),
                    .init("contractDigest", .textString(request.contractDigest)),
                    .init("providerID", .textString(request.providerID)),
                    .init("schemaVersion", .unsigned(UInt64(request.schemaVersion))),
                    .init("sourceLeaseGeneration", .unsigned(request.sourceLeaseGeneration)),
                    .init("sourceProviderGeneration", .unsigned(request.sourceProviderGeneration)),
                    .init("targetLeaseGeneration", .unsigned(request.targetLeaseGeneration)),
                    .init("targetProviderGeneration", .unsigned(request.targetProviderGeneration)),
                    .init("terminalHistoryDigest", .textString(request.terminalHistoryDigest)),
                ])),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func historyHandoffExportReceipt(
        _ value: LogDriverHistoryHandoffExportReceiptV1
    ) -> ProviderHandoffCanonicalValue {
        let request = value.request
        return .map([
            .init(
                "exportReceiptDigestSHA256",
                .textString(value.exportReceiptDigestSHA256)
            ),
            .init(
                "providerOutcomeDigestSHA256",
                .textString(value.providerOutcomeDigestSHA256)
            ),
            .init(
                "request",
                .map([
                    .init("containerID", .textString(request.containerID)),
                    .init("destinationStateRootUUID", .textString(request.destinationStateRootUUID)),
                    .init("manifestID", .textString(request.manifestID)),
                    .init("schemaVersion", .unsigned(UInt64(request.schemaVersion))),
                    .init("sourceContractDigest", .textString(request.sourceContractDigest)),
                    .init("sourceLeaseGeneration", .unsigned(request.sourceLeaseGeneration)),
                    .init("sourceProviderGeneration", .unsigned(request.sourceProviderGeneration)),
                    .init("sourceProviderID", .textString(request.sourceProviderID)),
                    .init("sourceStateRootUUID", .textString(request.sourceStateRootUUID)),
                    .init("terminalHistoryDigestSHA256", .textString(request.terminalHistoryDigestSHA256)),
                    .init("tokenID", .textString(request.tokenID)),
                ])),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
        ])
    }

    private static func terminalAudit(
        _ value: LoggingTerminalAuditV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("historyRetentionDigestSHA256", try digest(value.historyRetentionDigestSHA256)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("terminalCategoryDigestSHA256", try digest(value.terminalCategoryDigestSHA256)),
            .init("terminalDetachedCleanupCount", .unsigned(value.terminalDetachedCleanupCount)),
            .init("terminalReaderCount", .unsigned(value.terminalReaderCount)),
            .init("terminalWriterCount", .unsigned(value.terminalWriterCount)),
        ])
    }

    // Decoding deliberately round-trips the closed CBOR projection through a
    // tiny schema decoder; it never accepts JSON or an implementation object.
    private static func decodeContainer(
        _ data: Data
    ) throws -> LoggingHandoffContainerRecordV1 {
        let map = try exactMap(
            ProviderHandoffCanonicalCBOR.decode(data),
            keys: [
                "containerID", "historyEntryIDs", "protectedEntryIDs", "requested",
                "schemaVersion", "sourceResolved", "terminalAudit",
            ]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return LoggingHandoffContainerRecordV1(
            schemaVersion: 1,
            containerID: try text(map["containerID"]),
            requested: try decodeRequested(map["requested"]),
            sourceResolved: try decodeSourceResolved(map["sourceResolved"]),
            protectedEntryIDs: try textArray(map["protectedEntryIDs"]),
            historyEntryIDs: try textArray(map["historyEntryIDs"]),
            terminalAudit: try decodeTerminalAudit(map["terminalAudit"])
        )
    }

    private static func decodeProtectedFrame(
        _ data: Data
    ) throws -> LoggingHandoffProtectedValueFrameV1 {
        let map = try exactMap(
            ProviderHandoffCanonicalCBOR.decode(data),
            keys: [
                "boundedValueByteLength", "containerID", "entryID", "optionName",
                "sourceAuthorityLineageUUID", "sourceBlobIdentityDigest",
                "sourceLineageKeyVersion", "sourceProtectedContentDigest",
                "sourceStateRootUUID", "value",
            ]
        )
        let value = try bytes(map["value"])
        let descriptor = ProtectedLoggingOptionHandoffEntryV1(
            entryID: try text(map["entryID"]),
            containerID: try text(map["containerID"]),
            sourceStateRootUUID: try text(map["sourceStateRootUUID"]),
            sourceAuthorityLineageUUID: try text(map["sourceAuthorityLineageUUID"]),
            sourceLineageKeyVersion: try unsigned(map["sourceLineageKeyVersion"]),
            sourceBlobIdentityDigest: try digestText(map["sourceBlobIdentityDigest"]),
            sourceProtectedContentDigest: try digestText(map["sourceProtectedContentDigest"]),
            boundedValueByteLength: try unsigned(map["boundedValueByteLength"])
        )
        let optionName = try text(map["optionName"])
        guard
            !descriptor.entryID.isEmpty,
            !descriptor.containerID.isEmpty,
            descriptor.containerID.precomposedStringWithCanonicalMapping
                == descriptor.containerID,
            !descriptor.sourceAuthorityLineageUUID.isEmpty,
            descriptor.sourceLineageKeyVersion > 0,
            !optionName.isEmpty,
            optionName.precomposedStringWithCanonicalMapping == optionName,
            optionName.utf8.count
                <= LoggingProtectedOptionsStore.maximumOptionNameBytes,
            descriptor.boundedValueByteLength == UInt64(value.count),
            value.count <= LoggingProtectedOptionsStore.maximumOptionValueBytes
        else {
            throw LoggingHandoffPayloadError.invalidEntry(descriptor.entryID)
        }
        return LoggingHandoffProtectedValueFrameV1(
            descriptor: descriptor,
            optionName: optionName,
            value: value
        )
    }

    private static func decodeHistory(_ data: Data) throws -> LoggingHandoffHistoryStoreV1 {
        let map = try exactMap(
            ProviderHandoffCanonicalCBOR.decode(data),
            keys: [
                "byteLength", "bytes", "compressed", "contentDigestSHA256", "disposition",
                "formatVersion", "kind", "maximumInternalSequence",
                "providerExportDigestSHA256", "providerExportReceipt",
                "rotationIndex", "schemaVersion",
                "sourceDeviceID", "sourceInode", "storeID", "terminalHistoryEpoch",
            ]
        )
        guard
            try unsigned(map["schemaVersion"]) == 1,
            let kind = LoggingHandoffHistoryKindV1(rawValue: try text(map["kind"])),
            let disposition = LoggingHandoffHistoryDispositionV1(
                rawValue: try text(map["disposition"])
            )
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let encodedBytes = try optionalBytes(map["bytes"])
        guard let formatVersion = UInt32(exactly: try unsigned(map["formatVersion"])) else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let value = try LoggingHandoffHistoryStoreV1(
            storeID: text(map["storeID"]),
            kind: kind,
            disposition: disposition,
            formatVersion: formatVersion,
            rotationIndex: unsigned(map["rotationIndex"]),
            compressed: bool(map["compressed"]),
            terminalHistoryEpoch: unsigned(map["terminalHistoryEpoch"]),
            maximumInternalSequence: unsigned(map["maximumInternalSequence"]),
            sourceDeviceID: optionalUnsigned(map["sourceDeviceID"]),
            sourceInode: optionalUnsigned(map["sourceInode"]),
            bytes: encodedBytes,
            providerExportReceipt: decodeHistoryHandoffExportReceipt(
                map["providerExportReceipt"]
            )
        )
        let encodedByteLength = try unsigned(map["byteLength"])
        let encodedContentDigest = try optionalDigestText(map["contentDigestSHA256"])
        guard
            value.byteLength == encodedByteLength,
            value.contentDigestSHA256 == encodedContentDigest,
            value.providerExportDigestSHA256
                == (try optionalDigestText(map["providerExportDigestSHA256"]))
        else {
            throw LoggingHandoffPayloadError.invalidHistory(value.storeID)
        }
        return value
    }

    private static func decodeRequested(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> PersistedContainerLogRequest {
        let map = try exactMap(
            value,
            keys: ["driver", "protectedOptionNames", "safeOptions", "schemaVersion"]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return try PersistedContainerLogRequest(
            driver: optionalText(map["driver"]),
            safeOptions: decodeStringMap(map["safeOptions"]),
            protectedOptionNames: textArray(map["protectedOptionNames"])
        )
    }

    private static func decodeSourceResolved(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LoggingSourceResolvedConfigurationV1 {
        let map = try exactMap(
            value,
            keys: [
                "contractDigest", "delivery", "driver", "leaseGeneration",
                "protectedOptionNames", "providerGenerationAtResolution",
                "providerHistoryMigrationReceipt", "providerIdentity", "readPolicy",
                "safeOptions", "schemaVersion",
            ]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return try LoggingSourceResolvedConfigurationV1(
            leaseGeneration: try unsigned(map["leaseGeneration"]),
            driver: try text(map["driver"]),
            safeOptions: try decodeStringMap(map["safeOptions"]),
            protectedOptionNames: try textArray(map["protectedOptionNames"]),
            delivery: try decodeDelivery(map["delivery"]),
            readPolicy: try decodeReadPolicy(map["readPolicy"]),
            providerIdentity: try decodeProviderIdentity(map["providerIdentity"]),
            providerGenerationAtResolution: try unsigned(
                map["providerGenerationAtResolution"]
            ),
            contractDigest: try text(map["contractDigest"]),
            providerHistoryMigrationReceipt: try decodeHistoryReceipt(
                map["providerHistoryMigrationReceipt"]
            )
        )
    }

    private static func decodeDelivery(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LogDeliveryConfiguration {
        let map = try exactMap(
            value,
            keys: [
                "effectiveMaxBufferSizeInBytes", "effectiveMode",
                "maxBufferSizeInBytes", "requestedMode", "schemaVersion",
            ]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let requested: LogDeliveryConfiguration.Mode?
        if let rawRequested = try optionalText(map["requestedMode"]) {
            guard let value = LogDeliveryConfiguration.Mode(rawValue: rawRequested) else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            requested = value
        } else {
            requested = nil
        }
        let value = try LogDeliveryConfiguration(
            requestedMode: requested,
            maxBufferSizeInBytes: optionalUnsigned(map["maxBufferSizeInBytes"])
        )
        let encodedEffectiveMode = try text(map["effectiveMode"])
        let encodedEffectiveBufferSize = try optionalUnsigned(
            map["effectiveMaxBufferSizeInBytes"]
        )
        guard
            value.effectiveMode.rawValue == encodedEffectiveMode,
            value.effectiveMaxBufferSizeInBytes
                == encodedEffectiveBufferSize
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return value
    }

    private static func decodeReadPolicy(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LogReadPolicy {
        let map = try exactMap(value, keys: ["cache", "schemaVersion", "source"])
        guard
            try unsigned(map["schemaVersion"]) == 1,
            let source = LogReadPolicy.Source(rawValue: try text(map["source"]))
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let cacheValue: LogCacheConfiguration?
        if case .null? = map["cache"] {
            cacheValue = nil
        } else {
            let cacheMap = try exactMap(
                map["cache"],
                keys: ["compress", "maxFileCount", "maxSizeInBytes", "schemaVersion"]
            )
            guard
                try unsigned(cacheMap["schemaVersion"]) == 1,
                case .boolean(let compress)? = cacheMap["compress"],
                let count = Int(exactly: try unsigned(cacheMap["maxFileCount"]))
            else {
                throw LoggingHandoffPayloadError.invalidPackage
            }
            cacheValue = try LogCacheConfiguration(
                maxSizeInBytes: unsigned(cacheMap["maxSizeInBytes"]),
                maxFileCount: count,
                compress: compress
            )
        }
        return try LogReadPolicy(source: source, cache: cacheValue)
    }

    private static func decodeProviderIdentity(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LogDriverProviderIdentity {
        let map = try exactMap(
            value,
            keys: ["id", "kind", "schemaVersion", "version"]
        )
        guard
            try unsigned(map["schemaVersion"]) == 1,
            let kind = LogDriverProviderIdentity.Kind(rawValue: try text(map["kind"]))
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return LogDriverProviderIdentity(
            id: try text(map["id"]),
            version: try text(map["version"]),
            kind: kind
        )
    }

    private static func decodeHistoryReceipt(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LogDriverHistoryMigrationReceiptV1? {
        if case .null? = value { return nil }
        let map = try exactMap(
            value,
            keys: ["providerOutcomeDigest", "request", "schemaVersion"]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let requestMap = try exactMap(
            map["request"],
            keys: [
                "containerID", "contractDigest", "providerID", "schemaVersion",
                "sourceLeaseGeneration", "sourceProviderGeneration",
                "targetLeaseGeneration", "targetProviderGeneration",
                "terminalHistoryDigest",
            ]
        )
        guard try unsigned(requestMap["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let request = try LogDriverHistoryMigrationRequestV1(
            containerID: text(requestMap["containerID"]),
            sourceLeaseGeneration: unsigned(requestMap["sourceLeaseGeneration"]),
            targetLeaseGeneration: unsigned(requestMap["targetLeaseGeneration"]),
            providerID: text(requestMap["providerID"]),
            sourceProviderGeneration: unsigned(requestMap["sourceProviderGeneration"]),
            targetProviderGeneration: unsigned(requestMap["targetProviderGeneration"]),
            contractDigest: text(requestMap["contractDigest"]),
            terminalHistoryDigest: text(requestMap["terminalHistoryDigest"])
        )
        return try LogDriverHistoryMigrationReceiptV1(
            request: request,
            providerOutcomeDigest: text(map["providerOutcomeDigest"])
        )
    }

    private static func decodeHistoryHandoffExportReceipt(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LogDriverHistoryHandoffExportReceiptV1? {
        if case .null? = value { return nil }
        let map = try exactMap(
            value,
            keys: [
                "exportReceiptDigestSHA256", "providerOutcomeDigestSHA256",
                "request", "schemaVersion",
            ]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let requestMap = try exactMap(
            map["request"],
            keys: [
                "containerID", "destinationStateRootUUID", "manifestID",
                "schemaVersion", "sourceContractDigest",
                "sourceLeaseGeneration", "sourceProviderGeneration",
                "sourceProviderID", "sourceStateRootUUID",
                "terminalHistoryDigestSHA256", "tokenID",
            ]
        )
        guard try unsigned(requestMap["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        let request = try LogDriverHistoryHandoffExportRequestV1(
            tokenID: text(requestMap["tokenID"]),
            manifestID: text(requestMap["manifestID"]),
            containerID: text(requestMap["containerID"]),
            sourceStateRootUUID: text(requestMap["sourceStateRootUUID"]),
            destinationStateRootUUID: text(requestMap["destinationStateRootUUID"]),
            sourceLeaseGeneration: unsigned(requestMap["sourceLeaseGeneration"]),
            sourceProviderID: text(requestMap["sourceProviderID"]),
            sourceProviderGeneration: unsigned(requestMap["sourceProviderGeneration"]),
            sourceContractDigest: text(requestMap["sourceContractDigest"]),
            terminalHistoryDigestSHA256: text(
                requestMap["terminalHistoryDigestSHA256"]
            )
        )
        let receipt = try LogDriverHistoryHandoffExportReceiptV1(
            request: request,
            providerOutcomeDigestSHA256: text(
                map["providerOutcomeDigestSHA256"]
            )
        )
        guard
            receipt.exportReceiptDigestSHA256
                == (try text(map["exportReceiptDigestSHA256"]))
        else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return receipt
    }

    private static func decodeTerminalAudit(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> LoggingTerminalAuditV1 {
        let map = try exactMap(
            value,
            keys: [
                "historyRetentionDigestSHA256", "schemaVersion",
                "terminalCategoryDigestSHA256", "terminalDetachedCleanupCount",
                "terminalReaderCount", "terminalWriterCount",
            ]
        )
        guard try unsigned(map["schemaVersion"]) == 1 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return try LoggingTerminalAuditV1(
            terminalWriterCount: unsigned(map["terminalWriterCount"]),
            terminalReaderCount: unsigned(map["terminalReaderCount"]),
            terminalDetachedCleanupCount: unsigned(map["terminalDetachedCleanupCount"]),
            terminalCategoryDigestSHA256: digestText(map["terminalCategoryDigestSHA256"]),
            historyRetentionDigestSHA256: digestText(
                map["historyRetentionDigestSHA256"]
            )
        )
    }

    private static func verifyProtectedFrame(
        _ frame: LoggingHandoffProtectedValueFrameV1,
        sourceLineageHMACSHA256Key: Data
    ) throws {
        let actual = try protectedContentDigest(
            frame,
            sourceLineageHMACSHA256Key: sourceLineageHMACSHA256Key
        )
        guard
            ProviderHandoffDigest.constantTimeEqual(
                try ProviderHandoffDigest.parseSHA256(actual),
                try ProviderHandoffDigest.parseSHA256(
                    frame.descriptor.sourceProtectedContentDigest
                )
            )
        else {
            throw LoggingHandoffPayloadError.protectedDigestMismatch(
                frame.descriptor.entryID
            )
        }
    }

    private static func protectedContentDigest(
        _ frame: LoggingHandoffProtectedValueFrameV1,
        sourceLineageHMACSHA256Key: Data
    ) throws -> String {
        let descriptor = frame.descriptor
        let projection: ProviderHandoffCanonicalValue = .map([
            .init("boundedValueByteLength", .unsigned(descriptor.boundedValueByteLength)),
            .init("containerID", .textString(descriptor.containerID)),
            .init("entryID", .textString(descriptor.entryID)),
            .init("optionName", .textString(frame.optionName)),
            .init("sourceAuthorityLineageUUID", .textString(descriptor.sourceAuthorityLineageUUID)),
            .init("sourceBlobIdentityDigest", try digest(descriptor.sourceBlobIdentityDigest)),
            .init("sourceLineageKeyVersion", .unsigned(descriptor.sourceLineageKeyVersion)),
            .init("sourceStateRootUUID", .textString(descriptor.sourceStateRootUUID)),
            .init("value", .byteString(frame.value)),
        ])
        var message = Data("container-handoff-logging-protected-content-v1".utf8)
        message.append(0)
        message.append(try ProviderHandoffCanonicalCBOR.encode(projection))
        return ProviderHandoffDigest.hmacSHA256(
            key: sourceLineageHMACSHA256Key,
            data: message
        )
    }

    private static func stringMap(
        _ values: [String: String]
    ) -> ProviderHandoffCanonicalValue {
        .map(values.map { .init($0.key, .textString($0.value)) })
    }

    private static func decodeStringMap(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> [String: String] {
        guard case .map(let entries)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return try Dictionary(
            uniqueKeysWithValues: entries.map {
                ($0.key, try text($0.value))
            })
    }

    private static func exactMap(
        _ value: ProviderHandoffCanonicalValue?,
        keys: Set<String>
    ) throws -> [String: ProviderHandoffCanonicalValue] {
        guard case .map(let entries)? = value, Set(entries.map(\.key)) == keys else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }

    private static func text(_ value: ProviderHandoffCanonicalValue?) throws -> String {
        guard case .textString(let value)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return value
    }

    private static func optionalText(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String? {
        switch value {
        case .null?: nil
        case .textString(let value)?: value
        default: throw LoggingHandoffPayloadError.invalidPackage
        }
    }

    private static func textArray(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> [String] {
        guard case .array(let values)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return try values.map { try text($0) }
    }

    private static func bytes(_ value: ProviderHandoffCanonicalValue?) throws -> Data {
        guard case .byteString(let value)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return value
    }

    private static func optionalBytes(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> Data? {
        switch value {
        case .null?: nil
        case .byteString(let value)?: value
        default: throw LoggingHandoffPayloadError.invalidPackage
        }
    }

    private static func unsigned(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> UInt64 {
        guard case .unsigned(let value)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return value
    }

    private static func bool(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> Bool {
        guard case .boolean(let value)? = value else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return value
    }

    private static func optionalUnsigned(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> UInt64? {
        switch value {
        case .null?: nil
        case .unsigned(let value)?: value
        default: throw LoggingHandoffPayloadError.invalidPackage
        }
    }

    private static func digest(
        _ value: String
    ) throws -> ProviderHandoffCanonicalValue {
        .byteString(try ProviderHandoffDigest.parseSHA256(value))
    }

    private static func optionalDigest(
        _ value: String?
    ) throws -> ProviderHandoffCanonicalValue {
        guard let value else { return .null }
        return try digest(value)
    }

    private static func digestText(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String {
        let value = try bytes(value)
        guard value.count == 32 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return ProviderHandoffDigest.hex(value)
    }

    private static func optionalDigestText(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String? {
        guard let value = try optionalBytes(value) else { return nil }
        guard value.count == 32 else {
            throw LoggingHandoffPayloadError.invalidPackage
        }
        return ProviderHandoffDigest.hex(value)
    }

    private static func encodedIdentifier(_ value: String) -> String {
        ProviderHandoffDigest.hex(Data(value.utf8))
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func containerEntryID(_ containerID: String) -> String {
        "logging:\(encodedIdentifier(containerID)):00:container"
    }

    private static func protectedEntryID(
        containerID: String,
        optionName: String
    ) -> String {
        "logging:\(encodedIdentifier(containerID)):10:option:\(encodedIdentifier(optionName))"
    }

    private static func historyEntryID(containerID: String, storeID: String) -> String {
        "logging:\(encodedIdentifier(containerID)):20:history:\(encodedIdentifier(storeID))"
    }
}
