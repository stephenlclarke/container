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
import NIOPosix

enum AuthorityRemoteLogDriverPlaneError: Error, Equatable, Sendable {
    case incompleteConfiguration
    case unsupportedDriver(String)
    case runAlreadyPrepared(String)
    case runNotPrepared(String)
    case runAlreadyActivated(String)
    case runNotActivated(String)
    case generationMismatch(expected: UInt64, actual: UInt64)
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

    private let providers: BuiltinRemoteLogDriverProviderSet
    private let protectedEffects: ProtectedLoggingEffectStore
    private let eventLoopOwner: AuthorityRemoteLogEventLoopOwner
    private let gcpLoggingServiceFactory: AuthorityGCPLoggingServiceFactory
    private var runs = [String: Run]()

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
        let providers = try await BuiltinRemoteLogDriverProviderSet.install(
            eventLoopGroup: eventLoopOwner.group,
            awsLogsClientFactory: awsLogsClientFactory,
            journaldService: journaldService,
            providerGeneration: providerGeneration
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
        let catalog = try await providers.registry.logDriverCatalog()
        guard let journald = providers.journald else {
            return catalog
        }
        do {
            _ = try await journald.activeSandboxGeneration()
            return catalog
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try LogDriverCatalog(
                descriptors: catalog.descriptors.filter {
                    $0.driver != "journald"
                }
            )
        }
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

        let processGeneration = try ContainerLogProcessGenerationStore(
            directoryURL: bundle.containerLoggingV2
        ).next()
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
                for: resolved
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

    private func finishPipes(_ run: Run) async throws {
        for handle in run.authorityWriteHandles {
            try? handle.close()
        }
        for task in run.readerTasks {
            await task.value
        }
        try await run.delivery.finish()
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
        for resolved: ResolvedContainerLogConfiguration
    ) async throws -> UInt64? {
        guard resolved.driver == "journald" else {
            return nil
        }
        guard let journald = providers.journald else {
            throw AuthorityRemoteLogDriverPlaneError.unsupportedDriver(
                resolved.driver
            )
        }
        return try await journald.activeSandboxGeneration()
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
    private var stdoutSplitter = ContainerLogRecordSplitterV1(stream: .stdout)
    private var stderrSplitter = ContainerLogRecordSplitterV1(stream: .stderr)
    private var foreground: [ContainerLogStream: FileHandle]
    private var sequence: UInt64 = 0
    private var failedStreams = Set<ContainerLogStream>()

    init(
        delivery: AuthorityRemoteLogDelivery,
        processGeneration: UInt64,
        stdoutForeground: FileHandle?,
        stderrForeground: FileHandle?
    ) {
        self.delivery = delivery
        self.processGeneration = processGeneration
        var foreground = [ContainerLogStream: FileHandle]()
        foreground[.stdout] = stdoutForeground
        foreground[.stderr] = stderrForeground
        self.foreground = foreground
    }

    func consume(_ data: Data, stream: ContainerLogStream) async {
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
        await deliver(fragments)
        if let handle = foreground.removeValue(forKey: stream) {
            try? handle.close()
        }
    }

    func fail(stream: ContainerLogStream) async {
        failedStreams.insert(stream)
        await finish(stream: stream)
    }

    private func deliver(
        _ fragments: [ContainerLogRecordFragmentV1]
    ) async {
        for fragment in fragments {
            guard sequence < UInt64.max else {
                continue
            }
            sequence += 1
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
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
