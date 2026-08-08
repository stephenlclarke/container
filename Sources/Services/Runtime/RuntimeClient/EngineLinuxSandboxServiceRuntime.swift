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

import ContainerResource
import CryptoKit
import Foundation

/// Sealed Unix-socket relay declaration for one protected service slot.
///
/// The runtime admits a dial only when the recorded workload configuration
/// declares exactly one matching `--port`, a fixed private Unix listener, and
/// the corresponding Engine-owned published socket. Containerization relays
/// that private socket through Vminitd; neither path is a user-facing socket.
public enum EngineLinuxSandboxServiceEndpointV1 {
    /// Guest path shared by all sealed one-service workloads. Each workload has
    /// its own mount namespace, so this is never shared between services.
    public static let relayGuestSocketPath = "/run/container-engine-service.sock"

    /// The protected shared parent for compact host-side relay directories.
    ///
    /// `sandboxRoot` may be a long application-support path and cannot be used
    /// directly in a Unix socket pathname. This directory is intentionally
    /// outside that root, while each child remains private to one sandbox.
    public static let relayBaseDirectory = URL(
        fileURLWithPath: "/tmp/container-engine-services",
        isDirectory: true
    )

    /// The Engine-owned directory containing short host-side socket paths.
    ///
    /// Keeping the pathname short is intentional: Unix-domain socket path
    /// limits apply even when the application root is a long temporary path.
    public static func relayDirectory(sandboxRoot: URL) -> URL {
        let canonicalRoot =
            sandboxRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let identifier = SHA256.hash(data: Data(canonicalRoot.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return relayBaseDirectory.appendingPathComponent(
            identifier,
            isDirectory: true
        )
    }

    /// The deterministic private host socket for a sealed service port.
    public static func relayHostSocket(
        sandboxRoot: URL,
        port: UInt32
    ) -> URL {
        relayDirectory(sandboxRoot: sandboxRoot)
            .appendingPathComponent(String(port), isDirectory: false)
    }

    /// Removes only the exact private relay directory derived for a stopped
    /// sandbox. Cleanup is deliberately scoped to the leaf directory, never
    /// to the shared relay base.
    public static func removeRelayDirectory(sandboxRoot: URL) throws {
        let directory = relayDirectory(sandboxRoot: sandboxRoot)
        let manager = FileManager.default
        guard
            manager.fileExists(atPath: relayBaseDirectory.path),
            manager.fileExists(atPath: directory.path),
            try isCanonicalDirectory(relayBaseDirectory),
            try isCanonicalDirectory(directory)
        else {
            return
        }
        try manager.removeItem(at: directory)
    }

    /// Builds the only published socket shape accepted for a sealed service.
    public static func sealedRelaySocket(
        sandboxRoot: URL,
        port: UInt32
    ) throws -> PublishSocket {
        try PublishSocket(
            containerPath: .init(relayGuestSocketPath),
            hostPath: .init(
                relayHostSocket(sandboxRoot: sandboxRoot, port: port).path
            ),
            permissions: .init(rawValue: 0o600)
        )
    }

    public static func declaresExclusiveUnixRelay(
        arguments: [String],
        port: UInt32,
        sandboxRoot: URL,
        publishedSockets: [PublishSocket]
    ) -> Bool {
        guard
            port > 0,
            let declaredPorts = values(for: "--port", in: arguments),
            declaredPorts == [String(port)],
            let declaredUnixSockets = values(
                for: "--listen-unix",
                in: arguments
            ),
            declaredUnixSockets == [relayGuestSocketPath],
            publishedSockets.count == 1,
            let expectedSocket = try? sealedRelaySocket(
                sandboxRoot: sandboxRoot,
                port: port
            )
        else {
            return false
        }
        let publishedSocket = publishedSockets[0]
        return publishedSocket.containerPath == expectedSocket.containerPath
            && publishedSocket.hostPath == expectedSocket.hostPath
            && publishedSocket.permissions?.rawValue
                == expectedSocket.permissions?.rawValue
    }

    private static func values(
        for flag: String,
        in arguments: [String]
    ) -> [String]? {
        var values = [String]()
        for index in arguments.indices where arguments[index] == flag {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                return nil
            }
            values.append(arguments[valueIndex])
        }
        return values
    }

    private static func isCanonicalDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        return values.isDirectory == true
            && values.isSymbolicLink != true
            && url.standardizedFileURL.path
                == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Exact identity required to dial a protected service workload in the Engine
/// Linux sandbox. A stale authority cannot reuse a connection after sandbox or
/// workload replacement because every request names both active generations.
public struct EngineLinuxSandboxServiceDialRequestV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let sandboxGeneration: UInt64
    public let workloadID: String
    public let workloadProcessGeneration: UInt64
    public let port: UInt32

    public init(
        sandboxID: String,
        sandboxGeneration: UInt64,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) {
        self.sandboxID = sandboxID
        self.sandboxGeneration = sandboxGeneration
        self.workloadID = workloadID
        self.workloadProcessGeneration = workloadProcessGeneration
        self.port = port
    }
}

/// Transport boundary for protected services hosted in the shared sandbox.
public protocol EngineLinuxSandboxServiceRuntimeV1: Sendable {
    func dialService(
        _ request: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> FileHandle
}
