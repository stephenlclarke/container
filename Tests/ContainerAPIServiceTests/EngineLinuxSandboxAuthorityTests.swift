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
import ContainerRuntimeClient
import Containerization
import Foundation
import Testing

@testable import ContainerAPIService

struct EngineLinuxSandboxAuthorityTests {
    @Test
    func durableAuthorityReconcilesSandboxAndStartsWorkloadOnce() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(runtime: runtime)
        let persistence = InMemoryEngineWorkloadLedgerPersistenceV1()

        let first = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: persistence
        )
        let ready = try await first.ensureReady(configuration: fixture.sandboxConfiguration)
        #expect(ready.state == .ready)
        #expect(await runtime.bootCount == 1)

        // A fresh authority must reconcile the exact helper identity instead
        // of trusting the durable ready record by itself.
        let recovered = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: persistence
        )
        let observed = try await recovered.ensureReady(configuration: fixture.sandboxConfiguration)
        #expect(observed == ready)
        #expect(await runtime.bootCount == 1)
        #expect(await runtime.bootObservationCount == 1)

        let running = try await recovered.startWorkload(
            planDigest: "sha256:plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot,
            dynamicEnvironment: ["BUILD_ID": "42"]
        )
        #expect(running.state == .running)
        #expect(running.activeProcessGeneration == 1)
        #expect(await runtime.workloadStartCount == 1)

        let replay = try await recovered.startWorkload(
            planDigest: "sha256:plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot,
            dynamicEnvironment: ["BUILD_ID": "42"]
        )
        #expect(replay == running)
        #expect(await runtime.workloadStartCount == 1)
        #expect(await launcher.launchCount == 2)

        await #expect(throws: EngineWorkloadLedgerError.idempotencyConflict) {
            _ = try await recovered.startWorkload(
                planDigest: "sha256:plan",
                configuration: fixture.sandboxConfiguration,
                workloadRoot: fixture.workloadRoot,
                dynamicEnvironment: ["BUILD_ID": "changed"]
            )
        }
        #expect(await runtime.workloadStartCount == 1)
    }
}

private actor FakeAuthorityLauncher: EngineLinuxSandboxLaunchingV1 {
    private let runtime: FakeAuthorityRuntime
    private(set) var launchCount = 0
    private(set) var stopCount = 0

    init(runtime: FakeAuthorityRuntime) {
        self.runtime = runtime
    }

    func launch(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> any EngineLinuxSandboxRuntimeClientV1 {
        try configuration.write()
        launchCount += 1
        return runtime
    }

    func stop(configuration: EngineLinuxSandboxRuntimeConfigurationV1) async throws {
        stopCount += 1
        _ = configuration
    }
}

private actor FakeAuthorityRuntime: EngineLinuxSandboxRuntimeClientV1 {
    private var bootReceipt: EngineLinuxSandboxBootReceiptV1?
    private var workloadReceipt: WorkloadProcessReceiptV1?
    private(set) var bootCount = 0
    private(set) var bootObservationCount = 0
    private(set) var workloadStartCount = 0

    func boot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootReceiptV1 {
        if let bootReceipt {
            return bootReceipt
        }
        bootCount += 1
        let receipt = EngineLinuxSandboxBootReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest,
            runtimeFingerprint: "runtime-1"
        )
        bootReceipt = receipt
        return receipt
    }

    func observeBoot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootObservationV1 {
        bootObservationCount += 1
        guard let bootReceipt,
            bootReceipt.sandboxID == request.sandboxID,
            bootReceipt.generation == request.generation,
            bootReceipt.effectID == request.effectID,
            bootReceipt.requestDigest == request.requestDigest
        else { return .absent }
        return .ready(bootReceipt)
    }

    func shutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownReceiptV1 {
        bootReceipt = nil
        return EngineLinuxSandboxShutdownReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest
        )
    }

    func observeShutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownObservationV1 {
        guard bootReceipt == nil else { return .running }
        return .absent(
            EngineLinuxSandboxShutdownReceiptV1(
                sandboxID: request.sandboxID,
                generation: request.generation,
                effectID: request.effectID,
                requestDigest: request.requestDigest
            )
        )
    }

    func startWorkload(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1,
        stdio: [FileHandle?]
    ) async throws -> WorkloadProcessReceiptV1 {
        if let workloadReceipt {
            return workloadReceipt
        }
        workloadStartCount += 1
        let receipt = WorkloadProcessReceiptV1(
            containerID: request.context.containerID,
            operationGeneration: request.context.operationGeneration,
            processGeneration: request.context.candidateProcessGeneration,
            sandboxGeneration: request.context.sandboxGeneration,
            requestDigest: request.context.requestDigest
        )
        workloadReceipt = receipt
        _ = stdio
        return receipt
    }

    func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1 {
        guard let workloadReceipt,
            workloadReceipt.containerID == request.context.containerID,
            workloadReceipt.operationGeneration == request.context.operationGeneration,
            workloadReceipt.requestDigest == request.context.requestDigest
        else { return .absent }
        return .started(workloadReceipt)
    }
}

private struct EngineSandboxAuthorityFixture {
    let root: URL
    let sandboxRoot: URL
    let workloadRoot: URL
    let sandboxConfiguration: EngineLinuxSandboxRuntimeConfigurationV1

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-authority-\(UUID())")
        sandboxRoot = root.appendingPathComponent("sandbox")
        workloadRoot = root.appendingPathComponent("workload")
        sandboxConfiguration = EngineLinuxSandboxRuntimeConfigurationV1(
            path: sandboxRoot,
            sandboxID: "engine-sandbox",
            initialFilesystem: .tmpfs(destination: "/", options: []),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/kernel"),
                platform: .linuxArm
            ),
            cpus: 4,
            memoryInBytes: 4 * 1_024 * 1_024 * 1_024
        )

        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "echo ready"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        let configuration = ContainerConfiguration(
            id: "workload-1",
            image: image,
            process: process
        )
        try RuntimeConfiguration(
            path: workloadRoot,
            initialFilesystem: .tmpfs(destination: "/", options: []),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/kernel"),
                platform: .linuxArm
            ),
            containerConfiguration: configuration,
            containerRootFilesystem: .tmpfs(destination: "/", options: [])
        ).writeRuntimeConfiguration()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
