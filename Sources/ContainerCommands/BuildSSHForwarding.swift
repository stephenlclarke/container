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

import ArgumentParser
import Foundation

struct BuildSSHForwarding: Equatable, Sendable {
    static let guestSocketPath = "/var/host-services/ssh-auth.sock"
    static let builderSocketLabel = "com.apple.container.builder.ssh-auth-sock"

    struct SocketMount: Equatable, Sendable {
        let id: String
        let hostPath: String
        let guestPath: String
    }

    let metadataValues: [String]
    let socketMounts: [SocketMount]
    let environmentSocketGuestPath: String?

    var isEnabled: Bool {
        !socketMounts.isEmpty
    }

    var builderSocketLabelValue: String? {
        Self.builderSocketLabelValue(socketMounts: socketMounts, environmentSocketGuestPath: environmentSocketGuestPath)
    }

    static func builderSocketLabelValue(socketMounts: [SocketMount], environmentSocketGuestPath: String?) -> String? {
        guard !socketMounts.isEmpty else { return nil }
        let mounts =
            socketMounts
            .map { "\($0.id)=\($0.hostPath)->\($0.guestPath)" }
            .sorted()
            .joined(separator: "|")
        return [environmentSocketGuestPath ?? "-", mounts].joined(separator: "|")
    }

    static func resolve(
        values: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isSocket: (String) -> Bool = isUnixSocket
    ) throws -> BuildSSHForwarding {
        guard !values.isEmpty else {
            return BuildSSHForwarding(metadataValues: [], socketMounts: [], environmentSocketGuestPath: nil)
        }

        var metadataEntries: [SSHMetadataEntry] = []
        var socketMountsByID: [String: SocketMount] = [:]
        var implicitIDs: Set<String> = []

        for value in values {
            let spec = SSHSpec(value)
            if let path = spec.path {
                guard path.hasPrefix("/") else {
                    throw ValidationError("build --ssh \(spec.id)=\(path) must use an absolute host socket path")
                }
                guard isSocket(path) else {
                    throw ValidationError("build --ssh \(spec.id)=\(path) must reference a Unix socket")
                }
                let guestPath = guestSocketPath(for: spec.id)
                let socketMount = SocketMount(id: spec.id, hostPath: path, guestPath: guestPath)
                if let existing = socketMountsByID[spec.id], existing.hostPath != path {
                    throw ValidationError("build --ssh \(spec.id) was specified with multiple host sockets: \(existing.hostPath) and \(path)")
                }
                socketMountsByID[spec.id] = socketMount
                metadataEntries.append(.explicit(id: spec.id, guestPath: guestPath))
            } else {
                implicitIDs.insert(spec.id)
                metadataEntries.append(.implicit(id: spec.id))
            }
        }

        var environmentSocketGuestPath: String?
        if !implicitIDs.isEmpty {
            guard let envSocket = normalizedEnvironmentSocket(environment) else {
                throw ValidationError("build --ssh requires \(envKey) or an explicit --ssh id=/path/to/socket value")
            }
            guard isSocket(envSocket) else {
                throw ValidationError("build --ssh requires \(envKey) to reference a Unix socket")
            }
            let envGuestPath = environmentGuestSocketPath(
                for: envSocket,
                avoiding: Array(socketMountsByID.values)
            )
            environmentSocketGuestPath = envGuestPath
            for id in implicitIDs {
                if let existing = socketMountsByID[id], existing.hostPath != envSocket {
                    throw ValidationError("build --ssh \(id) cannot use both \(envKey)=\(envSocket) and \(existing.hostPath)")
                }
                guard socketMountsByID[id] == nil else {
                    throw ValidationError("build --ssh \(id) cannot be specified both implicitly and explicitly")
                }
                let socketMount = SocketMount(id: id, hostPath: envSocket, guestPath: envGuestPath)
                socketMountsByID[id] = socketMount
            }
        }

        let resolvedMetadataValues = try metadataEntries.map { entry in
            switch entry {
            case .explicit(let id, let guestPath):
                return "\(id)=\(guestPath)"
            case .implicit(let id):
                guard let environmentSocketGuestPath else {
                    throw ValidationError("build --ssh requires \(envKey) or an explicit --ssh id=/path/to/socket value")
                }
                return "\(id)=\(environmentSocketGuestPath)"
            }
        }

        return BuildSSHForwarding(
            metadataValues: resolvedMetadataValues,
            socketMounts: uniqueSocketMounts(Array(socketMountsByID.values)),
            environmentSocketGuestPath: environmentSocketGuestPath
        )
    }

    private static let envKey = "SSH_AUTH_SOCK"

    private static func normalizedEnvironmentSocket(_ environment: [String: String]) -> String? {
        let value = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func isUnixSocket(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSocket
    }

    private static func uniqueSocketMounts(_ mounts: [SocketMount]) -> [SocketMount] {
        var seen: Set<String> = []
        return
            mounts
            .sorted { lhs, rhs in
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                if lhs.guestPath != rhs.guestPath {
                    return lhs.guestPath < rhs.guestPath
                }
                return lhs.hostPath < rhs.hostPath
            }
            .filter { mount in
                let key = "\(mount.hostPath)\u{0}\(mount.guestPath)"
                return seen.insert(key).inserted
            }
    }

    private static func environmentGuestSocketPath(for hostPath: String, avoiding mounts: [SocketMount]) -> String {
        func canUse(_ guestPath: String) -> Bool {
            !mounts.contains { $0.guestPath == guestPath && $0.hostPath != hostPath }
        }

        if canUse(guestSocketPath) {
            return guestSocketPath
        }

        let environmentSocketPath = "/var/host-services/ssh-auth-env.sock"
        if canUse(environmentSocketPath) {
            return environmentSocketPath
        }

        var suffix = 2
        while true {
            let candidate = "/var/host-services/ssh-auth-env-\(suffix).sock"
            if canUse(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func guestSocketPath(for id: String) -> String {
        guard id != "default" else {
            return guestSocketPath
        }
        return "/var/host-services/ssh-auth-\(percentEncodedPathComponent(id)).sock"
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        var result = ""
        for byte in value.utf8 {
            if allowed.contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result.isEmpty ? "default" : result
    }

    private struct SSHSpec: Sendable {
        let id: String
        let path: String?

        init(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

            if parts.count == 2 {
                let id = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                self.id = id.isEmpty ? "default" : id
                self.path = path.isEmpty ? nil : path
                return
            }

            if value.hasPrefix("/") {
                self.id = "default"
                self.path = value
                return
            }

            self.id = value.isEmpty ? "default" : value
            self.path = nil
        }
    }

    private enum SSHMetadataEntry: Sendable {
        case explicit(id: String, guestPath: String)
        case implicit(id: String)
    }
}
