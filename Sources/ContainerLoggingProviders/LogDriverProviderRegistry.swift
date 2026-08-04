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
import Darwin
import Foundation

private struct LogDriverProviderRegistryAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownRegistryKeys<Key>(
    from decoder: any Decoder,
    allowed _: Key.Type,
    type: String
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(
        keyedBy: LogDriverProviderRegistryAnyCodingKey.self
    )
    let known = Set(Key.allCases.map(\.stringValue))
    if let unknown = container.allKeys.map(\.stringValue).first(
        where: { !known.contains($0) }
    ) {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown key '\(unknown)' in \(type)"
            )
        )
    }
}

public enum LogDriverProviderRegistryError: Error, Equatable, Sendable {
    case invalidDescriptor
    case invalidPersistedState
    case reservedProviderIdentity(String)
    case registeredNameCollision(String)
    case staleProviderGeneration(
        providerID: String,
        installedGeneration: UInt64,
        requestedGeneration: UInt64
    )
    case providerGenerationConflict(providerID: String, generation: UInt64)
    case providerGenerationNotStaged(providerID: String, generation: UInt64)
    case providerGenerationNotFound(providerID: String, generation: UInt64)
    case rollbackGenerationUnavailable(providerID: String, generation: UInt64)
    case providerNotFound(String)
    case resolvedConfigurationMismatch
}

public enum LogDriverProviderInstallResult: Equatable, Sendable {
    case installed
    case replaced(previousGeneration: UInt64)
    case unchanged
}

public enum LogDriverProviderStageResult: Equatable, Sendable {
    case staged
    case recovered(LogDriverProviderGenerationPhaseV1)
    case unchanged
}

public enum LogDriverProviderActivationResult: Equatable, Sendable {
    case activated(previousGeneration: UInt64?)
    case unchanged
}

public enum LogDriverProviderGenerationPhaseV1: String, Codable, Equatable,
    Sendable
{
    case staged
    case active
    case draining
}

/// Durable lifecycle state for every generation of one provider identity.
public struct LogDriverProviderIdentityStateV1: Codable, Equatable, Sendable {
    public let providerID: String
    public let activeGeneration: UInt64?
    public let stagedGenerations: [UInt64]
    public let drainingGenerations: [UInt64]
    public let descriptors: [LogDriverDescriptor]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerID
        case activeGeneration
        case stagedGenerations
        case drainingGenerations
        case descriptors
    }

    public init(
        providerID: String,
        activeGeneration: UInt64?,
        stagedGenerations: [UInt64],
        drainingGenerations: [UInt64],
        descriptors: [LogDriverDescriptor]
    ) throws {
        let staged = stagedGenerations.sorted()
        let draining = drainingGenerations.sorted()
        let all = staged + draining + (activeGeneration.map { [$0] } ?? [])
        let sortedDescriptors = descriptors.sorted {
            $0.providerGeneration < $1.providerGeneration
        }
        guard
            !providerID.isEmpty,
            staged == stagedGenerations,
            draining == drainingGenerations,
            all.allSatisfy({ $0 > 0 }),
            Set(all).count == all.count,
            descriptors == sortedDescriptors,
            descriptors.allSatisfy({
                $0.providerIdentity.id == providerID
            }),
            descriptors.map(\.providerGeneration) == all.sorted()
        else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
        self.providerID = providerID
        self.activeGeneration = activeGeneration
        self.stagedGenerations = staged
        self.drainingGenerations = draining
        self.descriptors = descriptors
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownRegistryKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "log-driver provider-generation state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decode(String.self, forKey: .providerID),
            activeGeneration: container.decodeIfPresent(
                UInt64.self,
                forKey: .activeGeneration
            ),
            stagedGenerations: container.decode(
                [UInt64].self,
                forKey: .stagedGenerations
            ),
            drainingGenerations: container.decode(
                [UInt64].self,
                forKey: .drainingGenerations
            ),
            descriptors: container.decode(
                [LogDriverDescriptor].self,
                forKey: .descriptors
            )
        )
    }
}

/// Closed, versioned snapshot written before a visible generation transition.
public struct LogDriverProviderRegistryStateV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let providers: [LogDriverProviderIdentityStateV1]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case providers
    }

    public init(
        schemaVersion: UInt32 = currentSchemaVersion,
        providers: [LogDriverProviderIdentityStateV1]
    ) throws {
        guard
            schemaVersion == Self.currentSchemaVersion,
            providers.map(\.providerID) == providers.map(\.providerID).sorted(),
            Set(providers.map(\.providerID)).count == providers.count
        else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
        self.schemaVersion = schemaVersion
        self.providers = providers
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownRegistryKeys(
            from: decoder,
            allowed: CodingKeys.self,
            type: "log-driver provider registry"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(
                UInt32.self,
                forKey: .schemaVersion
            ),
            providers: container.decode(
                [LogDriverProviderIdentityStateV1].self,
                forKey: .providers
            )
        )
    }
}

/// Synchronous persistence prevents actor reentrancy between durable commit
/// and publication of the corresponding in-memory registry state.
public protocol LogDriverProviderRegistryPersisting: Sendable {
    func load() throws -> LogDriverProviderRegistryStateV1?
    func save(_ state: LogDriverProviderRegistryStateV1) throws
}

/// Protected, atomically replaced registry state used by the API authority.
public struct FileLogDriverProviderRegistryPersistenceV1:
    LogDriverProviderRegistryPersisting
{
    private static let maximumStateBytes = 1_048_576
    private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        try Self.ensureProtectedDirectory(
            self.fileURL.deletingLastPathComponent()
        )
    }

    public func load() throws -> LogDriverProviderRegistryStateV1? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try Self.verifyProtectedRegularFile(fileURL)
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumStateBytes else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
        let state = try JSONDecoder().decode(
            LogDriverProviderRegistryStateV1.self,
            from: data
        )
        return try Self.validated(state)
    }

    public func save(_ state: LogDriverProviderRegistryStateV1) throws {
        let state = try Self.validated(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
        try Self.ensureProtectedDirectory(fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        try Self.verifyProtectedRegularFile(fileURL)
        try Self.synchronize(fileURL)
        try Self.synchronize(fileURL.deletingLastPathComponent(), directory: true)
    }

    private static func validated(
        _ state: LogDriverProviderRegistryStateV1
    ) throws -> LogDriverProviderRegistryStateV1 {
        try LogDriverProviderRegistryStateV1(
            schemaVersion: state.schemaVersion,
            providers: try state.providers.map {
                try LogDriverProviderIdentityStateV1(
                    providerID: $0.providerID,
                    activeGeneration: $0.activeGeneration,
                    stagedGenerations: $0.stagedGenerations,
                    drainingGenerations: $0.drainingGenerations,
                    descriptors: $0.descriptors
                )
            }
        )
    }

    private static func ensureProtectedDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            url.resolvingSymlinksInPath().standardizedFileURL.path == url.path
        else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func verifyProtectedRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .uint16Value
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            permissions.map({ $0 & 0o077 == 0 }) == true
        else {
            throw LogDriverProviderRegistryError.invalidPersistedState
        }
    }

    private static func synchronize(_ url: URL, directory: Bool = false) throws {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// One atomically selected provider implementation and its immutable contract.
///
/// Holding this value keeps a draining provider object available for an
/// existing lifecycle operation while new name-based selections use only the
/// active generation.
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

/// Authority-owned staged registry for native, Linux-service, and Docker-plugin
/// logging providers.
///
/// The state file is committed before in-memory activation. A restart therefore
/// reconstructs the same active, staged, and draining generations from the
/// installed immutable provider objects. Catalog/name lookup exposes only the
/// active generation; exact persisted configurations can still select a
/// draining generation for recovery and orderly close.
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

    private struct ProviderState: Sendable {
        var activeGeneration: UInt64?
        var stagedGenerations: Set<UInt64>
        var drainingGenerations: Set<UInt64>
        var descriptorsByGeneration: [UInt64: LogDriverDescriptor]

        init(_ state: LogDriverProviderIdentityStateV1? = nil) {
            activeGeneration = state?.activeGeneration
            stagedGenerations = Set(state?.stagedGenerations ?? [])
            drainingGenerations = Set(state?.drainingGenerations ?? [])
            descriptorsByGeneration = Dictionary(
                uniqueKeysWithValues: (state?.descriptors ?? []).map {
                    ($0.providerGeneration, $0)
                }
            )
        }

        func phase(generation: UInt64) -> LogDriverProviderGenerationPhaseV1? {
            if activeGeneration == generation { return .active }
            if stagedGenerations.contains(generation) { return .staged }
            if drainingGenerations.contains(generation) { return .draining }
            return nil
        }

        var allGenerations: Set<UInt64> {
            stagedGenerations.union(drainingGenerations)
                .union(activeGeneration.map { [$0] } ?? [])
        }
    }

    private let baseCatalog: LogDriverCatalog
    private let reservedProviderIDs: Set<String>
    private let persistence: (any LogDriverProviderRegistryPersisting)?
    private var entriesByProviderID: [String: [UInt64: Entry]] = [:]
    private var statesByProviderID: [String: ProviderState]

    public init(baseCatalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current) {
        self.baseCatalog = baseCatalog
        self.reservedProviderIDs = Set(
            baseCatalog.descriptors.map(\.providerIdentity.id)
        )
        self.persistence = nil
        self.statesByProviderID = [:]
    }

    private init(
        baseCatalog: LogDriverCatalog,
        persistence: any LogDriverProviderRegistryPersisting,
        restored: LogDriverProviderRegistryStateV1?
    ) {
        self.baseCatalog = baseCatalog
        self.reservedProviderIDs = Set(
            baseCatalog.descriptors.map(\.providerIdentity.id)
        )
        self.persistence = persistence
        self.statesByProviderID = Dictionary(
            uniqueKeysWithValues: (restored?.providers ?? []).map {
                ($0.providerID, ProviderState($0))
            }
        )
    }

    public static func open(
        baseCatalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current,
        persistence: any LogDriverProviderRegistryPersisting
    ) async throws -> LogDriverProviderRegistry {
        let restored = try persistence.load()
        if let restored {
            _ = try LogDriverProviderRegistryStateV1(
                schemaVersion: restored.schemaVersion,
                providers: restored.providers
            )
        }
        return LogDriverProviderRegistry(
            baseCatalog: baseCatalog,
            persistence: persistence,
            restored: restored
        )
    }

    /// Backward-compatible install performs stage and activation as one
    /// durable transition while retaining the previous generation for exact
    /// recovery.
    @discardableResult
    public func install(
        _ provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverProviderInstallResult {
        let descriptor = try await provider.descriptor
        if let existing = entriesByProviderID[descriptor.providerIdentity.id]?[descriptor.providerGeneration],
            existing.descriptor == descriptor,
            statesByProviderID[descriptor.providerIdentity.id]?.activeGeneration
                == descriptor.providerGeneration
        {
            return .unchanged
        }
        let previous = statesByProviderID[descriptor.providerIdentity.id]?
            .activeGeneration
        _ = try await stage(provider, descriptor: descriptor)
        if let phase = statesByProviderID[descriptor.providerIdentity.id]?
            .phase(generation: descriptor.providerGeneration),
            phase != .staged
        {
            return .unchanged
        }
        _ = try await activate(
            providerID: descriptor.providerIdentity.id,
            generation: descriptor.providerGeneration
        )
        if let previous, previous != descriptor.providerGeneration {
            return .replaced(previousGeneration: previous)
        }
        return previous == descriptor.providerGeneration ? .unchanged : .installed
    }

    /// Makes one immutable generation recoverable without changing new name
    /// lookup or catalog publication.
    @discardableResult
    public func stage(
        _ provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverProviderStageResult {
        let descriptor = try await provider.descriptor
        return try await stage(provider, descriptor: descriptor)
    }

    private func stage(
        _ provider: any ContainerLogDriverProvider,
        descriptor: LogDriverDescriptor
    ) async throws -> LogDriverProviderStageResult {
        try validate(descriptor)
        let providerID = descriptor.providerIdentity.id
        let generation = descriptor.providerGeneration
        guard !reservedProviderIDs.contains(providerID) else {
            throw LogDriverProviderRegistryError.reservedProviderIdentity(providerID)
        }

        if let existing = entriesByProviderID[providerID]?[generation] {
            guard existing.descriptor == descriptor else {
                throw LogDriverProviderRegistryError.providerGenerationConflict(
                    providerID: providerID,
                    generation: generation
                )
            }
            return .unchanged
        }

        var state = statesByProviderID[providerID] ?? ProviderState()
        if let recoveredDescriptor = state.descriptorsByGeneration[generation] {
            guard recoveredDescriptor == descriptor else {
                throw LogDriverProviderRegistryError.providerGenerationConflict(
                    providerID: providerID,
                    generation: generation
                )
            }
        }
        let entryGenerations = Set(
            entriesByProviderID[providerID]?.keys.map { $0 } ?? []
        )
        let known = state.allGenerations.union(entryGenerations)
        if let maximum = known.max(), generation < maximum,
            state.phase(generation: generation) == nil
        {
            throw LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: providerID,
                installedGeneration: maximum,
                requestedGeneration: generation
            )
        }
        try rejectNameCollisions(descriptor)

        let recoveredPhase = state.phase(generation: generation)
        if recoveredPhase == nil {
            state.stagedGenerations.insert(generation)
            state.descriptorsByGeneration[generation] = descriptor
            var nextStates = statesByProviderID
            nextStates[providerID] = state
            try persist(nextStates)
            statesByProviderID = nextStates
        }
        var nextEntries = entriesByProviderID[providerID] ?? [:]
        nextEntries[generation] = Entry(
            descriptor: descriptor,
            provider: provider
        )
        entriesByProviderID[providerID] = nextEntries
        if let recoveredPhase {
            return .recovered(recoveredPhase)
        }
        return .staged
    }

    /// Publishes one ready staged generation. The prior active generation is
    /// retained as draining before new lookups can observe the replacement.
    @discardableResult
    public func activate(
        providerID: String,
        generation: UInt64
    ) async throws -> LogDriverProviderActivationResult {
        guard entriesByProviderID[providerID]?[generation] != nil else {
            throw LogDriverProviderRegistryError.providerGenerationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        var state = statesByProviderID[providerID] ?? ProviderState()
        if state.activeGeneration == generation {
            return .unchanged
        }
        guard state.stagedGenerations.contains(generation) else {
            throw LogDriverProviderRegistryError.providerGenerationNotStaged(
                providerID: providerID,
                generation: generation
            )
        }
        if let active = state.activeGeneration, generation < active {
            throw LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: providerID,
                installedGeneration: active,
                requestedGeneration: generation
            )
        }
        let previous = state.activeGeneration
        if let previous {
            state.drainingGenerations.insert(previous)
        }
        state.stagedGenerations.remove(generation)
        state.drainingGenerations.remove(generation)
        state.activeGeneration = generation
        var nextStates = statesByProviderID
        nextStates[providerID] = state
        try persist(nextStates)
        statesByProviderID = nextStates
        return .activated(previousGeneration: previous)
    }

    /// Removes a candidate which failed readiness. The active catalog and all
    /// draining exact selections remain unchanged.
    @discardableResult
    public func rollbackStaged(
        providerID: String,
        generation: UInt64
    ) async throws -> Bool {
        guard var state = statesByProviderID[providerID] else { return false }
        guard state.stagedGenerations.contains(generation) else {
            return false
        }
        state.stagedGenerations.remove(generation)
        state.descriptorsByGeneration.removeValue(forKey: generation)
        var nextStates = statesByProviderID
        if state.allGenerations.isEmpty {
            nextStates.removeValue(forKey: providerID)
        } else {
            nextStates[providerID] = state
        }
        var nextEntries = entriesByProviderID
        nextEntries[providerID]?[generation] = nil
        try persist(nextStates)
        statesByProviderID = nextStates
        entriesByProviderID = nextEntries
        return true
    }

    /// Restores the newest retained draining generation after an activated
    /// candidate becomes unhealthy. The failed generation is no longer
    /// selectable in this process and will be staged again on rediscovery.
    @discardableResult
    public func rollbackActive(
        providerID: String,
        generation: UInt64
    ) async throws -> RegisteredLogDriverProvider {
        guard var state = statesByProviderID[providerID],
            state.activeGeneration == generation
        else {
            throw LogDriverProviderRegistryError.providerGenerationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        let fallbackGeneration = try state.drainingGenerations
            .filter { entriesByProviderID[providerID]?[$0] != nil }
            .max()
            .unwrap(
                or: LogDriverProviderRegistryError.rollbackGenerationUnavailable(
                    providerID: providerID,
                    generation: generation
                ))
        state.drainingGenerations.remove(fallbackGeneration)
        state.activeGeneration = fallbackGeneration
        state.stagedGenerations.remove(generation)
        state.drainingGenerations.remove(generation)
        state.descriptorsByGeneration.removeValue(forKey: generation)
        var nextStates = statesByProviderID
        nextStates[providerID] = state
        var nextEntries = entriesByProviderID
        nextEntries[providerID]?[generation] = nil
        try persist(nextStates)
        statesByProviderID = nextStates
        entriesByProviderID = nextEntries
        let fallback = entriesByProviderID[providerID]?[fallbackGeneration]
            .map(\.selection)
        return try fallback.unwrap(
            or: LogDriverProviderRegistryError.rollbackGenerationUnavailable(
                providerID: providerID,
                generation: generation
            )
        )
    }

    /// Removes only the exact installed generation. If it is active, the
    /// newest retained draining generation becomes active in the same durable
    /// transition; otherwise the provider disappears from the catalog.
    @discardableResult
    public func uninstall(
        providerID: String,
        generation: UInt64
    ) async throws -> Bool {
        guard entriesByProviderID[providerID]?[generation] != nil else {
            guard
                let installed = statesByProviderID[providerID]?
                    .allGenerations.max()
            else { return false }
            throw LogDriverProviderRegistryError.staleProviderGeneration(
                providerID: providerID,
                installedGeneration: installed,
                requestedGeneration: generation
            )
        }
        var state = statesByProviderID[providerID] ?? ProviderState()
        state.stagedGenerations.remove(generation)
        state.drainingGenerations.remove(generation)
        state.descriptorsByGeneration.removeValue(forKey: generation)
        if state.activeGeneration == generation {
            let fallback = state.drainingGenerations
                .filter { entriesByProviderID[providerID]?[$0] != nil }
                .max()
            state.activeGeneration = fallback
            if let fallback { state.drainingGenerations.remove(fallback) }
        }
        var nextStates = statesByProviderID
        if state.allGenerations.isEmpty {
            nextStates.removeValue(forKey: providerID)
        } else {
            nextStates[providerID] = state
        }
        var nextEntries = entriesByProviderID
        nextEntries[providerID]?[generation] = nil
        if nextEntries[providerID]?.isEmpty == true {
            nextEntries.removeValue(forKey: providerID)
        }
        try persist(nextStates)
        statesByProviderID = nextStates
        entriesByProviderID = nextEntries
        return true
    }

    public func logDriverCatalog() throws -> LogDriverCatalog {
        try LogDriverCatalog(
            descriptors: baseCatalog.descriptors + activeEntries().map(\.descriptor)
        )
    }

    public func selection(named registeredName: String) -> RegisteredLogDriverProvider? {
        activeEntries().first {
            $0.descriptor.registeredNames.contains(registeredName)
        }?.selection
    }

    public func selection(
        providerID: String,
        generation: UInt64
    ) -> RegisteredLogDriverProvider? {
        entriesByProviderID[providerID]?[generation]?.selection
    }

    public func activeSelections(
        kind: LogDriverProviderIdentity.Kind? = nil
    ) -> [RegisteredLogDriverProvider] {
        activeEntries().filter {
            kind == nil || $0.descriptor.providerIdentity.kind == kind
        }.map(\.selection)
    }

    public func generationPhase(
        providerID: String,
        generation: UInt64
    ) -> LogDriverProviderGenerationPhaseV1? {
        statesByProviderID[providerID]?.phase(generation: generation)
    }

    public func activeGeneration(providerID: String) -> UInt64? {
        statesByProviderID[providerID]?.activeGeneration
    }

    public func stateSnapshot() throws -> LogDriverProviderRegistryStateV1 {
        try snapshot(statesByProviderID)
    }

    /// Resolves one persisted authority decision without a catalog/provider
    /// time-of-check/time-of-use split. Active and draining generations are
    /// both valid; a merely staged candidate cannot own container effects.
    public func selection(
        for configuration: ResolvedContainerLogConfiguration
    ) throws -> RegisteredLogDriverProvider {
        let providerID = configuration.providerIdentity.id
        guard let entries = entriesByProviderID[providerID] else {
            throw LogDriverProviderRegistryError.providerNotFound(providerID)
        }
        let generation = configuration.providerGenerationAtResolution
        let phase = statesByProviderID[providerID]?.phase(
            generation: generation
        )
        guard
            phase == .active || phase == .draining,
            let entry = entries[generation]
        else {
            throw LogDriverProviderRegistryError.resolvedConfigurationMismatch
        }
        let descriptor = entry.descriptor
        guard
            descriptor.driver == configuration.driver,
            descriptor.providerIdentity == configuration.providerIdentity,
            descriptor.providerGeneration == generation,
            descriptor.optionContractDigest == configuration.contractDigest
        else {
            throw LogDriverProviderRegistryError.resolvedConfigurationMismatch
        }
        return entry.selection
    }

    private func activeEntries() -> [Entry] {
        statesByProviderID.compactMap { providerID, state in
            guard let generation = state.activeGeneration else { return nil }
            return entriesByProviderID[providerID]?[generation]
        }.sorted {
            $0.descriptor.providerIdentity.id
                < $1.descriptor.providerIdentity.id
        }
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
        _ descriptor: LogDriverDescriptor
    ) throws {
        var registeredNames = Set(baseCatalog.registeredNames)
        for (providerID, state) in statesByProviderID
        where providerID != descriptor.providerIdentity.id {
            for persistedDescriptor in state.descriptorsByGeneration.values {
                registeredNames.formUnion(
                    persistedDescriptor.registeredNames
                )
            }
        }
        if let collision = descriptor.registeredNames.first(
            where: registeredNames.contains
        ) {
            throw LogDriverProviderRegistryError.registeredNameCollision(collision)
        }
    }

    private func persist(_ states: [String: ProviderState]) throws {
        guard let persistence else { return }
        try persistence.save(snapshot(states))
    }

    private func snapshot(
        _ states: [String: ProviderState]
    ) throws -> LogDriverProviderRegistryStateV1 {
        try LogDriverProviderRegistryStateV1(
            providers: try states.map { providerID, state in
                try LogDriverProviderIdentityStateV1(
                    providerID: providerID,
                    activeGeneration: state.activeGeneration,
                    stagedGenerations: state.stagedGenerations.sorted(),
                    drainingGenerations: state.drainingGenerations.sorted(),
                    descriptors: state.descriptorsByGeneration.values.sorted {
                        $0.providerGeneration < $1.providerGeneration
                    }
                )
            }.sorted { $0.providerID < $1.providerID }
        )
    }
}

extension Optional {
    fileprivate func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
