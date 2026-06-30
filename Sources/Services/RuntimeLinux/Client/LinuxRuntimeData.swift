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

import ContainerizationOCI
import Foundation

/// Linux-specific runtime data passed through the opaque runtimeData field
/// in RuntimeConfiguration. Encoded by the CLI, decoded by the Linux runtime.
public struct LinuxRuntimeData: Codable, Sendable {
    public let variant: String?
    /// Block I/O cgroup tuning carried opaquely through
    /// `RuntimeConfiguration.runtimeData`.
    public let blockIO: ContainerizationOCI.LinuxBlockIO?
    /// Device cgroup rules carried opaquely through
    /// `RuntimeConfiguration.runtimeData`.
    public let deviceCgroupRules: [ContainerizationOCI.LinuxDeviceCgroup]

    public init(
        variant: String? = nil,
        blockIO: ContainerizationOCI.LinuxBlockIO? = nil,
        deviceCgroupRules: [ContainerizationOCI.LinuxDeviceCgroup] = []
    ) {
        self.variant = variant
        self.blockIO = blockIO
        self.deviceCgroupRules = deviceCgroupRules
    }

    enum CodingKeys: String, CodingKey {
        case variant
        case blockIO
        case deviceCgroupRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        blockIO = try container.decodeIfPresent(ContainerizationOCI.LinuxBlockIO.self, forKey: .blockIO)
        deviceCgroupRules = try container.decodeIfPresent([ContainerizationOCI.LinuxDeviceCgroup].self, forKey: .deviceCgroupRules) ?? []
    }
}
