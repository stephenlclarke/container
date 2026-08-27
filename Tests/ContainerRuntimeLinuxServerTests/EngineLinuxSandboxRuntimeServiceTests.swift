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
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import Testing

@testable import ContainerRuntimeLinuxServer

struct EngineLinuxSandboxRuntimeServiceTests {
    @Test
    func sealedEgressNetworkInstallsTheReservedVmnetInterface() throws {
        var configuration = LinuxPod.Configuration()
        let interface = NATInterface(
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            mtu: 1280
        )

        EngineLinuxSandboxRuntimeServiceV1
            .configureSealedEgressNetwork(&configuration, interface: interface)

        let storedInterface = try #require(configuration.interfaces.first as? NATInterface)
        #expect(configuration.interfaces.count == 1)
        #expect(try #require(storedInterface.ipv4Address).description == "192.168.64.2/24")
        #expect(storedInterface.ipv4Gateway?.description == "192.168.64.1")
        #expect(storedInterface.mtu == 1280)
    }

    @Test
    func sealedReverseVsockEndpointRequiresExactArguments() {
        let sealed = [
            "--sandbox-generation", "1",
            "--port", "12345",
            EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
        ]
        #expect(
            EngineLinuxSandboxServiceEndpointV1
                .declaresExclusiveReverseVsockRelay(
                    arguments: sealed,
                    port: 12_345,
                    publishedSockets: []
                )
        )
        #expect(
            EngineLinuxSandboxServiceEndpointV1.reverseVsockPort(
                arguments: sealed,
                publishedSockets: []
            ) == 12_345
        )
        #expect(
            !EngineLinuxSandboxServiceEndpointV1
                .declaresExclusiveReverseVsockRelay(
                    arguments: [
                        "--port", "12345",
                        "--listen-unix", "/run/service.sock",
                        EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
                    ],
                    port: 12_345,
                    publishedSockets: []
                )
        )
        #expect(
            EngineLinuxSandboxServiceEndpointV1.reverseVsockPort(
                arguments: [
                    "--port", "12345",
                    EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
                    EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
                ],
                publishedSockets: []
            ) == nil
        )
        let guestVsock = [
            "--sandbox-generation", "1",
            "--port", "19530",
        ]
        #expect(
            EngineLinuxSandboxServiceEndpointV1
                .declaresExclusiveGuestVsockService(
                    arguments: guestVsock,
                    port: 19_530,
                    publishedSockets: []
                )
        )
        #expect(
            EngineLinuxSandboxServiceEndpointV1.guestVsockPort(
                arguments: guestVsock,
                publishedSockets: []
            ) == 19_530
        )
        #expect(
            EngineLinuxSandboxServiceEndpointV1.guestVsockPort(
                arguments: sealed,
                publishedSockets: []
            ) == nil
        )
        #expect(
            EngineLinuxSandboxServiceEndpointV1.guestVsockPort(
                arguments: [
                    "--port", "19530",
                    "--listen-unix", "/run/service.sock",
                ],
                publishedSockets: []
            ) == nil
        )
    }

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
        let request = try workloadRequest(root: fixture.root)

        let receipt = try await service.startWorkload(request, stdio: [])
        #expect(receipt.containerID == request.context.containerID)
        #expect(receipt.processGeneration == request.context.candidateProcessGeneration)
        #expect(try await service.startWorkload(request, stdio: []) == receipt)
        #expect(try await service.observeWorkloadStart(request) == .started(receipt))
        #expect(await sandbox.addCount == 1)
        #expect(await sandbox.startCount == 1)
        #expect(
            await sandbox.configuredArguments == [
                "/bin/sh",
                "--port", "12345",
                EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
            ]
        )
        #expect(await sandbox.configuredGuestDevices.isEmpty)
    }

    @Test
    func exactWorkloadStopIsIdempotentAndObservable() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let start = try workloadRequest(root: fixture.root)
        _ = try await service.startWorkload(start, stdio: [])
        let stop = workloadStopRequest()

        let receipt = try await service.stopWorkload(stop)
        #expect(receipt.request == stop)
        #expect(try await service.stopWorkload(stop) == receipt)
        #expect(try await service.observeWorkloadStop(stop) == .stopped(receipt))
        #expect(try await service.observeWorkloadStart(start) == .absent)
        #expect(await sandbox.stopContainerCount == 1)

        var conflicting = workloadStopRequest()
        conflicting = EngineLinuxSandboxWorkloadStopRequestV1(
            sandboxID: conflicting.sandboxID,
            sandboxGeneration: conflicting.sandboxGeneration,
            workloadID: conflicting.workloadID,
            workloadProcessGeneration: conflicting.workloadProcessGeneration,
            operationGeneration: conflicting.operationGeneration,
            idempotencyKey: conflicting.idempotencyKey,
            requestDigest: "different-stop-digest"
        )
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.stopWorkload(conflicting)
        }
        #expect(await sandbox.stopContainerCount == 1)
    }

    @Test
    func workloadControlIsGenerationFencedAndPreservesTypedResults() async throws {
        let sandbox = FakeEngineLinuxSandbox(terminalOnWait: true)
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let start = try workloadRequest(root: fixture.root)
        _ = try await service.startWorkload(start, stdio: [])

        func request(
            generation: UInt64 = 3,
            action: EngineLinuxSandboxWorkloadControlRequestV1.Action
        ) -> EngineLinuxSandboxWorkloadControlRequestV1 {
            .init(
                sandboxID: "engine-sandbox",
                sandboxGeneration: 1,
                workloadID: "workload-1",
                workloadProcessGeneration: generation,
                action: action
            )
        }

        guard
            case .state(.running) = try await service.controlWorkload(
                request(action: .state)
            )
        else {
            Issue.record("expected running workload state")
            return
        }
        guard
            case .none = try await service.controlWorkload(
                request(action: .pause)
            )
        else {
            Issue.record("expected an empty pause response")
            return
        }
        guard
            case .state(.paused) = try await service.controlWorkload(
                request(action: .state)
            )
        else {
            Issue.record("expected paused workload state")
            return
        }
        guard
            case .none = try await service.controlWorkload(
                request(action: .resume)
            )
        else {
            Issue.record("expected an empty resume response")
            return
        }
        guard
            case .statistics(let statistics) = try await service.controlWorkload(
                request(action: .statistics)
            )
        else {
            Issue.record("expected workload statistics")
            return
        }
        #expect(statistics.id == "workload-1")
        #expect(statistics.cpuUsageUsec == 3)
        guard
            case .processes(let processes) = try await service.controlWorkload(
                request(action: .processes)
            )
        else {
            Issue.record("expected workload processes")
            return
        }
        #expect(processes.processIdentifiers == [123])
        guard
            case .exit(let status) = try await service.controlWorkload(
                request(action: .wait(timeoutInSeconds: 7))
            )
        else {
            Issue.record("expected workload exit status")
            return
        }
        #expect(status.exitCode == 0)
        #expect(await sandbox.lastWaitTimeoutInSeconds == 7)

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.controlWorkload(
                request(generation: 4, action: .state)
            )
        }
    }

    @Test
    func changedWorkloadBundleIsRejectedBeforeMaterialization() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let request = try workloadRequest(root: fixture.root)
        try fixture.replaceCommand(
            EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
            with: "--unexpected-listener"
        )

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.startWorkload(request, stdio: [])
        }
        #expect(await sandbox.addCount == 0)
        #expect(await sandbox.startCount == 0)
    }

    @Test
    func failedWorkloadMessageDoesNotConsumeTheSuccessReply() async throws {
        let sandbox = FakeEngineLinuxSandbox(failAdd: true)
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let message = XPCMessage(route: "engine-sandbox-start-workload")
        try message.setEngineSandboxPayload(
            workloadRequest(root: fixture.root)
        )

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.startWorkloadMessage(message)
        }
        #expect(await sandbox.addCount == 1)
        #expect(await sandbox.startCount == 0)
    }

    @Test
    func workloadMessagePreservesIndependentStdoutAndStderr() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let stdout = Pipe()
        let stderr = Pipe()
        let message = XPCMessage(route: "engine-sandbox-start-workload")
        try message.setEngineSandboxPayload(
            workloadRequest(root: fixture.root)
        )
        try message.setEngineSandboxStdio([
            nil,
            stdout.fileHandleForWriting,
            stderr.fileHandleForWriting,
        ])

        let decodedStdio = message.engineSandboxStdio()
        #expect(decodedStdio[1] != nil)
        #expect(decodedStdio[2] != nil)
        _ = try await service.startWorkload(
            workloadRequest(root: fixture.root),
            stdio: decodedStdio
        )

        #expect(await sandbox.configuredStdout)
        #expect(await sandbox.configuredStderr)
    }

    @Test
    func protectedServiceDialRequiresExactRunningGeneration() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        let request = EngineLinuxSandboxServiceDialRequestV1(
            sandboxID: "engine-sandbox",
            sandboxGeneration: 1,
            workloadID: "workload-1",
            workloadProcessGeneration: 3,
            port: 12_345
        )

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(request)
        }
        _ = try await service.boot(bootRequest())
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(request)
        }
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        _ = try await service.startWorkload(
            workloadRequest(root: fixture.root),
            stdio: []
        )
        let handle = try await service.dialService(request)
        try handle.close()
        #expect(await sandbox.listenedVsockPorts == [12_345])
        #expect(await sandbox.dialedVsockPorts.isEmpty)

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(
                EngineLinuxSandboxServiceDialRequestV1(
                    sandboxID: "engine-sandbox",
                    sandboxGeneration: 1,
                    workloadID: "workload-1",
                    workloadProcessGeneration: 4,
                    port: 12_345
                )
            )
        }
        #expect(await sandbox.listenedVsockPorts == [12_345])
    }

    @Test
    func protectedServiceDialBoundsAReverseVsockAcceptThatNeverConnects() async throws {
        let sandbox = FakeEngineLinuxSandbox(
            serviceListenerWaitsForConnection: true
        )
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        _ = try await service.startWorkload(
            workloadRequest(root: fixture.root),
            stdio: []
        )
        let request = EngineLinuxSandboxServiceDialRequestV1(
            sandboxID: "engine-sandbox",
            sandboxGeneration: 1,
            workloadID: "workload-1",
            workloadProcessGeneration: 3,
            port: 12_345
        )

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(request)
        }
        #expect(clock.now - start < .seconds(3))
        #expect(await sandbox.listenedVsockPorts == [12_345])
        #expect(await sandbox.closedServiceListenerCount() == 1)
    }

    @Test
    func protectedServiceDialRejectsUndeclaredVsockEndpoint() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture(endpoint: .none)
        defer { fixture.remove() }
        _ = try await service.startWorkload(
            workloadRequest(root: fixture.root),
            stdio: []
        )
        #expect(await sandbox.configuredGuestDevices.isEmpty)

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(
                EngineLinuxSandboxServiceDialRequestV1(
                    sandboxID: "engine-sandbox",
                    sandboxGeneration: 1,
                    workloadID: "workload-1",
                    workloadProcessGeneration: 3,
                    port: 12_345
                )
            )
        }
        #expect(await sandbox.listenedVsockPorts.isEmpty)
    }

    @Test
    func protectedServiceDialUsesValidatedGuestVsockEndpoint() async throws {
        let sandbox = FakeEngineLinuxSandbox()
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture(endpoint: .guestVsock)
        defer { fixture.remove() }
        _ = try await service.startWorkload(
            workloadRequest(root: fixture.root),
            stdio: []
        )

        let handle = try await service.dialService(
            EngineLinuxSandboxServiceDialRequestV1(
                sandboxID: "engine-sandbox",
                sandboxGeneration: 1,
                workloadID: "workload-1",
                workloadProcessGeneration: 3,
                port: 12_345
            )
        )
        try handle.close()

        #expect(await sandbox.dialedVsockPorts == [12_345])
        #expect(await sandbox.listenedVsockPorts.isEmpty)
        #expect(await sandbox.configuredGuestDevices.isEmpty)
    }

    @Test
    func monitoredWorkloadWithdrawalFencesDialAndAllowsRematerialization() async throws {
        let sandbox = FakeEngineLinuxSandbox(terminalOnWait: true)
        let service = try makeService(sandbox: sandbox)
        _ = try await service.boot(bootRequest())
        let fixture = try WorkloadBundleFixture()
        defer { fixture.remove() }
        let request = try workloadRequest(root: fixture.root, monitorTerminal: true)

        let first = try await service.startWorkload(request, stdio: [])
        await waitForTerminalObservation(
            service: service,
            request: request
        )
        #expect(try await service.observeWorkloadStart(request) == .absent)
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.dialService(
                EngineLinuxSandboxServiceDialRequestV1(
                    sandboxID: "engine-sandbox",
                    sandboxGeneration: 1,
                    workloadID: "workload-1",
                    workloadProcessGeneration: 3,
                    port: 12_345
                )
            )
        }
        #expect(await sandbox.stopContainerCount == 1)

        #expect(try await service.startWorkload(request, stdio: []) == first)
        #expect(await sandbox.addCount == 2)
        #expect(await sandbox.startCount == 2)
        #expect(await sandbox.removeCount == 1)
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
        let workloadRequest = try workloadRequest(
            root: URL(fileURLWithPath: "/tmp/engine-workload"),
            configurationDigest: "sha256:workload"
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
        let workloadStopRequest = workloadStopRequest()
        let workloadStopObservation =
            EngineLinuxSandboxWorkloadStopObservationV1.stopped(
                EngineLinuxSandboxWorkloadStopReceiptV1(
                    request: workloadStopRequest
                )
            )
        let dial = EngineLinuxSandboxServiceDialRequestV1(
            sandboxID: "engine-sandbox",
            sandboxGeneration: 1,
            workloadID: "workload-1",
            workloadProcessGeneration: 3,
            port: 12_345
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
        #expect(
            try JSONDecoder().decode(
                EngineLinuxSandboxWorkloadStopObservationV1.self,
                from: JSONEncoder().encode(workloadStopObservation)
            ) == workloadStopObservation
        )
        #expect(
            try JSONDecoder().decode(
                EngineLinuxSandboxServiceDialRequestV1.self,
                from: JSONEncoder().encode(dial)
            ) == dial
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

    private func workloadRequest(
        root: URL,
        configurationDigest: String? = nil,
        monitorTerminal: Bool = false
    ) throws -> EngineLinuxSandboxWorkloadStartRequestV1 {
        let digest =
            try configurationDigest
            ?? EngineLinuxSandboxWorkloadIntegrityV1.configurationDigest(at: root)
        return .init(
            context: WorkloadStartContextV1(
                containerID: "workload-1",
                operationGeneration: 2,
                candidateProcessGeneration: 3,
                sandboxGeneration: 1,
                requestDigest: "workload-digest"
            ),
            workloadRoot: root,
            workloadConfigurationDigest: digest,
            dynamicEnvironment: ["BUILD_ID": "42"],
            monitorTerminal: monitorTerminal
        )
    }

    private func workloadStopRequest()
        -> EngineLinuxSandboxWorkloadStopRequestV1
    {
        .init(
            sandboxID: "engine-sandbox",
            sandboxGeneration: 1,
            workloadID: "workload-1",
            workloadProcessGeneration: 3,
            operationGeneration: 4,
            idempotencyKey: "stop-workload-1",
            requestDigest: "stop-workload-digest"
        )
    }

    private func waitForTerminalObservation(
        service: EngineLinuxSandboxRuntimeServiceV1,
        request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async {
        for _ in 0..<100 {
            if (try? await service.observeWorkloadStart(request)) == .absent {
                return
            }
            await Task.yield()
        }
        Issue.record("monitored workload did not reach terminal observation")
    }
}

private actor FakeEngineLinuxSandbox: EngineLinuxSandboxInstanceV1 {
    nonisolated let id = "engine-sandbox"
    private var state: LinuxSandboxRuntimeState
    private(set) var createCount = 0
    private(set) var stopCount = 0
    private(set) var addCount = 0
    private(set) var startCount = 0
    private(set) var stopContainerCount = 0
    private(set) var removeCount = 0
    private(set) var configuredArguments: [String] = []
    private(set) var configuredGuestDevices: [LinuxGuestDeviceRequest] = []
    private(set) var configuredStdout = false
    private(set) var configuredStderr = false
    private(set) var dialedVsockPorts: [UInt32] = []
    private(set) var listenedVsockPorts: [UInt32] = []
    private(set) var lastWaitTimeoutInSeconds: Int64?
    private var serviceListeners: [FakeEngineLinuxSandboxServiceListener] = []
    private var workloads: [String: LinuxSandboxWorkloadSnapshot] = [:]
    private let terminalOnWait: Bool
    private let failAdd: Bool
    private let serviceListenerWaitsForConnection: Bool

    init(
        state: LinuxSandboxRuntimeState = .absent,
        terminalOnWait: Bool = false,
        failAdd: Bool = false,
        serviceListenerWaitsForConnection: Bool = false
    ) {
        self.state = state
        self.terminalOnWait = terminalOnWait
        self.failAdd = failAdd
        self.serviceListenerWaitsForConnection = serviceListenerWaitsForConnection
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
        configuredGuestDevices = config.guestDevices
        configuredStdout = config.process.stdout != nil
        configuredStderr = config.process.stderr != nil
        if failAdd {
            throw ContainerizationError(.internalError, message: "mount")
        }
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

    func stopContainer(_ containerID: String) throws {
        guard workloads[containerID] != nil else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        stopContainerCount += 1
        workloads[containerID] = LinuxSandboxWorkloadSnapshot(
            id: containerID,
            state: .stopped,
            initProcessID: nil
        )
    }

    func removeContainer(_ containerID: String) {
        removeCount += 1
        workloads[containerID] = nil
    }

    func waitContainer(
        _ containerID: String,
        timeoutInSeconds: Int64?
    ) async throws -> Containerization.ExitStatus {
        guard terminalOnWait, workloads[containerID]?.state == .running else {
            throw ContainerizationError(
                .invalidState,
                message: "fake workload was not configured to terminate"
            )
        }
        lastWaitTimeoutInSeconds = timeoutInSeconds
        workloads[containerID] = LinuxSandboxWorkloadSnapshot(
            id: containerID,
            state: .stopped,
            initProcessID: nil
        )
        return Containerization.ExitStatus(exitCode: 0)
    }

    func workloadStatus(_ containerID: String) throws -> RuntimeStatus {
        guard let workload = workloads[containerID] else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        return switch workload.state {
        case .registered, .created, .stopped:
            .stopped
        case .running:
            .running
        case .paused:
            .paused
        case .recoveryRequired:
            .unknown
        }
    }

    func pauseWorkload(_ containerID: String) throws {
        guard workloads[containerID]?.state == .running else {
            throw ContainerizationError(.invalidState, message: "fake workload is not running")
        }
        workloads[containerID] = LinuxSandboxWorkloadSnapshot(
            id: containerID,
            state: .paused,
            initProcessID: 123
        )
    }

    func resumeWorkload(_ containerID: String) throws {
        guard workloads[containerID]?.state == .paused else {
            throw ContainerizationError(.invalidState, message: "fake workload is not paused")
        }
        workloads[containerID] = LinuxSandboxWorkloadSnapshot(
            id: containerID,
            state: .running,
            initProcessID: 123
        )
    }

    func signalWorkload(_ containerID: String, signal: String) throws {
        guard workloads[containerID] != nil else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        _ = signal
    }

    func resizeWorkload(
        _ containerID: String,
        width: UInt16,
        height: UInt16
    ) throws {
        guard workloads[containerID] != nil else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        _ = (width, height)
    }

    func workloadStatistics(_ containerID: String) throws -> ContainerStats {
        guard workloads[containerID] != nil else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        return ContainerStats(
            id: containerID,
            memoryUsageBytes: 1,
            memoryLimitBytes: 2,
            cpuUsageUsec: 3,
            networkRxBytes: 4,
            networkTxBytes: 5,
            blockReadBytes: 6,
            blockWriteBytes: 7,
            numProcesses: 1
        )
    }

    func workloadProcesses(_ containerID: String) throws -> ContainerProcesses {
        guard workloads[containerID] != nil else {
            throw ContainerizationError(.notFound, message: "fake workload is absent")
        }
        return ContainerProcesses(id: containerID, processIdentifiers: [123])
    }

    func dialVsock(port: UInt32) -> FileHandle {
        dialedVsockPorts.append(port)
        return Pipe().fileHandleForReading
    }

    func listenVsock(port: UInt32) -> any EngineLinuxSandboxServiceListenerV1 {
        listenedVsockPorts.append(port)
        let listener = FakeEngineLinuxSandboxServiceListener(
            hasInitialConnection: !serviceListenerWaitsForConnection
        )
        serviceListeners.append(listener)
        return listener
    }

    func closedServiceListenerCount() async -> Int {
        var result = 0
        for listener in serviceListeners {
            if await listener.isClosed() {
                result += 1
            }
        }
        return result
    }
}

private actor FakeEngineLinuxSandboxServiceListener:
    EngineLinuxSandboxServiceListenerV1
{
    private var connection: FileHandle?
    private var waiter: CheckedContinuation<FileHandle?, Never>?
    private var closed = false

    init(hasInitialConnection: Bool = true) {
        connection = hasInitialConnection ? Pipe().fileHandleForReading : nil
    }

    func nextConnection() async throws -> FileHandle {
        guard let connection else {
            guard !closed else {
                throw ContainerizationError(
                    .invalidState,
                    message: "fake reverse VSOCK listener is closed"
                )
            }
            guard
                let connection = await withCheckedContinuation({ continuation in
                    waiter = continuation
                })
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "fake reverse VSOCK listener finished without a connection"
                )
            }
            return connection
        }
        self.connection = nil
        return connection
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        try? connection?.close()
        connection = nil
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }

    func isClosed() -> Bool {
        closed
    }
}

private struct WorkloadBundleFixture {
    enum Endpoint {
        case reverseVsock
        case guestVsock
        case none
    }

    let sandboxRoot: URL
    let root: URL

    init(endpoint: Endpoint = .reverseVsock) throws {
        sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-sandbox-\(UUID())", isDirectory: true)
        root =
            sandboxRoot
            .appendingPathComponent("workloads", isDirectory: true)
            .appendingPathComponent("workload-1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let arguments: [String] =
            switch endpoint {
            case .reverseVsock:
                [
                    "--port", "12345",
                    EngineLinuxSandboxServiceEndpointV1.reverseHostVsockFlag,
                ]
            case .guestVsock:
                ["--port", "12345"]
            case .none:
                ["-c", "echo ready"]
            }
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: arguments,
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        var configuration = ContainerConfiguration(
            id: "workload-1",
            image: image,
            process: process
        )
        configuration.publishedSockets = []
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
        try? FileManager.default.removeItem(at: sandboxRoot)
    }

    func replaceCommand(_ oldValue: String, with newValue: String) throws {
        let configurationURL = root.appendingPathComponent("runtime-configuration.json")
        let data = try Data(contentsOf: configurationURL)
        guard let value = String(data: data, encoding: .utf8), value.contains(oldValue) else {
            throw ContainerizationError(
                .internalError,
                message: "test runtime configuration did not contain the expected command"
            )
        }
        try Data(value.replacingOccurrences(of: oldValue, with: newValue).utf8)
            .write(to: configurationURL)
    }
}
