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
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerRuntimeLinuxServer

struct EngineLinuxSandboxRuntimeServiceTests {
    @Test
    func exactBootAndShutdownRequestsAreIdempotentAndObservable() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        let boot = bootRequest()

        let receipt = try await service.boot(boot)
        #expect(receipt.sandboxID == boot.sandboxID)
        #expect(receipt.generation == boot.generation)
        #expect(receipt.effectID == boot.effectID)
        #expect(receipt.requestDigest == boot.requestDigest)
        #expect(receipt.runtimeFingerprint == "runtime-1")
        #expect(try await service.boot(boot) == receipt)
        #expect(try await service.observeBoot(boot) == .ready(receipt))
        #expect(await sandbox.createCount == 1)

        let shutdown = shutdownRequest()
        let shutdownReceipt = try await service.shutdown(shutdown)
        #expect(try await service.shutdown(shutdown) == shutdownReceipt)
        #expect(try await service.observeShutdown(shutdown) == .absent(shutdownReceipt))
        #expect(try await service.observeBoot(boot) == .absent)
        #expect(await sandbox.stopCount == 1)
    }

    @Test
    func runningSandboxWithoutExactReceiptIsFenced() async throws {
        let sandbox = FakeEngineLinuxSandbox(state: .running)
        let service = try makeService(sandbox: sandbox)
        let request = bootRequest()

        #expect(try await service.observeBoot(request) == .unknown)
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.boot(request)
        }
        #expect(await sandbox.createCount == 0)
    }

    @Test
    func absentShutdownCanBeReconciledWithoutMutation() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        let request = shutdownRequest()
        let expected = EngineLinuxSandboxShutdownReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest
        )

        #expect(try await service.observeShutdown(request) == .absent(expected))
        #expect(await sandbox.stopCount == 0)
    }

    @Test
    func exactWorkloadStartMaterializesOnceAndIsObservable() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let request = workloadRequest(root: fixture.root)

        let receipt = try await service.startWorkload(request, stdio: [])
        #expect(receipt.containerID == request.context.containerID)
        #expect(receipt.processGeneration == request.context.candidateProcessGeneration)
        #expect(try await service.startWorkload(request, stdio: []) == receipt)
        #expect(try await service.observeWorkloadStart(request) == .started(receipt))
        #expect(await sandbox.addCount == 1)
        #expect(await sandbox.startCount == 1)
        #expect(await sandbox.configuredArguments == ["/bin/sh", "-c", "echo ready"])
    }

    @Test
    func wireObservationsRoundTrip() throws {
        let bootReceipt = EngineLinuxSandboxBootReceiptV1(
            sandboxID: "engine-sandbox",
            generation: 1,
            effectID: "boot-effect",
            requestDigest: "boot-digest",
            runtimeFingerprint: "runtime-1"
        )
        let boot = EngineLinuxSandboxBootObservationV1.ready(bootReceipt)
        let shutdownReceipt = EngineLinuxSandboxShutdownReceiptV1(
            sandboxID: "engine-sandbox",
            generation: 1,
            effectID: "shutdown-effect",
            requestDigest: "shutdown-digest"
        )
        let shutdown = EngineLinuxSandboxShutdownObservationV1.absent(shutdownReceipt)
        let workloadRequest = workloadRequest(
            root: URL(fileURLWithPath: "/tmp/engine-workload")
        )
        let workloadObservation = WorkloadProcessObservationV1.started(
            WorkloadProcessReceiptV1(
                containerID: workloadRequest.context.containerID,
                operationGeneration: workloadRequest.context.operationGeneration,
                processGeneration: workloadRequest.context.candidateProcessGeneration,
                sandboxGeneration: workloadRequest.context.sandboxGeneration,
                requestDigest: workloadRequest.context.requestDigest
            )
        )

        #expect(
            try JSONDecoder().decode(
                EngineLinuxSandboxBootObservationV1.self,
                from: JSONEncoder().encode(boot)
            ) == boot
        )
        #expect(
            try JSONDecoder().decode(
                EngineLinuxSandboxShutdownObservationV1.self,
                from: JSONEncoder().encode(shutdown)
            ) == shutdown
        )
        #expect(
            try JSONDecoder().decode(
                EngineLinuxSandboxWorkloadStartRequestV1.self,
                from: JSONEncoder().encode(workloadRequest)
            ) == workloadRequest
        )
        #expect(
            try JSONDecoder().decode(
                WorkloadProcessObservationV1.self,
                from: JSONEncoder().encode(workloadObservation)
            ) == workloadObservation
        )
    }

    private func makeService(
        sandbox: FakeEngineLinuxSandbox
    ) throws -> EngineLinuxSandboxRuntimeServiceV1 {
        try EngineLinuxSandboxRuntimeServiceV1(
            sandbox: sandbox,
            runtimeFingerprint: "runtime-1",
            log: Logger(label: "EngineLinuxSandboxRuntimeServiceTests")
        )
    }

    private func bootRequest() -> EngineLinuxSandboxBootRequestV1 {
        .init(
            sandboxID: "engine-sandbox",
            generation: 1,
            idempotencyKey: "boot-key",
            requestDigest: "boot-digest",
            effectID: "boot-effect"
        )
    }

    private func shutdownRequest() -> EngineLinuxSandboxShutdownRequestV1 {
        .init(
            sandboxID: "engine-sandbox",
            generation: 1,
            idempotencyKey: "shutdown-key",
            requestDigest: "shutdown-digest",
            effectID: "shutdown-effect"
        )
    }

    private func workloadRequest(root: URL) -> EngineLinuxSandboxWorkloadStartRequestV1 {
        .init(
            context: WorkloadStartContextV1(
                containerID: "workload-1",
                operationGeneration: 2,
                candidateProcessGeneration: 3,
                sandboxGeneration: 1,
                requestDigest: "workload-digest"
            ),
            workloadRoot: root,
            dynamicEnvironment: ["BUILD_ID": "42"]
        )
    }
}

private actor FakeEngineLinuxSandbox: EngineLinuxSandboxInstanceV1 {
    nonisolated let id = "engine-sandbox"
    private var state: LinuxSandboxRuntimeState
    private(set) var createCount = 0
    private(set) var stopCount = 0
    private(set) var addCount = 0
    private(set) var startCount = 0
    private(set) var configuredArguments: [String] = []
    private var workloads: [String: LinuxSandboxWorkloadSnapshot] = [:]

    init(state: LinuxSandboxRuntimeState = .absent) {
        self.state = state
    }

    func snapshot() -> LinuxSandboxSnapshot {
        LinuxSandboxSnapshot(
            sandboxID: id,
            state: state,
            workloads: workloads.values.sorted { $0.id < $1.id }
        )
    }

    func create() throws {
        createCount += 1
        state = .running
    }

    func stop() throws {
        stopCount += 1
        state = .absent
        workloads.removeAll()
    }

    func addContainer(
        _ id: String,
        rootfs: Containerization.Mount,
        configuration: @Sendable @escaping (inout LinuxPod.ContainerConfiguration) throws -> Void
    ) throws {
        var config = LinuxPod.ContainerConfiguration()
        try configuration(&config)
        addCount += 1
        configuredArguments = config.process.arguments
        workloads[id] = LinuxSandboxWorkloadSnapshot(
            id: id,
            state: .created,
            initProcessID: nil
        )
        _ = rootfs
    }

    func startContainer(_ containerID: String) throws {
        guard workloads[containerID]?.state == .created else {
            throw ContainerizationError(.invalidState, message: "fake workload is not created")
        }
        startCount += 1
        workloads[containerID] = LinuxSandboxWorkloadSnapshot(
            id: containerID,
            state: .running,
            initProcessID: 123
        )
    }

    func removeContainer(_ containerID: String) {
        workloads[containerID] = nil
    }
}

private struct WorkloadBundleFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-workload-\(UUID())")
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
        let runtime = RuntimeConfiguration(
            path: root,
            initialFilesystem: .tmpfs(destination: "/", options: []),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/kernel"),
                platform: .linuxArm
            ),
            containerConfiguration: configuration,
            containerRootFilesystem: .tmpfs(destination: "/", options: [])
        )
        try runtime.writeRuntimeConfiguration()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
