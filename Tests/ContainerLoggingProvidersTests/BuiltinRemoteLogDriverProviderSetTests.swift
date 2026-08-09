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

import Foundation
import NIOPosix
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct BuiltinRemoteLogDriverProviderSetTests {
    @Test func productionSetAtomicallyPublishesEveryMaintainedRemoteDriver() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let providers = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                providerGeneration: 7
            )
            let catalog = try await providers.registry.logDriverCatalog()

            #expect(
                Set(catalog.registeredNames) == [
                    "none", "json-file", "local", "syslog", "fluentd", "gelf",
                    "splunk", "awslogs", "gcplogs",
                ])
            for driver in [
                "syslog", "fluentd", "gelf", "splunk", "awslogs", "gcplogs",
            ] {
                let descriptor = try #require(
                    catalog.descriptor(named: driver)
                )
                #expect(descriptor.providerGeneration == 7)
                #expect(descriptor.providerIdentity.kind == .native)
                #expect(descriptor.placement == .macOSHost)
                #expect(descriptor.trust == .signed)
            }
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func restartStagesCompatibleNativeGenerationsForAuthorityCutover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-native-provider-set-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try FileLogDriverProviderRegistryPersistenceV1(
            fileURL: directory.appendingPathComponent("state-v1.json")
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            _ = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                providerGeneration: 7,
                registryPersistence: persistence
            )
            let reconstructed = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                providerGeneration: 8,
                registryPersistence: persistence
            )

            let providerID = SyslogLogDriverContract.providerIdentity.id
            #expect(
                await reconstructed.registry.activeGeneration(
                    providerID: providerID
                ) == 7
            )
            #expect(
                await reconstructed.registry.generationPhase(
                    providerID: providerID,
                    generation: 7
                ) == .active
            )
            #expect(
                await reconstructed.registry.generationPhase(
                    providerID: providerID,
                    generation: 8
                ) == .staged
            )
            #expect(
                await reconstructed.registry.selection(
                    providerID: providerID,
                    generation: 7
                )?.descriptor.providerGeneration == 7
            )
            let upgrades = try await reconstructed.registry.upgradeCandidates()
            #expect(upgrades.count == 6)
            let expectedUpgrade = try LogDriverProviderUpgradeV1(
                providerID: providerID,
                sourceGeneration: 7,
                targetGeneration: 8
            )
            #expect(upgrades.contains(expectedUpgrade))
            let catalog = try await reconstructed.registry.logDriverCatalog()
            #expect(
                catalog.descriptor(named: "syslog")?.providerGeneration == 7
            )
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func configurationRegistryIsExactReplaySafeAndGenerationFenced() async throws {
        let registry = BuiltinRemoteLogDriverConfigurationRegistry()
        let request = try Self.request()
        let binding = try Self.syslogBinding(request: request)

        try await registry.register(binding, for: request)
        try await registry.register(binding, for: request)
        let resolved: SyslogConfigurationBinding = try await registry.configuration(
            for: request
        )
        #expect(resolved == binding)
        #expect(await registry.registeredContextCount == 1)

        let conflicting = try SyslogConfigurationBinding(
            semanticRequestDigest: binding.semanticRequestDigest,
            containerID: binding.containerID,
            leaseGeneration: binding.leaseGeneration,
            providerID: binding.providerID,
            providerGeneration: binding.providerGeneration,
            configuration: Self.syslogConfiguration(hostname: "changed")
        )
        await #expect(
            throws: BuiltinRemoteLogDriverConfigurationError.contextConflict(
                request.sessionID
            )
        ) {
            try await registry.register(conflicting, for: request)
        }

        let stale = try Self.request(providerGeneration: 8)
        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        ) {
            let _: SyslogConfigurationBinding = try await registry.configuration(
                for: stale
            )
        }
        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        ) {
            try await registry.unregister(stale)
        }
        #expect(try await registry.unregister(request))
        #expect(try await !registry.unregister(request))
    }

    @Test func configurationRegistryRejectsCrossDriverResolution() async throws {
        let registry = BuiltinRemoteLogDriverConfigurationRegistry()
        let request = try Self.request()
        try await registry.register(
            Self.syslogBinding(request: request),
            for: request
        )

        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(expected: "fluentd", actual: "syslog")
        ) {
            let _: FluentdConfigurationBinding = try await registry.configuration(
                for: request
            )
        }
    }

    @Test func firstPluginGenerationIsLazyAndFailedUpgradeIsRolledBack() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let firstService = ProviderGenerationLifecycleFixture(
                readiness: .healthy(11)
            )
            let secondService = ProviderGenerationLifecycleFixture(
                readiness: .unavailable
            )
            let providers = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                dockerPluginInstallations: [
                    Self.pluginInstallation(
                        generation: 1,
                        service: firstService
                    ),
                    Self.pluginInstallation(
                        generation: 2,
                        service: secondService
                    ),
                ],
                providerGeneration: 7
            )

            #expect(
                await providers.registry.activeGeneration(
                    providerID: Self.pluginProviderIdentity.id
                ) == 1
            )
            #expect(
                await providers.registry.generationPhase(
                    providerID: Self.pluginProviderIdentity.id,
                    generation: 2
                ) == nil
            )
            #expect(await firstService.readinessProbeCount == 0)
            #expect(await secondService.readinessProbeCount == 1)
            #expect(await firstService.effectCallCount == 0)
            #expect(await secondService.effectCallCount == 0)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func firstPluginGenerationDoesNotRequireSandboxBootstrap() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = ProviderGenerationLifecycleFixture(
                readiness: .unavailable
            )
            let providers = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                dockerPluginInstallations: [
                    Self.pluginInstallation(
                        generation: 1,
                        service: service
                    )
                ],
                providerGeneration: 7
            )

            #expect(
                await providers.registry.activeGeneration(
                    providerID: Self.pluginProviderIdentity.id
                ) == 1
            )
            let catalog = try await providers.registry.logDriverCatalog()
            #expect(catalog.descriptor(named: "durable-plugin") != nil)
            #expect(await service.readinessProbeCount == 0)
            #expect(await service.effectCallCount == 0)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func restartStagesHealthyUpgradeWithoutPrematureCutoverOrEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-provider-set-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try FileLogDriverProviderRegistryPersistenceV1(
            fileURL: directory.appendingPathComponent("state-v1.json")
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let first = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                dockerPluginInstallations: [
                    Self.pluginInstallation(
                        generation: 1,
                        service: ProviderGenerationLifecycleFixture(
                            readiness: .healthy(11)
                        )
                    )
                ],
                providerGeneration: 7,
                registryPersistence: persistence
            )
            #expect(
                await first.registry.generationPhase(
                    providerID: Self.pluginProviderIdentity.id,
                    generation: 1
                ) == .active
            )
            #expect(
                await first.registry.activeGeneration(
                    providerID: Self.pluginProviderIdentity.id
                ) == 1
            )

            let reconstructedFirst = ProviderGenerationLifecycleFixture(
                readiness: .healthy(21)
            )
            let reconstructedSecond = ProviderGenerationLifecycleFixture(
                readiness: .healthy(22)
            )
            let reconstructed = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                dockerPluginInstallations: [
                    Self.pluginInstallation(
                        generation: 1,
                        service: reconstructedFirst
                    ),
                    Self.pluginInstallation(
                        generation: 2,
                        service: reconstructedSecond
                    ),
                ],
                providerGeneration: 7,
                registryPersistence: persistence
            )

            let catalog = try await reconstructed.registry.logDriverCatalog()
            let descriptor = try #require(
                catalog.descriptor(named: "durable-plugin")
            )
            #expect(descriptor.providerGeneration == 1)
            #expect(
                catalog.descriptors.filter {
                    $0.providerIdentity == Self.pluginProviderIdentity
                }.count == 1
            )
            #expect(
                await reconstructed.registry.generationPhase(
                    providerID: Self.pluginProviderIdentity.id,
                    generation: 1
                ) == .active
            )
            #expect(
                await reconstructed.registry.generationPhase(
                    providerID: Self.pluginProviderIdentity.id,
                    generation: 2
                ) == .staged
            )
            let candidate = try #require(
                try await reconstructed.registry.upgradeCandidates().first
            )
            #expect(candidate.sourceGeneration == 1)
            #expect(candidate.targetGeneration == 2)
            #expect(await reconstructedFirst.readinessProbeCount == 0)
            #expect(await reconstructedSecond.readinessProbeCount == 1)
            #expect(await reconstructedFirst.effectCallCount == 0)
            #expect(await reconstructedSecond.effectCallCount == 0)

            _ = try await reconstructed.registry.beginUpgrade(
                providerID: Self.pluginProviderIdentity.id,
                targetGeneration: 2
            )
            _ = try await reconstructed.registry.activate(
                providerID: Self.pluginProviderIdentity.id,
                generation: 2
            )
            #expect(
                try await reconstructed.registry.uninstall(
                    providerID: Self.pluginProviderIdentity.id,
                    generation: 1
                )
            )

            let activeService = ProviderGenerationLifecycleFixture(
                readiness: .healthy(31)
            )
            let recoveredActive = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                dockerPluginInstallations: [
                    Self.pluginInstallation(
                        generation: 2,
                        service: activeService
                    )
                ],
                providerGeneration: 7,
                registryPersistence: persistence
            )
            #expect(
                await recoveredActive.registry.activeGeneration(
                    providerID: Self.pluginProviderIdentity.id
                ) == 2
            )
            #expect(await activeService.readinessProbeCount == 0)
            let reclaimedGeneration = await recoveredActive.registry.selection(
                providerID: Self.pluginProviderIdentity.id,
                generation: 1
            )
            #expect(reclaimedGeneration?.descriptor == nil)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func request(
        providerGeneration: UInt64 = 7
    ) throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "start:container:1",
            semanticRequestDigest: "sha256:request",
            sessionID: "session-1",
            containerID: "container-1",
            leaseGeneration: 1,
            candidateProcessGeneration: 1,
            providerID: SyslogLogDriverContract.providerIdentity.id,
            providerGeneration: providerGeneration,
            candidateSandboxGeneration: nil
        )
    }

    private static func syslogBinding(
        request: LogDriverStartRequestV1
    ) throws -> SyslogConfigurationBinding {
        try SyslogConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            configuration: syslogConfiguration(hostname: "host")
        )
    }

    private static func syslogConfiguration(
        hostname: String
    ) throws -> SyslogDriverConfiguration {
        try SyslogDriverConfiguration(
            endpoint: .udp(
                SyslogNetworkAddress(host: "127.0.0.1", port: 514)
            ),
            facility: SyslogFacility(number: 1),
            format: .rfc5424,
            tag: Data("container".utf8),
            hostname: hostname,
            processID: 1,
            tls: nil,
            policy: .dockerCompatible
        )
    }

    private static let pluginProviderIdentity = LogDriverProviderIdentity(
        id: "io.container.logging.plugin.generation-tests",
        version: "1.0.0",
        kind: .dockerPlugin
    )

    private static func pluginInstallation(
        generation: UInt64,
        service: any DockerPluginLifecycleService
    ) -> DockerPluginLogDriverInstallation {
        DockerPluginLogDriverInstallation(
            driver: "durable-plugin",
            aliases: ["durable-plugin-alias"],
            providerIdentity: pluginProviderIdentity,
            providerGeneration: generation,
            readLogs: true,
            lifecycleService: service
        )
    }
}

private enum ProviderGenerationReadiness: Sendable {
    case healthy(UInt64)
    case unavailable
}

private enum ProviderGenerationLifecycleFixtureError: Error {
    case unavailable
    case unexpectedEffect
}

private actor ProviderGenerationLifecycleFixture: DockerPluginLifecycleService {
    private let readiness: ProviderGenerationReadiness
    private(set) var readinessProbeCount = 0
    private(set) var effectCallCount = 0

    init(readiness: ProviderGenerationReadiness) {
        self.readiness = readiness
    }

    func activeSandboxGeneration() throws -> UInt64 {
        readinessProbeCount += 1
        switch readiness {
        case .healthy(let generation):
            return generation
        case .unavailable:
            throw ProviderGenerationLifecycleFixtureError.unavailable
        }
    }

    func startWriter(
        _ request: DockerPluginWriterOpenRequest
    ) throws -> DockerPluginServiceStartedWriter {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) throws -> DockerPluginServiceWriterReconciliation {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func reconcileWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func fenceWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func closeWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func openReader(
        _ request: DockerPluginReaderOpenRequest
    ) throws -> DockerPluginServiceStartedReader {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> DockerPluginServiceReaderReconciliation {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) throws -> LogDriverReaderAcknowledgementV1 {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) throws -> LogDriverReaderAcknowledgementV1 {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }

    func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) throws {
        effectCallCount += 1
        throw ProviderGenerationLifecycleFixtureError.unexpectedEffect
    }
}
