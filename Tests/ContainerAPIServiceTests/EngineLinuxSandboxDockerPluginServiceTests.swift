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
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ContainerAPIService

struct EngineLinuxSandboxDockerPluginServiceTests {
    @Test func discoveryAllowsExactGenerationsOfOneProviderToCoexist() throws {
        var registry = DockerPluginInstallationCollisionRegistry(
            reservedDescriptors:
                BuiltinLogDriverDescriptors.current.descriptors
                + [SyslogLogDriverContract.descriptor()]
        )

        try registry.register(
            driver: "example-plugin",
            aliases: ["example-plugin-alias"],
            providerID: "io.container.logging.plugin.example",
            providerGeneration: 1,
            servicePort: 12_001
        )
        try registry.register(
            driver: "example-plugin",
            aliases: ["example-plugin-alias"],
            providerID: "io.container.logging.plugin.example",
            providerGeneration: 2,
            servicePort: 12_002
        )

        #expect(
            throws:
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin provider generation is duplicated"
                )
        ) {
            try registry.register(
                driver: "example-plugin",
                aliases: ["example-plugin-alias"],
                providerID: "io.container.logging.plugin.example",
                providerGeneration: 2,
                servicePort: 12_003
            )
        }
    }

    @Test func discoveryStillRejectsCrossProviderNamesAndSharedPorts() throws {
        var registry = DockerPluginInstallationCollisionRegistry(
            reservedDescriptors:
                BuiltinLogDriverDescriptors.current.descriptors
                + [SyslogLogDriverContract.descriptor()]
        )
        try registry.register(
            driver: "example-plugin",
            aliases: ["example-plugin-alias"],
            providerID: "io.container.logging.plugin.example",
            providerGeneration: 1,
            servicePort: 12_001
        )

        #expect(
            throws:
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin name collides with an installed provider"
                )
        ) {
            try registry.register(
                driver: "other-plugin",
                aliases: ["example-plugin-alias"],
                providerID: "io.container.logging.plugin.other",
                providerGeneration: 1,
                servicePort: 12_002
            )
        }
        #expect(
            throws:
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin service port collides with an installed provider"
                )
        ) {
            try registry.register(
                driver: "other-plugin",
                aliases: [],
                providerID: "io.container.logging.plugin.other",
                providerGeneration: 1,
                servicePort: 12_001
            )
        }
        #expect(
            throws:
                EngineLinuxSandboxDockerPluginServiceError
                .invalidInstalledAsset(
                    "logging plugin name collides with an installed provider"
                )
        ) {
            try registry.register(
                driver: "syslog",
                aliases: [],
                providerID: "io.container.logging.plugin.other",
                providerGeneration: 1,
                servicePort: 12_002
            )
        }
    }

    @Test func authenticationKeyIsPersistentProtectedAndNotReplaceable()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "docker-plugin-key-\(UUID())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let keyURL = root.appendingPathComponent("authentication.key")
        let first =
            try InstalledDockerPluginWorkloadMaterializerV1
            .loadOrCreateAuthenticationKey(at: keyURL)
        let second =
            try InstalledDockerPluginWorkloadMaterializerV1
            .loadOrCreateAuthenticationKey(at: keyURL)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: keyURL.path)[
                .posixPermissions
            ] as? NSNumber
        )
        #expect(first.count == 32)
        #expect(second == first)
        #expect(permissions.uint16Value == 0o600)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: keyURL.path
        )
        #expect(throws: EngineLinuxSandboxDockerPluginServiceError.self) {
            _ =
                try InstalledDockerPluginWorkloadMaterializerV1
                .loadOrCreateAuthenticationKey(at: keyURL)
        }
    }

    @Test func installedManifestBindsArchiveIdentityAndGeneration() throws {
        let fixture = try InstalledDockerPluginAssetFixture()
        defer { fixture.remove() }

        let verified = try InstalledDockerPluginWorkloadManifestV1.verify(
            resourceRoot: fixture.root
        )
        #expect(verified.manifest.driver == "example/plugin")
        #expect(verified.manifest.providerGeneration == 7)
        #expect(verified.manifest.readLogs)
        #expect(verified.workloadID.hasPrefix("container-docker-log-"))
        #expect(verified.planDigest.hasPrefix("sha256:"))

        try Data("changed".utf8).write(to: fixture.archiveURL)
        #expect(throws: EngineLinuxSandboxDockerPluginServiceError.self) {
            _ = try InstalledDockerPluginWorkloadManifestV1.verify(
                resourceRoot: fixture.root
            )
        }
    }

    @Test func unknownManifestFieldAndWritableAssetFailClosed() throws {
        let unknown = try InstalledDockerPluginAssetFixture(
            additionalManifestFields: ["unexpected": true]
        )
        defer { unknown.remove() }
        #expect(throws: EngineLinuxSandboxDockerPluginServiceError.self) {
            _ = try InstalledDockerPluginWorkloadManifestV1.verify(
                resourceRoot: unknown.root
            )
        }

        let writable = try InstalledDockerPluginAssetFixture()
        defer { writable.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: writable.archiveURL.path
        )
        #expect(throws: EngineLinuxSandboxDockerPluginServiceError.self) {
            _ = try InstalledDockerPluginWorkloadManifestV1.verify(
                resourceRoot: writable.root
            )
        }

        let unsafeSocket = try InstalledDockerPluginAssetFixture(
            manifestOverrides: ["pluginSocket": "/var/lib/plugin.sock"]
        )
        defer { unsafeSocket.remove() }
        #expect(throws: EngineLinuxSandboxDockerPluginServiceError.self) {
            _ = try InstalledDockerPluginWorkloadManifestV1.verify(
                resourceRoot: unsafeSocket.root
            )
        }
    }

    @Test func immutablePluginWorkloadHasPrivateWritableRuntimeMounts() {
        let stateRoot = URL(fileURLWithPath: "/protected/plugin-state")
        let mounts = InstalledDockerPluginWorkloadMaterializerV1.serviceMounts(
            stateRoot: stateRoot
        )

        #expect(mounts.count == 3)
        #expect(mounts[0].isVirtiofs)
        #expect(mounts[0].source == stateRoot.path)
        #expect(
            mounts[0].destination
                == "/var/lib/container-docker-plugin-service"
        )
        #expect(mounts[1].isTmpfs)
        #expect(mounts[1].destination == "/run")
        #expect(Set(mounts[1].options) == ["nosuid", "nodev", "noexec", "mode=0755"])
        #expect(mounts[2].isTmpfs)
        #expect(mounts[2].destination == "/tmp")
        #expect(Set(mounts[2].options) == ["nosuid", "nodev", "mode=1777"])
    }

    @Test func connectorStartsAndDialsExactPluginWorkloadGeneration()
        async throws
    {
        let assetFixture = try InstalledDockerPluginAssetFixture()
        defer { assetFixture.remove() }
        let assets = try InstalledDockerPluginWorkloadManifestV1.verify(
            resourceRoot: assetFixture.root
        )
        let connectorFixture = try DockerPluginConnectorFixture()
        defer { connectorFixture.remove() }
        let authority = FakeDockerPluginAuthority(
            sandboxGeneration: 9,
            assets: assets
        )
        let materializer = FakeDockerPluginMaterializer(
            assets: assets,
            configuration: connectorFixture.configuration,
            workloadRoot: connectorFixture.workloadRoot
        )
        let connector = EngineLinuxSandboxDockerPluginConnectorV1(
            authority: authority,
            materializer: materializer
        )

        let handle = try await connector.connect()
        try handle.close()
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 1)
        #expect(await authority.lastDialProcessGeneration == 3)
        #expect(await materializer.lastGeneration == 9)
    }

    @Test func generationProbeRejectsStalePluginService() async throws {
        let (client, server) = try dockerPluginServicePair(generation: 8)
        defer { try? client.close() }
        defer { try? server.close() }

        await #expect(
            throws:
                EngineLinuxSandboxDockerPluginServiceError
                .generationMismatch(expected: 9, actual: 8)
        ) {
            try await EngineLinuxSandboxDockerPluginConnectorV1
                .verifyGeneration(
                    on: client,
                    expected: 9,
                    authenticationKey: Data(repeating: 0x5a, count: 32)
                )
        }
    }

    @Test func generationReclaimerStopsExactPluginWorkloadOnce() async throws {
        let assetFixture = try InstalledDockerPluginAssetFixture()
        defer { assetFixture.remove() }
        let assets = try InstalledDockerPluginWorkloadManifestV1.verify(
            resourceRoot: assetFixture.root
        )
        let connectorFixture = try DockerPluginConnectorFixture()
        defer { connectorFixture.remove() }
        let authority = FakeDockerPluginAuthority(
            sandboxGeneration: 9,
            assets: assets
        )
        let materializer = FakeDockerPluginMaterializer(
            assets: assets,
            configuration: connectorFixture.configuration,
            workloadRoot: connectorFixture.workloadRoot
        )
        _ = try await authority.startWorkload(
            planDigest: assets.planDigest,
            configuration: connectorFixture.configuration,
            workloadRoot: connectorFixture.workloadRoot,
            dynamicEnvironment: [:],
            networkEndpoints: [],
            stdio: [],
            controllers: [],
            monitorTerminal: true
        )
        let reclaimer =
            EngineLinuxSandboxDockerPluginGenerationReclaimerV1(
                authority: authority,
                materializer: materializer
            )
        let request = try LogDriverProviderGenerationReclaimV1(
            providerID: assets.manifest.providerID,
            providerGeneration: assets.manifest.providerGeneration
        )

        #expect(
            try await reclaimer.isProviderGenerationReclaimed(request)
                == false
        )
        try await reclaimer.reclaimProviderGeneration(request)
        #expect(
            try await reclaimer.isProviderGenerationReclaimed(request)
                == true
        )
        try await reclaimer.reclaimProviderGeneration(request)
        #expect(await authority.stopCount == 1)
    }
}

private struct InstalledDockerPluginAssetFixture {
    let root: URL
    let archiveURL: URL
    let manifestURL: URL

    init(
        additionalManifestFields: [String: Any] = [:],
        manifestOverrides: [String: Any] = [:]
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "docker-plugin-assets-\(UUID())",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent(
            InstalledDockerPluginWorkloadManifestV1.archiveFilename
        )
        manifestURL = root.appendingPathComponent(
            InstalledDockerPluginWorkloadManifestV1.manifestFilename
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let archive = Data("archive".utf8)
        try archive.write(to: archiveURL)
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": 1,
            "serviceVersion": "1",
            "driver": "example/plugin",
            "aliases": ["example"],
            "providerID": "io.container.logging.plugin.example",
            "providerVersion": "1.2.3",
            "providerGeneration": 7,
            "readLogs": true,
            "servicePort": 20_007,
            "pluginSocket": "/run/docker/plugins/example.sock",
            "architecture": "arm64",
            "platform": "linux",
            "ociArchiveSHA256": Self.sha256(archive),
            "serviceSourceSHA256": String(repeating: "a", count: 64),
            "workloadManifestDigest":
                "sha256:" + String(repeating: "b", count: 64),
        ]
        for (key, value) in additionalManifestFields {
            manifest[key] = value
        }
        for (key, value) in manifestOverrides {
            manifest[key] = value
        }
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL)
        for path in [archiveURL.path, manifestURL.path] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DockerPluginConnectorFixture {
    let root: URL
    let workloadRoot: URL
    let configuration: EngineLinuxSandboxRuntimeConfigurationV1

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "docker-plugin-connector-\(UUID())",
            isDirectory: true
        )
        workloadRoot = root.appendingPathComponent("workload")
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

private actor FakeDockerPluginMaterializer:
    EngineLinuxSandboxDockerPluginWorkloadMaterializingV1
{
    nonisolated let assets: VerifiedDockerPluginWorkloadAssetsV1
    nonisolated let authenticationKey = Data(repeating: 0x5a, count: 32)
    private let configuration: EngineLinuxSandboxRuntimeConfigurationV1
    private let workloadRoot: URL
    private(set) var lastGeneration: UInt64?

    init(
        assets: VerifiedDockerPluginWorkloadAssetsV1,
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL
    ) {
        self.assets = assets
        self.configuration = configuration
        self.workloadRoot = workloadRoot
    }

    func sandboxConfiguration() -> EngineLinuxSandboxRuntimeConfigurationV1 {
        configuration
    }

    func workload(
        sandboxGeneration: UInt64
    ) -> EngineLinuxSandboxDockerPluginWorkloadMaterializationV1 {
        lastGeneration = sandboxGeneration
        return EngineLinuxSandboxDockerPluginWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: assets.planDigest
        )
    }
}

private actor FakeDockerPluginAuthority:
    EngineLinuxSandboxDockerPluginAuthorityV1
{
    private let sandboxGeneration: UInt64
    private let assets: VerifiedDockerPluginWorkloadAssetsV1
    private(set) var ensureReadyCount = 0
    private(set) var startCount = 0
    private(set) var dialCount = 0
    private(set) var lastDialProcessGeneration: UInt64?
    private(set) var stopCount = 0
    private var workloadRecord: EngineWorkloadRecordV1?

    init(
        sandboxGeneration: UInt64,
        assets: VerifiedDockerPluginWorkloadAssetsV1
    ) {
        self.sandboxGeneration = sandboxGeneration
        self.assets = assets
    }

    func snapshot() -> EngineWorkloadLedgerSnapshotV1 {
        try! EngineWorkloadLedgerSnapshotV1(
            owningControllerID: "docker-plugin-test",
            sandbox: EngineLinuxSandboxRecordV1(
                sandboxID: "engine-linux-sandbox",
                generation: sandboxGeneration,
                revision: 2,
                state: .ready,
                operationKind: .boot,
                idempotencyKey: "boot-key",
                requestDigest: "sha256:" + String(repeating: "d", count: 64),
                effectID: "boot-effect",
                runtimeFingerprint:
                    "sha256:" + String(repeating: "e", count: 64)
            ),
            workloads: workloadRecord.map { [$0] } ?? []
        )
    }

    func ensureReady(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) throws -> EngineLinuxSandboxRecordV1 {
        ensureReadyCount += 1
        _ = configuration
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
        #expect(planDigest == assets.planDigest)
        #expect(monitorTerminal)
        #expect(networkEndpoints.isEmpty)
        _ = configuration
        _ = workloadRoot
        _ = dynamicEnvironment
        _ = stdio
        _ = controllers
        let record = try EngineWorkloadRecordV1(
            containerID: assets.workloadID,
            planDigest: planDigest,
            state: .running,
            transitionRevision: 2,
            latestProcessGeneration: 3,
            activeProcessGeneration: 3,
            activeSandboxGeneration: sandboxGeneration
        )
        workloadRecord = record
        return record
    }

    func dialService(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) throws -> FileHandle {
        dialCount += 1
        lastDialProcessGeneration = workloadProcessGeneration
        #expect(workloadID == assets.workloadID)
        #expect(port == assets.manifest.servicePort)
        _ = configuration
        return try dockerPluginServicePair(
            generation: sandboxGeneration
        ).client
    }

    func stopWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) throws -> EngineWorkloadRecordV1 {
        _ = configuration
        stopCount += 1
        let record = try EngineWorkloadRecordV1(
            containerID: workloadID,
            planDigest: assets.planDigest,
            state: .stopped,
            transitionRevision: 4,
            latestProcessGeneration: workloadProcessGeneration
        )
        workloadRecord = record
        return record
    }
}

private func dockerPluginServicePair(
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
        let request = try DockerPluginLifecycleServiceFrameCodecV1.read(
            DockerPluginLifecycleServiceWireRequestV1.self,
            from: server
        )
        try DockerPluginLifecycleServiceFrameCodecV1.write(
            DockerPluginLifecycleServiceWireResponseV1(
                operationID: request.operationID,
                sandboxGeneration: generation
            ),
            to: server
        )
    }
    return (client, server)
}
