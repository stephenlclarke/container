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

import CVersion
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

public actor ContainersService {
    enum ContainerLoggingCreatePlan: Sendable {
        case legacy(ContainerLogConfiguration)
        case version2(PreparedContainerLogResolution)
    }

    struct SealedContainerLogging: Sendable {
        let configuration: ContainerLogConfiguration
        let protectedReference: LoggingProtectedOptionsReference?
        let protectedBinding: LoggingProtectedOptionsBinding?
    }

    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: RuntimeClient? = nil
        var restart = ContainerRestartTracker()

        func getClient() throws -> RuntimeClient {
            guard let client else {
                var message = "no runtime client exists"
                if snapshot.status == .stopped {
                    message += ": container is stopped"
                }
                throw ContainerizationError(.invalidState, message: message)
            }
            return client
        }
    }

    private struct StartedExecProcess {
        let snapshot: ContainerSnapshot
        let processID: String
        let client: RuntimeClient
    }

    private static let machServicePrefix = "com.apple.container"
    private static let launchdDomainString = try! ServiceManager.getDomainString()
    private static let logTailReadChunkSize = UInt64(32 * 1024)
    static let loggingProtectedOptionsDirectoryName = "logging-protected-options"
    private static let loggingLeaseGeneration: UInt64 = 1

    private let log: Logger
    private let debugHelpers: Bool
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor
    private let eventBroadcaster: ContainerEventBroadcaster
    private let containerSystemConfig: ContainerSystemConfig
    private let loggingProtectedOptionsStore: LoggingProtectedOptionsStore

    private let lock: AsyncLock
    private var containers: [String: ContainerState]
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]
    private var restartTasks: [String: Task<Void, Never>] = [:]
    private var restartTaskTokens: [String: UUID] = [:]
    private var restartStabilityTasks: [String: Task<Void, Never>] = [:]
    private var restartStabilityTaskTokens: [String: UUID] = [:]
    private var execEventTracker = ContainerExecEventTracker()
    private var execExitTasks: [String: [String: Task<Void, Never>]] = [:]

    // FIXME: Find a better mechanism for services running on the APIServer to work with each other
    private weak var networksService: NetworksService?

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        debugHelpers: Bool = false
    ) throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        let containers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
        let retainedProtectedObjectIDs = Self.loggingProtectedObjectIDsAtBoot(
            root: containerRoot,
            log: log
        )
        let protectedStoreRoot = appRoot.appendingPathComponent(Self.loggingProtectedOptionsDirectoryName)
        let loggingProtectedOptionsStore: LoggingProtectedOptionsStore
        if let retainedProtectedObjectIDs {
            loggingProtectedOptionsStore = try LoggingProtectedOptionsStore(
                rootURL: protectedStoreRoot,
                retainingObjectIDs: retainedProtectedObjectIDs
            )
        } else {
            // An unreadable durable container may still own an object. Leave
            // every object in place until ownership can be proved at a later
            // boot instead of turning configuration damage into secret loss.
            loggingProtectedOptionsStore = try LoggingProtectedOptionsStore(rootURL: protectedStoreRoot)
        }
        self.exitMonitor = ExitMonitor(log: log)
        self.lock = AsyncLock(log: log)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.containerSystemConfig = containerSystemConfig
        self.log = log
        self.debugHelpers = debugHelpers
        self.eventBroadcaster = ContainerEventBroadcaster()
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.loggingProtectedOptionsStore = loggingProtectedOptionsStore
        self.containers = containers
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
    }

    func events(options: ContainerEventOptions = .default) async -> ContainerEventSubscription {
        await eventBroadcaster.subscribe(options: options)
    }

    static func loadAtBoot(root: URL, loader: PluginLoader, log: Logger) throws -> [String: ContainerState] {
        var directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        directories = directories.filter {
            $0.isDirectory
        }

        let runtimePlugins = loader.findPlugins().filter { $0.hasType(.runtime) }
        var results = [String: ContainerState]()
        for dir in directories {
            do {
                let (config, options) = try Self.getContainerConfiguration(at: dir)
                _ = try Self.containerPath(root: root, id: config.id)
                if options?.autoRemove ?? false {
                    log.info(
                        "reap auto-remove container",
                        metadata: [
                            "id": "\(config.id)"
                        ])

                    let label = Self.fullLaunchdServiceLabel(
                        runtimeName: config.runtimeHandler,
                        instanceId: config.id)

                    var status: Int32 = -1
                    try? ServiceManager.deregister(fullServiceLabel: label, status: &status)
                    if status != 0 {
                        log.warning(
                            "failed to deregister service",
                            metadata: [
                                "id": "\(config.id)",
                                "service": "\(label)",
                                "status": "\(status)",
                            ]
                        )
                    }

                    let bundle = ContainerResource.Bundle(path: dir)
                    try? bundle.delete()
                    continue
                }

                guard runtimePlugins.first(where: { $0.name == config.runtimeHandler }) != nil else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to find runtime plugin \(config.runtimeHandler)"
                    )
                }
                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        networks: [],
                        startedDate: nil
                    ),
                )
                results[config.id] = state
            } catch {
                log.warning(
                    "failed to load container; leaving bundle on disk",
                    metadata: [
                        "path": "\(dir.path)",
                        "error": "\(error)",
                    ])
            }
        }
        return results
    }

    static func loggingProtectedObjectIDsAtBoot(root: URL, log: Logger) -> Set<String>? {
        guard
            let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return nil
        }

        var objectIDs = Set<String>()
        for directory in directories where directory.isDirectory {
            do {
                let (configuration, _) = try Self.getContainerConfiguration(at: directory)
                if let objectID = configuration.logging.resolved?.protectedOptionReference?.objectID {
                    objectIDs.insert(objectID)
                }
            } catch {
                log.warning(
                    "unable to inspect durable container logging reference during reconciliation",
                    metadata: ["path": "\(directory.path)"]
                )
                return nil
            }
        }
        return objectIDs
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let labelPatterns: [(key: String, regex: Regex<AnyRegexOutput>)] = try filters.labels.map { key, pattern in
            do {
                return (key: key, regex: try Regex(pattern))
            } catch {
                throw ContainerizationError(
                    .invalidArgument, message: "failed to compile regex '\(pattern)' for \(key)",
                    cause: error)
            }
        }

        return self.containers.values.compactMap { state -> ContainerSnapshot? in
            let snapshot = state.snapshot

            if !filters.ids.isEmpty {
                guard filters.ids.contains(snapshot.id) else {
                    return nil
                }
            }

            if let status = filters.status {
                guard snapshot.status == status else {
                    return nil
                }
            }

            for (key, regex) in labelPatterns {
                let label = snapshot.configuration.labels[key] ?? ""

                guard label.contains(regex) else {
                    return nil
                }
            }

            return snapshot
        }
    }

    /// Execute an operation with the current container list while maintaining atomicity
    /// This prevents race conditions where containers are created during the operation
    public func withContainerList<T: Sendable>(
        logMetadata: Logger.Metadata? = nil,
        _ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T
    ) async throws -> T {
        try await lock.withLock(logMetadata: logMetadata) { context in
            let snapshots = await self.containers.values.map { $0.snapshot }
            return try await operation(snapshots)
        }
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        let containers = await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            await self.containers.map {
                ContainerDiskUsageEntry(id: $0.key, status: $0.value.snapshot.status)
            }
        }

        let paths = containers.compactMap { container -> ContainerDiskUsagePath? in
            guard let bundlePath = try? Self.containerPath(root: containerRoot, id: container.id) else {
                log.warning(
                    "skipping disk usage for container with invalid storage identifier",
                    metadata: ["id": "\(container.id)"]
                )
                return nil
            }
            return ContainerDiskUsagePath(path: bundlePath, status: container.status)
        }
        return await Self.calculateDiskUsage(totalCount: containers.count, paths: paths)
    }

    struct ContainerDiskUsageEntry: Sendable {
        let id: String
        let status: RuntimeStatus
    }

    struct ContainerDiskUsagePath: Sendable {
        let path: URL
        let status: RuntimeStatus
    }

    nonisolated static func calculateDiskUsage(
        totalCount: Int,
        paths: [ContainerDiskUsagePath]
    ) async -> (Int, Int, UInt64, UInt64) {
        await Task.detached(priority: .utility) {
            var totalSize: UInt64 = 0
            var reclaimableSize: UInt64 = 0
            var activeCount = 0

            for path in paths {
                let containerSize = FileManager.default.allocatedSize(of: path.path)
                totalSize += containerSize

                if path.status == .running {
                    activeCount += 1
                } else {
                    reclaimableSize += containerSize
                }
            }

            return (totalCount, activeCount, totalSize, reclaimableSize)
        }.value
    }

    /// Get set of image references used by containers (for disk usage calculation)
    /// - Returns: Set of image references currently in use
    public func getActiveImageReferences() async -> Set<String> {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var imageRefs = Set<String>()
            for (_, state) in await self.containers {
                imageRefs.insert(state.snapshot.configuration.image.reference)
            }
            return imageRefs
        }
    }

    /// Create a new container from the provided id and configuration.
    public func create(
        configuration: ContainerConfiguration,
        loggingRequest: ContainerLogRequest? = nil,
        kernel: Kernel,
        options: ContainerCreateOptions,
        initImage: String? = nil,
        runtimeData: Data? = nil
    ) async throws {
        let loggingPlan: ContainerLoggingCreatePlan
        do {
            loggingPlan = try Self.prepareLoggingForCreate(
                configuration: configuration.logging,
                request: loggingRequest,
                defaults: containerSystemConfig.logging
            )
        } catch {
            throw Self.mapLoggingCreateError(error)
        }

        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        let createdSnapshot = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(configuration.id)"]) { context -> ContainerSnapshot in
            try Utility.validEntityName(configuration.id)

            guard await self.containers[configuration.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container already exists: \(configuration.id)"
                )
            }

            let existingAttachments = await self.containers.values.map(\.snapshot.configuration.networks)
            let conflictingHostnames = Self.conflictingNetworkNames(
                existingAttachments: existingAttachments,
                requestedAttachments: configuration.networks
            )

            guard conflictingHostnames.isEmpty else {
                throw ContainerizationError(
                    .exists,
                    message: "hostname(s) already exist: \(conflictingHostnames)"
                )
            }

            guard self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) != nil else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(configuration.runtimeHandler)"
                )
            }

            // Protect against a user providing a memory amount that will cause us to not be able
            // to boot. We can go lower, but this is a somewhat safe threshold. Containerization
            // also gives a little bit extra than the user asked for to account for guest agent overhead.
            //
            // NOTE: We could potentially leave this validation to the runtime service(s), as
            // it's possible there could be an implementation that can get away with a lower
            // amount and be perfectly safe.
            let minimumMemory: UInt64 = 200.mib()
            guard configuration.resources.memoryInBytes >= minimumMemory else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "minimum memory amount allowed is 200 MiB (got \(configuration.resources.memoryInBytes) bytes)"
                )
            }

            let path = try Self.containerPath(root: self.containerRoot, id: configuration.id)
            let systemPlatform = kernel.platform

            // Fetch init image (custom or default)
            self.log.debug(
                "ContainersService: get init block",
                metadata: [
                    "id": "\(configuration.id)"
                ]
            )
            let initFilesystem = try await self.getInitBlock(for: systemPlatform.ociPlatform(), imageRef: initImage)

            var sealedLogging: SealedContainerLogging?
            do {
                self.log.debug(
                    "create snapshot",
                    metadata: [
                        "id": "\(configuration.id)",
                        "ref": "\(configuration.image.reference)",
                    ])
                let containerImage = ClientImage(description: configuration.image)
                let imageFs = try await options.rootFsOverride == nil ? containerImage.getCreateSnapshot(platform: configuration.platform) : nil

                let logging = try await self.sealLoggingForCreate(
                    containerID: configuration.id,
                    plan: loggingPlan
                )
                sealedLogging = logging
                var authoritativeConfiguration = configuration
                authoritativeConfiguration.logging = logging.configuration

                self.log.debug(
                    "configure runtime",
                    metadata: [
                        "id": "\(configuration.id)",
                        "kernel": "\(kernel.path)",
                        "initfs": "\(initImage ?? self.containerSystemConfig.vminit.image)",
                    ])
                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    initialFilesystem: initFilesystem,
                    kernel: kernel,
                    containerConfiguration: authoritativeConfiguration,
                    containerRootFilesystem: imageFs,
                    options: options,
                    runtimeData: runtimeData
                )

                try runtimeConfig.writeRuntimeConfiguration()

                let snapshot = ContainerSnapshot(
                    configuration: authoritativeConfiguration,
                    status: .stopped,
                    networks: [],
                    startedDate: nil
                )
                await self.setContainerState(configuration.id, ContainerState(snapshot: snapshot), context: context)
                return snapshot
            } catch {
                if let sealedLogging {
                    let bundle = ContainerResource.Bundle(path: path)
                    let bundleRemoved: Bool
                    if FileManager.default.fileExists(atPath: path.path) {
                        do {
                            try bundle.delete()
                            bundleRemoved = true
                        } catch {
                            bundleRemoved = false
                            self.log.warning(
                                "failed to remove container bundle after create failure",
                                metadata: ["id": "\(configuration.id)"]
                            )
                        }
                    } else {
                        bundleRemoved = true
                    }
                    if bundleRemoved {
                        await self.rollbackSealedLogging(sealedLogging)
                    }
                }
                throw error
            }
        }

        await publishContainerEvent(action: "create", snapshot: createdSnapshot)
    }

    static func validateLoggingConfigurationForCreate(_ logging: ContainerLogConfiguration) throws {
        guard logging.isLegacy else {
            throw ContainerizationError(
                .invalidArgument,
                message: "authority-resolved logging configuration requires a structured logging request"
            )
        }
    }

    static func prepareLoggingForCreate(
        configuration: ContainerLogConfiguration,
        request: ContainerLogRequest?,
        defaults: LoggingConfig,
        catalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current
    ) throws -> ContainerLoggingCreatePlan {
        guard let request else {
            try validateLoggingConfigurationForCreate(configuration)
            return .legacy(configuration)
        }
        let prepared = try ContainerLogRequestResolver(
            defaults: defaults,
            catalog: catalog
        ).prepare(request)
        return .version2(prepared)
    }

    func sealLoggingForCreate(
        containerID: String,
        plan: ContainerLoggingCreatePlan
    ) async throws -> SealedContainerLogging {
        switch plan {
        case .legacy(let configuration):
            return SealedContainerLogging(
                configuration: configuration,
                protectedReference: nil,
                protectedBinding: nil
            )
        case .version2(let prepared):
            let binding = LoggingProtectedOptionsBinding(
                containerID: containerID,
                prepared: prepared,
                leaseGeneration: Self.loggingLeaseGeneration
            )
            var reference: LoggingProtectedOptionsReference?
            do {
                if !prepared.protectedOptions.isEmpty {
                    let values = prepared.protectedOptions.withValues { $0 }
                    reference = try await loggingProtectedOptionsStore.store(
                        values,
                        boundTo: binding
                    )
                }
                let configuration = try prepared.finalizedConfiguration(
                    protectedReference: reference,
                    leaseGeneration: Self.loggingLeaseGeneration
                )
                return SealedContainerLogging(
                    configuration: configuration,
                    protectedReference: reference,
                    protectedBinding: reference == nil ? nil : binding
                )
            } catch {
                if let reference {
                    try? await loggingProtectedOptionsStore.delete(reference, boundTo: binding)
                }
                throw Self.mapLoggingCreateError(error)
            }
        }
    }

    func rollbackSealedLogging(_ sealed: SealedContainerLogging) async {
        guard
            let reference = sealed.protectedReference,
            let binding = sealed.protectedBinding
        else {
            return
        }
        do {
            try await loggingProtectedOptionsStore.delete(reference, boundTo: binding)
        } catch {
            log.warning("failed to roll back protected logging options after container create failure")
            guard
                let retainedObjectIDs = Self.loggingProtectedObjectIDsAtBoot(
                    root: containerRoot,
                    log: log
                )
            else {
                return
            }
            do {
                try await loggingProtectedOptionsStore.reconcile(
                    retainingObjectIDs: retainedObjectIDs
                )
            } catch {
                log.warning("protected logging rollback will retry at authority boot")
            }
        }
    }

    static func mapLoggingCreateError(_ error: any Error) -> ContainerizationError {
        if let error = error as? ContainerizationError {
            return error
        }
        if let error = error as? ContainerLogResolutionError {
            return ContainerizationError(
                .invalidArgument,
                message: "invalid logging configuration: \(error.description)"
            )
        }
        return ContainerizationError(
            .internalError,
            message: "failed to persist authoritative logging configuration"
        )
    }

    /// Returns primary hostnames that are already reserved on the same network.
    ///
    /// Primary hostnames identify one attachment. Aliases intentionally may resolve to
    /// multiple attachments, including an attachment whose primary hostname matches.
    static func conflictingNetworkNames(
        existingAttachments: [[AttachmentConfiguration]],
        requestedAttachments: [AttachmentConfiguration]
    ) -> [String] {
        var primaryHostnamesByNetwork = [String: Set<String>]()

        for attachments in existingAttachments {
            for attachment in attachments {
                let hostname = normalizedNetworkName(attachment.options.hostname)
                primaryHostnamesByNetwork[attachment.network, default: []].insert(hostname)
            }
        }

        var conflictingHostnames = Set<String>()
        for attachment in requestedAttachments {
            let hostname = normalizedNetworkName(attachment.options.hostname)
            if !primaryHostnamesByNetwork[attachment.network, default: []].insert(hostname).inserted {
                conflictingHostnames.insert(hostname)
            }
        }

        return conflictingHostnames.sorted()
    }

    private static func normalizedNetworkName(_ name: String) -> String {
        let name = name.hasSuffix(".") ? String(name.dropLast()) : name
        return name.lowercased()
    }

    /// Bootstrap the init process of the container.
    public func bootstrap(id: String, stdio: [FileHandle?], dynamicEnv: [String: String]) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "env": "\(dynamicEnv)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self.getContainerState(id: id, context: context)

            // We've already bootstrapped this container. Ideally we should be able to
            // return some sort of error code from the sandbox svc to check here, but this
            // is also a very simple check and faster than doing an rpc to get the same result.
            if state.client != nil {
                return
            }

            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let (config, _) = try Self.getContainerConfiguration(at: path)
            try await self.validateLoggingForStart(
                containerID: id,
                configuration: config.logging
            )

            var networkBootstrapInfos = [NetworkBootstrapInfo]()
            for n in config.networks {
                guard let plugin = try await self.networksService?.plugin(for: n.network) else {
                    throw ContainerizationError(.internalError, message: "failed to get plugin for network \(n.network)")
                }
                networkBootstrapInfos.append(NetworkBootstrapInfo(plugin: plugin))
            }

            do {
                try Self.registerService(
                    plugin: self.runtimePlugins.first { $0.name == config.runtimeHandler }!,
                    loader: self.pluginLoader,
                    configuration: config,
                    path: path,
                    debug: self.debugHelpers
                )

                let runtime = state.snapshot.configuration.runtimeHandler
                let runtimeClient = try await RuntimeClient.create(
                    id: id,
                    runtime: runtime
                )
                try await runtimeClient.bootstrap(stdio: stdio, networkBootstrapInfos: networkBootstrapInfos, dynamicEnv: dynamicEnv)

                try await self.exitMonitor.registerProcess(
                    id: id,
                    onExit: self.handleContainerExit
                )

                state.client = runtimeClient
                await self.setContainerState(id, state, context: context)
            } catch {
                let label = Self.fullLaunchdServiceLabel(
                    runtimeName: config.runtimeHandler,
                    instanceId: id
                )

                await self.exitMonitor.stopTracking(id: id)
                try? ServiceManager.deregister(fullServiceLabel: label)
                throw error
            }
        }
    }

    private func validateLoggingForStart(
        containerID: String,
        configuration: ContainerLogConfiguration
    ) async throws {
        guard !configuration.isLegacy else {
            return
        }
        do {
            let protectedOptions: [String: String]
            if let reference = configuration.resolved?.protectedOptionReference {
                let binding = try LoggingProtectedOptionsBinding(
                    containerID: containerID,
                    configuration: configuration
                )
                protectedOptions = try await loggingProtectedOptionsStore.load(
                    reference,
                    boundTo: binding
                )
            } else {
                protectedOptions = [:]
            }
            try ContainerLogStartValidator(
                catalog: BuiltinLogDriverDescriptors.current
            ).validate(
                configuration,
                authenticatedProtectedOptions: protectedOptions
            )
        } catch {
            throw Self.mapLoggingStartError(error)
        }
    }

    static func mapLoggingStartError(_ error: any Error) -> ContainerizationError {
        if let error = error as? ContainerLogStartValidationError {
            return ContainerizationError(
                .invalidState,
                message: "container logging configuration is not valid for start: \(error.description)"
            )
        }
        if let error = error as? ContainerLogResolutionError {
            return ContainerizationError(
                .invalidState,
                message: "container logging configuration is not valid for start: \(error.description)"
            )
        }
        if error is LoggingProtectedOptionsStoreError
            || error is LoggingProtectedOptionsBindingError
        {
            return ContainerizationError(
                .invalidState,
                message: "protected container logging options failed authentication"
            )
        }
        return ContainerizationError(
            .invalidState,
            message: "container logging configuration is not valid for start"
        )
    }

    /// Attach client standard streams to a running container's init process.
    public func attach(id: String, stdio: [FileHandle?]) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: ["func": "\(#function)", "id": "\(id)"]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: ["func": "\(#function)", "id": "\(id)"]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.attach(stdio: stdio)
    }

    /// Create a new process in the container.
    public func createProcess(
        id: String,
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "command": "\(config.arguments.isEmpty ? "" : config.arguments[0])",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.createProcess(
            processID,
            config: config,
            stdio: stdio
        )
        guard !Self.isInitProcess(id: id, processID: processID) else {
            return
        }

        await eventBroadcaster.publish(
            execEventTracker.create(
                snapshot: state.snapshot,
                processID: processID,
                configuration: config
            )
        )
    }

    /// Start a process in a container. This can either be a process created via
    /// createProcess, or the init process of the container which requires
    /// id == processID.
    public func startProcess(id: String, processID: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let restartPolicy = try getContainerCreationOptions(id: id).restartPolicy
        let execConfiguration = execEventTracker.configuration(containerID: id, processID: processID)
        let (startedSnapshot, startedExecProcess) = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)", "processId": "\(processID)"]) {
            context -> (ContainerSnapshot?, StartedExecProcess?) in
            var state = try await self.getContainerState(id: id, context: context)

            let isInit = Self.isInitProcess(id: id, processID: processID)
            if state.snapshot.status == .running && isInit {
                return (nil, nil)
            }

            let client = try state.getClient()
            try await client.startProcess(processID)

            guard isInit else {
                guard execConfiguration != nil else {
                    return (nil, nil)
                }
                return (
                    nil,
                    StartedExecProcess(
                        snapshot: state.snapshot,
                        processID: processID,
                        client: client
                    )
                )
            }

            do {
                let log = self.log
                let waitFunc: ExitMonitor.WaitHandler = {
                    log.info("registering container with exit monitor")
                    let code = try await client.wait(id)
                    log.info(
                        "container finished in exit monitor",
                        metadata: [
                            "id": "\(id)",
                            "rc": "\(code)",
                        ])

                    return code
                }
                try await self.exitMonitor.track(id: id, waitingOn: waitFunc)

                let sandboxSnapshot = try await client.state()
                let startedDate = Date()
                state.snapshot.status = .running
                state.snapshot.networks = sandboxSnapshot.networks
                state.snapshot.startedDate = startedDate
                state.snapshot.exitCode = nil
                state.snapshot.exitedDate = nil
                state.snapshot.health = state.snapshot.configuration.healthCheck == nil ? nil : .starting
                state.restart.markStarted()
                await self.setContainerState(id, state, context: context)
                await self.scheduleRestartStabilityReset(
                    id: id,
                    startedDate: startedDate,
                    durationInNanoseconds: ContainerRestartTracker.stableRunDuration(for: restartPolicy)
                )
                await self.startHealthCheckMonitor(
                    id: id,
                    healthCheck: state.snapshot.configuration.healthCheck,
                    client: client
                )
                return (state.snapshot, nil)
            } catch {
                await self.stopHealthCheckMonitor(id: id)
                await self.exitMonitor.stopTracking(id: id)
                try? await client.stop(options: ContainerStopOptions.default)
                throw error
            }
        }

        if let startedExecProcess {
            if let event = execEventTracker.start(
                snapshot: startedExecProcess.snapshot,
                processID: startedExecProcess.processID
            ) {
                await eventBroadcaster.publish(event)
            }
            scheduleExecExit(
                id: id,
                processID: startedExecProcess.processID,
                client: startedExecProcess.client
            )
        }

        if let startedSnapshot {
            await publishContainerEvent(action: "start", snapshot: startedSnapshot)
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, processID: String, signal: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "signal": "\(signal)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state: ContainerState
        if processID == id {
            state = try await self.markContainerManuallyStopped(id: id)
        } else {
            state = try self._getContainerState(id: id)
        }
        let client = try state.getClient()
        try await client.kill(processID, signal: signal)
        let parsedSignal = try? Signal(signal)
        await eventBroadcaster.publish(
            Self.killEvent(
                snapshot: state.snapshot,
                processID: processID,
                signal: parsedSignal?.rawValue,
                requestedSignal: signal
            )
        )

        // SIGKILL is guaranteed to terminate the target. When directed at the
        // container's init process, follow up with the same API-server cleanup
        // that `stop` performs.
        if processID == id, parsedSignal == .kill {
            try await handleContainerExit(id: id, code: ExitStatus(exitCode: 128 + Signal.kill.rawValue))
        }
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let currentState = try self._getContainerState(id: id)
        guard currentState.snapshot.status != .paused else {
            throw ContainerizationError(
                .invalidState,
                message: "container is paused; unpause the container before stopping"
            )
        }

        let state = try await self.markContainerManuallyStopped(id: id)

        // Stop should be idempotent.
        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            return
        }

        var resolvedOptions = options
        if resolvedOptions.signal == nil, let stopSignal = state.snapshot.configuration.stopSignal {
            resolvedOptions.signal = stopSignal
        }
        if resolvedOptions.timeoutInSeconds == nil {
            resolvedOptions.timeoutInSeconds = state.snapshot.configuration.stopTimeoutInSeconds
        }

        do {
            try await client.stop(options: resolvedOptions)
        } catch let err as ContainerizationError {
            if err.code != .interrupted {
                throw err
            }
        }
        try await handleContainerExit(id: id)
    }

    /// Pause a running container.
    public func pause(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let pausedSnapshot = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context -> ContainerSnapshot in
            var state = try await self.getContainerState(id: id, context: context)
            guard state.snapshot.status == .running else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container is not running"
                )
            }

            let client = try state.getClient()
            try await client.pause()

            await self.stopHealthCheckMonitor(id: id)
            state.snapshot.status = .paused
            await self.setContainerState(id, state, context: context)
            return state.snapshot
        }

        await publishContainerEvent(action: "pause", snapshot: pausedSnapshot)
    }

    /// Resume a paused container.
    public func unpause(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let unpausedSnapshot = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context -> ContainerSnapshot in
            var state = try await self.getContainerState(id: id, context: context)
            guard state.snapshot.status == .paused else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container is not paused"
                )
            }

            let client = try state.getClient()
            try await client.resume()

            state.snapshot.status = .running
            state.snapshot.health = state.snapshot.configuration.healthCheck == nil ? nil : .starting
            await self.setContainerState(id, state, context: context)
            await self.startHealthCheckMonitor(
                id: id,
                healthCheck: state.snapshot.configuration.healthCheck,
                client: client
            )
            return state.snapshot
        }

        await publishContainerEvent(action: "unpause", snapshot: unpausedSnapshot)
    }

    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "port": "\(port)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "port": "\(port)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.dial(port)
    }

    /// Wait waits for the container's init process or exec to exit and returns the
    /// exit status.
    public func wait(id: String, processID: String) async throws -> ExitStatus {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.wait(processID)
    }

    /// Resize resizes the container's PTY if one exists.
    public func resize(id: String, processID: String, size: Terminal.Size) async throws {
        log.trace(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.trace(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.resize(processID, size: size)
    }

    /// Get the logs for the container.
    public func logs(id: String) async throws -> [FileHandle] {
        try await logs(id: id, options: .default, replay: .default)
    }

    /// Get the logs for the container.
    public func logs(
        id: String,
        options: ContainerLogOptions = .default,
        replay: ContainerLogReplayOptions = .default
    ) async throws -> [FileHandle] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Logs doesn't care if the container is running or not, just that
        // the bundle is there, and that the files actually exist. We do
        // first try and get the container state so we get a nicer error message
        // (container foo not found) however.
        do {
            _ = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            let handles = [
                try Self.logHandle(for: bundle.containerLog, options: options, replay: replay),
                Self.applyLogOptions(to: try FileHandle(forReadingFrom: bundle.bootlog), options: options),
            ]
            return handles
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container logs: \(error)"
            )
        }
    }

    /// Follow raw stdio logs for the container.
    public func followLogs(
        id: String,
        options: ContainerLogOptions = .default
    ) async throws -> FileHandle {
        guard options.since == nil && options.until == nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "raw followed logs do not support time filters; use structured log records"
            )
        }

        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        do {
            _ = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            return try Self.followLogFile(for: bundle.containerLog, options: options)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to follow container logs: \(error)"
            )
        }
    }

    /// Get timestamped log records for the container.
    public func logRecords(
        id: String,
        options: ContainerLogOptions = .default,
        replay: ContainerLogReplayOptions = .default
    ) async throws -> [ContainerLogRecord] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        do {
            _ = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            let data = try Self.logData(from: Self.logReplayURLs(for: bundle.containerLogRecords, includeRotated: replay.includeRotated))
            return try Self.filteredLogRecords(data, options: options)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container log records: \(error)"
            )
        }
    }

    /// Get the timestamped log record file for the container.
    public func logRecordFile(id: String) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        do {
            _ = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            return try FileHandle(forReadingFrom: bundle.containerLogRecords)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container log record file: \(error)"
            )
        }
    }

    /// Follow timestamped log records for the container.
    public func followLogRecords(
        id: String,
        options: ContainerLogOptions = .default
    ) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        do {
            _ = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            return try Self.followLogRecordFile(
                for: bundle.containerLogRecords,
                options: options,
                isLive: { await self.isLiveForLogFollow(id: id) }
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to follow container log records: \(error)"
            )
        }
    }

    static func logHandle(
        for url: URL,
        options: ContainerLogOptions,
        replay: ContainerLogReplayOptions
    ) throws -> FileHandle {
        guard replay.includeRotated else {
            return Self.applyLogOptions(to: try FileHandle(forReadingFrom: url), options: options)
        }

        let urls = Self.logReplayURLs(for: url, includeRotated: true)
        let filtered =
            if let tail = options.tail, tail >= 0, options.since == nil, options.until == nil {
                try Self.tailLogData(from: urls, lineCount: tail)
            } else {
                try Self.filteredLogData(Self.logData(from: urls), options: options)
            }
        guard let replayHandle = Self.temporaryFileHandle(containing: filtered) else {
            return Self.applyLogOptions(to: try FileHandle(forReadingFrom: url), options: options)
        }
        return replayHandle
    }

    static func logReplayURLs(for url: URL, includeRotated: Bool) -> [URL] {
        guard includeRotated else {
            return [url]
        }
        return Self.rotatedLogURLs(for: url) + [url]
    }

    static func rotatedLogURLs(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent)."
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }

        return urls.compactMap { candidate -> (index: Int, url: URL)? in
            guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let name = candidate.lastPathComponent
            guard name.hasPrefix(prefix) else {
                return nil
            }
            let suffix = name.dropFirst(prefix.count)
            guard let index = Int(suffix), index > 0 else {
                return nil
            }
            return (index, candidate)
        }
        .sorted { left, right in
            left.index > right.index
        }
        .map { $0.url }
    }

    static func logData(from urls: [URL]) throws -> Data {
        var data = Data()
        for url in urls {
            data.append(try Data(contentsOf: url))
        }
        return data
    }

    static func tailLogData(from urls: [URL], lineCount: Int) throws -> Data {
        guard lineCount != 0 else {
            return Data()
        }
        guard lineCount > 0 else {
            return try logData(from: urls)
        }

        var buffer = TailLogBuffer()
        for url in urls.reversed() {
            guard buffer.lineCount <= lineCount else {
                break
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            try appendTailData(from: handle, lineCount: lineCount, into: &buffer)
        }
        return filteredLogData(buffer.data, options: ContainerLogOptions(tail: lineCount))
    }

    private static func tailLogData(from handle: FileHandle, lineCount: Int) throws -> Data {
        guard lineCount != 0 else {
            return Data()
        }
        guard lineCount > 0 else {
            try handle.seek(toOffset: 0)
            return handle.readDataToEndOfFile()
        }

        var buffer = TailLogBuffer()
        try appendTailData(from: handle, lineCount: lineCount, into: &buffer)
        return filteredLogData(buffer.data, options: ContainerLogOptions(tail: lineCount))
    }

    private static func appendTailData(
        from handle: FileHandle,
        lineCount: Int,
        into buffer: inout TailLogBuffer
    ) throws {
        var offset = try handle.seekToEnd()
        while offset > 0, buffer.lineCount <= lineCount {
            let readSize = min(logTailReadChunkSize, offset)
            offset -= readSize
            try handle.seek(toOffset: offset)
            buffer.appendReverseChunk(handle.readData(ofLength: Int(readSize)))
        }
    }

    private struct TailLogBuffer {
        private var reverseChunks: [Data] = []
        private var lineFeedCount = 0
        private var newestByte: UInt8?

        var data: Data {
            var result = Data()
            for chunk in reverseChunks.reversed() {
                result.append(chunk)
            }
            return result
        }

        var lineCount: Int {
            guard let newestByte else {
                return 0
            }
            return newestByte == LogByte.lineFeed ? lineFeedCount : lineFeedCount + 1
        }

        mutating func appendReverseChunk(_ chunk: Data) {
            guard !chunk.isEmpty else {
                return
            }
            if newestByte == nil {
                newestByte = chunk.last
            }
            lineFeedCount += chunk.reduce(0) { count, byte in
                byte == LogByte.lineFeed ? count + 1 : count
            }
            reverseChunks.append(chunk)
        }
    }

    static func applyLogOptions(to handle: FileHandle, options: ContainerLogOptions) -> FileHandle {
        guard options.tail != nil || options.since != nil || options.until != nil else {
            return handle
        }
        if let tail = options.tail, options.since == nil, options.until == nil {
            guard tail >= 0 else {
                return handle
            }

            do {
                let data = try Self.tailLogData(from: handle, lineCount: tail)
                guard let filteredHandle = Self.temporaryFileHandle(containing: data) else {
                    try? handle.seek(toOffset: 0)
                    return handle
                }
                try? handle.close()
                return filteredHandle
            } catch {
                try? handle.seek(toOffset: 0)
                return handle
            }
        }
        guard let data = try? handle.readToEnd() else {
            return handle
        }
        let filtered = Self.filteredLogData(data, options: options)
        guard let filteredHandle = Self.temporaryFileHandle(containing: filtered) else {
            try? handle.seek(toOffset: 0)
            return handle
        }
        try? handle.close()
        return filteredHandle
    }

    static func filteredLogData(_ data: Data, options: ContainerLogOptions) -> Data {
        guard !data.isEmpty else {
            return Data()
        }
        let appliesTail = options.tail.map { $0 >= 0 } ?? false
        guard appliesTail || options.since != nil || options.until != nil else {
            return data
        }

        var lines = logDataLines(data)

        let timestampParser = LogTimestampParser()
        lines = lines.filter { line in
            guard let timestamp = timestampParser.timestampPrefix(from: line.data) else {
                return true
            }
            if let since = options.since, timestamp < since {
                return false
            }
            if let until = options.until, timestamp > until {
                return false
            }
            return true
        }

        if let tail = options.tail, tail >= 0 {
            if tail == 0 {
                return Data()
            }
            lines = Array(lines.suffix(tail))
        }

        return joinedLogData(lines)
    }

    static func filteredLogRecords(_ data: Data, options: ContainerLogOptions) throws -> [ContainerLogRecord] {
        guard !data.isEmpty else {
            return []
        }
        let records = try decodedLogRecords(data)
        return filteredLogRecords(records, options: options)
    }

    static func filteredLogRecords(_ records: [ContainerLogRecord], options: ContainerLogOptions) -> [ContainerLogRecord] {
        let appliesTail = options.tail.map { $0 >= 0 } ?? false
        guard appliesTail || options.since != nil || options.until != nil else {
            return records
        }
        if options.tail == 0 {
            return []
        }

        var accumulator = StructuredLogLineAccumulator()
        var lines = records.flatMap { accumulator.append($0) }
        if let line = accumulator.flush() {
            lines.append(line)
        }

        lines = lines.filter { line in
            if let since = options.since, line.timestamp < since {
                return false
            }
            if let until = options.until, line.timestamp > until {
                return false
            }
            return true
        }

        if let tail = options.tail, tail >= 0 {
            lines = Array(lines.suffix(tail))
        }

        return lines.map(\.record)
    }

    private static func decodedLogRecords(_ data: Data) throws -> [ContainerLogRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: LogByte.lineFeed).map { line in
            try decoder.decode(ContainerLogRecord.self, from: Data(line))
        }
    }

    private static func temporaryFileHandle(containing data: Data) -> FileHandle? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-\(UUID().uuidString)")
        do {
            try data.write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            try? FileManager.default.removeItem(at: url)
            return handle
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func logDataLines(_ data: Data) -> [LogDataLine] {
        var lines: [LogDataLine] = []
        var current = Data()

        for byte in data {
            if byte == LogByte.lineFeed {
                lines.append(LogDataLine(data: current, terminated: true))
                current.removeAll()
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            lines.append(LogDataLine(data: current, terminated: false))
        }
        return lines
    }

    private static func joinedLogData(_ lines: [LogDataLine]) -> Data {
        var result = Data()
        for (index, line) in lines.enumerated() {
            result.append(line.data)
            if line.terminated || index < lines.count - 1 {
                result.append(LogByte.lineFeed)
            }
        }
        return result
    }

    private struct LogDataLine {
        var data: Data
        var terminated: Bool
    }

    private struct StructuredLogLine {
        var timestamp: Date
        var stream: ContainerLogRecord.Stream
        var data: Data
        var terminated: Bool

        var record: ContainerLogRecord {
            var recordData = data
            if terminated {
                recordData.append(LogByte.lineFeed)
            }
            return ContainerLogRecord(timestamp: timestamp, stream: stream, data: recordData)
        }
    }

    private struct StructuredLogLineAccumulator {
        private var pending = Data()
        private var pendingTimestamp: Date?
        private var pendingStream: ContainerLogRecord.Stream?

        mutating func append(_ record: ContainerLogRecord) -> [StructuredLogLine] {
            guard !record.data.isEmpty else {
                return []
            }

            var lines: [StructuredLogLine] = []
            var index = record.data.startIndex
            while index < record.data.endIndex {
                let byte = record.data[index]
                if byte == LogByte.lineFeed {
                    lines.append(completeLine(record: record, terminated: true))
                    index = record.data.index(after: index)
                } else {
                    if pendingTimestamp == nil {
                        pendingTimestamp = record.timestamp
                        pendingStream = record.stream
                    }
                    pending.append(byte)
                    index = record.data.index(after: index)
                }
            }
            return lines
        }

        mutating func flush() -> StructuredLogLine? {
            guard !pending.isEmpty,
                let timestamp = pendingTimestamp,
                let stream = pendingStream
            else {
                return nil
            }
            let line = StructuredLogLine(timestamp: timestamp, stream: stream, data: pending, terminated: false)
            pending.removeAll()
            pendingTimestamp = nil
            pendingStream = nil
            return line
        }

        private mutating func completeLine(record: ContainerLogRecord, terminated: Bool) -> StructuredLogLine {
            let line = StructuredLogLine(
                timestamp: pendingTimestamp ?? record.timestamp,
                stream: pendingStream ?? record.stream,
                data: pending,
                terminated: terminated
            )
            pending.removeAll()
            pendingTimestamp = nil
            pendingStream = nil
            return line
        }
    }

    private struct LogTimestampParser {
        private let fractionalFormatter: ISO8601DateFormatter
        private let formatter: ISO8601DateFormatter

        init() {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractionalFormatter = fractionalFormatter

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            self.formatter = formatter
        }

        func timestampPrefix(from line: Data) -> Date? {
            let token = Data(line.prefix { $0 != UInt8(ascii: " ") })
            guard let timestamp = String(data: token, encoding: .utf8) else {
                return nil
            }
            return timestampPrefix(fromTimestampToken: timestamp)
        }

        private func timestampPrefix(fromTimestampToken timestamp: String) -> Date? {
            if let date = fractionalFormatter.date(from: timestamp) {
                return date
            }

            return formatter.date(from: timestamp)
        }
    }

    private enum LogByte {
        static let lineFeed = UInt8(ascii: "\n")
    }

    /// Copy a file or directory from the host into the container.
    public func copyIn(id: String, source: String, destination: String, mode: UInt32, createParents: Bool = true, followSymlink: Bool = false, preserveOwnership: Bool = false)
        async throws
    {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyIn(
            source: source, destination: destination, mode: mode, createParents: createParents, followSymlink: followSymlink, preserveOwnership: preserveOwnership)
    }

    /// Stream a tar archive from the host into a container directory.
    public func copyIn(
        id: String,
        archive: FileHandle,
        destination: String,
        createParents: Bool = true,
        preserveOwnership: Bool = false
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyIn(
            archive: archive,
            destination: destination,
            createParents: createParents,
            preserveOwnership: preserveOwnership
        )
    }

    /// Copy a file or directory from the container to the host.
    public func copyOut(id: String, source: String, destination: String, createParents: Bool = true, followSymlink: Bool = false, preserveOwnership: Bool = false) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyOut(source: source, destination: destination, createParents: createParents, followSymlink: followSymlink, preserveOwnership: preserveOwnership)
    }

    /// Stream a container path to the host as an uncompressed tar archive.
    public func copyOut(
        id: String,
        source: String,
        archive: FileHandle,
        followSymlink: Bool = false,
        copyContents: Bool = false
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyOut(
            source: source,
            archive: archive,
            followSymlink: followSymlink,
            copyContents: copyContents
        )
    }

    /// Get statistics for the container.
    public func stats(id: String) async throws -> ContainerStats {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.statistics()
    }

    /// Get process information for the container.
    public func processes(id: String) async throws -> ContainerProcesses {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running || state.snapshot.status == .paused else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running or paused")
        }
        let client = try state.getClient()
        return try await client.processes()
    }

    /// Delete a container and its resources.
    public func delete(id: String, force: Bool) async throws {
        log.info(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "force": "\(force)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let events: [ContainerEvent]
        switch state.snapshot.status {
        case .running:
            if !force {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and can not be deleted"
                )
            }
            let opts = ContainerStopOptions(
                timeoutInSeconds: 5,
                signal: "SIGKILL"
            )
            let client = try state.getClient()
            try await client.stop(options: opts)
            events = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                self.log.info(
                    "ContainersService: attempt cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                try await self.cleanUp(id: id, context: context)
                self.log.info(
                    "ContainersService: successful cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                var stoppedSnapshot = state.snapshot
                stoppedSnapshot.status = .stopped
                stoppedSnapshot.networks = []
                stoppedSnapshot.health = nil
                stoppedSnapshot.exitCode = 128 + Signal.kill.rawValue
                stoppedSnapshot.exitedDate = .now
                return Self.terminalLifecycleEvents(snapshot: stoppedSnapshot)
                    + Self.removalEvents(snapshot: stoppedSnapshot)
            }
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is \(state.snapshot.status) and can not be deleted"
            )
        default:
            events = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                let current = try await self.getContainerState(id: id, context: context)
                switch current.snapshot.status {
                case .running, .stopping:
                    throw ContainerizationError(
                        .invalidState,
                        message: "container \(id) is \(current.snapshot.status) and can not be deleted"
                    )
                default:
                    break
                }
                try await self.cleanUp(id: id, context: context)
                return Self.removalEvents(snapshot: current.snapshot)
            }
        }

        for event in events {
            await eventBroadcaster.publish(event)
        }
    }

    public func containerDiskUsage(id: String) async throws -> UInt64 {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        try Utility.validEntityName(id)
        let containerPath = try Self.containerPath(root: self.containerRoot, id: id).path

        return FileManager.default.allocatedSize(of: URL(fileURLWithPath: containerPath))
    }

    /// Exports a root filesystem, optionally taking a running-container snapshot.
    ///
    /// `noFreeze` is meaningful only with `live`: it requests a best-effort
    /// APFS copy-on-write snapshot without freezing guest writes.
    public func exportRootfs(id: String, archive: URL, live: Bool = false, noFreeze: Bool = false) async throws {
        self.log.debug("\(#function)")

        try Utility.validEntityName(id)
        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .stopped || (live && state.snapshot.status == .running) else {
            throw ContainerizationError(.invalidState, message: "container is not stopped")
        }

        let path = try Self.containerPath(root: self.containerRoot, id: id)
        let bundle = ContainerResource.Bundle(path: path)
        let rootfs: URL
        if FileManager.default.fileExists(atPath: bundle.containerRootfsBlock.path) {
            rootfs = bundle.containerRootfsBlock
        } else {
            let filesystem: Filesystem
            do {
                filesystem = try bundle.containerRootfs
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
                guard
                    let configuredFilesystem = runtimeConfig.options?.rootFsOverride
                        ?? runtimeConfig.containerRootFilesystem
                else {
                    throw ContainerizationError(.notFound, message: "container root filesystem is not available")
                }
                filesystem = configuredFilesystem
            }
            rootfs = try Self.exportableRootfsURL(filesystem)
        }
        if live {
            let client = try state.getClient()
            let snapshot = FileManager.default.temporaryDirectory
                .appendingPathComponent("container-live-export-\(UUID().uuidString).ext4")
            defer {
                try? FileManager.default.removeItem(at: snapshot)
            }
            try await client.snapshotDisk(imagePath: rootfs.path, destinationPath: snapshot.path, noFreeze: noFreeze)
            try EXT4.EXT4Reader(blockDevice: FilePath(snapshot)).export(archive: FilePath(archive))
            return
        }
        try EXT4.EXT4Reader(blockDevice: FilePath(rootfs)).export(archive: FilePath(archive))
    }

    private static func exportableRootfsURL(_ filesystem: Filesystem) throws -> URL {
        switch filesystem.type {
        case .block(let format, _, _), .volume(_, let format, _, _):
            guard format == "ext4" else {
                throw ContainerizationError(.unsupported, message: "cannot export " + format + " container root filesystem")
            }
            return URL(fileURLWithPath: filesystem.source)
        default:
            throw ContainerizationError(.unsupported, message: "container root filesystem is not an ext4 block device")
        }
    }

    private func handleContainerExit(id: String, code: ExitStatus? = nil) async throws {
        let events = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { [self] context in
            try await handleContainerExit(id: id, code: code, context: context)
        }
        for event in events {
            await eventBroadcaster.publish(event)
        }
    }

    private func handleContainerExit(id: String, code: ExitStatus?, context: AsyncLock.Context) async throws -> [ContainerEvent] {
        if let code {
            self.log.info(
                "handling container exit",
                metadata: [
                    "id": "\(id)",
                    "rc": "\(code)",
                ])
        }

        var state: ContainerState
        do {
            state = try self.getContainerState(id: id, context: context)
            if state.snapshot.status == .stopped {
                return []
            }
        } catch {
            // Was auto removed by the background thread, nothing for us to do.
            return []
        }

        await self.exitMonitor.stopTracking(id: id)
        self.stopHealthCheckMonitor(id: id)

        // Shutdown and deregister the runtime service
        self.log.info("shutting down runtime service", metadata: ["id": "\(id)"])

        let path = try Self.containerPath(root: self.containerRoot, id: id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: config.runtimeHandler,
            instanceId: id
        )

        // Try to shutdown the client gracefully, but if the runtime service
        // is already dead (e.g., killed externally), we should still continue
        // with state cleanup.
        if let client = state.client {
            do {
                try await client.shutdown()
            } catch {
                self.log.error(
                    "failed to shutdown runtime service",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ])
            }
        }

        // Deregister the service, launchd will terminate the process.
        // This may also fail if the service was already deregistered or
        // the process was killed externally.
        do {
            try ServiceManager.deregister(fullServiceLabel: label)
            self.log.info("deregistered runtime service", metadata: ["id": "\(id)"])
        } catch {
            self.log.error(
                "failed to deregister runtime service",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        state.snapshot.status = .stopped
        state.snapshot.networks = []
        state.snapshot.health = nil
        if let code {
            state.snapshot.exitCode = code.exitCode
            state.snapshot.exitedDate = code.exitedAt
        }
        state.client = nil

        let options = try getContainerCreationOptions(id: id)
        let terminalEvents = Self.terminalLifecycleEvents(snapshot: state.snapshot)
        if options.autoRemove {
            await self.setContainerState(id, state, context: context)
            try await self.cleanUp(id: id, context: context)
            return terminalEvents + Self.removalEvents(snapshot: state.snapshot)
        }

        let restartDelay = state.restart.restartDelay(
            policy: options.restartPolicy,
            exitCode: code?.exitCode
        )
        await self.setContainerState(id, state, context: context)
        if let restartDelay {
            self.scheduleRestart(id: id, delayInNanoseconds: restartDelay)
        }
        return terminalEvents
    }

    private static func fullLaunchdServiceLabel(runtimeName: String, instanceId: String) -> String {
        "\(Self.launchdDomainString)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    /// Returns Docker's terminal event before the existing generic stop event.
    static func terminalLifecycleEvents(snapshot: ContainerSnapshot) -> [ContainerEvent] {
        var exitAttributes = [String: String]()
        if let exitCode = snapshot.exitCode {
            exitAttributes["exitCode"] = "\(exitCode)"
        }
        return [
            containerEvent(action: "die", snapshot: snapshot, additionalAttributes: exitAttributes),
            containerEvent(action: "stop", snapshot: snapshot),
        ]
    }

    /// Returns the generic deletion event and Docker's matching destroy event.
    static func removalEvents(snapshot: ContainerSnapshot) -> [ContainerEvent] {
        [
            containerEvent(action: "delete", snapshot: snapshot),
            containerEvent(action: "destroy", snapshot: snapshot),
        ]
    }

    /// Describes a signal delivered through the generic container API.
    static func killEvent(
        snapshot: ContainerSnapshot,
        processID: String,
        signal: Int32?,
        requestedSignal: String
    ) -> ContainerEvent {
        var attributes = ["process": processID]
        attributes["signal"] = signal.map(String.init) ?? requestedSignal
        return containerEvent(action: "kill", snapshot: snapshot, additionalAttributes: attributes)
    }

    private static func containerEvent(
        action: String,
        snapshot: ContainerSnapshot,
        additionalAttributes: [String: String] = [:]
    ) -> ContainerEvent {
        var attributes = snapshot.configuration.labels
        attributes["image"] = snapshot.configuration.image.reference
        attributes["status"] = snapshot.status.rawValue
        attributes["health"] = snapshot.health?.rawValue
        attributes.merge(additionalAttributes) { _, additional in additional }
        return ContainerEvent(
            type: "container",
            id: snapshot.id,
            action: action,
            attributes: attributes
        )
    }

    private func publishContainerEvent(action: String, snapshot: ContainerSnapshot) async {
        await eventBroadcaster.publish(Self.containerEvent(action: action, snapshot: snapshot))
    }

    private func _cleanUp(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Did the exit container handler win?
        if self.containers[id] == nil {
            return
        }

        // To be pedantic. This is only needed if something in the "launch
        // the init process" lifecycle fails before actually fork+exec'ing
        // the OCI runtime.
        await self.exitMonitor.stopTracking(id: id)
        let path = try Self.containerPath(root: self.containerRoot, id: id)

        // Try to get config for service deregistration and protected logging
        // cleanup. Runtime configuration is the durable source before the
        // runtime has materialized a full bundle.
        var config: ContainerConfiguration?
        let bundle = ContainerResource.Bundle(path: path)
        do {
            config = try Self.getContainerConfiguration(at: path).0
        } catch {
            self.log.warning(
                "failed to read bundle configuration during cleanup for container",
                metadata: [
                    "id": "\(id)"
                ])
        }

        // Only try to deregister service if we have a valid config
        // TODO: Change this so we don't have to reread the config
        // possibly store the container ID to service label mapping
        if let config = config {
            let label = Self.fullLaunchdServiceLabel(
                runtimeName: config.runtimeHandler,
                instanceId: id
            )
            try? ServiceManager.deregister(fullServiceLabel: label)
        }

        let protectedCleanup:
            (
                reference: LoggingProtectedOptionsReference,
                binding: LoggingProtectedOptionsBinding
            )?
        if let logging = config?.logging,
            let reference = logging.resolved?.protectedOptionReference,
            let binding = try? LoggingProtectedOptionsBinding(
                containerID: id,
                configuration: logging
            )
        {
            protectedCleanup = (reference, binding)
        } else {
            protectedCleanup = nil
        }

        // The durable bundle must disappear before its protected child. If
        // deletion fails, keep both the in-memory state and protected object so
        // a retry sees the same stopped container configuration.
        do {
            try bundle.delete()
        } catch {
            self.log.warning(
                "failed to delete bundle for container",
                metadata: [
                    "id": "\(id)"
                ])
            throw error
        }

        self.containers.removeValue(forKey: id)

        guard let protectedCleanup else {
            return
        }
        do {
            try await loggingProtectedOptionsStore.delete(
                protectedCleanup.reference,
                boundTo: protectedCleanup.binding
            )
        } catch {
            self.log.warning(
                "protected logging options remain queued for orphan reconciliation",
                metadata: ["id": "\(id)"]
            )
            guard
                let retainedObjectIDs = Self.loggingProtectedObjectIDsAtBoot(
                    root: containerRoot,
                    log: log
                )
            else {
                return
            }
            do {
                try await loggingProtectedOptionsStore.reconcile(
                    retainingObjectIDs: retainedObjectIDs
                )
            } catch {
                self.log.warning(
                    "protected logging orphan reconciliation will retry at authority boot",
                    metadata: ["id": "\(id)"]
                )
            }
        }
    }

    private func cleanUp(id: String, context: AsyncLock.Context) async throws {
        self.stopHealthCheckMonitor(id: id)
        self.cancelRestartTasks(id: id)
        self.cancelExecTasks(id: id)
        try await self._cleanUp(id: id)
    }

    private func getContainerCreationOptions(id: String) throws -> ContainerCreateOptions {
        let path = try Self.containerPath(root: self.containerRoot, id: id)
        let bundle = ContainerResource.Bundle(path: path)
        let options: ContainerCreateOptions = try bundle.load(filename: "options.json")
        return options
    }

    static func containerPath(root: URL, id: String) throws -> URL {
        guard let component = FilePath.Component(id), case .regular = component.kind else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container ID \(id) is not a valid path component"
            )
        }
        return root.appendingPathComponent(component.string, isDirectory: true)
    }

    private func getInitBlock(for platform: Platform, imageRef: String? = nil) async throws -> Filesystem {
        let ref = imageRef ?? containerSystemConfig.vminit.image
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform, containerSystemConfig: containerSystemConfig)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL,
        debug: Bool
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", configuration.id,
            debug ? "--debug" : nil,
        ].compactMap { $0 }
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: path,
            args: args,
            instanceId: configuration.id
        )
    }

    private func setContainerState(_ id: String, _ state: ContainerState, context: AsyncLock.Context) async {
        self.containers[id] = state
    }

    private func startHealthCheckMonitor(
        id: String,
        healthCheck: ContainerHealthCheck?,
        client: RuntimeClient
    ) async {
        self.stopHealthCheckMonitor(id: id)
        guard let healthCheck else {
            return
        }

        healthCheckTasks[id] = Task {
            await self.runHealthCheckMonitor(
                id: id,
                healthCheck: healthCheck,
                client: client
            )
        }
    }

    private func stopHealthCheckMonitor(id: String) {
        healthCheckTasks[id]?.cancel()
        healthCheckTasks.removeValue(forKey: id)
    }

    private func markContainerManuallyStopped(id: String) async throws -> ContainerState {
        cancelRestartTasks(id: id)
        return try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self.getContainerState(id: id, context: context)
            state.restart.markManuallyStopped()
            await self.setContainerState(id, state, context: context)
            return state
        }
    }

    private func cancelRestartTasks(id: String) {
        restartTasks[id]?.cancel()
        restartTasks.removeValue(forKey: id)
        restartTaskTokens.removeValue(forKey: id)
        restartStabilityTasks[id]?.cancel()
        restartStabilityTasks.removeValue(forKey: id)
        restartStabilityTaskTokens.removeValue(forKey: id)
    }

    /// Cancels detached exec observers and drops their transient event state with the container.
    private func cancelExecTasks(id: String) {
        if let tasks = execExitTasks[id] {
            for task in tasks.values {
                task.cancel()
            }
        }
        execExitTasks.removeValue(forKey: id)
        execEventTracker.removeContainer(id: id)
    }

    /// Begins observing one started exec process so detached commands also emit `exec_die`.
    private func scheduleExecExit(id: String, processID: String, client: RuntimeClient) {
        execExitTasks[id]?[processID]?.cancel()
        execExitTasks[id, default: [:]][processID] = Task { [weak self] in
            do {
                let status = try await client.wait(processID)
                guard !Task.isCancelled else {
                    return
                }
                await self?.completeExecProcess(
                    id: id,
                    processID: processID,
                    exitCode: status.exitCode
                )
            } catch {
                // A stopped or removed container can invalidate its runtime client before its exec exits.
            }
        }
    }

    /// Publishes a terminal exec event exactly once, even when a caller is also waiting on the process.
    private func completeExecProcess(id: String, processID: String, exitCode: Int32) async {
        execExitTasks[id]?.removeValue(forKey: processID)
        guard let state = containers[id] else {
            execEventTracker.removeContainer(id: id)
            return
        }
        guard
            let event = execEventTracker.die(
                snapshot: state.snapshot,
                processID: processID,
                exitCode: exitCode
            )
        else {
            return
        }
        await eventBroadcaster.publish(event)
    }

    private func scheduleRestart(id: String, delayInNanoseconds: UInt64) {
        restartTasks[id]?.cancel()
        let token = UUID()
        restartTaskTokens[id] = token
        restartTasks[id] = Task {
            await self.runScheduledRestart(id: id, token: token, delayInNanoseconds: delayInNanoseconds)
        }
    }

    private func runScheduledRestart(id: String, token: UUID, delayInNanoseconds: UInt64) async {
        defer {
            if restartTaskTokens[id] == token {
                restartTasks.removeValue(forKey: id)
                restartTaskTokens.removeValue(forKey: id)
            }
        }

        do {
            try await Task.sleep(for: Self.duration(fromNanoseconds: delayInNanoseconds))
            try Task.checkCancellation()
            guard try await prepareContainerForRestart(id: id) else {
                return
            }
            try Task.checkCancellation()
            guard restartTaskTokens[id] == token else {
                return
            }
            try await bootstrap(id: id, stdio: [FileHandle?](repeating: nil, count: 3), dynamicEnv: [:])
            try await startProcess(id: id, processID: id)
        } catch is CancellationError {
            return
        } catch {
            await markContainerRestartFailed(id: id)
            log.error(
                "failed to restart container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }
    }

    private func prepareContainerForRestart(id: String) async throws -> Bool {
        try await lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            let state = try await self.getContainerState(id: id, context: context)
            guard state.snapshot.status == .stopped, state.restart.allowsAutomaticRestart else {
                return false
            }
            return true
        }
    }

    private func markContainerRestartFailed(id: String) async {
        await self.exitMonitor.stopTracking(id: id)
        self.stopHealthCheckMonitor(id: id)

        let cleanup = await lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context -> (RuntimeClient?, String?) in
            guard var state = try? await self.getContainerState(id: id, context: context) else {
                return (nil, nil)
            }

            let label = Self.fullLaunchdServiceLabel(
                runtimeName: state.snapshot.configuration.runtimeHandler,
                instanceId: id
            )
            let client = state.client

            state.snapshot.status = .stopped
            state.snapshot.networks = []
            state.snapshot.health = nil
            state.client = nil
            await self.setContainerState(id, state, context: context)
            return (client, label)
        }

        if let client = cleanup.0 {
            try? await client.stop(options: ContainerStopOptions.default)
        }
        if let label = cleanup.1 {
            try? ServiceManager.deregister(fullServiceLabel: label)
        }
    }

    private func scheduleRestartStabilityReset(
        id: String,
        startedDate: Date,
        durationInNanoseconds: UInt64
    ) {
        restartStabilityTasks[id]?.cancel()
        let token = UUID()
        restartStabilityTaskTokens[id] = token
        restartStabilityTasks[id] = Task {
            await self.runRestartStabilityReset(
                id: id,
                token: token,
                startedDate: startedDate,
                durationInNanoseconds: durationInNanoseconds
            )
        }
    }

    private func runRestartStabilityReset(
        id: String,
        token: UUID,
        startedDate: Date,
        durationInNanoseconds: UInt64
    ) async {
        defer {
            if restartStabilityTaskTokens[id] == token {
                restartStabilityTasks.removeValue(forKey: id)
                restartStabilityTaskTokens.removeValue(forKey: id)
            }
        }

        do {
            try await Task.sleep(for: Self.duration(fromNanoseconds: durationInNanoseconds))
        } catch {
            return
        }

        await lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            guard var state = try? await self.getContainerState(id: id, context: context),
                state.snapshot.status == .running,
                state.snapshot.startedDate == startedDate
            else {
                return
            }
            state.restart.markStable()
            await self.setContainerState(id, state, context: context)
        }
    }

    private func runHealthCheckMonitor(
        id: String,
        healthCheck: ContainerHealthCheck,
        client: RuntimeClient
    ) async {
        var tracker = ContainerHealthProbeTracker(retries: healthCheck.retries)
        let clock = ContinuousClock()
        let startedAt = clock.now

        while !Task.isCancelled {
            let startPeriod = Self.duration(fromNanoseconds: healthCheck.startPeriodInNanoseconds)
            let withinStartPeriod = startedAt.duration(to: clock.now) < startPeriod
            let delay = tracker.nextProbeDelay(
                healthCheck: healthCheck,
                withinStartPeriod: withinStartPeriod
            )
            do {
                try await Task.sleep(for: Self.duration(fromNanoseconds: delay))
            } catch {
                return
            }

            let probeWithinStartPeriod = startedAt.duration(to: clock.now) < startPeriod
            let exitCode = await runHealthProbe(id: id, healthCheck: healthCheck, client: client)
            let status = tracker.record(
                exitCode: exitCode,
                countsFailure: tracker.shouldCountFailure(withinStartPeriod: probeWithinStartPeriod)
            )
            let update = await updateHealthStatus(id: id, status: status)
            guard update.isRunning else {
                return
            }
            if let snapshot = update.transition {
                await publishContainerEvent(
                    action: "health_status: \(status.rawValue)",
                    snapshot: snapshot
                )
            }
        }
    }

    private func runHealthProbe(
        id: String,
        healthCheck: ContainerHealthCheck,
        client: RuntimeClient
    ) async -> Int32 {
        let processID = "\(id)-health-\(UUID().uuidString.lowercased())"
        do {
            try await client.createProcess(processID, config: healthCheck.process, stdio: [])
            try await client.startProcess(processID)
            let timeout =
                healthCheck.timeoutInNanoseconds == 0
                ? ContainerHealthCheck.defaultTimeoutInNanoseconds
                : healthCheck.timeoutInNanoseconds
            return try await waitForHealthProbe(
                processID: processID,
                timeout: Self.duration(fromNanoseconds: timeout),
                client: client
            )
        } catch {
            self.log.debug(
                "health probe failed",
                metadata: [
                    "id": "\(id)",
                    "processId": "\(processID)",
                    "error": "\(error)",
                ])
            return 1
        }
    }

    private func waitForHealthProbe(
        processID: String,
        timeout: Duration,
        client: RuntimeClient
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await client.wait(processID).exitCode
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    try? await client.kill(processID, signal: "SIGKILL")
                    return 137
                } catch {
                    return 137
                }
            }

            guard let exitCode = try await group.next() else {
                throw ContainerizationError(.internalError, message: "health probe did not return an exit code")
            }
            group.cancelAll()
            return exitCode
        }
    }

    private func updateHealthStatus(
        id: String,
        status: HealthStatus
    ) async -> (isRunning: Bool, transition: ContainerSnapshot?) {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            guard var state = try? await self.getContainerState(id: id, context: context), state.snapshot.status == .running else {
                return (false, nil)
            }
            let previousStatus = state.snapshot.health
            state.snapshot.health = status
            await self.setContainerState(id, state, context: context)
            return (true, previousStatus == status ? nil : state.snapshot)
        }
    }

    static func duration(fromNanoseconds nanoseconds: UInt64) -> Duration {
        .nanoseconds(Int64(clamping: nanoseconds))
    }

    private func getContainerState(id: String, context: AsyncLock.Context) throws -> ContainerState {
        try self._getContainerState(id: id)
    }

    private func _getContainerState(id: String) throws -> ContainerState {
        let state = self.containers[id]
        guard let state else {
            throw ContainerizationError(
                .notFound,
                message: "container with ID \(id) not found"
            )
        }
        return state
    }

    private func isLiveForLogFollow(id: String) -> Bool {
        guard let state = try? _getContainerState(id: id) else {
            return false
        }
        return state.snapshot.status == .running || state.snapshot.status == .stopping
    }

    private static func isInitProcess(id: String, processID: String) -> Bool {
        id == processID
    }

    /// Get container configuration, either from existing bundle or from RuntimeConfiguration
    private static func getContainerConfiguration(at path: URL) throws -> (ContainerConfiguration, ContainerCreateOptions?) {
        let bundle = ContainerResource.Bundle(path: path)
        do {
            let config = try bundle.configuration
            let options: ContainerCreateOptions? = try? bundle.load(filename: "options.json")
            return (config, options)
        } catch {
            // Bundle doesn't exist or incomplete, try runtime configuration
            // This handles containers that were created but not started yet
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            guard let config = runtimeConfig.containerConfiguration else {
                throw ContainerizationError(.internalError, message: "runtime configuration missing container configuration")
            }
            return (config, runtimeConfig.options)
        }
    }
}

extension XPCMessage {
    func signal() throws -> String {
        guard let signal = self.string(key: .signal) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: .stopOptions) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: .snapshot, value: data)
    }

    func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: .stdin) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: .stdout) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: .stderr) {
            handles[2] = stderr
        }
        return handles
    }

    func setFileHandle(_ handle: FileHandle) {
        self.set(key: .fd, value: handle)
    }

    func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: .processConfig) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }
}
