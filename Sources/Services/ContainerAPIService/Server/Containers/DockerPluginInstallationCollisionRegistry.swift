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

import ContainerResource

/// Collision authority for one deterministic logging-plugin discovery pass.
///
/// Multiple immutable generations may own the same provider identity and
/// registered names. Exact provider-generation pairs and service ports remain
/// unique because staged and draining workloads can coexist.
package struct DockerPluginInstallationCollisionRegistry {
    private var registeredNameOwners: [String: String]
    private let reservedProviderIDs: Set<String>
    private var servicePorts = Set<UInt32>()
    private var providerGenerations = Set<ProviderGeneration>()

    private struct ProviderGeneration: Hashable {
        let providerID: String
        let generation: UInt64
    }

    package init(reservedDescriptors: [LogDriverDescriptor]) {
        var nameOwners = [String: String]()
        for descriptor in reservedDescriptors {
            for name in descriptor.registeredNames {
                nameOwners[name] = descriptor.providerIdentity.id
            }
        }
        self.registeredNameOwners = nameOwners
        self.reservedProviderIDs = Set(
            reservedDescriptors.map(\.providerIdentity.id)
        )
    }

    package mutating func register(
        driver: String,
        aliases: [String],
        providerID: String,
        providerGeneration: UInt64,
        servicePort: UInt32
    ) throws {
        let names = [driver] + aliases
        guard
            names.allSatisfy({ name in
                registeredNameOwners[name].map { $0 == providerID } ?? true
            })
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin name collides with an installed provider"
                )
        }
        guard !servicePorts.contains(servicePort) else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin service port collides with an installed provider"
                )
        }
        let providerGeneration = ProviderGeneration(
            providerID: providerID,
            generation: providerGeneration
        )
        guard
            !reservedProviderIDs.contains(providerID),
            !providerGenerations.contains(providerGeneration)
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin provider generation is duplicated"
                )
        }

        for name in names {
            registeredNameOwners[name] = providerID
        }
        servicePorts.insert(servicePort)
        providerGenerations.insert(providerGeneration)
    }
}
