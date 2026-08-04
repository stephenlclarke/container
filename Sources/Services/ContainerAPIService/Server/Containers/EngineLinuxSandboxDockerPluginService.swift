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
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import CryptoKit
import Darwin
import Foundation

public enum EngineLinuxSandboxDockerPluginServiceError: Error, Equatable,
    Sendable
{
    case invalidInstalledAsset(String)
    case exactWorkloadImageNotFound
    case invalidWorkloadReceipt
    case readinessTimedOut
    case generationMismatch(expected: UInt64, actual: UInt64)
}

/// Immutable, operator-installed Docker logging-plugin workload generation.
///
/// Plugin distribution and approval remain plugin-manager responsibilities.
/// Container accepts only a protected, digest-pinned Linux arm64 workload that
/// embeds the lifecycle service entrypoint and the approved plugin in one
/// namespace. This keeps the plugin Unix socket private to that workload.
package struct InstalledDockerPluginWorkloadManifestV1: Decodable, Equatable,
    Sendable
{
    package static let manifestFilename =
        "container-docker-logging-plugin.manifest.json"
    package static let archiveFilename =
        "container-docker-logging-plugin.oci.tar"
    package static let expectedSchemaVersion: UInt32 = 1
    package static let expectedProtocolVersion: UInt32 = 1
    package static let expectedServiceVersion = "1"

    package let schemaVersion: UInt32
    package let protocolVersion: UInt32
    package let serviceVersion: String
    package let driver: String
    package let aliases: [String]
    package let providerID: String
    package let providerVersion: String
    package let providerGeneration: UInt64
    package let readLogs: Bool
    package let servicePort: UInt32
    package let pluginSocket: String
    package let architecture: String
    package let platform: String
    package let ociArchiveSHA256: String
    package let serviceSourceSHA256: String
    package let workloadManifestDigest: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case protocolVersion
        case serviceVersion
        case driver
        case aliases
        case providerID
        case providerVersion
        case providerGeneration
        case readLogs
        case servicePort
        case pluginSocket
        case architecture
        case platform
        case ociArchiveSHA256
        case serviceSourceSHA256
        case workloadManifestDigest
    }

    package static func verify(
        resourceRoot: URL
    ) throws -> VerifiedDockerPluginWorkloadAssetsV1 {
        let canonicalRoot = resourceRoot.standardizedFileURL
        try verifyProtectedDirectory(canonicalRoot)
        let archiveURL = canonicalRoot.appendingPathComponent(archiveFilename)
        let manifestURL = canonicalRoot.appendingPathComponent(manifestFilename)
        try verifySecureRegularFile(archiveURL)
        try verifySecureRegularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        try rejectUnknownManifestKeys(manifestData)
        let manifest = try JSONDecoder().decode(Self.self, from: manifestData)
        let identity = LogDriverProviderIdentity(
            id: manifest.providerID,
            version: manifest.providerVersion,
            kind: .dockerPlugin
        )
        _ = try DockerPluginLogDriverContract.descriptor(
            driver: manifest.driver,
            aliases: manifest.aliases,
            providerIdentity: identity,
            providerGeneration: manifest.providerGeneration,
            readLogs: manifest.readLogs,
            trust: .approved
        )
        guard
            manifest.schemaVersion == expectedSchemaVersion,
            manifest.protocolVersion == expectedProtocolVersion,
            manifest.serviceVersion == expectedServiceVersion,
            manifest.architecture == "arm64",
            manifest.platform == "linux",
            manifest.providerGeneration > 0,
            manifest.servicePort >= 20_000,
            manifest.servicePort <= 60_999,
            isBoundedText(manifest.providerVersion, maximumBytes: 128),
            isSafeGuestSocket(manifest.pluginSocket),
            isSHA256Hex(manifest.ociArchiveSHA256),
            isSHA256Hex(manifest.serviceSourceSHA256),
            isSHA256Digest(manifest.workloadManifestDigest)
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin manifest has an unsupported or malformed contract"
                )
        }
        guard try sha256Hex(of: archiveURL) == manifest.ociArchiveSHA256 else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin archive does not match its manifest"
                )
        }
        return VerifiedDockerPluginWorkloadAssetsV1(
            archiveURL: archiveURL,
            manifestURL: manifestURL,
            manifest: manifest,
            planDigest: "sha256:\(sha256Hex(manifestData))"
        )
    }

    package static func workloadID(
        providerID: String,
        providerGeneration: UInt64
    ) -> String {
        let material = Data(
            "docker-plugin-workload-v1\u{0}\(providerID)\u{0}\(providerGeneration)"
                .utf8
        )
        let suffix = SHA256.hash(data: material).prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
        return "container-docker-log-\(suffix)"
    }

    private static func rejectUnknownManifestKeys(_ data: Data) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin manifest fields are incomplete or unknown"
                )
        }
    }

    private static func verifyProtectedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .uint16Value
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
            let permissions,
            permissions & 0o022 == 0
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin resource root is not protected"
                )
        }
    }

    private static func verifySecureRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .uint16Value
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let permissions,
            permissions & 0o022 == 0
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin asset is not a protected regular file"
                )
        }
    }

    private static func isBoundedText(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    private static func isSafeGuestSocket(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096 else { return false }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        return value.hasPrefix("/run/docker/plugins/")
            && value != "/run/docker/plugins/" && url.path == value
            && !value.split(separator: "/").contains("..")
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.hasPrefix("sha256:")
            && isSHA256Hex(String(value.dropFirst("sha256:".count)))
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

package struct VerifiedDockerPluginWorkloadAssetsV1: Equatable, Sendable {
    package let archiveURL: URL
    package let manifestURL: URL
    package let manifest: InstalledDockerPluginWorkloadManifestV1
    package let planDigest: String

    package var workloadID: String {
        InstalledDockerPluginWorkloadManifestV1.workloadID(
            providerID: manifest.providerID,
            providerGeneration: manifest.providerGeneration
        )
    }
}

package struct EngineLinuxSandboxDockerPluginWorkloadMaterializationV1:
    Sendable
{
    package let workloadRoot: URL
    package let planDigest: String
}

package protocol EngineLinuxSandboxDockerPluginWorkloadMaterializingV1:
    Sendable
{
    var assets: VerifiedDockerPluginWorkloadAssetsV1 { get }
    var authenticationKey: Data { get }
    func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    func workload(
        sandboxGeneration: UInt64
    ) async throws -> EngineLinuxSandboxDockerPluginWorkloadMaterializationV1
}

package actor InstalledDockerPluginWorkloadMaterializerV1:
    EngineLinuxSandboxDockerPluginWorkloadMaterializingV1
{
    package nonisolated let assets: VerifiedDockerPluginWorkloadAssetsV1
    package nonisolated let authenticationKey: Data

    private let appRoot: URL
    private let stateRoot: URL
    private let kernelService: KernelService
    private let containerSystemConfig: ContainerSystemConfig
    private var cachedSandboxConfiguration: EngineLinuxSandboxRuntimeConfigurationV1?
    private var cachedImage: ClientImage?
    private var materializedGeneration: UInt64?

    package init(
        appRoot: URL,
        resourceRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig
    ) throws {
        let assets = try InstalledDockerPluginWorkloadManifestV1.verify(
            resourceRoot: resourceRoot
        )
        let appRoot = appRoot.standardizedFileURL
        let stateRoot =
            appRoot
            .appendingPathComponent("engine-services", isDirectory: true)
            .appendingPathComponent("docker-plugins", isDirectory: true)
            .appendingPathComponent(assets.workloadID, isDirectory: true)
        try Self.ensureProtectedDirectory(stateRoot)
        let authenticationKey = try Self.loadOrCreateAuthenticationKey(
            at: stateRoot.appendingPathComponent("authentication.key")
        )
        self.assets = assets
        self.appRoot = appRoot
        self.stateRoot = stateRoot
        self.authenticationKey = authenticationKey
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
    ) async throws -> EngineLinuxSandboxDockerPluginWorkloadMaterializationV1 {
        guard sandboxGeneration > 0 else {
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
        let sandbox = try await sandboxConfiguration()
        let workloadRoot = sandbox.path
            .appendingPathComponent("workloads", isDirectory: true)
            .appendingPathComponent(assets.workloadID, isDirectory: true)
        if materializedGeneration == sandboxGeneration,
            FileManager.default.fileExists(
                atPath:
                    workloadRoot
                    .appendingPathComponent("runtime-configuration.json").path
            )
        {
            return EngineLinuxSandboxDockerPluginWorkloadMaterializationV1(
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
        try Self.ensureProtectedDirectory(stateRoot)
        try Self.ensureProtectedDirectory(workloadRoot)

        let manifest = assets.manifest
        let descriptor = try DockerPluginLogDriverContract.descriptor(
            driver: manifest.driver,
            aliases: manifest.aliases,
            providerIdentity: LogDriverProviderIdentity(
                id: manifest.providerID,
                version: manifest.providerVersion,
                kind: .dockerPlugin
            ),
            providerGeneration: manifest.providerGeneration,
            readLogs: manifest.readLogs,
            trust: .approved
        )
        let process = ProcessConfiguration(
            executable:
                "/usr/local/libexec/container-docker-plugin-entrypoint",
            arguments: [
                "--sandbox-generation", "\(sandboxGeneration)",
                "--provider-id", manifest.providerID,
                "--provider-generation", "\(manifest.providerGeneration)",
                "--contract-digest", descriptor.optionContractDigest,
                "--plugin-socket", manifest.pluginSocket,
                "--expected-read-logs", manifest.readLogs ? "true" : "false",
                "--port", "\(manifest.servicePort)",
                "--authentication-key-file",
                "/var/lib/container-docker-plugin-service/authentication.key",
            ],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            rlimits: [
                .init(limit: "RLIMIT_NOFILE", soft: 65_536, hard: 65_536)
            ]
        )
        var configuration = ContainerConfiguration(
            id: assets.workloadID,
            image: image.description,
            process: process
        )
        configuration.platform = platform
        configuration.mounts = Self.serviceMounts(stateRoot: stateRoot)
        configuration.readOnly = true
        configuration.hostNetwork = true
        configuration.logging = ContainerLogConfiguration(storage: .none)
        configuration.stopSignal = "SIGTERM"
        configuration.stopTimeoutInSeconds = 10
        configuration.creationDate = Date(timeIntervalSince1970: 0)
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 1
        resources.memoryInBytes = 256 * 1_024 * 1_024
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
        return EngineLinuxSandboxDockerPluginWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: assets.planDigest
        )
    }

    package static func serviceMounts(stateRoot: URL) -> [Filesystem] {
        [
            .virtiofs(
                source: stateRoot.path,
                destination: "/var/lib/container-docker-plugin-service",
                options: []
            ),
            .tmpfs(
                destination: "/run",
                options: ["nosuid", "nodev", "noexec", "mode=0755"]
            ),
            .tmpfs(
                destination: "/tmp",
                options: ["nosuid", "nodev", "mode=1777"]
            ),
        ]
    }

    private func exactImage() async throws -> ClientImage {
        if let cachedImage { return cachedImage }
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
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin OCI archive contained rejected members"
                )
        }
        guard
            let image = try await Self.exactImage(
                in: loaded.images,
                manifestDigest: assets.manifest.workloadManifestDigest
            )
        else {
            throw EngineLinuxSandboxDockerPluginServiceError
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
            guard let index = try? await image.index() else { continue }
            let descriptors = index.manifests.filter {
                $0.platform == platform && $0.digest == manifestDigest
            }
            if descriptors.count == 1 { matches.append(image) }
        }
        guard matches.count <= 1 else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "multiple images claim the Docker logging-plugin workload manifest"
                )
        }
        return matches.first
    }

    private static func ensureProtectedDirectory(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        let manager = FileManager.default
        if !manager.fileExists(atPath: canonical.path) {
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
            canonical.resolvingSymlinksInPath().standardizedFileURL.path
                == canonical.path
        else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "Docker logging-plugin state path is not protected"
                )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: canonical.path
        )
    }

    package static func loadOrCreateAuthenticationKey(at url: URL) throws
        -> Data
    {
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            if descriptor >= 0 {
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard
                    fstat(descriptor, &status) == 0,
                    status.st_mode & S_IFMT == S_IFREG,
                    status.st_mode & 0o077 == 0,
                    status.st_size == 32
                else {
                    throw
                        EngineLinuxSandboxDockerPluginServiceError
                        .invalidInstalledAsset(
                            "Docker logging-plugin authentication key is not protected"
                        )
                }
                var key = Data(count: 32)
                let count = try key.withUnsafeMutableBytes { bytes in
                    try readExactly(
                        descriptor: descriptor,
                        buffer: bytes
                    )
                }
                guard count == 32 else {
                    throw
                        EngineLinuxSandboxDockerPluginServiceError
                        .invalidInstalledAsset(
                            "Docker logging-plugin authentication key is incomplete"
                        )
                }
                return key
            }
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var generated = Data(count: 32)
            generated.withUnsafeMutableBytes { bytes in
                arc4random_buf(bytes.baseAddress, bytes.count)
            }
            let created = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            if created < 0 {
                guard errno == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                continue
            }
            do {
                try generated.withUnsafeBytes { bytes in
                    try writeExactly(descriptor: created, buffer: bytes)
                }
                guard fsync(created) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                Darwin.close(created)
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            Darwin.close(created)
            let directory = Darwin.open(
                url.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directory >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return generated
        }
    }

    private static func readExactly(
        descriptor: Int32,
        buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                buffer.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { return offset }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
        return offset
    }

    private static func writeExactly(
        descriptor: Int32,
        buffer: UnsafeRawBufferPointer
    ) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                buffer.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
    }
}

package protocol EngineLinuxSandboxDockerPluginAuthorityV1: Sendable {
    func snapshot() async -> EngineWorkloadLedgerSnapshotV1
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
    func stopWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1
}

extension EngineLinuxSandboxAuthorityV1:
    EngineLinuxSandboxDockerPluginAuthorityV1
{}

package actor EngineLinuxSandboxDockerPluginConnectorV1 {
    private static let readinessTimeout: Duration = .seconds(10)
    private static let retryDelay: Duration = .milliseconds(50)

    private let authority: any EngineLinuxSandboxDockerPluginAuthorityV1
    private let materializer: any EngineLinuxSandboxDockerPluginWorkloadMaterializingV1

    package init(
        authority: any EngineLinuxSandboxDockerPluginAuthorityV1,
        materializer:
            any EngineLinuxSandboxDockerPluginWorkloadMaterializingV1
    ) {
        self.authority = authority
        self.materializer = materializer
    }

    package func connect() async throws -> FileHandle {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.readinessTimeout)
        while true {
            try Task.checkCancellation()
            do {
                return try await connectOnce()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard clock.now < deadline else {
                    throw ContainerizationError(
                        .internalError,
                        message: "Docker logging plugin service readiness timed out",
                        cause: error
                    )
                }
                try await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    private func connectOnce() async throws -> FileHandle {
        let configuration = try await materializer.sandboxConfiguration()
        let ready = try await authority.ensureReady(
            configuration: configuration
        )
        guard ready.state == .ready, ready.generation > 0 else {
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
        let materialized = try await materializer.workload(
            sandboxGeneration: ready.generation
        )
        let assets = materializer.assets
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
            running.containerID == assets.workloadID,
            running.state == .running,
            let processGeneration = running.activeProcessGeneration,
            running.activeSandboxGeneration == ready.generation
        else {
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
        let handle = try await authority.dialService(
            configuration: configuration,
            workloadID: running.containerID,
            workloadProcessGeneration: processGeneration,
            port: assets.manifest.servicePort
        )
        do {
            try await Self.verifyGeneration(
                on: handle,
                expected: ready.generation,
                authenticationKey: materializer.authenticationKey
            )
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    package static func verifyGeneration(
        on handle: FileHandle,
        expected: UInt64,
        authenticationKey: Data
    ) async throws {
        let request =
            try DockerPluginLifecycleServiceWireRequestV1
            .generation().authenticated(using: authenticationKey)
        let response = try await Task.detached {
            try DockerPluginLifecycleServiceFrameCodecV1.write(
                request,
                to: handle
            )
            return try DockerPluginLifecycleServiceFrameCodecV1.read(
                DockerPluginLifecycleServiceWireResponseV1.self,
                from: handle
            )
        }.value
        guard
            response.operationID == request.operationID,
            response.failure == nil,
            let actual = response.sandboxGeneration
        else {
            throw DockerPluginLifecycleServiceWireError.invalidEnvelope
        }
        guard actual == expected else {
            throw
                EngineLinuxSandboxDockerPluginServiceError
                .generationMismatch(expected: expected, actual: actual)
        }
    }
}

package actor EngineLinuxSandboxDockerPluginGenerationReclaimerV1:
    DockerPluginProviderGenerationReclaiming
{
    private let authority: any EngineLinuxSandboxDockerPluginAuthorityV1
    private let materializer: any EngineLinuxSandboxDockerPluginWorkloadMaterializingV1

    package init(
        authority: any EngineLinuxSandboxDockerPluginAuthorityV1,
        materializer:
            any EngineLinuxSandboxDockerPluginWorkloadMaterializingV1
    ) {
        self.authority = authority
        self.materializer = materializer
    }

    package func isProviderGenerationReclaimed(
        _ request: LogDriverProviderGenerationReclaimV1
    ) async throws -> Bool {
        try validate(request)
        let workloadID = materializer.assets.workloadID
        guard
            let workload = await authority.snapshot().workloads.first(
                where: { $0.containerID == workloadID }
            )
        else {
            return true
        }
        switch workload.state {
        case .stopped, .removed:
            return true
        case .running, .paused, .stopping:
            return false
        case .created, .starting, .pausing, .resuming, .removing,
            .recoveryRequired:
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
    }

    package func reclaimProviderGeneration(
        _ request: LogDriverProviderGenerationReclaimV1
    ) async throws {
        try validate(request)
        let assets = materializer.assets
        guard
            let workload = await authority.snapshot().workloads.first(
                where: { $0.containerID == assets.workloadID }
            )
        else {
            return
        }
        if workload.state == .stopped || workload.state == .removed {
            return
        }
        guard
            workload.state == .running || workload.state == .paused
                || workload.state == .stopping,
            let processGeneration = workload.activeProcessGeneration
        else {
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
        let configuration = try await materializer.sandboxConfiguration()
        let stopped = try await authority.stopWorkload(
            configuration: configuration,
            workloadID: assets.workloadID,
            workloadProcessGeneration: processGeneration
        )
        guard stopped.state == .stopped else {
            throw EngineLinuxSandboxDockerPluginServiceError
                .invalidWorkloadReceipt
        }
    }

    private func validate(
        _ request: LogDriverProviderGenerationReclaimV1
    ) throws {
        let manifest = materializer.assets.manifest
        guard
            request.providerID == manifest.providerID,
            request.providerGeneration == manifest.providerGeneration
        else {
            throw LogDriverProviderGenerationReclaimError.invalidRequest
        }
    }
}

/// Production composition for one operator-approved plugin bundle.
public enum EngineLinuxSandboxDockerPluginServiceV1 {
    public static func create(
        appRoot: URL,
        resourceRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig,
        authority: EngineLinuxSandboxAuthorityV1
    ) throws -> DockerPluginLogDriverInstallation {
        let materializer = try InstalledDockerPluginWorkloadMaterializerV1(
            appRoot: appRoot,
            resourceRoot: resourceRoot,
            kernelService: kernelService,
            containerSystemConfig: containerSystemConfig
        )
        let assets = materializer.assets
        let connector = EngineLinuxSandboxDockerPluginConnectorV1(
            authority: authority,
            materializer: materializer
        )
        let generationReclaimer =
            EngineLinuxSandboxDockerPluginGenerationReclaimerV1(
                authority: authority,
                materializer: materializer
            )
        let transport = try DockerPluginLifecycleServiceFileHandleTransportV1(
            authenticationKey: materializer.authenticationKey
        ) {
            try await connector.connect()
        }
        let service = DockerPluginLifecycleServiceWireClientV1(
            expectedReadLogs: assets.manifest.readLogs,
            transport: transport
        )
        return DockerPluginLogDriverInstallation(
            driver: assets.manifest.driver,
            aliases: assets.manifest.aliases,
            providerIdentity: LogDriverProviderIdentity(
                id: assets.manifest.providerID,
                version: assets.manifest.providerVersion,
                kind: .dockerPlugin
            ),
            providerGeneration: assets.manifest.providerGeneration,
            readLogs: assets.manifest.readLogs,
            trust: .approved,
            lifecycleService: service,
            generationReclaimer: generationReclaimer
        )
    }
}
