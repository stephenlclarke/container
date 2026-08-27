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

import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import CryptoKit
import Foundation
import Logging

public protocol EngineLinuxSandboxWorkloadAuthorityV1: Sendable {
    func startWorkload(
        planDigest: String,
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String],
        networkEndpoints: [WorkloadNetworkEndpoint],
        stdio: [FileHandle?],
        controllers: [any WorkloadEffectControllerV1],
        monitorTerminal: Bool
    ) async throws -> EngineWorkloadRecordV1

    func controlWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        action: EngineLinuxSandboxWorkloadControlRequestV1.Action
    ) async throws -> EngineLinuxSandboxWorkloadControlResponseV1

    func pauseWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1

    func resumeWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1

    func dialService(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) async throws -> FileHandle

    func stopWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1

    func reclaimEffectlessWorkloadAtBoot(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String
    ) async throws -> EngineWorkloadRecordV1?
}

public protocol EngineLinuxSandboxLaunchingV1: Sendable {
    func launch(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> any EngineLinuxSandboxRuntimeClientV1

    func stop(configuration: EngineLinuxSandboxRuntimeConfigurationV1) async throws
}

/// Launchd-backed ownership of the single Engine Linux runtime helper.
public struct LaunchdEngineLinuxSandboxLauncherV1: EngineLinuxSandboxLaunchingV1 {
    public static let runtimePluginName = "container-runtime-linux"

    private let loader: PluginLoader
    private let plugin: Plugin
    private let debug: Bool

    public init(loader: PluginLoader, plugin: Plugin, debug: Bool = false) throws {
        guard plugin.name == Self.runtimePluginName, plugin.hasType(.runtime) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "shared Engine sandbox requires the container-runtime-linux plugin"
            )
        }
        self.loader = loader
        self.plugin = plugin
        self.debug = debug
    }

    public func launch(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> any EngineLinuxSandboxRuntimeClientV1 {
        try configuration.write()
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: configuration.path,
            args: [
                "shared-sandbox",
                "--root", configuration.path.path,
                "--uuid", configuration.sandboxID,
            ],
            instanceId: configuration.sandboxID,
            debug: debug
        )
        return try await RuntimeClient.create(
            id: configuration.sandboxID,
            runtime: plugin.name
        )
    }

    public func stop(configuration: EngineLinuxSandboxRuntimeConfigurationV1) async throws {
        try loader.deregisterWithLaunchd(
            plugin: plugin,
            instanceId: configuration.sandboxID
        )
    }
}

/// Retains the first durable-ledger failure at the authority boundary.
///
/// `EngineWorkloadLedgerV1` correctly fails closed after a persistence error,
/// but later callers then observe its generic failed state. Keeping the
/// original operation and path in the service log makes the root cause
/// recoverable without weakening that fail-closed behaviour.
actor EngineLinuxSandboxLedgerPersistenceDiagnosticsV1:
    EngineWorkloadLedgerPersistenceV1
{
    private static let logger = Logger(
        label: "com.apple.container.engine-linux-sandbox.ledger"
    )

    private let persistence: any EngineWorkloadLedgerPersistenceV1
    private let ledgerURL: URL

    init(
        persistence: any EngineWorkloadLedgerPersistenceV1,
        ledgerURL: URL
    ) {
        self.persistence = persistence
        self.ledgerURL = ledgerURL
    }

    func load() async throws -> Data? {
        do {
            return try await persistence.load()
        } catch {
            logFailure(operation: "load", error: error)
            throw error
        }
    }

    func save(_ data: Data) async throws {
        do {
            try await persistence.save(data)
        } catch {
            logFailure(operation: "save", error: error)
            throw error
        }
    }

    private func logFailure(operation: String, error: Error) {
        Self.logger.error(
            "Engine Linux sandbox ledger persistence failed",
            metadata: [
                "operation": "\(operation)",
                "path": "\(ledgerURL.path)",
                "error": "\(error)",
            ]
        )
    }
}

/// API-service composition root for durable shared-sandbox and workload starts.
///
/// The authority owns helper launch/reuse, the durable workload ledger, exact
/// sandbox reconciliation, and the common workload transaction resolver. It
/// accepts specialized controllers but does not interpret their policy.
public actor EngineLinuxSandboxAuthorityV1:
    EngineLinuxSandboxWorkloadAuthorityV1
{
    public static let ledgerFilename = "engine-workload-ledger-v1.json"

    private struct WorkloadRequestDigestMaterial: Codable {
        let planDigest: String
        let workloadConfigurationDigest: String
        let dynamicEnvironment: [String: String]
        let networkEndpoints: [WorkloadNetworkEndpoint]
        let monitorTerminal: Bool
    }

    private struct ReadinessInFlight {
        let id: UUID
        let configurationDigest: String
        let task: Task<EngineLinuxSandboxRecordV1, any Error>
    }

    private let root: URL
    private let sandboxID: String
    private let ledger: EngineWorkloadLedgerV1
    private let resolver: WorkloadPlanResolverV1
    private let launcher: any EngineLinuxSandboxLaunchingV1
    private var runtime: (any EngineLinuxSandboxRuntimeClientV1)?
    private var readinessInFlight: ReadinessInFlight?
    private var manager: EngineLinuxSandboxManagerV1?
    private var activeConfigurationDigest: String?

    private init(
        root: URL,
        sandboxID: String,
        ledger: EngineWorkloadLedgerV1,
        launcher: any EngineLinuxSandboxLaunchingV1
    ) {
        self.root = root
        self.sandboxID = sandboxID
        self.ledger = ledger
        self.resolver = WorkloadPlanResolverV1(ledger: ledger)
        self.launcher = launcher
    }

    public static func open(
        root: URL,
        owningControllerID: String,
        sandboxID: String,
        launcher: any EngineLinuxSandboxLaunchingV1,
        persistence: (any EngineWorkloadLedgerPersistenceV1)? = nil
    ) async throws -> EngineLinuxSandboxAuthorityV1 {
        guard root.isFileURL else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Engine Linux sandbox authority root must be a file URL"
            )
        }
        let canonicalRoot = root.standardizedFileURL
        let resolvedPersistence: any EngineWorkloadLedgerPersistenceV1
        if let persistence {
            resolvedPersistence = persistence
        } else {
            let ledgerURL = canonicalRoot.appendingPathComponent(ledgerFilename)
            let filePersistence = try FileEngineWorkloadLedgerPersistenceV1(
                fileURL: ledgerURL
            )
            resolvedPersistence = EngineLinuxSandboxLedgerPersistenceDiagnosticsV1(
                persistence: filePersistence,
                ledgerURL: ledgerURL
            )
        }
        let ledger = try await EngineWorkloadLedgerV1.open(
            owningControllerID: owningControllerID,
            sandboxID: sandboxID,
            persistence: resolvedPersistence
        )
        return EngineLinuxSandboxAuthorityV1(
            root: canonicalRoot,
            sandboxID: sandboxID,
            ledger: ledger,
            launcher: launcher
        )
    }

    public func snapshot() async -> EngineWorkloadLedgerSnapshotV1 {
        await ledger.snapshot()
    }

    public func ensureReady(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> EngineLinuxSandboxRecordV1 {
        try configuration.validate(expectedPath: root)
        guard configuration.sandboxID == sandboxID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Engine Linux sandbox configuration has the wrong authority identifier"
            )
        }

        let requestedDigest = try Self.configurationDigest(configuration)
        if let activeConfigurationDigest, activeConfigurationDigest != requestedDigest {
            throw ContainerizationError(
                .invalidState,
                message: "active Engine Linux sandbox configuration cannot change"
            )
        }

        if let readinessInFlight {
            guard readinessInFlight.configurationDigest == requestedDigest else {
                throw ContainerizationError(
                    .invalidState,
                    message: "active Engine Linux sandbox configuration cannot change"
                )
            }
            return try await readinessInFlight.task.value
        }

        let readiness = ReadinessInFlight(
            id: UUID(),
            configurationDigest: requestedDigest,
            task: Task {
                try await self.ensureReadyUncoalesced(
                    configuration: configuration,
                    requestedDigest: requestedDigest
                )
            }
        )
        readinessInFlight = readiness
        do {
            let ready = try await readiness.task.value
            if readinessInFlight?.id == readiness.id {
                readinessInFlight = nil
            }
            return ready
        } catch {
            if readinessInFlight?.id == readiness.id {
                readinessInFlight = nil
            }
            throw error
        }
    }

    private func ensureReadyUncoalesced(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        requestedDigest: String
    ) async throws -> EngineLinuxSandboxRecordV1 {
        let snapshot = await ledger.snapshot()

        var replaceStoppedHelper = false
        if activeConfigurationDigest == nil,
            FileManager.default.fileExists(atPath: configuration.configurationURL.path)
        {
            let persisted = try EngineLinuxSandboxRuntimeConfigurationV1.read(from: root)
            let persistedDigest = try Self.digest(persisted)
            if persistedDigest != requestedDigest {
                if snapshot.sandbox.state == .ready {
                    let launched = try await launcher.launch(
                        configuration: persisted
                    )
                    let persistedManager = EngineLinuxSandboxManagerV1(
                        ledger: ledger,
                        runtime: launched
                    )
                    switch try await persistedManager.reconcileReadyRuntime() {
                    case .ready:
                        runtime = launched
                        manager = persistedManager
                        activeConfigurationDigest = persistedDigest
                        throw ContainerizationError(
                            .invalidState,
                            message: "active Engine Linux sandbox configuration cannot change"
                        )
                    case .absent:
                        try await launcher.stop(configuration: persisted)
                    }
                } else {
                    guard snapshot.sandbox.state == .absent else {
                        throw ContainerizationError(
                            .invalidState,
                            message: "persisted Engine Linux sandbox configuration does not match durable runtime state"
                        )
                    }
                    replaceStoppedHelper = true
                }
            }
        }

        if runtime == nil {
            if replaceStoppedHelper {
                try await launcher.stop(configuration: configuration)
            }
            let launched = try await launcher.launch(configuration: configuration)
            runtime = launched
            manager = EngineLinuxSandboxManagerV1(ledger: ledger, runtime: launched)
            activeConfigurationDigest = requestedDigest
        }
        guard let lifecycleManager = manager else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox manager was not initialized"
            )
        }

        return try await lifecycleManager.ensureReady(
            idempotencyKey: "boot-\(sandboxID)-\(Self.shortDigest(requestedDigest))",
            requestDigest: requestedDigest,
            effectID: "boot-effect-\(sandboxID)-\(Self.shortDigest(requestedDigest))"
        )
    }

    public func startWorkload(
        planDigest: String,
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String] = [:],
        networkEndpoints: [WorkloadNetworkEndpoint] = [],
        stdio: [FileHandle?] = [],
        controllers: [any WorkloadEffectControllerV1] = [],
        monitorTerminal: Bool = false
    ) async throws -> EngineWorkloadRecordV1 {
        let ready = try await ensureReady(configuration: configuration)
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
            from: workloadRoot
        )
        guard let containerID = runtimeConfiguration.containerConfiguration?.id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "workload bundle has no container configuration"
            )
        }
        let configurationDigest =
            try EngineLinuxSandboxWorkloadIntegrityV1
            .configurationDigest(runtimeConfiguration)
        let requestDigest = try Self.digest(
            WorkloadRequestDigestMaterial(
                planDigest: planDigest,
                workloadConfigurationDigest: configurationDigest,
                dynamicEnvironment: dynamicEnvironment,
                networkEndpoints: networkEndpoints,
                monitorTerminal: monitorTerminal
            )
        )
        var registered = try await ledger.registerWorkload(
            containerID: containerID,
            planDigest: planDigest
        )
        let process = EngineLinuxSandboxWorkloadProcessStarterV1(
            runtime: runtime,
            workloadRoot: workloadRoot,
            workloadConfigurationDigest: configurationDigest,
            dynamicEnvironment: dynamicEnvironment,
            networkEndpoints: networkEndpoints,
            stdio: stdio,
            monitorTerminal: monitorTerminal
        )
        if registered.state == .running {
            guard registered.lastOperation?.kind == .start,
                registered.lastOperation?.outcome == .running,
                registered.lastOperation?.requestDigest == requestDigest
            else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            guard monitorTerminal else {
                return registered
            }
            let context = try startContext(for: registered)
            switch try await process.observe(context: context) {
            case .started(let receipt):
                guard Self.matches(receipt, context: context) else {
                    throw WorkloadPlanResolverError.recoveryRequired
                }
                return registered
            case .absent:
                registered = try await reclaimTerminalWorkload(registered)
            case .unknown:
                throw WorkloadPlanResolverError.recoveryRequired
            }
        }
        let mutation = try startMutation(for: registered, requestDigest: requestDigest)
        return try await resolver.start(
            mutation,
            sandboxGeneration: ready.generation,
            controllers: controllers,
            process: process
        )
    }

    /// Opens a service connection only after reconciling the exact durable
    /// sandbox generation. The runtime independently checks the same fence.
    public func dialService(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        port: UInt32
    ) async throws -> FileHandle {
        guard port > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Engine Linux sandbox service port must be positive"
            )
        }
        let ready = try await ensureReady(configuration: configuration)
        guard
            let workload = await ledger.workload(containerID: workloadID),
            workload.state == .running,
            workload.activeProcessGeneration == workloadProcessGeneration,
            workload.activeSandboxGeneration == ready.generation
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox service workload is not active for the requested generation"
            )
        }
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        return try await runtime.dialService(
            EngineLinuxSandboxServiceDialRequestV1(
                sandboxID: sandboxID,
                sandboxGeneration: ready.generation,
                workloadID: workloadID,
                workloadProcessGeneration: workloadProcessGeneration,
                port: port
            )
        )
    }

    /// Applies one generation-fenced lifecycle or observation operation to an
    /// active workload without granting access to the shared sandbox itself.
    public func controlWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        action: EngineLinuxSandboxWorkloadControlRequestV1.Action
    ) async throws -> EngineLinuxSandboxWorkloadControlResponseV1 {
        switch action {
        case .pause, .resume:
            throw ContainerizationError(
                .invalidArgument,
                message: "shared workload pause and resume require a durable lifecycle transaction"
            )
        default:
            break
        }
        let ready = try await ensureReady(configuration: configuration)
        guard
            let workload = await ledger.workload(containerID: workloadID),
            workload.state == .running || workload.state == .paused,
            workload.activeProcessGeneration == workloadProcessGeneration,
            workload.activeSandboxGeneration == ready.generation
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox workload is not active for the requested generation"
            )
        }
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        return try await runtime.controlWorkload(
            EngineLinuxSandboxWorkloadControlRequestV1(
                sandboxID: sandboxID,
                sandboxGeneration: ready.generation,
                workloadID: workloadID,
                workloadProcessGeneration: workloadProcessGeneration,
                action: action
            )
        )
    }

    public func pauseWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        let ready = try await ensureReady(configuration: configuration)
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        guard let current = await ledger.workload(containerID: workloadID),
            current.activeProcessGeneration == workloadProcessGeneration,
            current.activeSandboxGeneration == ready.generation
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox workload is not active for the requested generation"
            )
        }
        let requestDigest = Self.digest(
            "pause:\(workloadID):\(workloadProcessGeneration):\(ready.generation)"
        )
        let mutation = EngineWorkloadMutationRequestV1(
            containerID: workloadID,
            idempotencyKey: "pause-\(workloadID)-\(workloadProcessGeneration)",
            requestDigest: requestDigest,
            expectedTransitionRevision: current.transitionRevision
        )
        let pausing: EngineWorkloadRecordV1
        switch try await ledger.beginPause(mutation) {
        case .reserved(let record), .replay(let record):
            pausing = record
        }
        if pausing.state == .paused {
            return pausing
        }
        guard pausing.state == .pausing,
            let operationGeneration = pausing.operation?.operationGeneration
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        let request = EngineLinuxSandboxWorkloadControlRequestV1(
            sandboxID: sandboxID,
            sandboxGeneration: ready.generation,
            workloadID: workloadID,
            workloadProcessGeneration: workloadProcessGeneration,
            action: .pause
        )
        do {
            guard case .none = try await runtime.controlWorkload(request) else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
        } catch {
            if case .state(.paused)? = try? await runtime.controlWorkload(
                EngineLinuxSandboxWorkloadControlRequestV1(
                    sandboxID: sandboxID,
                    sandboxGeneration: ready.generation,
                    workloadID: workloadID,
                    workloadProcessGeneration: workloadProcessGeneration,
                    action: .state
                )
            ) {
                return try await ledger.commitPause(
                    containerID: workloadID,
                    operationGeneration: operationGeneration
                )
            }
            _ = try? await ledger.markOperationRecoveryRequired(
                containerID: workloadID,
                operationGeneration: operationGeneration,
                reason: "shared workload pause outcome is unknown"
            )
            throw error
        }
        return try await ledger.commitPause(
            containerID: workloadID,
            operationGeneration: operationGeneration
        )
    }

    public func resumeWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        let ready = try await ensureReady(configuration: configuration)
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        guard let current = await ledger.workload(containerID: workloadID),
            current.activeProcessGeneration == workloadProcessGeneration,
            current.activeSandboxGeneration == ready.generation
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox workload is not active for the requested generation"
            )
        }
        let requestDigest = Self.digest(
            "resume:\(workloadID):\(workloadProcessGeneration):\(ready.generation)"
        )
        let mutation = EngineWorkloadMutationRequestV1(
            containerID: workloadID,
            idempotencyKey: "resume-\(workloadID)-\(workloadProcessGeneration)",
            requestDigest: requestDigest,
            expectedTransitionRevision: current.transitionRevision
        )
        let resuming: EngineWorkloadRecordV1
        switch try await ledger.beginResume(mutation) {
        case .reserved(let record), .replay(let record):
            resuming = record
        }
        if resuming.state == .running {
            return resuming
        }
        guard resuming.state == .resuming,
            let operationGeneration = resuming.operation?.operationGeneration
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        let request = EngineLinuxSandboxWorkloadControlRequestV1(
            sandboxID: sandboxID,
            sandboxGeneration: ready.generation,
            workloadID: workloadID,
            workloadProcessGeneration: workloadProcessGeneration,
            action: .resume
        )
        do {
            guard case .none = try await runtime.controlWorkload(request) else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
        } catch {
            if case .state(.running)? = try? await runtime.controlWorkload(
                EngineLinuxSandboxWorkloadControlRequestV1(
                    sandboxID: sandboxID,
                    sandboxGeneration: ready.generation,
                    workloadID: workloadID,
                    workloadProcessGeneration: workloadProcessGeneration,
                    action: .state
                )
            ) {
                return try await ledger.commitResume(
                    containerID: workloadID,
                    operationGeneration: operationGeneration
                )
            }
            _ = try? await ledger.markOperationRecoveryRequired(
                containerID: workloadID,
                operationGeneration: operationGeneration,
                reason: "shared workload resume outcome is unknown"
            )
            throw error
        }
        return try await ledger.commitResume(
            containerID: workloadID,
            operationGeneration: operationGeneration
        )
    }

    /// Stops only the exact active workload generation after all controller
    /// effects have been released. A durable stop reservation precedes the
    /// runtime call, and a lost response is reconciled before the ledger can
    /// forget the active process tuple.
    public func stopWorkload(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String,
        workloadProcessGeneration: UInt64
    ) async throws -> EngineWorkloadRecordV1 {
        let ready = try await ensureReady(configuration: configuration)
        guard let runtime else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox runtime was not initialized"
            )
        }
        guard var workload = await ledger.workload(containerID: workloadID)
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox workload is not registered"
            )
        }
        if workload.state == .stopped,
            workload.lastOperation?.kind == .stop,
            workload.lastOperation?.outcome == .stopped,
            workload.lastOperation?.processGeneration
                == workloadProcessGeneration
        {
            return workload
        }
        guard
            workload.activeEffects.isEmpty,
            workload.activeProcessGeneration == workloadProcessGeneration,
            workload.activeSandboxGeneration == ready.generation,
            workload.state == .running || workload.state == .paused
                || workload.state == .stopping
                || workload.state == .recoveryRequired
        else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "Engine Linux sandbox workload is not reclaimable for the requested generation"
            )
        }
        let requestDigest = Self.digest(
            "reclaim:\(workloadID):\(workloadProcessGeneration):\(ready.generation)"
        )
        let mutation: EngineWorkloadMutationRequestV1
        if let operation = workload.operation, operation.kind == .stop {
            guard
                operation.requestDigest == requestDigest,
                operation.candidateProcessGeneration
                    == workloadProcessGeneration,
                operation.sandboxGeneration == ready.generation
            else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            mutation = EngineWorkloadMutationRequestV1(
                containerID: workloadID,
                idempotencyKey: operation.idempotencyKey,
                requestDigest: operation.requestDigest
            )
        } else {
            mutation = EngineWorkloadMutationRequestV1(
                containerID: workloadID,
                idempotencyKey:
                    "reclaim-\(workloadID)-\(workloadProcessGeneration)",
                requestDigest: requestDigest,
                expectedTransitionRevision: workload.transitionRevision
            )
        }
        if workload.state == .recoveryRequired {
            workload = try await ledger.resumeEffectlessStop(mutation)
        } else {
            switch try await ledger.beginStop(mutation) {
            case .reserved(let value), .replay(let value):
                workload = value
            }
        }
        guard
            workload.state == .stopping,
            let operation = workload.operation,
            operation.kind == .stop,
            operation.effects.isEmpty,
            operation.candidateProcessGeneration
                == workloadProcessGeneration,
            operation.sandboxGeneration == ready.generation
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        let request = EngineLinuxSandboxWorkloadStopRequestV1(
            sandboxID: sandboxID,
            sandboxGeneration: ready.generation,
            workloadID: workloadID,
            workloadProcessGeneration: workloadProcessGeneration,
            operationGeneration: operation.operationGeneration,
            idempotencyKey: operation.idempotencyKey,
            requestDigest: operation.requestDigest
        )
        do {
            let receipt = try await runtime.stopWorkload(request)
            guard receipt.request == request else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
        } catch {
            switch try await runtime.observeWorkloadStop(request) {
            case .stopped(let receipt):
                guard receipt.request == request else {
                    throw WorkloadPlanResolverError.recoveryRequired
                }
            case .absent:
                break
            case .running:
                throw error
            case .unknown:
                throw WorkloadPlanResolverError.recoveryRequired
            }
        }
        return try await ledger.commitStop(
            containerID: workloadID,
            operationGeneration: operation.operationGeneration
        )
    }

    /// Reconciles an ordinary shared workload that survived the API authority.
    /// Protected service workloads retain controller effects and are therefore
    /// deliberately outside this boot-cleanup boundary.
    public func reclaimEffectlessWorkloadAtBoot(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        workloadID: String
    ) async throws -> EngineWorkloadRecordV1? {
        guard var workload = await ledger.workload(containerID: workloadID) else {
            return nil
        }
        guard workload.activeEffects.isEmpty,
            workload.operation?.effects.isEmpty ?? true
        else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox boot cleanup cannot reclaim a controller-owned workload"
            )
        }
        switch workload.state {
        case .created, .stopped, .removed:
            return workload
        case .pausing:
            guard let processGeneration = workload.activeProcessGeneration else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
            workload = try await pauseWorkload(
                configuration: configuration,
                workloadID: workloadID,
                workloadProcessGeneration: processGeneration
            )
        case .resuming:
            guard let processGeneration = workload.activeProcessGeneration else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
            workload = try await resumeWorkload(
                configuration: configuration,
                workloadID: workloadID,
                workloadProcessGeneration: processGeneration
            )
        case .running, .paused, .stopping:
            break
        case .recoveryRequired:
            guard workload.operation?.kind == .stop else {
                throw WorkloadPlanResolverError.recoveryRequired
            }
        case .starting, .removing:
            throw WorkloadPlanResolverError.recoveryRequired
        }
        guard let processGeneration = workload.activeProcessGeneration else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        return try await stopWorkload(
            configuration: configuration,
            workloadID: workloadID,
            workloadProcessGeneration: processGeneration
        )
    }

    public func shutdownIfIdle(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) async throws -> EngineLinuxSandboxRecordV1 {
        let snapshot = await ledger.snapshot()
        if snapshot.sandbox.state == .absent {
            return snapshot.sandbox
        }
        if runtime == nil {
            try configuration.validate(expectedPath: root)
            let launched = try await launcher.launch(configuration: configuration)
            runtime = launched
            manager = EngineLinuxSandboxManagerV1(ledger: ledger, runtime: launched)
            activeConfigurationDigest = try Self.digest(configuration)
        }
        guard let lifecycleManager = manager else {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox manager was not initialized"
            )
        }
        let generation = snapshot.sandbox.generation
        let requestDigest = Self.digest("stop:\(sandboxID):\(generation)")
        let absent = try await lifecycleManager.shutdownIfIdle(
            idempotencyKey: "stop-\(sandboxID)-\(generation)",
            requestDigest: requestDigest,
            effectID: "stop-effect-\(sandboxID)-\(generation)"
        )
        try await launcher.stop(configuration: configuration)
        runtime = nil
        manager = nil
        activeConfigurationDigest = nil
        return absent
    }

    private func startMutation(
        for workload: EngineWorkloadRecordV1,
        requestDigest: String
    ) throws -> EngineWorkloadMutationRequestV1 {
        if let operation = workload.operation, operation.kind == .start {
            guard operation.requestDigest == requestDigest else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return .init(
                containerID: workload.containerID,
                idempotencyKey: operation.idempotencyKey,
                requestDigest: operation.requestDigest
            )
        }
        return .init(
            containerID: workload.containerID,
            idempotencyKey: "start-\(workload.containerID)-\(workload.transitionRevision + 1)-\(Self.shortDigest(requestDigest))",
            requestDigest: requestDigest,
            expectedTransitionRevision: workload.transitionRevision
        )
    }

    private func startContext(
        for workload: EngineWorkloadRecordV1
    ) throws -> WorkloadStartContextV1 {
        guard
            let operation = workload.lastOperation,
            operation.kind == .start,
            operation.outcome == .running,
            let processGeneration = workload.activeProcessGeneration,
            let sandboxGeneration = workload.activeSandboxGeneration
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        return WorkloadStartContextV1(
            containerID: workload.containerID,
            operationGeneration: operation.operationGeneration,
            candidateProcessGeneration: processGeneration,
            sandboxGeneration: sandboxGeneration,
            requestDigest: operation.requestDigest
        )
    }

    private func reclaimTerminalWorkload(
        _ workload: EngineWorkloadRecordV1
    ) async throws -> EngineWorkloadRecordV1 {
        guard workload.activeEffects.isEmpty,
            let processGeneration = workload.activeProcessGeneration,
            let sandboxGeneration = workload.activeSandboxGeneration
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        let requestDigest = Self.digest(
            "terminal:\(workload.containerID):\(processGeneration):\(sandboxGeneration)"
        )
        let reservation = try await ledger.beginStop(
            EngineWorkloadMutationRequestV1(
                containerID: workload.containerID,
                idempotencyKey: "terminal-\(workload.containerID)-\(processGeneration)",
                requestDigest: requestDigest,
                expectedTransitionRevision: workload.transitionRevision
            )
        )
        let stopping: EngineWorkloadRecordV1
        switch reservation {
        case .reserved(let record), .replay(let record):
            stopping = record
        }
        guard
            stopping.state == .stopping,
            let operationGeneration = stopping.operation?.operationGeneration
        else {
            throw WorkloadPlanResolverError.recoveryRequired
        }
        return try await ledger.commitStop(
            containerID: workload.containerID,
            operationGeneration: operationGeneration
        )
    }

    private static func matches(
        _ receipt: WorkloadProcessReceiptV1,
        context: WorkloadStartContextV1
    ) -> Bool {
        receipt.containerID == context.containerID
            && receipt.operationGeneration == context.operationGeneration
            && receipt.processGeneration == context.candidateProcessGeneration
            && receipt.sandboxGeneration == context.sandboxGeneration
            && receipt.requestDigest == context.requestDigest
    }

    /// Keeps pre-snapshot-root and explicit snapshot-root configurations equivalent.
    static func configurationDigest(
        _ configuration: EngineLinuxSandboxRuntimeConfigurationV1
    ) throws -> String {
        // `snapshotRoot` was added after the durable sandbox ledger shipped.
        // Omitting it here preserves the exact legacy encoding while validation
        // guarantees every explicit value resolves to the derived legacy root.
        let normalized = EngineLinuxSandboxRuntimeConfigurationV1(
            path: configuration.path,
            snapshotRoot: nil,
            sandboxID: configuration.sandboxID,
            initialFilesystem: configuration.initialFilesystem,
            kernel: configuration.kernel,
            cpus: configuration.cpus,
            memoryInBytes: configuration.memoryInBytes,
            nestedVirtualization: configuration.nestedVirtualization,
            rosetta: configuration.rosetta
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(normalized))
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(value))
    }

    private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ data: Data) -> String {
        let value = SHA256.hash(data: data)
        return "sha256:" + value.map { String(format: "%02x", $0) }.joined()
    }

    private static func shortDigest(_ digest: String) -> String {
        String(digest.split(separator: ":").last?.prefix(20) ?? "invalid")
    }
}
