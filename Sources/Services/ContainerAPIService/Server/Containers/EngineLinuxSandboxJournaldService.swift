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
import ContainerLoggingProviders
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import CryptoKit
import Foundation

public enum EngineLinuxSandboxJournaldServiceError: Error, Equatable, Sendable {
    case invalidInstalledAsset(String)
    case exactWorkloadImageNotFound
    case invalidWorkloadReceipt
    case readinessTimedOut
    case generationMismatch(expected: UInt64, actual: UInt64)
}

package struct InstalledJournaldWorkloadManifestV1: Decodable, Equatable,
    Sendable
{
    package static let expectedSchemaVersion: UInt32 = 1
    package static let expectedProtocolVersion: UInt32 = 2
    package static let expectedServiceVersion = "2"

    package let schemaVersion: UInt32
    package let protocolVersion: UInt32
    package let serviceVersion: String
    package let architecture: String
    package let platform: String
    package let ociArchiveSHA256: String
    package let serviceSourceSHA256: String
    package let workloadManifestDigest: String

    package static func verify(
        archiveURL: URL,
        manifestURL: URL
    ) throws -> VerifiedJournaldWorkloadAssetsV1 {
        try verifySecureRegularFile(archiveURL)
        try verifySecureRegularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Self.self, from: manifestData)
        guard
            manifest.schemaVersion == Self.expectedSchemaVersion,
            manifest.protocolVersion == Self.expectedProtocolVersion,
            manifest.serviceVersion == Self.expectedServiceVersion,
            manifest.architecture == "arm64",
            manifest.platform == "linux",
            isSHA256Hex(manifest.ociArchiveSHA256),
            isSHA256Hex(manifest.serviceSourceSHA256),
            isSHA256Digest(manifest.workloadManifestDigest)
        else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "journald workload manifest has an unsupported or malformed contract"
            )
        }
        let archiveSHA256 = try sha256Hex(of: archiveURL)
        guard archiveSHA256 == manifest.ociArchiveSHA256 else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "journald workload archive does not match its installed manifest"
            )
        }
        return VerifiedJournaldWorkloadAssetsV1(
            archiveURL: archiveURL,
            manifestURL: manifestURL,
            manifest: manifest,
            planDigest: "sha256:\(sha256Hex(manifestData))"
        )
    }

    private static func verifySecureRegularFile(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        guard canonical.isFileURL else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "installed journald asset is not a file URL"
            )
        }
        let values = try canonical.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: canonical.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let permissions,
            permissions & 0o022 == 0
        else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "installed journald asset is not a protected regular file"
            )
        }
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowercaseHex)
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.hasPrefix("sha256:")
            && isSHA256Hex(String(value.dropFirst("sha256:".count)))
    }

    private static func isLowercaseHex(_ value: UInt8) -> Bool {
        (value >= 48 && value <= 57) || (value >= 97 && value <= 102)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

package struct VerifiedJournaldWorkloadAssetsV1: Equatable, Sendable {
    package let archiveURL: URL
    package let manifestURL: URL
    package let manifest: InstalledJournaldWorkloadManifestV1
    package let planDigest: String
}

package struct EngineLinuxSandboxJournaldWorkloadMaterializationV1: Sendable {
    package let workloadRoot: URL
    package let planDigest: String
}

package protocol EngineLinuxSandboxJournaldWorkloadMaterializingV1: Sendable {
    func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    func workload(
        sandboxGeneration: UInt64
    ) async throws -> EngineLinuxSandboxJournaldWorkloadMaterializationV1
}

package actor InstalledJournaldWorkloadMaterializerV1:
    EngineLinuxSandboxJournaldWorkloadMaterializingV1
{
    package static let workloadID = "container-journald-service"
    package static let servicePort: UInt32 = 19_530
    package static let protectedRuntimeMounts: [Filesystem] = [
        .tmpfs(
            destination: "/run",
            options: ["nosuid", "nodev", "noexec", "mode=0755"]
        ),
        .tmpfs(
            destination: "/tmp",
            options: ["nosuid", "nodev", "mode=1777"]
        ),
    ]

    private let appRoot: URL
    private let kernelService: KernelService
    private let containerSystemConfig: ContainerSystemConfig
    private let assets: VerifiedJournaldWorkloadAssetsV1
    private var cachedSandboxConfiguration: EngineLinuxSandboxRuntimeConfigurationV1?
    private var cachedImage: ClientImage?
    private var materializedGeneration: UInt64?

    package init(
        appRoot: URL,
        installRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig
    ) throws {
        let serviceRoot =
            installRoot
            .appendingPathComponent("libexec/container/services/journald")
        self.assets = try InstalledJournaldWorkloadManifestV1.verify(
            archiveURL: serviceRoot.appendingPathComponent(
                "container-journald-service.oci.tar"
            ),
            manifestURL: serviceRoot.appendingPathComponent(
                "container-journald-service.manifest.json"
            )
        )
        self.appRoot = appRoot.standardizedFileURL
        self.kernelService = kernelService
        self.containerSystemConfig = containerSystemConfig
    }

    package func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    {
        if let cachedSandboxConfiguration {
            return cachedSandboxConfiguration
        }
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
        let root = appRoot.appendingPathComponent(
            "engine-linux-sandbox",
            isDirectory: true
        )
        try Self.ensureProtectedDirectory(root)
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
        cachedSandboxConfiguration = configuration
        return configuration
    }

    package func workload(
        sandboxGeneration: UInt64
    ) async throws -> EngineLinuxSandboxJournaldWorkloadMaterializationV1 {
        guard sandboxGeneration > 0 else {
            throw EngineLinuxSandboxJournaldServiceError.invalidWorkloadReceipt
        }
        let sandbox = try await sandboxConfiguration()
        let workloadRoot = sandbox.path
            .appendingPathComponent("workloads", isDirectory: true)
            .appendingPathComponent(Self.workloadID, isDirectory: true)
        if materializedGeneration == sandboxGeneration,
            FileManager.default.fileExists(
                atPath:
                    workloadRoot
                    .appendingPathComponent("runtime-configuration.json").path
            )
        {
            return EngineLinuxSandboxJournaldWorkloadMaterializationV1(
                workloadRoot: workloadRoot,
                planDigest: assets.planDigest
            )
        }

        let image = try await exactImage()
        let platform = SystemPlatform.linuxArm.ociPlatform()
        var rootFilesystem = try await image.getCreateSnapshot(
            platform: platform
        )
        rootFilesystem.options = ["ro"]
        let stateRoot =
            appRoot
            .appendingPathComponent("engine-services", isDirectory: true)
            .appendingPathComponent("journald", isDirectory: true)
        try Self.ensureProtectedDirectory(stateRoot)
        let serviceStateRoot = stateRoot.appendingPathComponent(
            "service",
            isDirectory: true
        )
        let journalStateRoot = stateRoot.appendingPathComponent(
            "journal",
            isDirectory: true
        )
        try Self.ensureProtectedDirectory(serviceStateRoot)
        try Self.ensureProtectedDirectory(journalStateRoot)
        try Self.ensureProtectedDirectory(workloadRoot)

        let process = ProcessConfiguration(
            executable: "/usr/local/libexec/container-journald-entrypoint",
            arguments: Self.processArguments(sandboxGeneration: sandboxGeneration),
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            rlimits: [
                .init(limit: "RLIMIT_NOFILE", soft: 65_536, hard: 65_536)
            ]
        )
        var configuration = ContainerConfiguration(
            id: Self.workloadID,
            image: image.description,
            process: process
        )
        configuration.platform = platform
        configuration.mounts =
            [
                .virtiofs(
                    source: serviceStateRoot.path,
                    destination: "/var/lib/container-journald-service",
                    options: []
                ),
                .virtiofs(
                    source: journalStateRoot.path,
                    destination: "/var/log/journal",
                    options: []
                ),
            ] + Self.protectedRuntimeMounts
        configuration.readOnly = true
        configuration.logging = ContainerLogConfiguration(storage: .none)
        configuration.stopSignal = "SIGTERM"
        configuration.stopTimeoutInSeconds = 10
        configuration.creationDate = Date(timeIntervalSince1970: 0)
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 1
        resources.memoryInBytes = 512 * 1_024 * 1_024
        configuration.resources = resources

        let runtime = RuntimeConfiguration(
            path: workloadRoot,
            initialFilesystem: sandbox.initialFilesystem,
            kernel: sandbox.kernel,
            containerConfiguration: configuration,
            containerRootFilesystem: rootFilesystem
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(runtime).write(
            to: runtime.runtimeConfigurationPath,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: runtime.runtimeConfigurationPath.path
        )
        materializedGeneration = sandboxGeneration
        return EngineLinuxSandboxJournaldWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: assets.planDigest
        )
    }

    package static func processArguments(sandboxGeneration: UInt64) -> [String] {
        [
            "--sandbox-generation", "\(sandboxGeneration)",
            "--port", "\(Self.servicePort)",
            EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
        ]
    }

    private func exactImage() async throws -> ClientImage {
        if let cachedImage {
            return cachedImage
        }
        let installed = try await ClientImage.list()
        if let existing = try await Self.exactImage(
            in: installed,
            manifestDigest: assets.manifest.workloadManifestDigest
        ) {
            cachedImage = existing
            return existing
        }
        let loaded = try await ClientImage.load(from: assets.archiveURL.path)
        guard loaded.rejectedMembers.isEmpty else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "journald OCI archive contained rejected members"
            )
        }
        guard
            let image = try await Self.exactImage(
                in: loaded.images,
                manifestDigest: assets.manifest.workloadManifestDigest
            )
        else {
            throw EngineLinuxSandboxJournaldServiceError
                .exactWorkloadImageNotFound
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
            let descriptors = index.manifests.filter {
                $0.platform == platform && $0.digest == manifestDigest
            }
            if descriptors.count == 1 {
                matches.append(image)
            }
        }
        guard matches.count <= 1 else {
            throw EngineLinuxSandboxJournaldServiceError.invalidInstalledAsset(
                "multiple installed images claim the journald workload manifest"
            )
        }
        return matches.first
    }

    private static func ensureProtectedDirectory(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: canonical.path) {
            let values = try canonical.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard
                values.isDirectory == true,
                values.isSymbolicLink != true,
                canonical.path
                    == canonical.resolvingSymlinksInPath()
                    .standardizedFileURL.path
            else {
                throw
                    EngineLinuxSandboxJournaldServiceError
                    .invalidInstalledAsset(
                        "journald state path is not a protected directory"
                    )
            }
        } else {
            try manager.createDirectory(
                at: canonical,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try canonical.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            canonical.path
                == canonical.resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw
                EngineLinuxSandboxJournaldServiceError
                .invalidInstalledAsset(
                    "journald state path is not a protected directory"
                )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: canonical.path
        )
    }
}

package protocol EngineLinuxSandboxJournaldAuthorityV1: Sendable {
    func ensureReady(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> EngineLinuxSandboxRecordV1
    func startWorkload(
        planDigest: String,
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String],
        networkEndpoints: [WorkloadNetworkEndpoint],
        stdio: [FileHandle?],
        controllers: [any WorkloadEffectControllerV1],
        monitorTerminal: Bool
    ) async throws -> EngineWorkloadRecordV1
    func dialService(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) async throws -> FileHandle
}

extension EngineLinuxSandboxAuthorityV1:
    EngineLinuxSandboxJournaldAuthorityV1
{}

package actor EngineLinuxSandboxJournaldConnectorV1 {
    private static let readinessTimeout: Duration = .seconds(10)
    private static let retryDelay: Duration = .milliseconds(50)

    private let authority: any EngineLinuxSandboxJournaldAuthorityV1
    private let materializer: any EngineLinuxSandboxJournaldWorkloadMaterializingV1

    package init(
        authority: any EngineLinuxSandboxJournaldAuthorityV1,
        materializer: any EngineLinuxSandboxJournaldWorkloadMaterializingV1
    ) {
        self.authority = authority
        self.materializer = materializer
    }

    package func connect() async throws -> FileHandle {
        try Task.checkCancellation()
        let configuration = try await materializer.sandboxConfiguration()
        let ready = try await authority.ensureReady(
            configuration: configuration
        )
        guard ready.state == .ready, ready.generation > 0 else {
            throw EngineLinuxSandboxJournaldServiceError.invalidWorkloadReceipt
        }
        let materialized = try await materializer.workload(
            sandboxGeneration: ready.generation
        )
        let diagnosticStdio = try EngineLinuxSandboxServiceDiagnosticsV1.stdio(
            workloadRoot: materialized.workloadRoot
        )
        defer {
            for handle in diagnosticStdio.compactMap({ $0 }) {
                try? handle.close()
            }
        }
        let running = try await authority.startWorkload(
            planDigest: materialized.planDigest,
            configuration: configuration,
            workloadRoot: materialized.workloadRoot,
            dynamicEnvironment: [:],
            networkEndpoints: [],
            stdio: diagnosticStdio,
            controllers: [],
            monitorTerminal: true
        )
        guard
            running.containerID
                == InstalledJournaldWorkloadMaterializerV1.workloadID,
            running.state == .running,
            let processGeneration = running.activeProcessGeneration,
            running.activeSandboxGeneration == ready.generation
        else {
            throw EngineLinuxSandboxJournaldServiceError.invalidWorkloadReceipt
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.readinessTimeout)
        while true {
            try Task.checkCancellation()
            do {
                let handle = try await authority.dialService(
                    configuration: configuration,
                    workloadID: running.containerID,
                    workloadProcessGeneration: processGeneration,
                    port: InstalledJournaldWorkloadMaterializerV1.servicePort
                )
                do {
                    try await Self.verifyGeneration(
                        on: handle,
                        expected: ready.generation
                    )
                    return handle
                } catch {
                    try? handle.close()
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard clock.now < deadline else {
                    throw ContainerizationError(
                        .internalError,
                        message: "journald logging service readiness timed out",
                        cause: error
                    )
                }
                try await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    package static func verifyGeneration(
        on handle: FileHandle,
        expected: UInt64
    ) async throws {
        let request =
            try JournaldServiceWireRequestV1
            .activeSandboxGeneration()
        let response = try await Task.detached {
            try JournaldServiceFrameCodecV1.write(request, to: handle)
            return try JournaldServiceFrameCodecV1.read(
                JournaldServiceWireResponseV1.self,
                from: handle
            )
        }.value
        guard
            response.operationID == request.operationID,
            response.failure == nil,
            let actual = response.sandboxGeneration
        else {
            throw JournaldServiceWireError.invalidEnvelope
        }
        guard actual == expected else {
            throw EngineLinuxSandboxJournaldServiceError.generationMismatch(
                expected: expected,
                actual: actual
            )
        }
    }
}

/// Production journald client composition. Installed release assets are
/// verified before the driver enters the catalog; the VM and workload remain
/// lazy until the first provider operation.
public enum EngineLinuxSandboxJournaldServiceV1 {
    public static func create(
        appRoot: URL,
        installRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig,
        authority: EngineLinuxSandboxAuthorityV1
    ) throws -> any JournaldService {
        let materializer = try InstalledJournaldWorkloadMaterializerV1(
            appRoot: appRoot,
            installRoot: installRoot,
            kernelService: kernelService,
            containerSystemConfig: containerSystemConfig
        )
        let connector = EngineLinuxSandboxJournaldConnectorV1(
            authority: authority,
            materializer: materializer
        )
        let transport = JournaldServiceFileHandleTransportV1 {
            try await connector.connect()
        }
        return JournaldServiceWireClientV1(transport: transport)
    }
}
