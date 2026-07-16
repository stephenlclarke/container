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

/// A persistent, immutable configuration resource.
public struct ConfigResource: ManagedResource {
    /// The configuration's persistent metadata.
    public let configuration: ConfigConfiguration

    public var id: String { configuration.name }
    public var name: String { configuration.name }
    public var creationDate: Date { configuration.creationDate }
    public var labels: ResourceLabels {
        (try? ResourceLabels(configuration.labels)) ?? ResourceLabels()
    }
    public var isAnonymous: Bool { false }

    public static func nameValid(_ name: String) -> Bool {
        ConfigStorage.isValidConfigName(name)
    }

    public init(configuration: ConfigConfiguration) {
        self.configuration = configuration
    }
}

extension ConfigResource {
    enum CodingKeys: String, CodingKey {
        case id
        case configuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(configuration, forKey: .configuration)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(ConfigConfiguration.self, forKey: .configuration)
    }
}
