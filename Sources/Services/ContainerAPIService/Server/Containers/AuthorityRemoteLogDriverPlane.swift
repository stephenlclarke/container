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

import ContainerLoggingProviders
import ContainerResource
import ContainerRuntimeClient
import CryptoKit
import DockerSemanticHelper
import Foundation
import Logging
import NIOPosix

enum AuthorityRemoteLogDriverPlaneError: Error, Equatable, Sendable {
    case incompleteConfiguration
    case unsupportedDriver(String)
    case runAlreadyPrepared(String)
    case runNotPrepared(String)
    case runAlreadyActivated(String)
    case runNotActivated(String)
    case generationMismatch(expected: UInt64, actual: UInt64)
    case providerGenerationNotTerminal(containerID: String, generation: UInt64)
    case providerHistoryMigrationReceiptMismatch(containerID: String)
    case providerHistoryHandoffReceiptMismatch(containerID: String)
}

package struct AuthorityRemoteLogDriverUpgradeCandidate: Equatable, Sendable {
    package let upgrade: LogDriverProviderUpgradeV1
    package let sourceDescriptor: LogDriverDescriptor
    package let targetDescriptor: LogDriverDescriptor
}

package struct AuthorityRemoteLogDriverTerminalProof: Equatable, Sendable {
    package let terminalHistoryDigest: String?
}

package struct AuthorityRemoteLogDriverReclamationCandidate: Equatable,
    Sendable
{
    package let providerID: String
    package let generation: UInt64
    package let descriptor: LogDriverDescriptor
}

package typealias AuthorityGCPLoggingServiceFactory =
    @Sendable (
        DockerSemanticHelperGeneration
    ) throws -> any DockerGCPLoggingServicing

/// API-authority ownership for built-in remote logging drivers.
///
/// Protected options are authenticated and converted into an exact typed
/// provider binding before this plane is called. The runtime receives only
/// pipe descriptors, never protected values, provider effect tokens, or
/// network endpoints. Lifecycle intent and effect-token references are made
/// durable before provider effects and are generation-fenced on every close.
public actor AuthorityRemoteLogDriverPlane: LogDriverCatalogProviding {
    private struct Run: Sendable {
        let request: LogDriverStartRequestV1
        let provider: any ContainerLogDriverProvider
        let controller: ContainerLogLifecycleControllerV1
        let session: any ContainerLogDriverSession
        let delivery: AuthorityRemoteLogDelivery
        let pump: AuthorityRemoteLogPump
        let readerTasks: [Task<Void, Never>]
        var authorityWriteHandles: [FileHandle]
        var activation: LoggingSessionActivationV1?
    }

    private struct ReaderRun: Sendable {
        let request: LogDriverReaderOpenRequestV1
        let provider: any ContainerLogDriverProvider
        let controller: ContainerLogLifecycleControllerV1
        let session: LoggingReaderSessionV1
    }

    private let providers: BuiltinRemoteLogDriverProviderSet
    private let protectedEffects: ProtectedLoggingEffectStore
    private let eventLoopOwner: AuthorityRemoteLogEventLoopOwner
    private let gcpLoggingServiceFactory: AuthorityGCPLoggingServiceFactory
    private let log = Logger(label: "com.apple.container.logging.authority")
    private var runs = [String: Run]()
    private var readerRuns = [String: ReaderRun]()
    private var closingReaderIDs = Set<String>()

    private init(
        providers: BuiltinRemoteLogDriverProviderSet,
        protectedEffects: ProtectedLoggingEffectStore,
        eventLoopOwner: AuthorityRemoteLogEventLoopOwner,
        gcpLoggingServiceFactory: @escaping AuthorityGCPLoggingServiceFactory
    ) {
        self.providers = providers
        self.protectedEffects = protectedEffects
        self.eventLoopOwner = eventLoopOwner
        self.gcpLoggingServiceFactory = gcpLoggingServiceFactory
    }

    package static func create(
        appRoot: URL,
        awsLogsClientFactory: any AWSLogsClientFactory,
        journaldService: (any JournaldService)? = nil,
        dockerPluginInstallations: [DockerPluginLogDriverInstallation] = [],
        gcpLoggingServiceFactory: @escaping AuthorityGCPLoggingServiceFactory = {
            generation in
            try DockerSemanticHelperClient.shared(
                for: generation,
                launchConfiguration: .discover(inheritEnvironment: true)
            )
        },
        providerGeneration: UInt64 = 1
    ) async throws -> AuthorityRemoteLogDriverPlane {
        let threadCount = max(
            1,
            min(4, ProcessInfo.processInfo.activeProcessorCount)
        )
        let eventLoopOwner = AuthorityRemoteLogEventLoopOwner(
            threadCount: threadCount
        )
        let registryPersistence = try FileLogDriverProviderRegistryPersistenceV1(
            fileURL:
                appRoot
                .appendingPathComponent("engine-services", isDirectory: true)
                .appendingPathComponent("docker-plugins", isDirectory: true)
                .appendingPathComponent("provider-generations-v1.json")
        )
        let providers = try await BuiltinRemoteLogDriverProviderSet.install(
            eventLoopGroup: eventLoopOwner.group,
            awsLogsClientFactory: awsLogsClientFactory,
            journaldService: journaldService,
            dockerPluginInstallations: dockerPluginInstallations,
            providerGeneration: providerGeneration,
            registryPersistence: registryPersistence
        )
        let protectedEffects = try ProtectedLoggingEffectStore(
            rootURL: appRoot.appendingPathComponent(
                "logging-protected-effects",
                isDirectory: true
            )
        )
        return AuthorityRemoteLogDriverPlane(
            providers: providers,
            protectedEffects: protectedEffects,
            eventLoopOwner: eventLoopOwner,
            gcpLoggingServiceFactory: gcpLoggingServiceFactory
        )
    }

    public func logDriverCatalog() async throws -> LogDriverCatalog {
        var unavailableProviderIDs = Set<String>()
        if let journald = providers.journald {
            do {
                _ = try await journald.activeSandboxGeneration()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let descriptor = try await journald.descriptor
                unavailableProviderIDs.insert(descriptor.providerIdentity.id)
            }
        }
        // An installed Docker plugin remains a valid create-time driver while
        // its lazy Linux service is booting. Session admission performs the
        // authoritative generation-fenced readiness check and returns a
        // start-time error if the service cannot be acquired. Catalog lookup
        // must not mutate or hide an active generation because of transient
        // sandbox availability.
        let currentCatalog = try await advertisedLogDriverCatalog()
        guard !unavailableProviderIDs.isEmpty else {
            return currentCatalog
        }
        return try LogDriverCatalog(
            descriptors: currentCatalog.descriptors.filter {
                !unavailableProviderIDs.contains($0.providerIdentity.id)
            }
        )
    }

    public func advertisedLogDriverCatalog() async throws -> LogDriverCatalog {
        try await providers.registry.logDriverCatalog()
    }

    package func providerUpgradeCandidates() async throws
        -> [AuthorityRemoteLogDriverUpgradeCandidate]
    {
        let upgrades = try await providers.registry.upgradeCandidates()
        var candidates = [AuthorityRemoteLogDriverUpgradeCandidate]()
        candidates.reserveCapacity(upgrades.count)
        for upgrade in upgrades {
            guard
                let source = await providers.registry.selection(
                    providerID: upgrade.providerID,
                    generation: upgrade.sourceGeneration
                ),
                let target = await providers.registry.selection(
                    providerID: upgrade.providerID,
                    generation: upgrade.targetGeneration
                )
            else {
                throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                    upgrade.providerID
                )
            }
            candidates.append(
                AuthorityRemoteLogDriverUpgradeCandidate(
                    upgrade: upgrade,
                    sourceDescriptor: source.descriptor,
                    targetDescriptor: target.descriptor
                )
            )
        }
        return candidates
    }

    package func providerReclamationCandidates() async throws
        -> [AuthorityRemoteLogDriverReclamationCandidate]
    {
        let snapshot = try await providers.registry.stateSnapshot()
        var candidates = [AuthorityRemoteLogDriverReclamationCandidate]()
        for state in snapshot.providers {
            for generation in state.drainingGenerations {
                guard
                    let selection = await providers.registry.selection(
                        providerID: state.providerID,
                        generation: generation
                    )
                else {
                    continue
                }
                candidates.append(
                    AuthorityRemoteLogDriverReclamationCandidate(
                        providerID: state.providerID,
                        generation: generation,
                        descriptor: selection.descriptor
                    )
                )
            }
        }
        return candidates.sorted {
            ($0.providerID, $0.generation) < ($1.providerID, $1.generation)
        }
    }

    package func beginProviderUpgrade(
        _ candidate: AuthorityRemoteLogDriverUpgradeCandidate
    ) async throws {
        if let selection = await providers.registry.selection(
            providerID: candidate.upgrade.providerID,
            generation: candidate.upgrade.targetGeneration
        ),
            let provider = selection.provider
                as? any EngineLinuxSandboxLogDriverProvider
        {
            guard try await provider.activeSandboxGeneration() > 0 else {
                throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                    candidate.upgrade.providerID
                )
            }
        }
        _ = try await providers.registry.beginUpgrade(
            providerID: candidate.upgrade.providerID,
            targetGeneration: candidate.upgrade.targetGeneration
        )
    }

    package func cancelProviderUpgrade(
        _ candidate: AuthorityRemoteLogDriverUpgradeCandidate
    ) async throws {
        _ = try await providers.registry.cancelUpgrade(
            providerID: candidate.upgrade.providerID,
            targetGeneration: candidate.upgrade.targetGeneration
        )
    }

    package func activateProviderUpgrade(
        _ candidate: AuthorityRemoteLogDriverUpgradeCandidate
    ) async throws {
        _ = try await providers.registry.activate(
            providerID: candidate.upgrade.providerID,
            generation: candidate.upgrade.targetGeneration
        )
    }

    package func reclaimProviderGeneration(
        _ candidate: AuthorityRemoteLogDriverUpgradeCandidate
    ) async throws {
        guard
            let selection = await providers.registry.selection(
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.sourceGeneration
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                candidate.upgrade.providerID
            )
        }
        try await reclaimProviderGeneration(
            AuthorityRemoteLogDriverReclamationCandidate(
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.sourceGeneration,
                descriptor: selection.descriptor
            )
        )
    }

    package func reclaimProviderGeneration(
        _ candidate: AuthorityRemoteLogDriverReclamationCandidate
    ) async throws {
        guard
            let selection = await providers.registry.selection(
                providerID: candidate.providerID,
                generation: candidate.generation
            ),
            selection.descriptor == candidate.descriptor
        else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                candidate.providerID
            )
        }
        try await selection.provider.reclaimGeneration(
            LogDriverProviderGenerationReclaimV1(
                providerID: candidate.providerID,
                providerGeneration: candidate.generation
            )
        )
        _ = try await providers.registry.uninstall(
            providerID: candidate.providerID,
            generation: candidate.generation
        )
    }

    /// Reconciles every source-generation effect in one container ledger and
    /// returns only after the durable snapshot proves no effect or protected
    /// cleanup reference can still reach the provider.
    package func proveProviderGenerationTerminal(
        candidate: AuthorityRemoteLogDriverUpgradeCandidate,
        containerID: String,
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        authenticatedProtectedOptions: [String: String]
    ) async throws -> AuthorityRemoteLogDriverTerminalProof {
        guard
            configuration.id == containerID,
            let resolved = configuration.logging.resolved,
            resolved.providerIdentity.id == candidate.upgrade.providerID,
            resolved.providerGenerationAtResolution
                == candidate.upgrade.sourceGeneration,
            runs[containerID] == nil,
            !readerRuns.values.contains(where: {
                $0.request.containerID == containerID
                    && $0.request.providerGeneration
                        == candidate.upgrade.sourceGeneration
            }),
            let selection = await providers.registry.selection(
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.sourceGeneration
            )
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerGenerationNotTerminal(
                    containerID: containerID,
                    generation: candidate.upgrade.sourceGeneration
                )
        }
        let controllerID = Self.controllerID(
            containerID: containerID,
            leaseGeneration: resolved.leaseGeneration
        )
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(resolved.leaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: protectedEffects
        )
        let options = try Self.mergedOptions(
            resolved: resolved,
            protected: authenticatedProtectedOptions
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        try await reconcilePriorRuns(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options,
            semanticDigest: try Self.semanticDigest(
                containerID: containerID,
                configuration: configuration.logging
            )
        )
        try await reconcilePriorReaders(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        let snapshot = await ledger.snapshot()
        guard
            Self.isTerminal(
                snapshot,
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.sourceGeneration
            )
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerGenerationNotTerminal(
                    containerID: containerID,
                    generation: candidate.upgrade.sourceGeneration
                )
        }
        return try Self.terminalProof(
            snapshot: snapshot,
            configuration: configuration
        )
    }

    /// Reconciles the selected provider generation to a terminal, immutable
    /// ledger snapshot for cross-provider handoff export.
    package func proveHandoffTerminal(
        containerID: String,
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        authenticatedProtectedOptions: [String: String]
    ) async throws -> (
        snapshot: ContainerLogLifecycleLedgerSnapshotV1,
        proof: AuthorityRemoteLogDriverTerminalProof
    ) {
        guard
            configuration.id == containerID,
            let resolved = configuration.logging.resolved,
            resolved.providerIdentity.kind != .core,
            runs[containerID] == nil,
            !readerRuns.values.contains(where: {
                $0.request.containerID == containerID
                    && $0.request.providerGeneration
                    == resolved.providerGenerationAtResolution
            }),
            let selection = await providers.registry.selection(
                providerID: resolved.providerIdentity.id,
                generation: resolved.providerGenerationAtResolution
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError
                .providerGenerationNotTerminal(
                    containerID: containerID,
                    generation: configuration.logging.resolved?
                        .providerGenerationAtResolution ?? 0
                )
        }
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(resolved.leaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: Self.controllerID(
                containerID: containerID,
                leaseGeneration: resolved.leaseGeneration
            ),
            persistence: persistence
        )
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: protectedEffects
        )
        let options = try Self.mergedOptions(
            resolved: resolved,
            protected: authenticatedProtectedOptions
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        try await reconcilePriorRuns(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options,
            semanticDigest: Self.semanticDigest(
                containerID: containerID,
                configuration: configuration.logging
            )
        )
        try await reconcilePriorReaders(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        let snapshot = await ledger.snapshot()
        guard
            Self.isTerminal(
                snapshot,
                providerID: resolved.providerIdentity.id,
                generation: resolved.providerGenerationAtResolution
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError
                .providerGenerationNotTerminal(
                    containerID: containerID,
                    generation: resolved.providerGenerationAtResolution
                )
        }
        return try (
            snapshot,
            Self.terminalProof(
                snapshot: snapshot,
                configuration: configuration
            )
        )
    }

    /// Verifies the already-durable terminal proof when restart occurs after
    /// configuration publication but before alias activation.
    package func verifyProviderGenerationTerminal(
        candidate: AuthorityRemoteLogDriverUpgradeCandidate,
        containerID: String,
        bundle: ContainerResource.Bundle,
        targetConfiguration: ContainerConfiguration,
        sourceLeaseGeneration: UInt64
    ) async throws -> AuthorityRemoteLogDriverTerminalProof {
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(sourceLeaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: Self.controllerID(
                containerID: containerID,
                leaseGeneration: sourceLeaseGeneration
            ),
            persistence: persistence
        )
        let snapshot = await ledger.snapshot()
        guard
            Self.isTerminal(
                snapshot,
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.sourceGeneration
            )
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerGenerationNotTerminal(
                    containerID: containerID,
                    generation: candidate.upgrade.sourceGeneration
                )
        }
        return try Self.terminalProof(
            snapshot: snapshot,
            configuration: targetConfiguration
        )
    }

    package func migrateProviderHistory(
        candidate: AuthorityRemoteLogDriverUpgradeCandidate,
        containerID: String,
        sourceConfiguration: ContainerLogConfiguration,
        proof: AuthorityRemoteLogDriverTerminalProof
    ) async throws -> LogDriverHistoryMigrationReceiptV1? {
        guard let terminalHistoryDigest = proof.terminalHistoryDigest else {
            return nil
        }
        guard
            let resolved = sourceConfiguration.resolved,
            resolved.leaseGeneration < UInt64.max,
            let selection = await providers.registry.selection(
                providerID: candidate.upgrade.providerID,
                generation: candidate.upgrade.targetGeneration
            )
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryMigrationReceiptMismatch(
                    containerID: containerID
                )
        }
        let request = try LogDriverHistoryMigrationRequestV1(
            containerID: containerID,
            sourceLeaseGeneration: resolved.leaseGeneration,
            targetLeaseGeneration: resolved.leaseGeneration + 1,
            providerID: candidate.upgrade.providerID,
            sourceProviderGeneration: candidate.upgrade.sourceGeneration,
            targetProviderGeneration: candidate.upgrade.targetGeneration,
            contractDigest: resolved.contractDigest,
            terminalHistoryDigest: terminalHistoryDigest
        )
        let receipt = try await selection.provider.migrateHistory(request)
        guard receipt.request == request else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryMigrationReceiptMismatch(
                    containerID: containerID
                )
        }
        return receipt
    }

    package func exportProviderHistoryForHandoff(
        containerID: String,
        configuration: ContainerLogConfiguration,
        tokenID: String,
        manifestID: String,
        sourceStateRootUUID: String,
        destinationStateRootUUID: String,
        terminalHistoryDigestSHA256: String
    ) async throws -> LogDriverHistoryHandoffExportReceiptV1 {
        guard
            let resolved = configuration.resolved,
            resolved.readPolicy.source == .direct,
            let selection = await providers.registry.selection(
                providerID: resolved.providerIdentity.id,
                generation: resolved.providerGenerationAtResolution
            )
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: containerID
                )
        }
        let request = try LogDriverHistoryHandoffExportRequestV1(
            tokenID: tokenID,
            manifestID: manifestID,
            containerID: containerID,
            sourceStateRootUUID: sourceStateRootUUID,
            destinationStateRootUUID: destinationStateRootUUID,
            sourceLeaseGeneration: resolved.leaseGeneration,
            sourceProviderID: resolved.providerIdentity.id,
            sourceProviderGeneration:
                resolved.providerGenerationAtResolution,
            sourceContractDigest: resolved.contractDigest,
            terminalHistoryDigestSHA256: terminalHistoryDigestSHA256
        )
        let receipt = try await selection.provider
            .exportHistoryForHandoff(request)
        guard receipt.request == request else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: containerID
                )
        }
        return receipt
    }

    package func verifyProviderHistoryMigration(
        candidate: AuthorityRemoteLogDriverUpgradeCandidate,
        containerID: String,
        targetConfiguration: ContainerLogConfiguration,
        proof: AuthorityRemoteLogDriverTerminalProof
    ) throws {
        guard
            let resolved = targetConfiguration.resolved,
            resolved.leaseGeneration > 1
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryMigrationReceiptMismatch(
                    containerID: containerID
                )
        }
        let receipt = resolved.providerHistoryMigrationReceipt
        guard let terminalHistoryDigest = proof.terminalHistoryDigest else {
            guard receipt == nil else {
                throw
                    AuthorityRemoteLogDriverPlaneError
                    .providerHistoryMigrationReceiptMismatch(
                        containerID: containerID
                    )
            }
            return
        }
        let request = try LogDriverHistoryMigrationRequestV1(
            containerID: containerID,
            sourceLeaseGeneration: resolved.leaseGeneration - 1,
            targetLeaseGeneration: resolved.leaseGeneration,
            providerID: candidate.upgrade.providerID,
            sourceProviderGeneration: candidate.upgrade.sourceGeneration,
            targetProviderGeneration: candidate.upgrade.targetGeneration,
            contractDigest: resolved.contractDigest,
            terminalHistoryDigest: terminalHistoryDigest
        )
        guard receipt?.request == request else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryMigrationReceiptMismatch(
                    containerID: containerID
                )
        }
    }

    private static func terminalProof(
        snapshot: ContainerLogLifecycleLedgerSnapshotV1,
        configuration: ContainerConfiguration
    ) throws -> AuthorityRemoteLogDriverTerminalProof {
        guard configuration.logging.resolved?.readPolicy.source == .direct,
            snapshot.writerOperations.contains(where: {
                if case .activated = $0.result { return true }
                return false
            })
        else {
            return AuthorityRemoteLogDriverTerminalProof(
                terminalHistoryDigest: nil
            )
        }
        return AuthorityRemoteLogDriverTerminalProof(
            terminalHistoryDigest: try terminalHistoryDigest(snapshot)
        )
    }

    private static func terminalHistoryDigest(
        _ snapshot: ContainerLogLifecycleLedgerSnapshotV1
    ) throws -> String? {
        guard
            snapshot.writerOperations.contains(where: {
                if case .activated = $0.result { return true }
                return false
            })
        else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var material = Data("provider-terminal-history-v1\u{0}".utf8)
        material.append(try encoder.encode(snapshot))
        return "sha256:" + sha256Hex(material)
    }

    private static func isTerminal(
        _ snapshot: ContainerLogLifecycleLedgerSnapshotV1,
        providerID: String,
        generation: UInt64
    ) -> Bool {
        guard snapshot.pendingEffectRemovals.isEmpty else {
            return false
        }
        let writersTerminal = snapshot.writerOperations.allSatisfy { record in
            guard
                record.request.providerID == providerID,
                record.request.providerGeneration == generation
            else {
                return false
            }
            switch record.result {
            case .candidateClosed:
                return true
            case .activated(let activation):
                return activation.state == .closed
                    || activation.state == .tombstoned
            default:
                return false
            }
        }
        let readersTerminal = snapshot.readerOperations.allSatisfy { record in
            guard
                record.request.providerID == providerID,
                record.request.providerGeneration == generation
            else {
                return false
            }
            switch record.result {
            case .candidateClosed:
                return true
            case .activated(let session):
                return session.state == .closed
                    || session.state == .tombstoned
            default:
                return false
            }
        }
        let cleanupsTerminal = snapshot.detachedCleanups.allSatisfy {
            $0.providerID == providerID
                && $0.providerGeneration == generation
                && ($0.state == .complete || $0.state == .tombstoned)
        }
        return writersTerminal && readersTerminal && cleanupsTerminal
    }

    /// Prepares one provider session and substitutes authority-owned pipes for
    /// runtime stdout/stderr. Core drivers return the caller's handles intact.
    package func prepareBootstrap(
        containerID: String,
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        authenticatedProtectedOptions: [String: String],
        stdio: [FileHandle?]
    ) async throws -> [FileHandle?] {
        guard let resolved = configuration.logging.resolved else {
            return stdio
        }
        guard resolved.providerIdentity.kind != .core else {
            return stdio
        }
        guard runs[containerID] == nil else {
            throw AuthorityRemoteLogDriverPlaneError.runAlreadyPrepared(
                containerID
            )
        }
        guard configuration.id == containerID else {
            throw AuthorityRemoteLogDriverPlaneError.incompleteConfiguration
        }

        let selection = try await providers.registry.selection(for: resolved)
        let controllerID = Self.controllerID(
            containerID: containerID,
            leaseGeneration: resolved.leaseGeneration
        )
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(resolved.leaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: protectedEffects
        )
        let options = try Self.mergedOptions(
            resolved: resolved,
            protected: authenticatedProtectedOptions
        )
        let semanticDigest = try Self.semanticDigest(
            containerID: containerID,
            configuration: configuration.logging
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        try await reconcilePriorRuns(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options,
            semanticDigest: semanticDigest
        )
        try await reconcilePriorReaders(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options
        )

        let sequenceStore = try ContainerLogProcessGenerationStore(
            directoryURL: bundle.containerLoggingV2
        )
        let processGeneration = try sequenceStore.next()
        let sequenceReservation = try sequenceStore.reserveSequenceBlock()
        let identityDigest = Self.sha256Hex(
            Data(
                "\(containerID)\u{0}\(resolved.leaseGeneration)\u{0}\(processGeneration)"
                    .utf8
            )
        )
        let request = try LogDriverStartRequestV1(
            operationGeneration: processGeneration,
            idempotencyKey: "writer-\(identityDigest)",
            semanticRequestDigest: semanticDigest,
            sessionID: "session-\(identityDigest)",
            containerID: containerID,
            leaseGeneration: resolved.leaseGeneration,
            candidateProcessGeneration: processGeneration,
            providerID: resolved.providerIdentity.id,
            providerGeneration: resolved.providerGenerationAtResolution,
            candidateSandboxGeneration: try await sandboxGeneration(
                for: resolved,
                provider: selection.provider
            )
        )
        try await registerConfiguration(
            request: request,
            options: options,
            configuration: configuration
        )

        let started: StartedLogDriverSessionV1
        do {
            started = try await controller.prepareWriter(
                request,
                using: selection.provider
            )
        } catch {
            _ = try? await providers.configurations.unregister(request)
            throw error
        }

        let delivery = AuthorityRemoteLogDelivery(
            session: started.session,
            configuration: resolved.delivery
        )
        let stdoutPipe = Pipe()
        let stderrPipe = configuration.initProcess.terminal ? nil : Pipe()
        let pump = AuthorityRemoteLogPump(
            delivery: delivery,
            processGeneration: processGeneration,
            sequenceReservation: sequenceReservation,
            sequenceStore: sequenceStore,
            stdoutForeground: stdio[safe: 1] ?? nil,
            stderrForeground: stdio[safe: 2] ?? nil
        )
        let stdoutTask = Self.readerTask(
            handle: stdoutPipe.fileHandleForReading,
            stream: .stdout,
            pump: pump
        )
        var readerTasks = [stdoutTask]
        var authorityWriteHandles = [stdoutPipe.fileHandleForWriting]
        if let stderrPipe {
            readerTasks.append(
                Self.readerTask(
                    handle: stderrPipe.fileHandleForReading,
                    stream: .stderr,
                    pump: pump
                )
            )
            authorityWriteHandles.append(stderrPipe.fileHandleForWriting)
        }

        var runtimeStdio = Array(stdio.prefix(3))
        while runtimeStdio.count < 3 {
            runtimeStdio.append(nil)
        }
        runtimeStdio[1] = stdoutPipe.fileHandleForWriting
        runtimeStdio[2] = stderrPipe?.fileHandleForWriting
        runs[containerID] = Run(
            request: request,
            provider: selection.provider,
            controller: controller,
            session: started.session,
            delivery: delivery,
            pump: pump,
            readerTasks: readerTasks,
            authorityWriteHandles: authorityWriteHandles,
            activation: nil
        )
        return runtimeStdio
    }

    /// Drops the authority's pipe-writer copies after XPC bootstrap has
    /// transferred descriptors to the runtime. Runtime close then produces EOF.
    package func bootstrapSucceeded(containerID: String) throws {
        guard var run = runs[containerID] else {
            return
        }
        for handle in run.authorityWriteHandles {
            try? handle.close()
        }
        run.authorityWriteHandles.removeAll()
        runs[containerID] = run
    }

    package func activate(containerID: String) async throws {
        guard var run = runs[containerID] else {
            return
        }
        guard run.activation == nil else {
            throw AuthorityRemoteLogDriverPlaneError.runAlreadyActivated(
                containerID
            )
        }
        run.activation = try await run.controller.activateWriter(run.request)
        runs[containerID] = run
    }

    package func abortBootstrap(containerID: String) async throws {
        guard let run = runs.removeValue(forKey: containerID) else {
            return
        }
        var firstError: (any Error)?
        do {
            try await finishPipes(run)
        } catch {
            firstError = error
        }
        do {
            _ = try await run.controller.closePreparedWriter(
                run.request,
                using: run.provider
            )
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        do {
            _ = try await providers.configurations.unregister(run.request)
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func close(containerID: String) async throws {
        guard let run = runs.removeValue(forKey: containerID) else {
            return
        }
        var firstError: (any Error)?
        do {
            try await finishPipes(run)
        } catch {
            firstError = error
        }
        guard let activation = run.activation else {
            do {
                _ = try await run.controller.closePreparedWriter(
                    run.request,
                    using: run.provider
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
            do {
                _ = try await providers.configurations.unregister(run.request)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
            if let firstError {
                throw firstError
            }
            return
        }
        do {
            _ = try await run.controller.closeWriter(
                activation,
                using: run.provider
            )
        } catch {
            do {
                let cleanupID =
                    "cleanup-"
                    + Self.sha256Hex(
                        Data(run.request.sessionID.utf8)
                    )
                let outcome = try await run.controller.fenceWriterAtDeadline(
                    activation,
                    cleanupID: cleanupID,
                    using: run.provider
                )
                if case .detached(let cleanup) = outcome {
                    Task {
                        try? await run.controller.runDetachedCleanup(
                            cleanup,
                            using: run.provider
                        )
                    }
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        do {
            _ = try await providers.configurations.unregister(run.request)
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// Opens a generation-fenced direct reader for a non-core provider. The
    /// same durable lifecycle ledger used by the writer owns reader intent,
    /// the sealed provider token, close recovery, and terminal reclamation.
    package func openReader(
        containerID: String,
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        authenticatedProtectedOptions: [String: String],
        read: ContainerLogReadRequest
    ) async throws -> any ContainerLogReader {
        guard
            configuration.id == containerID,
            let resolved = configuration.logging.resolved,
            resolved.providerIdentity.kind != .core,
            resolved.readPolicy.source == .direct
        else {
            throw AuthorityRemoteLogDriverPlaneError
                .incompleteConfiguration
        }
        let selection = try await providers.registry.selection(for: resolved)
        let controllerID = Self.controllerID(
            containerID: containerID,
            leaseGeneration: resolved.leaseGeneration
        )
        let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
            fileURL: bundle.containerLoggingV2.appendingPathComponent(
                "provider-lifecycle-\(resolved.leaseGeneration)-v1.json"
            )
        )
        let ledger = try await ContainerLogLifecycleLedgerV1.open(
            owningControllerID: controllerID,
            persistence: persistence
        )
        let controller = ContainerLogLifecycleControllerV1(
            ledger: ledger,
            protectedEffects: protectedEffects
        )
        let options = try Self.mergedOptions(
            resolved: resolved,
            protected: authenticatedProtectedOptions
        )
        try await controller.reconcilePendingEffectRemovals(
            using: selection.provider
        )
        try await reconcilePriorReaders(
            ledger: ledger,
            controller: controller,
            configuration: configuration,
            options: options
        )

        let source = try readerSource(
            containerID: containerID,
            resolved: resolved
        )
        let operationGeneration = try Self.nextReaderOperationGeneration(
            await ledger.snapshot()
        )
        let semanticDigest = try Self.readerSemanticDigest(
            containerID: containerID,
            configuration: configuration.logging,
            source: source,
            read: read
        )
        let identityDigest = Self.sha256Hex(
            Data(
                "\(containerID)\u{0}\(resolved.leaseGeneration)\u{0}\(operationGeneration)\u{0}\(semanticDigest)"
                    .utf8
            )
        )
        let request = try LogDriverReaderOpenRequestV1(
            operationGeneration: operationGeneration,
            idempotencyKey: "reader-\(identityDigest)",
            semanticRequestDigest: semanticDigest,
            readerSessionID: "reader-session-\(identityDigest)",
            containerID: containerID,
            leaseGeneration: resolved.leaseGeneration,
            providerID: resolved.providerIdentity.id,
            providerGeneration: resolved.providerGenerationAtResolution,
            source: source,
            read: read
        )
        try await registerReaderConfiguration(
            request: request,
            options: options,
            configuration: configuration
        )

        let started: StartedLogDriverReaderV1
        do {
            started = try await controller.prepareReader(
                request,
                using: selection.provider
            )
        } catch {
            _ = try? await providers.configurations.unregister(request)
            throw error
        }
        let session: LoggingReaderSessionV1
        do {
            session = try await controller.activateReader(request)
        } catch {
            _ = try? await controller.closePreparedReader(
                request,
                using: selection.provider
            )
            _ = try? await providers.configurations.unregister(request)
            throw error
        }
        readerRuns[request.readerSessionID] = ReaderRun(
            request: request,
            provider: selection.provider,
            controller: controller,
            session: session
        )
        return AuthorityRemoteLogReader(reader: started.reader) {
            try await self.closeReader(
                readerSessionID: request.readerSessionID
            )
        }
    }

    private func closeReader(readerSessionID: String) async throws {
        guard !closingReaderIDs.contains(readerSessionID) else {
            return
        }
        guard let run = readerRuns[readerSessionID] else {
            return
        }
        closingReaderIDs.insert(readerSessionID)
        defer { closingReaderIDs.remove(readerSessionID) }
        _ = try await run.controller.closeReader(
            run.session,
            using: run.provider
        )
        _ = try await providers.configurations.unregister(run.request)
        readerRuns.removeValue(forKey: readerSessionID)
    }

    private func finishPipes(_ run: Run) async throws {
        for handle in run.authorityWriteHandles {
            try? handle.close()
        }
        for task in run.readerTasks {
            await task.value
        }
        try await run.delivery.finish()
        let pump = await run.pump.metrics()
        let delivery = await run.delivery.metrics()
        let lastWriteFailure = await run.delivery.lastWriteFailureDescription()
        guard
            pump.failedStreams > 0 || delivery.writeFailures > 0
                || delivery.droppedRecords > 0
        else {
            return
        }
        log.error(
            "authority remote logging closed with delivery failures",
            metadata: [
                "stdoutBytes": "\(pump.stdoutBytes)",
                "stderrBytes": "\(pump.stderrBytes)",
                "stdoutRecords": "\(pump.stdoutRecords)",
                "stderrRecords": "\(pump.stderrRecords)",
                "finishedStreams": "\(pump.finishedStreams)",
                "failedStreams": "\(pump.failedStreams)",
                "writeFailures": "\(delivery.writeFailures)",
                "lastWriteFailure": "\(lastWriteFailure ?? "none")",
                "droppedRecords": "\(delivery.droppedRecords)",
            ]
        )
    }

    private func reconcilePriorRuns(
        ledger: ContainerLogLifecycleLedgerV1,
        controller: ContainerLogLifecycleControllerV1,
        configuration: ContainerConfiguration,
        options: [String: String],
        semanticDigest: String
    ) async throws {
        let snapshot = await ledger.snapshot()
        for cleanup in snapshot.detachedCleanups
        where cleanup.state != .complete && cleanup.state != .tombstoned {
            guard
                let selection = await providers.registry.selection(
                    providerID: cleanup.providerID,
                    generation: cleanup.providerGeneration
                )
            else {
                throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                    cleanup.providerID
                )
            }
            _ = try await controller.runDetachedCleanup(
                cleanup,
                using: selection.provider
            )
        }
        for record in snapshot.writerOperations {
            if record.result == .reserved
                || record.result == .startRecoveryRequired
            {
                guard
                    record.request.semanticRequestDigest == semanticDigest,
                    let selection = await providers.registry.selection(
                        providerID: record.request.providerID,
                        generation: record.request.providerGeneration
                    )
                else {
                    throw AuthorityRemoteLogDriverPlaneError
                        .incompleteConfiguration
                }
                try await registerConfiguration(
                    request: record.request,
                    options: options,
                    configuration: configuration
                )
                do {
                    if try await retireAbsentWriterFromPriorSandbox(
                        record.request,
                        ledger: ledger,
                        configuration: configuration,
                        provider: selection.provider
                    ) {
                        _ = try await providers.configurations.unregister(
                            record.request
                        )
                        continue
                    }
                    _ = try await controller.prepareWriter(
                        record.request,
                        using: selection.provider
                    )
                    _ = try await controller.closePreparedWriter(
                        record.request,
                        using: selection.provider
                    )
                    _ = try await providers.configurations.unregister(
                        record.request
                    )
                } catch {
                    _ = try? await providers.configurations.unregister(
                        record.request
                    )
                    throw error
                }
            } else if let activation = record.result.activation,
                activation.state != .closed,
                activation.state != .tombstoned
            {
                guard
                    let selection = await providers.registry.selection(
                        providerID: record.request.providerID,
                        generation: record.request.providerGeneration
                    )
                else {
                    throw
                        AuthorityRemoteLogDriverPlaneError
                        .unsupportedDriver(record.request.providerID)
                }
                _ = try await controller.closeWriter(
                    activation,
                    using: selection.provider
                )
            } else if record.result.preparation != nil {
                guard
                    let selection = await providers.registry.selection(
                        providerID: record.request.providerID,
                        generation: record.request.providerGeneration
                    )
                else {
                    throw
                        AuthorityRemoteLogDriverPlaneError
                        .unsupportedDriver(record.request.providerID)
                }
                _ = try await controller.closePreparedWriter(
                    record.request,
                    using: selection.provider
                )
            }
        }
    }

    private func reconcilePriorReaders(
        ledger: ContainerLogLifecycleLedgerV1,
        controller: ContainerLogLifecycleControllerV1,
        configuration: ContainerConfiguration,
        options: [String: String]
    ) async throws {
        let snapshot = await ledger.snapshot()
        for record in snapshot.readerOperations {
            guard
                let selection = await providers.registry.selection(
                    providerID: record.request.providerID,
                    generation: record.request.providerGeneration
                )
            else {
                throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                    record.request.providerID
                )
            }
            switch record.result {
            case .reserved, .openRecoveryRequired:
                try await registerReaderConfiguration(
                    request: record.request,
                    options: options,
                    configuration: configuration
                )
                do {
                    _ = try await controller.prepareReader(
                        record.request,
                        using: selection.provider
                    )
                    _ = try await controller.closePreparedReader(
                        record.request,
                        using: selection.provider
                    )
                    _ = try await providers.configurations.unregister(
                        record.request
                    )
                } catch {
                    _ = try? await providers.configurations.unregister(
                        record.request
                    )
                    throw error
                }
            case .prepared, .candidateClosing,
                .candidateRecoveryRequired:
                try await registerReaderConfiguration(
                    request: record.request,
                    options: options,
                    configuration: configuration
                )
                do {
                    _ = try await controller.closePreparedReader(
                        record.request,
                        using: selection.provider
                    )
                    _ = try await providers.configurations.unregister(
                        record.request
                    )
                } catch {
                    _ = try? await providers.configurations.unregister(
                        record.request
                    )
                    throw error
                }
            case .candidateClosed:
                continue
            case .activated(let session):
                guard
                    session.state != .closed,
                    session.state != .tombstoned
                else {
                    continue
                }
                _ = try await controller.closeReader(
                    session,
                    using: selection.provider
                )
            }
        }
    }

    /// A tokenless start from a retired sandbox generation cannot be replayed
    /// into the current generation. Reconcile its exact idempotency scope and
    /// make an observed absence terminal before allocating the next process
    /// generation.
    private func retireAbsentWriterFromPriorSandbox(
        _ request: LogDriverStartRequestV1,
        ledger: ContainerLogLifecycleLedgerV1,
        configuration: ContainerConfiguration,
        provider: any ContainerLogDriverProvider
    ) async throws -> Bool {
        guard let requestedGeneration = request.candidateSandboxGeneration else {
            return false
        }
        let resolved = try Self.requireResolved(configuration.logging)
        guard
            let activeGeneration = try await sandboxGeneration(
                for: resolved,
                provider: provider
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError.incompleteConfiguration
        }
        guard activeGeneration >= requestedGeneration else {
            throw AuthorityRemoteLogDriverPlaneError.generationMismatch(
                expected: requestedGeneration,
                actual: activeGeneration
            )
        }
        guard activeGeneration > requestedGeneration else {
            return false
        }
        guard case .absent = try await provider.reconcileStart(request) else {
            return false
        }
        _ = try await ledger.completeAbsentWriterStart(for: request)
        return true
    }

    private func registerConfiguration(
        request: LogDriverStartRequestV1,
        options: [String: String],
        configuration: ContainerConfiguration
    ) async throws {
        let resolved = try Self.requireResolved(configuration.logging)
        let info = SyslogContainerInfo(
            containerID: configuration.id,
            containerName: configuration.id,
            containerEntrypoint: configuration.initProcess.executable,
            containerArguments: configuration.initProcess.arguments,
            containerImageID: configuration.image.digest,
            containerImageName: configuration.image.reference,
            containerCreated: configuration.creationDate,
            containerEnvironment: configuration.initProcess.environment,
            containerLabels: configuration.labels,
            hostname: configuration.hostname
                ?? ProcessInfo.processInfo.hostName
        )
        if resolved.providerIdentity.kind == .dockerPlugin {
            try await providers.configurations.register(
                DockerPluginConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    info: try Self.dockerPluginInfo(
                        configuration: configuration,
                        options: options
                    )
                ),
                for: request
            )
            return
        }
        switch resolved.driver {
        case "syslog":
            let helper = try DockerSemanticHelperClient.shared(
                for: DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try SyslogDriverConfiguration.resolve(
                options: options,
                info: info,
                semanticService: helper
            )
            try await providers.configurations.register(
                SyslogConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration
                ),
                for: request
            )
        case "fluentd":
            let helper = try DockerSemanticHelperClient.shared(
                for: DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try FluentdDriverConfiguration.resolve(
                options: options,
                info: info,
                semanticService: helper
            )
            try await providers.configurations.register(
                FluentdConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration
                ),
                for: request
            )
        case "gelf":
            let driverConfiguration = try GELFDriverConfiguration.resolve(
                options: options,
                info: info
            )
            try await providers.configurations.register(
                GELFConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration
                ),
                for: request
            )
        case "splunk":
            let helper = try DockerSemanticHelperClient.shared(
                for: DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try SplunkDriverConfiguration.resolve(
                options: options,
                info: info,
                semanticService: helper
            )
            try await providers.configurations.register(
                SplunkConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration
                ),
                for: request
            )
        case "awslogs":
            let helper = try DockerSemanticHelperClient.shared(
                for: DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try AWSLogsDriverConfiguration.resolve(
                options: options,
                info: info,
                semanticService: helper
            )
            try await providers.configurations.register(
                AWSLogsConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration,
                    multilineMatcher:
                        DockerSemanticAWSLogsMultilineMatcher(
                            semanticService: helper
                        )
                ),
                for: request
            )
        case "gcplogs":
            let helper = try gcpLoggingServiceFactory(
                DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try GCPLogsDriverConfiguration.resolve(
                options: options,
                info: info
            )
            try await providers.configurations.register(
                GCPLogsConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration,
                    loggingService: helper
                ),
                for: request
            )
        case "journald":
            let helper = try DockerSemanticHelperClient.shared(
                for: DockerSemanticHelperGeneration(
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration
                )
            )
            let driverConfiguration = try JournaldDriverConfiguration.resolve(
                options: options,
                info: info,
                semanticService: helper
            )
            try await providers.configurations.register(
                JournaldConfigurationBinding(
                    semanticRequestDigest: request.semanticRequestDigest,
                    containerID: request.containerID,
                    leaseGeneration: request.leaseGeneration,
                    providerID: request.providerID,
                    providerGeneration: request.providerGeneration,
                    configuration: driverConfiguration
                ),
                for: request
            )
        default:
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                resolved.driver
            )
        }
    }

    private func registerReaderConfiguration(
        request: LogDriverReaderOpenRequestV1,
        options: [String: String],
        configuration: ContainerConfiguration
    ) async throws {
        let resolved = try Self.requireResolved(configuration.logging)
        guard resolved.providerIdentity.kind == .dockerPlugin else {
            return
        }
        try await providers.configurations.register(
            DockerPluginConfigurationBinding(
                semanticRequestDigest: request.semanticRequestDigest,
                containerID: request.containerID,
                leaseGeneration: request.leaseGeneration,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration,
                info: try Self.dockerPluginInfo(
                    configuration: configuration,
                    options: options
                )
            ),
            for: request
        )
    }

    private static func dockerPluginInfo(
        configuration: ContainerConfiguration,
        options: [String: String]
    ) throws -> DockerPluginInfo {
        try DockerPluginInfo(
            config: options,
            containerID: configuration.id,
            containerName: "/\(configuration.id)",
            containerEntrypoint: configuration.initProcess.executable,
            containerArgs: configuration.initProcess.arguments,
            containerImageID: configuration.image.digest,
            containerImageName: configuration.image.reference,
            containerCreated: configuration.creationDate,
            containerEnv: configuration.initProcess.environment,
            containerLabels: configuration.labels,
            logPath: "",
            daemonName: "docker"
        )
    }

    private static func mergedOptions(
        resolved: ResolvedContainerLogConfiguration,
        protected: [String: String]
    ) throws -> [String: String] {
        guard Set(protected.keys) == Set(resolved.protectedOptionNames) else {
            throw AuthorityRemoteLogDriverPlaneError.incompleteConfiguration
        }
        var options = resolved.safeOptions
        for (name, value) in protected {
            guard options.updateValue(value, forKey: name) == nil else {
                throw AuthorityRemoteLogDriverPlaneError
                    .incompleteConfiguration
            }
        }
        return options
    }

    private func sandboxGeneration(
        for resolved: ResolvedContainerLogConfiguration,
        provider: any ContainerLogDriverProvider
    ) async throws -> UInt64? {
        guard
            resolved.providerIdentity.kind == .linuxService
                || resolved.providerIdentity.kind == .dockerPlugin
        else {
            return nil
        }
        guard
            let sandboxProvider =
                provider as? any EngineLinuxSandboxLogDriverProvider
        else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                resolved.driver
            )
        }
        return try await sandboxProvider.activeSandboxGeneration()
    }

    private func readerSource(
        containerID: String,
        resolved: ResolvedContainerLogConfiguration
    ) throws -> LoggingReaderSourceV1 {
        guard let activation = runs[containerID]?.activation else {
            return .stoppedContainer
        }
        guard
            activation.providerID == resolved.providerIdentity.id,
            activation.providerGeneration
                == resolved.providerGenerationAtResolution,
            activation.leaseGeneration == resolved.leaseGeneration
        else {
            throw AuthorityRemoteLogDriverPlaneError
                .incompleteConfiguration
        }
        return .activeWriter(
            sessionID: activation.sessionID,
            writerProviderID: activation.providerID,
            writerProviderGeneration: activation.providerGeneration,
            activeProcessGeneration: activation.activeProcessGeneration,
            activeSandboxGeneration: activation.activeSandboxGeneration
        )
    }

    private static func semanticDigest(
        containerID: String,
        configuration: ContainerLogConfiguration
    ) throws -> String {
        let binding = try LoggingProtectedOptionsBinding(
            containerID: containerID,
            configuration: configuration
        )
        let reference = configuration.resolved?.protectedOptionReference
        var data = Data("container.logging.semantic-request.v1\u{0}".utf8)
        data.append(try binding.canonicalData())
        data.append(0)
        data.append(Data((reference?.objectID ?? "-").utf8))
        data.append(0)
        data.append(Data((reference?.integrityDigest ?? "-").utf8))
        return "sha256:" + sha256Hex(data)
    }

    private static func readerSemanticDigest(
        containerID: String,
        configuration: ContainerLogConfiguration,
        source: LoggingReaderSourceV1,
        read: ContainerLogReadRequest
    ) throws -> String {
        let writerDigest = try semanticDigest(
            containerID: containerID,
            configuration: configuration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data("container.logging.reader.semantic-request.v1\u{0}".utf8)
        data.append(Data(writerDigest.utf8))
        data.append(0)
        data.append(try encoder.encode(source))
        data.append(0)
        data.append(try encoder.encode(read))
        return "sha256:" + sha256Hex(data)
    }

    private static func nextReaderOperationGeneration(
        _ snapshot: ContainerLogLifecycleLedgerSnapshotV1
    ) throws -> UInt64 {
        let current =
            snapshot.readerOperations.map {
                $0.request.operationGeneration
            }.max() ?? 0
        guard current < UInt64.max else {
            throw AuthorityRemoteLogDriverPlaneError
                .incompleteConfiguration
        }
        return current + 1
    }

    private static func controllerID(
        containerID: String,
        leaseGeneration: UInt64
    ) -> String {
        let digest = sha256Hex(Data(containerID.utf8))
        return "container-\(digest)-lease-\(leaseGeneration)"
    }

    private static func requireResolved(
        _ configuration: ContainerLogConfiguration
    ) throws -> ResolvedContainerLogConfiguration {
        guard let resolved = configuration.resolved else {
            throw AuthorityRemoteLogDriverPlaneError.incompleteConfiguration
        }
        return resolved
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func readerTask(
        handle: FileHandle,
        stream: ContainerLogStream,
        pump: AuthorityRemoteLogPump
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            defer { try? handle.close() }
            do {
                while true {
                    guard
                        let data = try handle.read(upToCount: 64 * 1024),
                        !data.isEmpty
                    else {
                        break
                    }
                    await pump.consume(data, stream: stream)
                }
                await pump.finish(stream: stream)
            } catch {
                await pump.fail(stream: stream)
            }
        }
    }
}

extension AuthorityRemoteLogDriverPlane:
    LoggingHandoffProviderHistoryPreflighting,
    LoggingHandoffProviderHistoryPromoting
{
    func preflightProviderHistory(
        containerID: String,
        history: LoggingHandoffHistoryStoreV1,
        destination: PreparedContainerLogResolution,
        handoffManifestDigestSHA256: String,
        destinationStateRootUUID: String
    ) async throws {
        let request = try Self.historyHandoffDestinationRequest(
            containerID: containerID,
            history: history,
            descriptor: destination.descriptor,
            destinationLeaseGeneration: 1,
            manifestDigestSHA256: handoffManifestDigestSHA256,
            destinationStateRootUUID: destinationStateRootUUID
        )
        guard
            let selection = await providers.registry.selection(
                providerID: request.destinationProviderID,
                generation: request.destinationProviderGeneration
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                destination.descriptor.driver
            )
        }
        try await selection.provider.preflightHistoryHandoff(request)
    }

    func promoteProviderHistory(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffHistoryStoreV1],
        authorization: LoggingHandoffPromotionAuthorizationV1
    ) async throws {
        let (provider, request) = try await historyHandoffPromotion(
            container: container,
            history: history,
            tokenID: authorization.tokenID,
            manifestID: authorization.manifestID,
            manifestDigestSHA256: authorization.manifestDigest,
            destinationStateRootUUID: authorization.destinationStateRootUUID,
            commitDigestSHA256: authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                authorization.handoffChainHeadDigestSHA256
        )
        let receipt = try await provider.promoteHistoryHandoff(request)
        guard receipt.request == request else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: container.containerID
                )
        }
    }

    func activateProviderHistory(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffHistoryStoreV1],
        promotionReceipt _: LoggingHandoffControllerPromotionReceiptV1,
        authorization: LoggingHandoffActivationAuthorizationV1
    ) async throws {
        let (provider, request) = try await historyHandoffPromotion(
            container: container,
            history: history,
            tokenID: authorization.tokenID,
            manifestID: authorization.manifestID,
            manifestDigestSHA256: authorization.manifestDigest,
            destinationStateRootUUID: authorization.destinationStateRootUUID,
            commitDigestSHA256: authorization.commitDigestSHA256,
            handoffChainHeadDigestSHA256:
                authorization.handoffChainHeadDigestSHA256
        )
        let receipt = try await provider.promoteHistoryHandoff(request)
        guard receipt.request == request else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: container.containerID
                )
        }
        try await provider.activateHistoryHandoff(
            LogDriverHistoryHandoffActivationRequestV1(
                promotionReceipt: receipt,
                terminalOutcomeDigestSHA256:
                    authorization.terminalOutcomeDigestSHA256
            )
        )
    }

    private func historyHandoffPromotion(
        container: LoggingHandoffStagedContainerV1,
        history: [LoggingHandoffHistoryStoreV1],
        tokenID: String,
        manifestID: String,
        manifestDigestSHA256: String,
        destinationStateRootUUID: String,
        commitDigestSHA256: String,
        handoffChainHeadDigestSHA256: String
    ) async throws -> (
        any ContainerLogDriverProvider,
        LogDriverHistoryHandoffPromotionRequestV1
    ) {
        guard
            history.count == 1,
            let resolved = container.configuration.resolved,
            let export = history[0].providerExportReceipt,
            export.request.tokenID == tokenID,
            export.request.manifestID == manifestID
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: container.containerID
                )
        }
        let destination = try Self.historyHandoffDestinationRequest(
            containerID: container.containerID,
            history: history[0],
            descriptorIdentity: (
                resolved.providerIdentity.id,
                resolved.providerGenerationAtResolution,
                resolved.contractDigest
            ),
            destinationLeaseGeneration: resolved.leaseGeneration,
            manifestDigestSHA256: manifestDigestSHA256,
            destinationStateRootUUID: destinationStateRootUUID
        )
        guard
            let selection = await providers.registry.selection(
                providerID: destination.destinationProviderID,
                generation: destination.destinationProviderGeneration
            )
        else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                resolved.driver
            )
        }
        return (
            selection.provider,
            try LogDriverHistoryHandoffPromotionRequestV1(
                destination: destination,
                commitDigestSHA256: commitDigestSHA256,
                handoffChainHeadDigestSHA256: handoffChainHeadDigestSHA256
            )
        )
    }

    private static func historyHandoffDestinationRequest(
        containerID: String,
        history: LoggingHandoffHistoryStoreV1,
        descriptor: LogDriverDescriptor,
        destinationLeaseGeneration: UInt64,
        manifestDigestSHA256: String,
        destinationStateRootUUID: String
    ) throws -> LogDriverHistoryHandoffDestinationRequestV1 {
        try historyHandoffDestinationRequest(
            containerID: containerID,
            history: history,
            descriptorIdentity: (
                descriptor.providerIdentity.id,
                descriptor.providerGeneration,
                descriptor.optionContractDigest
            ),
            destinationLeaseGeneration: destinationLeaseGeneration,
            manifestDigestSHA256: manifestDigestSHA256,
            destinationStateRootUUID: destinationStateRootUUID
        )
    }

    private static func historyHandoffDestinationRequest(
        containerID: String,
        history: LoggingHandoffHistoryStoreV1,
        descriptorIdentity: (id: String, generation: UInt64, contract: String),
        destinationLeaseGeneration: UInt64,
        manifestDigestSHA256: String,
        destinationStateRootUUID: String
    ) throws -> LogDriverHistoryHandoffDestinationRequestV1 {
        guard
            history.kind == .providerOwned,
            history.disposition == .providerExportVerified,
            let export = history.providerExportReceipt,
            history.providerExportDigestSHA256
                == export.exportReceiptDigestSHA256,
            export.request.containerID == containerID,
            export.request.destinationStateRootUUID
                == destinationStateRootUUID
        else {
            throw
                AuthorityRemoteLogDriverPlaneError
                .providerHistoryHandoffReceiptMismatch(
                    containerID: containerID
                )
        }
        return try LogDriverHistoryHandoffDestinationRequestV1(
            exportReceipt: export,
            manifestDigestSHA256: manifestDigestSHA256,
            destinationLeaseGeneration: destinationLeaseGeneration,
            destinationProviderID: descriptorIdentity.id,
            destinationProviderGeneration: descriptorIdentity.generation,
            destinationContractDigest: descriptorIdentity.contract
        )
    }
}

private actor AuthorityRemoteLogReader: ContainerLogReader {
    private let reader: any ContainerLogReader
    private let closeLifecycle: @Sendable () async throws -> Void
    private var ended = false

    init(
        reader: any ContainerLogReader,
        closeLifecycle: @escaping @Sendable () async throws -> Void
    ) {
        self.reader = reader
        self.closeLifecycle = closeLifecycle
    }

    func next() async throws -> ContainerLogReaderEventV1 {
        guard !ended else {
            throw ContainerLogReaderError.alreadyEnded
        }
        do {
            let event = try await reader.next()
            if event == .endOfStream {
                ended = true
                try await closeLifecycle()
            }
            return event
        } catch {
            ended = true
            await reader.cancel()
            try? await closeLifecycle()
            throw error
        }
    }

    func cancel() async {
        guard !ended else {
            return
        }
        ended = true
        await reader.cancel()
        try? await closeLifecycle()
    }
}

private final class AuthorityRemoteLogEventLoopOwner: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup

    init(threadCount: Int) {
        self.group = MultiThreadedEventLoopGroup(
            numberOfThreads: threadCount
        )
    }

    deinit {
        try? group.syncShutdownGracefully()
    }
}

package struct AuthorityRemoteLogDeliveryMetrics: Equatable, Sendable {
    package let queuedRecords: Int
    package let queuedBytes: UInt64
    package let droppedRecords: UInt64
    package let writeFailures: UInt64
}

package actor AuthorityRemoteLogDelivery {
    private let session: any ContainerLogDriverSession
    private let mode: LogDeliveryConfiguration.Mode
    private let capacity: UInt64
    // A moving head avoids Array.removeFirst's O(n) copy for every record.
    // Consumed optional slots release payload storage immediately; occasional
    // compaction keeps the backing allocation proportional to the live queue.
    private var queue = [ContainerLogRecordV2?]()
    private var queueHead = 0
    private var queuedBytes: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var closing = false
    private(set) var droppedRecords: UInt64 = 0
    private(set) var writeFailures: UInt64 = 0
    private var lastWriteFailure: String?

    init(
        session: any ContainerLogDriverSession,
        configuration: LogDeliveryConfiguration
    ) {
        self.session = session
        self.mode = configuration.effectiveMode
        self.capacity =
            configuration.effectiveMaxBufferSizeInBytes
            ?? LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes
    }

    func submit(_ record: ContainerLogRecordV2) async {
        guard !closing else {
            increment(&droppedRecords)
            return
        }
        if mode == .blocking {
            do {
                try await session.write(record)
            } catch {
                increment(&writeFailures)
                lastWriteFailure = String(describing: error)
            }
            return
        }

        let size = Self.recordSize(record)
        if size > capacity {
            // Docker admits one oversized message when the queue is otherwise
            // empty, then applies drop-new while that message is in flight.
            guard queueHead == queue.count, worker == nil else {
                increment(&droppedRecords)
                return
            }
        } else if queuedBytes > capacity - size {
            increment(&droppedRecords)
            return
        }
        queue.append(record)
        queuedBytes = size > capacity ? capacity : queuedBytes + size
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    func finish() async throws {
        closing = true
        let activeWorker = worker
        await activeWorker?.value
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        try await session.flush(deadline: deadline)
    }

    package func metrics() -> AuthorityRemoteLogDeliveryMetrics {
        AuthorityRemoteLogDeliveryMetrics(
            queuedRecords: queue.count - queueHead,
            queuedBytes: queuedBytes,
            droppedRecords: droppedRecords,
            writeFailures: writeFailures
        )
    }

    func lastWriteFailureDescription() -> String? {
        lastWriteFailure
    }

    private func drain() async {
        while queueHead < queue.count {
            guard let record = queue[queueHead] else {
                queueHead += 1
                continue
            }
            queue[queueHead] = nil
            queueHead += 1
            let size = Self.recordSize(record)
            queuedBytes = size >= queuedBytes ? 0 : queuedBytes - size
            do {
                try await session.write(record)
            } catch {
                increment(&writeFailures)
                lastWriteFailure = String(describing: error)
            }
            compactQueueIfNeeded()
        }
        queue.removeAll(keepingCapacity: true)
        queueHead = 0
        worker = nil
    }

    private func compactQueueIfNeeded() {
        guard queueHead >= 1_024, queueHead >= queue.count / 2 else {
            return
        }
        queue.removeFirst(queueHead)
        queueHead = 0
    }

    private static func recordSize(_ record: ContainerLogRecordV2) -> UInt64 {
        let base = record.payload.count.addingReportingOverflow(128)
        guard !base.overflow else {
            return UInt64.max
        }
        var bytes = UInt64(base.partialValue)
        for (key, value) in record.attributes {
            let entryBytes = key.utf8.count.addingReportingOverflow(
                value.utf8.count
            )
            guard !entryBytes.overflow else {
                return UInt64.max
            }
            let entry = UInt64(entryBytes.partialValue)
            let addition = bytes.addingReportingOverflow(entry)
            if addition.overflow {
                return UInt64.max
            }
            bytes = addition.partialValue
        }
        return bytes
    }

    private func increment(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}

private actor AuthorityRemoteLogPump {
    private let delivery: AuthorityRemoteLogDelivery
    private let processGeneration: UInt64
    private let sequenceStore: ContainerLogProcessGenerationStore
    private var stdoutSplitter = ContainerLogRecordSplitterV1(stream: .stdout)
    private var stderrSplitter = ContainerLogRecordSplitterV1(stream: .stderr)
    private var foreground: [ContainerLogStream: FileHandle]
    private var nextSequence: UInt64
    private var reservedUpperBound: UInt64
    private var failedStreams = Set<ContainerLogStream>()
    private var finishedStreams = Set<ContainerLogStream>()
    private var receivedBytes: [ContainerLogStream: UInt64] = [:]
    private var emittedRecords: [ContainerLogStream: UInt64] = [:]

    init(
        delivery: AuthorityRemoteLogDelivery,
        processGeneration: UInt64,
        sequenceReservation: ContainerLogSequenceReservationV1,
        sequenceStore: ContainerLogProcessGenerationStore,
        stdoutForeground: FileHandle?,
        stderrForeground: FileHandle?
    ) {
        self.delivery = delivery
        self.processGeneration = processGeneration
        self.sequenceStore = sequenceStore
        nextSequence = sequenceReservation.lowerBound
        reservedUpperBound = sequenceReservation.upperBoundInclusive
        var foreground = [ContainerLogStream: FileHandle]()
        foreground[.stdout] = stdoutForeground
        foreground[.stderr] = stderrForeground
        self.foreground = foreground
    }

    func consume(_ data: Data, stream: ContainerLogStream) async {
        increment(&receivedBytes[stream, default: 0], by: UInt64(data.count))
        if let handle = foreground[stream] {
            do {
                try handle.write(contentsOf: data)
            } catch {
                foreground.removeValue(forKey: stream)
                try? handle.close()
            }
        }
        var fragments = [ContainerLogRecordFragmentV1]()
        switch stream {
        case .stdout:
            stdoutSplitter.append(data) { fragments.append($0) }
        case .stderr:
            stderrSplitter.append(data) { fragments.append($0) }
        }
        increment(&emittedRecords[stream, default: 0], by: UInt64(fragments.count))
        await deliver(fragments)
    }

    func finish(stream: ContainerLogStream) async {
        var fragments = [ContainerLogRecordFragmentV1]()
        switch stream {
        case .stdout:
            stdoutSplitter.finish { fragments.append($0) }
        case .stderr:
            stderrSplitter.finish { fragments.append($0) }
        }
        increment(&emittedRecords[stream, default: 0], by: UInt64(fragments.count))
        await deliver(fragments)
        finishedStreams.insert(stream)
        if let handle = foreground.removeValue(forKey: stream) {
            try? handle.close()
        }
    }

    func fail(stream: ContainerLogStream) async {
        failedStreams.insert(stream)
        await finish(stream: stream)
    }

    func metrics() -> AuthorityRemoteLogPumpMetrics {
        AuthorityRemoteLogPumpMetrics(
            stdoutBytes: receivedBytes[.stdout, default: 0],
            stderrBytes: receivedBytes[.stderr, default: 0],
            stdoutRecords: emittedRecords[.stdout, default: 0],
            stderrRecords: emittedRecords[.stderr, default: 0],
            finishedStreams: finishedStreams.count,
            failedStreams: failedStreams.count
        )
    }

    private func deliver(
        _ fragments: [ContainerLogRecordFragmentV1]
    ) async {
        for fragment in fragments {
            if nextSequence > reservedUpperBound {
                guard
                    let reservation =
                        try? sequenceStore
                        .reserveSequenceBlock(),
                    reservation.lowerBound > reservedUpperBound
                else {
                    return
                }
                nextSequence = reservation.lowerBound
                reservedUpperBound = reservation.upperBoundInclusive
            }
            let sequence = nextSequence
            if sequence == UInt64.max {
                nextSequence = UInt64.max
                reservedUpperBound = UInt64.max - 1
            } else {
                nextSequence = sequence + 1
            }
            guard
                let record = try? ContainerLogRecordV2(
                    fragment: fragment,
                    sequence: sequence,
                    processGeneration: processGeneration
                )
            else {
                continue
            }
            await delivery.submit(record)
        }
    }

    private func increment(_ value: inout UInt64, by amount: UInt64) {
        let addition = value.addingReportingOverflow(amount)
        value = addition.overflow ? UInt64.max : addition.partialValue
    }
}

private struct AuthorityRemoteLogPumpMetrics: Sendable {
    let stdoutBytes: UInt64
    let stderrBytes: UInt64
    let stdoutRecords: UInt64
    let stderrRecords: UInt64
    let finishedStreams: Int
    let failedStreams: Int
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
