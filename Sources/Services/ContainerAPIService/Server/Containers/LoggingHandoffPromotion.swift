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
import Foundation

enum LoggingHandoffPromotionError: Error, Equatable, Sendable {
    case activationNotAuthorized
    case destinationReceiptMismatch
    case promotionNotAuthorized
}

struct LoggingHandoffPromotionAuthorizationV1: Equatable, Sendable {
    let tokenID: String
    let manifestID: String
    let manifestDigest: String
    let commitDigestSHA256: String
    let handoffChainHeadDigestSHA256: String
    let destinationProviderFingerprint: String
    let destinationStateRootUUID: String
}

struct LoggingHandoffActivationAuthorizationV1: Equatable, Sendable {
    let tokenID: String
    let manifestID: String
    let manifestDigest: String
    let commitDigestSHA256: String
    let handoffChainHeadDigestSHA256: String
    let terminalOutcomeDigestSHA256: String
    let destinationProviderFingerprint: String
    let destinationStateRootUUID: String
}

/// Exact controller receipt that joins private logging promotion to the root
/// revision vector consumed by the signed Complete transition.
struct LoggingHandoffControllerPromotionReceiptV1: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let handoffTokenID: String
    let handoffManifestID: String
    let handoffManifestDigest: String
    let protectedStagingReceiptDigestSHA256: String
    let commitDigestSHA256: String
    let handoffChainHeadDigestSHA256: String
    let destinationProviderFingerprint: String
    let destinationStateRootUUID: String
    let privateStateDigestSHA256: String
    let historySetDigestSHA256: String
    let controllerRevision: UInt64
    let controllerStateDigestSHA256: String
    let promotionReceiptDigestSHA256: String

    init(
        authorization: LoggingHandoffPromotionAuthorizationV1,
        protectedStagingReceiptDigestSHA256: String,
        privateState: LoggingHandoffPrivateStagingStateV1,
        controllerRevision: UInt64,
        previousControllerStateDigestSHA256: String
    ) throws {
        guard controllerRevision > 0 else {
            throw LoggingHandoffPromotionError.destinationReceiptMismatch
        }
        _ = try ProviderHandoffDigest.parseSHA256(
            previousControllerStateDigestSHA256
        )
        let privateStateBytes = try privateState.canonicalBytes()
        let privateStateDigest = try ProviderHandoffDigest.domain(
            "container-handoff-logging-private-state-v1",
            projection: .byteString(privateStateBytes)
        )
        let historySetDigest = try Self.historySetDigest(privateState)
        schemaVersion = 1
        handoffTokenID = authorization.tokenID
        handoffManifestID = authorization.manifestID
        handoffManifestDigest = authorization.manifestDigest
        self.protectedStagingReceiptDigestSHA256 =
            protectedStagingReceiptDigestSHA256
        commitDigestSHA256 = authorization.commitDigestSHA256
        handoffChainHeadDigestSHA256 =
            authorization.handoffChainHeadDigestSHA256
        destinationProviderFingerprint =
            authorization.destinationProviderFingerprint
        destinationStateRootUUID = authorization.destinationStateRootUUID
        privateStateDigestSHA256 = privateStateDigest
        historySetDigestSHA256 = historySetDigest
        self.controllerRevision = controllerRevision
        controllerStateDigestSHA256 = try Self.controllerStateDigest(
            previousControllerStateDigestSHA256:
                previousControllerStateDigestSHA256,
            privateStateDigestSHA256: privateStateDigest,
            historySetDigestSHA256: historySetDigest,
            controllerRevision: controllerRevision
        )
        promotionReceiptDigestSHA256 = try Self.digest(
            handoffTokenID: authorization.tokenID,
            handoffManifestID: authorization.manifestID,
            handoffManifestDigest: authorization.manifestDigest,
            protectedStagingReceiptDigestSHA256:
                protectedStagingReceiptDigestSHA256,
            commitDigestSHA256: authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                authorization.handoffChainHeadDigestSHA256,
            destinationProviderFingerprint:
                authorization.destinationProviderFingerprint,
            destinationStateRootUUID: authorization.destinationStateRootUUID,
            privateStateDigestSHA256: privateStateDigest,
            historySetDigestSHA256: historySetDigest,
            controllerRevision: controllerRevision,
            controllerStateDigestSHA256: controllerStateDigestSHA256
        )
    }

    func validate(
        authorization: LoggingHandoffPromotionAuthorizationV1,
        protectedStagingReceiptDigestSHA256: String,
        privateState: LoggingHandoffPrivateStagingStateV1
    ) throws {
        let privateStateDigest = try ProviderHandoffDigest.domain(
            "container-handoff-logging-private-state-v1",
            projection: .byteString(try privateState.canonicalBytes())
        )
        let historySetDigest = try Self.historySetDigest(privateState)
        _ = try ProviderHandoffDigest.parseSHA256(controllerStateDigestSHA256)
        let expectedDigest = try Self.digest(
            handoffTokenID: authorization.tokenID,
            handoffManifestID: authorization.manifestID,
            handoffManifestDigest: authorization.manifestDigest,
            protectedStagingReceiptDigestSHA256:
                protectedStagingReceiptDigestSHA256,
            commitDigestSHA256: authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                authorization.handoffChainHeadDigestSHA256,
            destinationProviderFingerprint:
                authorization.destinationProviderFingerprint,
            destinationStateRootUUID: authorization.destinationStateRootUUID,
            privateStateDigestSHA256: privateStateDigest,
            historySetDigestSHA256: historySetDigest,
            controllerRevision: controllerRevision,
            controllerStateDigestSHA256: controllerStateDigestSHA256
        )
        guard
            schemaVersion == 1,
            handoffTokenID == authorization.tokenID,
            handoffManifestID == authorization.manifestID,
            handoffManifestDigest == authorization.manifestDigest,
            self.protectedStagingReceiptDigestSHA256
                == protectedStagingReceiptDigestSHA256,
            commitDigestSHA256 == authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256
                == authorization.handoffChainHeadDigestSHA256,
            destinationProviderFingerprint
                == authorization.destinationProviderFingerprint,
            destinationStateRootUUID == authorization.destinationStateRootUUID,
            privateStateDigestSHA256 == privateStateDigest,
            historySetDigestSHA256 == historySetDigest,
            promotionReceiptDigestSHA256 == expectedDigest
        else {
            throw LoggingHandoffPromotionError.destinationReceiptMismatch
        }
    }

    static func emptyControllerStateDigest() throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-logging-controller-empty-state-v1",
            projection: .map([
                .init("controllerRevision", .unsigned(0)),
                .init("schemaVersion", .unsigned(1)),
            ])
        )
    }

    func expectedControllerStateDigest(
        previousControllerStateDigestSHA256: String
    ) throws -> String {
        try Self.controllerStateDigest(
            previousControllerStateDigestSHA256:
                previousControllerStateDigestSHA256,
            privateStateDigestSHA256: privateStateDigestSHA256,
            historySetDigestSHA256: historySetDigestSHA256,
            controllerRevision: controllerRevision
        )
    }

    private static func historySetDigest(
        _ privateState: LoggingHandoffPrivateStagingStateV1
    ) throws -> String {
        var entries: [ProviderHandoffCanonicalValue] = []
        for container in privateState.containers {
            for history in container.histories {
                let historyEntries: [ProviderHandoffCanonicalMapEntry] = [
                    .init("byteLength", .unsigned(history.byteLength)),
                    .init("compressed", .boolean(history.compressed)),
                    .init("containerID", .textString(container.containerID)),
                    .init(
                        "contentDigest",
                        try history.contentDigestSHA256.map {
                            .byteString(try ProviderHandoffDigest.parseSHA256($0))
                        } ?? .null),
                    .init("disposition", .textString(history.disposition.rawValue)),
                    .init("entryID", .textString(history.entryID)),
                    .init("formatVersion", .unsigned(UInt64(history.formatVersion))),
                    .init("kind", .textString(history.kind.rawValue)),
                    .init("maximumInternalSequence", .unsigned(history.maximumInternalSequence)),
                    .init(
                        "providerExportDigest",
                        try history.providerExportDigestSHA256.map {
                            .byteString(try ProviderHandoffDigest.parseSHA256($0))
                        } ?? .null),
                    .init("rotationIndex", .unsigned(history.rotationIndex)),
                    .init("storeID", .textString(history.storeID)),
                    .init("terminalHistoryEpoch", .unsigned(history.terminalHistoryEpoch)),
                ]
                entries.append(.map(historyEntries))
            }
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-logging-promoted-history-set-v1",
            projection: .array(entries)
        )
    }

    private static func digest(
        handoffTokenID: String,
        handoffManifestID: String,
        handoffManifestDigest: String,
        protectedStagingReceiptDigestSHA256: String,
        commitDigestSHA256: String,
        handoffChainHeadDigestSHA256: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        privateStateDigestSHA256: String,
        historySetDigestSHA256: String,
        controllerRevision: UInt64,
        controllerStateDigestSHA256: String
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-logging-controller-promotion-receipt-v1",
            projection: .map([
                .init("commitDigest", .byteString(try ProviderHandoffDigest.parseSHA256(commitDigestSHA256))),
                .init("controllerRevision", .unsigned(controllerRevision)),
                .init("controllerStateDigest", .byteString(try ProviderHandoffDigest.parseSHA256(controllerStateDigestSHA256))),
                .init("destinationProviderFingerprint", .textString(destinationProviderFingerprint)),
                .init("destinationStateRootUUID", .textString(destinationStateRootUUID)),
                .init("handoffChainHeadDigest", .byteString(try ProviderHandoffDigest.parseSHA256(handoffChainHeadDigestSHA256))),
                .init("handoffManifestDigest", .byteString(try ProviderHandoffDigest.parseSHA256(handoffManifestDigest))),
                .init("handoffManifestID", .textString(handoffManifestID)),
                .init("handoffTokenID", .textString(handoffTokenID)),
                .init("historySetDigest", .byteString(try ProviderHandoffDigest.parseSHA256(historySetDigestSHA256))),
                .init("privateStateDigest", .byteString(try ProviderHandoffDigest.parseSHA256(privateStateDigestSHA256))),
                .init("protectedStagingReceiptDigest", .byteString(try ProviderHandoffDigest.parseSHA256(protectedStagingReceiptDigestSHA256))),
                .init("schemaVersion", .unsigned(1)),
            ])
        )
    }

    private static func controllerStateDigest(
        previousControllerStateDigestSHA256: String,
        privateStateDigestSHA256: String,
        historySetDigestSHA256: String,
        controllerRevision: UInt64
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-logging-controller-state-v1",
            projection: .map([
                .init("controllerRevision", .unsigned(controllerRevision)),
                .init("historySetDigest", .byteString(try ProviderHandoffDigest.parseSHA256(historySetDigestSHA256))),
                .init("privateStateDigest", .byteString(try ProviderHandoffDigest.parseSHA256(privateStateDigestSHA256))),
                .init("previousControllerStateDigest", .byteString(try ProviderHandoffDigest.parseSHA256(previousControllerStateDigestSHA256))),
                .init("schemaVersion", .unsigned(1)),
            ])
        )
    }
}

/// Controller-specific destination transaction boundary. Implementations must
/// make `promoteLogging` and `activateLogging` exact-replay idempotent and
/// durable before returning.
protocol LoggingHandoffDestinationReconciling: Sendable {
    func promoteLogging(
        privateState: LoggingHandoffPrivateStagingStateV1,
        payload: LoggingHandoffDecodedPayloadV1,
        authorization: LoggingHandoffPromotionAuthorizationV1,
        protectedReceipt: LoggingProtectedOptionStagingReceiptV1
    ) async throws -> LoggingHandoffControllerPromotionReceiptV1

    func activateLogging(
        privateState: LoggingHandoffPrivateStagingStateV1,
        payload: LoggingHandoffDecodedPayloadV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws
}
