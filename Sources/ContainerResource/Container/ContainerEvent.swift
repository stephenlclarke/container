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
    /// Monotonic sequence within the current authority event epoch.
    public var sequence: UInt64
    /// Lifecycle revision that committed the observable action.
    public var transitionRevision: UInt64
    /// Mutation attempt generation associated with the action.
    public var operationGeneration: UInt64

    public init(
        time: Date = Date(),
        type: String,
        id: String,
        action: String,
        attributes: [String: String] = [:],
        sequence: UInt64 = 0,
        transitionRevision: UInt64 = 0,
        operationGeneration: UInt64 = 0
    ) {
        self.time = time
        self.type = type
        self.id = id
        self.action = action
        self.attributes = attributes
        self.sequence = sequence
        self.transitionRevision = transitionRevision
        self.operationGeneration = operationGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case time
        case type
        case id
        case action
        case attributes
        case sequence
        case transitionRevision
        case operationGeneration
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        time = try values.decode(Date.self, forKey: .time)
        type = try values.decode(String.self, forKey: .type)
        id = try values.decode(String.self, forKey: .id)
        action = try values.decode(String.self, forKey: .action)
        attributes =
            try values.decodeIfPresent(
                [String: String].self,
                forKey: .attributes
            ) ?? [:]
        sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        transitionRevision =
            try values.decodeIfPresent(
                UInt64.self,
                forKey: .transitionRevision
            ) ?? 0
        operationGeneration =
            try values.decodeIfPresent(
                UInt64.self,
                forKey: .operationGeneration
            ) ?? 0
    }
}
