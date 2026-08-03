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

/// Exact identity required to dial a protected service in the Engine Linux
/// sandbox. A stale authority cannot reuse a connection after sandbox
/// replacement because every request names the active durable generation.
public struct EngineLinuxSandboxServiceDialRequestV1: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let sandboxGeneration: UInt64
    public let port: UInt32

    public init(
        sandboxID: String,
        sandboxGeneration: UInt64,
        port: UInt32
    ) {
        self.sandboxID = sandboxID
        self.sandboxGeneration = sandboxGeneration
        self.port = port
    }
}

/// Transport boundary for protected services hosted in the shared sandbox.
public protocol EngineLinuxSandboxServiceRuntimeV1: Sendable {
    func dialService(
        _ request: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> FileHandle
}
