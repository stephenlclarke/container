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

    let metadataValues: [String]
    let hostSocketPath: String?

    static func resolve(
        values: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isSocket: (String) -> Bool = isUnixSocket
    ) throws -> BuildSSHForwarding {
        guard !values.isEmpty else {
            return BuildSSHForwarding(metadataValues: [], hostSocketPath: nil)
        }

        var metadataValues: [String] = []
        var explicitHostSocketPath: String?
        var hasImplicitSocket = false

        for value in values {
            let spec = SSHSpec(value)
            if let path = spec.path {
                guard path.hasPrefix("/") else {
                    throw ValidationError("build --ssh \(spec.id)=\(path) must use an absolute host socket path")
                }
                guard isSocket(path) else {
                    throw ValidationError("build --ssh \(spec.id)=\(path) must reference a Unix socket")
                }
                if let existing = explicitHostSocketPath, existing != path {
                    throw ValidationError("build --ssh currently supports one host SSH socket; got \(existing) and \(path)")
                }
                explicitHostSocketPath = path
                metadataValues.append("\(spec.id)=\(guestSocketPath)")
            } else {
                hasImplicitSocket = true
                metadataValues.append(spec.id)
            }
        }

        if let explicitHostSocketPath {
            if hasImplicitSocket,
               let envSocket = normalizedEnvironmentSocket(environment),
               envSocket != explicitHostSocketPath
            {
                throw ValidationError("build --ssh currently supports one host SSH socket; \(BuildSSHForwarding.envKey) is \(envSocket) but an explicit socket \(explicitHostSocketPath) was also requested")
            }
            return BuildSSHForwarding(metadataValues: metadataValues, hostSocketPath: explicitHostSocketPath)
        }

        guard let envSocket = normalizedEnvironmentSocket(environment) else {
            throw ValidationError("build --ssh requires \(envKey) or an explicit --ssh id=/path/to/socket value")
        }
        guard isSocket(envSocket) else {
            throw ValidationError("build --ssh requires \(envKey) to reference a Unix socket")
        }

        return BuildSSHForwarding(metadataValues: metadataValues, hostSocketPath: envSocket)
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
}
