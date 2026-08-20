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

/// Durable Docker-visible lifecycle state retained across authority restarts.
public struct ContainerLifecycleStateV1: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public var version: UInt32
    public var startedDate: Date
    public var exitCode: Int32?
    public var exitedDate: Date?

    public init(
        startedDate: Date,
        exitCode: Int32? = nil,
        exitedDate: Date? = nil
    ) {
        self.version = Self.schemaVersion
        self.startedDate = startedDate
        self.exitCode = exitCode
        self.exitedDate = exitedDate
    }
}

public enum ContainerPublicStateV2: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case running
    case paused
    case restarting
    case exited
    case removing
    case dead
}

public struct ContainerLifecycleSnapshotV2: Codable, Equatable, Sendable {
    public var state: ContainerPublicStateV2
    public var running: Bool
    public var paused: Bool
    public var restarting: Bool
    public var removalInProgress: Bool
    public var dead: Bool
    public var oomKilled: Bool
    public var oomKillCountBaseline: UInt64?
    public var pid: Int32
    public var exitCode: Int32
    public var error: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var restartCount: UInt64
    public var restartConsecutiveFailureCount: UInt32?
    public var health: String?
    public var processGeneration: UInt64?
    public var transitionRevision: UInt64
    public var operationGeneration: UInt64

    public init(
        state: ContainerPublicStateV2,
        running: Bool = false,
        paused: Bool = false,
        restarting: Bool = false,
        removalInProgress: Bool = false,
        dead: Bool = false,
        oomKilled: Bool = false,
        oomKillCountBaseline: UInt64? = nil,
        pid: Int32 = 0,
        exitCode: Int32 = 0,
        error: String = "",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        restartCount: UInt64 = 0,
        restartConsecutiveFailureCount: UInt32? = nil,
        health: String? = nil,
        processGeneration: UInt64? = nil,
        transitionRevision: UInt64 = 1,
        operationGeneration: UInt64 = 0
    ) {
        self.state = state
        self.running = running
        self.paused = paused
        self.restarting = restarting
        self.removalInProgress = removalInProgress
        self.dead = dead
        self.oomKilled = oomKilled
        self.oomKillCountBaseline = oomKillCountBaseline
        self.pid = pid
        self.exitCode = exitCode
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.restartCount = restartCount
        self.restartConsecutiveFailureCount = restartConsecutiveFailureCount
        self.health = health
        self.processGeneration = processGeneration
        self.transitionRevision = transitionRevision
        self.operationGeneration = operationGeneration
    }
}

public struct ContainerLifecycleIntentV2: Codable, Equatable, Sendable {
    public var autoRemove: Bool
    public var restartPolicy: ContainerRestartPolicy
    public var removalRequested: Bool
    public var manualRestartSuppressed: Bool

    public init(
        autoRemove: Bool = false,
        restartPolicy: ContainerRestartPolicy = .no,
        removalRequested: Bool = false,
        manualRestartSuppressed: Bool = false
    ) {
        self.autoRemove = autoRemove
        self.restartPolicy = restartPolicy
        self.removalRequested = removalRequested
        self.manualRestartSuppressed = manualRestartSuppressed
    }
}

public struct ContainerLifecycleRecordV2: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 2

    public var version: UInt32
    public var containerID: String
    public var canonicalName: String
    public var immutableBundleKey: String
    public var selectedProviderFingerprint: String
    public var intent: ContainerLifecycleIntentV2
    public var snapshot: ContainerLifecycleSnapshotV2

    public init(
        containerID: String,
        canonicalName: String,
        immutableBundleKey: String,
        selectedProviderFingerprint: String,
        intent: ContainerLifecycleIntentV2 = .init(),
        snapshot: ContainerLifecycleSnapshotV2
    ) {
        self.version = Self.schemaVersion
        self.containerID = containerID
        self.canonicalName = canonicalName
        self.immutableBundleKey = immutableBundleKey
        self.selectedProviderFingerprint = selectedProviderFingerprint
        self.intent = intent
        self.snapshot = snapshot
    }

    /// Migrates a stopped legacy record without inventing transient state.
    public static func migrate(
        bundleKey: String,
        canonicalName: String,
        selectedProviderFingerprint: String,
        legacy: ContainerLifecycleStateV1?,
        intent: ContainerLifecycleIntentV2 = .init()
    ) -> Self {
        let domain = "container.lifecycle.v2\u{0}"
        let material = domain + selectedProviderFingerprint + "\u{0}" + bundleKey
        let containerID = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let started = legacy?.startedDate
        return Self(
            containerID: containerID,
            canonicalName: canonicalName,
            immutableBundleKey: bundleKey,
            selectedProviderFingerprint: selectedProviderFingerprint,
            intent: intent,
            snapshot: ContainerLifecycleSnapshotV2(
                state: started == nil ? .created : .exited,
                exitCode: legacy?.exitCode ?? 0,
                startedAt: started,
                finishedAt: legacy?.exitedDate,
                processGeneration: started == nil ? nil : 1,
                transitionRevision: 1
            )
        )
    }
}

/// One atomic resource-and-lifecycle view from the container authority.
public struct ContainerLifecycleViewV2: Codable, Sendable {
    public var container: ContainerSnapshot
    public var lifecycle: ContainerLifecycleRecordV2

    public init(
        container: ContainerSnapshot,
        lifecycle: ContainerLifecycleRecordV2
    ) {
        self.container = container
        self.lifecycle = lifecycle
    }
}

extension Bundle {
    public static let lifecycleStateFilename = "lifecycle-v1.json"
    public static let lifecycleRecordV2Filename = "lifecycle-v2.json"

    public var lifecycleState: ContainerLifecycleStateV1? {
        get throws {
            let file = filePath(for: Self.lifecycleStateFilename)
            guard FileManager.default.fileExists(atPath: file.path) else {
                return nil
            }
            let state: ContainerLifecycleStateV1 = try load(
                filename: Self.lifecycleStateFilename
            )
            guard state.version == ContainerLifecycleStateV1.schemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            return state
        }
    }

    public func setDurably(lifecycleState: ContainerLifecycleStateV1) throws {
        try writeDurably(
            filename: Self.lifecycleStateFilename,
            value: lifecycleState
        )
    }

    public var lifecycleRecordV2: ContainerLifecycleRecordV2? {
        get throws {
            let file = filePath(for: Self.lifecycleRecordV2Filename)
            guard FileManager.default.fileExists(atPath: file.path) else {
                return nil
            }
            let record: ContainerLifecycleRecordV2 = try load(
                filename: Self.lifecycleRecordV2Filename
            )
            guard record.version == ContainerLifecycleRecordV2.schemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            return record
        }
    }

    public func setDurably(lifecycleRecordV2: ContainerLifecycleRecordV2) throws {
        try writeDurably(
            filename: Self.lifecycleRecordV2Filename,
            value: lifecycleRecordV2
        )
    }
}
