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

enum LoggingHandoffPrivateStagingStateError: Error, Equatable, Sendable {
    case invalidState
    case nonCanonicalEncoding
    case receiptMismatch
}

/// Immutable history expectation retained with a protected staging receipt.
///
/// History bytes remain in the verified content-addressed handoff bundle. This
/// record freezes the exact metadata/digests that reconciliation must recover
/// from that bundle; it cannot silently accept replacement bytes.
struct LoggingHandoffStagedHistoryV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let entryID: String
    let containerID: String
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

    init(
        entryID: String,
        containerID: String,
        history: LoggingHandoffHistoryStoreV1
    ) {
        schemaVersion = 1
        self.entryID = entryID
        self.containerID = containerID
        storeID = history.storeID
        kind = history.kind
        disposition = history.disposition
        formatVersion = history.formatVersion
        rotationIndex = history.rotationIndex
        compressed = history.compressed
        terminalHistoryEpoch = history.terminalHistoryEpoch
        maximumInternalSequence = history.maximumInternalSequence
        sourceDeviceID = history.sourceDeviceID
        sourceInode = history.sourceInode
        byteLength = history.byteLength
        contentDigestSHA256 = history.contentDigestSHA256
        providerExportDigestSHA256 = history.providerExportDigestSHA256
    }

    func matches(_ history: LoggingHandoffHistoryStoreV1) -> Bool {
        schemaVersion == 1
            && storeID == history.storeID
            && kind == history.kind
            && disposition == history.disposition
            && formatVersion == history.formatVersion
            && rotationIndex == history.rotationIndex
            && compressed == history.compressed
            && terminalHistoryEpoch == history.terminalHistoryEpoch
            && maximumInternalSequence == history.maximumInternalSequence
            && sourceDeviceID == history.sourceDeviceID
            && sourceInode == history.sourceInode
            && byteLength == history.byteLength
            && contentDigestSHA256 == history.contentDigestSHA256
            && providerExportDigestSHA256 == history.providerExportDigestSHA256
    }
}

struct LoggingHandoffStagedContainerV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let containerID: String
    let configuration: ContainerLogConfiguration
    let protectedEntryIDs: [String]
    let histories: [LoggingHandoffStagedHistoryV1]
    let sourceTerminalAudit: LoggingTerminalAuditV1

    init(
        containerID: String,
        configuration: ContainerLogConfiguration,
        protectedEntryIDs: [String],
        histories: [LoggingHandoffStagedHistoryV1],
        sourceTerminalAudit: LoggingTerminalAuditV1
    ) {
        schemaVersion = 1
        self.containerID = containerID
        self.configuration = configuration
        self.protectedEntryIDs = protectedEntryIDs
        self.histories = histories
        self.sourceTerminalAudit = sourceTerminalAudit
    }
}

/// Controller-private, immutable destination resolution frozen at import.
///
/// This state shares the receipt's authenticated 0600 envelope. Generic
/// handoff records still see only the receipt digest and never receive a
/// protected reference or destination configuration.
struct LoggingHandoffPrivateStagingStateV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let handoffTokenID: String
    let handoffManifestID: String
    let handoffManifestDigest: String
    let bundleObjectID: String
    let payloadDescriptorDigestSHA256: String
    let verifiedCanonicalContentDigest: String
    let receiptDigestSHA256: String
    let containers: [LoggingHandoffStagedContainerV1]

    init(
        receipt: LoggingProtectedOptionStagingReceiptV1,
        containers: [LoggingHandoffStagedContainerV1]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        handoffTokenID = receipt.handoffTokenID
        handoffManifestID = receipt.handoffManifestID
        handoffManifestDigest = receipt.handoffManifestDigest
        bundleObjectID = receipt.bundleObjectID
        payloadDescriptorDigestSHA256 = receipt.payloadDescriptorDigestSHA256
        verifiedCanonicalContentDigest = receipt.verifiedCanonicalContentDigest
        receiptDigestSHA256 = receipt.receiptDigestSHA256
        self.containers = containers
        try validate(receipt: receipt)
    }

    func validate(receipt: LoggingProtectedOptionStagingReceiptV1) throws {
        guard
            schemaVersion == Self.currentSchemaVersion,
            handoffTokenID == receipt.handoffTokenID,
            handoffManifestID == receipt.handoffManifestID,
            handoffManifestDigest == receipt.handoffManifestDigest,
            bundleObjectID == receipt.bundleObjectID,
            payloadDescriptorDigestSHA256
                == receipt.payloadDescriptorDigestSHA256,
            verifiedCanonicalContentDigest
                == receipt.verifiedCanonicalContentDigest,
            receiptDigestSHA256 == receipt.receiptDigestSHA256,
            !containers.isEmpty,
            containers.map(\.containerID)
                == containers.map(\.containerID).sorted(by: Self.utf8Less),
            containers.map(\.containerID).count
                == Set(containers.map(\.containerID)).count
        else {
            throw LoggingHandoffPrivateStagingStateError.receiptMismatch
        }
        _ = try ProviderHandoffDigest.parseSHA256(handoffManifestDigest)
        _ = try ProviderHandoffDigest.parseSHA256(
            String(bundleObjectID.dropFirst("sha256:".count))
        )
        _ = try ProviderHandoffDigest.parseSHA256(
            payloadDescriptorDigestSHA256
        )
        _ = try ProviderHandoffDigest.parseSHA256(
            verifiedCanonicalContentDigest
        )
        _ = try ProviderHandoffDigest.parseSHA256(receiptDigestSHA256)

        var protectedEntryIDs: [String] = []
        var historyEntryIDs = Set<String>()
        for container in containers {
            guard
                container.schemaVersion == 1,
                !container.containerID.isEmpty,
                container.containerID.precomposedStringWithCanonicalMapping
                    == container.containerID,
                !container.configuration.isLegacy,
                let resolved = container.configuration.resolved,
                container.protectedEntryIDs
                    == container.protectedEntryIDs.sorted(by: Self.utf8Less),
                container.protectedEntryIDs.count
                    == Set(container.protectedEntryIDs).count,
                resolved.protectedOptionNames.isEmpty
                    == container.protectedEntryIDs.isEmpty,
                container.histories.map(\.entryID)
                    == container.histories.map(\.entryID).sorted(by: Self.utf8Less)
            else {
                throw LoggingHandoffPrivateStagingStateError.invalidState
            }
            for history in container.histories {
                guard
                    history.schemaVersion == 1,
                    history.containerID == container.containerID,
                    !history.entryID.isEmpty,
                    !history.storeID.isEmpty,
                    history.formatVersion > 0,
                    historyEntryIDs.insert(history.entryID).inserted,
                    (history.sourceDeviceID == nil) == (history.sourceInode == nil)
                else {
                    throw LoggingHandoffPrivateStagingStateError.invalidState
                }
                if let digest = history.contentDigestSHA256 {
                    _ = try ProviderHandoffDigest.parseSHA256(digest)
                }
                if let digest = history.providerExportDigestSHA256 {
                    _ = try ProviderHandoffDigest.parseSHA256(digest)
                }
            }
            protectedEntryIDs.append(contentsOf: container.protectedEntryIDs)
        }
        guard
            Set(protectedEntryIDs) == Set(receipt.importedEntries.map(\.entryID)),
            protectedEntryIDs.count == Set(protectedEntryIDs).count
        else {
            throw LoggingHandoffPrivateStagingStateError.receiptMismatch
        }
    }

    func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeCanonicalBytes(
        _ data: Data,
        receipt: LoggingProtectedOptionStagingReceiptV1
    ) throws -> Self {
        let decoded: Self
        do {
            decoded = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw LoggingHandoffPrivateStagingStateError.invalidState
        }
        try decoded.validate(receipt: receipt)
        guard try decoded.canonicalBytes() == data else {
            throw LoggingHandoffPrivateStagingStateError.nonCanonicalEncoding
        }
        return decoded
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
