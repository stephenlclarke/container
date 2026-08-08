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

public enum EngineLinuxSandboxGELFTCPServiceError: Error, Equatable, Sendable {
    case invalidInstalledAsset(String)
    case exactWorkloadImageNotFound
    case invalidWorkloadReceipt
    case readinessTimedOut
    case generationMismatch(expected: UInt64, actual: UInt64)
}

/// The immutable installed workload that makes TCP reset observation happen
/// in Engine Linux. Retry cadence and frame replay remain in `GELFSession`.
package struct InstalledGELFTCPWorkloadManifestV1: Decodable, Equatable, Sendable {
    package static let expectedSchemaVersion: UInt32 = 1
    package static let expectedProtocolVersion: UInt32 = 1
    package static let expectedServiceVersion = "1"
    package static let expectedGoVersion = "go1.25.6"
    package static let expectedBuilderImage =
        "golang:1.25.6-bookworm@sha256:"
        + "f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e"
    package static let expectedRuntimeImage =
        "debian:bookworm-slim@sha256:"
        + "7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818"
    package static let expectedDockerfileFrontend =
        "docker/dockerfile:1.7@sha256:"
        + "a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e"

    package let schemaVersion: UInt32
    package let protocolVersion: UInt32
    package let serviceVersion: String
    package let architecture: String
    package let platform: String
    package let builderImage: String
    package let runtimeImage: String
    package let dockerfileFrontend: String
    package let goVersion: String
    package let ociArchiveSHA256: String
    package let serviceSourceSHA256: String
    package let testSourceSHA256: String
    package let workloadManifestDigest: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case protocolVersion
        case serviceVersion
        case architecture
        case platform
        case builderImage
        case runtimeImage
        case dockerfileFrontend
        case goVersion
        case ociArchiveSHA256
        case serviceSourceSHA256
        case testSourceSHA256
        case workloadManifestDigest
    }

    package static func verify(
        archiveURL: URL,
        manifestURL: URL
    ) throws -> VerifiedGELFTCPWorkloadAssetsV1 {
        try verifySecureRegularFile(archiveURL)
        try verifySecureRegularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        try rejectUnknownManifestKeys(manifestData)
        let manifest = try JSONDecoder().decode(Self.self, from: manifestData)
        guard
            manifest.schemaVersion == expectedSchemaVersion,
            manifest.protocolVersion == expectedProtocolVersion,
            manifest.serviceVersion == expectedServiceVersion,
            manifest.architecture == "arm64",
            manifest.platform == "linux",
            manifest.builderImage == expectedBuilderImage,
            manifest.runtimeImage == expectedRuntimeImage,
            manifest.dockerfileFrontend == expectedDockerfileFrontend,
            manifest.goVersion == expectedGoVersion,
            isSHA256Hex(manifest.ociArchiveSHA256),
            isSHA256Hex(manifest.serviceSourceSHA256),
            isSHA256Hex(manifest.testSourceSHA256),
            isSHA256Digest(manifest.workloadManifestDigest)
        else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "GELF TCP workload manifest has an unsupported or malformed contract"
            )
        }
        guard try sha256Hex(of: archiveURL) == manifest.ociArchiveSHA256 else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "GELF TCP workload archive does not match its installed manifest"
            )
        }
        return VerifiedGELFTCPWorkloadAssetsV1(
            archiveURL: archiveURL,
            manifestURL: manifestURL,
            manifest: manifest,
            planDigest: "sha256:\(sha256Hex(manifestData))"
        )
    }

    private static func rejectUnknownManifestKeys(_ data: Data) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "GELF TCP workload manifest fields are incomplete or unknown"
            )
        }
    }

    private static func verifySecureRegularFile(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        guard canonical.isFileURL else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "installed GELF TCP asset is not a file URL"
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
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "installed GELF TCP asset is not a protected regular file"
            )
        }
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

package struct VerifiedGELFTCPWorkloadAssetsV1: Equatable, Sendable {
    package let archiveURL: URL
    package let manifestURL: URL
    package let manifest: InstalledGELFTCPWorkloadManifestV1
    package let planDigest: String
}

package struct EngineLinuxSandboxGELFTCPWorkloadMaterializationV1: Sendable {
    package let workloadRoot: URL
    package let planDigest: String
}

package protocol EngineLinuxSandboxGELFTCPWorkloadMaterializingV1: Sendable {
    func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    func workload(
        sandboxGeneration: UInt64
    ) async throws -> EngineLinuxSandboxGELFTCPWorkloadMaterializationV1
}

/// The minimum host-side inputs needed to configure the shared Engine-Linux
/// sandbox. Keeping this value boundary free of XPC objects makes the
/// materialization policy independently verifiable.
package struct EngineLinuxSandboxGELFTCPBootstrapV1: Sendable {
    package let initialFilesystem: Filesystem
    package let kernel: Kernel
    package let cpus: Int
    package let memoryInBytes: UInt64
}

/// The exact pinned guest image selected for the sealed TCP relay workload.
package struct EngineLinuxSandboxGELFTCPWorkloadImageV1: Sendable {
    package let image: ImageDescription
    package let rootFilesystem: Filesystem
}

/// Resolves the host-XPC objects at the boundary, leaving protected-path,
/// caching, plan construction, and generation semantics in the materializer.
package protocol EngineLinuxSandboxGELFTCPWorkloadResolvingV1: Sendable {
    func sandboxBootstrap() async throws -> EngineLinuxSandboxGELFTCPBootstrapV1
    func workloadImage(
        archiveURL: URL,
        manifestDigest: String
    ) async throws -> EngineLinuxSandboxGELFTCPWorkloadImageV1
}

package actor InstalledGELFTCPWorkloadMaterializerV1:
    EngineLinuxSandboxGELFTCPWorkloadMaterializingV1
{
    package static let workloadID = "container-gelf-service"
    package static let servicePort: UInt32 = 19_532
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
    private let assets: VerifiedGELFTCPWorkloadAssetsV1
    private let resolver: any EngineLinuxSandboxGELFTCPWorkloadResolvingV1
    private var cachedSandboxConfiguration: EngineLinuxSandboxRuntimeConfigurationV1?
    private var cachedImage: EngineLinuxSandboxGELFTCPWorkloadImageV1?
    private var materializedGeneration: UInt64?

    package init(
        appRoot: URL,
        installRoot: URL,
        resolver: any EngineLinuxSandboxGELFTCPWorkloadResolvingV1
    ) throws {
        let serviceRoot = installRoot.appendingPathComponent(
            "libexec/container/services/gelf"
        )
        self.init(
            appRoot: appRoot,
            assets: try InstalledGELFTCPWorkloadManifestV1.verify(
                archiveURL: serviceRoot.appendingPathComponent(
                    "container-gelf-service.oci.tar"
                ),
                manifestURL: serviceRoot.appendingPathComponent(
                    "container-gelf-service.manifest.json"
                )
            ),
            resolver: resolver
        )
    }

    package init(
        appRoot: URL,
        assets: VerifiedGELFTCPWorkloadAssetsV1,
        resolver: any EngineLinuxSandboxGELFTCPWorkloadResolvingV1
    ) {
        self.appRoot = appRoot.standardizedFileURL
        self.assets = assets
        self.resolver = resolver
    }

    package func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    {
        if let cachedSandboxConfiguration {
            return cachedSandboxConfiguration
        }
        let bootstrap = try await resolver.sandboxBootstrap()
        var initialFilesystem = bootstrap.initialFilesystem
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
            kernel: bootstrap.kernel,
            cpus: max(1, bootstrap.cpus),
            memoryInBytes: max(
                512 * 1_024 * 1_024,
                bootstrap.memoryInBytes
            )
        )
        try configuration.validate(expectedPath: root)
        cachedSandboxConfiguration = configuration
        return configuration
    }

    package func workload(
        sandboxGeneration: UInt64
    ) async throws -> EngineLinuxSandboxGELFTCPWorkloadMaterializationV1 {
        guard sandboxGeneration > 0 else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidWorkloadReceipt
        }
        let sandbox = try await sandboxConfiguration()
        let workloadRoot = sandbox.path
            .appendingPathComponent("workloads", isDirectory: true)
            .appendingPathComponent(Self.workloadID, isDirectory: true)
        if materializedGeneration == sandboxGeneration,
            FileManager.default.fileExists(
                atPath: workloadRoot.appendingPathComponent(
                    "runtime-configuration.json"
                ).path
            )
        {
            return EngineLinuxSandboxGELFTCPWorkloadMaterializationV1(
                workloadRoot: workloadRoot,
                planDigest: assets.planDigest
            )
        }

        let image = try await exactImage()
        var rootFilesystem = image.rootFilesystem
        rootFilesystem.options = ["ro"]
        try Self.ensureProtectedDirectory(workloadRoot)
        try Self.ensureProtectedDirectory(
            EngineLinuxSandboxServiceEndpointV1.relayBaseDirectory
        )
        try Self.ensureProtectedDirectory(
            EngineLinuxSandboxServiceEndpointV1.relayDirectory(
                sandboxRoot: sandbox.path
            )
        )

        let runtime = try Self.runtimeConfiguration(
            workloadRoot: workloadRoot,
            sandbox: sandbox,
            image: image.image,
            rootFilesystem: rootFilesystem,
            sandboxGeneration: sandboxGeneration
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
        return EngineLinuxSandboxGELFTCPWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: assets.planDigest
        )
    }

    /// Builds the deterministic single-process workload plan before the
    /// authority materializes it inside Engine Linux.
    package static func runtimeConfiguration(
        workloadRoot: URL,
        sandbox: EngineLinuxSandboxRuntimeConfigurationV1,
        image: ImageDescription,
        rootFilesystem: Filesystem,
        sandboxGeneration: UInt64
    ) throws -> RuntimeConfiguration {
        let process = ProcessConfiguration(
            executable: "/usr/local/libexec/container-gelf-service",
            arguments: [
                "--sandbox-generation", "\(sandboxGeneration)",
                "--port", "\(Self.servicePort)",
                "--listen-unix",
                EngineLinuxSandboxServiceEndpointV1.relayGuestSocketPath,
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
            id: Self.workloadID,
            image: image,
            process: process
        )
        configuration.platform = SystemPlatform.linuxArm.ociPlatform()
        configuration.mounts = Self.protectedRuntimeMounts
        configuration.readOnly = true
        // This is the only authority-approved host network consumer: it is
        // required to reach the macOS receiver through the guest gateway.
        configuration.hostNetwork = true
        configuration.logging = ContainerLogConfiguration(storage: .none)
        configuration.stopSignal = "SIGTERM"
        configuration.stopTimeoutInSeconds = 10
        configuration.creationDate = Date(timeIntervalSince1970: 0)
        configuration.publishedSockets = [
            try EngineLinuxSandboxServiceEndpointV1.sealedRelaySocket(
                sandboxRoot: sandbox.path,
                port: Self.servicePort
            )
        ]
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 1
        resources.memoryInBytes = 256 * 1_024 * 1_024
        configuration.resources = resources

        return RuntimeConfiguration(
            path: workloadRoot,
            initialFilesystem: sandbox.initialFilesystem,
            kernel: sandbox.kernel,
            containerConfiguration: configuration,
            containerRootFilesystem: rootFilesystem
        )
    }

    private func exactImage() async throws -> EngineLinuxSandboxGELFTCPWorkloadImageV1 {
        if let cachedImage {
            return cachedImage
        }
        let image = try await resolver.workloadImage(
            archiveURL: assets.archiveURL,
            manifestDigest: assets.manifest.workloadManifestDigest
        )
        cachedImage = image
        return image
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
            canonical.path
                == canonical.resolvingSymlinksInPath()
                .standardizedFileURL.path
        else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidInstalledAsset(
                "GELF TCP state path is not protected"
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: canonical.path
        )
    }
}

package protocol EngineLinuxSandboxGELFTCPAuthorityV1: Sendable {
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

extension EngineLinuxSandboxAuthorityV1: EngineLinuxSandboxGELFTCPAuthorityV1 {}

/// Starts the sealed Linux service exactly once per socket request. The GELF
/// session owns reconnect policy and replay, so this connector never retries a
/// remote logging write on its own.
package actor EngineLinuxSandboxGELFTCPConnectorV1 {
    private let authority: any EngineLinuxSandboxGELFTCPAuthorityV1
    private let materializer: any EngineLinuxSandboxGELFTCPWorkloadMaterializingV1
    private let readinessTimeout: Duration
    private let retryDelay: Duration

    package init(
        authority: any EngineLinuxSandboxGELFTCPAuthorityV1,
        materializer: any EngineLinuxSandboxGELFTCPWorkloadMaterializingV1
    ) {
        self.init(
            authority: authority,
            materializer: materializer,
            readinessTimeout: .seconds(10),
            retryDelay: .milliseconds(50)
        )
    }

    package init(
        authority: any EngineLinuxSandboxGELFTCPAuthorityV1,
        materializer: any EngineLinuxSandboxGELFTCPWorkloadMaterializingV1,
        readinessTimeout: Duration,
        retryDelay: Duration
    ) {
        self.authority = authority
        self.materializer = materializer
        self.readinessTimeout = readinessTimeout
        self.retryDelay = retryDelay
    }

    package func connect() async throws -> FileHandle {
        try Task.checkCancellation()
        let configuration = try await materializer.sandboxConfiguration()
        let ready = try await authority.ensureReady(configuration: configuration)
        guard ready.state == .ready, ready.generation > 0 else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidWorkloadReceipt
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
            running.containerID == InstalledGELFTCPWorkloadMaterializerV1.workloadID,
            running.state == .running,
            let processGeneration = running.activeProcessGeneration,
            running.activeSandboxGeneration == ready.generation
        else {
            throw EngineLinuxSandboxGELFTCPServiceError.invalidWorkloadReceipt
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while true {
            try Task.checkCancellation()
            do {
                let handle = try await authority.dialService(
                    configuration: configuration,
                    workloadID: running.containerID,
                    workloadProcessGeneration: processGeneration,
                    port: InstalledGELFTCPWorkloadMaterializerV1.servicePort
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
            } catch let error as EngineLinuxSandboxGELFTCPServiceError {
                // A connected service that fails the identity handshake is not
                // a readiness race. Do not turn a stale or substituted service
                // into a retry loop.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard clock.now < deadline else {
                    throw ContainerizationError(
                        .internalError,
                        message: "GELF TCP logging service readiness timed out",
                        cause: error
                    )
                }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    package static func verifyGeneration(
        on handle: FileHandle,
        expected: UInt64
    ) async throws {
        let actual = try await GELFTCPServiceWireClientV1.activeSandboxGeneration(
            on: handle
        )
        guard actual == expected else {
            throw EngineLinuxSandboxGELFTCPServiceError.generationMismatch(
                expected: expected,
                actual: actual
            )
        }
    }
}

/// Production GELF TCP client composition. Installed release assets are
/// verified before the driver enters the catalog; the sandbox and workload
/// remain lazy until the first TCP GELF provider operation.
public enum EngineLinuxSandboxGELFTCPServiceV1 {
    public static func create(
        appRoot: URL,
        installRoot: URL,
        kernelService: KernelService,
        containerSystemConfig: ContainerSystemConfig,
        authority: EngineLinuxSandboxAuthorityV1
    ) throws -> any GELFTCPService {
        let resolver = EngineLinuxSandboxGELFTCPWorkloadResolverV1(
            kernelService: kernelService,
            containerSystemConfig: containerSystemConfig
        )
        let materializer = try InstalledGELFTCPWorkloadMaterializerV1(
            appRoot: appRoot,
            installRoot: installRoot,
            resolver: resolver
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer
        )
        return GELFTCPServiceWireClientV1 {
            try await connector.connect()
        }
    }
}
