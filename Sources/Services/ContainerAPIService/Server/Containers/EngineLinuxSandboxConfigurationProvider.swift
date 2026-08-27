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
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import Foundation

public protocol EngineLinuxSandboxConfigurationProvidingV1: Sendable {
    func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
}

/// Lazily materializes and caches the VM-wide assets shared by ordinary
/// `shared-vm` workloads. Workload root filesystems remain per-container and
/// are hot-plugged only after the authority has fenced the sandbox generation.
public actor EngineLinuxSandboxConfigurationProviderV1:
    EngineLinuxSandboxConfigurationProvidingV1
{
    private let root: URL
    private let kernelService: KernelService
    private let containerSystemConfig: ContainerSystemConfig
    private var cached: EngineLinuxSandboxRuntimeConfigurationV1?

    public init(
        appRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig
    ) {
        self.root = appRoot.appendingPathComponent(
            "engine-linux-sandbox",
            isDirectory: true
        )
        self.kernelService = kernelService
        self.containerSystemConfig = containerSystemConfig
    }

    public func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    {
        if let cached {
            return cached
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )

        let platform = SystemPlatform.linuxArm.ociPlatform()
        let kernel = try await kernelService.getDefaultKernel(
            platform: .linuxArm
        )
        let initImage = try await ClientImage.fetch(
            reference: containerSystemConfig.vminit.image,
            platform: platform,
            containerSystemConfig: containerSystemConfig
        )
        var initialFilesystem = try await initImage.getCreateSnapshot(
            platform: platform
        )
        initialFilesystem.options = ["ro"]

        let configuration = EngineLinuxSandboxRuntimeConfigurationV1(
            path: root,
            sandboxID: "engine-linux-sandbox",
            initialFilesystem: initialFilesystem,
            kernel: kernel,
            cpus: max(1, containerSystemConfig.container.cpus),
            memoryInBytes: max(
                512 * 1_024 * 1_024,
                containerSystemConfig.container.memory.toUInt64(unit: .bytes)
            )
        )
        try configuration.validate(expectedPath: root)
        cached = configuration
        return configuration
    }
}
