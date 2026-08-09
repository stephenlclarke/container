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

struct ImportedProtectedLoggingOptionV1: Codable, Equatable, Sendable {
    let entryID: String
    let destinationReference: LoggingProtectedOptionsReference
    let destinationProtectedContentDigest: String
}

struct LoggingProtectedOptionStagingReceiptV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let handoffTokenID: String
    let handoffManifestID: String
    let handoffManifestDigest: String
    let partKind: ProviderHandoffPartKindV1
    let bundleObjectID: String
    let payloadDescriptorDigestSHA256: String
    let verifiedCanonicalContentDigest: String
    let importedEntries: [ImportedProtectedLoggingOptionV1]
    let receiptDigestSHA256: String

    private init(
        schemaVersion: UInt32,
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigest: String,
        partKind: ProviderHandoffPartKindV1,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String,
        verifiedCanonicalContentDigest: String,
        importedEntries: [ImportedProtectedLoggingOptionV1],
        receiptDigestSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.handoffTokenID = handoffTokenID
        self.handoffManifestID = handoffManifestID
        self.handoffManifestDigest = handoffManifestDigest
        self.partKind = partKind
        self.bundleObjectID = bundleObjectID
        self.payloadDescriptorDigestSHA256 = payloadDescriptorDigestSHA256
        self.verifiedCanonicalContentDigest = verifiedCanonicalContentDigest
        self.importedEntries = importedEntries
        self.receiptDigestSHA256 = receiptDigestSHA256
    }

    init(
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigest: String,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String,
        verifiedCanonicalContentDigest: String,
        importedEntries: [ImportedProtectedLoggingOptionV1]
    ) throws {
        try Self.validateIdentity(
            handoffTokenID: handoffTokenID,
            handoffManifestID: handoffManifestID,
            handoffManifestDigest: handoffManifestDigest,
            partKind: .logging,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: payloadDescriptorDigestSHA256,
            verifiedCanonicalContentDigest: verifiedCanonicalContentDigest,
            importedEntries: importedEntries
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.handoffTokenID = handoffTokenID
        self.handoffManifestID = handoffManifestID
        self.handoffManifestDigest = handoffManifestDigest
        self.partKind = .logging
        self.bundleObjectID = bundleObjectID
        self.payloadDescriptorDigestSHA256 = payloadDescriptorDigestSHA256
        self.verifiedCanonicalContentDigest = verifiedCanonicalContentDigest
        self.importedEntries = importedEntries
        self.receiptDigestSHA256 = try Self.digest(
            handoffTokenID: handoffTokenID,
            handoffManifestID: handoffManifestID,
            handoffManifestDigest: handoffManifestDigest,
            partKind: .logging,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: payloadDescriptorDigestSHA256,
            verifiedCanonicalContentDigest: verifiedCanonicalContentDigest,
            importedEntries: importedEntries
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        let tokenID = try container.decode(String.self, forKey: .handoffTokenID)
        let manifestID = try container.decode(String.self, forKey: .handoffManifestID)
        let manifestDigest = try container.decode(String.self, forKey: .handoffManifestDigest)
        let partKind = try container.decode(
            ProviderHandoffPartKindV1.self,
            forKey: .partKind
        )
        let bundleObjectID = try container.decode(String.self, forKey: .bundleObjectID)
        let descriptorDigest = try container.decode(
            String.self,
            forKey: .payloadDescriptorDigestSHA256
        )
        let contentDigest = try container.decode(
            String.self,
            forKey: .verifiedCanonicalContentDigest
        )
        let importedEntries = try container.decode(
            [ImportedProtectedLoggingOptionV1].self,
            forKey: .importedEntries
        )
        let receiptDigest = try container.decode(
            String.self,
            forKey: .receiptDigestSHA256
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        try Self.validateIdentity(
            handoffTokenID: tokenID,
            handoffManifestID: manifestID,
            handoffManifestDigest: manifestDigest,
            partKind: partKind,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: descriptorDigest,
            verifiedCanonicalContentDigest: contentDigest,
            importedEntries: importedEntries
        )
        let expected = try Self.digest(
            handoffTokenID: tokenID,
            handoffManifestID: manifestID,
            handoffManifestDigest: manifestDigest,
            partKind: partKind,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: descriptorDigest,
            verifiedCanonicalContentDigest: contentDigest,
            importedEntries: importedEntries
        )
        guard Self.constantTimeDigestEqual(receiptDigest, expected) else {
            throw LoggingHandoffStagingReceiptError.digestMismatch
        }
        self.schemaVersion = schemaVersion
        self.handoffTokenID = tokenID
        self.handoffManifestID = manifestID
        self.handoffManifestDigest = manifestDigest
        self.partKind = partKind
        self.bundleObjectID = bundleObjectID
        self.payloadDescriptorDigestSHA256 = descriptorDigest
        self.verifiedCanonicalContentDigest = contentDigest
        self.importedEntries = importedEntries
        self.receiptDigestSHA256 = receiptDigest
    }

    func validate(commonRecord: ProviderHandoffPartStagingRecordV1) throws {
        let receiptMatches =
            commonRecord.stagedImportReceiptDigestSHA256.map {
                Self.constantTimeDigestEqual($0, receiptDigestSHA256)
            } ?? true
        guard
            commonRecord.schemaVersion == 1,
            commonRecord.tokenID == handoffTokenID,
            commonRecord.manifestID == handoffManifestID,
            commonRecord.manifestDigest == handoffManifestDigest,
            commonRecord.partKind == partKind,
            commonRecord.bundleObjectID == bundleObjectID,
            commonRecord.payloadDescriptorDigestSHA256
                == payloadDescriptorDigestSHA256,
            commonRecord.verifiedCanonicalContentDigest
                == verifiedCanonicalContentDigest,
            receiptMatches
        else {
            throw LoggingHandoffStagingReceiptError.commonRecordMismatch
        }
    }

    static func importedEntry(
        frame: LoggingHandoffProtectedValueFrameV1,
        destinationReference: LoggingProtectedOptionsReference
    ) throws -> ImportedProtectedLoggingOptionV1 {
        let digest = try ProviderHandoffDigest.domain(
            "container-handoff-logging-destination-protected-content-v1",
            projection: .map([
                .init("destinationIntegrityDigest", .textString(destinationReference.integrityDigest)),
                .init("destinationObjectID", .textString(destinationReference.objectID)),
                .init("entryID", .textString(frame.descriptor.entryID)),
                .init("optionName", .textString(frame.optionName)),
                .init("value", .byteString(frame.value)),
            ])
        )
        return ImportedProtectedLoggingOptionV1(
            entryID: frame.descriptor.entryID,
            destinationReference: destinationReference,
            destinationProtectedContentDigest: digest
        )
    }

    static func canonicalBytes(_ value: Self) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(
            try projection(value, includeReceiptDigest: true)
        )
    }

    static func decodeCanonicalBytes(_ data: Data) throws -> Self {
        let map = try exactMap(
            ProviderHandoffCanonicalCBOR.decode(data),
            keys: [
                "bundleObjectID", "handoffManifestDigest", "handoffManifestID",
                "handoffTokenID", "importedEntries", "partKind",
                "payloadDescriptorDigestSHA256", "receiptDigestSHA256",
                "schemaVersion", "verifiedCanonicalContentDigest",
            ]
        )
        guard
            try unsigned(map["schemaVersion"]) == 1,
            try text(map["partKind"]) == ProviderHandoffPartKindV1.logging.rawValue,
            case .array(let encodedEntries)? = map["importedEntries"]
        else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        let entries = try encodedEntries.map { encoded in
            let entry = try exactMap(
                encoded,
                keys: [
                    "destinationIntegrityDigest", "destinationObjectID",
                    "destinationProtectedContentDigest", "entryID",
                    "referenceSchemaVersion",
                ]
            )
            guard try unsigned(entry["referenceSchemaVersion"]) == 1 else {
                throw LoggingHandoffStagingReceiptError.invalidReceipt
            }
            return ImportedProtectedLoggingOptionV1(
                entryID: try text(entry["entryID"]),
                destinationReference: LoggingProtectedOptionsReference(
                    objectID: try text(entry["destinationObjectID"]),
                    integrityDigest: try text(entry["destinationIntegrityDigest"])
                ),
                destinationProtectedContentDigest: try digestText(
                    entry["destinationProtectedContentDigest"]
                )
            )
        }
        let value = try Self(
            handoffTokenID: text(map["handoffTokenID"]),
            handoffManifestID: text(map["handoffManifestID"]),
            handoffManifestDigest: digestText(map["handoffManifestDigest"]),
            bundleObjectID: text(map["bundleObjectID"]),
            payloadDescriptorDigestSHA256: digestText(
                map["payloadDescriptorDigestSHA256"]
            ),
            verifiedCanonicalContentDigest: digestText(
                map["verifiedCanonicalContentDigest"]
            ),
            importedEntries: entries
        )
        let encodedDigest = try digestText(map["receiptDigestSHA256"])
        guard constantTimeDigestEqual(value.receiptDigestSHA256, encodedDigest) else {
            throw LoggingHandoffStagingReceiptError.digestMismatch
        }
        return value
    }

    private static func validateIdentity(
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigest: String,
        partKind: ProviderHandoffPartKindV1,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String,
        verifiedCanonicalContentDigest: String,
        importedEntries: [ImportedProtectedLoggingOptionV1]
    ) throws {
        guard
            !handoffTokenID.isEmpty,
            !handoffManifestID.isEmpty,
            partKind == .logging,
            bundleObjectID.hasPrefix("sha256:"),
            importedEntries.map(\.entryID)
                == importedEntries.map(\.entryID).sorted(by: utf8Less),
            importedEntries.map(\.entryID).count
                == Set(importedEntries.map(\.entryID)).count
        else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        _ = try ProviderHandoffDigest.parseSHA256(handoffManifestDigest)
        _ = try ProviderHandoffDigest.parseSHA256(
            String(bundleObjectID.dropFirst("sha256:".count))
        )
        _ = try ProviderHandoffDigest.parseSHA256(payloadDescriptorDigestSHA256)
        _ = try ProviderHandoffDigest.parseSHA256(verifiedCanonicalContentDigest)
        for entry in importedEntries {
            guard
                !entry.entryID.isEmpty,
                !entry.destinationReference.objectID.isEmpty,
                !entry.destinationReference.integrityDigest.isEmpty
            else {
                throw LoggingHandoffStagingReceiptError.invalidReceipt
            }
            _ = try ProviderHandoffDigest.parseSHA256(
                entry.destinationProtectedContentDigest
            )
        }
    }

    private static func digest(
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigest: String,
        partKind: ProviderHandoffPartKindV1,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String,
        verifiedCanonicalContentDigest: String,
        importedEntries: [ImportedProtectedLoggingOptionV1]
    ) throws -> String {
        let unsigned = Self(
            schemaVersion: 1,
            handoffTokenID: handoffTokenID,
            handoffManifestID: handoffManifestID,
            handoffManifestDigest: handoffManifestDigest,
            partKind: partKind,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: payloadDescriptorDigestSHA256,
            verifiedCanonicalContentDigest: verifiedCanonicalContentDigest,
            importedEntries: importedEntries,
            receiptDigestSHA256: ""
        )
        return try ProviderHandoffDigest.domain(
            "container-handoff-logging-protected-staging-receipt-v1",
            projection: projection(unsigned, includeReceiptDigest: false)
        )
    }

    private static func projection(
        _ value: Self,
        includeReceiptDigest: Bool
    ) throws -> ProviderHandoffCanonicalValue {
        var fields: [ProviderHandoffCanonicalMapEntry] = [
            .init("bundleObjectID", .textString(value.bundleObjectID)),
            .init("handoffManifestDigest", try digestValue(value.handoffManifestDigest)),
            .init("handoffManifestID", .textString(value.handoffManifestID)),
            .init("handoffTokenID", .textString(value.handoffTokenID)),
            .init(
                "importedEntries",
                .array(
                    try value.importedEntries.map { entry in
                        .map([
                            .init("destinationIntegrityDigest", .textString(entry.destinationReference.integrityDigest)),
                            .init("destinationObjectID", .textString(entry.destinationReference.objectID)),
                            .init("destinationProtectedContentDigest", try digestValue(entry.destinationProtectedContentDigest)),
                            .init("entryID", .textString(entry.entryID)),
                            .init("referenceSchemaVersion", .unsigned(UInt64(entry.destinationReference.schemaVersion))),
                        ])
                    })),
            .init("partKind", .textString(value.partKind.rawValue)),
            .init("payloadDescriptorDigestSHA256", try digestValue(value.payloadDescriptorDigestSHA256)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("verifiedCanonicalContentDigest", try digestValue(value.verifiedCanonicalContentDigest)),
        ]
        if includeReceiptDigest {
            fields.append(
                .init("receiptDigestSHA256", try digestValue(value.receiptDigestSHA256))
            )
        }
        return .map(fields)
    }

    private static func exactMap(
        _ value: ProviderHandoffCanonicalValue,
        keys: Set<String>
    ) throws -> [String: ProviderHandoffCanonicalValue] {
        guard
            case .map(let entries) = value,
            Set(entries.map(\.key)) == keys,
            entries.count == keys.count
        else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }

    private static func text(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String {
        guard case .textString(let value)? = value else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        return value
    }

    private static func unsigned(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> UInt64 {
        guard case .unsigned(let value)? = value else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        return value
    }

    private static func digestText(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String {
        guard case .byteString(let value)? = value, value.count == 32 else {
            throw LoggingHandoffStagingReceiptError.invalidReceipt
        }
        return ProviderHandoffDigest.hex(value)
    }

    private static func digestValue(
        _ value: String
    ) throws -> ProviderHandoffCanonicalValue {
        .byteString(try ProviderHandoffDigest.parseSHA256(value))
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func constantTimeDigestEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard
            let lhs = try? ProviderHandoffDigest.parseSHA256(lhs),
            let rhs = try? ProviderHandoffDigest.parseSHA256(rhs)
        else {
            return false
        }
        return ProviderHandoffDigest.constantTimeEqual(lhs, rhs)
    }
}

enum LoggingHandoffStagingReceiptError: Error, Equatable, Sendable {
    case invalidReceipt
    case digestMismatch
    case commonRecordMismatch
}
