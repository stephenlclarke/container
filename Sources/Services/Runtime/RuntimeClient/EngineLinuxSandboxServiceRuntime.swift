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

import Foundation

/// Sealed AF_VSOCK endpoint declaration for one protected service slot.
///
/// The runtime admits a dial only when the recorded workload configuration
/// declares exactly one matching `--port` and no Unix-listener override. This
/// keeps the service endpoint inside the Engine-owned VM and avoids the guest
/// UDS path and mount-namespace limits of published socket relays.
public enum EngineLinuxSandboxServiceEndpointV1 {
    public static func declaresExclusiveVsockPort(
        arguments: [String],
        port: UInt32
    ) -> Bool {
        guard !arguments.contains("--listen-unix") else {
            return false
        }
        var declaredPorts = [String]()
        for index in arguments.indices where arguments[index] == "--port" {
            guard arguments.indices.contains(index + 1) else {
                return false
            }
            declaredPorts.append(arguments[index + 1])
        }
        return declaredPorts == [String(port)]
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
