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

/// Versioned runtime contracts provided by the supported container stack.
public enum RuntimeCapability: String, CaseIterable, Codable, Sendable {
    case composeArchiveCopy = "io.github.stephenlclarke.container.compose.archive-copy.v1"
    case composeBuildExtensions = "io.github.stephenlclarke.container.compose.build-extensions.v1"
    case composeCreateConfiguration = "io.github.stephenlclarke.container.compose.create-configuration.v1"
    case composeImageFilesystem = "io.github.stephenlclarke.container.compose.image-filesystem.v1"
    case composeLifecycle = "io.github.stephenlclarke.container.compose.lifecycle.v1"
    case composeNetworkScopedAliases = "io.github.stephenlclarke.container.compose.network-scoped-aliases.v1"
    case composeObservation = "io.github.stephenlclarke.container.compose.observation.v1"
    case inboundUnixSocket = "io.github.stephenlclarke.container.inbound-unix-socket.v1"
    case loggingDrivers = "io.github.stephenlclarke.container.logging-drivers.v1"
}

/// Machine-readable capability contract emitted by `container system version`.
public struct RuntimeCapabilityManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let capabilities: [RuntimeCapability]

    public init(schemaVersion: Int, capabilities: [RuntimeCapability]) {
        self.schemaVersion = schemaVersion
        self.capabilities = capabilities
    }

    public static var current: RuntimeCapabilityManifest {
        RuntimeCapabilityManifest(
            schemaVersion: currentSchemaVersion,
            capabilities: RuntimeCapability.allCases.sorted { $0.rawValue < $1.rawValue }
        )
    }
}
