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

/// API-service composition root for durable shared-sandbox and workload starts.
///
/// The authority owns helper launch/reuse, the durable workload ledger, exact
/// sandbox reconciliation, and the common workload transaction resolver. It
/// accepts specialized controllers but does not interpret their policy.
public actor EngineLinuxSandboxAuthorityV1 {
    public static let ledgerFilename = "engine-workload-ledger-v1.json"

    private struct WorkloadRequestDigestMaterial: Codable {
        let planDigest: String
        let workloadConfigurationDigest: String
        let dynamicEnvironment: [String: String]
        let networkEndpoints: [WorkloadNetworkEndpoint]
    }

    private let root: URL
    private let sandboxID: String
    private let ledger: EngineWorkloadLedgerV1
    private let resolver: WorkloadPlanResolverV1
    private let launcher: any EngineLinuxSandboxLaunchingV1
    private var runtime: (any EngineLinuxSandboxRuntimeClientV1)?
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
            resolvedPersistence = try FileEngineWorkloadLedgerPersistenceV1(
                fileURL: canonicalRoot.appendingPathComponent(ledgerFilename)
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

        let requestedDigest = try Self.digest(configuration)
        let snapshot = await ledger.snapshot()
        if let activeConfigurationDigest, activeConfigurationDigest != requestedDigest {
            throw ContainerizationError(
                .invalidState,
                message: "active Engine Linux sandbox configuration cannot change"
            )
        }

        var replaceStoppedHelper = false
        if activeConfigurationDigest == nil,
            FileManager.default.fileExists(atPath: configuration.configurationURL.path)
        {
            let persisted = try EngineLinuxSandboxRuntimeConfigurationV1.read(from: root)
            let persistedDigest = try Self.digest(persisted)
            if persistedDigest != requestedDigest {
                guard snapshot.sandbox.state == .absent else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "persisted Engine Linux sandbox configuration does not match durable runtime state"
                    )
                }
                replaceStoppedHelper = true
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
        controllers: [any WorkloadEffectControllerV1] = []
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
                networkEndpoints: networkEndpoints
            )
        )
        let registered = try await ledger.registerWorkload(
            containerID: containerID,
            planDigest: planDigest
        )
        if registered.state == .running {
            guard registered.lastOperation?.kind == .start,
                registered.lastOperation?.outcome == .running,
                registered.lastOperation?.requestDigest == requestDigest
            else {
                throw EngineWorkloadLedgerError.idempotencyConflict
            }
            return registered
        }
        let mutation = try startMutation(for: registered, requestDigest: requestDigest)
        let process = EngineLinuxSandboxWorkloadProcessStarterV1(
            runtime: runtime,
            workloadRoot: workloadRoot,
            workloadConfigurationDigest: configurationDigest,
            dynamicEnvironment: dynamicEnvironment,
            networkEndpoints: networkEndpoints,
            stdio: stdio
        )
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
        port: UInt32
    ) async throws -> FileHandle {
        guard port > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Engine Linux sandbox service port must be positive"
            )
        }
        let ready = try await ensureReady(configuration: configuration)
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
                port: port
            )
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
