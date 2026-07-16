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

/// A persistent secret resource whose value is not included in metadata output.
public struct SecretResource: ManagedResource {
    /// The secret's persistent metadata.
    public let configuration: SecretConfiguration

    public var id: String { configuration.name }
    public var name: String { configuration.name }
    public var creationDate: Date { configuration.creationDate }
    public var labels: ResourceLabels { ResourceLabels() }
    public var isAnonymous: Bool { false }

    public static func nameValid(_ name: String) -> Bool {
        SecretStorage.isValidSecretName(name)
    }

    public init(configuration: SecretConfiguration) {
        self.configuration = configuration
    }
}

extension SecretResource {
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
        configuration = try container.decode(SecretConfiguration.self, forKey: .configuration)
    }
}
