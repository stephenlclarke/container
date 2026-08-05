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

extension Bundle {
    public static let lifecycleStateFilename = "lifecycle-v1.json"

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
}
