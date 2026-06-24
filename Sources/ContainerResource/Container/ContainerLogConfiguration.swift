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

/// Logging policy applied by the runtime when capturing container stdio.
public struct ContainerLogConfiguration: Codable, Equatable, Sendable {
    /// Storage backend used for captured container stdio.
    public enum Storage: String, Codable, Equatable, Sendable {
        /// Store logs in the container bundle on the local host.
        case local

        /// Do not persist captured container stdio.
        case none
    }

    /// Local log storage backend.
    public var storage: Storage

    /// Maximum size in bytes for the active local log file before rotation.
    public var maxSizeInBytes: UInt64?

    /// Maximum number of local log files to retain, including the active file.
    public var maxFileCount: Int?

    public static let `default` = ContainerLogConfiguration()

    public init(
        storage: Storage = .local,
        maxSizeInBytes: UInt64? = nil,
        maxFileCount: Int? = nil
    ) {
        self.storage = storage
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = maxFileCount
    }
}
