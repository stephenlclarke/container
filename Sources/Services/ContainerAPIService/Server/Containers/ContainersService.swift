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

import ArgumentParser
import CVersion
import ContainerAPIClient
import ContainerEngineLogging
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerLoggingStorage
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

struct ContainerCreationReservations: Sendable {
    private var reservations: [String: ContainerSnapshot] = [:]

    var snapshots: [ContainerSnapshot] {
        Array(reservations.values)
    }

    mutating func reserve(
        _ snapshot: ContainerSnapshot,
        existing: [ContainerSnapshot],
        reservedNames: Set<String>
    ) throws {
        guard reservations[snapshot.id] == nil, !existing.contains(where: { $0.id == snapshot.id }) else {
            throw ContainerizationError(
                .exists,
                message: "container already exists: \(snapshot.id)"
            )
        }

        let dockerName = snapshot.configuration.dockerName ?? snapshot.id
        let occupiedNames = Set(
            (existing + snapshots).flatMap { container in
                [
                    container.id,
                    container.configuration.dockerName,
                    container.configuration.dockerID,
                ].compactMap { $0 }
            }
        ).union(reservedNames)
        let requestedNames = [
            dockerName,
            snapshot.id,
            snapshot.configuration.dockerID,
        ].compactMap { $0 }
        if let conflictingName = requestedNames.first(where: occupiedNames.contains) {
            throw ContainerizationError(
                .exists,
                message: "container name already exists: \(conflictingName)"
            )
        }

        let conflictingHostnames = ContainersService.conflictingNetworkNames(
            existingAttachments: (existing + snapshots).map(\.configuration.networks),
            requestedAttachments: snapshot.configuration.networks
        )
        guard conflictingHostnames.isEmpty else {
            throw ContainerizationError(
                .exists,
                message: "hostname(s) already exist: \(conflictingHostnames)"
            )
        }

        reservations[snapshot.id] = snapshot
    }

    @discardableResult
    mutating func remove(_ id: String) -> ContainerSnapshot? {
        reservations.removeValue(forKey: id)
    }
}

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

    private struct LoggingProviderMigrationSource: Sendable {
        let containerID: String
        let configuration: ContainerConfiguration
        let protectedOptions: [String: String]
    }

    private struct PreparedLoggingProviderMigration: Sendable {
        let source: LoggingProviderMigrationSource
        let historyReceipt: LogDriverHistoryMigrationReceiptV1?
    }

    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: RuntimeClient? = nil
        var restart = ContainerRestartTracker()
        var dockerStateError = ""
        /// Distinguishes a container from a later replacement that reuses its ID.
        /// Copies retain the generation so delayed commits can be fenced safely.
        let generation = UUID()

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

    private struct ContainerBootstrapPlan {
        let containerGeneration: UUID
        let operationGeneration: UInt64
        let path: URL
        let configuration: ContainerConfiguration
    }

    private struct ContainerBootstrapTimings {
        private let startedAt = ProcessInfo.processInfo.systemUptime
        private var phaseStartedAt = ProcessInfo.processInfo.systemUptime
        private var phases: [(String, Int64)] = []

        mutating func finish(_ phase: String) {
            let now = ProcessInfo.processInfo.systemUptime
            phases.append((phase, Int64((now - phaseStartedAt) * 1_000_000)))
            phaseStartedAt = now
        }

        mutating func finish(_ measuredPhases: [(String, Int64)]) {
            phases.append(contentsOf: measuredPhases)
            phaseStartedAt = ProcessInfo.processInfo.systemUptime
        }

        func metadata(id: String, outcome: String) -> Logger.Metadata {
            let phaseSummary = phases.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            let totalMicroseconds = Int64(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000
            )
            return [
                "id": "\(id)",
                "outcome": "\(outcome)",
                "phase-duration-us": "\(phaseSummary)",
                "total-duration-us": "\(totalMicroseconds)",
            ]
        }
    }

    private struct DockerContainerWaiter {
        let condition: DockerContainerWaitCondition
        let continuation: CheckedContinuation<DockerContainerWaitResult, any Error>
    }

    enum DockerContainerWaitCompletion {
        case exited
        case removed
    }

    private struct StartedExecProcess {
        let snapshot: ContainerSnapshot
        let processID: String
        let client: RuntimeClient
    }

    private struct StartedInitProcess {
        let snapshot: ContainerSnapshot
        let lifecycle: ContainerResource.ContainerLifecycleRecordV2
    }

    private static var machServicePrefix: String {
        ContainerServiceNamespace.current.value
    }
    private static let launchdDomainString = try! ServiceManager.getDomainString()
    private static let logTailReadChunkSize = UInt64(32 * 1024)
    static let loggingProtectedOptionsDirectoryName = "logging-protected-options"
    private static let loggingLeaseGeneration: UInt64 = 1
    private static let bootServiceDeregistrationAttempts = 3
    // A 50-VM release diagnostic on an 18-core host found a sharp VZ/guest
    // setup contention cliff after the fifteenth simultaneous bootstrap.
    // Lower-core hosts remain bounded by their available processor count.
    private static let maximumConcurrentRuntimeBootstraps = 15
    private static let runtimeBootstrapLimiter = RuntimeBootstrapLimiter(
        limit: min(
            maximumConcurrentRuntimeBootstraps,
            max(1, ProcessInfo.processInfo.activeProcessorCount)
        )
    )

    private let log: Logger
    private let debugHelpers: Bool
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor
    private let eventBroadcaster: ContainerEventBroadcaster
    private let containerSystemConfig: ContainerSystemConfig
    private let logDriverCatalogProvider: any LogDriverCatalogProviding
    private let remoteLogDriverPlane: AuthorityRemoteLogDriverPlane?
    private let loggingProtectedOptionsStore: LoggingProtectedOptionsStore

    private let lock: AsyncLock
    private var containers: [String: ContainerState]
    private var pendingCreations = ContainerCreationReservations()
    private var lifecycleRecords: [String: ContainerResource.ContainerLifecycleRecordV2]
    private let quarantinedContainerNames: Set<String>
    private var runtimeClientTokens: [String: UUID] = [:]
    private var explicitExitCauses: [String: ExplicitExitCause] = [:]
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]
    private var restartTasks: [String: Task<Void, Never>] = [:]
    private var restartTaskTokens: [String: UUID] = [:]
    private var restartStabilityTasks: [String: Task<Void, Never>] = [:]
    private var restartStabilityTaskTokens: [String: UUID] = [:]
    private var exitPersistenceRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var exitPersistenceRecoveries: [String: ExitPersistenceRecovery] = [:]
    private var execEventTracker = ContainerExecEventTracker()
    private var execExitTasks: [String: [String: Task<Void, Never>]] = [:]
    private var dockerContainerWaiters: [String: [UUID: DockerContainerWaiter]] = [:]
    private var lifecycleMutationsInFlight: Set<String> = []
    private var lifecycleMutationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    enum ExplicitExitCause: Equatable {
        case stop
        case kill
        case restart
    }

    private enum ExitPersistenceRecoveryAction: Sendable {
        case none
        case restart(delayInNanoseconds: UInt64)
        case remove
    }

    private struct ExitPersistenceRecovery: Sendable {
        let token: UUID
        var expectedOperationGeneration: UInt64
        let terminalPublicState: ContainerResource.ContainerPublicStateV2
        let incrementRestartCount: Bool
        let observedOOMKillCount: UInt64?
        let manualRestartSuppressed: Bool
        let terminalError: String?
        let action: ExitPersistenceRecoveryAction
        var terminalPersisted = false
        var removalLifecycle: ContainerResource.ContainerLifecycleRecordV2?
    }

    /// Serializes lifecycle mutations per container. Composite operations call
    /// their private implementation methods while holding this slot instead of
    /// relying on task-local reentrancy, which unstructured child tasks inherit.
    private func withLifecycleMutation<T>(
        id: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        await acquireLifecycleMutation(id: id)
        defer { releaseLifecycleMutation(id: id) }
        return try await operation()
    }

    private func acquireLifecycleMutation(id: String) async {
        guard !lifecycleMutationsInFlight.insert(id).inserted else {
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleMutationWaiters[id, default: []].append(continuation)
        }
    }

    private func releaseLifecycleMutation(id: String) {
        guard var waiters = lifecycleMutationWaiters[id], !waiters.isEmpty else {
            lifecycleMutationWaiters.removeValue(forKey: id)
            lifecycleMutationsInFlight.remove(id)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            lifecycleMutationWaiters.removeValue(forKey: id)
        } else {
            lifecycleMutationWaiters[id] = waiters
        }
        next.resume()
    }

    // FIXME: Find a better mechanism for services running on the APIServer to work with each other
    private weak var networksService: NetworksService?

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        debugHelpers: Bool = false,
        logDriverCatalogProvider: any LogDriverCatalogProviding = StaticLogDriverCatalogProvider(
            catalog: BuiltinLogDriverDescriptors.current
        ),
        remoteLogDriverPlane: AuthorityRemoteLogDriverPlane? = nil
    ) throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        let loadedContainers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
        let lifecycleRecords = Self.loadLifecycleRecords(
            containers: loadedContainers,
            root: containerRoot,
            log: log
        )
        var containers = loadedContainers.filter { lifecycleRecords[$0.key] != nil }
        for (id, record) in lifecycleRecords {
            guard var state = containers[id] else {
                continue
            }
            let recoveredFailureCount =
                record.snapshot.restartConsecutiveFailureCount
                ?? (record.snapshot.state == .restarting
                    && !record.intent.manualRestartSuppressed ? 1 : 0)
            state.restart = ContainerRestartTracker(
                restoringConsecutiveFailureCount: recoveredFailureCount
            )
            containers[id] = state
        }
        let quarantinedContainerNames = try Self.quarantinedContainerNamesAtBoot(
            root: containerRoot,
            acceptedContainerIDs: Set(containers.keys)
        )
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
        self.logDriverCatalogProvider =
            remoteLogDriverPlane
            ?? logDriverCatalogProvider
        self.remoteLogDriverPlane = remoteLogDriverPlane
        self.log = log
        self.debugHelpers = debugHelpers
        self.eventBroadcaster = ContainerEventBroadcaster()
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.loggingProtectedOptionsStore = loggingProtectedOptionsStore
        self.containers = containers
        self.lifecycleRecords = lifecycleRecords
        self.quarantinedContainerNames = quarantinedContainerNames
    }

    /// Completes every ready provider-generation transition before API routes
    /// become reachable. Quiescence is durable in the provider registry;
    /// partial configuration publication therefore resumes forward after an
    /// authority restart and can never make source and target both admit new
    /// effects.
    package func reconcileLoggingProviderUpgrades(
        afterPublishingContainer: (@Sendable (String) async throws -> Void)? = nil
    ) async throws {
        guard let remoteLogDriverPlane else {
            return
        }
        while let candidate =
            try await remoteLogDriverPlane
            .providerUpgradeCandidates().first
        {
            try await reconcileLoggingProviderUpgrade(
                candidate,
                plane: remoteLogDriverPlane,
                afterPublishingContainer: afterPublishingContainer
            )
        }
        while let candidate =
            try await remoteLogDriverPlane
            .providerReclamationCandidates().first
        {
            guard
                !containers.values.contains(where: {
                    $0.snapshot.configuration.logging.resolved?
                        .providerIdentity.id == candidate.providerID
                        && $0.snapshot.configuration.logging.resolved?
                            .providerGenerationAtResolution
                            == candidate.generation
                })
            else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "draining logging provider generation remains referenced by durable configuration"
                )
            }
            try await remoteLogDriverPlane.reclaimProviderGeneration(
                candidate
            )
        }
    }

    private func reconcileLoggingProviderUpgrade(
        _ candidate: AuthorityRemoteLogDriverUpgradeCandidate,
        plane: AuthorityRemoteLogDriverPlane,
        afterPublishingContainer: (@Sendable (String) async throws -> Void)?
    ) async throws {
        try await plane.beginProviderUpgrade(candidate)
        var forwardOnly = false
        do {
            var sources = [LoggingProviderMigrationSource]()
            for containerID in containers.keys.sorted() {
                guard
                    let state = containers[containerID],
                    let resolved = state.snapshot.configuration.logging.resolved,
                    resolved.providerIdentity.id == candidate.upgrade.providerID
                else {
                    continue
                }
                let bundle = ContainerResource.Bundle(
                    path: try Self.containerPath(
                        root: containerRoot,
                        id: containerID
                    )
                )
                switch resolved.providerGenerationAtResolution {
                case candidate.upgrade.sourceGeneration:
                    guard state.snapshot.status == .stopped, state.client == nil else {
                        throw ContainerizationError(
                            .invalidState,
                            message:
                                "logging provider generation \(candidate.upgrade.sourceGeneration) is still live for container \(containerID)"
                        )
                    }
                    try Self.validateLoggingProviderMigration(
                        configuration: state.snapshot.configuration.logging,
                        candidate: candidate
                    )
                    let protectedOptions = try await loadProtectedLoggingOptions(
                        containerID: containerID,
                        configuration: state.snapshot.configuration.logging
                    )
                    sources.append(
                        LoggingProviderMigrationSource(
                            containerID: containerID,
                            configuration: state.snapshot.configuration,
                            protectedOptions: protectedOptions
                        )
                    )
                case candidate.upgrade.targetGeneration:
                    forwardOnly = true
                    guard resolved.leaseGeneration > 1 else {
                        throw ContainerizationError(
                            .invalidState,
                            message: "migrated logging lease is missing its source generation"
                        )
                    }
                    _ = try await loadProtectedLoggingOptions(
                        containerID: containerID,
                        configuration: state.snapshot.configuration.logging
                    )
                    let proof = try await plane.verifyProviderGenerationTerminal(
                        candidate: candidate,
                        containerID: containerID,
                        bundle: bundle,
                        targetConfiguration: state.snapshot.configuration,
                        sourceLeaseGeneration: resolved.leaseGeneration - 1
                    )
                    try await plane.verifyProviderHistoryMigration(
                        candidate: candidate,
                        containerID: containerID,
                        targetConfiguration: state.snapshot.configuration.logging,
                        proof: proof
                    )
                default:
                    throw ContainerizationError(
                        .invalidState,
                        message:
                            "logging provider update found an unexpected durable generation for container \(containerID)"
                    )
                }
            }

            var preparedSources = [PreparedLoggingProviderMigration]()
            preparedSources.reserveCapacity(sources.count)
            for source in sources {
                let bundle = ContainerResource.Bundle(
                    path: try Self.containerPath(
                        root: containerRoot,
                        id: source.containerID
                    )
                )
                let proof = try await plane.proveProviderGenerationTerminal(
                    candidate: candidate,
                    containerID: source.containerID,
                    bundle: bundle,
                    configuration: source.configuration,
                    authenticatedProtectedOptions: source.protectedOptions
                )
                let historyReceipt = try await plane.migrateProviderHistory(
                    candidate: candidate,
                    containerID: source.containerID,
                    sourceConfiguration: source.configuration.logging,
                    proof: proof
                )
                preparedSources.append(
                    PreparedLoggingProviderMigration(
                        source: source,
                        historyReceipt: historyReceipt
                    )
                )
            }

            for prepared in preparedSources {
                try await migrateLoggingConfiguration(
                    prepared.source,
                    to: candidate.targetDescriptor,
                    historyReceipt: prepared.historyReceipt
                )
                forwardOnly = true
                try await afterPublishingContainer?(
                    prepared.source.containerID
                )
            }

            try await plane.activateProviderUpgrade(candidate)
            guard
                !containers.values.contains(where: {
                    $0.snapshot.configuration.logging.resolved?
                        .providerIdentity.id == candidate.upgrade.providerID
                        && $0.snapshot.configuration.logging.resolved?
                            .providerGenerationAtResolution
                            == candidate.upgrade.sourceGeneration
                })
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "source logging provider generation remains referenced after migration"
                )
            }
            try await plane.reclaimProviderGeneration(candidate)
        } catch {
            if !forwardOnly {
                try? await plane.cancelProviderUpgrade(candidate)
            }
            throw error
        }
    }

    private func loadProtectedLoggingOptions(
        containerID: String,
        configuration: ContainerLogConfiguration
    ) async throws -> [String: String] {
        guard let resolved = configuration.resolved else {
            throw ContainerizationError(
                .invalidState,
                message: "logging provider migration requires resolved configuration"
            )
        }
        guard let reference = resolved.protectedOptionReference else {
            guard resolved.protectedOptionNames.isEmpty else {
                throw ContainerizationError(
                    .invalidState,
                    message: "logging provider migration is missing protected options"
                )
            }
            return [:]
        }
        let binding = try LoggingProtectedOptionsBinding(
            containerID: containerID,
            configuration: configuration
        )
        let options = try await loggingProtectedOptionsStore.load(
            reference,
            boundTo: binding
        )
        guard options.keys.sorted() == resolved.protectedOptionNames.sorted() else {
            throw ContainerizationError(
                .invalidState,
                message: "logging provider migration found a protected option mismatch"
            )
        }
        return options
    }

    private static func validateLoggingProviderMigration(
        configuration: ContainerLogConfiguration,
        candidate: AuthorityRemoteLogDriverUpgradeCandidate
    ) throws {
        guard
            let resolved = configuration.resolved,
            resolved.driver == candidate.sourceDescriptor.driver,
            resolved.driver == candidate.targetDescriptor.driver,
            resolved.providerIdentity == candidate.sourceDescriptor.providerIdentity,
            resolved.providerIdentity == candidate.targetDescriptor.providerIdentity,
            resolved.providerGenerationAtResolution
                == candidate.upgrade.sourceGeneration,
            candidate.sourceDescriptor.providerGeneration
                == candidate.upgrade.sourceGeneration,
            candidate.targetDescriptor.providerGeneration
                == candidate.upgrade.targetGeneration,
            resolved.contractDigest
                == candidate.sourceDescriptor.optionContractDigest,
            resolved.contractDigest
                == candidate.targetDescriptor.optionContractDigest
        else {
            throw ContainerizationError(
                .invalidState,
                message: "logging provider generation has an incompatible frozen contract"
            )
        }
    }

    private func migrateLoggingConfiguration(
        _ source: LoggingProviderMigrationSource,
        to targetDescriptor: LogDriverDescriptor,
        historyReceipt: LogDriverHistoryMigrationReceiptV1?
    ) async throws {
        guard
            let requested = source.configuration.logging.requested,
            let resolved = source.configuration.logging.resolved,
            resolved.leaseGeneration < UInt64.max
        else {
            throw ContainerizationError(
                .invalidState,
                message: "logging provider migration cannot advance the lease"
            )
        }
        let targetLeaseGeneration = resolved.leaseGeneration + 1
        let targetBinding = try LoggingProtectedOptionsBinding(
            containerID: source.containerID,
            sourceConfiguration: source.configuration.logging,
            targetDescriptor: targetDescriptor,
            targetLeaseGeneration: targetLeaseGeneration,
            historyReceipt: historyReceipt
        )
        var targetReference: LoggingProtectedOptionsReference?
        var published = false
        do {
            if !source.protectedOptions.isEmpty {
                targetReference = try await loggingProtectedOptionsStore.store(
                    source.protectedOptions,
                    boundTo: targetBinding
                )
            }
            let targetResolved = try ResolvedContainerLogConfiguration(
                leaseGeneration: targetLeaseGeneration,
                driver: resolved.driver,
                safeOptions: resolved.safeOptions,
                protectedOptionNames: resolved.protectedOptionNames,
                protectedOptionReference: targetReference,
                delivery: resolved.delivery,
                readPolicy: resolved.readPolicy,
                providerIdentity: targetDescriptor.providerIdentity,
                providerGenerationAtResolution: targetDescriptor.providerGeneration,
                contractDigest: targetDescriptor.optionContractDigest,
                providerHistoryMigrationReceipt: historyReceipt
            )
            var requestedOptions = requested.safeOptions
            for name in requested.protectedOptionNames {
                guard let value = source.protectedOptions[name] else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "logging provider migration cannot reconstruct the request"
                    )
                }
                requestedOptions[name] = value
            }
            let targetLogging = try ContainerLogConfiguration(
                requested: ContainerLogRequest(
                    driver: requested.driver,
                    options: requestedOptions
                ),
                resolved: targetResolved
            )
            guard
                try LoggingProtectedOptionsBinding(
                    containerID: source.containerID,
                    configuration: targetLogging
                ) == targetBinding
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "logging provider migration binding is not canonical"
                )
            }
            var targetConfiguration = source.configuration
            targetConfiguration.logging = targetLogging
            guard var state = containers[source.containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container disappeared during logging provider migration"
                )
            }
            let path = try Self.containerPath(
                root: containerRoot,
                id: source.containerID
            )
            try Self.persistContainerConfiguration(
                targetConfiguration,
                at: path
            )
            published = true
            state.snapshot.configuration = targetConfiguration
            containers[source.containerID] = state

            if let sourceReference = resolved.protectedOptionReference {
                let sourceBinding = try LoggingProtectedOptionsBinding(
                    containerID: source.containerID,
                    configuration: source.configuration.logging
                )
                do {
                    try await loggingProtectedOptionsStore.delete(
                        sourceReference,
                        boundTo: sourceBinding
                    )
                } catch {
                    log.warning(
                        "old protected logging options will be reclaimed at authority boot",
                        metadata: ["id": "\(source.containerID)"]
                    )
                }
            }
        } catch {
            if !published, let targetReference {
                try? await loggingProtectedOptionsStore.delete(
                    targetReference,
                    boundTo: targetBinding
                )
            }
            throw error
        }
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
        await resumeInterruptedRemovals()
        resumeInterruptedRestarts()
    }

    private func resumeInterruptedRemovals() async {
        let containerIDs = lifecycleRecords.compactMap { id, record in
            record.intent.removalRequested ? id : nil
        }
        for id in containerIDs.sorted() {
            do {
                try await withLifecycleMutation(id: id) {
                    try await lock.withLock(
                        logMetadata: [
                            "acquirer": "\(#function)",
                            "id": "\(id)",
                        ]
                    ) { context in
                        try await self.cleanUp(id: id, context: context)
                    }
                    lifecycleRecords.removeValue(forKey: id)
                }
            } catch {
                if let lifecycle = lifecycleRecords[id] {
                    scheduleExitPersistenceRecovery(
                        id: id,
                        expectedOperationGeneration: lifecycle.snapshot.operationGeneration,
                        terminalPublicState: lifecycle.snapshot.state,
                        incrementRestartCount: false,
                        observedOOMKillCount: nil,
                        manualRestartSuppressed: lifecycle.intent.manualRestartSuppressed,
                        terminalError: lifecycle.snapshot.error,
                        action: .remove,
                        terminalPersisted: true,
                        removalLifecycle: lifecycle
                    )
                }
                log.error(
                    "failed to resume interrupted container removal; retrying",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ]
                )
            }
        }
    }

    private func resumeInterruptedRestarts() {
        let pendingRestarts = lifecycleRecords.compactMap { id, record -> (String, UInt64)? in
            guard record.snapshot.state == .restarting,
                !record.intent.removalRequested
            else {
                return nil
            }
            let failureCount =
                record.snapshot.restartConsecutiveFailureCount
                ?? (record.intent.manualRestartSuppressed ? 0 : 1)
            return (
                id,
                ContainerRestartTracker.pendingDelay(
                    policy: record.intent.restartPolicy,
                    consecutiveFailureCount: failureCount
                )
            )
        }
        for (id, delay) in pendingRestarts.sorted(by: { $0.0 < $1.0 }) {
            scheduleRestart(id: id, delayInNanoseconds: delay)
        }
    }

    func events(options: ContainerEventOptions = .default) async -> ContainerEventSubscription {
        await eventBroadcaster.subscribe(options: options)
    }

    static func loadAtBoot(
        root: URL,
        loader: PluginLoader,
        log: Logger,
        deregisterService: (String) throws -> Void = { label in
            var status: Int32 = -1
            try ServiceManager.deregister(
                fullServiceLabel: label,
                status: &status
            )
            if status != 0,
                try ServiceManager.isRegistered(fullServiceLabel: label)
            {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to stop surviving runtime service \(label)"
                )
            }
        },
        waitBeforeDeregistrationRetry: () -> Void = {
            Thread.sleep(forTimeInterval: 0.1)
        }
    ) throws -> [String: ContainerState] {
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
            let config: ContainerConfiguration
            do {
                (config, _) = try Self.getContainerConfiguration(at: dir)
                _ = try Self.containerPath(root: root, id: config.id)
            } catch {
                log.warning(
                    "failed to load container; leaving bundle on disk",
                    metadata: [
                        "path": "\(dir.path)",
                        "error": "\(error)",
                    ])
                continue
            }

            let label = Self.fullLaunchdServiceLabel(
                runtimeName: config.runtimeHandler,
                instanceId: config.id
            )
            for attempt in 1...Self.bootServiceDeregistrationAttempts {
                do {
                    try deregisterService(label)
                    break
                } catch {
                    guard attempt < Self.bootServiceDeregistrationAttempts else {
                        log.error(
                            "failed to stop surviving runtime service; refusing authority startup",
                            metadata: [
                                "id": "\(config.id)",
                                "label": "\(label)",
                                "attempts": "\(attempt)",
                                "error": "\(error)",
                            ])
                        throw error
                    }
                    log.warning(
                        "failed to stop surviving runtime service; retrying",
                        metadata: [
                            "id": "\(config.id)",
                            "label": "\(label)",
                            "attempt": "\(attempt)",
                            "error": "\(error)",
                        ])
                    waitBeforeDeregistrationRetry()
                }
            }

            do {
                guard runtimePlugins.first(where: { $0.name == config.runtimeHandler }) != nil else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to find runtime plugin \(config.runtimeHandler)"
                    )
                }
                let bundle = ContainerResource.Bundle(path: dir)
                let lifecycle = try bundle.lifecycleState
                let dockerState = try bundle.dockerState
                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        networks: [],
                        startedDate: lifecycle?.startedDate,
                        exitCode: lifecycle?.exitCode,
                        exitedDate: lifecycle?.exitedDate
                    ),
                    dockerStateError: dockerState?.error ?? ""
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

    static func quarantinedContainerNamesAtBoot(
        root: URL,
        acceptedContainerIDs: Set<String>
    ) throws -> Set<String> {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter(\.isDirectory)
        var names = Set<String>()
        for directory in directories {
            let bundleKey = directory.lastPathComponent
            guard !acceptedContainerIDs.contains(bundleKey),
                let (configuration, _) = try? Self.getContainerConfiguration(
                    at: directory
                )
            else {
                continue
            }
            names.insert(bundleKey)
            names.insert(configuration.id)
            if let dockerName = configuration.dockerName {
                names.insert(dockerName)
            }
            if let dockerID = configuration.dockerID {
                names.insert(dockerID)
            }
        }
        return names
    }

    static func loadLifecycleRecords(
        containers: [String: ContainerState],
        root: URL,
        log: Logger
    ) -> [String: ContainerResource.ContainerLifecycleRecordV2] {
        var records = [String: ContainerResource.ContainerLifecycleRecordV2]()
        for (bundleKey, state) in containers {
            do {
                let bundle = ContainerResource.Bundle(
                    path: try containerPath(root: root, id: bundleKey)
                )
                if var record = try bundle.lifecycleRecordV2 {
                    var needsPersistence = try Self.reconcileLifecycleRecordIdentity(
                        &record,
                        bundleKey: bundleKey,
                        configuration: state.snapshot.configuration
                    )
                    var revisionAdvanced = needsPersistence
                    if let options = try Self.getContainerConfiguration(
                        at: bundle.path
                    ).1 {
                        let intentChanged =
                            record.intent.restartPolicy != options.restartPolicy
                            || record.intent.autoRemove != options.autoRemove
                        if intentChanged {
                            try Self.advanceLifecycleRevisions(&record.snapshot)
                            record.intent.restartPolicy = options.restartPolicy
                            record.intent.autoRemove = options.autoRemove
                            needsPersistence = true
                            revisionAdvanced = true
                        }
                    }
                    var normalizationChanged = Self.normalizeLifecycleStateFlags(
                        &record.snapshot
                    )
                    needsPersistence = normalizationChanged || needsPersistence
                    if record.intent.removalRequested {
                        if record.snapshot.state != .removing {
                            try Self.advanceLifecycleRevisions(&record.snapshot)
                            record.snapshot.state = .removing
                            needsPersistence = true
                            revisionAdvanced = true
                        }
                        normalizationChanged =
                            Self.normalizeLifecycleStateFlags(&record.snapshot)
                            || normalizationChanged
                        needsPersistence = normalizationChanged || needsPersistence
                        if normalizationChanged, !revisionAdvanced {
                            try Self.advanceLifecycleRevisions(&record.snapshot)
                        }
                        if needsPersistence {
                            try bundle.setDurably(lifecycleRecordV2: record)
                        }
                        records[bundleKey] = record
                        continue
                    }
                    if [.running, .paused, .restarting, .removing]
                        .contains(record.snapshot.state)
                    {
                        let recoveredState = record.snapshot.state
                        try Self.advanceLifecycleRevisions(&record.snapshot)
                        let recoveredFailureCount =
                            record.snapshot.restartConsecutiveFailureCount
                            ?? (recoveredState == .restarting
                                && !record.intent.manualRestartSuppressed ? 1 : 0)
                        let resumesRestart = Self.shouldResumeRestartAtBoot(
                            previousState: recoveredState,
                            policy: record.intent.restartPolicy,
                            exitCode: record.snapshot.exitCode,
                            manualRestartSuppressed: record.intent.manualRestartSuppressed,
                            restartConsecutiveFailureCount: recoveredFailureCount
                        )
                        if resumesRestart,
                            recoveredState != .restarting
                        {
                            record.snapshot.restartCount = try Self.nextLifecycleCounter(
                                record.snapshot.restartCount,
                                named: "restart count"
                            )
                        }
                        if resumesRestart,
                            !record.intent.manualRestartSuppressed,
                            record.snapshot.restartConsecutiveFailureCount == nil
                        {
                            record.snapshot.restartConsecutiveFailureCount = max(
                                1,
                                recoveredFailureCount
                            )
                        }
                        record.snapshot.state = resumesRestart ? .restarting : .exited
                        record.snapshot.pid = 0
                        record.snapshot.finishedAt =
                            record.snapshot.finishedAt ?? Date()
                        record.snapshot.error =
                            "authority restarted while lifecycle state was \(recoveredState.rawValue)"
                        _ = Self.normalizeLifecycleStateFlags(&record.snapshot)
                        needsPersistence = true
                        revisionAdvanced = true
                    }
                    if record.intent.autoRemove,
                        [.exited, .dead, .removing].contains(record.snapshot.state)
                    {
                        try Self.advanceLifecycleRevisions(&record.snapshot)
                        record.intent.removalRequested = true
                        record.snapshot.state = .removing
                        _ = Self.normalizeLifecycleStateFlags(&record.snapshot)
                        needsPersistence = true
                        revisionAdvanced = true
                    }
                    if normalizationChanged, !revisionAdvanced {
                        try Self.advanceLifecycleRevisions(&record.snapshot)
                    }
                    if needsPersistence {
                        try bundle.setDurably(lifecycleRecordV2: record)
                    }
                    records[bundleKey] = record
                    continue
                }
                let options =
                    try Self.getContainerConfiguration(
                        at: bundle.path
                    ).1 ?? .default
                var migrated = ContainerResource.ContainerLifecycleRecordV2.migrate(
                    bundleKey: bundleKey,
                    canonicalName: state.snapshot.configuration.dockerName ?? bundleKey,
                    selectedProviderFingerprint: state.snapshot.configuration.runtimeHandler,
                    legacy: try bundle.lifecycleState,
                    intent: ContainerResource.ContainerLifecycleIntentV2(
                        autoRemove: options.autoRemove,
                        restartPolicy: options.restartPolicy
                    )
                )
                if let dockerID = state.snapshot.configuration.dockerID,
                    dockerID.count == 64
                {
                    migrated.containerID = dockerID
                }
                if migrated.intent.autoRemove,
                    [.exited, .dead, .removing].contains(migrated.snapshot.state)
                {
                    try Self.advanceLifecycleRevisions(&migrated.snapshot)
                    migrated.intent.removalRequested = true
                    migrated.snapshot.state = .removing
                    _ = Self.normalizeLifecycleStateFlags(&migrated.snapshot)
                }
                try bundle.setDurably(lifecycleRecordV2: migrated)
                records[bundleKey] = migrated
            } catch {
                log.warning(
                    "failed to load lifecycle record; leaving bundle on disk",
                    metadata: [
                        "id": "\(bundleKey)",
                        "error": "\(error)",
                    ]
                )
            }
        }
        return records
    }

    static func shouldResumeRestartAtBoot(
        previousState: ContainerResource.ContainerPublicStateV2,
        policy: ContainerRestartPolicy,
        exitCode: Int32?,
        manualRestartSuppressed: Bool = false,
        restartConsecutiveFailureCount: UInt32 = 0
    ) -> Bool {
        switch previousState {
        case .restarting:
            return Self.restartIntentAllowsPendingRestart(
                lifecycleState: previousState,
                manualRestartSuppressed: manualRestartSuppressed,
                policy: policy,
                exitCode: exitCode,
                restartConsecutiveFailureCount: restartConsecutiveFailureCount
            )
        case .running, .paused:
            return !manualRestartSuppressed
                && (policy.mode == .always || policy.mode == .unlessStopped)
        case .created, .exited, .dead, .removing:
            return false
        }
    }

    @discardableResult
    static func reconcileLifecycleRecordIdentity(
        _ record: inout ContainerResource.ContainerLifecycleRecordV2,
        bundleKey: String,
        configuration: ContainerConfiguration
    ) throws -> Bool {
        let expected = Self.makeLifecycleRecord(
            configuration: configuration,
            options: .default
        )
        guard record.immutableBundleKey == bundleKey,
            record.containerID == expected.containerID,
            record.selectedProviderFingerprint
                == configuration.runtimeHandler
        else {
            throw ContainerizationError(
                .invalidState,
                message: "lifecycle record identity does not match bundle \(bundleKey)"
            )
        }
        let canonicalName = configuration.dockerName ?? configuration.id
        guard record.canonicalName != canonicalName else {
            return false
        }
        record.canonicalName = canonicalName
        try Self.advanceLifecycleRevisions(&record.snapshot)
        return true
    }

    @discardableResult
    static func normalizeLifecycleStateFlags(
        _ snapshot: inout ContainerResource.ContainerLifecycleSnapshotV2
    ) -> Bool {
        let running =
            snapshot.state == .running
            || snapshot.state == .paused
            || snapshot.state == .restarting
        let paused = snapshot.state == .paused
        let restarting = snapshot.state == .restarting
        let removalInProgress = snapshot.state == .removing
        let dead = snapshot.state == .dead
        let pid = running ? snapshot.pid : 0
        let changed =
            snapshot.running != running
            || snapshot.paused != paused
            || snapshot.restarting != restarting
            || snapshot.removalInProgress != removalInProgress
            || snapshot.dead != dead
            || snapshot.pid != pid
        snapshot.running = running
        snapshot.paused = paused
        snapshot.restarting = restarting
        snapshot.removalInProgress = removalInProgress
        snapshot.dead = dead
        snapshot.pid = pid
        return changed
    }

    static func advanceLifecycleRevisions(
        _ snapshot: inout ContainerResource.ContainerLifecycleSnapshotV2
    ) throws {
        let transitionRevision = try Self.nextLifecycleCounter(
            snapshot.transitionRevision,
            named: "transition revision"
        )
        let operationGeneration = try Self.nextLifecycleCounter(
            snapshot.operationGeneration,
            named: "operation generation"
        )
        snapshot.transitionRevision = transitionRevision
        snapshot.operationGeneration = operationGeneration
    }

    static func resetRestartFailureState(
        _ snapshot: inout ContainerResource.ContainerLifecycleSnapshotV2
    ) throws {
        try Self.advanceLifecycleRevisions(&snapshot)
        snapshot.restartConsecutiveFailureCount = 0
    }

    static func nextLifecycleCounter(_ value: UInt64, named name: String) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw ContainerizationError(
                .invalidState,
                message: "lifecycle \(name) counter overflow"
            )
        }
        return next
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

        return try filteredContainerSnapshots(filters: filters)
    }

    private func filteredContainerSnapshots(
        filters: ContainerListFilters
    ) throws -> [ContainerSnapshot] {
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

    /// Returns resource snapshots and lifecycle records from one actor-isolated revision.
    package func lifecycleViewsForAPI(
        filters: ContainerListFilters = .all
    ) throws -> [ContainerResource.ContainerLifecycleViewV2] {
        try filteredContainerSnapshots(filters: filters).map { snapshot in
            guard let lifecycle = lifecycleRecords[snapshot.id] else {
                throw ContainerizationError(
                    .internalError,
                    message: "container \(snapshot.id) is missing its lifecycle record"
                )
            }
            return ContainerResource.ContainerLifecycleViewV2(
                container: snapshot,
                lifecycle: lifecycle
            )
        }
    }

    /// Resolves a Docker route identifier to the native resource identifier.
    /// Docker accepts an exact container name, a full immutable ID, or a
    /// unique ID prefix. Native callers continue to use their resource ID.
    func resolveDockerContainerIdentifier(_ identifier: String) throws -> String {
        if containers[identifier] != nil {
            return identifier
        }

        let namedMatches = containers.values.compactMap { state -> String? in
            state.snapshot.configuration.dockerName == identifier
                ? state.snapshot.id
                : nil
        }
        if namedMatches.count == 1, let match = namedMatches.first {
            return match
        }

        let idMatches = containers.values.compactMap { state -> String? in
            guard let dockerID = state.snapshot.configuration.dockerID,
                dockerID.hasPrefix(identifier)
            else {
                return nil
            }
            return state.snapshot.id
        }
        if idMatches.count == 1, let match = idMatches.first {
            return match
        }
        if idMatches.count > 1 {
            throw ContainerizationError(
                .invalidArgument,
                message: "ambiguous Docker container ID prefix \(identifier)"
            )
        }
        throw ContainerizationError(
            .notFound,
            message: "container not found: \(identifier)"
        )
    }

    /// Execute an operation with the current container list while maintaining atomicity
    /// This prevents race conditions where containers are created during the operation
    public func withContainerList<T: Sendable>(
        logMetadata: Logger.Metadata? = nil,
        _ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T
    ) async throws -> T {
        try await lock.withLock(logMetadata: logMetadata) { context in
            let snapshots = await self.protectedContainerSnapshots()
            return try await operation(snapshots)
        }
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        let containers = await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            let lifecycleRecords = await self.lifecycleRecords
            return await self.containers.values.map(\.snapshot).map {
                ContainerDiskUsageEntry(
                    id: $0.id,
                    isActive: Self.isActiveForDiskUsage(
                        runtimeStatus: $0.status,
                        lifecycleState: lifecycleRecords[$0.id]?.snapshot.state
                    )
                )
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
            return ContainerDiskUsagePath(path: bundlePath, isActive: container.isActive)
        }
        return await Self.calculateDiskUsage(totalCount: containers.count, paths: paths)
    }

    struct ContainerDiskUsageEntry: Sendable {
        let id: String
        let isActive: Bool
    }

    struct ContainerDiskUsagePath: Sendable {
        let path: URL
        let isActive: Bool
    }

    static func isActiveForDiskUsage(
        runtimeStatus: RuntimeStatus,
        lifecycleState: ContainerResource.ContainerPublicStateV2?
    ) -> Bool {
        if let lifecycleState {
            return [.running, .paused, .restarting].contains(lifecycleState)
        }
        return [.running, .paused, .stopping].contains(runtimeStatus)
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

                if path.isActive {
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
            for snapshot in await self.protectedContainerSnapshots() {
                imageRefs.insert(snapshot.configuration.image.reference)
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
            loggingPlan = try await prepareLoggingForCreate(
                configuration: configuration.logging,
                request: loggingRequest
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

        try Utility.validEntityName(configuration.id)
        let path = try Self.containerPath(root: self.containerRoot, id: configuration.id)
        let requestedSnapshot = ContainerSnapshot(
            configuration: configuration,
            status: .stopped,
            networks: [],
            startedDate: nil
        )
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-reserve", "id": "\(configuration.id)"]) { context in
            try await self.reserveContainerCreation(
                requestedSnapshot,
                path: path,
                context: context
            )
        }

        var sealedLogging: SealedContainerLogging?
        let createdSnapshot: ContainerSnapshot
        do {
            let systemPlatform = kernel.platform
            self.log.debug(
                "ContainersService: prepare filesystems",
                metadata: [
                    "id": "\(configuration.id)",
                    "ref": "\(configuration.image.reference)",
                ]
            )
            async let initFilesystem = self.getInitBlock(
                for: systemPlatform.ociPlatform(),
                imageRef: initImage
            )
            async let imageFilesystem: Filesystem? = {
                guard options.rootFsOverride == nil else {
                    return nil
                }
                let containerImage = ClientImage(description: configuration.image)
                return try await containerImage.getCreateSnapshot(platform: configuration.platform)
            }()
            let (preparedInitFilesystem, preparedImageFilesystem) = try await (
                initFilesystem,
                imageFilesystem
            )

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
                ]
            )
            let runtimeConfig = RuntimeConfiguration(
                path: path,
                initialFilesystem: preparedInitFilesystem,
                kernel: kernel,
                containerConfiguration: authoritativeConfiguration,
                containerRootFilesystem: preparedImageFilesystem,
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
            let lifecycleRecord = Self.makeLifecycleRecord(
                configuration: authoritativeConfiguration,
                options: options
            )
            try ContainerResource.Bundle(path: path).setDurably(
                lifecycleRecordV2: lifecycleRecord
            )
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-commit", "id": "\(configuration.id)"]) { context in
                try await self.commitContainerCreation(
                    snapshot,
                    lifecycleRecord: lifecycleRecord,
                    context: context
                )
            }
            createdSnapshot = snapshot
        } catch {
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
            if bundleRemoved, let sealedLogging {
                await self.rollbackSealedLogging(sealedLogging)
            }
            await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-rollback", "id": "\(configuration.id)"]) { context in
                await self.rollbackContainerCreation(configuration.id, context: context)
            }
            throw error
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

    func prepareLoggingForCreate(
        configuration: ContainerLogConfiguration,
        request: ContainerLogRequest?
    ) async throws -> ContainerLoggingCreatePlan {
        let catalog = try await logDriverCatalogProvider.logDriverCatalog()
        return try Self.prepareLoggingForCreate(
            configuration: configuration,
            request: request,
            defaults: containerSystemConfig.logging,
            catalog: catalog
        )
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

    /// Host-mode workloads share the sandbox VM network and therefore must not
    /// ask a network plugin to allocate a private endpoint.
    static func networkBootstrapAttachments(
        for configuration: ContainerConfiguration
    ) -> [AttachmentConfiguration] {
        configuration.hostNetwork ? [] : configuration.networks
    }

    private static func normalizedNetworkName(_ name: String) -> String {
        let name = name.hasSuffix(".") ? String(name.dropLast()) : name
        return name.lowercased()
    }

    /// Bootstrap the init process of the container.
    public func bootstrap(id: String, stdio: [FileHandle?], dynamicEnv: [String: String]) async throws {
        try await withLifecycleMutation(id: id) {
            _ = try await self.bootstrap(
                id: id,
                stdio: stdio,
                dynamicEnv: dynamicEnv,
                onlyIfNeverStarted: false
            )
        }
    }

    /// Bootstrap a newly created container with attach-owned stdio.
    ///
    /// Returns `true` only when this call created the runtime client. A caller
    /// that receives `false` must attach its stdio to the existing client
    /// instead. The lifecycle check prevents a late attach from recreating an
    /// exited container after its runtime client has been released.
    func bootstrapForAttach(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String]
    ) async throws -> Bool {
        try await withLifecycleMutation(id: id) {
            try await self.bootstrap(
                id: id,
                stdio: stdio,
                dynamicEnv: dynamicEnv,
                onlyIfNeverStarted: true
            )
        }
    }

    private func bootstrap(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String],
        onlyIfNeverStarted: Bool
    ) async throws -> Bool {
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

        var timings = ContainerBootstrapTimings()
        let plan = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)-capture", "id": "\(id)"]
        ) { context -> ContainerBootstrapPlan? in
            let state = try await self.getContainerState(id: id, context: context)

            // We've already bootstrapped this container. Ideally we should be able to
            // return some sort of error code from the sandbox svc to check here, but this
            // is also a very simple check and faster than doing an rpc to get the same result.
            if state.client != nil {
                return nil
            }

            // Attach is allowed to bootstrap only a never-started container.
            // Once startedDate is durable, recreating the runtime here would
            // silently turn an attach to an exited container into a restart.
            if onlyIfNeverStarted, state.snapshot.startedDate != nil {
                return nil
            }

            let lifecycle = try await self.lifecycleRecord(id: id)
            guard
                Self.lifecycleMayBootstrap(
                    removalRequested: lifecycle.intent.removalRequested,
                    removalInProgress: lifecycle.snapshot.removalInProgress
                )
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) requires removal recovery"
                )
            }

            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let (config, _) = try Self.getContainerConfiguration(at: path)
            return ContainerBootstrapPlan(
                containerGeneration: state.generation,
                operationGeneration: lifecycle.snapshot.operationGeneration,
                path: path,
                configuration: config
            )
        }
        timings.finish("capture")
        guard let plan else {
            log.debug(
                "container bootstrap timings",
                metadata: timings.metadata(id: id, outcome: "already-bootstrapped")
            )
            return false
        }

        var runtimeClientToken: UUID?
        do {
            let authenticatedProtectedOptions =
                try await self
                .validateLoggingForStart(
                    containerID: id,
                    configuration: plan.configuration.logging
                )
            timings.finish("logging-validation")

            let networkAttachments = Self.networkBootstrapAttachments(
                for: plan.configuration
            )
            let networkBootstrapInfos: [NetworkBootstrapInfo]
            if networkAttachments.isEmpty {
                networkBootstrapInfos = []
            } else {
                let networkIDs = networkAttachments.map(\.network)
                guard let plugins = try await self.networksService?.plugins(for: networkIDs) else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to get plugin for network \(networkIDs[0])"
                    )
                }
                networkBootstrapInfos = plugins.map { NetworkBootstrapInfo(plugin: $0) }
            }
            timings.finish("network-resolution")

            let runtimeStdio: [FileHandle?]
            if let remoteLogDriverPlane = self.remoteLogDriverPlane {
                runtimeStdio =
                    try await remoteLogDriverPlane
                    .prepareBootstrap(
                        containerID: id,
                        bundle: ContainerResource.Bundle(path: plan.path),
                        configuration: plan.configuration,
                        authenticatedProtectedOptions:
                            authenticatedProtectedOptions,
                        stdio: stdio
                    )
            } else {
                runtimeStdio = stdio
            }
            timings.finish("logging-prepare")

            guard
                let runtimePlugin = self.runtimePlugins.first(where: {
                    $0.name == plan.configuration.runtimeHandler
                })
            else {
                throw ContainerizationError(
                    .notFound,
                    message:
                        "unable to locate runtime plugin \(plan.configuration.runtimeHandler)"
                )
            }
            try Self.registerService(
                plugin: runtimePlugin,
                loader: self.pluginLoader,
                configuration: plan.configuration,
                path: plan.path,
                debug: self.debugHelpers
            )
            timings.finish("launchd-registration")

            let runtimeClient = try await RuntimeClient.create(
                id: id,
                runtime: plan.configuration.runtimeHandler
            )
            timings.finish("runtime-client")
            let bootstrapWaitStartedAt = ProcessInfo.processInfo.systemUptime
            let bootstrapPhases = try await Self.runtimeBootstrapLimiter.withPermit {
                let bootstrapStartedAt = ProcessInfo.processInfo.systemUptime
                try await runtimeClient.bootstrap(
                    stdio: runtimeStdio,
                    networkBootstrapInfos: networkBootstrapInfos,
                    dynamicEnv: dynamicEnv
                )
                let bootstrapFinishedAt = ProcessInfo.processInfo.systemUptime
                return [
                    (
                        "runtime-bootstrap-admission",
                        Int64((bootstrapStartedAt - bootstrapWaitStartedAt) * 1_000_000)
                    ),
                    (
                        "runtime-bootstrap",
                        Int64((bootstrapFinishedAt - bootstrapStartedAt) * 1_000_000)
                    ),
                ]
            }
            timings.finish(bootstrapPhases)
            try await self.remoteLogDriverPlane?.bootstrapSucceeded(
                containerID: id
            )
            timings.finish("logging-commit")

            let token = UUID()
            runtimeClientToken = token
            try await self.exitMonitor.registerProcess(id: id) {
                [weak self] callbackID, status in
                guard let self else {
                    return
                }
                try await self.handleContainerExit(
                    id: callbackID,
                    code: status,
                    runtimeClientToken: token
                )
            }
            timings.finish("exit-monitor")

            try await self.lock.withLock(
                logMetadata: ["acquirer": "\(#function)-commit", "id": "\(id)"]
            ) { context in
                var state = try await self.getContainerState(id: id, context: context)
                let lifecycle = try await self.lifecycleRecord(id: id)
                guard
                    Self.bootstrapCommitIsCurrent(
                        plannedContainerGeneration: plan.containerGeneration,
                        currentContainerGeneration: state.generation,
                        plannedOperationGeneration: plan.operationGeneration,
                        currentOperationGeneration: lifecycle.snapshot.operationGeneration
                    ),
                    Self.lifecycleMayBootstrap(
                        removalRequested: lifecycle.intent.removalRequested,
                        removalInProgress: lifecycle.snapshot.removalInProgress
                    ),
                    state.client == nil,
                    !onlyIfNeverStarted || state.snapshot.startedDate == nil
                else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "container \(id) changed during bootstrap"
                    )
                }

                state.client = runtimeClient
                await self.setRuntimeClientToken(token, id: id)
                await self.setContainerState(id, state, context: context)
            }
            timings.finish("state-commit")
            log.debug(
                "container bootstrap timings",
                metadata: timings.metadata(id: id, outcome: "success")
            )
            return true
        } catch {
            let label = Self.fullLaunchdServiceLabel(
                runtimeName: plan.configuration.runtimeHandler,
                instanceId: id
            )

            await self.exitMonitor.stopTracking(id: id)
            if let runtimeClientToken {
                self.clearRuntimeClientToken(runtimeClientToken, id: id)
            }
            try? ServiceManager.deregister(fullServiceLabel: label)
            try? await self.remoteLogDriverPlane?.abortBootstrap(
                containerID: id
            )
            log.debug(
                "container bootstrap timings",
                metadata: timings.metadata(id: id, outcome: "failure")
            )
            throw error
        }
    }

    static func bootstrapCommitIsCurrent(
        plannedContainerGeneration: UUID,
        currentContainerGeneration: UUID,
        plannedOperationGeneration: UInt64,
        currentOperationGeneration: UInt64
    ) -> Bool {
        plannedContainerGeneration == currentContainerGeneration
            && plannedOperationGeneration == currentOperationGeneration
    }

    func validateLoggingForStart(
        containerID: String,
        configuration: ContainerLogConfiguration
    ) async throws -> [String: String] {
        guard !configuration.isLegacy else {
            return [:]
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
            let catalog = try await logDriverCatalogProvider.logDriverCatalog()
            try ContainerLogStartValidator(
                catalog: catalog
            ).validate(
                configuration,
                authenticatedProtectedOptions: protectedOptions
            )
            return protectedOptions
        } catch {
            throw Self.mapLoggingStartError(error)
        }
    }

    static func mapLoggingStartError(_ error: any Error) -> ContainerizationError {
        if let resolutionError = error as? ContainerLogResolutionError,
            case .invalidOption(let driver, let name, let reason) = resolutionError,
            driver == "local",
            name == "compress",
            reason == "compression cannot be enabled when max file count is 1"
        {
            return ContainerizationError(
                .invalidState,
                message: "failed to initialize logging driver: \(reason)"
            )
        }
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

        await publishEvent(
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
        try await withLifecycleMutation(id: id) {
            try await self.startProcessImpl(id: id, processID: processID)
        }
    }

    private func startProcessImpl(id: String, processID: String) async throws {
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
        let state = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-snapshot", "id": "\(id)"]) { context in
            try await self.getContainerState(id: id, context: context)
        }
        let isInit = Self.isInitProcess(id: id, processID: processID)
        if state.snapshot.status == .running && isInit {
            return
        }

        let client = try state.getClient()
        let oomKillCountBaseline: UInt64?
        if isInit {
            do {
                oomKillCountBaseline = try await client.statistics().memoryOOMKillCount
            } catch {
                oomKillCountBaseline = nil
            }
        } else {
            oomKillCountBaseline = nil
        }
        let preStartState = state
        try await client.startProcess(processID)

        var startedInitProcess: StartedInitProcess?
        var startedExecProcess: StartedExecProcess?
        if !isInit {
            if execConfiguration != nil {
                startedExecProcess = StartedExecProcess(
                    snapshot: state.snapshot,
                    processID: processID,
                    client: client
                )
            }
        } else {
            do {
                try await self.remoteLogDriverPlane?.activate(
                    containerID: id
                )
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
                let initPID: Int32
                do {
                    initPID = Self.reportedInitPID(
                        try await client.processes().processIdentifiers
                    )
                } catch  where Self.isPostStartProcessExitRace(error) {
                    // A short-lived init can exit between the successful start
                    // reply and this process snapshot. The exit monitor is
                    // already registered, so keep the successful start and let
                    // that monitor publish the terminal state.
                    initPID = 0
                }
                let startedDate = Date()
                startedInitProcess = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-commit", "id": "\(id)"]) { context in
                    var currentState = try await self.getContainerState(id: id, context: context)
                    Self.markContainerStarted(
                        &currentState,
                        from: sandboxSnapshot,
                        at: startedDate
                    )
                    let path = try Self.containerPath(
                        root: self.containerRoot,
                        id: id
                    )
                    let bundle = ContainerResource.Bundle(path: path)
                    try bundle.setDurably(
                        dockerState: ContainerDockerStateV1()
                    )
                    currentState.dockerStateError = ""
                    try bundle.setDurably(
                        lifecycleState: ContainerLifecycleStateV1(
                            startedDate: startedDate
                        )
                    )
                    currentState.restart.markStarted()
                    let lifecycle = try await self.commitLifecycle(
                        id: id,
                        from: currentState,
                        publicState: .running,
                        pid: initPID,
                        incrementProcessGeneration: true,
                        resetOOMObservation: true,
                        observedOOMKillCount: oomKillCountBaseline,
                        intent: { $0.manualRestartSuppressed = false }
                    )
                    await self.setContainerState(id, currentState, context: context)
                    return StartedInitProcess(
                        snapshot: currentState.snapshot,
                        lifecycle: lifecycle
                    )
                }
                self.scheduleRestartStabilityReset(
                    id: id,
                    startedDate: startedDate,
                    durationInNanoseconds: ContainerRestartTracker.stableRunDuration(for: restartPolicy)
                )
                await self.startHealthCheckMonitor(
                    id: id,
                    healthCheck: startedInitProcess?.snapshot.configuration.healthCheck,
                    client: client
                )
            } catch {
                self.stopHealthCheckMonitor(id: id)
                self.clearRuntimeClientToken(id: id)
                await self.exitMonitor.stopTracking(id: id)
                try? await client.stop(options: ContainerStopOptions.default)
                try? await client.shutdown()
                let label = Self.fullLaunchdServiceLabel(
                    runtimeName: state.snapshot.configuration.runtimeHandler,
                    instanceId: id
                )
                try? ServiceManager.deregister(fullServiceLabel: label)
                try? await self.remoteLogDriverPlane?.close(containerID: id)
                let recoveredState = Self.recoveredContainerStateAfterFailedStart(
                    preStartState
                )
                await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-rollback", "id": "\(id)"]) { context in
                    await self.setContainerState(id, recoveredState, context: context)
                }
                throw error
            }
        }

        if let startedExecProcess {
            if let event = execEventTracker.start(
                snapshot: startedExecProcess.snapshot,
                processID: startedExecProcess.processID
            ) {
                await publishEvent(event)
            }
            scheduleExecExit(
                id: id,
                processID: startedExecProcess.processID,
                client: startedExecProcess.client
            )
        }

        if let startedInitProcess {
            await publishEvent(
                Self.stampEvents(
                    [
                        Self.containerEvent(
                            action: "start",
                            snapshot: startedInitProcess.snapshot
                        )
                    ],
                    with: startedInitProcess.lifecycle
                )[0]
            )
        }
    }

    static func reportedInitPID(_ processIdentifiers: [Int32]) -> Int32 {
        // A short-lived init can exit after start succeeds but before the
        // process snapshot is read. The exit monitor is already registered,
        // so retain a zero PID briefly and let that monitor commit the real
        // terminal status instead of cancelling it as a failed start.
        processIdentifiers.filter { $0 > 0 }.min() ?? 0
    }

    static func markContainerStarted(
        _ state: inout ContainerState,
        from sandboxSnapshot: SandboxSnapshot,
        at startedDate: Date
    ) {
        state.snapshot.status = .running
        state.snapshot.networks = sandboxSnapshot.networks
        state.snapshot.startedDate = startedDate
        state.snapshot.exitCode = nil
        state.snapshot.exitedDate = nil
        state.snapshot.health = state.snapshot.configuration.healthCheck == nil ? nil : .starting
    }

    static func isPostStartProcessExitRace(_ error: any Error) -> Bool {
        guard let error = error as? ContainerizationError else {
            return false
        }
        if error.code == .invalidState,
            error.message.contains("container must be running or paused")
        {
            return true
        }
        guard let cause = error.cause else {
            return false
        }
        return isPostStartProcessExitRace(cause)
    }

    /// Send a signal to the container.
    public func kill(id: String, processID: String, signal: String) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.killImpl(id: id, processID: processID, signal: signal)
        }
    }

    private func killImpl(id: String, processID: String, signal: String) async throws {
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

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        let parsedSignal = try? Signal(signal)
        let recordsGuaranteedExplicitExit =
            processID == id && parsedSignal == .kill
        let canObserveExplicitExit =
            processID == id && Self.signalTerminatesByDefault(parsedSignal)
        var durableState: ContainerResource.ContainerPublicStateV2?
        if recordsGuaranteedExplicitExit {
            durableState = try lifecyclePublicState(id: id)
            explicitExitCauses[id] = .kill
            do {
                try await commitLifecycle(
                    id: id,
                    from: state,
                    publicState: durableState ?? .running,
                    intent: { $0.manualRestartSuppressed = true }
                )
            } catch {
                explicitExitCauses.removeValue(forKey: id)
                throw error
            }
        }
        var interruptedKillReply = false
        do {
            try await client.kill(processID, signal: signal)
        } catch let error as ContainerizationError
            where canObserveExplicitExit && error.code == .interrupted
        {
            // The runtime can terminate before replying. For an init-process
            // signal whose default action terminates, that interruption is an
            // observed terminal outcome rather than a failed signal request.
            interruptedKillReply = true
        } catch {
            if recordsGuaranteedExplicitExit, let durableState {
                try await rollbackManualTerminationIntent(
                    id: id,
                    fallbackState: state,
                    publicState: durableState,
                    error: error
                )
            }
            throw error
        }
        var observedSignalTermination = interruptedKillReply
        if canObserveExplicitExit, !recordsGuaranteedExplicitExit,
            !observedSignalTermination
        {
            observedSignalTermination =
                (try? await client.state().status)
                .map(Self.signalOutcomeConfirmsTermination) ?? false
        }
        if canObserveExplicitExit, !recordsGuaranteedExplicitExit,
            observedSignalTermination
        {
            let observedDurableState = try lifecyclePublicState(id: id)
            explicitExitCauses[id] = .kill
            do {
                try await commitLifecycle(
                    id: id,
                    from: state,
                    publicState: observedDurableState,
                    intent: { $0.manualRestartSuppressed = true }
                )
            } catch {
                explicitExitCauses.removeValue(forKey: id)
                throw error
            }
        }
        await publishEvent(
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
            try await handleContainerExitImpl(
                id: id,
                code: ExitStatus(exitCode: 128 + Signal.kill.rawValue)
            )
        }
    }

    /// Signals whose Linux default action only ignores, continues, stops, or
    /// otherwise observes a process must not suppress a later natural exit.
    static func signalTerminatesByDefault(_ signal: Signal?) -> Bool {
        guard let signal else {
            return false
        }
        let nonterminatingSignals: Set<Int32> = [
            Signal.Linux.chld.rawValue,
            Signal.Linux.cont.rawValue,
            Signal.Linux.stop.rawValue,
            Signal.Linux.tstp.rawValue,
            Signal.Linux.ttin.rawValue,
            Signal.Linux.ttou.rawValue,
            Signal.Linux.urg.rawValue,
            Signal.Linux.winch.rawValue,
        ]
        return !nonterminatingSignals.contains(signal.rawValue)
    }

    static func signalOutcomeConfirmsTermination(_ status: RuntimeStatus) -> Bool {
        status == .stopping || status == .stopped
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.stopImpl(id: id, options: options)
        }
    }

    private func stopImpl(id: String, options: ContainerStopOptions) async throws {
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
        if currentState.snapshot.status == .stopped {
            guard
                Self.shouldCancelPendingRestart(
                    runtimeStatus: currentState.snapshot.status,
                    lifecycleState: lifecycleRecords[id]?.snapshot.state,
                    restartScheduled: restartTasks[id] != nil
                )
            else {
                return
            }
            try await commitLifecycle(
                id: id,
                from: currentState,
                publicState: .exited,
                intent: { $0.manualRestartSuppressed = true }
            )
            _ = try await self.markContainerManuallyStopped(id: id)
            return
        }
        guard Self.shouldSendRuntimeStop(for: currentState.snapshot.status) else {
            return
        }
        guard currentState.snapshot.status != .paused else {
            throw ContainerizationError(
                .invalidState,
                message: "container is paused; unpause the container before stopping"
            )
        }

        // Stop should be idempotent.
        let client: RuntimeClient
        do {
            client = try currentState.getClient()
        } catch {
            return
        }

        let resolvedOptions = Self.resolvedStopOptions(
            options,
            configuredSignal: currentState.snapshot.configuration.stopSignal,
            configuredTimeoutInSeconds: currentState.snapshot.configuration.stopTimeoutInSeconds
        )

        let durableState = try lifecyclePublicState(id: id)
        explicitExitCauses[id] = .stop
        do {
            try await commitLifecycle(
                id: id,
                from: currentState,
                publicState: durableState,
                intent: { $0.manualRestartSuppressed = true }
            )
        } catch {
            explicitExitCauses.removeValue(forKey: id)
            throw error
        }
        do {
            _ = try await self.markContainerManuallyStopped(id: id)
        } catch {
            try await rollbackManualTerminationIntent(
                id: id,
                fallbackState: currentState,
                publicState: durableState,
                error: error
            )
            throw error
        }
        do {
            try await client.stop(options: resolvedOptions)
        } catch let err as ContainerizationError {
            if err.code != .interrupted {
                try await rollbackManualTerminationIntent(
                    id: id,
                    fallbackState: currentState,
                    publicState: durableState,
                    error: err
                )
                throw err
            }
        } catch {
            try await rollbackManualTerminationIntent(
                id: id,
                fallbackState: currentState,
                publicState: durableState,
                error: error
            )
            throw error
        }
        try await handleContainerExitImpl(id: id)
    }

    static func shouldSendRuntimeStop(for status: RuntimeStatus) -> Bool {
        status != .stopped
    }

    static func resolvedStopOptions(
        _ requested: ContainerStopOptions,
        configuredSignal: String?,
        configuredTimeoutInSeconds: Int32?
    ) -> ContainerStopOptions {
        var resolved = requested
        if resolved.signal == nil {
            resolved.signal = configuredSignal
        }
        if resolved.timeoutInSeconds == nil {
            resolved.timeoutInSeconds = configuredTimeoutInSeconds
        }
        return resolved
    }

    static func shouldCancelPendingRestart(
        runtimeStatus: RuntimeStatus,
        lifecycleState: ContainerResource.ContainerPublicStateV2?,
        restartScheduled: Bool
    ) -> Bool {
        runtimeStatus == .stopped
            && (lifecycleState == .restarting || restartScheduled)
    }

    /// Pause a running container.
    public func pause(id: String) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.pauseImpl(id: id)
        }
    }

    private func pauseImpl(id: String) async throws {
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

            state.snapshot.status = .paused
            do {
                try await self.commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .paused
                )
            } catch {
                let persistenceError = error
                do {
                    try await client.resume()
                } catch {
                    let recoveryError = error
                    await self.stopHealthCheckMonitor(id: id)
                    state.snapshot.status = .unknown
                    state.snapshot.health = nil
                    _ = try? await self.commitLifecycle(
                        id: id,
                        from: state,
                        publicState: .dead,
                        error:
                            "pause persistence failed: \(persistenceError); runtime resume recovery failed: \(recoveryError)"
                    )
                    await self.setContainerState(id, state, context: context)
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "pause persistence failed: \(persistenceError); runtime resume recovery failed: \(recoveryError)"
                    )
                }
                throw persistenceError
            }
            await self.stopHealthCheckMonitor(id: id)
            await self.setContainerState(id, state, context: context)
            return state.snapshot
        }

        await publishContainerEvent(action: "pause", snapshot: pausedSnapshot)
    }

    /// Resume a paused container.
    public func unpause(id: String) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.unpauseImpl(id: id)
        }
    }

    private func unpauseImpl(id: String) async throws {
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
            do {
                try await self.commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .running
                )
            } catch {
                let persistenceError = error
                do {
                    try await client.pause()
                } catch {
                    let recoveryError = error
                    state.snapshot.status = .unknown
                    state.snapshot.health = nil
                    _ = try? await self.commitLifecycle(
                        id: id,
                        from: state,
                        publicState: .dead,
                        error:
                            "unpause persistence failed: \(persistenceError); runtime pause recovery failed: \(recoveryError)"
                    )
                    await self.setContainerState(id, state, context: context)
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "unpause persistence failed: \(persistenceError); runtime pause recovery failed: \(recoveryError)"
                    )
                }
                throw persistenceError
            }
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

        if Self.isInitProcess(id: id, processID: processID) {
            let result = try await waitForDockerContainer(
                id: id,
                condition: .notRunning
            )
            let exitedAt = try? self._getContainerState(id: id).snapshot.exitedDate
            return ExitStatus(
                exitCode: result.statusCode,
                exitedAt: exitedAt ?? .now
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.wait(processID)
    }

    /// Waits for the Docker Engine container lifecycle condition without
    /// polling the runtime or racing a terminal state transition.
    public func waitForDockerContainer(
        id: String,
        condition: DockerContainerWaitCondition
    ) async throws -> DockerContainerWaitResult {
        try await waitForDockerContainer(
            id: id,
            condition: condition,
            onRegistered: {}
        )
    }

    /// Waits for the Docker Engine lifecycle condition after either recording
    /// its cancellation-aware waiter or resolving an already-terminal state.
    public func waitForDockerContainer(
        id: String,
        condition: DockerContainerWaitCondition,
        onRegistered: @escaping @Sendable () -> Void
    ) async throws -> DockerContainerWaitResult {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<DockerContainerWaitResult, any Error>) in
                do {
                    let snapshot = try self._getContainerState(id: id).snapshot
                    if let result = Self.dockerWaitResult(
                        snapshot: snapshot,
                        condition: condition
                    ) {
                        onRegistered()
                        continuation.resume(returning: result)
                        return
                    }
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.dockerContainerWaiters[id, default: [:]][waiterID] =
                        DockerContainerWaiter(
                            condition: condition,
                            continuation: continuation
                        )
                    onRegistered()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.cancelDockerContainerWaiter(
                    id: id,
                    waiterID: waiterID
                )
            }
        }
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
            let state = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            if !state.snapshot.configuration.logging.isLegacy {
                let reader = try await nativeLogReader(
                    containerID: id,
                    bundle: bundle,
                    configuration: state.snapshot.configuration,
                    options: options,
                    includeRotated: replay.includeRotated
                )
                return [
                    Self.logHandle(for: reader),
                    Self.applyLogOptions(
                        to: try FileHandle(forReadingFrom: bundle.bootlog),
                        options: options
                    ),
                ]
            }
            let handles = [
                try Self.logHandle(for: bundle.containerLog, options: options, replay: replay),
                Self.applyLogOptions(to: try FileHandle(forReadingFrom: bundle.bootlog), options: options),
            ]
            return handles
        } catch {
            throw Self.logReadError(error, operation: "open container logs")
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
            let state = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            if !state.snapshot.configuration.logging.isLegacy {
                if !Self.requiresAuthorityLogReader(
                    state.snapshot.configuration
                ), isLiveForLogFollow(id: id) {
                    do {
                        let request = try Self.nativeLogReadRequest(
                            options: options,
                            follow: true
                        )
                        return try await state.getClient().followLogs(
                            request: request
                        )
                    } catch {
                        guard !isLiveForLogFollow(id: id) else {
                            throw error
                        }
                    }
                }
                return Self.logHandle(
                    for: try await nativeLogReader(
                        containerID: id,
                        bundle: bundle,
                        configuration: state.snapshot.configuration,
                        options: options,
                        includeRotated: true,
                        follow: true
                    )
                )
            }
            return try Self.followLogFile(for: bundle.containerLog, options: options)
        } catch {
            throw Self.logReadError(error, operation: "follow container logs")
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
            let state = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            if !state.snapshot.configuration.logging.isLegacy {
                let reader = try await nativeLogReader(
                    containerID: id,
                    bundle: bundle,
                    configuration: state.snapshot.configuration,
                    options: options,
                    includeRotated: replay.includeRotated
                )
                return try await Self.logRecords(from: reader)
            }
            let data = try Self.logData(from: Self.logReplayURLs(for: bundle.containerLogRecords, includeRotated: replay.includeRotated))
            return try Self.filteredLogRecords(data, options: options)
        } catch {
            throw Self.logReadError(error, operation: "open container log records")
        }
    }

    /// Stream a finite newline-delimited record file for the container.
    public func logRecordFile(
        id: String,
        replay: ContainerLogReplayOptions = .default
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
            let state = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            if !state.snapshot.configuration.logging.isLegacy {
                let reader = try await nativeLogReader(
                    containerID: id,
                    bundle: bundle,
                    configuration: state.snapshot.configuration,
                    options: .default,
                    includeRotated: replay.includeRotated
                )
                return Self.logRecordHandle(for: reader)
            }
            let urls = Self.logReplayURLs(
                for: bundle.containerLogRecords,
                includeRotated: replay.includeRotated
            )
            return try Self.concatenatedFileHandle(for: urls)
        } catch {
            throw Self.logReadError(error, operation: "open container log record file")
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
            let state = try _getContainerState(id: id)
            let path = try Self.containerPath(root: self.containerRoot, id: id)
            let bundle = ContainerResource.Bundle(path: path)
            if !state.snapshot.configuration.logging.isLegacy {
                if !Self.requiresAuthorityLogReader(
                    state.snapshot.configuration
                ), isLiveForLogFollow(id: id) {
                    do {
                        let request = try Self.nativeLogReadRequest(
                            options: options,
                            follow: true
                        )
                        return try await state.getClient().followLogRecords(
                            request: request
                        )
                    } catch {
                        guard !isLiveForLogFollow(id: id) else {
                            throw error
                        }
                    }
                }
                return Self.logRecordHandle(
                    for: try await nativeLogReader(
                        containerID: id,
                        bundle: bundle,
                        configuration: state.snapshot.configuration,
                        options: options,
                        includeRotated: true,
                        follow: true
                    )
                )
            }
            return try Self.followLogRecordFile(
                for: bundle.containerLogRecords,
                options: options,
                isLive: { await self.isLiveForLogFollow(id: id) }
            )
        } catch {
            throw Self.logReadError(error, operation: "follow container log records")
        }
    }

    /// Preserves the stable public category for a configured driver whose
    /// history cannot be read, while retaining contextual failures for every
    /// other log operation.
    static func logReadError(_ error: any Error, operation: String) -> ContainerizationError {
        if let readerError = error as? ContainerLogReaderError,
            readerError == .configuredDriverDoesNotSupportReading
        {
            return ContainerizationError(
                .unsupported,
                message: "configured logging driver does not support reading"
            )
        }
        if let containerError = error as? ContainerizationError,
            containerError.code == .unsupported
        {
            return containerError
        }
        return ContainerizationError(
            .internalError,
            message: "failed to \(operation): \(error)"
        )
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

    private static func requiresAuthorityLogReader(
        _ configuration: ContainerConfiguration
    ) -> Bool {
        guard let resolved = configuration.logging.resolved else {
            return false
        }
        return resolved.readPolicy.source == .direct
            && resolved.providerIdentity.kind != .core
    }

    private func nativeLogReader(
        containerID: String,
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        options: ContainerLogOptions,
        includeRotated: Bool,
        follow: Bool = false
    ) async throws -> any ContainerLogReader {
        let request = try Self.nativeLogReadRequest(
            options: options,
            follow: follow
        )
        if Self.requiresAuthorityLogReader(configuration) {
            guard let remoteLogDriverPlane else {
                throw ContainerizationError(
                    .invalidState,
                    message: "direct logging provider is unavailable"
                )
            }
            var protectedOptions = [String: String]()
            if let reference = configuration.logging.resolved?
                .protectedOptionReference
            {
                let binding = try LoggingProtectedOptionsBinding(
                    containerID: containerID,
                    configuration: configuration.logging
                )
                protectedOptions = try await loggingProtectedOptionsStore.load(
                    reference,
                    boundTo: binding
                )
            }
            return try await remoteLogDriverPlane.openReader(
                containerID: containerID,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: protectedOptions,
                read: request
            )
        }
        return try ContainerLogNativeReaderFactory.makeReader(
            bundle: bundle,
            configuration: configuration,
            request: request,
            source: .stoppedContainer,
            includeRotated: includeRotated
        )
    }

    private static func nativeLogReadRequest(
        options: ContainerLogOptions,
        follow: Bool
    ) throws -> ContainerLogReadRequest {
        let tail = options.tail.flatMap { $0 < 0 ? nil : $0 }
        return try ContainerLogReadRequest(
            follow: follow,
            tail: tail,
            since: options.since,
            until: options.until
        )
    }

    private nonisolated static func logHandle(
        for reader: any ContainerLogReader
    ) -> FileHandle {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        Task.detached(priority: .utility) {
            defer { try? writer.close() }
            do {
                while true {
                    switch try await reader.next() {
                    case .record(let record):
                        try writer.write(contentsOf: record.data)
                    case .endOfStream:
                        return
                    }
                }
            } catch {
                await reader.cancel()
            }
        }
        return pipe.fileHandleForReading
    }

    private static func logRecords(
        from reader: any ContainerLogReader
    ) async throws -> [ContainerLogRecord] {
        var records = [ContainerLogRecord]()
        while true {
            switch try await reader.next() {
            case .record(let record):
                records.append(
                    ContainerLogRecord(
                        timestamp: Date(
                            timeIntervalSince1970:
                                Double(record.timestamp.secondsSinceUnixEpoch)
                                + Double(record.timestamp.nanoseconds)
                                / 1_000_000_000
                        ),
                        stream: record.stream == .stdout ? .stdout : .stderr,
                        data: record.data
                    )
                )
            case .endOfStream:
                return records
            }
        }
    }

    private nonisolated static func logRecordHandle(
        for reader: any ContainerLogReader
    ) -> FileHandle {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        Task.detached(priority: .utility) {
            defer { try? writer.close() }
            let encoder = JSONEncoder()
            do {
                while true {
                    switch try await reader.next() {
                    case .record(let record):
                        let encoded = try encoder.encode(
                            ContainerLogRecord(
                                timestamp: Date(
                                    timeIntervalSince1970:
                                        Double(record.timestamp.secondsSinceUnixEpoch)
                                        + Double(record.timestamp.nanoseconds)
                                        / 1_000_000_000
                                ),
                                stream: record.stream == .stdout ? .stdout : .stderr,
                                data: record.data
                            )
                        )
                        try writer.write(contentsOf: encoded)
                        try writer.write(contentsOf: Data([UInt8(ascii: "\n")]))
                    case .endOfStream:
                        return
                    }
                }
            } catch {
                await reader.cancel()
            }
        }
        return pipe.fileHandleForReading
    }

    private nonisolated static func concatenatedFileHandle(
        for urls: [URL]
    ) throws -> FileHandle {
        let handles = try urls.map(FileHandle.init(forReadingFrom:))
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        Task.detached(priority: .utility) {
            defer {
                try? writer.close()
                for handle in handles {
                    try? handle.close()
                }
            }
            do {
                for handle in handles {
                    while let bytes = try handle.read(upToCount: 64 * 1024),
                        !bytes.isEmpty
                    {
                        try writer.write(contentsOf: bytes)
                    }
                }
            } catch {
                return
            }
        }
        return pipe.fileHandleForReading
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
        try await withLifecycleMutation(id: id) {
            try await self.deleteImpl(id: id, force: force)
        }
    }

    private func deleteImpl(id: String, force: Bool) async throws {
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
            let previousLifecycleState = try lifecyclePublicState(id: id)
            let removalLifecycle = try await commitLifecycle(
                id: id,
                from: state,
                publicState: .removing,
                intent: { $0.removalRequested = true }
            )
            do {
                try await client.stop(options: opts)
            } catch let error as ContainerizationError where error.code == .interrupted {
                // The runtime service can disappear before replying after a
                // successful forced stop. Continue with removal cleanup.
            } catch {
                try await rollbackRemovalIntent(
                    id: id,
                    fallbackState: state,
                    publicState: previousLifecycleState,
                    error: error
                )
                throw error
            }
            events = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                var stoppedSnapshot = state.snapshot
                stoppedSnapshot.status = .stopped
                stoppedSnapshot.networks = []
                stoppedSnapshot.health = nil
                stoppedSnapshot.exitCode = 128 + Signal.kill.rawValue
                stoppedSnapshot.exitedDate = .now
                var stoppedState = state
                stoppedState.snapshot = stoppedSnapshot
                stoppedState.client = nil
                await self.setContainerState(id, stoppedState, context: context)
                await self.completeDockerContainerWaiters(
                    id: id,
                    snapshot: stoppedSnapshot,
                    completion: .exited
                )
                self.log.info(
                    "ContainersService: attempt cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                do {
                    try await self.cleanUp(id: id, context: context)
                } catch {
                    try await self.recordCleanupFailure(
                        id: id,
                        from: stoppedState,
                        underlyingError: error
                    )
                }
                self.log.info(
                    "ContainersService: successful cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                return Self.stampEvents(
                    [
                        Self.killEvent(
                            snapshot: stoppedSnapshot,
                            processID: id,
                            signal: Signal.kill.rawValue,
                            requestedSignal: "SIGKILL"
                        )
                    ] + Self.terminalLifecycleEvents(snapshot: stoppedSnapshot)
                        + Self.removalEvents(snapshot: stoppedSnapshot),
                    with: removalLifecycle
                )
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
                let removalLifecycle = try await self.commitLifecycle(
                    id: id,
                    from: current,
                    publicState: .removing,
                    intent: { $0.removalRequested = true }
                )
                do {
                    try await self.cleanUp(id: id, context: context)
                } catch {
                    try await self.recordCleanupFailure(
                        id: id,
                        from: current,
                        underlyingError: error
                    )
                }
                return Self.stampEvents(
                    Self.removalEvents(snapshot: current.snapshot),
                    with: removalLifecycle
                )
            }
        }

        for event in events {
            await publishEvent(event)
        }
        if containers[id] == nil {
            lifecycleRecords.removeValue(forKey: id)
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

        switch state.snapshot.status {
        case .running:
            let client = try state.getClient()
            let snapshot = FileManager.default.temporaryDirectory
                .appendingPathComponent("container-live-export-\(UUID().uuidString).ext4")
            defer {
                try? FileManager.default.removeItem(at: snapshot)
            }
            try await client.snapshotDisk(imagePath: rootfs.path, destinationPath: snapshot.path, noFreeze: noFreeze)
            try EXT4.EXT4Reader(blockDevice: FilePath(snapshot)).export(archive: FilePath(archive))
        case .stopped:
            try EXT4.EXT4Reader(blockDevice: FilePath(rootfs)).export(archive: FilePath(archive))
        default:
            throw ContainerizationError(.invalidState, message: "container must be running or stopped")
        }
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

    private func handleContainerExit(
        id: String,
        code: ExitStatus? = nil,
        runtimeClientToken: UUID? = nil
    ) async throws {
        try await withLifecycleMutation(id: id) {
            guard
                runtimeClientToken == nil
                    || self.runtimeClientTokens[id] == runtimeClientToken
            else {
                return
            }
            try await self.handleContainerExitImpl(id: id, code: code)
        }
    }

    private func handleContainerExitImpl(id: String, code: ExitStatus? = nil) async throws {
        let events = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { [self] context in
            try await handleContainerExit(id: id, code: code, context: context)
        }
        for event in events {
            await publishEvent(event)
        }
        if containers[id] == nil {
            lifecycleRecords.removeValue(forKey: id)
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

        self.runtimeClientTokens.removeValue(forKey: id)
        await self.exitMonitor.stopTracking(id: id)
        self.stopHealthCheckMonitor(id: id)

        // Shutdown and deregister the runtime service
        self.log.info("shutting down runtime service", metadata: ["id": "\(id)"])

        let path = try Self.containerPath(root: self.containerRoot, id: id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let options = try getContainerCreationOptions(id: id)
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: config.runtimeHandler,
            instanceId: id
        )

        var observedOOMKillCount: UInt64?
        if let client = state.client {
            observedOOMKillCount = try? await client.statistics().memoryOOMKillCount
        }

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

        do {
            try await self.remoteLogDriverPlane?.close(containerID: id)
        } catch {
            self.log.error(
                "failed to close remote logging provider session",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ]
            )
        }

        state.snapshot.status = .stopped
        state.snapshot.networks = []
        state.snapshot.health = nil
        if let code {
            state.snapshot.exitCode = code.exitCode
            state.snapshot.exitedDate = code.exitedAt
        }
        state.client = nil

        await self.setContainerState(id, state, context: context)
        self.completeDockerContainerWaiters(
            id: id,
            snapshot: state.snapshot,
            completion: .exited
        )

        if let startedDate = state.snapshot.startedDate {
            do {
                try bundle.setDurably(
                    lifecycleState: ContainerLifecycleStateV1(
                        startedDate: startedDate,
                        exitCode: state.snapshot.exitCode,
                        exitedDate: state.snapshot.exitedDate
                    )
                )
            } catch {
                self.log.error(
                    "failed to persist legacy container exit state",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
            }
        }

        let explicitExitCause = explicitExitCauses.removeValue(forKey: id)
        if explicitExitCause == .kill {
            state.restart.markManuallyStopped()
        }
        let restartDelay = state.restart.restartDelay(
            policy: options.restartPolicy,
            exitCode: code?.exitCode
        )
        // restartDelay mutates the retry count/backoff; publish that state even
        // if the following disk write fails.
        await self.setContainerState(id, state, context: context)
        let willRestart = restartDelay != nil
        let explicitRestart = explicitExitCause == .restart
        let lifecycle: ContainerResource.ContainerLifecycleRecordV2
        var recoveredFromPersistenceFailure = false
        do {
            lifecycle = try await commitLifecycle(
                id: id,
                from: state,
                publicState: explicitRestart || willRestart ? .restarting : .exited,
                incrementRestartCount: willRestart,
                restartConsecutiveFailureCount: state.restart.consecutiveFailures,
                observedOOMKillCount: observedOOMKillCount ?? nil,
                intent: { intent in
                    intent.manualRestartSuppressed = explicitExitCause != nil
                }
            )
        } catch {
            guard let existingLifecycle = lifecycleRecords[id] else {
                throw error
            }
            lifecycle = Self.recoveredLifecycleAfterExitPersistenceFailure(
                existingLifecycle,
                exitCode: state.snapshot.exitCode,
                startedAt: state.snapshot.startedDate,
                finishedAt: state.snapshot.exitedDate,
                health: state.snapshot.health?.rawValue,
                restartConsecutiveFailureCount: state.restart.consecutiveFailures,
                observedOOMKillCount: observedOOMKillCount,
                manualRestartSuppressed: explicitExitCause != nil,
                persistenceError: String(describing: error)
            )
            lifecycleRecords[id] = lifecycle
            recoveredFromPersistenceFailure = true
            self.log.error(
                "failed to persist lifecycle v2 exit state; retained stopped state in memory",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
            if !explicitRestart {
                let recoveryAction: ExitPersistenceRecoveryAction
                if options.autoRemove {
                    recoveryAction = .remove
                } else if let restartDelay {
                    recoveryAction = .restart(
                        delayInNanoseconds: restartDelay
                    )
                } else {
                    recoveryAction = .none
                }
                scheduleExitPersistenceRecovery(
                    id: id,
                    expectedOperationGeneration: lifecycle.snapshot.operationGeneration,
                    terminalPublicState: willRestart ? .restarting : .exited,
                    incrementRestartCount: willRestart,
                    observedOOMKillCount: observedOOMKillCount,
                    manualRestartSuppressed: explicitExitCause != nil,
                    action: recoveryAction
                )
            }
        }
        var terminalEvents =
            lifecycle.snapshot.oomKilled
            ? [Self.containerEvent(action: "oom", snapshot: state.snapshot)] : []
        terminalEvents += Self.terminalLifecycleEvents(
            snapshot: state.snapshot,
            explicitCause: explicitExitCause
        )
        terminalEvents = Self.stampEvents(terminalEvents, with: lifecycle)
        guard !recoveredFromPersistenceFailure else {
            return terminalEvents
        }
        if options.autoRemove {
            let removalLifecycle: ContainerResource.ContainerLifecycleRecordV2
            do {
                removalLifecycle = try await commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .removing,
                    intent: { $0.removalRequested = true }
                )
                try await self.cleanUp(id: id, context: context)
            } catch {
                let removalError = error
                let recoveryLifecycle = lifecycleRecords[id] ?? lifecycle
                scheduleExitPersistenceRecovery(
                    id: id,
                    expectedOperationGeneration: recoveryLifecycle.snapshot.operationGeneration,
                    terminalPublicState: lifecycle.snapshot.state,
                    incrementRestartCount: false,
                    observedOOMKillCount: observedOOMKillCount,
                    manualRestartSuppressed: explicitExitCause != nil,
                    terminalError: lifecycle.snapshot.error,
                    action: .remove,
                    terminalPersisted: true,
                    removalLifecycle: recoveryLifecycle.snapshot.removalInProgress
                        ? recoveryLifecycle : nil
                )
                log.error(
                    "failed to complete automatic removal; retrying",
                    metadata: ["id": "\(id)", "error": "\(removalError)"]
                )
                return terminalEvents
            }
            return terminalEvents
                + Self.stampEvents(
                    Self.removalEvents(snapshot: state.snapshot),
                    with: removalLifecycle
                )
        }
        if let restartDelay {
            self.scheduleRestart(id: id, delayInNanoseconds: restartDelay)
        }
        return terminalEvents
    }

    /// Returns immediately only for Docker's `not-running` condition and a
    /// snapshot that no longer owns a live init process.
    static func dockerWaitResult(
        snapshot: ContainerSnapshot,
        condition: DockerContainerWaitCondition
    ) -> DockerContainerWaitResult? {
        guard condition == .notRunning,
            !Self.dockerWaitRequiresLiveProcess(snapshot.status)
        else {
            return nil
        }
        return DockerContainerWaitResult(statusCode: snapshot.exitCode ?? 0)
    }

    static func dockerWaitCompletes(
        condition: DockerContainerWaitCondition,
        completion: DockerContainerWaitCompletion
    ) -> Bool {
        switch completion {
        case .exited:
            condition == .notRunning || condition == .nextExit
        case .removed:
            true
        }
    }

    private static func dockerWaitRequiresLiveProcess(
        _ status: RuntimeStatus
    ) -> Bool {
        switch status {
        case .running, .paused, .stopping:
            true
        case .unknown, .stopped:
            false
        }
    }

    private func completeDockerContainerWaiters(
        id: String,
        snapshot: ContainerSnapshot,
        completion: DockerContainerWaitCompletion
    ) {
        guard let waiters = dockerContainerWaiters[id] else {
            return
        }
        let result = DockerContainerWaitResult(statusCode: snapshot.exitCode ?? 0)
        var remaining = [UUID: DockerContainerWaiter]()
        for (waiterID, waiter) in waiters {
            if Self.dockerWaitCompletes(
                condition: waiter.condition,
                completion: completion
            ) {
                waiter.continuation.resume(returning: result)
            } else {
                remaining[waiterID] = waiter
            }
        }
        if remaining.isEmpty {
            dockerContainerWaiters.removeValue(forKey: id)
        } else {
            dockerContainerWaiters[id] = remaining
        }
    }

    private func cancelDockerContainerWaiter(
        id: String,
        waiterID: UUID
    ) {
        guard var waiters = dockerContainerWaiters[id],
            let waiter = waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        if waiters.isEmpty {
            dockerContainerWaiters.removeValue(forKey: id)
        } else {
            dockerContainerWaiters[id] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private static func fullLaunchdServiceLabel(runtimeName: String, instanceId: String) -> String {
        "\(Self.launchdDomainString)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    /// Natural exit emits only `die`; an explicit stop/restart additionally
    /// emits `stop`. Kill already emits its request event at signal delivery.
    static func terminalLifecycleEvents(
        snapshot: ContainerSnapshot,
        explicitCause: ExplicitExitCause? = nil
    ) -> [ContainerEvent] {
        var exitAttributes = [String: String]()
        if let exitCode = snapshot.exitCode {
            exitAttributes["exitCode"] = "\(exitCode)"
        }
        var events = [
            containerEvent(action: "die", snapshot: snapshot, additionalAttributes: exitAttributes)
        ]
        if explicitCause == .stop || explicitCause == .restart {
            events.append(containerEvent(action: "stop", snapshot: snapshot))
        }
        return events
    }

    /// Docker publishes one terminal destroy action for container removal.
    static func removalEvents(snapshot: ContainerSnapshot) -> [ContainerEvent] {
        [containerEvent(action: "destroy", snapshot: snapshot)]
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
        attributes["name"] = snapshot.configuration.dockerName ?? snapshot.id
        attributes["status"] = snapshot.status.rawValue
        attributes["health"] = snapshot.health?.rawValue
        attributes.merge(additionalAttributes) { _, additional in additional }
        return ContainerEvent(
            type: "container",
            id: snapshot.configuration.dockerID ?? snapshot.id,
            action: action,
            attributes: attributes
        )
    }

    static func stampEvents(
        _ events: [ContainerEvent],
        with lifecycle: ContainerResource.ContainerLifecycleRecordV2
    ) -> [ContainerEvent] {
        events.map { source in
            var event = source
            event.transitionRevision = lifecycle.snapshot.transitionRevision
            event.operationGeneration = lifecycle.snapshot.operationGeneration
            return event
        }
    }

    private func publishContainerEvent(action: String, snapshot: ContainerSnapshot) async {
        await publishEvent(Self.containerEvent(action: action, snapshot: snapshot))
    }

    private func publishEvent(_ sourceEvent: ContainerEvent) async {
        var event = sourceEvent
        if event.transitionRevision == 0,
            event.operationGeneration == 0,
            let record = lifecycleRecords.values.first(where: {
                $0.containerID == event.id || $0.immutableBundleKey == event.id
            })
        {
            event.transitionRevision = record.snapshot.transitionRevision
            event.operationGeneration = record.snapshot.operationGeneration
        }
        await eventBroadcaster.publish(event)
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
        self.runtimeClientTokens.removeValue(forKey: id)
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
            try await releaseNetworkAttachments(configuration: config)
        }
        try await self.remoteLogDriverPlane?.close(containerID: id)

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

        let removedSnapshot = self.containers[id]?.snapshot
        self.containers.removeValue(forKey: id)
        self.explicitExitCauses.removeValue(forKey: id)
        if let removedSnapshot {
            self.completeDockerContainerWaiters(
                id: id,
                snapshot: removedSnapshot,
                completion: .removed
            )
        }

        do {
            try await remoteLogDriverPlane?.reconcileProtectedEffects(
                containerRoot: containerRoot
            )
        } catch {
            log.warning(
                "protected logging effects remain queued for orphan reconciliation",
                metadata: ["id": "\(id)"]
            )
        }

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

    static func persistContainerConfiguration(
        _ configuration: ContainerConfiguration,
        options: ContainerCreateOptions? = nil,
        at path: URL
    ) throws {
        let bundle = ContainerResource.Bundle(path: path)
        if FileManager.default.fileExists(
            atPath: bundle.filePath(for: "config.json").path
        ) {
            try bundle.setDurably(configuration: configuration)
            if let options {
                try bundle.writeDurably(
                    filename: "options.json",
                    value: options
                )
            }
            return
        }

        let runtime = try RuntimeConfiguration.readRuntimeConfiguration(
            from: path
        )
        let updated = RuntimeConfiguration(
            path: runtime.path,
            initialFilesystem: runtime.initialFilesystem,
            kernel: runtime.kernel,
            containerConfiguration: configuration,
            containerRootFilesystem: runtime.containerRootFilesystem,
            options: options ?? runtime.options,
            runtimeData: runtime.runtimeData
        )
        try bundle.writeDurably(
            filename: "runtime-configuration.json",
            value: updated
        )
    }

    /// Release durable attachment leases only when the container itself is removed.
    private func releaseNetworkAttachments(configuration: ContainerConfiguration) async throws {
        guard !configuration.networks.isEmpty else {
            return
        }
        guard let networksService else {
            throw ContainerizationError(
                .internalError,
                message: "cannot release network attachments without the networks service"
            )
        }
        for attachment in configuration.networks {
            try await networksService.releaseAttachment(
                network: attachment.network,
                hostname: attachment.options.hostname
            )
        }
    }

    private func getContainerCreationOptions(id: String) throws -> ContainerCreateOptions {
        let path = try Self.containerPath(root: self.containerRoot, id: id)
        let bundle = ContainerResource.Bundle(path: path)
        if let options: ContainerCreateOptions = try? bundle.load(
            filename: "options.json"
        ) {
            return options
        }
        return try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            .options ?? .default
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

    private func protectedContainerSnapshots() -> [ContainerSnapshot] {
        self.containers.values.map(\.snapshot) + self.pendingCreations.snapshots
    }

    private func reserveContainerCreation(
        _ snapshot: ContainerSnapshot,
        path: URL,
        context _: AsyncLock.Context
    ) throws {
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw ContainerizationError(
                .exists,
                message: "container bundle already exists: \(snapshot.id)"
            )
        }

        try self.pendingCreations.reserve(
            snapshot,
            existing: self.containers.values.map(\.snapshot),
            reservedNames: quarantinedContainerNames
        )

        do {
            try Task.checkCancellation()
            guard self.runtimePlugins.contains(where: { $0.name == snapshot.configuration.runtimeHandler }) else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(snapshot.configuration.runtimeHandler)"
                )
            }
            try Self.validateBootableMemory(snapshot.configuration.resources.memoryInBytes)
        } catch {
            self.pendingCreations.remove(snapshot.id)
            throw error
        }
    }

    private func commitContainerCreation(
        _ snapshot: ContainerSnapshot,
        lifecycleRecord: ContainerResource.ContainerLifecycleRecordV2,
        context _: AsyncLock.Context
    ) throws {
        try Task.checkCancellation()
        guard self.pendingCreations.remove(snapshot.id) != nil else {
            throw ContainerizationError(
                .internalError,
                message: "container creation reservation not found: \(snapshot.id)"
            )
        }
        self.lifecycleRecords[snapshot.id] = lifecycleRecord
        self.containers[snapshot.id] = ContainerState(snapshot: snapshot)
    }

    private func rollbackContainerCreation(
        _ id: String,
        context _: AsyncLock.Context
    ) {
        self.pendingCreations.remove(id)
    }

    private func setLifecycleRecord(
        _ record: ContainerResource.ContainerLifecycleRecordV2,
        id: String
    ) {
        lifecycleRecords[id] = record
    }

    private func setRuntimeClientToken(_ token: UUID, id: String) {
        runtimeClientTokens[id] = token
    }

    private func clearRuntimeClientToken(id: String) {
        runtimeClientTokens.removeValue(forKey: id)
    }

    private func clearRuntimeClientToken(_ token: UUID, id: String) {
        guard runtimeClientTokens[id] == token else {
            return
        }
        runtimeClientTokens.removeValue(forKey: id)
    }

    private func removeLifecycleRecord(id: String) {
        lifecycleRecords.removeValue(forKey: id)
    }

    private func lifecyclePublicState(
        id: String
    ) throws -> ContainerResource.ContainerPublicStateV2 {
        guard let record = lifecycleRecords[id] else {
            throw ContainerizationError(
                .internalError,
                message: "container \(id) has no lifecycle v2 record"
            )
        }
        return record.snapshot.state
    }

    private func hasContainer(named name: String, excluding id: String) -> Bool {
        Self.hasContainer(
            named: name,
            excluding: id,
            among: containers.values.map {
                (
                    id: $0.snapshot.id,
                    dockerName: $0.snapshot.configuration.dockerName,
                    dockerID: $0.snapshot.configuration.dockerID
                )
            },
            reservedNames: quarantinedContainerNames
        )
    }

    static func recoveredLifecycleAfterExitPersistenceFailure(
        _ existing: ContainerResource.ContainerLifecycleRecordV2,
        exitCode: Int32?,
        startedAt: Date?,
        finishedAt: Date?,
        health: String?,
        restartConsecutiveFailureCount: UInt32,
        observedOOMKillCount: UInt64?,
        manualRestartSuppressed: Bool,
        terminalError: String? = nil,
        persistenceError: String
    ) -> ContainerResource.ContainerLifecycleRecordV2 {
        var recovered = existing
        try? Self.advanceLifecycleRevisions(&recovered.snapshot)
        recovered.snapshot.state = .exited
        recovered.snapshot.running = false
        recovered.snapshot.paused = false
        recovered.snapshot.restarting = false
        recovered.snapshot.removalInProgress = false
        recovered.snapshot.dead = false
        recovered.snapshot.pid = 0
        recovered.snapshot.exitCode = exitCode ?? 0
        recovered.snapshot.startedAt = startedAt
        recovered.snapshot.finishedAt = finishedAt
        recovered.snapshot.health = health
        recovered.snapshot.restartConsecutiveFailureCount = restartConsecutiveFailureCount
        if let observedOOMKillCount,
            let baseline = recovered.snapshot.oomKillCountBaseline
        {
            recovered.snapshot.oomKilled = observedOOMKillCount > baseline
        }
        let persistenceMessage =
            "failed to persist lifecycle exit state: \(persistenceError)"
        recovered.snapshot.error =
            terminalError.map {
                "\($0); \(persistenceMessage)"
            } ?? persistenceMessage
        recovered.intent.manualRestartSuppressed = manualRestartSuppressed
        return recovered
    }

    static func recoveredContainerStateAfterFailedStart(
        _ preStartState: ContainerState
    ) -> ContainerState {
        var recovered = preStartState
        recovered.client = nil
        recovered.snapshot.status = .stopped
        recovered.snapshot.networks = []
        recovered.snapshot.health = nil
        return recovered
    }

    static func exitPersistenceRecoveryIsCurrent(
        currentOperationGeneration: UInt64?,
        expectedOperationGeneration: UInt64,
        status: RuntimeStatus?
    ) -> Bool {
        currentOperationGeneration == expectedOperationGeneration
            && status == .stopped
    }

    static func restartStabilityPersistenceRecoveryIsCurrent(
        status: RuntimeStatus,
        startedDate: Date?,
        expectedStartedDate: Date
    ) -> Bool {
        status == .running && startedDate == expectedStartedDate
    }

    static func lifecyclePID(
        previousPID: Int32,
        publicState: ContainerResource.ContainerPublicStateV2,
        runtimeStatus: RuntimeStatus,
        reportedPID: Int32?
    ) -> Int32 {
        guard
            publicState == .running || publicState == .paused
                || (publicState == .restarting
                    && (runtimeStatus == .running || runtimeStatus == .paused))
        else {
            return 0
        }
        return reportedPID ?? previousPID
    }

    static func hasContainer(
        named name: String,
        excluding id: String,
        among containers: [(id: String, dockerName: String?, dockerID: String?)],
        reservedNames: Set<String> = []
    ) -> Bool {
        reservedNames.contains(name)
            || containers.contains {
                $0.id != id
                    && ($0.dockerName == name || $0.dockerID == name || $0.id == name)
            }
    }

    @discardableResult
    private func commitLifecycle(
        id: String,
        from container: ContainerState,
        publicState: ContainerResource.ContainerPublicStateV2,
        error: String? = nil,
        pid: Int32? = nil,
        incrementProcessGeneration: Bool = false,
        incrementRestartCount: Bool = false,
        restartConsecutiveFailureCount: UInt32? = nil,
        resetOOMObservation: Bool = false,
        observedOOMKillCount: UInt64? = nil,
        intent: ((inout ContainerResource.ContainerLifecycleIntentV2) -> Void)? = nil
    ) async throws -> ContainerResource.ContainerLifecycleRecordV2 {
        guard var record = lifecycleRecords[id] else {
            throw ContainerizationError(
                .internalError,
                message: "container \(id) has no lifecycle v2 record"
            )
        }
        try Self.advanceLifecycleRevisions(&record.snapshot)
        if incrementProcessGeneration {
            record.snapshot.processGeneration = try Self.nextLifecycleCounter(
                record.snapshot.processGeneration ?? 0,
                named: "process generation"
            )
        }
        if incrementRestartCount {
            record.snapshot.restartCount = try Self.nextLifecycleCounter(
                record.snapshot.restartCount,
                named: "restart count"
            )
        }
        if let restartConsecutiveFailureCount {
            record.snapshot.restartConsecutiveFailureCount = restartConsecutiveFailureCount
        }
        if resetOOMObservation {
            record.snapshot.oomKillCountBaseline = observedOOMKillCount
            record.snapshot.oomKilled = false
        } else if let observedOOMKillCount,
            let baseline = record.snapshot.oomKillCountBaseline
        {
            record.snapshot.oomKilled = observedOOMKillCount > baseline
        }
        record.snapshot.state = publicState
        record.snapshot.running =
            publicState == .running || publicState == .paused
            || publicState == .restarting
        record.snapshot.paused = publicState == .paused
        record.snapshot.restarting = publicState == .restarting
        record.snapshot.removalInProgress = publicState == .removing
        record.snapshot.dead = publicState == .dead
        record.snapshot.pid = Self.lifecyclePID(
            previousPID: record.snapshot.pid,
            publicState: publicState,
            runtimeStatus: container.snapshot.status,
            reportedPID: pid
        )
        record.snapshot.exitCode = container.snapshot.exitCode ?? 0
        record.snapshot.error = error ?? container.dockerStateError
        record.snapshot.startedAt = container.snapshot.startedDate
        record.snapshot.finishedAt = container.snapshot.exitedDate
        record.snapshot.health = container.snapshot.health?.rawValue
        intent?(&record.intent)

        let bundle = ContainerResource.Bundle(
            path: try Self.containerPath(root: containerRoot, id: id)
        )
        try bundle.setDurably(lifecycleRecordV2: record)
        lifecycleRecords[id] = record
        return record
    }

    private func recordCleanupFailure(
        id: String,
        from container: ContainerState,
        underlyingError: any Error
    ) async throws -> Never {
        do {
            try await commitLifecycle(
                id: id,
                from: container,
                publicState: .dead,
                error: String(describing: underlyingError),
                intent: { $0.removalRequested = true }
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message:
                    "cleanup failed: \(underlyingError); failed to record dead state: \(error)"
            )
        }
        throw underlyingError
    }

    private static func makeLifecycleRecord(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions
    ) -> ContainerResource.ContainerLifecycleRecordV2 {
        ContainerResource.ContainerLifecycleRecordV2(
            containerID: configuration.dockerID
                ?? ContainerResource.ContainerLifecycleRecordV2.migrate(
                    bundleKey: configuration.id,
                    canonicalName: configuration.dockerName ?? configuration.id,
                    selectedProviderFingerprint: configuration.runtimeHandler,
                    legacy: nil
                ).containerID,
            canonicalName: configuration.dockerName ?? configuration.id,
            immutableBundleKey: configuration.id,
            selectedProviderFingerprint: configuration.runtimeHandler,
            intent: ContainerResource.ContainerLifecycleIntentV2(
                autoRemove: options.autoRemove,
                restartPolicy: options.restartPolicy
            ),
            snapshot: ContainerResource.ContainerLifecycleSnapshotV2(
                state: .created
            )
        )
    }

    func recordDockerStartError(
        containerID: String,
        error: String
    ) async {
        await self.lock.withLock(logMetadata: ["acquirer": "\\(#function)", "id": "\\(containerID)"]) { context in
            guard var state = try? await self.getContainerState(id: containerID, context: context),
                state.snapshot.status == .stopped
            else {
                return
            }
            do {
                let path = try Self.containerPath(root: self.containerRoot, id: containerID)
                try ContainerResource.Bundle(path: path).setDurably(
                    dockerState: ContainerDockerStateV1(error: error)
                )
                state.dockerStateError = error
                let publicState = try await self.lifecyclePublicState(
                    id: containerID
                )
                try await self.commitLifecycle(
                    id: containerID,
                    from: state,
                    publicState: publicState,
                    error: error
                )
                await self.setContainerState(containerID, state, context: context)
            } catch {
                self.log.error(
                    "failed to persist Docker start error",
                    metadata: ["id": "\\(containerID)", "error": "\\(error)"]
                )
            }
        }
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
        let state = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self.getContainerState(id: id, context: context)
            state.restart.markManuallyStopped()
            await self.setContainerState(id, state, context: context)
            return state
        }
        cancelRestartTasks(id: id)
        return state
    }

    private func restoreContainerRestartEligibility(id: String) async -> ContainerState? {
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            guard var state = try? await self.getContainerState(id: id, context: context) else {
                return nil
            }
            state.restart.restoreAutomaticRestartEligibility()
            await self.setContainerState(id, state, context: context)
            return state
        }
    }

    private func rollbackManualTerminationIntent(
        id: String,
        fallbackState: ContainerState,
        publicState: ContainerResource.ContainerPublicStateV2,
        error: any Error
    ) async throws {
        explicitExitCauses.removeValue(forKey: id)
        let recoveredState = await restoreContainerRestartEligibility(id: id) ?? fallbackState
        do {
            try await commitLifecycle(
                id: id,
                from: recoveredState,
                publicState: publicState,
                error: String(describing: error),
                intent: { $0.manualRestartSuppressed = false }
            )
            restoreRestartStabilityResetIfNeeded(
                id: id,
                state: recoveredState,
                publicState: publicState
            )
        } catch let rollbackError {
            throw ContainerizationError(
                .internalError,
                message:
                    "manual termination failed: \(error); failed to roll back durable intent: \(rollbackError)"
            )
        }
    }

    private func restorePausedRuntimeAfterFailedRestart(
        id: String,
        client: RuntimeClient,
        restartError: any Error
    ) async throws {
        do {
            if try await client.state().status != .paused {
                try await client.pause()
            }
        } catch {
            let pauseError = error
            explicitExitCauses.removeValue(forKey: id)
            await markContainerRestartFailed(
                id: id,
                error:
                    "restart failed: \(restartError); failed to restore paused runtime: \(pauseError)"
            )
            throw ContainerizationError(
                .internalError,
                message:
                    "restart failed: \(restartError); failed to restore paused runtime: \(pauseError)"
            )
        }
    }

    private func restoreRestartStabilityResetIfNeeded(
        id: String,
        state: ContainerState,
        publicState: ContainerResource.ContainerPublicStateV2
    ) {
        guard publicState == .running,
            state.restart.consecutiveFailures > 0,
            let startedDate = state.snapshot.startedDate,
            let record = lifecycleRecords[id]
        else {
            return
        }
        let duration = ContainerRestartTracker.stableRunDuration(
            for: record.intent.restartPolicy
        )
        scheduleRestartStabilityReset(
            id: id,
            startedDate: startedDate,
            durationInNanoseconds: Self.remainingRestartStabilityDuration(
                startedDate: startedDate,
                durationInNanoseconds: duration
            )
        )
    }

    private func rollbackRemovalIntent(
        id: String,
        fallbackState: ContainerState,
        publicState: ContainerResource.ContainerPublicStateV2,
        error: any Error
    ) async throws {
        do {
            try await commitLifecycle(
                id: id,
                from: fallbackState,
                publicState: publicState,
                error: String(describing: error),
                intent: { $0.removalRequested = false }
            )
        } catch let rollbackError {
            throw ContainerizationError(
                .internalError,
                message:
                    "forced removal failed: \(error); failed to roll back durable intent: \(rollbackError)"
            )
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
        await publishEvent(event)
    }

    private func scheduleRestart(id: String, delayInNanoseconds: UInt64) {
        restartTasks[id]?.cancel()
        let token = UUID()
        restartTaskTokens[id] = token
        restartTasks[id] = Task {
            await self.runScheduledRestart(id: id, token: token, delayInNanoseconds: delayInNanoseconds)
        }
    }

    private func scheduleExitPersistenceRecovery(
        id: String,
        expectedOperationGeneration: UInt64,
        terminalPublicState: ContainerResource.ContainerPublicStateV2,
        incrementRestartCount: Bool,
        observedOOMKillCount: UInt64?,
        manualRestartSuppressed: Bool,
        terminalError: String? = nil,
        action: ExitPersistenceRecoveryAction,
        terminalPersisted: Bool = false,
        removalLifecycle: ContainerResource.ContainerLifecycleRecordV2? = nil
    ) {
        exitPersistenceRecoveryTasks[id]?.cancel()
        let token = UUID()
        exitPersistenceRecoveries[id] = ExitPersistenceRecovery(
            token: token,
            expectedOperationGeneration: expectedOperationGeneration,
            terminalPublicState: terminalPublicState,
            incrementRestartCount: incrementRestartCount,
            observedOOMKillCount: observedOOMKillCount,
            manualRestartSuppressed: manualRestartSuppressed,
            terminalError: terminalError,
            action: action,
            terminalPersisted: terminalPersisted,
            removalLifecycle: removalLifecycle
        )
        exitPersistenceRecoveryTasks[id] = Task {
            await self.runExitPersistenceRecovery(
                id: id,
                token: token
            )
        }
    }

    private func runExitPersistenceRecovery(
        id: String,
        token: UUID
    ) async {
        defer {
            if exitPersistenceRecoveries[id]?.token == token {
                exitPersistenceRecoveryTasks.removeValue(forKey: id)
                exitPersistenceRecoveries.removeValue(forKey: id)
            }
        }

        var retryDelay: UInt64 = 100_000_000

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.duration(fromNanoseconds: retryDelay))
                try Task.checkCancellation()
                let events = try await withLifecycleMutation(id: id) { () async throws -> [ContainerEvent]? in
                    guard self.exitPersistenceRecoveries[id]?.token == token else {
                        return nil
                    }
                    return try await self.lock.withLock(
                        logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
                    ) { context -> [ContainerEvent]? in
                        try await self.attemptExitPersistenceRecovery(
                            id: id,
                            token: token,
                            context: context
                        )
                    }
                }
                guard let events else {
                    return
                }
                for event in events {
                    await publishEvent(event)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                log.error(
                    "failed to recover lifecycle exit persistence; retrying",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
                retryDelay = min(retryDelay.multipliedReportingOverflow(by: 2).partialValue, 5_000_000_000)
            }
        }
    }

    private func attemptExitPersistenceRecovery(
        id: String,
        token: UUID,
        context: AsyncLock.Context
    ) async throws -> [ContainerEvent]? {
        guard var recovery = exitPersistenceRecoveries[id],
            recovery.token == token,
            let current = lifecycleRecords[id],
            let state = containers[id],
            Self.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: current.snapshot.operationGeneration,
                expectedOperationGeneration: recovery.expectedOperationGeneration,
                status: state.snapshot.status
            )
        else {
            return nil
        }

        if !recovery.terminalPersisted {
            let terminal = try await commitLifecycle(
                id: id,
                from: state,
                publicState: recovery.terminalPublicState,
                error: recovery.terminalError,
                incrementRestartCount: recovery.incrementRestartCount,
                restartConsecutiveFailureCount: state.restart.consecutiveFailures,
                observedOOMKillCount: recovery.observedOOMKillCount,
                intent: { intent in
                    intent.manualRestartSuppressed = recovery.manualRestartSuppressed
                }
            )
            recovery.expectedOperationGeneration = terminal.snapshot.operationGeneration
            recovery.terminalPersisted = true
            exitPersistenceRecoveries[id] = recovery
        }

        switch recovery.action {
        case .none:
            return []
        case .restart(let delayInNanoseconds):
            scheduleRestart(
                id: id,
                delayInNanoseconds: delayInNanoseconds
            )
            return []
        case .remove:
            if recovery.removalLifecycle == nil {
                let removal = try await commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .removing,
                    intent: { $0.removalRequested = true }
                )
                recovery.expectedOperationGeneration = removal.snapshot.operationGeneration
                recovery.removalLifecycle = removal
                exitPersistenceRecoveries[id] = recovery
            }
            try await cleanUp(id: id, context: context)
            lifecycleRecords.removeValue(forKey: id)
            guard let removalLifecycle = recovery.removalLifecycle else {
                return []
            }
            return Self.stampEvents(
                Self.removalEvents(snapshot: state.snapshot),
                with: removalLifecycle
            )
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
            try await withLifecycleMutation(id: id) {
                do {
                    guard self.restartTaskTokens[id] == token else {
                        return
                    }
                    guard try await self.prepareContainerForRestart(id: id) else {
                        return
                    }
                    try Task.checkCancellation()
                    guard self.restartTaskTokens[id] == token else {
                        return
                    }
                    _ = try await self.bootstrap(
                        id: id,
                        stdio: [FileHandle?](repeating: nil, count: 3),
                        dynamicEnv: [:],
                        onlyIfNeverStarted: false
                    )
                    try await self.startProcessImpl(id: id, processID: id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await self.markContainerRestartFailed(
                        id: id,
                        error: "automatic restart failed: \(error)"
                    )
                    throw error
                }
            }
        } catch is CancellationError {
            return
        } catch {
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
            let options = try await self.getContainerCreationOptions(id: id)
            let lifecycleRecords = await self.lifecycleRecords
            let lifecycle = lifecycleRecords[id]
            guard state.snapshot.status == .stopped,
                state.restart.allowsAutomaticRestart,
                Self.restartIntentAllowsPendingRestart(
                    lifecycleState: lifecycle?.snapshot.state,
                    manualRestartSuppressed: lifecycle?.intent.manualRestartSuppressed ?? false,
                    policy: options.restartPolicy,
                    exitCode: state.snapshot.exitCode,
                    restartConsecutiveFailureCount: state.restart.consecutiveFailures
                )
            else {
                return false
            }
            return true
        }
    }

    private func markContainerRestartFailed(
        id: String,
        error restartError: String
    ) async {
        runtimeClientTokens.removeValue(forKey: id)
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
            do {
                try await self.commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .exited,
                    error: restartError
                )
            } catch {
                let lifecycleRecords = await self.lifecycleRecords
                if let existingLifecycle = lifecycleRecords[id] {
                    let recoveredLifecycle = Self.recoveredLifecycleAfterExitPersistenceFailure(
                        existingLifecycle,
                        exitCode: state.snapshot.exitCode,
                        startedAt: state.snapshot.startedDate,
                        finishedAt: state.snapshot.exitedDate,
                        health: state.snapshot.health?.rawValue,
                        restartConsecutiveFailureCount: state.restart.consecutiveFailures,
                        observedOOMKillCount: nil,
                        manualRestartSuppressed: existingLifecycle.intent.manualRestartSuppressed,
                        terminalError: restartError,
                        persistenceError: String(describing: error)
                    )
                    await self.setLifecycleRecord(recoveredLifecycle, id: id)
                    await self.scheduleExitPersistenceRecovery(
                        id: id,
                        expectedOperationGeneration: recoveredLifecycle.snapshot.operationGeneration,
                        terminalPublicState: .exited,
                        incrementRestartCount: false,
                        observedOOMKillCount: nil,
                        manualRestartSuppressed: existingLifecycle.intent.manualRestartSuppressed,
                        terminalError: restartError,
                        action: .none
                    )
                }
                self.log.error(
                    "failed to record restart failure; retrying",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
            }
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

    static func remainingRestartStabilityDuration(
        startedDate: Date,
        durationInNanoseconds: UInt64,
        now: Date = Date()
    ) -> UInt64 {
        let elapsedSeconds = max(0, now.timeIntervalSince(startedDate))
        let elapsedNanoseconds = elapsedSeconds * 1_000_000_000
        guard elapsedNanoseconds < Double(durationInNanoseconds) else {
            return 0
        }
        return durationInNanoseconds - UInt64(elapsedNanoseconds.rounded(.down))
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

        var retryDelay: UInt64 = 100_000_000
        while !Task.isCancelled {
            let shouldRetry = await withLifecycleMutation(id: id) {
                await lock.withLock(
                    logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
                ) { context in
                    guard !Task.isCancelled,
                        await self.restartStabilityTokenIsCurrent(id: id, token: token),
                        var state = try? await self.getContainerState(id: id, context: context),
                        Self.restartStabilityPersistenceRecoveryIsCurrent(
                            status: state.snapshot.status,
                            startedDate: state.snapshot.startedDate,
                            expectedStartedDate: startedDate
                        )
                    else {
                        return false
                    }

                    state.restart.markStable()
                    await self.setContainerState(id, state, context: context)
                    do {
                        var record = try await self.lifecycleRecord(id: id)
                        try Self.resetRestartFailureState(&record.snapshot)
                        let path = try Self.containerPath(
                            root: self.containerRoot,
                            id: id
                        )
                        try ContainerResource.Bundle(path: path).setDurably(
                            lifecycleRecordV2: record
                        )
                        await self.setLifecycleRecord(record, id: id)
                        return false
                    } catch {
                        self.log.error(
                            "failed to persist stable restart state; retrying",
                            metadata: ["id": "\(id)", "error": "\(error)"]
                        )
                        return true
                    }
                }
            }
            guard shouldRetry else {
                return
            }
            do {
                try await Task.sleep(for: Self.duration(fromNanoseconds: retryDelay))
            } catch {
                return
            }
            retryDelay = min(
                retryDelay.multipliedReportingOverflow(by: 2).partialValue,
                5_000_000_000
            )
        }
    }

    private func restartStabilityTokenIsCurrent(id: String, token: UUID) -> Bool {
        restartStabilityTaskTokens[id] == token
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
        await withLifecycleMutation(id: id) {
            guard !Task.isCancelled else {
                return (false, nil)
            }
            return await lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                let lifecycleRecords = await self.lifecycleRecords
                guard let lifecycle = lifecycleRecords[id],
                    var state = try? await self.getContainerState(id: id, context: context),
                    Self.healthLifecycleUpdateIsCurrent(
                        runtimeStatus: state.snapshot.status,
                        lifecycleState: lifecycle.snapshot.state
                    )
                else {
                    return (false, nil)
                }
                let previousStatus = state.snapshot.health
                guard previousStatus != status else {
                    return (true, nil)
                }

                state.snapshot.health = status
                do {
                    try await self.commitLifecycle(
                        id: id,
                        from: state,
                        publicState: .running
                    )
                } catch {
                    self.log.error(
                        "failed to record container health transition; retrying on the next probe",
                        metadata: ["id": "\(id)", "error": "\(error)"]
                    )
                    return (true, nil)
                }
                await self.setContainerState(id, state, context: context)
                return (true, state.snapshot)
            }
        }
    }

    static func healthLifecycleUpdateIsCurrent(
        runtimeStatus: RuntimeStatus,
        lifecycleState: ContainerResource.ContainerPublicStateV2
    ) -> Bool {
        runtimeStatus == .running && lifecycleState == .running
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
        return state.snapshot.status == .running
            || state.snapshot.status == .paused
            || state.snapshot.status == .stopping
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

extension ContainersService: LoggingHandoffContainerPromoting {
    func promoteContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffPromotedHistorySegmentV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws {
        if let reference = container.configuration.resolved?
            .protectedOptionReference
        {
            let binding = try LoggingProtectedOptionsBinding(
                containerID: container.containerID,
                configuration: container.configuration
            )
            _ = try await loggingProtectedOptionsStore.load(
                reference,
                boundTo: binding
            )
        }

        try await lock.withLock(logMetadata: [
            "acquirer": "\(#function)",
            "id": "\(container.containerID)",
        ]) { context in
            var state = try await self.getContainerState(
                id: container.containerID,
                context: context
            )
            guard
                state.snapshot.status == .stopped,
                state.client == nil
            else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "logging handoff promotion requires a hidden stopped destination container"
                )
            }
            let placeholder = ContainerLogConfiguration(storage: .none)
            let currentLogging = state.snapshot.configuration.logging
            guard
                currentLogging == container.configuration
                    || currentLogging == placeholder
            else {
                throw ContainerizationError(
                    .exists,
                    message:
                        "logging handoff destination configuration collides with existing state"
                )
            }
            let stagedLocalEntryIDs: Set<String> = Set(
                container.histories.compactMap { staged -> String? in
                    guard staged.disposition == .importVerified else {
                        return nil
                    }
                    switch staged.kind {
                    case .dockerJSONFile, .nativeLocal, .dualCache:
                        return staged.entryID
                    default:
                        return nil
                    }
                }
            )
            guard stagedLocalEntryIDs == Set(history.map(\.entryID)) else {
                throw ContainerizationError(
                    .invalidState,
                    message: "logging handoff history set changed before promotion"
                )
            }

            let path = try Self.containerPath(
                root: self.containerRoot,
                id: container.containerID
            )
            let bundle = ContainerResource.Bundle(path: path)
            try LoggingHandoffBundleHistoryPublisher.publish(
                bundle: bundle,
                segments: history,
                transactionID:
                    "\(authorization.tokenID):\(authorization.manifestID):\(container.containerID)"
            )
            if let terminalEpoch = container.histories
                .map(\.terminalHistoryEpoch).max(),
                let maximumSequence = container.histories
                    .map(\.maximumInternalSequence).max()
            {
                try ContainerLogProcessGenerationStore(
                    directoryURL: bundle.containerLoggingV2
                ).adoptHistoryCursor(
                    terminalHistoryEpoch: terminalEpoch,
                    maximumInternalSequence: maximumSequence
                )
            }

            if currentLogging != container.configuration {
                var configuration = state.snapshot.configuration
                configuration.logging = container.configuration
                try Self.persistContainerConfiguration(
                    configuration,
                    at: path
                )
                state.snapshot.configuration = configuration
                await self.setContainerState(
                    container.containerID,
                    state,
                    context: context
                )
            }
        }
    }

    func activateContainerLogging(
        container: LoggingHandoffStagedContainerV1,
        promotionReceipt: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws {
        guard
            promotionReceipt.handoffTokenID == authorization.tokenID,
            promotionReceipt.handoffManifestID == authorization.manifestID,
            promotionReceipt.handoffManifestDigest
                == authorization.manifestDigest,
            promotionReceipt.commitDigestSHA256
                == authorization.commitDigestSHA256,
            promotionReceipt.handoffChainHeadDigestSHA256
                == authorization.handoffChainHeadDigestSHA256
        else {
            throw ContainerizationError(
                .invalidState,
                message: "logging handoff activation authorization changed"
            )
        }
        try await lock.withLock(logMetadata: [
            "acquirer": "\(#function)",
            "id": "\(container.containerID)",
        ]) { context in
            let state = try await self.getContainerState(
                id: container.containerID,
                context: context
            )
            guard
                state.snapshot.status == .stopped,
                state.client == nil,
                state.snapshot.configuration.logging
                    == container.configuration
            else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "logging handoff activation found an unpromoted destination container"
                )
            }
        }
    }
}

extension ContainersService {
    package func restartDockerContainer(
        id: String,
        timeoutSeconds: Int32?,
        signal: String? = nil
    ) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.restartDockerContainerImpl(
                id: id,
                timeoutSeconds: timeoutSeconds,
                signal: signal
            )
        }
    }

    private func restartDockerContainerImpl(
        id: String,
        timeoutSeconds: Int32?,
        signal: String?
    ) async throws {
        let initial = try _getContainerState(id: id)
        let wasPaused = initial.snapshot.status == .paused
        var stoppedRestartRollback:
            (
                state: ContainerState,
                publicState: ContainerResource.ContainerPublicStateV2,
                manualRestartSuppressed: Bool
            )?
        switch initial.snapshot.status {
        case .paused, .running:
            let state = initial
            let client = try state.getClient()
            let stopOptions = Self.resolvedStopOptions(
                ContainerStopOptions(
                    timeoutInSeconds: timeoutSeconds,
                    signal: signal
                ),
                configuredSignal: state.snapshot.configuration.stopSignal,
                configuredTimeoutInSeconds: state.snapshot.configuration.stopTimeoutInSeconds
            )
            explicitExitCauses[id] = .restart
            do {
                try await commitLifecycle(
                    id: id,
                    from: state,
                    publicState: .restarting,
                    intent: { $0.manualRestartSuppressed = true }
                )
            } catch {
                explicitExitCauses.removeValue(forKey: id)
                throw error
            }
            if wasPaused {
                do {
                    try await client.resume()
                } catch {
                    let resumeError = error
                    try await restorePausedRuntimeAfterFailedRestart(
                        id: id,
                        client: client,
                        restartError: resumeError
                    )
                    try await rollbackManualTerminationIntent(
                        id: id,
                        fallbackState: state,
                        publicState: .paused,
                        error: resumeError
                    )
                    throw resumeError
                }
            }
            do {
                _ = try await markContainerManuallyStopped(id: id)
            } catch {
                if wasPaused {
                    try await restorePausedRuntimeAfterFailedRestart(
                        id: id,
                        client: client,
                        restartError: error
                    )
                }
                try await rollbackManualTerminationIntent(
                    id: id,
                    fallbackState: state,
                    publicState: wasPaused ? .paused : .running,
                    error: error
                )
                throw error
            }
            do {
                try await client.stop(options: stopOptions)
            } catch let error as ContainerizationError where error.code == .interrupted {
                // The runtime service can disappear before replying after a
                // successful stop. Continue through exit handling, matching
                // the ordinary stop path.
            } catch {
                if wasPaused {
                    try await restorePausedRuntimeAfterFailedRestart(
                        id: id,
                        client: client,
                        restartError: error
                    )
                }
                try await rollbackManualTerminationIntent(
                    id: id,
                    fallbackState: state,
                    publicState: wasPaused ? .paused : .running,
                    error: error
                )
                throw error
            }
            do {
                try await handleContainerExitImpl(id: id)
            } catch {
                explicitExitCauses.removeValue(forKey: id)
                await markContainerRestartFailed(
                    id: id,
                    error: "restart exit handling failed: \(error)"
                )
                throw error
            }
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is stopping"
            )
        case .unknown:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) requires removal recovery"
            )
        case .stopped:
            let lifecycle = try lifecycleRecord(id: id)
            guard
                Self.lifecycleMayBootstrap(
                    removalRequested: lifecycle.intent.removalRequested,
                    removalInProgress: lifecycle.snapshot.removalInProgress
                )
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) requires removal recovery"
                )
            }
            try await commitLifecycle(
                id: id,
                from: initial,
                publicState: .restarting,
                intent: { $0.manualRestartSuppressed = true }
            )
            stoppedRestartRollback = (
                state: initial,
                publicState: lifecycle.snapshot.state,
                manualRestartSuppressed: lifecycle.intent.manualRestartSuppressed
            )
        }

        do {
            _ = try await bootstrap(
                id: id,
                stdio: [FileHandle?](repeating: nil, count: 3),
                dynamicEnv: [:],
                onlyIfNeverStarted: false
            )
            try await startProcessImpl(id: id, processID: id)
        } catch {
            if let stoppedRestartRollback {
                do {
                    try await commitLifecycle(
                        id: id,
                        from: stoppedRestartRollback.state,
                        publicState: stoppedRestartRollback.publicState,
                        error: String(describing: error),
                        intent: {
                            $0.manualRestartSuppressed =
                                stoppedRestartRollback.manualRestartSuppressed
                        }
                    )
                } catch let rollbackError {
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "explicit restart failed: \(error); failed to roll back durable restart intent: \(rollbackError)"
                    )
                }
                throw error
            }
            await markContainerRestartFailed(
                id: id,
                error: "explicit restart failed: \(error)"
            )
            throw error
        }
        await publishContainerEvent(
            action: "restart",
            snapshot: try _getContainerState(id: id).snapshot
        )
    }

    static func lifecycleMayBootstrap(
        removalRequested: Bool,
        removalInProgress: Bool
    ) -> Bool {
        !removalRequested && !removalInProgress
    }

    package func renameDockerContainer(id: String, newName: String) async throws {
        try await withLifecycleMutation(id: id) {
            try await self.renameDockerContainerImpl(id: id, newName: newName)
        }
    }

    private func renameDockerContainerImpl(id: String, newName: String) async throws {
        guard ManagedContainer.nameValid(newName) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid container name \(newName)"
            )
        }
        let renamed = try await lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
        ) { context -> (snapshot: ContainerSnapshot, oldName: String) in
            guard !(await self.hasContainer(named: newName, excluding: id)) else {
                throw ContainerizationError(
                    .exists,
                    message: "container name already exists: \(newName)"
                )
            }
            var state = try await self.getContainerState(id: id, context: context)
            let oldConfiguration = state.snapshot.configuration
            let oldName = oldConfiguration.dockerName ?? oldConfiguration.id
            guard oldName != newName else {
                return (state.snapshot, oldName)
            }
            var configuration = oldConfiguration
            configuration.dockerName = newName
            let bundle = ContainerResource.Bundle(
                path: try Self.containerPath(root: self.containerRoot, id: id)
            )
            try Self.persistContainerConfiguration(
                configuration,
                at: bundle.path
            )
            state.snapshot.configuration = configuration
            do {
                var record = try await self.lifecycleRecord(id: id)
                record.canonicalName = newName
                try Self.advanceLifecycleRevisions(&record.snapshot)
                try bundle.setDurably(lifecycleRecordV2: record)
                await self.setLifecycleRecord(record, id: id)
            } catch {
                try? Self.persistContainerConfiguration(
                    oldConfiguration,
                    at: bundle.path
                )
                throw error
            }
            await self.setContainerState(id, state, context: context)
            return (state.snapshot, oldName)
        }
        await publishEvent(
            Self.containerEvent(
                action: "rename",
                snapshot: renamed.snapshot,
                additionalAttributes: ["oldName": renamed.oldName]
            )
        )
    }

    package func updateDockerContainer(
        id: String,
        memoryBytes: Int64?,
        nanoCPUs: Int64?,
        restartPolicy: ContainerRestartPolicy?
    ) async throws -> [String] {
        try await withLifecycleMutation(id: id) {
            try await self.updateDockerContainerImpl(
                id: id,
                memoryBytes: memoryBytes,
                nanoCPUs: nanoCPUs,
                restartPolicy: restartPolicy
            )
        }
    }

    static let minimumBootableMemoryInBytes: UInt64 = 200.mib()
    static let dockerCPUPeriodInMicroseconds: UInt64 = 100_000

    static func validateBootableMemory(_ memoryInBytes: UInt64) throws {
        guard memoryInBytes >= minimumBootableMemoryInBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "minimum memory amount allowed is 200 MiB (got \(memoryInBytes) bytes)"
            )
        }
    }

    static func validateRestartPolicy(
        _ restartPolicy: ContainerRestartPolicy,
        autoRemove: Bool
    ) throws {
        guard !autoRemove || restartPolicy.mode == .no else {
            throw ContainerizationError(
                .invalidArgument,
                message: "--rm cannot be combined with --restart"
            )
        }
    }

    static func cpuQuotaInMicroseconds(
        nanoCPUs: Int64,
        periodInMicroseconds: UInt64 = dockerCPUPeriodInMicroseconds
    ) throws -> Int64 {
        guard nanoCPUs > 0,
            periodInMicroseconds > 0,
            periodInMicroseconds <= UInt64(Int64.max)
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "NanoCpus must be a positive value representable as a CPU quota"
            )
        }
        let period = Int64(periodInMicroseconds)
        let nanosPerCPU: Int64 = 1_000_000_000
        let (wholeQuota, wholeOverflow) = (nanoCPUs / nanosPerCPU)
            .multipliedReportingOverflow(by: period)
        let (fractionalProduct, fractionalOverflow) = (nanoCPUs % nanosPerCPU)
            .multipliedReportingOverflow(by: period)
        guard !wholeOverflow, !fractionalOverflow else {
            throw ContainerizationError(
                .invalidArgument,
                message: "NanoCpus must be a positive value representable as a CPU quota"
            )
        }
        let (quota, quotaOverflow) = wholeQuota.addingReportingOverflow(
            fractionalProduct / nanosPerCPU
        )
        guard !quotaOverflow, quota >= 1 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "NanoCpus must be a positive value representable as a CPU quota"
            )
        }
        return quota
    }

    static func shouldCancelPendingRestart(
        lifecycleState: ContainerResource.ContainerPublicStateV2,
        restartScheduled: Bool,
        manualRestartSuppressed: Bool = false,
        updatedPolicy: ContainerRestartPolicy,
        exitCode: Int32?,
        restartConsecutiveFailureCount: UInt32
    ) -> Bool {
        lifecycleState == .restarting
            && restartScheduled
            && !manualRestartSuppressed
            && !Self.restartPolicyAllowsPendingRestart(
                updatedPolicy,
                exitCode: exitCode,
                restartConsecutiveFailureCount: restartConsecutiveFailureCount
            )
    }

    static func restartPolicyAllowsPendingRestart(
        _ policy: ContainerRestartPolicy,
        exitCode: Int32?,
        restartConsecutiveFailureCount: UInt32
    ) -> Bool {
        switch policy.mode {
        case .no:
            return false
        case .onFailure:
            guard exitCode != nil, exitCode != 0 else {
                return false
            }
            guard let maximumRetryCount = policy.maximumRetryCount else {
                return true
            }
            return restartConsecutiveFailureCount <= maximumRetryCount
        case .always, .unlessStopped:
            return true
        }
    }

    static func restartIntentAllowsPendingRestart(
        lifecycleState: ContainerResource.ContainerPublicStateV2?,
        manualRestartSuppressed: Bool,
        policy: ContainerRestartPolicy,
        exitCode: Int32?,
        restartConsecutiveFailureCount: UInt32
    ) -> Bool {
        lifecycleState == .restarting && manualRestartSuppressed
            || Self.restartPolicyAllowsPendingRestart(
                policy,
                exitCode: exitCode,
                restartConsecutiveFailureCount: restartConsecutiveFailureCount
            )
    }

    private func updateDockerContainerImpl(
        id: String,
        memoryBytes: Int64?,
        nanoCPUs: Int64?,
        restartPolicy: ContainerRestartPolicy?
    ) async throws -> [String] {
        let restartScheduled = restartTasks[id] != nil
        let update = try await lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
        ) { context -> (warnings: [String], cancelPendingRestart: Bool) in
            var state = try await self.getContainerState(id: id, context: context)
            if state.snapshot.status == .running || state.snapshot.status == .paused,
                memoryBytes != nil || nanoCPUs != nil
            {
                throw ContainerizationError(
                    .unsupported,
                    message: "live resource update is not supported by this runtime provider"
                )
            }
            var configuration = state.snapshot.configuration
            if let memoryBytes {
                guard memoryBytes > 0 else {
                    throw ContainerizationError(.invalidArgument, message: "memory must be positive")
                }
                let memoryInBytes = UInt64(memoryBytes)
                try Self.validateBootableMemory(memoryInBytes)
                configuration.resources.memoryInBytes = memoryInBytes
            }
            if let nanoCPUs {
                let period = Self.dockerCPUPeriodInMicroseconds
                configuration.resources.cpuPeriodInMicroseconds = period
                configuration.resources.cpuQuotaInMicroseconds = try Self.cpuQuotaInMicroseconds(
                    nanoCPUs: nanoCPUs,
                    periodInMicroseconds: period
                )
            }
            let bundle = ContainerResource.Bundle(
                path: try Self.containerPath(root: self.containerRoot, id: id)
            )
            let oldConfiguration = state.snapshot.configuration
            let oldOptions = try await self.getContainerCreationOptions(id: id)
            let newOptions = ContainerCreateOptions(
                autoRemove: oldOptions.autoRemove,
                rootFsOverride: oldOptions.rootFsOverride,
                restartPolicy: restartPolicy ?? oldOptions.restartPolicy
            )
            try Self.validateRestartPolicy(
                newOptions.restartPolicy,
                autoRemove: newOptions.autoRemove
            )
            let lifecycle = try await self.lifecycleRecord(id: id)
            let publicState = lifecycle.snapshot.state
            let cancelPendingRestart = Self.shouldCancelPendingRestart(
                lifecycleState: publicState,
                restartScheduled: restartScheduled,
                manualRestartSuppressed: lifecycle.intent.manualRestartSuppressed,
                updatedPolicy: newOptions.restartPolicy,
                exitCode: state.snapshot.exitCode,
                restartConsecutiveFailureCount: state.restart.consecutiveFailures
            )
            do {
                try Self.persistContainerConfiguration(
                    configuration,
                    options: newOptions,
                    at: bundle.path
                )
                state.snapshot.configuration = configuration
                try await self.commitLifecycle(
                    id: id,
                    from: state,
                    publicState: cancelPendingRestart ? .exited : publicState,
                    intent: { $0.restartPolicy = newOptions.restartPolicy }
                )
            } catch {
                try? Self.persistContainerConfiguration(
                    oldConfiguration,
                    options: oldOptions,
                    at: bundle.path
                )
                throw error
            }
            await self.setContainerState(id, state, context: context)
            await self.publishContainerEvent(action: "update", snapshot: state.snapshot)
            return ([], cancelPendingRestart)
        }
        if update.cancelPendingRestart {
            cancelRestartTasks(id: id)
        }
        return update.warnings
    }

    package func lifecycleRecord(
        id: String
    ) throws -> ContainerResource.ContainerLifecycleRecordV2 {
        guard let record = lifecycleRecords[id] else {
            throw ContainerizationError(.notFound, message: "container not found: \(id)")
        }
        return record
    }

    package func lifecycleRecordsForAPI()
        -> [ContainerResource.ContainerLifecycleRecordV2]
    {
        Array(lifecycleRecords.values)
    }

    package func createDockerContainer(
        request: DockerContainerCreateRequest,
        requestedName: String?
    ) async throws -> String {
        guard !request.image.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Image must not be empty"
            )
        }
        let id = Utility.createContainerID(name: requestedName)
        let dockerID = Utility.createDockerContainerID()
        let dockerName = requestedName ?? id
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid container name \(id)"
            )
        }

        var process = try Flags.Process.parse([])
        process.cwd = request.workingDirectory.flatMap {
            $0.isEmpty ? nil : $0
        }
        process.env = request.environment ?? []
        process.interactive = request.openStandardInput ?? false
        process.privileged = request.hostConfiguration?.privileged ?? false
        process.tty = request.terminal ?? false
        process.user = request.user.flatMap { $0.isEmpty ? nil : $0 }

        var management = try Flags.Management.parse([])
        management.name = id
        management.hostname = request.hostname.flatMap {
            $0.isEmpty ? nil : $0
        }
        management.labels = (request.labels ?? [:]).map {
            "\($0.key)=\($0.value)"
        }.sorted()
        management.capAdd =
            request.hostConfiguration?.capabilitiesToAdd ?? []
        management.capDrop =
            request.hostConfiguration?.capabilitiesToDrop ?? []
        management.remove = request.hostConfiguration?.autoRemove ?? false
        management.readOnly =
            request.hostConfiguration?.readOnlyRootFilesystem ?? false
        management.useInit = request.hostConfiguration?.initProcess ?? false
        management.volumes = request.hostConfiguration?.binds ?? []
        if let mode = request.hostConfiguration?.networkMode,
            !mode.isEmpty,
            !["bridge", "default"].contains(mode)
        {
            management.networks = [mode]
        }
        management.publishPorts = try Self.dockerPublishedPorts(
            request.hostConfiguration?.portBindings ?? [:]
        )
        management.restart = Self.dockerRestartPolicy(
            request.hostConfiguration?.restartPolicy
        )
        if let healthcheck = request.healthcheck {
            switch healthcheck.test ?? [] {
            case let test where test.first == "NONE":
                management.noHealthCheck = true
            case let test where test.first == "CMD-SHELL":
                management.healthCommand = test.dropFirst().joined(
                    separator: " "
                )
            case let test where test.first == "CMD":
                management.healthCommand = test.dropFirst().map {
                    $0.replacingOccurrences(of: "'", with: "'\\''")
                }.map { "'\($0)'" }.joined(separator: " ")
            default:
                break
            }
            management.healthInterval = healthcheck.intervalNanoseconds.map {
                "\($0)ns"
            }
            management.healthTimeout = healthcheck.timeoutNanoseconds.map {
                "\($0)ns"
            }
            management.healthStartPeriod =
                healthcheck.startPeriodNanoseconds.map { "\($0)ns" }
            management.healthRetries = healthcheck.retries
        }

        var arguments = request.command ?? []
        if let entrypoint = request.entrypoint {
            let values = entrypoint.values
            if values.isEmpty {
                management.clearEntrypoint = true
            } else {
                management.entrypoint = values[0]
                arguments = Array(values.dropFirst()) + arguments
            }
        }

        var resources = try Flags.Resource.parse([])
        if let memory = request.hostConfiguration?.memoryBytes, memory > 0 {
            resources.memory = "\(memory)"
        }
        if let nanoCPUs = request.hostConfiguration?.nanoCPUs, nanoCPUs > 0 {
            resources.cpus = Double(nanoCPUs) / 1_000_000_000
        }
        let logging = request.hostConfiguration?.logConfiguration
        let loggingRequest = ContainerLogRequest(
            driver: logging?.type.flatMap { $0.isEmpty ? nil : $0 },
            options: logging?.options ?? [:]
        )
        let prepared = try await Utility.containerConfigFromFlags(
            id: id,
            image: request.image,
            arguments: arguments,
            process: process,
            management: management,
            resource: resources,
            registry: try Flags.Registry.parse([]),
            imageFetch: try Flags.ImageFetch.parse([]),
            loggingRequest: loggingRequest,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: nil,
            log: log
        )
        let options = try Parser.createOptions(
            autoRemove: management.remove,
            restart: management.restart,
            restartDelay: nil,
            restartWindow: nil
        )
        var configuration = prepared.0
        configuration.dockerID = dockerID
        configuration.dockerName = dockerName
        try await create(
            configuration: configuration,
            loggingRequest: loggingRequest,
            kernel: prepared.1,
            options: options,
            initImage: prepared.2
        )
        return dockerID
    }

    private static func dockerRestartPolicy(
        _ request: DockerContainerRestartPolicyRequest?
    ) -> String? {
        guard let name = request?.name, !name.isEmpty, name != "no" else {
            return nil
        }
        if name == "on-failure", let maximum = request?.maximumRetryCount,
            maximum > 0
        {
            return "on-failure:\(maximum)"
        }
        return name
    }

    private static func dockerPublishedPorts(
        _ bindings: [String: [DockerContainerPortBindingRequest]]
    ) throws -> [String] {
        var result = [String]()
        for key in bindings.keys.sorted() {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard let containerPort = UInt16(parts[0]) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid container port \(key)"
                )
            }
            let transport = parts.count == 2 ? String(parts[1]) : "tcp"
            for binding in bindings[key] ?? [] {
                let host = binding.hostIP ?? ""
                let port = binding.hostPort ?? ""
                let prefix = host.isEmpty ? port : "\(host):\(port)"
                result.append(
                    "\(prefix):\(containerPort)/\(transport)"
                )
            }
        }
        return result
    }

    package func makeLoggingHandoffControlResponder(
        stateRoot: URL,
        objectStore: ProviderHandoffBundleObjectStore,
        possessionProofStore: ProviderHandoffPossessionProofStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        providerIdentity: ProviderHandoffProviderIdentityV1
    ) throws -> any ContainerEngineProviderHandoffControlResponder {
        let commonStore = ProviderHandoffPartStagingStore(
            root: stateRoot.appendingPathComponent(
                "handoff-part-staging",
                isDirectory: true
            )
        )
        let controller = try LoggingHandoffStagingController(
            defaults: containerSystemConfig.logging,
            commonStore: commonStore,
            protectedOptionsStore: loggingProtectedOptionsStore,
            receiptStore: LoggingHandoffProtectedReceiptStore(
                rootURL: stateRoot.appendingPathComponent(
                    "handoff-logging-protected-receipts",
                    isDirectory: true
                )
            ),
            providerHistoryPreflight: remoteLogDriverPlane,
            destinationStateRootUUID:
                providerIdentity.context.stateRootUUID
        )
        let destination = try LoggingHandoffDestinationReconciler(
            rootURL: stateRoot.appendingPathComponent(
                "handoff-logging-promotions",
                isDirectory: true
            ),
            containerPromoter: self,
            providerPromoter: remoteLogDriverPlane
        )
        let destinationResponder = LoggingHandoffControlResponder(
            objectStore: objectStore,
            possessionProofStore: possessionProofStore,
            trustRegistryStore: trustRegistryStore,
            commonStore: commonStore,
            providerIdentity: providerIdentity,
            stagingController: controller,
            destination: destination,
            stagingContext: { [self] in
                try await loggingHandoffStagingContext()
            }
        )
        return LoggingHandoffSourceControlResponder(
            objectStore: objectStore,
            contributionStore: ProviderHandoffSourceContributionStore(
                root: stateRoot.appendingPathComponent(
                    "handoff-source-contributions",
                    isDirectory: true
                )
            ),
            lineageKeyStore: ProviderHandoffLineageKeyStore(),
            trustRegistryStore: trustRegistryStore,
            providerIdentity: providerIdentity,
            exportContainers: { [self] request, historyDirectoryURL in
                try await loggingHandoffExportContainers(
                    request,
                    historyDirectoryURL: historyDirectoryURL
                )
            },
            downstream: destinationResponder
        )
    }

    private func loggingHandoffExportContainers(
        _ request: ProviderHandoffPartExportRequestV1,
        historyDirectoryURL: URL
    ) async throws -> LoggingHandoffExportPayloadV2 {
        var result: [LoggingHandoffExportContainerV1] = []
        var historyFiles: [String: LoggingHandoffHistoryFileV2] = [:]
        result.reserveCapacity(request.selectedResourceIDs.count)
        for containerID in request.selectedResourceIDs {
            guard let state = containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "logging handoff source container was not found"
                )
            }
            let configuration = state.snapshot.configuration
            guard
                state.snapshot.status == .stopped,
                state.client == nil,
                !configuration.logging.isLegacy,
                let resolved = configuration.logging.resolved
            else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "logging handoff source requires stopped resolved containers"
                )
            }
            let protectedOptions = try await loadProtectedLoggingOptions(
                containerID: containerID,
                configuration: configuration.logging
            )
            let bundle = try ContainerResource.Bundle(
                path: Self.containerPath(
                    root: containerRoot,
                    id: containerID
                )
            )
            let lifecycleSnapshot: ContainerLogLifecycleLedgerSnapshotV1
            let histories: [LoggingHandoffHistoryStoreV1]
            if resolved.providerIdentity.kind == .core {
                lifecycleSnapshot = try ContainerLogLifecycleLedgerSnapshotV1(
                    owningControllerID:
                        "logging-handoff-local-\(containerID)"
                )
                let local = try Self.loggingHandoffLocalHistories(
                    resolved: resolved,
                    bundle: bundle,
                    destinationDirectoryURL: historyDirectoryURL
                )
                histories = local.histories
                try Self.appendLoggingHandoffHistoryFiles(
                    local.filesByStoreID,
                    containerID: containerID,
                    to: &historyFiles
                )
            } else {
                guard let remoteLogDriverPlane else {
                    throw ContainerizationError(
                        .invalidState,
                        message:
                            "logging handoff source provider is unavailable"
                    )
                }
                let terminal =
                    try await remoteLogDriverPlane
                    .proveHandoffTerminal(
                        containerID: containerID,
                        bundle: bundle,
                        configuration: configuration,
                        authenticatedProtectedOptions: protectedOptions
                    )
                lifecycleSnapshot = terminal.snapshot
                switch resolved.readPolicy.source {
                case .dualCache:
                    let local = try Self.loggingHandoffLocalHistories(
                        resolved: resolved,
                        bundle: bundle,
                        destinationDirectoryURL: historyDirectoryURL
                    )
                    histories = local.histories
                    try Self.appendLoggingHandoffHistoryFiles(
                        local.filesByStoreID,
                        containerID: containerID,
                        to: &historyFiles
                    )
                case .direct:
                    if let digest = terminal.proof.terminalHistoryDigest {
                        let receipt =
                            try await remoteLogDriverPlane
                            .exportProviderHistoryForHandoff(
                                containerID: containerID,
                                configuration: configuration.logging,
                                tokenID: request.tokenID,
                                manifestID: request.manifestID,
                                sourceStateRootUUID:
                                    request.sourceStateRootUUID,
                                destinationStateRootUUID:
                                    request.destinationStateRootUUID,
                                terminalHistoryDigestSHA256: digest
                            )
                        histories = try [
                            LoggingHandoffHistoryStoreV1(
                                storeID: "provider-owned",
                                kind: .providerOwned,
                                disposition: .providerExportVerified,
                                formatVersion: 1,
                                rotationIndex: 0,
                                terminalHistoryEpoch:
                                    resolved.leaseGeneration,
                                maximumInternalSequence: 0,
                                sourceDeviceID: nil,
                                sourceInode: nil,
                                bytes: nil,
                                providerExportReceipt: receipt
                            )
                        ]
                    } else {
                        histories = try [
                            Self.loggingHandoffEmptyHistory(
                                storeID: "provider-owned",
                                kind: .providerOwned,
                                terminalHistoryEpoch:
                                    resolved.leaseGeneration
                            )
                        ]
                    }
                case .unavailable:
                    histories = []
                case .legacyLocalV1:
                    throw ContainerizationError(
                        .invalidState,
                        message:
                            "logging handoff source cannot export legacy history"
                    )
                }
            }
            try result.append(
                LoggingHandoffExportContainerV1(
                    containerID: containerID,
                    configuration: configuration.logging,
                    protectedOptions: protectedOptions,
                    historyStores: histories,
                    lifecycleSnapshot: lifecycleSnapshot
                )
            )
        }
        return LoggingHandoffExportPayloadV2(
            containers: result,
            historyFiles: historyFiles
        )
    }

    private struct LoggingHandoffLocalHistoryExport {
        let histories: [LoggingHandoffHistoryStoreV1]
        let filesByStoreID: [String: LoggingHandoffHistoryFileV2]
    }

    private static func loggingHandoffLocalHistories(
        resolved: ResolvedContainerLogConfiguration,
        bundle: ContainerResource.Bundle,
        destinationDirectoryURL: URL
    ) throws -> LoggingHandoffLocalHistoryExport {
        let kind: LoggingHandoffHistoryKindV1
        let directory: URL
        let activeFileName: String
        let snapshots: [ContainerLogHandoffSegmentFileSnapshot]
        if resolved.providerIdentity.kind == .core,
            resolved.driver == "json-file"
        {
            kind = .dockerJSONFile
            directory = bundle.containerJSONFileLogDirectory
            activeFileName = ContainerResource.Bundle.jsonFileLogName
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return LoggingHandoffLocalHistoryExport(
                    histories: try [
                        loggingHandoffEmptyHistory(
                            storeID: "docker-json-file-0",
                            kind: kind,
                            terminalHistoryEpoch: 0
                        )
                    ],
                    filesByStoreID: [:]
                )
            }
            snapshots = try DockerJSONFileHandoffSegmentExporter.snapshotFiles(
                directoryURL: directory,
                activeFileName: activeFileName,
                destinationDirectoryURL: destinationDirectoryURL
            )
        } else if resolved.providerIdentity.kind == .core,
            resolved.driver == "local"
        {
            kind = .nativeLocal
            directory = bundle.containerNativeLocalLogDirectory
            activeFileName = ContainerResource.Bundle.nativeLocalLogName
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return LoggingHandoffLocalHistoryExport(
                    histories: try [
                        loggingHandoffEmptyHistory(
                            storeID: "native-local-0",
                            kind: kind,
                            terminalHistoryEpoch: 0
                        )
                    ],
                    filesByStoreID: [:]
                )
            }
            snapshots = try NativeLocalLogHandoffSegmentExporter.snapshotFiles(
                directoryURL: directory,
                activeFileName: activeFileName,
                destinationDirectoryURL: destinationDirectoryURL
            )
        } else if resolved.readPolicy.source == .dualCache {
            kind = .dualCache
            directory = bundle.containerNativeLogCacheDirectory
            activeFileName = ContainerResource.Bundle.nativeLogCacheName
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return LoggingHandoffLocalHistoryExport(
                    histories: try [
                        loggingHandoffEmptyHistory(
                            storeID: "dual-cache-0",
                            kind: kind,
                            terminalHistoryEpoch: 0
                        )
                    ],
                    filesByStoreID: [:]
                )
            }
            snapshots = try NativeLocalLogHandoffSegmentExporter.snapshotFiles(
                directoryURL: directory,
                activeFileName: activeFileName,
                destinationDirectoryURL: destinationDirectoryURL
            )
        } else {
            return LoggingHandoffLocalHistoryExport(
                histories: [],
                filesByStoreID: [:]
            )
        }

        let terminalEpoch = try ContainerLogProcessGenerationStore(
            directoryURL: bundle.containerLoggingV2
        ).current()
        guard !snapshots.isEmpty else {
            return LoggingHandoffLocalHistoryExport(
                histories: try [
                    loggingHandoffEmptyHistory(
                        storeID: "\(kind.rawValue)-0",
                        kind: kind,
                        terminalHistoryEpoch: terminalEpoch
                    )
                ],
                filesByStoreID: [:]
            )
        }
        var filesByStoreID: [String: LoggingHandoffHistoryFileV2] = [:]
        let histories = try snapshots.map { snapshot in
            let storeID = "\(kind.rawValue)-\(snapshot.rotationIndex)"
            guard filesByStoreID[storeID] == nil else {
                throw LoggingHandoffPayloadError.invalidHistory(storeID)
            }
            filesByStoreID[storeID] = LoggingHandoffHistoryFileV2(
                url: snapshot.fileURL,
                byteLength: snapshot.byteLength,
                contentDigestSHA256: snapshot.contentDigestSHA256
            )
            return try LoggingHandoffHistoryStoreV1(
                fileBackedStoreID: storeID,
                kind: kind,
                disposition: .importVerified,
                formatVersion: 1,
                rotationIndex: snapshot.rotationIndex,
                compressed: snapshot.compressed,
                terminalHistoryEpoch: terminalEpoch,
                maximumInternalSequence:
                    snapshot.maximumInternalSequence,
                sourceDeviceID: snapshot.sourceDeviceID,
                sourceInode: snapshot.sourceInode,
                byteLength: snapshot.byteLength,
                contentDigestSHA256: snapshot.contentDigestSHA256
            )
        }
        return LoggingHandoffLocalHistoryExport(
            histories: histories,
            filesByStoreID: filesByStoreID
        )
    }

    private static func appendLoggingHandoffHistoryFiles(
        _ filesByStoreID: [String: LoggingHandoffHistoryFileV2],
        containerID: String,
        to destination: inout [String: LoggingHandoffHistoryFileV2]
    ) throws {
        for (storeID, file) in filesByStoreID {
            let entryID = LoggingHandoffPayloadCodec.historyEntryID(
                containerID: containerID,
                storeID: storeID
            )
            guard destination[entryID] == nil else {
                throw LoggingHandoffPayloadError.invalidEntry(entryID)
            }
            destination[entryID] = file
        }
    }

    private static func loggingHandoffEmptyHistory(
        storeID: String,
        kind: LoggingHandoffHistoryKindV1,
        terminalHistoryEpoch: UInt64
    ) throws -> LoggingHandoffHistoryStoreV1 {
        try LoggingHandoffHistoryStoreV1(
            storeID: storeID,
            kind: kind,
            disposition: .empty,
            formatVersion: 1,
            rotationIndex: 0,
            terminalHistoryEpoch: terminalHistoryEpoch,
            maximumInternalSequence: 0,
            sourceDeviceID: nil,
            sourceInode: nil,
            bytes: nil
        )
    }

    private func loggingHandoffStagingContext() async throws -> (
        catalog: LogDriverCatalog,
        occupiedContainerIDs: Set<String>
    ) {
        (
            catalog: try await logDriverCatalogProvider.logDriverCatalog(),
            occupiedContainerIDs: Set(containers.keys)
        )
    }

    func engineInspectBase(
        containerID: String
    ) throws -> ContainerEngineInspectBase {
        let state = try _getContainerState(id: containerID)
        let snapshot = state.snapshot
        let path = try Self.containerPath(
            root: containerRoot,
            id: containerID
        )
        let runtime = try? RuntimeConfiguration.readRuntimeConfiguration(
            from: path
        )
        let bundle = ContainerResource.Bundle(path: path)
        let persistedOptions: ContainerCreateOptions? = try? bundle.load(
            filename: "options.json"
        )
        return ContainerEngineInspectBase(
            snapshot: snapshot,
            lifecycle: try lifecycleRecord(id: containerID),
            options: Self.authoritativeCreateOptions(
                persisted: persistedOptions,
                runtime: runtime?.options
            ),
            runtimeData: runtime?.runtimeData,
            stateError: state.dockerStateError
        )
    }

    static func authoritativeCreateOptions(
        persisted: ContainerCreateOptions?,
        runtime: ContainerCreateOptions?
    ) -> ContainerCreateOptions {
        persisted ?? runtime ?? .default
    }

    func engineContainerRootPath() -> String {
        containerRoot.path
    }

    func engineLifecycleRecords()
        -> [String: ContainerResource.ContainerLifecycleRecordV2]
    {
        lifecycleRecords
    }

    func engineListSnapshot() -> ContainerEngineListSnapshot {
        ContainerEngineListSnapshot(
            snapshots: containers.values.map(\.snapshot),
            lifecycleRecords: lifecycleRecords
        )
    }

    func engineAttachmentInspection(
        containerID: String
    ) throws -> ContainerEngineAttachmentInspection {
        let snapshot = try _getContainerState(id: containerID).snapshot
        return ContainerEngineAttachmentInspection(
            snapshot: snapshot,
            terminal: snapshot.configuration.initProcess.terminal,
            restarting: snapshot.status != .running
                && restartTasks[containerID] != nil
        )
    }

    func publishEngineAttachEvent(snapshot: ContainerSnapshot) async {
        await publishContainerEvent(action: "attach", snapshot: snapshot)
    }

    func publishEngineDetachEvent(snapshot: ContainerSnapshot) async {
        await publishContainerEvent(action: "detach", snapshot: snapshot)
    }

    func publishEngineResizeEvent(
        snapshot: ContainerSnapshot,
        height: UInt32,
        width: UInt32
    ) async {
        await publishEvent(
            Self.containerEvent(
                action: "resize",
                snapshot: snapshot,
                additionalAttributes: [
                    "height": String(height),
                    "width": String(width),
                ]
            )
        )
    }

    func engineLoggingSystemInfo() async throws -> (
        defaultDriver: String,
        registeredDrivers: [String]
    ) {
        let catalog =
            try await logDriverCatalogProvider
            .advertisedLogDriverCatalog()
        return (
            defaultDriver: containerSystemConfig.logging.driver,
            registeredDrivers: catalog.registeredNames
        )
    }

    func engineLoggingInspection(
        containerID: String
    ) async throws -> ContainerEngineLoggingInspection {
        let state = try _getContainerState(id: containerID)
        let configuration = state.snapshot.configuration
        let logging = configuration.logging
        let driver: String
        let options: [String: String]
        let publicLogPath: String?

        if logging.isLegacy {
            driver = logging.effectiveDriver
            options = [:]
            publicLogPath = nil
        } else {
            guard let resolved = logging.resolved else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container logging configuration is incomplete"
                )
            }
            var resolvedOptions = resolved.safeOptions
            if let reference = resolved.protectedOptionReference {
                let binding = try LoggingProtectedOptionsBinding(
                    containerID: containerID,
                    configuration: logging
                )
                let protectedOptions = try await loggingProtectedOptionsStore.load(
                    reference,
                    boundTo: binding
                )
                guard
                    Set(resolvedOptions.keys).isDisjoint(
                        with: protectedOptions.keys
                    )
                else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "container logging option classes overlap"
                    )
                }
                resolvedOptions.merge(protectedOptions) { current, _ in current }
            }
            driver = resolved.driver
            options = resolvedOptions
            if resolved.driver == "json-file",
                state.snapshot.startedDate != nil
            {
                let path = try Self.containerPath(
                    root: containerRoot,
                    id: containerID
                )
                publicLogPath =
                    ContainerResource.Bundle(path: path)
                    .containerJSONFileLog.path
            } else {
                publicLogPath = nil
            }
        }

        return ContainerEngineLoggingInspection(
            driver: driver,
            options: options,
            publicLogPath: publicLogPath,
            terminal: configuration.initProcess.terminal
        )
    }

    func engineLogReadSource(
        containerID: String,
        request: ContainerLogReadRequest
    ) async throws -> ContainerEngineLogReadSource {
        let state = try _getContainerState(id: containerID)
        let configuration = state.snapshot.configuration
        let terminal = configuration.initProcess.terminal
        let path = try Self.containerPath(
            root: containerRoot,
            id: containerID
        )
        let bundle = ContainerResource.Bundle(path: path)

        if let resolved = configuration.logging.resolved,
            resolved.readPolicy.source == .direct,
            resolved.providerIdentity.kind != .core
        {
            guard let remoteLogDriverPlane else {
                throw ContainerizationError(
                    .invalidState,
                    message: "direct logging provider is unavailable"
                )
            }
            var protectedOptions = [String: String]()
            if let reference = resolved.protectedOptionReference {
                let binding = try LoggingProtectedOptionsBinding(
                    containerID: containerID,
                    configuration: configuration.logging
                )
                protectedOptions = try await loggingProtectedOptionsStore.load(
                    reference,
                    boundTo: binding
                )
            }
            let reader = try await remoteLogDriverPlane.openReader(
                containerID: containerID,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: protectedOptions,
                read: request
            )
            return .direct(reader: reader, terminal: terminal)
        }

        if let resolved = configuration.logging.resolved,
            resolved.driver == "syslog",
            resolved.readPolicy.source == .unavailable,
            resolved.providerIdentity.kind != .core,
            !isLiveForLogFollow(id: containerID)
        {
            guard let remoteLogDriverPlane else {
                throw ContainerizationError(
                    .invalidState,
                    message: "direct logging provider is unavailable"
                )
            }
            var protectedOptions = [String: String]()
            if let reference = resolved.protectedOptionReference {
                let binding = try LoggingProtectedOptionsBinding(
                    containerID: containerID,
                    configuration: configuration.logging
                )
                protectedOptions = try await loggingProtectedOptionsStore.load(
                    reference,
                    boundTo: binding
                )
            }
            try await remoteLogDriverPlane.recreateStoppedUnavailableSyslogLogger(
                containerID: containerID,
                configuration: configuration,
                authenticatedProtectedOptions: protectedOptions
            )
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
        }

        if request.follow, isLiveForLogFollow(id: containerID) {
            do {
                let file = try await state.getClient().followLogReadRecordsV1(
                    request: request
                )
                return .activeWire(file: file, terminal: terminal)
            } catch {
                guard !isLiveForLogFollow(id: containerID) else {
                    throw error
                }
            }
        }

        let reader = try ContainerLogNativeReaderFactory.makeReader(
            bundle: bundle,
            configuration: configuration,
            request: request,
            source: .stoppedContainer,
            includeRotated: true
        )
        return .direct(reader: reader, terminal: terminal)
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
