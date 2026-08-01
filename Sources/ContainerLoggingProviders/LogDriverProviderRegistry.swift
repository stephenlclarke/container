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

public enum LogDriverProviderRegistryError: Error, Equatable, Sendable {
    case invalidDescriptor
    case reservedProviderIdentity(String)
    case registeredNameCollision(String)
    case staleProviderGeneration(
        providerID: String,
        installedGeneration: UInt64,
        requestedGeneration: UInt64
    )
    case providerGenerationConflict(providerID: String, generation: UInt64)
    case providerNotFound(String)
    case resolvedConfigurationMismatch
}

public enum LogDriverProviderInstallResult: Equatable, Sendable {
    case installed
    case replaced(previousGeneration: UInt64)
    case unchanged
}

/// One atomically selected provider implementation and its immutable contract.
///
/// Holding this value keeps an old provider object available for an already
/// prepared lifecycle operation even if the registry later installs a newer
/// generation. New operations must select again and therefore cannot silently
/// cross a generation boundary.
public struct RegisteredLogDriverProvider: Sendable {
    public let descriptor: LogDriverDescriptor
    public let provider: any ContainerLogDriverProvider

    fileprivate init(
        descriptor: LogDriverDescriptor,
        provider: any ContainerLogDriverProvider
    ) {
        self.descriptor = descriptor
        self.provider = provider
    }
}

/// Authority-owned registry for native, Linux-service, and Docker-plugin
/// logging providers.
///
/// Registration snapshots each provider descriptor exactly once. Publishing a
/// replacement is an atomic, monotonic generation change; descriptor failures,
/// stale generations, and name collisions leave the visible catalog untouched.
public actor LogDriverProviderRegistry: LogDriverCatalogProviding {
    private struct Entry: Sendable {
        let descriptor: LogDriverDescriptor
        let provider: any ContainerLogDriverProvider

        var selection: RegisteredLogDriverProvider {
            RegisteredLogDriverProvider(
                descriptor: descriptor,
                provider: provider
            )
        }
    }

    private let baseCatalog: LogDriverCatalog
    private let reservedProviderIDs: Set<String>
    private var entriesByProviderID: [String: Entry] = [:]

    public init(baseCatalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current) {
        self.baseCatalog = baseCatalog
        self.reservedProviderIDs = Set(
            baseCatalog.descriptors.map(\.providerIdentity.id)
        )
    }

    @discardableResult
    public func install(
        _ provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverProviderInstallResult {
        let descriptor = try await provider.descriptor
        try validate(descriptor)

        let providerID = descriptor.providerIdentity.id
        guard !reservedProviderIDs.contains(providerID) else {
            throw LogDriverProviderRegistryError.reservedProviderIdentity(providerID)
        }

        let existing = entriesByProviderID[providerID]
        if let existing {
            if descriptor.providerGeneration < existing.descriptor.providerGeneration {
                throw LogDriverProviderRegistryError.staleProviderGeneration(
                    providerID: providerID,
                    installedGeneration: existing.descriptor.providerGeneration,
                    requestedGeneration: descriptor.providerGeneration
                )
            }
            if descriptor.providerGeneration == existing.descriptor.providerGeneration {
                guard descriptor == existing.descriptor else {
                    throw LogDriverProviderRegistryError.providerGenerationConflict(
                        providerID: providerID,
                        generation: descriptor.providerGeneration
                    )
                }
                return .unchanged
            }
        }

        try rejectNameCollisions(
            descriptor,
            replacingProviderID: existing == nil ? nil : providerID
        )
        entriesByProviderID[providerID] = Entry(
            descriptor: descriptor,
            provider: provider
        )
        if let existing {
            return .replaced(
                previousGeneration: existing.descriptor.providerGeneration
            )
        }
        return .installed
    }

    /// Removes only the exact installed generation. An already-absent provider
    /// is an idempotent no-op; a request against another live generation fails.
    @discardableResult
    public func uninstall(
        providerID: String,
        generation: UInt64
    ) throws -> Bool {
        guard let existing = entriesByProviderID[providerID] else {
            return false
        }
        guard existing.descriptor.providerGeneration == generation else {
            throw LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: providerID,
                installedGeneration: existing.descriptor.providerGeneration,
                requestedGeneration: generation
            )
        }
        entriesByProviderID.removeValue(forKey: providerID)
        return true
    }

    public func logDriverCatalog() throws -> LogDriverCatalog {
        try LogDriverCatalog(
            descriptors: baseCatalog.descriptors
                + entriesByProviderID.values.map(\.descriptor)
        )
    }

    public func selection(named registeredName: String) -> RegisteredLogDriverProvider? {
        entriesByProviderID.values.first {
            $0.descriptor.registeredNames.contains(registeredName)
        }?.selection
    }

    public func selection(
        providerID: String,
        generation: UInt64
    ) -> RegisteredLogDriverProvider? {
        guard
            let entry = entriesByProviderID[providerID],
            entry.descriptor.providerGeneration == generation
        else {
            return nil
        }
        return entry.selection
    }

    /// Resolves one persisted authority decision without a catalog/provider
    /// time-of-check/time-of-use split.
    public func selection(
        for configuration: ResolvedContainerLogConfiguration
    ) throws -> RegisteredLogDriverProvider {
        let providerID = configuration.providerIdentity.id
        guard let entry = entriesByProviderID[providerID] else {
            throw LogDriverProviderRegistryError.providerNotFound(providerID)
        }
        let descriptor = entry.descriptor
        guard
            descriptor.driver == configuration.driver,
            descriptor.providerIdentity == configuration.providerIdentity,
            descriptor.providerGeneration == configuration.providerGenerationAtResolution,
            descriptor.optionContractDigest == configuration.contractDigest
        else {
            throw LogDriverProviderRegistryError.resolvedConfigurationMismatch
        }
        return entry.selection
    }

    private func validate(_ descriptor: LogDriverDescriptor) throws {
        guard
            descriptor.providerGeneration > 0,
            !descriptor.driver.isEmpty,
            descriptor.registeredNames.allSatisfy({ !$0.isEmpty }),
            !descriptor.providerIdentity.id.isEmpty,
            !descriptor.providerIdentity.version.isEmpty,
            descriptor.providerIdentity.kind != .core
        else {
            throw LogDriverProviderRegistryError.invalidDescriptor
        }
    }

    private func rejectNameCollisions(
        _ descriptor: LogDriverDescriptor,
        replacingProviderID: String?
    ) throws {
        var registeredNames = Set(baseCatalog.registeredNames)
        for (providerID, entry) in entriesByProviderID where providerID != replacingProviderID {
            registeredNames.formUnion(entry.descriptor.registeredNames)
        }
        if let collision = descriptor.registeredNames.first(where: registeredNames.contains) {
            throw LogDriverProviderRegistryError.registeredNameCollision(collision)
        }
    }
}
