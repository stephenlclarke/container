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
import Foundation
import Testing

@testable import ContainerLoggingProviders

struct LogDriverProviderRegistryTests {
    @Test
    func publishesBaseAndProviderDescriptorsWithAliasLookup() async throws {
        let registry = LogDriverProviderRegistry()
        let provider = try RegistryTestProvider(
            descriptor: Self.descriptor(
                driver: "remote",
                aliases: ["remote-alias"],
                providerID: "test.remote",
                generation: 1
            )
        )

        #expect(try await registry.install(provider) == .installed)
        let catalog = try await registry.logDriverCatalog()
        #expect(catalog.registeredNames.contains("none"))
        #expect(catalog.registeredNames.contains("json-file"))
        #expect(catalog.registeredNames.contains("local"))
        #expect(catalog.registeredNames.contains("remote"))
        #expect(catalog.registeredNames.contains("remote-alias"))

        let canonical = try #require(await registry.selection(named: "remote"))
        let alias = try #require(await registry.selection(named: "remote-alias"))
        #expect(canonical.descriptor == provider.storedDescriptor)
        #expect(alias.descriptor == provider.storedDescriptor)
        let canonicalProvider = try #require(canonical.provider as? RegistryTestProvider)
        let aliasProvider = try #require(alias.provider as? RegistryTestProvider)
        #expect(canonicalProvider === provider)
        #expect(aliasProvider === provider)
    }

    @Test
    func exactInstallReplayIsIdempotent() async throws {
        let registry = LogDriverProviderRegistry()
        let descriptor = try Self.descriptor(
            driver: "remote",
            providerID: "test.remote",
            generation: 4
        )
        let first = RegistryTestProvider(descriptor: descriptor)
        let replayObject = RegistryTestProvider(descriptor: descriptor)

        #expect(try await registry.install(first) == .installed)
        #expect(try await registry.install(replayObject) == .unchanged)

        let selected = try #require(
            await registry.selection(providerID: "test.remote", generation: 4)
        )
        let selectedProvider = try #require(selected.provider as? RegistryTestProvider)
        #expect(selectedProvider === first)
    }

    @Test
    func higherGenerationReplacesAtomicallyAndOldSelectionStaysUsable() async throws {
        let registry = LogDriverProviderRegistry()
        let first = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: "test.remote",
                generation: 1
            )
        )
        let second = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote-v2",
                aliases: ["remote"],
                providerID: "test.remote",
                generation: 2,
                version: "2"
            )
        )

        #expect(try await registry.install(first) == .installed)
        let retained = try #require(await registry.selection(named: "remote"))
        #expect(try await registry.install(second) == .replaced(previousGeneration: 1))

        let staleSelection = await registry.selection(providerID: "test.remote", generation: 1)
        #expect(staleSelection?.descriptor == nil)
        let current = try #require(
            await registry.selection(providerID: "test.remote", generation: 2)
        )
        let retainedProvider = try #require(retained.provider as? RegistryTestProvider)
        let currentProvider = try #require(current.provider as? RegistryTestProvider)
        #expect(retainedProvider === first)
        #expect(currentProvider === second)
        #expect(try await registry.logDriverCatalog().descriptor(named: "remote")?.driver == "remote-v2")
    }

    @Test
    func rejectsStaleAndConflictingGenerationsWithoutMutation() async throws {
        let registry = LogDriverProviderRegistry()
        let installed = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: "test.remote",
                generation: 5
            )
        )
        try await registry.install(installed)

        let stale = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "stale",
                providerID: "test.remote",
                generation: 4
            )
        )
        await #expect(
            throws: LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: "test.remote",
                installedGeneration: 5,
                requestedGeneration: 4
            )
        ) {
            try await registry.install(stale)
        }

        let conflicting = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "different",
                providerID: "test.remote",
                generation: 5
            )
        )
        await #expect(
            throws: LogDriverProviderRegistryError.providerGenerationConflict(
                providerID: "test.remote",
                generation: 5
            )
        ) {
            try await registry.install(conflicting)
        }

        let selected = try #require(await registry.selection(named: "remote"))
        let selectedProvider = try #require(selected.provider as? RegistryTestProvider)
        #expect(selectedProvider === installed)
        let staleSelection = await registry.selection(named: "stale")
        let conflictingSelection = await registry.selection(named: "different")
        #expect(staleSelection?.descriptor == nil)
        #expect(conflictingSelection?.descriptor == nil)
    }

    @Test
    func rejectsBaseAndProviderNameCollisionsWithoutMutation() async throws {
        let registry = LogDriverProviderRegistry()
        let first = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                aliases: ["shared"],
                providerID: "test.remote",
                generation: 1
            )
        )
        try await registry.install(first)

        let coreCollision = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "json-file",
                providerID: "test.core-collision",
                generation: 1
            )
        )
        await #expect(
            throws: LogDriverProviderRegistryError.registeredNameCollision("json-file")
        ) {
            try await registry.install(coreCollision)
        }

        let providerCollision = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "second",
                aliases: ["shared"],
                providerID: "test.second",
                generation: 1
            )
        )
        await #expect(
            throws: LogDriverProviderRegistryError.registeredNameCollision("shared")
        ) {
            try await registry.install(providerCollision)
        }

        let catalog = try await registry.logDriverCatalog()
        #expect(catalog.descriptor(named: "remote") != nil)
        #expect(catalog.descriptor(named: "second") == nil)
    }

    @Test
    func exactUninstallIsIdempotentAndGenerationFenced() async throws {
        let registry = LogDriverProviderRegistry()
        let provider = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: "test.remote",
                generation: 7
            )
        )
        try await registry.install(provider)

        await #expect(
            throws: LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: "test.remote",
                installedGeneration: 7,
                requestedGeneration: 6
            )
        ) {
            try await registry.uninstall(providerID: "test.remote", generation: 6)
        }
        #expect(try await registry.uninstall(providerID: "test.remote", generation: 7))
        #expect(try await !registry.uninstall(providerID: "test.remote", generation: 7))
        let removedSelection = await registry.selection(named: "remote")
        #expect(removedSelection?.descriptor == nil)
    }

    @Test
    func resolvedSelectionRequiresExactIdentityGenerationAndDigest() async throws {
        let registry = LogDriverProviderRegistry()
        let descriptor = try Self.descriptor(
            driver: "remote",
            providerID: "test.remote",
            generation: 3
        )
        let provider = RegistryTestProvider(descriptor: descriptor)
        try await registry.install(provider)

        let exact = try Self.resolved(descriptor: descriptor)
        let selected = try await registry.selection(for: exact)
        let selectedProvider = try #require(selected.provider as? RegistryTestProvider)
        #expect(selectedProvider === provider)

        let wrongGeneration = try Self.resolved(
            descriptor: descriptor,
            generation: 2
        )
        await #expect(throws: LogDriverProviderRegistryError.resolvedConfigurationMismatch) {
            try await registry.selection(for: wrongGeneration)
        }

        let missingIdentity = try Self.resolved(
            descriptor: descriptor,
            providerIdentity: LogDriverProviderIdentity(
                id: "test.missing",
                version: "1",
                kind: .native
            )
        )
        await #expect(throws: LogDriverProviderRegistryError.providerNotFound("test.missing")) {
            try await registry.selection(for: missingIdentity)
        }
    }

    @Test
    func rejectsInvalidAndReservedProviderDescriptors() async throws {
        let registry = LogDriverProviderRegistry()
        let zeroGeneration = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: "test.remote",
                generation: 0
            )
        )
        await #expect(throws: LogDriverProviderRegistryError.invalidDescriptor) {
            try await registry.install(zeroGeneration)
        }

        let reserved = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: BuiltinLogDriverDescriptors.coreProvider.id,
                generation: 2,
                kind: .native
            )
        )
        await #expect(
            throws: LogDriverProviderRegistryError.reservedProviderIdentity(
                BuiltinLogDriverDescriptors.coreProvider.id
            )
        ) {
            try await registry.install(reserved)
        }
        #expect(try await registry.logDriverCatalog().registeredNames == ["json-file", "local", "none"])
    }

    @Test
    func descriptorFailureDoesNotMutateTheVisibleRegistry() async throws {
        let registry = LogDriverProviderRegistry()
        let installed = RegistryTestProvider(
            descriptor: try Self.descriptor(
                driver: "remote",
                providerID: "test.remote",
                generation: 1
            )
        )
        try await registry.install(installed)

        let failing = RegistryFailingDescriptorProvider()
        await #expect(throws: RegistryTestProviderError.unsupported) {
            try await registry.install(failing)
        }

        let selected = try #require(await registry.selection(named: "remote"))
        let selectedProvider = try #require(selected.provider as? RegistryTestProvider)
        #expect(selectedProvider === installed)
        #expect(try await registry.logDriverCatalog().descriptor(named: "remote") != nil)
    }

    private static func descriptor(
        driver: String,
        aliases: [String] = [],
        providerID: String,
        generation: UInt64,
        version: String = "1",
        kind: LogDriverProviderIdentity.Kind = .native
    ) throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: driver,
            aliases: aliases,
            providerIdentity: LogDriverProviderIdentity(
                id: providerID,
                version: version,
                kind: kind
            ),
            providerGeneration: generation,
            placement: .macOSHost,
            trust: .signed,
            options: [],
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

    private static func resolved(
        descriptor: LogDriverDescriptor,
        generation: UInt64? = nil,
        providerIdentity: LogDriverProviderIdentity? = nil
    ) throws -> ResolvedContainerLogConfiguration {
        try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: descriptor.driver,
            delivery: LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(
                source: .dualCache,
                cache: LogCacheConfiguration(
                    maxSizeInBytes: 20 * 1024 * 1024,
                    maxFileCount: 5,
                    compress: true
                )
            ),
            providerIdentity: providerIdentity ?? descriptor.providerIdentity,
            providerGenerationAtResolution: generation ?? descriptor.providerGeneration,
            contractDigest: descriptor.optionContractDigest
        )
    }
}

private enum RegistryTestProviderError: Error {
    case unsupported
}

private final class RegistryTestProvider: ContainerLogDriverProvider, @unchecked Sendable {
    let storedDescriptor: LogDriverDescriptor

    init(descriptor: LogDriverDescriptor) {
        self.storedDescriptor = descriptor
    }

    var descriptor: LogDriverDescriptor {
        get async throws { storedDescriptor }
    }

    func start(_ request: LogDriverStartRequestV1) async throws -> StartedLogDriverSessionV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }
}

private struct RegistryFailingDescriptorProvider: ContainerLogDriverProvider {
    var descriptor: LogDriverDescriptor {
        get async throws { throw RegistryTestProviderError.unsupported }
    }

    func start(_ request: LogDriverStartRequestV1) async throws -> StartedLogDriverSessionV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        throw RegistryTestProviderError.unsupported
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        throw RegistryTestProviderError.unsupported
    }
}
