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

/// Retrieval filters that refine which container log lines are returned.
///
/// ``default`` is the zero-option equivalent to the original `logs(id:)`
/// behavior.
public struct ContainerLogOptions: Codable, Equatable, Sendable {
    /// If non-nil and non-negative, return only the last `tail` log lines.
    ///
    /// A negative value preserves Docker compatibility by behaving like `all`.
    public let tail: Int?

    /// If non-nil, return log lines not older than this date.
    public let since: Date?

    /// If non-nil, return log lines not newer than this date.
    public let until: Date?

    public static let `default` = ContainerLogOptions()

    public init(
        tail: Int? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) {
        self.tail = tail
        self.since = since
        self.until = until
    }
}

/// Static replay policy for local container log storage.
public struct ContainerLogReplayOptions: Codable, Equatable, Sendable {
    /// If true, static replay includes rotated local log files.
    public let includeRotated: Bool

    public static let `default` = ContainerLogReplayOptions()

    public init(includeRotated: Bool = false) {
        self.includeRotated = includeRotated
    }
}
