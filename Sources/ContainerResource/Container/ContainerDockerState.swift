//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// Durable Docker Engine state that is independent of the native lifecycle.
public struct ContainerDockerStateV1: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public var version: UInt32
    /// The most recent rejected Docker start reason, or an empty string after a successful start.
    public var error: String

    public init(error: String = "") {
        self.version = Self.schemaVersion
        self.error = error
    }
}

extension Bundle {
    public static let dockerStateFilename = "docker-state-v1.json"

    public var dockerState: ContainerDockerStateV1? {
        get throws {
            let file = filePath(for: Self.dockerStateFilename)
            guard FileManager.default.fileExists(atPath: file.path) else {
                return nil
            }
            let state: ContainerDockerStateV1 = try load(
                filename: Self.dockerStateFilename
            )
            guard state.version == ContainerDockerStateV1.schemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            return state
        }
    }

    public func setDurably(dockerState: ContainerDockerStateV1) throws {
        try writeDurably(
            filename: Self.dockerStateFilename,
            value: dockerState
        )
    }
}
