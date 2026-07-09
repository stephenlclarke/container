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

/// Docker-style Linux device mapping resolved by the Linux runtime service.
///
/// The `source` path names a runtime-supported Linux VM device, not an
/// arbitrary macOS host device.
public struct LinuxDeviceMapping: Codable, Equatable, Sendable {
    public let source: String
    public let target: String
    public let permissions: String

    public init(source: String, target: String, permissions: String) {
        self.source = source
        self.target = target
        self.permissions = permissions
    }
}

/// Linux-specific runtime data passed through the opaque runtimeData field
/// in RuntimeConfiguration. Encoded by the CLI, decoded by the Linux runtime.
public struct LinuxRuntimeData: Codable, Sendable {
    public let variant: String?
    /// Block I/O cgroup tuning carried opaquely through
    /// `RuntimeConfiguration.runtimeData`.
    public let blockIO: ContainerizationOCI.LinuxBlockIO?
    /// Process count limit carried opaquely through
    /// `RuntimeConfiguration.runtimeData`.
    public let pidsLimit: Int64?
    /// Device cgroup rules carried opaquely through
    /// `RuntimeConfiguration.runtimeData`.
    public let deviceCgroupRules: [ContainerizationOCI.LinuxDeviceCgroup]
    /// Linux VM device mappings resolved by the runtime service.
    public let devices: [LinuxDeviceMapping]

    public init(
        variant: String? = nil,
        blockIO: ContainerizationOCI.LinuxBlockIO? = nil,
        pidsLimit: Int64? = nil,
        deviceCgroupRules: [ContainerizationOCI.LinuxDeviceCgroup] = [],
        devices: [LinuxDeviceMapping] = []
    ) {
        self.variant = variant
        self.blockIO = blockIO
        self.pidsLimit = pidsLimit
        self.deviceCgroupRules = deviceCgroupRules
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case variant
        case blockIO
        case pidsLimit
        case deviceCgroupRules
        case devices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        blockIO = try container.decodeIfPresent(ContainerizationOCI.LinuxBlockIO.self, forKey: .blockIO)
        pidsLimit = try container.decodeIfPresent(Int64.self, forKey: .pidsLimit)
        deviceCgroupRules = try container.decodeIfPresent([ContainerizationOCI.LinuxDeviceCgroup].self, forKey: .deviceCgroupRules) ?? []
        devices = try container.decodeIfPresent([LinuxDeviceMapping].self, forKey: .devices) ?? []
    }
}
