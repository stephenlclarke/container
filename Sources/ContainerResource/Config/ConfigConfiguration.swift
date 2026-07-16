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

/// Metadata for immutable, non-secret configuration content.
public struct ConfigConfiguration: Codable, Sendable, Equatable, Identifiable {
    /// The unique identifier for the configuration. Identical to ``name``.
    public var id: String { name }
    /// User-assigned configuration name.
    public var name: String
    /// Timestamp when the configuration was created.
    public var creationDate: Date
    /// User-defined key/value metadata.
    public var labels: [String: String]
    /// Size of the stored configuration content in bytes.
    public var sizeInBytes: UInt64

    public init(
        name: String,
        creationDate: Date = Date(),
        labels: [String: String] = [:],
        sizeInBytes: UInt64
    ) {
        self.name = name
        self.creationDate = creationDate
        self.labels = labels
        self.sizeInBytes = sizeInBytes
    }
}

/// Error types for configuration resource operations.
public enum ConfigError: Error, LocalizedError {
    case configNotFound(String)
    case configAlreadyExists(String)
    case invalidConfigName(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .configNotFound(let name):
            "config '\(name)' not found"
        case .configAlreadyExists(let name):
            "config '\(name)' already exists"
        case .invalidConfigName(let name):
            "invalid config name '\(name)'"
        case .storageError(let message):
            "storage error: \(message)"
        }
    }
}

/// Configuration storage management utilities.
public struct ConfigStorage {
    public static let configNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"

    public static func isValidConfigName(_ name: String) -> Bool {
        guard name.count <= 255 else { return false }

        do {
            let regex = try Regex(configNamePattern)
            return (try? regex.wholeMatch(in: name)) != nil
        } catch {
            return false
        }
    }
}
