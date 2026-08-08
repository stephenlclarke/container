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
import Foundation

/// Sealed VSOCK declaration for one protected service slot.
///
/// The runtime derives the transport from the immutable workload
/// configuration. A reverse-VSOCK marker makes the workload connect to a
/// host listener; without that marker, the host dials the established direct
/// guest-VSOCK service. Both shapes require exactly one matching port and no
/// published socket or guest Unix listener.
public enum EngineLinuxSandboxServiceEndpointV1 {
    /// The exact, valueless process flag that authorizes a reverse connection
    /// from the workload to the host listener for its sealed service port.
    public static let reverseHostVsockFlag = "--connect-host-vsock"

    /// Returns the sealed reverse-VSOCK port, if the process declaration has
    /// exactly the Engine-owned shape. A caller must still fence the returned
    /// port to its active workload and sandbox generations.
    public static func reverseVsockPort(
        arguments: [String],
        publishedSockets: [PublishSocket]
    ) -> UInt32? {
        guard
            publishedSockets.isEmpty,
            let declaredPorts = values(for: "--port", in: arguments),
            declaredPorts.count == 1,
            let port = UInt32(declaredPorts[0]),
            port > 0,
            hasExactlyOneValuelessFlag(
                reverseHostVsockFlag,
                in: arguments
            ),
            !containsFlag("--listen-unix", in: arguments)
        else {
            return nil
        }
        return port
    }

    public static func declaresExclusiveReverseVsockRelay(
        arguments: [String],
        port: UInt32,
        publishedSockets: [PublishSocket]
    ) -> Bool {
        reverseVsockPort(
            arguments: arguments,
            publishedSockets: publishedSockets
        ) == port
    }

    /// Returns the direct guest-VSOCK port for a sealed service that has not
    /// opted into the reverse-VSOCK transport. The Engine still fences the
    /// returned port to the active workload and sandbox generations before it
    /// opens a connection.
    ///
    /// This retains the established transport for the journald and installed
    /// Docker logging-plugin services while ensuring a reverse-VSOCK marker,
    /// a published socket, or a Unix listener cannot be reinterpreted as a
    /// direct guest endpoint.
    public static func guestVsockPort(
        arguments: [String],
        publishedSockets: [PublishSocket]
    ) -> UInt32? {
        guard
            publishedSockets.isEmpty,
            let declaredPorts = values(for: "--port", in: arguments),
            declaredPorts.count == 1,
            let port = UInt32(declaredPorts[0]),
            port > 0,
            !containsFlag(reverseHostVsockFlag, in: arguments),
            !containsFlag("--listen-unix", in: arguments)
        else {
            return nil
        }
        return port
    }

    /// Returns whether the declaration authorizes only the requested direct
    /// guest-VSOCK service port.
    public static func declaresExclusiveGuestVsockService(
        arguments: [String],
        port: UInt32,
        publishedSockets: [PublishSocket]
    ) -> Bool {
        guestVsockPort(
            arguments: arguments,
            publishedSockets: publishedSockets
        ) == port
    }

    private static func values(
        for flag: String,
        in arguments: [String]
    ) -> [String]? {
        var values = [String]()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            guard arguments[index] == flag else {
                index = arguments.index(after: index)
                continue
            }
            let valueIndex = arguments.index(after: index)
            guard
                valueIndex < arguments.endIndex,
                !arguments[valueIndex].hasPrefix("--")
            else {
                return nil
            }
            values.append(arguments[valueIndex])
            index = arguments.index(after: valueIndex)
        }
        return values.isEmpty ? nil : values
    }

    private static func hasExactlyOneValuelessFlag(
        _ flag: String,
        in arguments: [String]
    ) -> Bool {
        var count = 0
        for index in arguments.indices {
            if arguments[index].hasPrefix("\(flag)=") {
                return false
            }
            guard arguments[index] == flag else {
                continue
            }
            count += 1
            let next = arguments.index(after: index)
            guard next == arguments.endIndex || arguments[next].hasPrefix("--") else {
                return false
            }
        }
        return count == 1
    }

    private static func containsFlag(
        _ flag: String,
        in arguments: [String]
    ) -> Bool {
        arguments.contains {
            $0 == flag || $0.hasPrefix("\(flag)=")
        }
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
