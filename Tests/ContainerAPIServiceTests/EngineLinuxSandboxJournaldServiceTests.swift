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

struct EngineLinuxSandboxJournaldServiceTests {
    @Test
    func installedManifestBindsTheExactProtectedArchive() throws {
        let fixture = try InstalledJournaldAssetFixture()
        defer { fixture.remove() }

        let verified = try InstalledJournaldWorkloadManifestV1.verify(
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
            throws: EngineLinuxSandboxJournaldServiceError.self
        ) {
            _ = try InstalledJournaldWorkloadManifestV1.verify(
                archiveURL: fixture.archiveURL,
                manifestURL: fixture.manifestURL
            )
        }
    }

    @Test
    func installedAssetsAllowAHomebrewStyleParentLinkButNotAnAssetLink()
        throws
    {
        let fixture = try InstalledJournaldAssetFixture()
        defer { fixture.remove() }
        let linkedRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("journald-assets-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: fixture.root
        )

        _ = try InstalledJournaldWorkloadManifestV1.verify(
            archiveURL: linkedRoot.appendingPathComponent(
                fixture.archiveURL.lastPathComponent
            ),
            manifestURL: linkedRoot.appendingPathComponent(
                fixture.manifestURL.lastPathComponent
            )
        )

        let linkedArchive = fixture.root.appendingPathComponent(
            "linked-journald-service.oci.tar"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedArchive,
            withDestinationURL: fixture.archiveURL
        )
        #expect(throws: EngineLinuxSandboxJournaldServiceError.self) {
            _ = try InstalledJournaldWorkloadManifestV1.verify(
                archiveURL: linkedArchive,
                manifestURL: fixture.manifestURL
            )
        }
    }

    @Test
    func connectorStartsAndDialsOnlyTheExactWorkloadGeneration() async throws {
        let fixture = try JournaldConnectorFixture()
        defer { fixture.remove() }
        let authority = FakeJournaldAuthority(sandboxGeneration: 7)
        let materializer = FakeJournaldMaterializer(
            configuration: fixture.configuration,
            workloadRoot: fixture.workloadRoot
        )
        let connector = EngineLinuxSandboxJournaldConnectorV1(
            authority: authority,
            materializer: materializer
        )

        let handle = try await connector.connect()
        try handle.close()
        #expect(await authority.ensureReadyCount == 1)
        #expect(await authority.startCount == 1)
        #expect(await authority.dialCount == 1)
        #expect(await authority.lastDialProcessGeneration == 3)
        #expect(await materializer.lastGeneration == 7)
    }

    @Test
    func generationProbeRejectsAStaleService() async throws {
        let (client, server) = try servicePair(generation: 6)
        defer { try? client.close() }
        defer { try? server.close() }

        await #expect(
            throws:
                EngineLinuxSandboxJournaldServiceError
                .generationMismatch(expected: 7, actual: 6)
        ) {
            try await EngineLinuxSandboxJournaldConnectorV1.verifyGeneration(
                on: client,
                expected: 7
            )
        }
    }
}

private struct InstalledJournaldAssetFixture {
    let root: URL
    let archiveURL: URL
    let manifestURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "journald-assets-\(UUID())",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent(
            "container-journald-service.oci.tar"
        )
        manifestURL = root.appendingPathComponent(
            "container-journald-service.manifest.json"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let archive = Data("archive".utf8)
        try archive.write(to: archiveURL)
        let archiveDigest = Self.sha256(archive)
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": 2,
            "serviceVersion": "2",
            "architecture": "arm64",
            "platform": "linux",
            "ociArchiveSHA256": archiveDigest,
            "serviceSourceSHA256": String(repeating: "a", count: 64),
            "workloadManifestDigest":
                "sha256:" + String(repeating: "b", count: 64),
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: archiveURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: manifestURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct JournaldConnectorFixture {
    let root: URL
    let workloadRoot: URL
    let configuration: EngineLinuxSandboxRuntimeConfigurationV1

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "journald-connector-\(UUID())",
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

private actor FakeJournaldMaterializer:
    EngineLinuxSandboxJournaldWorkloadMaterializingV1
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
    ) -> EngineLinuxSandboxJournaldWorkloadMaterializationV1 {
        lastGeneration = sandboxGeneration
        return EngineLinuxSandboxJournaldWorkloadMaterializationV1(
            workloadRoot: workloadRoot,
            planDigest: "sha256:" + String(repeating: "c", count: 64)
        )
    }
}

private actor FakeJournaldAuthority: EngineLinuxSandboxJournaldAuthorityV1 {
    private let sandboxGeneration: UInt64
    private(set) var ensureReadyCount = 0
    private(set) var startCount = 0
    private(set) var dialCount = 0
    private(set) var lastDialProcessGeneration: UInt64?

    init(sandboxGeneration: UInt64) {
        self.sandboxGeneration = sandboxGeneration
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
        #expect(monitorTerminal)
        _ = configuration
        _ = workloadRoot
        _ = dynamicEnvironment
        _ = networkEndpoints
        _ = stdio
        _ = controllers
        return try EngineWorkloadRecordV1(
            containerID: "container-journald-service",
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
        #expect(workloadID == "container-journald-service")
        #expect(port == 19_530)
        _ = configuration
        return try servicePair(generation: sandboxGeneration).client
    }
}

private func servicePair(
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
        let request = try JournaldServiceFrameCodecV1.read(
            JournaldServiceWireRequestV1.self,
            from: server
        )
        let response = try JournaldServiceWireResponseV1.generation(
            operationID: request.operationID,
            sandboxGeneration: generation
        )
        try JournaldServiceFrameCodecV1.write(response, to: server)
    }
    return (client, server)
}
