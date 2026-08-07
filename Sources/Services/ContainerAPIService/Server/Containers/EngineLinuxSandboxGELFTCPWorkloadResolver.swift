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
import Containerization
import Foundation
import Logging

/// The production XPC boundary. The materializer never receives a live
/// `ClientImage` or `KernelService`, so its persistence and security policy can
/// be exercised without starting the user's shared engine.
actor EngineLinuxSandboxGELFTCPWorkloadResolverV1:
    EngineLinuxSandboxGELFTCPWorkloadResolvingV1
{
    private static let logger = Logger(
        label: "com.apple.container.logging.gelf.tcp-service"
    )

    private let kernelService: KernelService
    private let containerSystemConfig: ContainerSystemConfig
    private var cachedImage: ClientImage?

    init(
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig
    ) {
        self.kernelService = kernelService
        self.containerSystemConfig = containerSystemConfig
    }

    func sandboxBootstrap() async throws -> EngineLinuxSandboxGELFTCPBootstrapV1 {
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let kernel = try await kernelService.getDefaultKernel(platform: .linuxArm)
        let initImage: ClientImage
        do {
            initImage = try await ClientImage.fetch(
                reference: containerSystemConfig.vminit.image,
                platform: platform,
                containerSystemConfig: containerSystemConfig
            )
        } catch {
            Self.logger.error(
                "Failed to resolve Engine-Linux GELF TCP service init image",
                metadata: [
                    "reference": "\(containerSystemConfig.vminit.image)",
                    "error": "\(error)",
                ]
            )
            throw error
        }
        return EngineLinuxSandboxGELFTCPBootstrapV1(
            initialFilesystem: try await initImage.getCreateSnapshot(
                platform: platform
            ),
            kernel: kernel,
            cpus: containerSystemConfig.container.cpus,
            memoryInBytes: containerSystemConfig.container.memory.toUInt64(
                unit: .bytes
            )
        )
    }

    func workloadImage(
        archiveURL: URL,
        manifestDigest: String
    ) async throws -> EngineLinuxSandboxGELFTCPWorkloadImageV1 {
        let image = try await exactImage(
            archiveURL: archiveURL,
            manifestDigest: manifestDigest
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        return try await EngineLinuxSandboxGELFTCPWorkloadImageV1(
            image: image.description,
            rootFilesystem: image.getCreateSnapshot(platform: platform)
        )
    }

    private func exactImage(
        archiveURL: URL,
        manifestDigest: String
    ) async throws -> ClientImage {
        if let cachedImage {
            return cachedImage
        }
        let installed = try await ClientImage.list()
        if let existing = try await Self.exactImage(
            in: installed,
            manifestDigest: manifestDigest
        ) {
            cachedImage = existing
            return existing
        }
        let loaded = try await ClientImage.load(from: archiveURL.path)
        guard loaded.rejectedMembers.isEmpty else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "GELF TCP OCI archive contained rejected members"
            )
        }
        guard
            let image = try await Self.exactImage(
                in: loaded.images,
                manifestDigest: manifestDigest
            )
        else {
            throw EngineLinuxSandboxGELFTCPServiceError.exactWorkloadImageNotFound
        }
        cachedImage = image
        return image
    }

    private static func exactImage(
        in images: [ClientImage],
        manifestDigest: String
    ) async throws -> ClientImage? {
        let platform = SystemPlatform.linuxArm.ociPlatform()
        var matches = [ClientImage]()
        for image in images {
            guard let index = try? await image.index() else {
                continue
            }
            if index.manifests.filter({
                $0.platform == platform && $0.digest == manifestDigest
            }).count == 1 {
                matches.append(image)
            }
        }
        guard matches.count <= 1 else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "multiple installed images claim the GELF TCP workload manifest"
            )
        }
        return matches.first
    }
}
