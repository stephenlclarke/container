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

enum LoggingHandoffTerminalAuditError: Error, Equatable, Sendable {
    case pendingProtectedEffectRemoval
    case nonTerminalWriter
    case nonTerminalReader
    case nonTerminalDetachedCleanup
}

enum LoggingHandoffTerminalAuditBuilder {
    static func build(
        containerID: String,
        snapshot: ContainerLogLifecycleLedgerSnapshotV1,
        historyStores: [LoggingHandoffHistoryStoreV1]
    ) throws -> LoggingTerminalAuditV1 {
        guard snapshot.pendingEffectRemovals.isEmpty else {
            throw LoggingHandoffTerminalAuditError.pendingProtectedEffectRemoval
        }

        var categories: [String: UInt64] = [:]
        var writerCount: UInt64 = 0
        for record in snapshot.writerOperations {
            let category: String
            switch record.result {
            case .candidateClosed:
                category = "writer.candidate-closed"
            case .activated(let activation):
                switch activation.state {
                case .closed, .tombstoned:
                    guard let disposition = activation.closeDisposition else {
                        throw LoggingHandoffTerminalAuditError.nonTerminalWriter
                    }
                    category =
                        "writer.\(activation.state.rawValue).\(disposition.rawValue)"
                case .active, .draining, .recoveryRequired:
                    throw LoggingHandoffTerminalAuditError.nonTerminalWriter
                }
            case .reserved, .startRecoveryRequired, .prepared,
                .candidateClosing, .candidateRecoveryRequired:
                throw LoggingHandoffTerminalAuditError.nonTerminalWriter
            }
            guard record.request.containerID == containerID else { continue }
            writerCount += 1
            categories[category, default: 0] += 1
        }

        var readerCount: UInt64 = 0
        for record in snapshot.readerOperations {
            let category: String
            switch record.result {
            case .candidateClosed:
                category = "reader.candidate-closed"
            case .activated(let session):
                switch session.state {
                case .closed, .tombstoned:
                    category = "reader.\(session.state.rawValue)"
                case .active, .closing, .recoveryRequired:
                    throw LoggingHandoffTerminalAuditError.nonTerminalReader
                }
            case .reserved, .openRecoveryRequired, .prepared,
                .candidateClosing, .candidateRecoveryRequired:
                throw LoggingHandoffTerminalAuditError.nonTerminalReader
            }
            guard record.request.containerID == containerID else { continue }
            readerCount += 1
            categories[category, default: 0] += 1
        }

        var cleanupCount: UInt64 = 0
        for cleanup in snapshot.detachedCleanups {
            let category: String
            switch cleanup.state {
            case .complete, .tombstoned:
                category = "detached-cleanup.\(cleanup.state.rawValue)"
            case .pending, .recoveryRequired:
                throw LoggingHandoffTerminalAuditError.nonTerminalDetachedCleanup
            }
            guard cleanup.containerID == containerID else { continue }
            cleanupCount += 1
            categories[category, default: 0] += 1
        }

        return try LoggingTerminalAuditV1(
            terminalWriterCount: writerCount,
            terminalReaderCount: readerCount,
            terminalDetachedCleanupCount: cleanupCount,
            terminalCategoryDigestSHA256: terminalCategoryDigest(
                containerID: containerID,
                categories: categories
            ),
            historyRetentionDigestSHA256: historyRetentionDigest(
                containerID: containerID,
                historyStores: historyStores
            )
        )
    }

    static func historyRetentionDigest(
        containerID: String,
        historyStores: [LoggingHandoffHistoryStoreV1]
    ) throws -> String {
        let ordered = historyStores.sorted {
            $0.storeID.utf8.lexicographicallyPrecedes($1.storeID.utf8)
        }
        guard ordered.map(\.storeID).count == Set(ordered.map(\.storeID)).count else {
            throw LoggingHandoffPayloadError.invalidContainer(containerID)
        }
        let stores = try ordered.map { store in
            ProviderHandoffCanonicalValue.map([
                .init("byteLength", .unsigned(store.byteLength)),
                .init(
                    "contentDigestSHA256",
                    try optionalDigest(store.contentDigestSHA256)
                ),
                .init("disposition", .textString(store.disposition.rawValue)),
                .init("formatVersion", .unsigned(UInt64(store.formatVersion))),
                .init("kind", .textString(store.kind.rawValue)),
                .init(
                    "maximumInternalSequence",
                    .unsigned(store.maximumInternalSequence)
                ),
                .init(
                    "providerExportDigestSHA256",
                    try optionalDigest(store.providerExportDigestSHA256)
                ),
                .init("rotationIndex", .unsigned(store.rotationIndex)),
                .init("sourceDeviceID", .optional(store.sourceDeviceID)),
                .init("sourceInode", .optional(store.sourceInode)),
                .init("storeID", .textString(store.storeID)),
                .init("terminalHistoryEpoch", .unsigned(store.terminalHistoryEpoch)),
            ])
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-logging-history-retention-v1",
            projection: .map([
                .init("containerID", .textString(containerID)),
                .init("stores", .array(stores)),
            ])
        )
    }

    private static func terminalCategoryDigest(
        containerID: String,
        categories: [String: UInt64]
    ) throws -> String {
        let ordered = categories.sorted {
            $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }.map {
            ProviderHandoffCanonicalValue.map([
                .init("category", .textString($0.key)),
                .init("count", .unsigned($0.value)),
            ])
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-logging-terminal-categories-v1",
            projection: .map([
                .init("categories", .array(ordered)),
                .init("containerID", .textString(containerID)),
            ])
        )
    }

    private static func optionalDigest(
        _ value: String?
    ) throws -> ProviderHandoffCanonicalValue {
        guard let value else { return .null }
        return .byteString(try ProviderHandoffDigest.parseSHA256(value))
    }
}
