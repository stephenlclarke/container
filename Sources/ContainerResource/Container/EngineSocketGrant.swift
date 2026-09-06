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
import CryptoKit
import Foundation

public enum EngineSocketGrantStateV1: String, Codable, Equatable, Sendable {
    case inactive
    case staged
    case active
    case revoked
}

public enum EngineSocketGrantError: Error, Equatable, Sendable {
    case invalidContainerID
    case invalidIntent
    case invalidPermissions
    case invalidGeneration
    case staleGeneration
    case invalidTransition(
        expected: EngineSocketGrantStateV1,
        actual: EngineSocketGrantStateV1
    )
}

/// Durable authority-owned grant for one Container Engine socket projection.
///
/// Private host broker paths are deliberately absent. A staged or active
/// grant is fenced by the socket lease, workload process, and sandbox
/// generations that must all match before a lifecycle operation may change it.
public struct EngineSocketGrantRecordV1: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let dockerSocketMode: UInt16 = 0o660
    public static let dockerSocketUID: UInt32 = 0
    public static let dockerSocketGID: UInt32 = 991

    public var version: UInt32
    public var grantID: String
    public var containerID: String
    public var guestPath: AbsoluteGuestPath
    public var guestMode: UInt16
    public var guestUID: UInt32
    public var guestGID: UInt32
    public var leaseGeneration: UInt64
    public var activeProcessGeneration: UInt64?
    public var activeSandboxGeneration: UInt64?
    public var state: EngineSocketGrantStateV1

    public init(
        grantID: String,
        containerID: String,
        guestPath: AbsoluteGuestPath,
        guestMode: UInt16 = Self.dockerSocketMode,
        guestUID: UInt32 = Self.dockerSocketUID,
        guestGID: UInt32 = Self.dockerSocketGID,
        leaseGeneration: UInt64 = 0,
        activeProcessGeneration: UInt64? = nil,
        activeSandboxGeneration: UInt64? = nil,
        state: EngineSocketGrantStateV1 = .inactive
    ) throws {
        self.version = Self.schemaVersion
        self.grantID = grantID
        self.containerID = containerID
        self.guestPath = guestPath
        self.guestMode = guestMode
        self.guestUID = guestUID
        self.guestGID = guestGID
        self.leaseGeneration = leaseGeneration
        self.activeProcessGeneration = activeProcessGeneration
        self.activeSandboxGeneration = activeSandboxGeneration
        self.state = state
        try validate()
    }

    public static func prepare(
        containerID: String,
        intent: InboundUnixSocketIntentV1
    ) throws -> Self {
        guard intent.kind == .engineAPI,
            intent.target.value == InboundUnixSocketIntentV1.dockerSocketPath,
            intent.inspectSource == InboundUnixSocketIntentV1.dockerSocketPath
        else {
            throw EngineSocketGrantError.invalidIntent
        }
        guard !containerID.isEmpty, !containerID.utf8.contains(0) else {
            throw EngineSocketGrantError.invalidContainerID
        }
        let identity = [
            "container.engine-socket-grant.v1",
            containerID,
            intent.kind.rawValue,
            intent.target.value,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        return try Self(
            grantID: "engine-api-\(digest)",
            containerID: containerID,
            guestPath: intent.target
        )
    }

    /// Stages the next lease for one exact candidate workload tuple.
    /// Repeating the same persisted request is idempotent.
    public mutating func stage(
        leaseGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64
    ) throws {
        if state == .staged,
            self.leaseGeneration == leaseGeneration,
            activeProcessGeneration == processGeneration,
            activeSandboxGeneration == sandboxGeneration
        {
            return
        }
        guard state == .inactive else {
            throw EngineSocketGrantError.invalidTransition(
                expected: .inactive,
                actual: state
            )
        }
        guard processGeneration > 0, sandboxGeneration > 0,
            leaseGeneration > self.leaseGeneration,
            leaseGeneration == self.leaseGeneration + 1
        else {
            throw EngineSocketGrantError.staleGeneration
        }
        self.leaseGeneration = leaseGeneration
        activeProcessGeneration = processGeneration
        activeSandboxGeneration = sandboxGeneration
        state = .staged
    }

    /// Activates only the exact tuple previously staged for this lease.
    public mutating func activate(
        leaseGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64
    ) throws {
        if state == .active,
            matches(
                leaseGeneration: leaseGeneration,
                processGeneration: processGeneration,
                sandboxGeneration: sandboxGeneration
            )
        {
            return
        }
        guard state == .staged else {
            throw EngineSocketGrantError.invalidTransition(
                expected: .staged,
                actual: state
            )
        }
        try requireMatchingTuple(
            leaseGeneration: leaseGeneration,
            processGeneration: processGeneration,
            sandboxGeneration: sandboxGeneration
        )
        state = .active
    }

    /// Deactivates a staged or active lease after exact finalisation.
    public mutating func deactivate(
        leaseGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64
    ) throws {
        guard state == .staged || state == .active else {
            throw EngineSocketGrantError.invalidTransition(
                expected: .active,
                actual: state
            )
        }
        try requireMatchingTuple(
            leaseGeneration: leaseGeneration,
            processGeneration: processGeneration,
            sandboxGeneration: sandboxGeneration
        )
        activeProcessGeneration = nil
        activeSandboxGeneration = nil
        state = .inactive
    }

    /// Reconciles a recovered record without inventing a running workload.
    public mutating func reconcile(
        runningProcessGeneration: UInt64?,
        runningSandboxGeneration: UInt64?
    ) {
        guard state == .staged || state == .active else {
            return
        }
        if let runningProcessGeneration, let runningSandboxGeneration,
            activeProcessGeneration == runningProcessGeneration,
            activeSandboxGeneration == runningSandboxGeneration
        {
            state = .active
            return
        }
        activeProcessGeneration = nil
        activeSandboxGeneration = nil
        state = .inactive
    }

    /// Permanently revokes an inactive grant before container removal.
    public mutating func revoke(expectedLeaseGeneration: UInt64) throws {
        if state == .revoked {
            guard expectedLeaseGeneration == leaseGeneration else {
                throw EngineSocketGrantError.staleGeneration
            }
            return
        }
        guard state == .inactive else {
            throw EngineSocketGrantError.invalidTransition(
                expected: .inactive,
                actual: state
            )
        }
        guard expectedLeaseGeneration == leaseGeneration else {
            throw EngineSocketGrantError.staleGeneration
        }
        state = .revoked
    }

    public func validate() throws {
        guard version == Self.schemaVersion else {
            throw EngineSocketGrantError.invalidGeneration
        }
        guard !grantID.isEmpty, !grantID.utf8.contains(0),
            !containerID.isEmpty, !containerID.utf8.contains(0)
        else {
            throw EngineSocketGrantError.invalidContainerID
        }
        guard guestPath.value == InboundUnixSocketIntentV1.dockerSocketPath else {
            throw EngineSocketGrantError.invalidIntent
        }
        guard guestMode == Self.dockerSocketMode,
            guestUID == Self.dockerSocketUID,
            guestGID == Self.dockerSocketGID
        else {
            throw EngineSocketGrantError.invalidPermissions
        }
        let hasProcess = activeProcessGeneration != nil
        let hasSandbox = activeSandboxGeneration != nil
        guard hasProcess == hasSandbox else {
            throw EngineSocketGrantError.invalidGeneration
        }
        switch state {
        case .inactive, .revoked:
            guard !hasProcess else {
                throw EngineSocketGrantError.invalidGeneration
            }
        case .staged, .active:
            guard leaseGeneration > 0,
                activeProcessGeneration.map({ $0 > 0 }) == true,
                activeSandboxGeneration.map({ $0 > 0 }) == true
            else {
                throw EngineSocketGrantError.invalidGeneration
            }
        }
    }

    private func requireMatchingTuple(
        leaseGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64
    ) throws {
        guard
            matches(
                leaseGeneration: leaseGeneration,
                processGeneration: processGeneration,
                sandboxGeneration: sandboxGeneration
            )
        else {
            throw EngineSocketGrantError.staleGeneration
        }
    }

    private func matches(
        leaseGeneration: UInt64,
        processGeneration: UInt64,
        sandboxGeneration: UInt64
    ) -> Bool {
        self.leaseGeneration == leaseGeneration
            && activeProcessGeneration == processGeneration
            && activeSandboxGeneration == sandboxGeneration
    }
}
