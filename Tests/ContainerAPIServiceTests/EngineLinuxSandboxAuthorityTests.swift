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
import ContainerizationExtras
import CryptoKit
import Foundation
import Testing

@testable import ContainerAPIService

struct EngineLinuxSandboxAuthorityTests {
    @Test
    func concurrentEnsureReadyCoalescesRuntimeLaunch() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(
            runtime: runtime,
            launchDelay: .milliseconds(100)
        )
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try await authority.ensureReady(
                        configuration: fixture.sandboxConfiguration
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(await launcher.launchCount == 1)
        #expect(await runtime.bootCount == 1)
    }

    @Test
    func legacyAndExplicitSnapshotRootsShareConfigurationIdentity() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(runtime: runtime)
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let legacy = fixture.sandboxConfiguration
        let explicit = EngineLinuxSandboxRuntimeConfigurationV1(
            path: legacy.path,
            snapshotRoot: URL(
                fileURLWithPath: legacy.effectiveSnapshotRoot.path,
                isDirectory: false
            ),
            sandboxID: legacy.sandboxID,
            initialFilesystem: legacy.initialFilesystem,
            kernel: legacy.kernel,
            cpus: legacy.cpus,
            memoryInBytes: legacy.memoryInBytes,
            nestedVirtualization: legacy.nestedVirtualization,
            rosetta: legacy.rosetta
        )

        _ = try await authority.ensureReady(configuration: legacy)
        _ = try await authority.ensureReady(configuration: explicit)

        #expect(await launcher.launchCount == 1)
    }

    @Test
    func snapshotRootConfigurationPreservesLegacyLedgerDigest() throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let configuration = fixture.sandboxConfiguration
        let legacy = LegacySandboxRuntimeConfiguration(
            path: configuration.path,
            sandboxID: configuration.sandboxID,
            initialFilesystem: configuration.initialFilesystem,
            kernel: configuration.kernel,
            cpus: configuration.cpus,
            memoryInBytes: configuration.memoryInBytes,
            nestedVirtualization: configuration.nestedVirtualization,
            rosetta: configuration.rosetta
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(legacy))
        let expected = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()

        #expect(
            try EngineLinuxSandboxAuthorityV1.configurationDigest(configuration)
                == expected
        )
    }

    @Test
    func managedSharedClientUsesAuthorityWithoutDedicatedFallback() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
            from: fixture.workloadRoot
        )
        let containerConfiguration = try #require(
            runtimeConfiguration.containerConfiguration
        )
        var sharedConfiguration = containerConfiguration
        sharedConfiguration.requestedIsolation = .sharedVM
        sharedConfiguration.effectiveIsolation = .sharedVM
        sharedConfiguration.sandboxID = fixture.sandboxConfiguration.sandboxID
        let client = ManagedRuntimeClient.shared(
            SharedSandboxRuntimeClient(
                id: sharedConfiguration.id,
                workloadRoot: fixture.workloadRoot,
                containerConfiguration: sharedConfiguration,
                authority: authority,
                configurationProvider: StaticSandboxConfigurationProvider(
                    configuration: fixture.sandboxConfiguration
                )
            )
        )

        #expect(!client.isDedicated)
        try await client.bootstrap(
            stdio: [],
            networkBootstrapInfos: [],
            dynamicEnv: ["TEST": "1"]
        )
        try await client.startProcess(sharedConfiguration.id)
        #expect(try await client.state().status == .running)
        try await client.pause()
        #expect(try await client.state().status == .paused)
        try await client.resume()
        #expect(try await client.statistics().id == containerConfiguration.id)

        let error = await #expect(throws: ContainerizationError.self) {
            try await client.createProcess(
                "exec-1",
                config: sharedConfiguration.initProcess,
                stdio: []
            )
        }
        #expect(error?.code == .unsupported)
        #expect(await runtime.workloadStartCount == 1)

        try await client.stop(options: .default)
        #expect(await runtime.workloadStopCount == 1)
        try await client.shutdown()
        #expect(await runtime.workloadStopCount == 1)
    }

    @Test
    func managedSharedClientProjectsDefaultNetworkIntoWorkloadEndpoint() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let runtimeConfiguration =
            try RuntimeConfiguration
            .readRuntimeConfiguration(from: fixture.workloadRoot)
        var containerConfiguration = try #require(
            runtimeConfiguration.containerConfiguration
        )
        containerConfiguration.requestedIsolation = .sharedVM
        containerConfiguration.effectiveIsolation = .sharedVM
        containerConfiguration.sandboxID = fixture.sandboxConfiguration.sandboxID
        containerConfiguration.networks = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(
                    hostname: "workload.test.",
                    aliases: ["workload"],
                    mtu: 1400,
                    guestInterfaceName: "service0",
                    additionalIPAddresses: [try CIDR("192.0.2.8/32")]
                )
            )
        ]
        let attachment = ContainerResource.Attachment(
            network: "default",
            hostname: "workload.test.",
            aliases: ["workload"],
            ipv4Address: try CIDRv4("192.168.64.8/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: try CIDRv6("fd00::8/64"),
            ipv6Gateway: try IPv6Address("fd00::1"),
            macAddress: try MACAddress("f2:00:00:00:00:08"),
            mtu: 1280
        )
        let networkAllocator = FakeSharedSandboxNetworkAllocator(
            attachments: [attachment]
        )
        let client = SharedSandboxRuntimeClient(
            id: containerConfiguration.id,
            workloadRoot: fixture.workloadRoot,
            containerConfiguration: containerConfiguration,
            authority: authority,
            configurationProvider: StaticSandboxConfigurationProvider(
                configuration: fixture.sandboxConfiguration
            ),
            networkAllocator: networkAllocator
        )

        try await client.bootstrap(
            stdio: [],
            networkBootstrapInfos: [
                NetworkBootstrapInfo(plugin: "container-network-vmnet")
            ],
            dynamicEnv: [:]
        )

        let request = try #require(await runtime.lastWorkloadStart)
        let endpoint = try #require(request.networkEndpoints.first)
        #expect(request.networkEndpoints.count == 1)
        #expect(endpoint.hostInterfaceName.utf8.count == 15)
        #expect(endpoint.hostInterfaceName.hasPrefix("cw"))
        #expect(
            endpoint.hostInterfaceName
                == SharedSandboxRuntimeClient.hostInterfaceName(
                    containerID: containerConfiguration.id,
                    interfaceIndex: 0
                )
        )
        #expect(
            endpoint.bridgeInterfaceName
                == EngineLinuxSandboxNetworkingV1.workloadBridgeName
        )
        #expect(endpoint.interface.name == "service0")
        #expect(endpoint.interface.mtu == 1400)
        #expect(
            endpoint.interface.addresses.map(\.address.description)
                == ["192.168.64.8/24", "192.0.2.8/32", "fd00::8/64"]
        )
        #expect(
            endpoint.interface.routes.map { $0.nextHop?.description }
                == ["192.168.64.1", "fd00::1"]
        )
        #expect(try await client.state().networks.count == 1)
        #expect(await networkAllocator.configurationCount == 1)
        #expect(await networkAllocator.plugins == ["container-network-vmnet"])
    }

    @Test
    func managedSharedClientReclaimsNaturallyExitedWorkloadOnShutdown() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
            from: fixture.workloadRoot
        )
        let containerConfiguration = try #require(
            runtimeConfiguration.containerConfiguration
        )
        var sharedConfiguration = containerConfiguration
        sharedConfiguration.requestedIsolation = .sharedVM
        sharedConfiguration.effectiveIsolation = .sharedVM
        sharedConfiguration.sandboxID = fixture.sandboxConfiguration.sandboxID
        let client = ManagedRuntimeClient.shared(
            SharedSandboxRuntimeClient(
                id: sharedConfiguration.id,
                workloadRoot: fixture.workloadRoot,
                containerConfiguration: sharedConfiguration,
                authority: authority,
                configurationProvider: StaticSandboxConfigurationProvider(
                    configuration: fixture.sandboxConfiguration
                )
            )
        )

        try await client.bootstrap(
            stdio: [],
            networkBootstrapInfos: []
        )
        _ = try await client.wait(sharedConfiguration.id)
        try await client.shutdown()

        #expect(await runtime.workloadStopCount == 1)
        let workload = try #require(
            (await authority.snapshot()).workloads.first
        )
        #expect(workload.state == .stopped)
        #expect(workload.activeProcessGeneration == nil)
    }

    @Test
    func managedSharedStopUsesGuestDeadlineBeforeForcedSignal() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime(waitTimesOut: true)
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
            from: fixture.workloadRoot
        )
        var containerConfiguration = try #require(
            runtimeConfiguration.containerConfiguration
        )
        containerConfiguration.requestedIsolation = .sharedVM
        containerConfiguration.effectiveIsolation = .sharedVM
        containerConfiguration.sandboxID = fixture.sandboxConfiguration.sandboxID
        let client = ManagedRuntimeClient.shared(
            SharedSandboxRuntimeClient(
                id: containerConfiguration.id,
                workloadRoot: fixture.workloadRoot,
                containerConfiguration: containerConfiguration,
                authority: authority,
                configurationProvider: StaticSandboxConfigurationProvider(
                    configuration: fixture.sandboxConfiguration
                )
            )
        )

        try await client.bootstrap(
            stdio: [],
            networkBootstrapInfos: []
        )
        try await client.stop(
            options: ContainerStopOptions(
                timeoutInSeconds: 1,
                signal: "SIGTERM"
            )
        )

        #expect(await runtime.signals == ["SIGTERM", "SIGKILL"])
        #expect(await runtime.waitTimeouts == [1, nil])
        #expect(await runtime.workloadStopCount == 1)
    }

    @Test
    func managedSharedClientRejectsMismatchedDurableSandboxIdentity() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
            from: fixture.workloadRoot
        )
        var containerConfiguration = try #require(
            runtimeConfiguration.containerConfiguration
        )
        containerConfiguration.effectiveIsolation = .sharedVM
        containerConfiguration.sandboxID = "different-sandbox"
        let client = ManagedRuntimeClient.shared(
            SharedSandboxRuntimeClient(
                id: containerConfiguration.id,
                workloadRoot: fixture.workloadRoot,
                containerConfiguration: containerConfiguration,
                authority: authority,
                configurationProvider: StaticSandboxConfigurationProvider(
                    configuration: fixture.sandboxConfiguration
                )
            )
        )

        let error = await #expect(throws: ContainerizationError.self) {
            try await client.bootstrap(
                stdio: [],
                networkBootstrapInfos: []
            )
        }

        #expect(error?.code == .invalidState)
        #expect(await runtime.workloadStartCount == 0)
    }

    @Test
    func genericSharedControlCannotBypassDurablePauseTransaction() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let running = try await authority.startWorkload(
            planDigest: "sha256:pause-bypass-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )

        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await authority.controlWorkload(
                configuration: fixture.sandboxConfiguration,
                workloadID: running.containerID,
                workloadProcessGeneration: try #require(
                    running.activeProcessGeneration
                ),
                action: .pause
            )
        }

        #expect(error?.code == .invalidArgument)
        #expect(await runtime.pauseCount == 0)
    }

    @Test
    func sharedWorkloadPauseAndResumeAreDurableAndIdempotent() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let running = try await authority.startWorkload(
            planDigest: "sha256:pause-resume-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )
        let processGeneration = try #require(
            running.activeProcessGeneration
        )

        let paused = try await authority.pauseWorkload(
            configuration: fixture.sandboxConfiguration,
            workloadID: running.containerID,
            workloadProcessGeneration: processGeneration
        )
        #expect(paused.state == .paused)
        #expect(
            try await authority.pauseWorkload(
                configuration: fixture.sandboxConfiguration,
                workloadID: running.containerID,
                workloadProcessGeneration: processGeneration
            ) == paused
        )
        #expect(await runtime.pauseCount == 1)

        let resumed = try await authority.resumeWorkload(
            configuration: fixture.sandboxConfiguration,
            workloadID: running.containerID,
            workloadProcessGeneration: processGeneration
        )
        #expect(resumed.state == .running)
        #expect(
            try await authority.resumeWorkload(
                configuration: fixture.sandboxConfiguration,
                workloadID: running.containerID,
                workloadProcessGeneration: processGeneration
            ) == resumed
        )
        #expect(await runtime.resumeCount == 1)
    }

    @Test
    func authorityBootReclaimsEffectlessSharedWorkload() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let running = try await authority.startWorkload(
            planDigest: "sha256:boot-reclaim-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )

        let reclaimed = try #require(
            try await authority.reclaimEffectlessWorkloadAtBoot(
                configuration: fixture.sandboxConfiguration,
                workloadID: running.containerID
            )
        )

        #expect(reclaimed.state == .stopped)
        #expect(reclaimed.activeProcessGeneration == nil)
        #expect(await runtime.workloadStopCount == 1)
    }

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

        let serviceHandle = try await recovered.dialService(
            configuration: fixture.sandboxConfiguration,
            workloadID: running.containerID,
            workloadProcessGeneration: try #require(running.activeProcessGeneration),
            port: 12_345
        )
        try serviceHandle.close()
        #expect(await runtime.serviceDialCount == 1)
        #expect(await runtime.lastServiceDial?.sandboxGeneration == ready.generation)

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

    @Test
    func defaultFileLedgerPersistsSharedSandboxLifecycle() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(runtime: runtime)

        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher
        )
        let running = try await authority.startWorkload(
            planDigest: "sha256:file-ledger-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )

        let ledgerURL = fixture.sandboxRoot.appendingPathComponent(
            EngineLinuxSandboxAuthorityV1.ledgerFilename
        )
        let values = try ledgerURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: ledgerURL.path
        )
        #expect(running.state == .running)
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink != true)
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value
                == 0o600
        )

        let reopened = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher
        )
        let recovered = try await reopened.ensureReady(
            configuration: fixture.sandboxConfiguration
        )
        #expect(recovered.state == .ready)
        #expect(recovered.generation == 1)
        #expect((await reopened.snapshot()).workloads == [running])
    }

    @Test
    func diagnosticLedgerPersistencePreservesUnderlyingFailure() async throws {
        let persistence = FailingLedgerPersistence()
        let diagnostics = EngineLinuxSandboxLedgerPersistenceDiagnosticsV1(
            persistence: persistence,
            ledgerURL: URL(fileURLWithPath: "/tmp/engine-workload-ledger-v1.json")
        )

        await #expect(throws: LedgerPersistenceTestError.injectedFailure) {
            _ = try await diagnostics.load()
        }
        await #expect(throws: LedgerPersistenceTestError.injectedFailure) {
            try await diagnostics.save(Data([0x01]))
        }
        #expect(await persistence.loadCount == 1)
        #expect(await persistence.saveCount == 1)
    }

    @Test
    func monitoredTerminalWorkloadIsReconciledBeforeRestartAndDial() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(runtime: runtime)
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )

        let first = try await authority.startWorkload(
            planDigest: "sha256:service-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot,
            monitorTerminal: true
        )
        let firstGeneration = try #require(first.activeProcessGeneration)
        await runtime.markWorkloadTerminal()

        await #expect(throws: ContainerizationError.self) {
            _ = try await authority.dialService(
                configuration: fixture.sandboxConfiguration,
                workloadID: first.containerID,
                workloadProcessGeneration: firstGeneration + 1,
                port: 12_345
            )
        }
        #expect(await runtime.serviceDialCount == 0)

        let restarted = try await authority.startWorkload(
            planDigest: "sha256:service-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot,
            monitorTerminal: true
        )
        let restartedGeneration = try #require(restarted.activeProcessGeneration)
        #expect(restarted.state == .running)
        #expect(restartedGeneration == firstGeneration + 1)
        #expect(await runtime.workloadObservationCount == 1)
        #expect(await runtime.workloadStartCount == 2)

        await #expect(throws: ContainerizationError.self) {
            _ = try await authority.dialService(
                configuration: fixture.sandboxConfiguration,
                workloadID: restarted.containerID,
                workloadProcessGeneration: firstGeneration,
                port: 12_345
            )
        }
        let handle = try await authority.dialService(
            configuration: fixture.sandboxConfiguration,
            workloadID: restarted.containerID,
            workloadProcessGeneration: restartedGeneration,
            port: 12_345
        )
        try handle.close()
        #expect(await runtime.serviceDialCount == 1)
        #expect(await runtime.lastServiceDial?.workloadID == restarted.containerID)
        #expect(
            await runtime.lastServiceDial?.workloadProcessGeneration
                == restartedGeneration
        )
    }

    @Test
    func absentRuntimeAllowsDurableConfigurationUpgradeAndWorkloadRematerialization()
        async throws
    {
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
        let initial = try await first.startWorkload(
            planDigest: "sha256:old-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )
        #expect(initial.state == .running)
        await runtime.loseSandbox()

        let upgradedConfiguration = EngineLinuxSandboxRuntimeConfigurationV1(
            path: fixture.sandboxRoot,
            sandboxID: "engine-sandbox",
            initialFilesystem: .tmpfs(destination: "/", options: []),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/tmp/kernel"),
                platform: .linuxArm
            ),
            cpus: 6,
            memoryInBytes: 4 * 1_024 * 1_024 * 1_024
        )
        let recovered = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: persistence
        )
        let ready = try await recovered.ensureReady(
            configuration: upgradedConfiguration
        )
        #expect(ready.state == .ready)
        #expect(ready.generation == 2)
        #expect(await launcher.launchCount == 3)
        #expect(await launcher.stopCount == 1)
        #expect((await recovered.snapshot()).workloads.isEmpty)

        let rematerialized = try await recovered.startWorkload(
            planDigest: "sha256:new-plan",
            configuration: upgradedConfiguration,
            workloadRoot: fixture.workloadRoot
        )
        #expect(rematerialized.state == .running)
        #expect(rematerialized.activeSandboxGeneration == 2)
        #expect(await runtime.workloadStartCount == 2)
    }

    @Test
    func exactWorkloadReclamationStopsRuntimeBeforeLedgerCommit() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime(failFirstStopResponse: true)
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: FakeAuthorityLauncher(runtime: runtime),
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let running = try await authority.startWorkload(
            planDigest: "sha256:reclaimable-plan",
            configuration: fixture.sandboxConfiguration,
            workloadRoot: fixture.workloadRoot
        )
        let processGeneration = try #require(
            running.activeProcessGeneration
        )

        let stopped = try await authority.stopWorkload(
            configuration: fixture.sandboxConfiguration,
            workloadID: running.containerID,
            workloadProcessGeneration: processGeneration
        )
        #expect(stopped.state == .stopped)
        #expect(stopped.activeProcessGeneration == nil)
        #expect(await runtime.workloadStopCount == 1)

        let replay = try await authority.stopWorkload(
            configuration: fixture.sandboxConfiguration,
            workloadID: running.containerID,
            workloadProcessGeneration: processGeneration
        )
        #expect(replay == stopped)
        #expect(await runtime.workloadStopCount == 1)
    }

    @Test
    func shutdownReleasesAbsentAndRunningSandboxes() async throws {
        let fixture = try EngineSandboxAuthorityFixture()
        defer { fixture.remove() }
        let runtime = FakeAuthorityRuntime()
        let launcher = FakeAuthorityLauncher(runtime: runtime)
        let authority = try await EngineLinuxSandboxAuthorityV1.open(
            root: fixture.sandboxRoot,
            owningControllerID: "api-service",
            sandboxID: "engine-sandbox",
            launcher: launcher,
            persistence: InMemoryEngineWorkloadLedgerPersistenceV1()
        )
        let absent = try await authority.shutdownIfIdle(
            configuration: fixture.sandboxConfiguration
        )
        #expect(absent.state == .absent)
        #expect(await launcher.stopCount == 0)

        _ = try await authority.ensureReady(
            configuration: fixture.sandboxConfiguration
        )
        let stopped = try await authority.shutdownIfIdle(
            configuration: fixture.sandboxConfiguration
        )
        #expect(stopped.state == .absent)
        #expect(await launcher.stopCount == 1)
    }
}

private struct LegacySandboxRuntimeConfiguration: Codable {
    let path: URL
    let sandboxID: String
    let initialFilesystem: Filesystem
    let kernel: Kernel
    let cpus: Int
    let memoryInBytes: UInt64
    let nestedVirtualization: Bool
    let rosetta: Bool
}

private enum LedgerPersistenceTestError: Error, Equatable {
    case injectedFailure
}

private actor FailingLedgerPersistence: EngineWorkloadLedgerPersistenceV1 {
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    func load() throws -> Data? {
        loadCount += 1
        throw LedgerPersistenceTestError.injectedFailure
    }

    func save(_ data: Data) throws {
        saveCount += 1
        _ = data
        throw LedgerPersistenceTestError.injectedFailure
    }
}

private actor FakeAuthorityLauncher: EngineLinuxSandboxLaunchingV1 {
    private let runtime: FakeAuthorityRuntime
    private let launchDelay: Duration?
    private(set) var launchCount = 0
    private(set) var stopCount = 0

    init(runtime: FakeAuthorityRuntime, launchDelay: Duration? = nil) {
        self.runtime = runtime
        self.launchDelay = launchDelay
    }

    func launch(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> any EngineLinuxSandboxRuntimeClientV1 {
        try configuration.write()
        launchCount += 1
        if let launchDelay {
            try await Task.sleep(for: launchDelay)
        }
        return runtime
    }

    func stop(configuration: EngineLinuxSandboxRuntimeConfigurationV1) async throws {
        stopCount += 1
        _ = configuration
    }
}

private actor FakeAuthorityRuntime: EngineLinuxSandboxRuntimeClientV1 {
    private enum Failure: Error {
        case lostStopResponse
    }

    private let failFirstStopResponse: Bool
    private let waitTimesOut: Bool
    private var bootReceipt: EngineLinuxSandboxBootReceiptV1?
    private var workloadReceipt: WorkloadProcessReceiptV1?
    private var workloadStopReceipt: EngineLinuxSandboxWorkloadStopReceiptV1?
    private var workloadTerminal = false
    private var workloadStatus = RuntimeStatus.running
    private var didFailStopResponse = false
    private(set) var bootCount = 0
    private(set) var bootObservationCount = 0
    private(set) var workloadStartCount = 0
    private(set) var lastWorkloadStart: EngineLinuxSandboxWorkloadStartRequestV1?
    private(set) var workloadObservationCount = 0
    private(set) var workloadStopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var serviceDialCount = 0
    private(set) var lastServiceDial: EngineLinuxSandboxServiceDialRequestV1?
    private(set) var signals: [String] = []
    private(set) var waitTimeouts: [Int64?] = []

    init(
        failFirstStopResponse: Bool = false,
        waitTimesOut: Bool = false
    ) {
        self.failFirstStopResponse = failFirstStopResponse
        self.waitTimesOut = waitTimesOut
    }

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
        lastWorkloadStart = request
        if let workloadReceipt,
            workloadReceipt.containerID == request.context.containerID,
            workloadReceipt.operationGeneration == request.context.operationGeneration,
            workloadReceipt.processGeneration == request.context.candidateProcessGeneration,
            workloadReceipt.sandboxGeneration == request.context.sandboxGeneration,
            workloadReceipt.requestDigest == request.context.requestDigest,
            !workloadTerminal
        {
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
        workloadTerminal = false
        workloadStatus = .running
        _ = stdio
        return receipt
    }

    func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1 {
        workloadObservationCount += 1
        if workloadTerminal {
            return .absent
        }
        guard let workloadReceipt,
            workloadReceipt.containerID == request.context.containerID,
            workloadReceipt.operationGeneration == request.context.operationGeneration,
            workloadReceipt.processGeneration == request.context.candidateProcessGeneration,
            workloadReceipt.sandboxGeneration == request.context.sandboxGeneration,
            workloadReceipt.requestDigest == request.context.requestDigest
        else { return .absent }
        return .started(workloadReceipt)
    }

    func stopWorkload(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopReceiptV1 {
        if let workloadStopReceipt,
            workloadStopReceipt.request == request
        {
            return workloadStopReceipt
        }
        let receipt = EngineLinuxSandboxWorkloadStopReceiptV1(
            request: request
        )
        workloadStopCount += 1
        workloadStopReceipt = receipt
        workloadTerminal = true
        workloadStatus = .stopped
        if failFirstStopResponse, !didFailStopResponse {
            didFailStopResponse = true
            throw Failure.lostStopResponse
        }
        return receipt
    }

    func observeWorkloadStop(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopObservationV1 {
        if let workloadStopReceipt,
            workloadStopReceipt.request == request
        {
            return .stopped(workloadStopReceipt)
        }
        return workloadTerminal ? .absent : .running
    }

    func controlWorkload(
        _ request: EngineLinuxSandboxWorkloadControlRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadControlResponseV1 {
        guard
            let workloadReceipt,
            workloadReceipt.containerID == request.workloadID,
            workloadReceipt.processGeneration
                == request.workloadProcessGeneration,
            workloadReceipt.sandboxGeneration == request.sandboxGeneration,
            !workloadTerminal
        else {
            throw ContainerizationError(
                .invalidState,
                message: "fake workload control generation is not active"
            )
        }
        switch request.action {
        case .state:
            return .state(workloadStatus)
        case .wait(let timeoutInSeconds):
            waitTimeouts.append(timeoutInSeconds)
            if waitTimesOut, timeoutInSeconds != nil {
                throw ContainerizationError(
                    .timeout,
                    message: "fake workload wait timed out"
                )
            }
            return .exit(
                .init(
                    exitCode: 0,
                    exitedAt: Date(timeIntervalSince1970: 0)
                )
            )
        case .statistics:
            return .statistics(
                ContainerStats(
                    id: request.workloadID,
                    memoryUsageBytes: 1,
                    memoryLimitBytes: 2,
                    cpuUsageUsec: 3,
                    networkRxBytes: 4,
                    networkTxBytes: 5,
                    blockReadBytes: 6,
                    blockWriteBytes: 7,
                    numProcesses: 1
                )
            )
        case .processes:
            return .processes(
                ContainerProcesses(
                    id: request.workloadID,
                    processIdentifiers: [123]
                )
            )
        case .pause:
            pauseCount += 1
            workloadStatus = .paused
            return .none
        case .resume:
            resumeCount += 1
            workloadStatus = .running
            return .none
        case .signal(let signal):
            signals.append(signal)
            return .none
        case .resize:
            return .none
        }
    }

    func markWorkloadTerminal() {
        workloadTerminal = true
    }

    func loseSandbox() {
        bootReceipt = nil
        workloadReceipt = nil
        workloadStopReceipt = nil
        workloadTerminal = false
        workloadStatus = .running
    }

    func dialService(
        _ request: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> FileHandle {
        serviceDialCount += 1
        lastServiceDial = request
        return Pipe().fileHandleForReading
    }
}

private actor FakeSharedSandboxNetworkAllocator:
    SharedSandboxNetworkAllocating
{
    private let attachments: [ContainerResource.Attachment]
    private(set) var configurationCount = 0
    private(set) var plugins: [String] = []

    init(attachments: [ContainerResource.Attachment]) {
        self.attachments = attachments
    }

    func allocate(
        configurations: [AttachmentConfiguration],
        bootstrapInfos: [NetworkBootstrapInfo]
    ) async throws -> [ContainerResource.Attachment] {
        configurationCount = configurations.count
        plugins = bootstrapInfos.map(\.plugin)
        return attachments
    }
}

private struct StaticSandboxConfigurationProvider:
    EngineLinuxSandboxConfigurationProvidingV1
{
    let configuration: EngineLinuxSandboxRuntimeConfigurationV1

    func sandboxConfiguration() async throws
        -> EngineLinuxSandboxRuntimeConfigurationV1
    {
        configuration
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
