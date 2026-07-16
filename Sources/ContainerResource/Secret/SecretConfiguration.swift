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

/// Metadata for an opaque secret held in the local keychain.
public struct SecretConfiguration: Codable, Sendable, Equatable, Identifiable {
    /// The unique identifier for the secret. Identical to ``name``.
    public var id: String { name }
    /// User-assigned secret name.
    public var name: String
    /// Timestamp when the secret was created.
    public var creationDate: Date
    /// Timestamp when the secret was last modified.
    public var modificationDate: Date
    /// Size of the secret content in bytes, when the value was read.
    public var sizeInBytes: UInt64?

    public init(
        name: String,
        creationDate: Date,
        modificationDate: Date,
        sizeInBytes: UInt64?
    ) {
        self.name = name
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.sizeInBytes = sizeInBytes
    }
}

/// Error types for secret resource operations.
public enum SecretError: Error, LocalizedError {
    case secretNotFound(String)
    case secretAlreadyExists(String)
    case invalidSecretName(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .secretNotFound(let name):
            "secret '\(name)' not found"
        case .secretAlreadyExists(let name):
            "secret '\(name)' already exists"
        case .invalidSecretName(let name):
            "invalid secret name '\(name)'"
        case .storageError(let message):
            "storage error: \(message)"
        }
    }
}

/// Secret storage management utilities.
public struct SecretStorage {
    public static let secretNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"

    public static func isValidSecretName(_ name: String) -> Bool {
        guard name.count <= 255 else { return false }

        do {
            let regex = try Regex(secretNamePattern)
            return (try? regex.wholeMatch(in: name)) != nil
        } catch {
            return false
        }
    }
}
