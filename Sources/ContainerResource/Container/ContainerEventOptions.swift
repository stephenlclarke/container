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

/// Replay and stream filters for container lifecycle events.
///
/// ``default`` is the zero-option equivalent to the original `events()` stream
/// behavior.
public struct ContainerEventOptions: Codable, Equatable, Sendable {
    /// If non-nil, return events not older than this date.
    public let since: Date?

    /// If non-nil, return events not newer than this date and close the stream
    /// after the bound is reached.
    public let until: Date?

    public static let `default` = ContainerEventOptions()

    public init(
        since: Date? = nil,
        until: Date? = nil
    ) {
        self.since = since
        self.until = until
    }
}
