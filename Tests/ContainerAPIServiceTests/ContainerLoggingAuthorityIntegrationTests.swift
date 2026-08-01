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

import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct ContainerLoggingAuthorityIntegrationTests {
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

            try await service.validateLoggingForStart(
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
        )
    ) throws -> ContainersService {
        try ContainersService(
            appRoot: appRoot,
            pluginLoader: try makePluginLoader(
                appRoot: appRoot,
                includeRuntime: includeRuntime
            ),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "ContainerLoggingAuthorityIntegrationTests"),
            logDriverCatalogProvider: logDriverCatalogProvider
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
