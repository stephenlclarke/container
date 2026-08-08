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

import ContainerLoggingProviders
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ContainerAPIService

struct EngineLinuxSandboxGELFTCPServiceTests {
    @Test
    func readOnlyWorkloadUsesOnlyProtectedRuntimeMounts() {
        let mounts = InstalledGELFTCPWorkloadMaterializerV1
            .protectedRuntimeMounts

        #expect(InstalledGELFTCPWorkloadMaterializerV1.workloadID == "container-gelf-service")
        #expect(InstalledGELFTCPWorkloadMaterializerV1.servicePort == 19_532)
        #expect(mounts.count == 2)
        #expect(mounts[0].isTmpfs)
        #expect(mounts[0].destination == "/run")
        #expect(
            Set(mounts[0].options)
                == ["nosuid", "nodev", "noexec", "mode=0755"]
        )
        #expect(mounts[1].isTmpfs)
        #expect(mounts[1].destination == "/tmp")
        #expect(
            Set(mounts[1].options)
                == ["nosuid", "nodev", "mode=1777"]
        )
    }

    @Test
    func runtimePlanBindsTheServiceToTheExpectedSandboxGeneration() throws {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let image = ImageDescription(
            reference: "example.invalid/container-gelf-service:sealed",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "f", count: 64),
                size: 42
            )
        )
        let rootFilesystem = Filesystem.tmpfs(
            destination: "/",
            options: ["ro"]
        )

        let runtime =
            try InstalledGELFTCPWorkloadMaterializerV1
            .runtimeConfiguration(
                workloadRoot: fixture.workloadRoot,
                sandbox: fixture.configuration,
                image: image,
                rootFilesystem: rootFilesystem,
                sandboxGeneration: 73
            )
        let configuration = try #require(runtime.containerConfiguration)
        let configuredRootFilesystem = try #require(
            runtime.containerRootFilesystem
        )

        #expect(runtime.path == fixture.workloadRoot)
        #expect(runtime.initialFilesystem.destination == "/")
        #expect(runtime.kernel.path == fixture.configuration.kernel.path)
        #expect(configuredRootFilesystem.destination == "/")
        #expect(configuration.id == "container-gelf-service")
        #expect(configuration.image.reference == image.reference)
        #expect(configuration.image.digest == image.digest)
        #expect(
            configuration.initProcess.executable
                == "/usr/local/libexec/container-gelf-service"
        )
        #expect(
            configuration.initProcess.arguments
                == [
                    "--sandbox-generation", "73",
                    "--port", "19532",
                    EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
                ]
        )
        #expect(configuration.publishedSockets.isEmpty)
        #expect(configuration.initProcess.environment.isEmpty)
        #expect(configuration.initProcess.workingDirectory == "/")
        #expect(!configuration.initProcess.terminal)
        #expect(configuration.initProcess.user == .id(uid: 0, gid: 0))
        #expect(
            configuration.initProcess.rlimits.map(\.limit)
                == ["RLIMIT_NOFILE"]
        )
        #expect(
            configuration.initProcess.rlimits.map(\.soft)
                == [65_536]
        )
        #expect(
            configuration.initProcess.rlimits.map(\.hard)
                == [65_536]
        )
        #expect(configuration.platform == SystemPlatform.linuxArm.ociPlatform())
        #expect(
            configuration.mounts.map(\.destination)
                == InstalledGELFTCPWorkloadMaterializerV1.protectedRuntimeMounts
                .map(\.destination)
        )
        #expect(
            configuration.mounts.map { Set($0.options) }
                == InstalledGELFTCPWorkloadMaterializerV1.protectedRuntimeMounts
                .map { Set($0.options) }
        )
        #expect(configuration.readOnly)
        #expect(configuration.hostNetwork)
        #expect(configuration.logging.storage == .none)
        #expect(configuration.stopSignal == "SIGTERM")
        #expect(configuration.stopTimeoutInSeconds == 10)
        #expect(configuration.creationDate == Date(timeIntervalSince1970: 0))
        #expect(configuration.resources.cpus == 1)
        #expect(configuration.resources.memoryInBytes == 256 * 1_024 * 1_024)
    }

    @Test
    func installedManifestBindsTheExactProtectedArchive() throws {
        let fixture = try GELFTCPAssetFixture()
        defer { fixture.remove() }

        let verified = try InstalledGELFTCPWorkloadManifestV1.verify(
            archiveURL: fixture.archiveURL,
            manifestURL: fixture.manifestURL
        )
        #expect(
            verified.manifest.workloadManifestDigest
                == "sha256:" + String(repeating: "b", count: 64)
        )
        #expect(verified.planDigest.hasPrefix("sha256:"))

        try Data("changed".utf8).write(to: fixture.archiveURL)
        #expect(
            throws: EngineLinuxSandboxGELFTCPServiceError.self
        ) {
            _ = try InstalledGELFTCPWorkloadManifestV1.verify(
                archiveURL: fixture.archiveURL,
                manifestURL: fixture.manifestURL
            )
        }
    }

    @Test
    func installedManifestRejectsUnknownFieldsAndAssetLinks() throws {
        let fixture = try GELFTCPAssetFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(extraFields: ["unexpected": true])
        #expect(
            throws: EngineLinuxSandboxGELFTCPServiceError.self
        ) {
            _ = try InstalledGELFTCPWorkloadManifestV1.verify(
                archiveURL: fixture.archiveURL,
                manifestURL: fixture.manifestURL
            )
        }

        try fixture.writeManifest()
        let linkedArchive = fixture.root.appendingPathComponent(
            "linked-container-gelf-service.oci.tar"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedArchive,
            withDestinationURL: fixture.archiveURL
        )
        #expect(
            throws: EngineLinuxSandboxGELFTCPServiceError.self
        ) {
            _ = try InstalledGELFTCPWorkloadManifestV1.verify(
                archiveURL: linkedArchive,
                manifestURL: fixture.manifestURL
            )
        }
    }

    @Test
    func installedManifestRejectsUnpinnedBuildProvenance() throws {
        let fixture = try GELFTCPAssetFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(extraFields: [
            "builderImage": "golang:unverified"
        ])

        #expect(
            throws: EngineLinuxSandboxGELFTCPServiceError.self
        ) {
            _ = try InstalledGELFTCPWorkloadManifestV1.verify(
                archiveURL: fixture.archiveURL,
                manifestURL: fixture.manifestURL
            )
        }
    }

    @Test
    func installedManifestAcceptsTheConfiguredBuildArtifact() throws {
        guard
            let directory = ProcessInfo.processInfo.environment[
                "CONTAINER_GELF_SERVICE_ASSET_DIRECTORY"
            ], !directory.isEmpty
        else {
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let verified = try InstalledGELFTCPWorkloadManifestV1.verify(
            archiveURL: root.appendingPathComponent(
                "container-gelf-service.oci.tar"
            ),
            manifestURL: root.appendingPathComponent(
                "container-gelf-service.manifest.json"
            )
        )

        #expect(
            verified.manifest.builderImage
                == InstalledGELFTCPWorkloadManifestV1.expectedBuilderImage
        )
        #expect(
            verified.manifest.runtimeImage
                == InstalledGELFTCPWorkloadManifestV1.expectedRuntimeImage
        )
        #expect(verified.planDigest.hasPrefix("sha256:"))
    }

    @Test
    func materializerWritesAProtectedDeterministicPlanAndReusesItsImage()
        async throws
    {
        let assets = try GELFTCPAssetFixture()
        defer { assets.remove() }
        let resolver = FakeGELFTCPWorkloadResolver()
        let appRoot = assets.root.appendingPathComponent(
            "app-state",
            isDirectory: true
        )
        let installRoot = try assets.installRoot()
        let materializer = try InstalledGELFTCPWorkloadMaterializerV1(
            appRoot: appRoot,
            installRoot: installRoot,
            resolver: resolver
        )

        let sandbox = try await materializer.sandboxConfiguration()
        #expect(sandbox.path == appRoot.appendingPathComponent("engine-linux-sandbox"))
        #expect(sandbox.initialFilesystem.options == ["ro"])
        #expect(sandbox.cpus == 1)
        #expect(sandbox.memoryInBytes == 512 * 1_024 * 1_024)

        let first = try await materializer.workload(sandboxGeneration: 41)
        let runtime = try RuntimeConfiguration.readRuntimeConfiguration(
            from: first.workloadRoot
        )
        let configuration = try #require(runtime.containerConfiguration)
        let rootFilesystem = try #require(runtime.containerRootFilesystem)
        let configurationPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: runtime.runtimeConfigurationPath.path
            )[.posixPermissions] as? NSNumber
        )

        #expect(
            first.workloadRoot
                == sandbox.path.appendingPathComponent(
                    "workloads/container-gelf-service",
                    isDirectory: true
                ))
        #expect(first.planDigest.hasPrefix("sha256:"))
        #expect(runtime.path == first.workloadRoot)
        #expect(runtime.initialFilesystem.options == ["ro"])
        #expect(rootFilesystem.options == ["ro"])
        #expect(
            configuration.initProcess.arguments == [
                "--sandbox-generation", "41",
                "--port", "19532",
                EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
            ])
        #expect(configuration.publishedSockets.isEmpty)
        #expect(configurationPermissions.uint16Value == 0o600)
        #expect(await resolver.bootstrapCount == 1)
        #expect(await resolver.workloadImageCount == 1)
        #expect(
            await resolver.lastArchiveURL
                == installRoot.appendingPathComponent(
                    "libexec/container/services/gelf/container-gelf-service.oci.tar"
                )
        )
        #expect(
            await resolver.lastManifestDigest
                == "sha256:" + String(repeating: "b", count: 64)
        )

        let cached = try await materializer.workload(sandboxGeneration: 41)
        #expect(cached.workloadRoot == first.workloadRoot)
        #expect(await resolver.bootstrapCount == 1)
        #expect(await resolver.workloadImageCount == 1)

        try FileManager.default.removeItem(at: runtime.runtimeConfigurationPath)
        let rematerialized = try await materializer.workload(sandboxGeneration: 41)
        #expect(rematerialized.workloadRoot == first.workloadRoot)
        #expect(
            FileManager.default.fileExists(
                atPath: runtime.runtimeConfigurationPath.path
            )
        )
        #expect(await resolver.workloadImageCount == 1)

        let nextGeneration = try await materializer.workload(sandboxGeneration: 42)
        let nextRuntime = try RuntimeConfiguration.readRuntimeConfiguration(
            from: nextGeneration.workloadRoot
        )
        let nextConfiguration = try #require(nextRuntime.containerConfiguration)
        #expect(
            nextConfiguration.initProcess.arguments == [
                "--sandbox-generation", "42",
                "--port", "19532",
                EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
            ])
        #expect(await resolver.workloadImageCount == 1)
    }

    @Test
    func materializerRejectsInvalidGenerationAndSymlinkedState() async throws {
        let assets = try GELFTCPAssetFixture()
        defer { assets.remove() }
        let resolver = FakeGELFTCPWorkloadResolver()
        let appRoot = assets.root.appendingPathComponent(
            "unsafe-app-state",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: appRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = assets.root.appendingPathComponent(
            "symlink-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: appRoot.appendingPathComponent("engine-linux-sandbox"),
            withDestinationURL: target
        )
        let materializer = try InstalledGELFTCPWorkloadMaterializerV1(
            appRoot: appRoot,
            installRoot: try assets.installRoot(),
            resolver: resolver
        )

        await #expect(
            throws: EngineLinuxSandboxGELFTCPServiceError.invalidWorkloadReceipt
        ) {
            _ = try await materializer.workload(sandboxGeneration: 0)
        }
        await #expect(throws: EngineLinuxSandboxGELFTCPServiceError.self) {
            _ = try await materializer.sandboxConfiguration()
        }
        #expect(await resolver.bootstrapCount == 1)
        #expect(await resolver.workloadImageCount == 0)
    }

    @Test
    func materializerPropagatesAResolverFailureBeforeWritingState() async throws {
        let assets = try GELFTCPAssetFixture()
        defer { assets.remove() }
        let resolver = FakeGELFTCPWorkloadResolver(failBootstrap: true)
        let appRoot = assets.root.appendingPathComponent(
            "failed-app-state",
            isDirectory: true
        )
        let materializer = try InstalledGELFTCPWorkloadMaterializerV1(
            appRoot: appRoot,
            installRoot: try assets.installRoot(),
            resolver: resolver
        )

        await #expect(throws: ContainerizationError.self) {
            _ = try await materializer.sandboxConfiguration()
        }
        #expect(await resolver.bootstrapCount == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: appRoot.appendingPathComponent("engine-linux-sandbox").path
            )
        )
    }

    @Test
    func connectorStartsAndDialsOnlyTheExactWorkloadGeneration() async throws {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(sandboxGeneration: 7)
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer
        )

        let handle = try await connector.connect()
        try handle.close()
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 1)
        #expect(await authority.lastDialProcessGeneration == 3)
        #expect(await authority.lastStdioCount == 3)
        #expect(await authority.lastStdinWasNil)
        #expect(await authority.lastStdoutWasPresent)
        #expect(await authority.lastStderrWasPresent)
        #expect(await materializer.lastGeneration == 7)
    }

    @Test
    func connectorDoesNotRetryATerminalWorkloadStart() async throws {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 7,
            failStart: true
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer
        )

        await #expect(throws: GELFTCPServiceBootstrapError.serviceStartFailed) {
            _ = try await connector.connect()
        }
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 0)
    }

    @Test
    func connectorRejectsANonReadySandboxBeforeMaterializingAWorkload()
        async throws
    {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 0,
            sandboxState: .absent
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer
        )

        await #expect(throws: GELFTCPServiceBootstrapError.serviceStartFailed) {
            _ = try await connector.connect()
        }
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 0)
        #expect(await authority.dialCount == 0)
        #expect(await materializer.lastGeneration == nil)
    }

    @Test
    func connectorRejectsAMismatchedWorkloadReceiptBeforeDialing()
        async throws
    {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 7,
            reportedWorkloadID: "unexpected-workload"
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer
        )

        await #expect(throws: GELFTCPServiceBootstrapError.serviceStartFailed) {
            _ = try await connector.connect()
        }
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 0)
        #expect(await materializer.lastGeneration == 7)
    }

    @Test
    func connectorRetriesOnlyServiceAvailabilityBeforeVerifyingGeneration()
        async throws
    {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 7,
            transientDialFailures: 1
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer,
            readinessTimeout: .milliseconds(100),
            retryDelay: .milliseconds(1)
        )

        let handle = try await connector.connect()
        try handle.close()
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 2)
        #expect(await materializer.lastGeneration == 7)
    }

    @Test
    func connectorRejectsAStaleServiceIdentityWithoutRetrying() async throws {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 7,
            serviceGeneration: 6
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer,
            readinessTimeout: .seconds(1),
            retryDelay: .milliseconds(1)
        )

        await #expect(
            throws: GELFTCPServiceBootstrapError.serviceIdentityRejected
        ) {
            _ = try await connector.connect()
        }
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 1)
    }

    @Test
    func connectorReturnsATerminalReadinessErrorAfterTheBoundedDialWindow()
        async throws
    {
        let fixture = try GELFTCPConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeGELFTCPAuthority(
            sandboxGeneration: 7,
            transientDialFailures: .max
        )
        let materializer = FakeGELFTCPMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxGELFTCPConnectorV1(
            authority: authority,
            materializer: materializer,
            readinessTimeout: .milliseconds(10),
            retryDelay: .milliseconds(1)
        )

        await #expect(
            throws: GELFTCPServiceBootstrapError.serviceReadinessTimedOut
        ) {
            _ = try await connector.connect()
        }
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount > 0)
    }

    @Test
    func generationProbeRejectsAStaleService() async throws {
        let (client, server) = try gelfTCPServicePair(generation: 6)
        defer { try? client.close() }
        defer { try? server.close() }

        await #expect(
            throws:
                EngineLinuxSandboxGELFTCPServiceError
                .generationMismatch(expected: 7, actual: 6)
        ) {
            try await EngineLinuxSandboxGELFTCPConnectorV1.verifyGeneration(
                on: client,
                expected: 7
            )
        }
    }
}

private struct GELFTCPAssetFixture {
    let root: URL
    let archiveURL: URL
    let manifestURL: URL
    private let archive: Data

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gelf-tcp-assets-\(UUID())",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent(
            "container-gelf-service.oci.tar"
        )
        manifestURL = root.appendingPathComponent(
            "container-gelf-service.manifest.json"
        )
        archive = Data("archive".utf8)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try archive.write(to: archiveURL)
        try writeManifest()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: archiveURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: manifestURL.path
        )
    }

    func writeManifest(extraFields: [String: Any] = [:]) throws {
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": 1,
            "serviceVersion": "1",
            "architecture": "arm64",
            "platform": "linux",
            "builderImage": InstalledGELFTCPWorkloadManifestV1
                .expectedBuilderImage,
            "runtimeImage": InstalledGELFTCPWorkloadManifestV1
                .expectedRuntimeImage,
            "dockerfileFrontend": InstalledGELFTCPWorkloadManifestV1
                .expectedDockerfileFrontend,
            "goVersion": InstalledGELFTCPWorkloadManifestV1.expectedGoVersion,
            "ociArchiveSHA256": Self.sha256(archive),
            "serviceSourceSHA256": String(repeating: "a", count: 64),
            "testSourceSHA256": String(repeating: "c", count: 64),
            "workloadManifestDigest":
                "sha256:" + String(repeating: "b", count: 64),
        ]
        for (key, value) in extraFields {
            manifest[key] = value
        }
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: manifestURL.path
        )
    }

    func installRoot() throws -> URL {
        let installRoot = root.appendingPathComponent(
            "install",
            isDirectory: true
        )
        let serviceRoot = installRoot.appendingPathComponent(
            "libexec/container/services/gelf",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: serviceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let installedArchive = serviceRoot.appendingPathComponent(
            "container-gelf-service.oci.tar"
        )
        let installedManifest = serviceRoot.appendingPathComponent(
            "container-gelf-service.manifest.json"
        )
        try FileManager.default.copyItem(at: archiveURL, to: installedArchive)
        try FileManager.default.copyItem(at: manifestURL, to: installedManifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: installedArchive.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: installedManifest.path
        )
        return installRoot
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct GELFTCPConnectorFixture {
    let root: URL
    let workloadRoot: URL
    let configuration: EngineLinuxSandboxRuntimeConfigurationV1

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gelf-tcp-connector-\(UUID())",
            isDirectory: true
        )
        workloadRoot = root.appendingPathComponent("workload")
        try FileManager.default.createDirectory(
            at: workloadRoot,
            withIntermediateDirectories: true
        )
        configuration = EngineLinuxSandboxRuntimeConfigurationV1(
            path: root,
            sandboxID: "engine-linux-sandbox",
            initialFilesystem: .tmpfs(destination: "/", options: []),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/kernel"),
                platform: .linuxArm
            ),
            cpus: 2,
            memoryInBytes: 1_024 * 1_024 * 1_024
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FakeGELFTCPMaterializer:
    EngineLinuxSandboxGELFTCPWorkloadMaterializingV1
{
    private let configuration: EngineLinuxSandboxRuntimeConfigurationV1
    private let workloadRoot: URL
    private(set) var lastGeneration: UInt64?

    init(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL
    ) {
        self.configuration = configuration
        self.workloadRoot = workloadRoot
    }

    func sandboxConfiguration() -> EngineLinuxSandboxRuntimeConfigurationV1 {
        configuration
    }

    func workload(
        sandboxGeneration: UInt64
    ) -> EngineLinuxSandboxGELFTCPWorkloadMaterializationV1 {
        lastGeneration = sandboxGeneration
        return EngineLinuxSandboxGELFTCPWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: "sha256:" + String(repeating: "c", count: 64)
        )
    }
}

private actor FakeGELFTCPWorkloadResolver:
    EngineLinuxSandboxGELFTCPWorkloadResolvingV1
{
    private let failBootstrap: Bool
    private(set) var bootstrapCount = 0
    private(set) var workloadImageCount = 0
    private(set) var lastArchiveURL: URL?
    private(set) var lastManifestDigest: String?

    init(failBootstrap: Bool = false) {
        self.failBootstrap = failBootstrap
    }

    func sandboxBootstrap() throws -> EngineLinuxSandboxGELFTCPBootstrapV1 {
        bootstrapCount += 1
        if failBootstrap {
            throw ContainerizationError(
                .internalError,
                message: "test bootstrap failure"
            )
        }
        return EngineLinuxSandboxGELFTCPBootstrapV1(
            initialFilesystem: .tmpfs(destination: "/", options: ["rw"]),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/gelf-test-kernel"),
                platform: .linuxArm
            ),
            cpus: 0,
            memoryInBytes: 1
        )
    }

    func workloadImage(
        archiveURL: URL,
        manifestDigest: String
    ) -> EngineLinuxSandboxGELFTCPWorkloadImageV1 {
        workloadImageCount += 1
        lastArchiveURL = archiveURL
        lastManifestDigest = manifestDigest
        return EngineLinuxSandboxGELFTCPWorkloadImageV1(
            image: ImageDescription(
                reference: "example.invalid/container-gelf-service:sealed",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "a", count: 64),
                    size: 42
                )
            ),
            rootFilesystem: .tmpfs(destination: "/", options: ["rw"])
        )
    }
}

private actor FakeGELFTCPAuthority: EngineLinuxSandboxGELFTCPAuthorityV1 {
    private let sandboxGeneration: UInt64
    private let sandboxState: EngineLinuxSandboxStateV1
    private let failStart: Bool
    private let reportedWorkloadID: String
    private let serviceGeneration: UInt64?
    private var transientDialFailures: Int
    private(set) var ensureReadyCount = 0
    private(set) var startCount = 0
    private(set) var dialCount = 0
    private(set) var lastDialProcessGeneration: UInt64?
    private(set) var lastStdioCount = 0
    private(set) var lastStdinWasNil = false
    private(set) var lastStdoutWasPresent = false
    private(set) var lastStderrWasPresent = false

    init(
        sandboxGeneration: UInt64,
        sandboxState: EngineLinuxSandboxStateV1 = .ready,
        failStart: Bool = false,
        reportedWorkloadID: String = "container-gelf-service",
        serviceGeneration: UInt64? = nil,
        transientDialFailures: Int = 0
    ) {
        self.sandboxGeneration = sandboxGeneration
        self.sandboxState = sandboxState
        self.failStart = failStart
        self.reportedWorkloadID = reportedWorkloadID
        self.serviceGeneration = serviceGeneration
        self.transientDialFailures = transientDialFailures
    }

    func ensureReady(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) throws -> EngineLinuxSandboxRecordV1 {
        ensureReadyCount += 1
        _ = configuration
        if sandboxState != .ready {
            return try EngineLinuxSandboxRecordV1(
                sandboxID: "engine-linux-sandbox",
                state: sandboxState
            )
        }
        return try EngineLinuxSandboxRecordV1(
            sandboxID: "engine-linux-sandbox",
            generation: sandboxGeneration,
            revision: 2,
            state: .ready,
            operationKind: .boot,
            idempotencyKey: "boot-key",
            requestDigest: "sha256:" + String(repeating: "d", count: 64),
            effectID: "boot-effect",
            runtimeFingerprint: "sha256:" + String(repeating: "e", count: 64)
        )
    }

    func startWorkload(
        planDigest: String,
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String],
        networkEndpoints: [WorkloadNetworkEndpoint],
        stdio: [FileHandle?],
        controllers: [any WorkloadEffectControllerV1],
        monitorTerminal: Bool
    ) throws -> EngineWorkloadRecordV1 {
        startCount += 1
        if failStart {
            throw ContainerizationError(
                .internalError,
                message: "terminal workload start failure"
            )
        }
        #expect(monitorTerminal)
        _ = configuration
        _ = workloadRoot
        _ = dynamicEnvironment
        _ = networkEndpoints
        lastStdioCount = stdio.count
        lastStdinWasNil = stdio.indices.contains(0) && stdio[0] == nil
        lastStdoutWasPresent = stdio.indices.contains(1) && stdio[1] != nil
        lastStderrWasPresent = stdio.indices.contains(2) && stdio[2] != nil
        _ = controllers
        return try EngineWorkloadRecordV1(
            containerID: reportedWorkloadID,
            planDigest: planDigest,
            state: .running,
            transitionRevision: 2,
            latestProcessGeneration: 3,
            activeProcessGeneration: 3,
            activeSandboxGeneration: sandboxGeneration
        )
    }

    func dialService(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) throws -> FileHandle {
        dialCount += 1
        lastDialProcessGeneration = workloadProcessGeneration
        #expect(workloadID == "container-gelf-service")
        #expect(port == 19_532)
        _ = configuration
        if transientDialFailures > 0 {
            transientDialFailures -= 1
            throw ContainerizationError(
                .internalError,
                message: "transient GELF service dial failure"
            )
        }
        return try gelfTCPServicePair(
            generation: serviceGeneration ?? sandboxGeneration
        ).client
    }
}

private func gelfTCPServicePair(
    generation: UInt64
) throws -> (client: FileHandle, server: FileHandle) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let client = FileHandle(
        fileDescriptor: descriptors[0],
        closeOnDealloc: true
    )
    let server = FileHandle(
        fileDescriptor: descriptors[1],
        closeOnDealloc: true
    )
    Task.detached {
        defer { try? server.close() }
        let request = try GELFTCPServiceFrameCodecV1.read(
            GELFTCPServiceWireRequestV1.self,
            from: server
        )
        let response = try GELFTCPServiceWireResponseV1.generation(
            operationID: request.operationID,
            sandboxGeneration: generation
        )
        try GELFTCPServiceFrameCodecV1.write(response, to: server)
    }
    return (client, server)
}
