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

/// A lifecycle event emitted by the container API service.
public struct ContainerEvent: Codable, Equatable, Sendable {
    /// Time when the event was observed by the API service.
    public var time: Date
    /// Type of resource that emitted the event.
    public var type: String
    /// Identifier of the resource that emitted the event.
    public var id: String
    /// Action that occurred on the resource.
    public var action: String
    /// Stable metadata associated with the resource at the time of the event.
    public var attributes: [String: String]

    public init(
        time: Date = Date(),
        type: String,
        id: String,
        action: String,
        attributes: [String: String] = [:]
    ) {
        self.time = time
        self.type = type
        self.id = id
        self.action = action
        self.attributes = attributes
    }
}
