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

import ContainerEngineLogging
import ContainerLoggingProviders
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct ContainerLoggingAuthorityIntegrationTests {
    @Test func providerUpgradeMigratesAndResealsDurableConfigurationBeforeCutover() async throws {
        try await withTemporaryRoot { root in
            let identity = LogDriverProviderIdentity(
                id: "test.logging.migration-plugin",
                version: "1.0.0",
                kind: .dockerPlugin
            )
            let sourcePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 11
                        )
                    )
                ]
            )
            let sourceService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: sourcePlane
            )
            let protectedValue = "DO_NOT_EXPOSE_MIGRATION_VALUE"
            let plan = try await sourceService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "migration-plugin",
                    options: ["opaque": protectedValue]
                )
            )
            let sealed = try await sourceService.sealLoggingForCreate(
                containerID: "migrated-provider",
                plan: plan
            )
            let sourceReference = try #require(sealed.protectedReference)
            let bundle = try persistConfiguration(
                appRoot: root,
                id: "migrated-provider",
                logging: sealed.configuration
            )

            let upgradePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 21
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 22
                        )
                    ),
                ]
            )
            let upgradeService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: upgradePlane
            )
            try await upgradeService.reconcileLoggingProviderUpgrades()

            let migrated = try bundle.configuration
            let migratedResolved = try #require(migrated.logging.resolved)
            #expect(migratedResolved.providerGenerationAtResolution == 2)
            #expect(migratedResolved.leaseGeneration == 2)
            #expect(migratedResolved.contractDigest == sealed.configuration.resolved?.contractDigest)
            #expect(
                migratedResolved.protectedOptionReference?.objectID
                    != sourceReference.objectID
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: protectedObjectURL(
                        appRoot: root,
                        objectID: sourceReference.objectID
                    ).path
                )
            )
            #expect(
                try await upgradeService.validateLoggingForStart(
                    containerID: "migrated-provider",
                    configuration: migrated.logging
                )["opaque"] == protectedValue
            )
            #expect(
                try await upgradePlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin")?
                    .providerGeneration == 2
            )
            #expect(try await upgradePlane.providerUpgradeCandidates().isEmpty)

            let restartedPlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 32
                        )
                    )
                ]
            )
            let restartedService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: restartedPlane
            )
            try await restartedService.reconcileLoggingProviderUpgrades()
            #expect(
                try await restartedService.validateLoggingForStart(
                    containerID: "migrated-provider",
                    configuration: bundle.configuration.logging
                )["opaque"] == protectedValue
            )
        }
    }

    @Test func interruptedProviderUpgradeResumesForwardWithoutDualAdmission() async throws {
        try await withTemporaryRoot { root in
            let identity = LogDriverProviderIdentity(
                id: "test.logging.restart-migration-plugin",
                version: "1.0.0",
                kind: .dockerPlugin
            )
            let sourcePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 41
                        )
                    )
                ]
            )
            let sourceService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: sourcePlane
            )
            var bundles = [ContainerResource.Bundle]()
            for id in ["migration-a", "migration-b"] {
                let plan = try await sourceService.prepareLoggingForCreate(
                    configuration: .default,
                    request: ContainerLogRequest(
                        driver: "migration-plugin",
                        options: ["opaque": "protected-\(id)"]
                    )
                )
                let sealed = try await sourceService.sealLoggingForCreate(
                    containerID: id,
                    plan: plan
                )
                bundles.append(
                    try persistConfiguration(
                        appRoot: root,
                        id: id,
                        logging: sealed.configuration
                    )
                )
            }

            let interruptedPlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 51
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 52
                        )
                    ),
                ]
            )
            let interruptedService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: interruptedPlane
            )
            await #expect(throws: AuthorityMigrationPluginError.injectedRestart) {
                try await interruptedService.reconcileLoggingProviderUpgrades {
                    _ in
                    throw AuthorityMigrationPluginError.injectedRestart
                }
            }
            #expect(
                try await interruptedPlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin") == nil
            )
            let interruptedGenerations = try bundles.map {
                try #require($0.configuration.logging.resolved)
                    .providerGenerationAtResolution
            }.sorted()
            #expect(interruptedGenerations == [1, 2])

            let resumedPlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 61
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 62
                        )
                    ),
                ]
            )
            let resumedService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: resumedPlane
            )
            try await resumedService.reconcileLoggingProviderUpgrades()

            for bundle in bundles {
                let resolved = try #require(
                    bundle.configuration.logging.resolved
                )
                #expect(resolved.providerGenerationAtResolution == 2)
                #expect(resolved.leaseGeneration == 2)
            }
            #expect(
                try await resumedPlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin")?
                    .providerGeneration == 2
            )
            #expect(try await resumedPlane.providerUpgradeCandidates().isEmpty)
        }
    }

    @Test func incompatibleProviderContractCancelsQuiescenceWithoutMutation() async throws {
        try await withTemporaryRoot { root in
            let identity = LogDriverProviderIdentity(
                id: "test.logging.incompatible-migration-plugin",
                version: "1.0.0",
                kind: .dockerPlugin
            )
            let sourcePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 71
                        )
                    )
                ]
            )
            let sourceService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: sourcePlane
            )
            let plan = try await sourceService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(driver: "migration-plugin")
            )
            let sealed = try await sourceService.sealLoggingForCreate(
                containerID: "incompatible-migration",
                plan: plan
            )
            let bundle = try persistConfiguration(
                appRoot: root,
                id: "incompatible-migration",
                logging: sealed.configuration
            )

            let upgradePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 81
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        readLogs: false,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 82
                        )
                    ),
                ]
            )
            let upgradeService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: upgradePlane
            )
            let error = await #expect(throws: ContainerizationError.self) {
                try await upgradeService.reconcileLoggingProviderUpgrades()
            }
            #expect(error?.code == .invalidState)
            #expect(error?.message.contains("incompatible frozen contract") == true)
            let unchanged = try #require(bundle.configuration.logging.resolved)
            #expect(unchanged.providerGenerationAtResolution == 1)
            #expect(unchanged.leaseGeneration == 1)
            #expect(
                try await upgradePlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin")?
                    .providerGeneration == 1
            )
        }
    }

    @Test func unsupportedHistoryMigrationCancelsQuiescenceWithoutMutation()
        async throws
    {
        try await withTemporaryRoot { root in
            let identity = LogDriverProviderIdentity(
                id: "test.logging.unsupported-history-plugin",
                version: "1.0.0",
                kind: .dockerPlugin
            )
            let sourcePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 83
                        )
                    )
                ]
            )
            let sourceService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: sourcePlane
            )
            let plan = try await sourceService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "migration-plugin",
                    options: ["opaque": "protected-history"]
                )
            )
            let sealed = try await sourceService.sealLoggingForCreate(
                containerID: "unsupported-history",
                plan: plan
            )
            let bundle = try persistConfiguration(
                appRoot: root,
                id: "unsupported-history",
                logging: sealed.configuration
            )
            try await persistTerminalWriterHistory(
                bundle: bundle,
                configuration: bundle.configuration,
                sandboxGeneration: 83
            )
            let sourceReference = sealed.protectedReference

            let unsupportedTarget = AuthorityMigrationPluginService(
                sandboxGeneration: 85,
                supportsHistoryMigration: false
            )
            let upgradePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 84
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: unsupportedTarget
                    ),
                ]
            )
            let upgradeService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: upgradePlane
            )
            await #expect(
                throws: LogDriverHistoryMigrationError.unsupported
            ) {
                try await upgradeService.reconcileLoggingProviderUpgrades()
            }

            let unchanged = try #require(
                bundle.configuration.logging.resolved
            )
            #expect(unchanged.providerGenerationAtResolution == 1)
            #expect(unchanged.leaseGeneration == 1)
            #expect(unchanged.providerHistoryMigrationReceipt == nil)
            #expect(
                unchanged.protectedOptionReference == sourceReference
            )
            #expect(await unsupportedTarget.historyMigrationRequestCount == 1)
            #expect(
                try await upgradePlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin")?
                    .providerGeneration == 1
            )
        }
    }

    @Test func providerHistoryReceiptSurvivesCrashAfterConfigurationPublication() async throws {
        try await withTemporaryRoot { root in
            let identity = LogDriverProviderIdentity(
                id: "test.logging.history-migration-plugin",
                version: "1.0.0",
                kind: .dockerPlugin
            )
            let sourcePlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 91
                        )
                    )
                ]
            )
            let sourceService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: sourcePlane
            )
            let plan = try await sourceService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "migration-plugin",
                    options: ["opaque": "history-protected-value"]
                )
            )
            let sealed = try await sourceService.sealLoggingForCreate(
                containerID: "history-migration",
                plan: plan
            )
            let bundle = try persistConfiguration(
                appRoot: root,
                id: "history-migration",
                logging: sealed.configuration
            )
            try await persistTerminalWriterHistory(
                bundle: bundle,
                configuration: bundle.configuration,
                sandboxGeneration: 91
            )

            let interruptedTarget = AuthorityMigrationPluginService(
                sandboxGeneration: 102
            )
            let interruptedPlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 101
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: interruptedTarget
                    ),
                ]
            )
            let interruptedService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: interruptedPlane
            )
            await #expect(throws: AuthorityMigrationPluginError.injectedRestart) {
                try await interruptedService.reconcileLoggingProviderUpgrades {
                    _ in
                    throw AuthorityMigrationPluginError.injectedRestart
                }
            }
            let interrupted = try #require(
                bundle.configuration.logging.resolved
            )
            let receipt = try #require(
                interrupted.providerHistoryMigrationReceipt
            )
            #expect(interrupted.providerGenerationAtResolution == 2)
            #expect(interrupted.leaseGeneration == 2)
            #expect(receipt.request.sourceProviderGeneration == 1)
            #expect(receipt.request.targetProviderGeneration == 2)
            #expect(await interruptedTarget.historyMigrationRequestCount == 1)
            #expect(
                try await interruptedPlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin") == nil
            )

            let resumedTarget = AuthorityMigrationPluginService(
                sandboxGeneration: 112
            )
            let resumedPlane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityMigrationAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 1,
                        service: AuthorityMigrationPluginService(
                            sandboxGeneration: 111
                        )
                    ),
                    Self.migrationPluginInstallation(
                        identity: identity,
                        generation: 2,
                        service: resumedTarget
                    ),
                ]
            )
            let resumedService = try makeService(
                appRoot: root,
                includeRuntime: true,
                remoteLogDriverPlane: resumedPlane
            )
            try await resumedService.reconcileLoggingProviderUpgrades()

            #expect(await resumedTarget.historyMigrationRequestCount == 0)
            #expect(
                try await resumedService.validateLoggingForStart(
                    containerID: "history-migration",
                    configuration: bundle.configuration.logging
                )["opaque"] == "history-protected-value"
            )
            #expect(
                try await resumedPlane.logDriverCatalog()
                    .descriptor(named: "migration-plugin")?
                    .providerGeneration == 2
            )
        }
    }

    @Test func engineInspectAuthenticatesProtectedOptionsAtAuthorityBoundary() async throws {
        try await withTemporaryRoot { root in
            let id = "engine-protected-inspect"
            let token = "DO_NOT_EXPOSE_SPLUNK_TOKEN"
            let descriptor = SplunkLogDriverContract.descriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors + [
                    descriptor
                ]
            )
            let catalogProvider = StaticLogDriverCatalogProvider(catalog: catalog)
            let sealingService = try makeService(
                appRoot: root,
                includeRuntime: false,
                logDriverCatalogProvider: catalogProvider
            )
            let plan = try await sealingService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "splunk",
                    options: [
                        "splunk-token": token,
                        "splunk-url": "https://splunk.example.test:8088",
                        "splunk-verify-connection": "false",
                    ]
                )
            )
            let sealed = try await sealingService.sealLoggingForCreate(
                containerID: id,
                plan: plan
            )
            _ = try persistConfiguration(
                appRoot: root,
                id: id,
                logging: sealed.configuration
            )

            let authoritativeService = try makeService(
                appRoot: root,
                includeRuntime: true,
                logDriverCatalogProvider: catalogProvider
            )
            let backend = ContainerDockerLoggingBackend(
                containers: authoritativeService
            )
            let inspection = try await backend.inspectContainerLogging(
                containerID: id
            )
            #expect(inspection.configuration.driver == "splunk")
            #expect(inspection.configuration.options["splunk-token"] == token)
            #expect(
                inspection.configuration.options["splunk-url"]
                    == "https://splunk.example.test:8088"
            )
            #expect(inspection.publicLogPath == nil)
        }
    }

    @Test func splunkCreateSealsTokenAndPinsProviderContract() async throws {
        try await withTemporaryRoot { root in
            let token = "DO_NOT_EXPOSE_SPLUNK_TOKEN"
            let descriptor = SplunkLogDriverContract.descriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors + [
                    descriptor
                ]
            )
            let service = try makeService(
                appRoot: root,
                includeRuntime: false,
                logDriverCatalogProvider: StaticLogDriverCatalogProvider(
                    catalog: catalog
                )
            )

            let plan = try await service.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "splunk",
                    options: [
                        "splunk-token": token,
                        "splunk-url": "https://splunk.example.test:8088",
                        "splunk-verify-connection": "false",
                    ]
                )
            )
            let sealed = try await service.sealLoggingForCreate(
                containerID: "splunk-sealed-token",
                plan: plan
            )
            let resolved = try #require(sealed.configuration.resolved)
            #expect(resolved.driver == "splunk")
            #expect(resolved.providerIdentity == descriptor.providerIdentity)
            #expect(resolved.contractDigest == descriptor.optionContractDigest)
            #expect(resolved.safeOptions["splunk-token"] == nil)
            #expect(resolved.protectedOptionNames == ["splunk-token"])
            #expect(sealed.protectedReference != nil)
            #expect(!String(describing: sealed.configuration).contains(token))
            #expect(
                !String(
                    decoding: try JSONEncoder().encode(sealed.configuration),
                    as: UTF8.self
                ).contains(token)
            )

            _ = try await service.validateLoggingForStart(
                containerID: "splunk-sealed-token",
                configuration: sealed.configuration
            )
            await service.rollbackSealedLogging(sealed)
        }
    }

    @Test func injectedCatalogIsRequeriedAtCreateAndStartBoundaries() async throws {
        try await withTemporaryRoot { root in
            let descriptor = try testProviderDescriptor()
            let catalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors + [descriptor]
            )
            let provider = RecordingLogDriverCatalogProvider(catalog: catalog)
            let service = try makeService(
                appRoot: root,
                includeRuntime: false,
                logDriverCatalogProvider: provider
            )

            let plan = try await service.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "test-remote-alias",
                    options: ["endpoint": "collector.example:1234"]
                )
            )
            let sealed = try await service.sealLoggingForCreate(
                containerID: "catalog-boundaries",
                plan: plan
            )
            let resolved = try #require(sealed.configuration.resolved)
            #expect(resolved.driver == descriptor.driver)
            #expect(resolved.providerIdentity == descriptor.providerIdentity)
            #expect(resolved.providerGenerationAtResolution == descriptor.providerGeneration)
            #expect(resolved.readPolicy.source == .dualCache)

            _ = try await service.validateLoggingForStart(
                containerID: "catalog-boundaries",
                configuration: sealed.configuration
            )
            #expect(await provider.requestCount == 2)
        }
    }

    @Test func providerGenerationChangeBetweenCreateAndStartFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let createDescriptor = try testProviderDescriptor(providerGeneration: 7)
            let startDescriptor = try testProviderDescriptor(providerGeneration: 8)
            let createCatalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors + [createDescriptor]
            )
            let startCatalog = try LogDriverCatalog(
                descriptors: BuiltinLogDriverDescriptors.current.descriptors + [startDescriptor]
            )
            let provider = RecordingLogDriverCatalogProvider(
                catalogs: [createCatalog, startCatalog]
            )
            let service = try makeService(
                appRoot: root,
                includeRuntime: false,
                logDriverCatalogProvider: provider
            )
            let plan = try await service.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(driver: createDescriptor.driver)
            )
            let sealed = try await service.sealLoggingForCreate(
                containerID: "changed-provider-generation",
                plan: plan
            )

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.validateLoggingForStart(
                    containerID: "changed-provider-generation",
                    configuration: sealed.configuration
                )
            }
            #expect(error?.code == .invalidState)
            #expect(error?.message.contains("provider generation") == true)
            #expect(await provider.requestCount == 2)
        }
    }

    @Test func sealedCreateConfigurationIsIdenticalAcrossRuntimeAndSnapshotPersistence() async throws {
        try await withTemporaryRoot { root in
            let secret = "DO_NOT_EXPOSE_THIS_VALUE"
            let service = try makeService(appRoot: root, includeRuntime: false)
            let plan = try ContainersService.prepareLoggingForCreate(
                configuration: .default,
                request: ContainerLogRequest(
                    driver: "none",
                    options: ["opaque": secret]
                ),
                defaults: LoggingConfig()
            )
            let sealed = try await service.sealLoggingForCreate(
                containerID: "same-config",
                plan: plan
            )

            var configuration = testConfiguration(id: "same-config")
            configuration.logging = sealed.configuration
            let runtimeConfiguration = RuntimeConfiguration(
                path: root.appendingPathComponent("containers/same-config"),
                initialFilesystem: .virtiofs(
                    source: "/private/tmp/init",
                    destination: "/",
                    options: ["ro"]
                ),
                kernel: Kernel(
                    path: URL(fileURLWithPath: "/private/tmp/kernel"),
                    platform: .linuxArm
                ),
                containerConfiguration: configuration
            )
            let snapshot = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: []
            )

            let runtimeData = try JSONEncoder().encode(runtimeConfiguration)
            let snapshotData = try JSONEncoder().encode(snapshot)
            let decodedRuntime = try JSONDecoder().decode(
                RuntimeConfiguration.self,
                from: runtimeData
            )
            let decodedSnapshot = try JSONDecoder().decode(
                ContainerSnapshot.self,
                from: snapshotData
            )
            #expect(decodedRuntime.containerConfiguration?.logging == sealed.configuration)
            #expect(decodedSnapshot.configuration.logging == sealed.configuration)
            #expect(!String(decoding: runtimeData, as: UTF8.self).contains(secret))
            #expect(!String(decoding: snapshotData, as: UTF8.self).contains(secret))

            let reference = try #require(sealed.protectedReference)
            let objectURL = protectedObjectURL(
                appRoot: root,
                objectID: reference.objectID
            )
            #expect(FileManager.default.fileExists(atPath: objectURL.path))
            await service.rollbackSealedLogging(sealed)
            #expect(!FileManager.default.fileExists(atPath: objectURL.path))
        }
    }

    @Test func startAuthenticatesProtectedReferenceBeforeRuntimeOrNetworkSideEffects() async throws {
        try await withTemporaryRoot { root in
            let id = "substitution-victim"
            let secret = "DO_NOT_EXPOSE_THIS_VALUE"
            let prepared = try makeResolver().prepare(
                ContainerLogRequest(
                    driver: "none",
                    options: ["opaque": secret]
                )
            )
            let wrongBinding = LoggingProtectedOptionsBinding(
                containerID: "different-owner",
                prepared: prepared,
                leaseGeneration: 1
            )
            let store = try LoggingProtectedOptionsStore(rootURL: protectedStoreURL(appRoot: root))
            let reference = try await store.store(
                ["opaque": secret],
                boundTo: wrongBinding
            )
            let logging = try prepared.finalizedConfiguration(protectedReference: reference)
            try persistConfiguration(appRoot: root, id: id, logging: logging)
            let service = try makeService(appRoot: root, includeRuntime: true)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.bootstrap(id: id, stdio: [], dynamicEnv: [:])
            }
            #expect(error?.code == .invalidState)
            #expect(error?.message == "protected container logging options failed authentication")
            #expect(!String(describing: error).contains(secret))
            let snapshot = try #require(try await service.list().first)
            #expect(snapshot.status == .stopped)
        }
    }

    @Test func deferredStartValidationFailsBeforeRuntimeRegistrationAndKeepsStoppedConfiguration() async throws {
        try await withTemporaryRoot { root in
            let id = "invalid-start-option"
            let invalidValue = "DO_NOT_EXPOSE_THIS_VALUE"
            let prepared = try makeResolver().prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: [
                        "compress": invalidValue,
                        "max-file": "2",
                        "max-size": "1m",
                    ]
                )
            )
            let logging = try prepared.finalizedConfiguration(protectedReference: nil)
            try persistConfiguration(appRoot: root, id: id, logging: logging)
            let service = try makeService(appRoot: root, includeRuntime: true)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.bootstrap(id: id, stdio: [], dynamicEnv: [:])
            }
            #expect(error?.code == .invalidState)
            #expect(error?.message.contains("invalid log option") == true)
            #expect(!String(describing: error).contains(invalidValue))
            let snapshot = try #require(try await service.list().first)
            #expect(snapshot.status == .stopped)
            #expect(snapshot.configuration.logging == logging)
        }
    }

    @Test func dockerRejectedStartErrorIsInspectableAfterAuthorityRestart() async throws {
        try await withTemporaryRoot { root in
            let id = "invalid-local-compression"
            let expected = "failed to initialize logging driver: compression cannot be enabled when max file count is 1"
            let prepared = try makeResolver().prepare(
                ContainerLogRequest(
                    driver: "local",
                    options: [
                        "compress": "true",
                        "max-file": "1",
                        "max-size": "4k",
                    ]
                )
            )
            let logging = try prepared.finalizedConfiguration(protectedReference: nil)
            try persistConfiguration(appRoot: root, id: id, logging: logging)

            let service = try makeService(appRoot: root, includeRuntime: true)
            let backend = ContainerDockerLoggingBackend(containers: service)
            let error = await #expect(throws: DockerLoggingBackendError.self) {
                try await backend.startContainer(containerID: id)
            }
            #expect(error == .conflict(expected))

            let initialObject = try #require(
                JSONSerialization.jsonObject(
                    with: try await backend.containerInspectBaseJSON(containerID: id)
                ) as? [String: Any]
            )
            let initialState = try #require(initialObject["State"] as? [String: Any])
            #expect((initialState["Status"] as? String) == "created")
            #expect((initialState["ExitCode"] as? Int) == 128)
            #expect((initialState["Error"] as? String) == expected)
            #expect((initialState["StartedAt"] as? String) == "0001-01-01T00:00:00Z")
            #expect((initialState["FinishedAt"] as? String) == "0001-01-01T00:00:00Z")

            let restartedService = try makeService(appRoot: root, includeRuntime: true)
            let restartedBackend = ContainerDockerLoggingBackend(containers: restartedService)
            let restartedObject = try #require(
                JSONSerialization.jsonObject(
                    with: try await restartedBackend.containerInspectBaseJSON(containerID: id)
                ) as? [String: Any]
            )
            let restartedState = try #require(restartedObject["State"] as? [String: Any])
            #expect((restartedState["Status"] as? String) == "created")
            #expect((restartedState["ExitCode"] as? Int) == 128)
            #expect((restartedState["Error"] as? String) == expected)
            #expect((restartedState["StartedAt"] as? String) == "0001-01-01T00:00:00Z")
            #expect((restartedState["FinishedAt"] as? String) == "0001-01-01T00:00:00Z")
        }
    }

    @Test func bootReconciliationDeletesProtectedObjectsWithoutDurableOwners() async throws {
        try await withTemporaryRoot { root in
            let store = try LoggingProtectedOptionsStore(rootURL: protectedStoreURL(appRoot: root))
            let orphan = try await store.store(["orphan": "protected"])
            let objectURL = protectedObjectURL(appRoot: root, objectID: orphan.objectID)
            #expect(FileManager.default.fileExists(atPath: objectURL.path))

            _ = try makeService(appRoot: root, includeRuntime: false)

            #expect(!FileManager.default.fileExists(atPath: objectURL.path))
        }
    }

    @Test func bootReconciliationPreservesAllObjectsWhenContainerOwnershipIsUnreadable() async throws {
        try await withTemporaryRoot { root in
            let store = try LoggingProtectedOptionsStore(rootURL: protectedStoreURL(appRoot: root))
            let possiblyOwned = try await store.store(["possibly-owned": "protected"])
            let objectURL = protectedObjectURL(appRoot: root, objectID: possiblyOwned.objectID)
            let unreadableBundle =
                root
                .appendingPathComponent("containers")
                .appendingPathComponent("damaged-container")
            try FileManager.default.createDirectory(
                at: unreadableBundle,
                withIntermediateDirectories: true
            )

            _ = try makeService(appRoot: root, includeRuntime: false)

            #expect(FileManager.default.fileExists(atPath: objectURL.path))
        }
    }

    @Test func failedPostBundleCleanupRecoversOrphanAtNextBoot() async throws {
        try await withTemporaryRoot { root in
            let id = "delete-recovery"
            let prepared = try makeResolver().prepare(
                ContainerLogRequest(
                    driver: "none",
                    options: ["opaque": "protected"]
                )
            )
            let binding = LoggingProtectedOptionsBinding(
                containerID: id,
                prepared: prepared,
                leaseGeneration: 1
            )
            let storeRoot = protectedStoreURL(appRoot: root)
            let store = try LoggingProtectedOptionsStore(rootURL: storeRoot)
            let reference = try await store.store(
                ["opaque": "protected"],
                boundTo: binding
            )
            let logging = try prepared.finalizedConfiguration(protectedReference: reference)
            let bundle = try persistConfiguration(appRoot: root, id: id, logging: logging)
            let objectURL = protectedObjectURL(appRoot: root, objectID: reference.objectID)
            let service = try makeService(appRoot: root, includeRuntime: true)

            #expect(Darwin.chmod(storeRoot.path, mode_t(0o755)) == 0)
            defer { _ = Darwin.chmod(storeRoot.path, mode_t(0o700)) }
            try await service.delete(id: id, force: false)

            #expect(!FileManager.default.fileExists(atPath: bundle.path.path))
            #expect(FileManager.default.fileExists(atPath: objectURL.path))
            #expect(Darwin.chmod(storeRoot.path, mode_t(0o700)) == 0)

            _ = try makeService(appRoot: root, includeRuntime: false)
            #expect(!FileManager.default.fileExists(atPath: objectURL.path))
        }
    }

    private func makeResolver() -> ContainerLogRequestResolver {
        ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: BuiltinLogDriverDescriptors.current
        )
    }

    private func makeService(
        appRoot: URL,
        includeRuntime: Bool,
        logDriverCatalogProvider: any LogDriverCatalogProviding = StaticLogDriverCatalogProvider(
            catalog: BuiltinLogDriverDescriptors.current
        ),
        remoteLogDriverPlane: AuthorityRemoteLogDriverPlane? = nil
    ) throws -> ContainersService {
        try ContainersService(
            appRoot: appRoot,
            pluginLoader: try makePluginLoader(
                appRoot: appRoot,
                includeRuntime: includeRuntime
            ),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "ContainerLoggingAuthorityIntegrationTests"),
            logDriverCatalogProvider: logDriverCatalogProvider,
            remoteLogDriverPlane: remoteLogDriverPlane
        )
    }

    private static func migrationPluginInstallation(
        identity: LogDriverProviderIdentity,
        generation: UInt64,
        readLogs: Bool = true,
        service: any DockerPluginLifecycleService
    ) -> DockerPluginLogDriverInstallation {
        DockerPluginLogDriverInstallation(
            driver: "migration-plugin",
            providerIdentity: identity,
            providerGeneration: generation,
            readLogs: readLogs,
            lifecycleService: service
        )
    }

    private func testProviderDescriptor(
        providerGeneration: UInt64 = 7
    ) throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: "test-remote",
            aliases: ["test-remote-alias"],
            providerIdentity: LogDriverProviderIdentity(
                id: "test.logging.provider",
                version: "1",
                kind: .native
            ),
            providerGeneration: providerGeneration,
            placement: .macOSHost,
            trust: .builtIn,
            options: [
                LogDriverOptionDescriptor(name: "endpoint", valueKind: .string)
            ],
            capabilities: try LogDriverCapabilities(
                deliveryModes: [.blocking, .nonBlocking],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: true,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: true,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    private func makePluginLoader(
        appRoot: URL,
        includeRuntime: Bool
    ) throws -> PluginLoader {
        let pluginRoot = appRoot.appendingPathComponent("plugins")
        let pluginDirectories: [URL]
        let pluginFactories: [any PluginFactory]
        if includeRuntime {
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("container-runtime-linux"),
                withIntermediateDirectories: true
            )
            pluginDirectories = [pluginRoot]
            pluginFactories = [AuthorityTestRuntimePluginFactory()]
        } else {
            pluginDirectories = []
            pluginFactories = []
        }
        return try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: pluginDirectories,
            pluginFactories: pluginFactories
        )
    }

    @discardableResult
    private func persistConfiguration(
        appRoot: URL,
        id: String,
        logging: ContainerLogConfiguration
    ) throws -> ContainerResource.Bundle {
        let bundle = ContainerResource.Bundle(
            path: appRoot.appendingPathComponent("containers").appendingPathComponent(id)
        )
        try FileManager.default.createDirectory(
            at: bundle.path,
            withIntermediateDirectories: true
        )
        var configuration = testConfiguration(id: id)
        configuration.logging = logging
        try bundle.set(configuration: configuration)
        return bundle
    }

    private func persistTerminalWriterHistory(
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        sandboxGeneration: UInt64
    ) async throws {
        let resolved = try #require(configuration.logging.resolved)
        let digest = SHA256.hash(data: Data(configuration.id.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let controllerID =
            "container-\(digest)-lease-\(resolved.leaseGeneration)"
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(resolved.leaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let request = try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "writer-history-key",
            semanticRequestDigest: "sha256:writer-history-request",
            sessionID: "writer-history-session",
            containerID: configuration.id,
            leaseGeneration: resolved.leaseGeneration,
            candidateProcessGeneration: 1,
            providerID: resolved.providerIdentity.id,
            providerGeneration: resolved.providerGenerationAtResolution,
            candidateSandboxGeneration: sandboxGeneration
        )
        let reference = try ProtectedLoggingEffectReferenceV1(
            effectID: request.sessionID,
            owningControllerID: controllerID,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            protectedStoreObjectID: "terminal-history-object",
            integrityDigest: "hmac:terminal-history"
        )
        _ = try await ledger.reserveWriter(request)
        _ = try await ledger.recordWriterPreparation(
            LoggingSessionPreparationV1(
                operationGeneration: request.operationGeneration,
                idempotencyKey: request.idempotencyKey,
                semanticRequestDigest: request.semanticRequestDigest,
                sessionID: request.sessionID,
                containerID: request.containerID,
                leaseGeneration: request.leaseGeneration,
                candidateProcessGeneration: request.candidateProcessGeneration,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration,
                candidateSandboxGeneration: request.candidateSandboxGeneration,
                effectTokenReference: reference
            ),
            for: request
        )
        let active = try await ledger.commitWriterActivation(for: request)
        let draining = try await ledger.beginWriterDrain(active)
        _ = try await ledger.completeWriterClose(draining)
        let removal = try #require(
            await ledger.pendingEffectRemoval(
                kind: .writerSession,
                ownerID: request.sessionID
            )
        )
        try await ledger.acknowledgeEffectRemoval(removal)
    }

    private func testConfiguration(id: String) -> ContainerConfiguration {
        ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "0", count: 64),
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0),
                supplementalGroups: [],
                rlimits: []
            )
        )
    }

    private func protectedStoreURL(appRoot: URL) -> URL {
        appRoot.appendingPathComponent(ContainersService.loggingProtectedOptionsDirectoryName)
    }

    private func protectedObjectURL(appRoot: URL, objectID: String) -> URL {
        protectedStoreURL(appRoot: appRoot).appendingPathComponent(
            LoggingProtectedOptionsStore.objectFilePrefix
                + objectID
                + LoggingProtectedOptionsStore.objectFileSuffix
        )
    }

    private func withTemporaryRoot(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-logging-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private actor RecordingLogDriverCatalogProvider: LogDriverCatalogProviding {
    private var catalogs: [LogDriverCatalog]
    private(set) var requestCount = 0

    init(catalog: LogDriverCatalog) {
        self.catalogs = [catalog]
    }

    init(catalogs: [LogDriverCatalog]) {
        precondition(!catalogs.isEmpty)
        self.catalogs = catalogs
    }

    func logDriverCatalog() async throws -> LogDriverCatalog {
        requestCount += 1
        if catalogs.count > 1 {
            return catalogs.removeFirst()
        }
        return catalogs[0]
    }
}

private struct AuthorityMigrationAWSLogsClientFactory: AWSLogsClientFactory {
    func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient {
        _ = configuration
        throw AuthorityMigrationPluginError.unexpectedEffect
    }
}

private enum AuthorityMigrationPluginError: Error {
    case injectedRestart
    case unexpectedEffect
}

private actor AuthorityMigrationPluginService: DockerPluginLifecycleService {
    private let sandboxGeneration: UInt64
    private let supportsHistoryMigration: Bool
    private(set) var historyMigrationRequestCount = 0
    private(set) var generationReclaimRequestCount = 0

    init(
        sandboxGeneration: UInt64,
        supportsHistoryMigration: Bool = true
    ) {
        self.sandboxGeneration = sandboxGeneration
        self.supportsHistoryMigration = supportsHistoryMigration
    }

    func activeSandboxGeneration() -> UInt64 {
        sandboxGeneration
    }

    func migrateHistory(
        _ request: LogDriverHistoryMigrationRequestV1
    ) throws -> LogDriverHistoryMigrationReceiptV1 {
        historyMigrationRequestCount += 1
        guard supportsHistoryMigration else {
            throw LogDriverHistoryMigrationError.unsupported
        }
        return try LogDriverHistoryMigrationReceiptV1(
            request: request,
            providerOutcomeDigest:
                "sha256:accepted-\(request.terminalHistoryDigest)"
        )
    }

    func reclaimGeneration(
        _ request: LogDriverProviderGenerationReclaimV1
    ) {
        _ = request
        generationReclaimRequestCount += 1
    }

    func startWriter(
        _ request: DockerPluginWriterOpenRequest
    ) throws -> DockerPluginServiceStartedWriter {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) throws -> DockerPluginServiceWriterReconciliation {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func reconcileWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func fenceWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func closeWriter(
        _ request: LogDriverSessionCallV1
    ) throws -> LogDriverSessionAcknowledgementV1 {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func openReader(
        _ request: DockerPluginReaderOpenRequest
    ) throws -> DockerPluginServiceStartedReader {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> DockerPluginServiceReaderReconciliation {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) throws -> LogDriverReaderAcknowledgementV1 {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) throws -> LogDriverReaderAcknowledgementV1 {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }

    func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) throws {
        _ = request
        throw AuthorityMigrationPluginError.unexpectedEffect
    }
}

private struct AuthorityTestRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux" else {
            return nil
        }
        return Plugin(
            binaryURL: installURL.appendingPathComponent("bin/container-runtime-linux"),
            config: PluginConfig(
                abstract: "runtime",
                author: nil,
                servicesConfig: PluginConfig.ServicesConfig(
                    loadAtBoot: false,
                    runAtLoad: false,
                    services: [PluginConfig.Service(type: .runtime, description: nil)],
                    defaultArguments: []
                )
            )
        )
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}
