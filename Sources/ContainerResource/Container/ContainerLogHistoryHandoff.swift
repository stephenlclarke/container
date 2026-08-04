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

import CryptoKit
import Foundation

public enum LogDriverHistoryHandoffError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case receiptMismatch
    case unsupported
}

private enum LogDriverHistoryHandoffValidation {
    static let maximumIdentifierBytes = 4_096
    static let maximumDigestBytes = 1_024

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIdentifierBytes
            && value.precomposedStringWithCanonicalMapping == value
    }

    static func digest(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumDigestBytes else {
            return false
        }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        let hex =
            components.count == 1
            ? components[0] : (components.last ?? "")
        return hex.count == 64
            && hex.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(character)
            }
    }

    static func canonicalDigest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Source-provider proof that one terminal provider-owned history set can be
/// considered for adoption by another authority. Provider generations remain
/// authority-local and are deliberately not compared with a destination
/// generation.
public struct LogDriverHistoryHandoffExportRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let tokenID: String
    public let manifestID: String
    public let containerID: String
    public let sourceStateRootUUID: String
    public let destinationStateRootUUID: String
    public let sourceLeaseGeneration: UInt64
    public let sourceProviderID: String
    public let sourceProviderGeneration: UInt64
    public let sourceContractDigest: String
    public let terminalHistoryDigestSHA256: String

    public init(
        tokenID: String,
        manifestID: String,
        containerID: String,
        sourceStateRootUUID: String,
        destinationStateRootUUID: String,
        sourceLeaseGeneration: UInt64,
        sourceProviderID: String,
        sourceProviderGeneration: UInt64,
        sourceContractDigest: String,
        terminalHistoryDigestSHA256: String
    ) throws {
        guard
            LogDriverHistoryHandoffValidation.identifier(tokenID),
            LogDriverHistoryHandoffValidation.identifier(manifestID),
            LogDriverHistoryHandoffValidation.identifier(containerID),
            LogDriverHistoryHandoffValidation.identifier(sourceStateRootUUID),
            LogDriverHistoryHandoffValidation.identifier(destinationStateRootUUID),
            sourceStateRootUUID != destinationStateRootUUID,
            sourceLeaseGeneration > 0,
            LogDriverHistoryHandoffValidation.identifier(sourceProviderID),
            sourceProviderGeneration > 0,
            LogDriverHistoryHandoffValidation.digest(sourceContractDigest),
            LogDriverHistoryHandoffValidation.digest(terminalHistoryDigestSHA256)
        else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history export identity is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.containerID = containerID
        self.sourceStateRootUUID = sourceStateRootUUID
        self.destinationStateRootUUID = destinationStateRootUUID
        self.sourceLeaseGeneration = sourceLeaseGeneration
        self.sourceProviderID = sourceProviderID
        self.sourceProviderGeneration = sourceProviderGeneration
        self.sourceContractDigest = sourceContractDigest
        self.terminalHistoryDigestSHA256 = terminalHistoryDigestSHA256
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history export schema")
        }
        try self.init(
            tokenID: values.decode(String.self, forKey: .tokenID),
            manifestID: values.decode(String.self, forKey: .manifestID),
            containerID: values.decode(String.self, forKey: .containerID),
            sourceStateRootUUID: values.decode(String.self, forKey: .sourceStateRootUUID),
            destinationStateRootUUID: values.decode(String.self, forKey: .destinationStateRootUUID),
            sourceLeaseGeneration: values.decode(UInt64.self, forKey: .sourceLeaseGeneration),
            sourceProviderID: values.decode(String.self, forKey: .sourceProviderID),
            sourceProviderGeneration: values.decode(UInt64.self, forKey: .sourceProviderGeneration),
            sourceContractDigest: values.decode(String.self, forKey: .sourceContractDigest),
            terminalHistoryDigestSHA256: values.decode(String.self, forKey: .terminalHistoryDigestSHA256)
        )
    }
}

public struct LogDriverHistoryHandoffExportReceiptV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    private struct DigestProjection: Codable {
        let schemaVersion: UInt32
        let request: LogDriverHistoryHandoffExportRequestV1
        let providerOutcomeDigestSHA256: String
    }

    public let schemaVersion: UInt32
    public let request: LogDriverHistoryHandoffExportRequestV1
    public let providerOutcomeDigestSHA256: String
    public let exportReceiptDigestSHA256: String

    public init(
        request: LogDriverHistoryHandoffExportRequestV1,
        providerOutcomeDigestSHA256: String
    ) throws {
        guard LogDriverHistoryHandoffValidation.digest(providerOutcomeDigestSHA256) else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history export outcome is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.request = request
        self.providerOutcomeDigestSHA256 = providerOutcomeDigestSHA256
        exportReceiptDigestSHA256 = try LogDriverHistoryHandoffValidation.canonicalDigest(
            DigestProjection(
                schemaVersion: Self.currentSchemaVersion,
                request: request,
                providerOutcomeDigestSHA256: providerOutcomeDigestSHA256
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history export receipt schema")
        }
        let request = try values.decode(LogDriverHistoryHandoffExportRequestV1.self, forKey: .request)
        let outcome = try values.decode(String.self, forKey: .providerOutcomeDigestSHA256)
        try self.init(request: request, providerOutcomeDigestSHA256: outcome)
        guard exportReceiptDigestSHA256 == (try values.decode(String.self, forKey: .exportReceiptDigestSHA256)) else {
            throw LogDriverHistoryHandoffError.receiptMismatch
        }
    }
}

/// Destination-provider preflight identity. It binds the source export to the
/// destination provider contract without assuming any ordering or equality
/// between the two authorities' provider-generation namespaces.
public struct LogDriverHistoryHandoffDestinationRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let exportReceipt: LogDriverHistoryHandoffExportReceiptV1
    public let manifestDigestSHA256: String
    public let destinationLeaseGeneration: UInt64
    public let destinationProviderID: String
    public let destinationProviderGeneration: UInt64
    public let destinationContractDigest: String

    public init(
        exportReceipt: LogDriverHistoryHandoffExportReceiptV1,
        manifestDigestSHA256: String,
        destinationLeaseGeneration: UInt64,
        destinationProviderID: String,
        destinationProviderGeneration: UInt64,
        destinationContractDigest: String
    ) throws {
        guard
            LogDriverHistoryHandoffValidation.digest(manifestDigestSHA256),
            destinationLeaseGeneration > 0,
            LogDriverHistoryHandoffValidation.identifier(destinationProviderID),
            destinationProviderGeneration > 0,
            LogDriverHistoryHandoffValidation.digest(destinationContractDigest)
        else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history destination identity is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.exportReceipt = exportReceipt
        self.manifestDigestSHA256 = manifestDigestSHA256
        self.destinationLeaseGeneration = destinationLeaseGeneration
        self.destinationProviderID = destinationProviderID
        self.destinationProviderGeneration = destinationProviderGeneration
        self.destinationContractDigest = destinationContractDigest
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history destination schema")
        }
        try self.init(
            exportReceipt: values.decode(LogDriverHistoryHandoffExportReceiptV1.self, forKey: .exportReceipt),
            manifestDigestSHA256: values.decode(String.self, forKey: .manifestDigestSHA256),
            destinationLeaseGeneration: values.decode(UInt64.self, forKey: .destinationLeaseGeneration),
            destinationProviderID: values.decode(String.self, forKey: .destinationProviderID),
            destinationProviderGeneration: values.decode(UInt64.self, forKey: .destinationProviderGeneration),
            destinationContractDigest: values.decode(String.self, forKey: .destinationContractDigest)
        )
    }
}

public struct LogDriverHistoryHandoffPromotionRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let destination: LogDriverHistoryHandoffDestinationRequestV1
    public let commitDigestSHA256: String
    public let handoffChainHeadDigestSHA256: String

    public init(
        destination: LogDriverHistoryHandoffDestinationRequestV1,
        commitDigestSHA256: String,
        handoffChainHeadDigestSHA256: String
    ) throws {
        guard
            LogDriverHistoryHandoffValidation.digest(commitDigestSHA256),
            LogDriverHistoryHandoffValidation.digest(handoffChainHeadDigestSHA256)
        else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history promotion authorization is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.destination = destination
        self.commitDigestSHA256 = commitDigestSHA256
        self.handoffChainHeadDigestSHA256 = handoffChainHeadDigestSHA256
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history promotion schema")
        }
        try self.init(
            destination: values.decode(LogDriverHistoryHandoffDestinationRequestV1.self, forKey: .destination),
            commitDigestSHA256: values.decode(String.self, forKey: .commitDigestSHA256),
            handoffChainHeadDigestSHA256: values.decode(String.self, forKey: .handoffChainHeadDigestSHA256)
        )
    }
}

public struct LogDriverHistoryHandoffPromotionReceiptV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    private struct DigestProjection: Codable {
        let schemaVersion: UInt32
        let request: LogDriverHistoryHandoffPromotionRequestV1
        let providerOutcomeDigestSHA256: String
    }

    public let schemaVersion: UInt32
    public let request: LogDriverHistoryHandoffPromotionRequestV1
    public let providerOutcomeDigestSHA256: String
    public let promotionReceiptDigestSHA256: String

    public init(
        request: LogDriverHistoryHandoffPromotionRequestV1,
        providerOutcomeDigestSHA256: String
    ) throws {
        guard LogDriverHistoryHandoffValidation.digest(providerOutcomeDigestSHA256) else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history promotion outcome is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.request = request
        self.providerOutcomeDigestSHA256 = providerOutcomeDigestSHA256
        promotionReceiptDigestSHA256 = try LogDriverHistoryHandoffValidation.canonicalDigest(
            DigestProjection(
                schemaVersion: Self.currentSchemaVersion,
                request: request,
                providerOutcomeDigestSHA256: providerOutcomeDigestSHA256
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history promotion receipt schema")
        }
        let request = try values.decode(LogDriverHistoryHandoffPromotionRequestV1.self, forKey: .request)
        let outcome = try values.decode(String.self, forKey: .providerOutcomeDigestSHA256)
        try self.init(request: request, providerOutcomeDigestSHA256: outcome)
        guard promotionReceiptDigestSHA256 == (try values.decode(String.self, forKey: .promotionReceiptDigestSHA256)) else {
            throw LogDriverHistoryHandoffError.receiptMismatch
        }
    }
}

public struct LogDriverHistoryHandoffActivationRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let promotionReceipt: LogDriverHistoryHandoffPromotionReceiptV1
    public let terminalOutcomeDigestSHA256: String

    public init(
        promotionReceipt: LogDriverHistoryHandoffPromotionReceiptV1,
        terminalOutcomeDigestSHA256: String
    ) throws {
        guard LogDriverHistoryHandoffValidation.digest(terminalOutcomeDigestSHA256) else {
            throw LogDriverHistoryHandoffError.invalidRequest(
                "provider history activation authorization is incomplete"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        self.promotionReceipt = promotionReceipt
        self.terminalOutcomeDigestSHA256 = terminalOutcomeDigestSHA256
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            throw LogDriverHistoryHandoffError.invalidRequest("unsupported history activation schema")
        }
        try self.init(
            promotionReceipt: values.decode(LogDriverHistoryHandoffPromotionReceiptV1.self, forKey: .promotionReceipt),
            terminalOutcomeDigestSHA256: values.decode(String.self, forKey: .terminalOutcomeDigestSHA256)
        )
    }
}
