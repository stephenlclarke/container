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
import ContainerLoggingStorage
import ContainerResource
import CryptoKit
import Darwin
import Foundation

enum LoggingHandoffDestinationReconcilerError: Error, Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case createRoot
        case openRoot
        case openLock
        case lock
        case openKey
        case openFile
        case read
        case write
        case synchronizeFile
        case publishFile
        case synchronizeDirectory
    }

    case activationMismatch
    case boundsExceeded
    case historyMismatch(String)
    case integrityMismatch
    case invalidEncoding
    case invalidMetadata
    case invalidRoot
    case promotionCollision
    case providerHistoryPromoterUnavailable
    case revisionOverflow
    case stateRevisionMismatch
    case ioFailure(Operation, Int32)
}

struct LoggingHandoffPromotedHistorySegmentV1: Equatable, Sendable {
    let entryID: String
    let storeID: String
    let kind: LoggingHandoffHistoryKindV1
    let rotationIndex: UInt64
    let compressed: Bool
    let terminalHistoryEpoch: UInt64
    let maximumInternalSequence: UInt64
    let contentDigestSHA256: String
    let bytes: Data

    var portableChunk: ProviderHandoffPortableLoggingHistoryChunkV1? {
        ProviderHandoffPortableLoggingPayloadCodec
            .parseHistoryChunkStoreID(storeID)
    }

    var destinationFileName: String {
        let activeName: String
        switch kind {
        case .dockerJSONFile:
            activeName = ContainerResource.Bundle.jsonFileLogName
        case .nativeLocal:
            activeName = ContainerResource.Bundle.nativeLocalLogName
        case .dualCache:
            activeName = ContainerResource.Bundle.nativeLogCacheName
        case .legacyLocalV1, .providerOwned:
            preconditionFailure("non-local history cannot name a local segment")
        }
        guard portableChunk == nil, rotationIndex > 0 else {
            return activeName
        }
        return "\(activeName).\(rotationIndex)\(compressed ? ".gz" : "")"
    }
}

/// Container-controller boundary used while the destination root is hidden by
/// `destinationReconciling`. Implementations durably adopt the exact logging
/// configuration and immutable history bytes, but must not start a writer,
/// reader, provider session, or expose the destination through public indexes.
protocol LoggingHandoffContainerPromoting: Sendable {
    func promoteContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffPromotedHistorySegmentV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws

    func activateContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws
}

/// Effectful provider-owned history import begins only after the signed commit.
/// Calls are keyed by immutable handoff identity and must be exact-replay
/// idempotent; activation may enable sessions only after signed Complete.
protocol LoggingHandoffProviderHistoryPromoting: Sendable {
    func promoteProviderHistory(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffHistoryStoreV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws

    func activateProviderHistory(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffHistoryStoreV1],
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws
}

/// Durable roll-forward participant for the logging controller.
///
/// Physical history objects are content-addressed and published privately
/// before controller adoption. The controller revision advances only after all
/// local and provider-owned effects are durable. Response loss therefore
/// replays the same adapters and returns the same receipt without allocating a
/// second reference, history object, writer, or provider session.
actor LoggingHandoffDestinationReconciler: LoggingHandoffDestinationReconciling {
    private struct Transaction: Codable, Equatable, Sendable {
        let promotionReceipt: LoggingHandoffControllerPromotionReceiptV1
        let containerIDs: [String]
        let historyObjectDigests: [String]
    }

    private struct StoreState: Codable, Equatable, Sendable {
        var schemaVersion: UInt32 = 1
        var storeRevision: UInt64 = 0
        var controllerRevision: UInt64 = 0
        var transactions: [Transaction] = []
    }

    private struct PreparedPromotion: Sendable {
        let localByContainer: [String: [LoggingHandoffPromotedHistorySegmentV1]]
        let providerByContainer: [String: [LoggingHandoffHistoryStoreV1]]
        let historyObjectDigests: [String]
    }

    static let stateFileName = "logging-handoff-promotions.bin"
    static let lockFileName = ".logging-handoff-promotions.lock"
    static let keyFileName = ".logging-handoff-promotions.key"
    static let historyObjectPrefix = "logging-handoff-history-"
    static let historyObjectSuffix = ".bin"

    private static let stateMagic = Data("CLOGHPR1".utf8)
    private static let stateSchemaVersion: UInt32 = 1
    private static let maximumStateBytes = 16 * 1024 * 1024
    private static let maximumHistoryObjects = 4_096
    private static let keyByteCount = 32
    private static let authenticationDomain = Data(
        "container.logging.handoff.promotion-state.v1\u{0}".utf8
    )
    private static let fixedEnvelopeBytes =
        stateMagic.count + MemoryLayout<UInt32>.size
        + MemoryLayout<UInt64>.size + SHA256.byteCount

    private let rootDescriptor: Int32
    private let lockDescriptor: Int32
    private let keyData: Data
    private let containerPromoter: any LoggingHandoffContainerPromoting
    private let providerPromoter: (any LoggingHandoffProviderHistoryPromoting)?

    init(
        rootURL: URL,
        containerPromoter: any LoggingHandoffContainerPromoting,
        providerPromoter: (any LoggingHandoffProviderHistoryPromoting)? = nil
    ) throws {
        let rootDescriptor = try Self.openRoot(rootURL)
        var lockDescriptor: Int32 = -1
        do {
            lockDescriptor = try Self.openManagedFile(
                rootDescriptor: rootDescriptor,
                name: Self.lockFileName,
                flags: O_RDWR | O_CREAT,
                mode: mode_t(0o600),
                operation: .openLock
            )
            let keyData = try Self.withLock(lockDescriptor) {
                try Self.loadOrCreateKey(rootDescriptor: rootDescriptor)
            }
            self.rootDescriptor = rootDescriptor
            self.lockDescriptor = lockDescriptor
            self.keyData = keyData
            self.containerPromoter = containerPromoter
            self.providerPromoter = providerPromoter
        } catch {
            if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(lockDescriptor)
        Darwin.close(rootDescriptor)
    }

    func promoteLogging(
        privateState: LoggingHandoffPrivateStagingStateV1,
        payload: LoggingHandoffDecodedPayloadV1,
        authorization: LoggingHandoffPromotionAuthorizationV1,
        protectedReceipt: LoggingProtectedOptionStagingReceiptV1
    ) async throws -> LoggingHandoffControllerPromotionReceiptV1 {
        try privateState.validate(receipt: protectedReceipt)
        try Self.validateIdentity(privateState, authorization: authorization)
        let prepared = try preparePromotion(
            privateState: privateState,
            payload: payload
        )

        if let existing = try transaction(
            tokenID: authorization.tokenID,
            manifestID: authorization.manifestID
        ) {
            try existing.promotionReceipt.validate(
                authorization: authorization,
                protectedStagingReceiptDigestSHA256:
                    protectedReceipt.receiptDigestSHA256,
                privateState: privateState
            )
            try Self.validatePrepared(prepared, transaction: existing)
            try await promoteEffects(
                privateState: privateState,
                prepared: prepared,
                authorization: authorization
            )
            return existing.promotionReceipt
        }

        let snapshot = try loadState()
        let (nextControllerRevision, controllerOverflow) =
            snapshot.controllerRevision.addingReportingOverflow(1)
        guard !controllerOverflow else {
            throw LoggingHandoffDestinationReconcilerError.revisionOverflow
        }
        let receipt = try LoggingHandoffControllerPromotionReceiptV1(
            authorization: authorization,
            protectedStagingReceiptDigestSHA256:
                protectedReceipt.receiptDigestSHA256,
            privateState: privateState,
            controllerRevision: nextControllerRevision,
            previousControllerStateDigestSHA256:
                try Self.currentControllerStateDigest(snapshot)
        )

        try await promoteEffects(
            privateState: privateState,
            prepared: prepared,
            authorization: authorization
        )
        let proposed = Transaction(
            promotionReceipt: receipt,
            containerIDs: privateState.containers.map(\.containerID),
            historyObjectDigests: prepared.historyObjectDigests
        )
        do {
            return try append(
                proposed,
                expectedStoreRevision: snapshot.storeRevision,
                expectedControllerRevision: snapshot.controllerRevision
            ).promotionReceipt
        } catch LoggingHandoffDestinationReconcilerError.stateRevisionMismatch {
            guard
                let existing = try transaction(
                    tokenID: authorization.tokenID,
                    manifestID: authorization.manifestID
                ), existing == proposed
            else {
                throw LoggingHandoffDestinationReconcilerError
                    .stateRevisionMismatch
            }
            return existing.promotionReceipt
        }
    }

    func activateLogging(
        privateState: LoggingHandoffPrivateStagingStateV1,
        payload: LoggingHandoffDecodedPayloadV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws {
        let promotionAuthorization = LoggingHandoffPromotionAuthorizationV1(
            tokenID: authorization.tokenID,
            manifestID: authorization.manifestID,
            manifestDigest: authorization.manifestDigest,
            commitDigestSHA256: authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                authorization.handoffChainHeadDigestSHA256,
            destinationProviderFingerprint:
                authorization.destinationProviderFingerprint,
            destinationStateRootUUID: authorization.destinationStateRootUUID
        )
        try Self.validateIdentity(
            privateState,
            authorization: promotionAuthorization
        )
        let existing = try transaction(
            tokenID: authorization.tokenID,
            manifestID: authorization.manifestID
        )
        guard
            let existing,
            existing.promotionReceipt == promotionReceipt,
            existing.containerIDs == privateState.containers.map(\.containerID)
        else {
            throw LoggingHandoffDestinationReconcilerError.activationMismatch
        }
        let prepared = try preparePromotion(
            privateState: privateState,
            payload: payload
        )
        try Self.validatePrepared(prepared, transaction: existing)

        for container in privateState.containers {
            try await containerPromoter.activateContainerLogging(
                container: container,
                promotionReceipt: promotionReceipt,
                authorization: authorization
            )
            if !prepared.providerByContainer[
                container.containerID,
                default: []
            ].isEmpty {
                guard let providerPromoter else {
                    throw LoggingHandoffDestinationReconcilerError
                        .providerHistoryPromoterUnavailable
                }
                try await providerPromoter.activateProviderHistory(
                    container: container,
                    history: prepared.providerByContainer[
                        container.containerID,
                        default: []
                    ],
                    promotionReceipt: promotionReceipt,
                    authorization: authorization
                )
            }
        }
    }

    func controllerRevision() throws -> ProviderHandoffControllerRevisionV1 {
        let state = try loadState()
        return ProviderHandoffControllerRevisionV1(
            controllerID: "logging",
            revision: state.controllerRevision,
            canonicalStateDigestSHA256:
                try Self.currentControllerStateDigest(state)
        )
    }

    private func promoteEffects(
        privateState: LoggingHandoffPrivateStagingStateV1,
        prepared: PreparedPromotion,
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws {
        for container in privateState.containers {
            try await containerPromoter.promoteContainerLogging(
                container: container,
                history: prepared.localByContainer[
                    container.containerID,
                    default: []
                ],
                authorization: authorization
            )
            let providerHistory = prepared.providerByContainer[
                container.containerID,
                default: []
            ]
            if !providerHistory.isEmpty {
                guard let providerPromoter else {
                    throw LoggingHandoffDestinationReconcilerError
                        .providerHistoryPromoterUnavailable
                }
                try await providerPromoter.promoteProviderHistory(
                    container: container,
                    history: providerHistory,
                    authorization: authorization
                )
            }
        }
    }

    private func preparePromotion(
        privateState: LoggingHandoffPrivateStagingStateV1,
        payload: LoggingHandoffDecodedPayloadV1
    ) throws -> PreparedPromotion {
        var localByContainer: [String: [LoggingHandoffPromotedHistorySegmentV1]] = [:]
        var providerByContainer: [String: [LoggingHandoffHistoryStoreV1]] = [:]
        var objectDigests = Set<String>()

        for container in privateState.containers {
            for staged in container.histories {
                guard
                    let history = payload.historyStores[staged.entryID],
                    staged.matches(history)
                else {
                    throw
                        LoggingHandoffDestinationReconcilerError
                        .historyMismatch(staged.entryID)
                }
                switch history.disposition {
                case .importVerified:
                    guard let digest = history.contentDigestSHA256 else {
                        throw
                            LoggingHandoffDestinationReconcilerError
                            .historyMismatch(staged.entryID)
                    }
                    let bytes = try payload.withHistoryBytes(
                        entryID: staged.entryID
                    ) { bytes in
                        try Self.validateLocalHistory(history, bytes: bytes)
                        try publishHistoryObject(bytes, digest: digest)
                        return bytes
                    }
                    objectDigests.insert(digest)
                    localByContainer[container.containerID, default: []]
                        .append(
                            LoggingHandoffPromotedHistorySegmentV1(
                                entryID: staged.entryID,
                                storeID: history.storeID,
                                kind: history.kind,
                                rotationIndex: history.rotationIndex,
                                compressed: history.compressed,
                                terminalHistoryEpoch: history.terminalHistoryEpoch,
                                maximumInternalSequence:
                                    history.maximumInternalSequence,
                                contentDigestSHA256: digest,
                                bytes: bytes
                            ))
                case .providerExportVerified:
                    guard history.kind == .providerOwned else {
                        throw
                            LoggingHandoffDestinationReconcilerError
                            .historyMismatch(staged.entryID)
                    }
                    providerByContainer[container.containerID, default: []]
                        .append(history)
                case .empty:
                    break
                case .retainOffline, .explicitResolutionRequired:
                    throw
                        LoggingHandoffDestinationReconcilerError
                        .historyMismatch(staged.entryID)
                }
            }
            localByContainer[container.containerID]?.sort {
                if $0.kind != $1.kind {
                    return $0.kind.rawValue.utf8.lexicographicallyPrecedes(
                        $1.kind.rawValue.utf8
                    )
                }
                return $0.rotationIndex > $1.rotationIndex
            }
            providerByContainer[container.containerID]?.sort {
                $0.storeID.utf8.lexicographicallyPrecedes($1.storeID.utf8)
            }
        }
        guard objectDigests.count <= Self.maximumHistoryObjects else {
            throw LoggingHandoffDestinationReconcilerError.boundsExceeded
        }
        return PreparedPromotion(
            localByContainer: localByContainer,
            providerByContainer: providerByContainer,
            historyObjectDigests: objectDigests.sorted()
        )
    }

    private static func validateLocalHistory(
        _ history: LoggingHandoffHistoryStoreV1,
        bytes: Data
    ) throws {
        switch history.kind {
        case .dockerJSONFile:
            _ = try DockerJSONFileHandoffSegmentValidator.inspect(
                bytes,
                compressed: history.compressed
            )
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
                    LoggingHandoffDestinationReconcilerError
                    .historyMismatch(history.storeID)
            }
        case .legacyLocalV1, .providerOwned:
            throw
                LoggingHandoffDestinationReconcilerError
                .historyMismatch(history.storeID)
        }
    }

    private static func validateIdentity(
        _ privateState: LoggingHandoffPrivateStagingStateV1,
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) throws {
        guard
            privateState.handoffTokenID == authorization.tokenID,
            privateState.handoffManifestID == authorization.manifestID,
            privateState.handoffManifestDigest == authorization.manifestDigest
        else {
            throw LoggingHandoffDestinationReconcilerError.promotionCollision
        }
    }

    private static func validatePrepared(
        _ prepared: PreparedPromotion,
        transaction: Transaction
    ) throws {
        guard
            prepared.historyObjectDigests
                == transaction.historyObjectDigests
        else {
            throw LoggingHandoffDestinationReconcilerError.promotionCollision
        }
    }

    private func transaction(
        tokenID: String,
        manifestID: String
    ) throws -> Transaction? {
        let state = try loadState()
        let tokenMatches = state.transactions.filter {
            $0.promotionReceipt.handoffTokenID == tokenID
        }
        guard
            tokenMatches.allSatisfy({
                $0.promotionReceipt.handoffManifestID == manifestID
            })
        else {
            throw LoggingHandoffDestinationReconcilerError.promotionCollision
        }
        return tokenMatches.first
    }

    private func append(
        _ transaction: Transaction,
        expectedStoreRevision: UInt64,
        expectedControllerRevision: UInt64
    ) throws -> Transaction {
        try Self.withLock(lockDescriptor) {
            var state = try Self.loadState(
                rootDescriptor: rootDescriptor,
                keyData: keyData
            )
            guard
                state.storeRevision == expectedStoreRevision,
                state.controllerRevision == expectedControllerRevision
            else {
                throw LoggingHandoffDestinationReconcilerError
                    .stateRevisionMismatch
            }
            if let existing = state.transactions.first(where: {
                $0.promotionReceipt.handoffTokenID
                    == transaction.promotionReceipt.handoffTokenID
            }) {
                guard existing == transaction else {
                    throw LoggingHandoffDestinationReconcilerError
                        .promotionCollision
                }
                return existing
            }
            let (nextStoreRevision, storeOverflow) =
                state.storeRevision.addingReportingOverflow(1)
            let (nextControllerRevision, controllerOverflow) =
                state.controllerRevision.addingReportingOverflow(1)
            guard !storeOverflow, !controllerOverflow else {
                throw LoggingHandoffDestinationReconcilerError.revisionOverflow
            }
            guard
                transaction.promotionReceipt.controllerRevision
                    == nextControllerRevision,
                transaction.promotionReceipt.controllerStateDigestSHA256
                    == (try transaction.promotionReceipt
                        .expectedControllerStateDigest(
                            previousControllerStateDigestSHA256:
                                try Self.currentControllerStateDigest(state)
                        ))
            else {
                throw LoggingHandoffDestinationReconcilerError
                    .stateRevisionMismatch
            }
            state.storeRevision = nextStoreRevision
            state.controllerRevision = nextControllerRevision
            state.transactions.append(transaction)
            state.transactions.sort {
                $0.promotionReceipt.handoffTokenID.utf8
                    .lexicographicallyPrecedes(
                        $1.promotionReceipt.handoffTokenID.utf8
                    )
            }
            try Self.persistState(
                state,
                rootDescriptor: rootDescriptor,
                keyData: keyData
            )
            return transaction
        }
    }

    private func loadState() throws -> StoreState {
        try Self.withLock(lockDescriptor) {
            try Self.loadState(
                rootDescriptor: rootDescriptor,
                keyData: keyData
            )
        }
    }

    private func publishHistoryObject(_ bytes: Data, digest: String) throws {
        _ = try ProviderHandoffDigest.parseSHA256(digest)
        guard
            bytes.count
                <= LoggingHandoffHistoryStoreV1
                .maximumStoredBytesPerSegment,
            ProviderHandoffDigest.sha256(bytes) == digest
        else {
            throw LoggingHandoffDestinationReconcilerError.integrityMismatch
        }
        let target = Self.historyObjectName(digest)
        try Self.withLock(lockDescriptor) {
            do {
                let existing = try Self.readFile(
                    rootDescriptor: rootDescriptor,
                    name: target,
                    maximumBytes: LoggingHandoffHistoryStoreV1
                        .maximumStoredBytesPerSegment
                )
                guard
                    existing == bytes,
                    ProviderHandoffDigest.sha256(existing) == digest
                else {
                    throw LoggingHandoffDestinationReconcilerError
                        .integrityMismatch
                }
                return
            } catch LoggingHandoffDestinationReconcilerError
                .ioFailure(.openFile, ENOENT)
            {
                // Publish below.
            }
            try Self.publishImmutable(
                bytes,
                target: target,
                rootDescriptor: rootDescriptor
            )
        }
    }

    private func loadHistoryObject(_ digest: String) throws -> Data {
        let bytes = try Self.withLock(lockDescriptor) {
            try Self.readFile(
                rootDescriptor: rootDescriptor,
                name: Self.historyObjectName(digest),
                maximumBytes: LoggingHandoffHistoryStoreV1
                    .maximumStoredBytesPerSegment
            )
        }
        guard ProviderHandoffDigest.sha256(bytes) == digest else {
            throw LoggingHandoffDestinationReconcilerError.integrityMismatch
        }
        return bytes
    }

    private static func loadState(
        rootDescriptor: Int32,
        keyData: Data
    ) throws -> StoreState {
        let encoded: Data
        do {
            encoded = try readFile(
                rootDescriptor: rootDescriptor,
                name: stateFileName,
                maximumBytes: fixedEnvelopeBytes + maximumStateBytes
            )
        } catch LoggingHandoffDestinationReconcilerError
            .ioFailure(.openFile, ENOENT)
        {
            return StoreState()
        }
        var reader = PromotionDataReader(data: encoded)
        guard
            try reader.read(count: stateMagic.count) == stateMagic,
            try reader.readUInt32() == stateSchemaVersion,
            let length = Int(exactly: try reader.readUInt64()),
            length <= maximumStateBytes
        else {
            throw LoggingHandoffDestinationReconcilerError.invalidEncoding
        }
        let canonical = try reader.read(count: length)
        let authenticationCode = try reader.read(count: SHA256.byteCount)
        guard
            reader.isAtEnd,
            HMAC<SHA256>.isValidAuthenticationCode(
                authenticationCode,
                authenticating: authenticatedState(canonical),
                using: SymmetricKey(data: keyData)
            )
        else {
            throw LoggingHandoffDestinationReconcilerError.integrityMismatch
        }
        let state: StoreState
        do {
            state = try JSONDecoder().decode(StoreState.self, from: canonical)
        } catch {
            throw LoggingHandoffDestinationReconcilerError.invalidEncoding
        }
        guard
            state.schemaVersion == 1,
            state.storeRevision == state.controllerRevision,
            state.controllerRevision
                == UInt64(state.transactions.count),
            state.transactions.map({
                $0.promotionReceipt.handoffTokenID
            })
                == state.transactions.map({
                    $0.promotionReceipt.handoffTokenID
                }).sorted(),
            Set(
                state.transactions.map {
                    $0.promotionReceipt.handoffTokenID
                }
            ).count == state.transactions.count,
            try validateControllerStateChain(state),
            try canonicalState(state) == canonical
        else {
            throw LoggingHandoffDestinationReconcilerError.invalidEncoding
        }
        return state
    }

    private static func validateControllerStateChain(
        _ state: StoreState
    ) throws -> Bool {
        var digest =
            try LoggingHandoffControllerPromotionReceiptV1
            .emptyControllerStateDigest()
        for (offset, transaction) in state.transactions.sorted(by: {
            $0.promotionReceipt.controllerRevision
                < $1.promotionReceipt.controllerRevision
        }).enumerated() {
            guard
                let revision = UInt64(exactly: offset + 1),
                transaction.promotionReceipt.controllerRevision == revision
            else {
                return false
            }
            digest = try transaction.promotionReceipt
                .expectedControllerStateDigest(
                    previousControllerStateDigestSHA256: digest
                )
            guard
                transaction.promotionReceipt.controllerStateDigestSHA256
                    == digest
            else {
                return false
            }
        }
        return true
    }

    private static func currentControllerStateDigest(
        _ state: StoreState
    ) throws -> String {
        guard
            let latest = state.transactions.max(by: {
                $0.promotionReceipt.controllerRevision
                    < $1.promotionReceipt.controllerRevision
            })
        else {
            return
                try LoggingHandoffControllerPromotionReceiptV1
                .emptyControllerStateDigest()
        }
        return latest.promotionReceipt.controllerStateDigestSHA256
    }

    private static func persistState(
        _ state: StoreState,
        rootDescriptor: Int32,
        keyData: Data
    ) throws {
        let canonical = try canonicalState(state)
        guard canonical.count <= maximumStateBytes else {
            throw LoggingHandoffDestinationReconcilerError.boundsExceeded
        }
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: authenticatedState(canonical),
            using: SymmetricKey(data: keyData)
        )
        var encoded = Data()
        encoded.append(stateMagic)
        appendBigEndian(stateSchemaVersion, to: &encoded)
        appendBigEndian(UInt64(canonical.count), to: &encoded)
        encoded.append(canonical)
        encoded.append(contentsOf: authenticationCode)
        try publishReplacing(
            encoded,
            target: stateFileName,
            rootDescriptor: rootDescriptor
        )
    }

    private static func canonicalState(_ state: StoreState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state)
    }

    private static func authenticatedState(_ canonical: Data) -> Data {
        var result = Data()
        result.append(authenticationDomain)
        appendBigEndian(UInt64(canonical.count), to: &result)
        result.append(canonical)
        return result
    }

    private static func historyObjectName(_ digest: String) -> String {
        "\(historyObjectPrefix)\(digest)\(historyObjectSuffix)"
    }

    private static func openRoot(_ rootURL: URL) throws -> Int32 {
        guard
            rootURL.isFileURL,
            rootURL.path.hasPrefix("/"),
            !rootURL.path.utf8.contains(0)
        else {
            throw LoggingHandoffDestinationReconcilerError.invalidRoot
        }
        let created: Bool
        if rootURL.path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .createRoot,
                errno
            )
        }
        let descriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .openRoot,
                errno
            )
        }
        do {
            try validateDirectory(descriptor)
            if created {
                guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw LoggingHandoffDestinationReconcilerError.ioFailure(
                        .createRoot,
                        errno
                    )
                }
                try synchronizeDirectory(descriptor)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_mode & mode_t(0o077) == 0
        else {
            throw LoggingHandoffDestinationReconcilerError.invalidMetadata
        }
    }

    private static func loadOrCreateKey(rootDescriptor: Int32) throws -> Data {
        do {
            return try readFile(
                rootDescriptor: rootDescriptor,
                name: keyFileName,
                maximumBytes: keyByteCount
            )
        } catch LoggingHandoffDestinationReconcilerError
            .ioFailure(.openFile, ENOENT)
        {
            let key = secureRandomBytes(count: keyByteCount)
            try publishImmutable(
                key,
                target: keyFileName,
                rootDescriptor: rootDescriptor
            )
            return try readFile(
                rootDescriptor: rootDescriptor,
                name: keyFileName,
                maximumBytes: keyByteCount
            )
        }
    }

    private static func secureRandomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func openManagedFile(
        rootDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: mode_t,
        operation: LoggingHandoffDestinationReconcilerError.Operation
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                flags | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
        }
        guard descriptor >= 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                operation,
                errno
            )
        }
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            metadata.st_mode & mode_t(0o077) == 0
        else {
            Darwin.close(descriptor)
            throw LoggingHandoffDestinationReconcilerError.invalidMetadata
        }
        return descriptor
    }

    private static func readFile(
        rootDescriptor: Int32,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = try openManagedFile(
            rootDescriptor: rootDescriptor,
            name: name,
            flags: O_RDONLY,
            mode: 0,
            operation: .openFile
        )
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_size >= 0,
            metadata.st_size <= off_t(maximumBytes)
        else {
            throw LoggingHandoffDestinationReconcilerError.boundsExceeded
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        let byteCount = data.count
        while offset < byteCount {
            let result = data.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw LoggingHandoffDestinationReconcilerError.ioFailure(
                    .read,
                    result == 0 ? EIO : errno
                )
            }
            offset += result
        }
        return data
    }

    private static func publishImmutable(
        _ data: Data,
        target: String,
        rootDescriptor: Int32
    ) throws {
        let temporary = ".logging-handoff-promotion.\(UUID().uuidString.lowercased()).tmp"
        let descriptor = try openManagedFile(
            rootDescriptor: rootDescriptor,
            name: temporary,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            mode: mode_t(0o600),
            operation: .openFile
        )
        var needsClose = true
        var needsRemoval = true
        defer {
            if needsClose { Darwin.close(descriptor) }
            if needsRemoval {
                temporary.withCString { _ = Darwin.unlinkat(rootDescriptor, $0, 0) }
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .synchronizeFile,
                errno
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            needsClose = false
            throw LoggingHandoffDestinationReconcilerError.ioFailure(.write, errno)
        }
        needsClose = false
        let result = temporary.withCString { source in
            target.withCString { destination in
                Darwin.renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .publishFile,
                errno
            )
        }
        needsRemoval = false
        try synchronizeDirectory(rootDescriptor)
    }

    private static func publishReplacing(
        _ data: Data,
        target: String,
        rootDescriptor: Int32
    ) throws {
        let temporary = ".logging-handoff-state.\(UUID().uuidString.lowercased()).tmp"
        let descriptor = try openManagedFile(
            rootDescriptor: rootDescriptor,
            name: temporary,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            mode: mode_t(0o600),
            operation: .openFile
        )
        var needsClose = true
        var needsRemoval = true
        defer {
            if needsClose { Darwin.close(descriptor) }
            if needsRemoval {
                temporary.withCString { _ = Darwin.unlinkat(rootDescriptor, $0, 0) }
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .synchronizeFile,
                errno
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            needsClose = false
            throw LoggingHandoffDestinationReconcilerError.ioFailure(.write, errno)
        }
        needsClose = false
        let result = temporary.withCString { source in
            target.withCString { destination in
                Darwin.renameat(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination
                )
            }
        }
        guard result == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .publishFile,
                errno
            )
        }
        needsRemoval = false
        try synchronizeDirectory(rootDescriptor)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw LoggingHandoffDestinationReconcilerError.ioFailure(
                    .write,
                    result == 0 ? EIO : errno
                )
            }
            offset += result
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(
                .synchronizeDirectory,
                errno
            )
        }
    }

    private static func withLock<Result>(
        _ descriptor: Int32,
        _ body: () throws -> Result
    ) throws -> Result {
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LoggingHandoffDestinationReconcilerError.ioFailure(.lock, errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

private struct PromotionDataReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw LoggingHandoffDestinationReconcilerError.invalidEncoding
        }
        let end = offset + count
        defer { offset = end }
        return Data(data[offset..<end])
    }

    mutating func readUInt32() throws -> UInt32 {
        try integer()
    }

    mutating func readUInt64() throws -> UInt64 {
        try integer()
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let bytes = try read(count: MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
