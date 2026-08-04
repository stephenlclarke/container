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
import NIOCore

/// Provider whose effect identity is fenced to one Engine Linux sandbox
/// generation. The authority must bind that generation into every writer
/// request before the first provider effect.
public protocol EngineLinuxSandboxLogDriverProvider:
    ContainerLogDriverProvider
{
    func activeSandboxGeneration() async throws -> UInt64
}

extension JournaldLogDriverProvider: EngineLinuxSandboxLogDriverProvider {}
extension DockerPluginLogDriverProvider:
    EngineLinuxSandboxLogDriverProvider
{}
extension DockerPluginServiceLogDriverProvider:
    EngineLinuxSandboxLogDriverProvider
{}

public enum BuiltinRemoteLogDriverConfigurationError: Error, Equatable,
    Sendable
{
    case contextNotFound(String)
    case contextConflict(String)
    case contextDriverMismatch(expected: String, actual: String)
    case requestIdentityMismatch(String)
}

/// Ephemeral authority-to-provider configuration registry.
///
/// Resolved safe and protected options are converted into a typed driver
/// configuration by the authority immediately before start. This registry
/// retains that typed value only for the exact start request. It deliberately
/// has no persistence or generic option-map API, so protected option values
/// cannot enter the provider lifecycle ledger or ordinary configuration.
public actor BuiltinRemoteLogDriverConfigurationRegistry:
    SyslogConfigurationResolving, FluentdConfigurationResolving,
    GELFConfigurationResolving, SplunkConfigurationResolving,
    AWSLogsConfigurationResolving, GCPLogsConfigurationResolving,
    JournaldConfigurationResolving, DockerPluginConfigurationResolving
{
    private enum Entry: Sendable {
        case syslog(
            request: LogDriverStartRequestV1,
            binding: SyslogConfigurationBinding
        )
        case fluentd(
            request: LogDriverStartRequestV1,
            binding: FluentdConfigurationBinding
        )
        case gelf(
            request: LogDriverStartRequestV1,
            binding: GELFConfigurationBinding
        )
        case splunk(
            request: LogDriverStartRequestV1,
            binding: SplunkConfigurationBinding
        )
        case awslogs(
            request: LogDriverStartRequestV1,
            binding: AWSLogsConfigurationBinding
        )
        case gcplogs(
            request: LogDriverStartRequestV1,
            binding: GCPLogsConfigurationBinding
        )
        case journald(
            request: LogDriverStartRequestV1,
            binding: JournaldConfigurationBinding
        )
        case dockerPlugin(
            request: LogDriverStartRequestV1,
            binding: DockerPluginConfigurationBinding
        )

        var request: LogDriverStartRequestV1 {
            switch self {
            case .syslog(let request, _), .fluentd(let request, _),
                .gelf(let request, _), .splunk(let request, _),
                .awslogs(let request, _), .gcplogs(let request, _),
                .journald(let request, _),
                .dockerPlugin(let request, _):
                request
            }
        }

        var driver: String {
            switch self {
            case .syslog: "syslog"
            case .fluentd: "fluentd"
            case .gelf: "gelf"
            case .splunk: "splunk"
            case .awslogs: "awslogs"
            case .gcplogs: "gcplogs"
            case .journald: "journald"
            case .dockerPlugin: "docker-plugin"
            }
        }
    }

    private struct ReaderEntry: Sendable {
        let request: LogDriverReaderOpenRequestV1
        let binding: DockerPluginConfigurationBinding
    }

    private var entries = [String: Entry]()
    private var readerEntries = [String: ReaderEntry]()

    public init() {}

    public func register(
        _ binding: SyslogConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.syslog(request: request, binding: binding))
    }

    public func register(
        _ binding: FluentdConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.fluentd(request: request, binding: binding))
    }

    public func register(
        _ binding: GELFConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.gelf(request: request, binding: binding))
    }

    public func register(
        _ binding: SplunkConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.splunk(request: request, binding: binding))
    }

    public func register(
        _ binding: AWSLogsConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.awslogs(request: request, binding: binding))
    }

    public func register(
        _ binding: GCPLogsConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.gcplogs(request: request, binding: binding))
    }

    public func register(
        _ binding: JournaldConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.journald(request: request, binding: binding))
    }

    public func register(
        _ binding: DockerPluginConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.dockerPlugin(request: request, binding: binding))
    }

    public func register(
        _ binding: DockerPluginConfigurationBinding,
        for request: LogDriverReaderOpenRequestV1
    ) throws {
        let entry = ReaderEntry(request: request, binding: binding)
        if let existing = readerEntries[request.readerSessionID] {
            guard
                existing.request == request,
                existing.binding == binding
            else {
                throw
                    BuiltinRemoteLogDriverConfigurationError
                    .contextConflict(request.readerSessionID)
            }
            return
        }
        readerEntries[request.readerSessionID] = entry
    }

    /// Removes only the exact request identity. A stale cleanup cannot erase a
    /// later session which happens to reuse the same externally supplied ID.
    @discardableResult
    public func unregister(
        _ request: LogDriverStartRequestV1
    ) throws -> Bool {
        guard let entry = entries[request.sessionID] else {
            return false
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        }
        entries.removeValue(forKey: request.sessionID)
        return true
    }

    /// Removes only the exact reader request identity.
    @discardableResult
    public func unregister(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> Bool {
        guard let entry = readerEntries[request.readerSessionID] else {
            return false
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.readerSessionID)
        }
        readerEntries.removeValue(forKey: request.readerSessionID)
        return true
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> SyslogConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .syslog(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "syslog",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> GCPLogsConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .gcplogs(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "gcplogs",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> AWSLogsConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .awslogs(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "awslogs",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> FluentdConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .fluentd(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "fluentd",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> GELFConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .gelf(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "gelf",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> SplunkConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .splunk(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "splunk",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> JournaldConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .journald(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "journald",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> DockerPluginConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .dockerPlugin(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "docker-plugin",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverReaderOpenRequestV1
    ) throws -> DockerPluginConfigurationBinding {
        guard let entry = readerEntries[request.readerSessionID] else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextNotFound(request.readerSessionID)
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.readerSessionID)
        }
        return entry.binding
    }

    package var registeredContextCount: Int {
        entries.count + readerEntries.count
    }

    private func register(_ entry: Entry) throws {
        let sessionID = entry.request.sessionID
        if let existing = entries[sessionID] {
            guard Self.isIdentical(existing, entry) else {
                throw
                    BuiltinRemoteLogDriverConfigurationError
                    .contextConflict(sessionID)
            }
            return
        }
        entries[sessionID] = entry
    }

    private func exactEntry(
        for request: LogDriverStartRequestV1
    ) throws -> Entry {
        guard let entry = entries[request.sessionID] else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextNotFound(request.sessionID)
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        }
        return entry
    }

    private static func isIdentical(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs, rhs) {
        case (.syslog(let leftRequest, let left), .syslog(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        case (.fluentd(let leftRequest, let left), .fluentd(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        case (.gelf(let leftRequest, let left), .gelf(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        case (
            .splunk(let leftRequest, let left),
            .splunk(let rightRequest, let right)
        ):
            leftRequest == rightRequest && left == right
        case (
            .awslogs(let leftRequest, let left),
            .awslogs(let rightRequest, let right)
        ):
            leftRequest == rightRequest && left == right
        case (
            .gcplogs(let leftRequest, let left),
            .gcplogs(let rightRequest, let right)
        ):
            leftRequest == rightRequest && left == right
        case (
            .journald(let leftRequest, let left),
            .journald(let rightRequest, let right)
        ):
            leftRequest == rightRequest && left == right
        case (
            .dockerPlugin(let leftRequest, let left),
            .dockerPlugin(let rightRequest, let right)
        ):
            leftRequest == rightRequest && left == right
        default:
            false
        }
    }
}

/// Trusted, already-installed Docker logging-plugin generation supplied by the
/// production service plane. Distribution and trust approval stay outside the
/// logging lifecycle; this immutable value installs only the resolved driver
/// contract and authenticated acquisition boundary.
public struct DockerPluginLogDriverInstallation: Sendable {
    public let driver: String
    public let aliases: [String]
    public let providerIdentity: LogDriverProviderIdentity
    public let providerGeneration: UInt64
    public let readLogs: Bool
    public let trust: LogDriverTrust
    public let lifecycleService: (any DockerPluginLifecycleService)?
    public let generationReclaimer: (any DockerPluginProviderGenerationReclaiming)?
    public let providerAcquirer: (any DockerPluginProviderAcquiring)?
    public let fifoFactory: (any DockerPluginFIFOFactory)?

    /// Installs the production, service-owned lifecycle boundary. Installed
    /// plugins are operator-approved unless a higher layer has verified a
    /// signature and explicitly supplies `.signed`.
    public init(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        readLogs: Bool,
        trust: LogDriverTrust = .approved,
        lifecycleService: any DockerPluginLifecycleService,
        generationReclaimer:
            (any DockerPluginProviderGenerationReclaiming)? = nil
    ) {
        self.driver = driver
        self.aliases = aliases
        self.providerIdentity = providerIdentity
        self.providerGeneration = providerGeneration
        self.readLogs = readLogs
        self.trust = trust
        self.lifecycleService = lifecycleService
        self.generationReclaimer = generationReclaimer
        self.providerAcquirer = nil
        self.fifoFactory = nil
    }

    /// Retains the low-level adapter seam for protocol conformance tests. The
    /// production install path uses the lifecycle-service initializer above
    /// because this variant cannot survive reconstruction of its host actor.
    public init(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        readLogs: Bool,
        trust: LogDriverTrust = .signed,
        providerAcquirer: any DockerPluginProviderAcquiring,
        fifoFactory: any DockerPluginFIFOFactory
    ) {
        self.driver = driver
        self.aliases = aliases
        self.providerIdentity = providerIdentity
        self.providerGeneration = providerGeneration
        self.readLogs = readLogs
        self.trust = trust
        self.lifecycleService = nil
        self.generationReclaimer = nil
        self.providerAcquirer = providerAcquirer
        self.fifoFactory = fifoFactory
    }
}

/// The maintained first-party remote provider generation installed as one
/// immutable production unit.
///
/// All transports share the caller-owned event-loop group. The authority
/// retains the configuration registry and registers one exact typed context
/// before invoking the lifecycle controller; providers cannot start from a
/// catalog lookup alone.
public struct BuiltinRemoteLogDriverProviderSet: Sendable {
    public let registry: LogDriverProviderRegistry
    public let configurations: BuiltinRemoteLogDriverConfigurationRegistry
    public let syslog: SyslogLogDriverProvider
    public let fluentd: FluentdLogDriverProvider
    public let gelf: GELFLogDriverProvider
    public let splunk: SplunkLogDriverProvider
    public let awslogs: AWSLogsLogDriverProvider
    public let gcplogs: GCPLogsLogDriverProvider
    public let journald: JournaldLogDriverProvider?
    public let dockerPlugins: [any EngineLinuxSandboxLogDriverProvider]

    private init(
        registry: LogDriverProviderRegistry,
        configurations: BuiltinRemoteLogDriverConfigurationRegistry,
        syslog: SyslogLogDriverProvider,
        fluentd: FluentdLogDriverProvider,
        gelf: GELFLogDriverProvider,
        splunk: SplunkLogDriverProvider,
        awslogs: AWSLogsLogDriverProvider,
        gcplogs: GCPLogsLogDriverProvider,
        journald: JournaldLogDriverProvider?,
        dockerPlugins: [any EngineLinuxSandboxLogDriverProvider]
    ) {
        self.registry = registry
        self.configurations = configurations
        self.syslog = syslog
        self.fluentd = fluentd
        self.gelf = gelf
        self.splunk = splunk
        self.awslogs = awslogs
        self.gcplogs = gcplogs
        self.journald = journald
        self.dockerPlugins = dockerPlugins
    }

    public static func install(
        eventLoopGroup: any EventLoopGroup,
        awsLogsClientFactory: any AWSLogsClientFactory,
        journaldService: (any JournaldService)? = nil,
        dockerPluginInstallations: [DockerPluginLogDriverInstallation] = [],
        providerGeneration: UInt64 = 1,
        baseCatalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current,
        registryPersistence:
            (any LogDriverProviderRegistryPersisting)? = nil
    ) async throws -> Self {
        let configurations = BuiltinRemoteLogDriverConfigurationRegistry()
        let syslog = SyslogLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOSyslogTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let fluentd = FluentdLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOFluentdTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let gelf = GELFLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOGELFTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let splunk = SplunkLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations
        )
        let awslogs = AWSLogsLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            clientFactory: awsLogsClientFactory
        )
        let gcplogs = GCPLogsLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations
        )
        let journald = journaldService.map {
            JournaldLogDriverProvider(
                providerGeneration: providerGeneration,
                configurationResolver: configurations,
                service: $0
            )
        }
        let dockerPlugins: [any EngineLinuxSandboxLogDriverProvider] =
            try dockerPluginInstallations.map { installation in
                if let service = installation.lifecycleService {
                    return try DockerPluginServiceLogDriverProvider(
                        driver: installation.driver,
                        aliases: installation.aliases,
                        providerIdentity: installation.providerIdentity,
                        providerGeneration: installation.providerGeneration,
                        readLogs: installation.readLogs,
                        trust: installation.trust,
                        configurationResolver: configurations,
                        service: service,
                        generationReclaimer: installation.generationReclaimer
                    )
                }
                guard
                    let providerAcquirer = installation.providerAcquirer,
                    let fifoFactory = installation.fifoFactory
                else {
                    throw DockerPluginProtocolError.invalidProviderIdentity
                }
                return try DockerPluginLogDriverProvider(
                    driver: installation.driver,
                    aliases: installation.aliases,
                    providerIdentity: installation.providerIdentity,
                    providerGeneration: installation.providerGeneration,
                    readLogs: installation.readLogs,
                    trust: installation.trust,
                    configurationResolver: configurations,
                    providerAcquirer: providerAcquirer,
                    fifoFactory: fifoFactory
                )
            }
        let registry: LogDriverProviderRegistry
        if let registryPersistence {
            registry = try await LogDriverProviderRegistry.open(
                baseCatalog: baseCatalog,
                persistence: registryPersistence
            )
        } else {
            registry = LogDriverProviderRegistry(baseCatalog: baseCatalog)
        }
        try await installNativeGeneration(
            syslog,
            registry: registry
        ) {
            SyslogLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations,
                transportFactory: NIOSyslogTransportFactory(
                    eventLoopGroup: eventLoopGroup
                )
            )
        }
        try await installNativeGeneration(
            fluentd,
            registry: registry
        ) {
            FluentdLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations,
                transportFactory: NIOFluentdTransportFactory(
                    eventLoopGroup: eventLoopGroup
                )
            )
        }
        try await installNativeGeneration(gelf, registry: registry) {
            GELFLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations,
                transportFactory: NIOGELFTransportFactory(
                    eventLoopGroup: eventLoopGroup
                )
            )
        }
        try await installNativeGeneration(splunk, registry: registry) {
            SplunkLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations
            )
        }
        try await installNativeGeneration(awslogs, registry: registry) {
            AWSLogsLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations,
                clientFactory: awsLogsClientFactory
            )
        }
        try await installNativeGeneration(gcplogs, registry: registry) {
            GCPLogsLogDriverProvider(
                providerGeneration: $0,
                configurationResolver: configurations
            )
        }
        if let journald, let journaldService {
            try await installNativeGeneration(
                journald,
                registry: registry
            ) {
                JournaldLogDriverProvider(
                    providerGeneration: $0,
                    configurationResolver: configurations,
                    service: journaldService
                )
            }
        }
        try await installDockerPluginGenerations(
            dockerPlugins,
            registry: registry
        )
        return Self(
            registry: registry,
            configurations: configurations,
            syslog: syslog,
            fluentd: fluentd,
            gelf: gelf,
            splunk: splunk,
            awslogs: awslogs,
            gcplogs: gcplogs,
            journald: journald,
            dockerPlugins: dockerPlugins
        )
    }

    /// Reconstructs the exact compatible source adapter before staging the
    /// current native generation. This lets authority-led quiescence reconcile
    /// old durable references after a binary restart without publishing the
    /// new generation prematurely. A changed descriptor fails closed because
    /// registry recovery compares it with the persisted source contract.
    private static func installNativeGeneration<Provider>(
        _ current: Provider,
        registry: LogDriverProviderRegistry,
        makeProvider: (UInt64) -> Provider
    ) async throws where Provider: ContainerLogDriverProvider {
        let descriptor = try await current.descriptor
        let providerID = descriptor.providerIdentity.id
        let currentGeneration = descriptor.providerGeneration
        if let active = await registry.activeGeneration(
            providerID: providerID
        ), active != currentGeneration {
            guard active < currentGeneration else {
                throw LogDriverProviderRegistryError.staleProviderGeneration(
                    providerID: providerID,
                    installedGeneration: active,
                    requestedGeneration: currentGeneration
                )
            }
            _ = try await registry.stage(makeProvider(active))
        }
        _ = try await registry.stage(current)
        if await registry.activeGeneration(providerID: providerID) == nil {
            _ = try await registry.activate(
                providerID: providerID,
                generation: currentGeneration
            )
        }
    }

    private static func installDockerPluginGenerations(
        _ providers: [any EngineLinuxSandboxLogDriverProvider],
        registry: LogDriverProviderRegistry
    ) async throws {
        var generations = [String: [(UInt64, any EngineLinuxSandboxLogDriverProvider)]]()
        for provider in providers {
            let descriptor = try await provider.descriptor
            generations[descriptor.providerIdentity.id, default: []].append(
                (descriptor.providerGeneration, provider)
            )
        }

        for providerID in generations.keys.sorted() {
            let candidates = generations[providerID, default: []].sorted {
                $0.0 < $1.0
            }
            for (_, provider) in candidates {
                _ = try await registry.stage(provider)
            }

            try await recoverHealthyActiveGeneration(
                providerID: providerID,
                registry: registry
            )
            var highestHealthyGeneration: UInt64?
            for (generation, provider) in candidates {
                guard
                    await registry.generationPhase(
                        providerID: providerID,
                        generation: generation
                    ) == .staged
                else {
                    continue
                }
                if let active = await registry.activeGeneration(
                    providerID: providerID
                ), generation < active {
                    _ = try await registry.rollbackStaged(
                        providerID: providerID,
                        generation: generation
                    )
                    continue
                }
                do {
                    let sandboxGeneration =
                        try await provider
                        .activeSandboxGeneration()
                    guard sandboxGeneration > 0 else {
                        throw DockerPluginProtocolError.invalidSessionFence
                    }
                    highestHealthyGeneration = generation
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    _ = try await registry.rollbackStaged(
                        providerID: providerID,
                        generation: generation
                    )
                }
            }
            if await registry.activeGeneration(providerID: providerID) == nil,
                let highestHealthyGeneration
            {
                for generation in await registry.stagedGenerations(
                    providerID: providerID
                ) where generation < highestHealthyGeneration {
                    _ = try await registry.rollbackStaged(
                        providerID: providerID,
                        generation: generation
                    )
                }
                _ = try await registry.activate(
                    providerID: providerID,
                    generation: highestHealthyGeneration
                )
            }
        }
    }

    private static func recoverHealthyActiveGeneration(
        providerID: String,
        registry: LogDriverProviderRegistry
    ) async throws {
        while let active = await registry.activeGeneration(
            providerID: providerID
        ) {
            guard
                let selection = await registry.selection(
                    providerID: providerID,
                    generation: active
                ),
                let provider = selection.provider
                    as? any EngineLinuxSandboxLogDriverProvider
            else {
                do {
                    _ = try await registry.rollbackActive(
                        providerID: providerID,
                        generation: active
                    )
                    continue
                } catch LogDriverProviderRegistryError
                    .rollbackGenerationUnavailable
                {
                    return
                }
            }
            do {
                let sandboxGeneration =
                    try await provider
                    .activeSandboxGeneration()
                guard sandboxGeneration > 0 else {
                    throw DockerPluginProtocolError.invalidSessionFence
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                do {
                    _ = try await registry.rollbackActive(
                        providerID: providerID,
                        generation: active
                    )
                } catch LogDriverProviderRegistryError
                    .rollbackGenerationUnavailable
                {
                    return
                }
            }
        }
    }
}
