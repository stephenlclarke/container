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

public struct ContainerStopOptions: Sendable, Codable {
    /// Seconds to wait before forcing termination. Nil lets the container's
    /// persisted default (or the runtime default) apply.
    public var timeoutInSeconds: Int32?
    public var signal: String?

    public static let `default` = ContainerStopOptions(
        timeoutInSeconds: nil,
        signal: nil
    )

    public init(timeoutInSeconds: Int32?, signal: String?) {
        self.timeoutInSeconds = timeoutInSeconds
        self.signal = signal
    }

    /// Source-compatible convenience initializer for callers that provide an
    /// explicit stop timeout.
    public init(timeoutInSeconds: Int32, signal: String?) {
        self.init(timeoutInSeconds: Optional(timeoutInSeconds), signal: signal)
    }
}
