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

import ContainerAPIClient
import ContainerRuntimeLinuxClient
import Foundation

extension LinuxRuntimeData {
    static func encoded(from flags: Flags.Management) throws -> Data? {
        let blockIO = try Parser.blockIO(specs: flags.blkio)
        let pidsLimit = try Parser.pidsLimit(flags.pidsLimit)
        let deviceCgroupRules = try Parser.deviceCgroupRules(flags.deviceCgroupRules)
        let devices = try Parser.devices(flags.devices).map {
            LinuxDeviceMapping(source: $0.source, target: $0.target, permissions: $0.permissions)
        }

        guard blockIO != nil || pidsLimit != nil || !deviceCgroupRules.isEmpty || !devices.isEmpty else {
            return nil
        }

        return try JSONEncoder().encode(
            LinuxRuntimeData(
                blockIO: blockIO,
                pidsLimit: pidsLimit,
                deviceCgroupRules: deviceCgroupRules,
                devices: devices
            ))
    }
}
