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
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging

/// Narrow lifecycle surface needed by the Engine-owned runtime service.
public protocol EngineLinuxSandboxInstanceV1: Sendable {
    var id: String { get }
    func snapshot() async -> LinuxSandboxSnapshot
    func create() async throws
    func stop() async throws
    func addContainer(
        _ id: String,
        rootfs: Containerization.Mount,
        configuration: @Sendable @escaping (inout LinuxPod.ContainerConfiguration) throws -> Void
    ) async throws
    func startContainer(_ containerID: String) async throws
    func removeContainer(_ containerID: String) async throws
    func dialVsock(port: UInt32) async throws -> FileHandle
}

extension LinuxPod: EngineLinuxSandboxInstanceV1 {}

/// Production XPC authority for the single Engine-owned Linux sandbox.
///
/// Exact request receipts stay resident for the lifetime of the helper. The
/// Containerization snapshot is consulted before every observation so a
/// receipt cannot report a running VM after a later shutdown.
public actor EngineLinuxSandboxRuntimeServiceV1: EngineLinuxSandboxRuntimeV1,
    EngineLinuxSandboxWorkloadRuntimeV1,
    EngineLinuxSandboxServiceRuntimeV1
{
    private struct BootInFlight: Sendable {
        let request: EngineLinuxSandboxBootRequestV1
        let task: Task<EngineLinuxSandboxBootReceiptV1, any Error>
    }

    private struct ShutdownInFlight: Sendable {
        let request: EngineLinuxSandboxShutdownRequestV1
        let task: Task<EngineLinuxSandboxShutdownReceiptV1, any Error>
    }

    private struct WorkloadStartInFlight: Sendable {
        let request: EngineLinuxSandboxWorkloadStartRequestV1
        let task: Task<WorkloadProcessReceiptV1, any Error>
    }

    private let connection: xpc_connection_t?
    private let sandbox: any EngineLinuxSandboxInstanceV1
    private let runtimeFingerprint: String
    private let log: Logger
    private var bootReceipt: EngineLinuxSandboxBootReceiptV1?
    private var shutdownReceipt: EngineLinuxSandboxShutdownReceiptV1?
    private var bootInFlight: BootInFlight?
    private var shutdownInFlight: ShutdownInFlight?
    private var workloadStartInFlight: [String: WorkloadStartInFlight] = [:]
    private var workloadRequests: [String: EngineLinuxSandboxWorkloadStartRequestV1] = [:]
    private var workloadReceipts: [String: WorkloadProcessReceiptV1] = [:]
    private var workloadCaptures: [String: ContainerLogRuntimeCapture] = [:]
    private var serviceDialsInFlight = 0

    public init(
        sandbox: any EngineLinuxSandboxInstanceV1,
        runtimeFingerprint: String,
        connection: xpc_connection_t? = nil,
        log: Logger
    ) throws {
        guard !runtimeFingerprint.isEmpty,
            runtimeFingerprint.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumDigestBytes
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox runtime fingerprint"
            )
        }
        self.sandbox = sandbox
        self.runtimeFingerprint = runtimeFingerprint
        self.connection = connection
        self.log = log
    }

    public init(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        runtimeFingerprint: String,
        connection: xpc_connection_t,
        log: Logger
    ) throws {
        try configuration.validate()
        let vmm = VZVirtualMachineManager(
            kernel: configuration.kernel,
            initialFilesystem: configuration.initialFilesystem.asMount,
            rosetta: configuration.rosetta,
            logger: log
        )
        let sandbox = try LinuxSandbox(
            configuration.sandboxID,
            vmm: vmm,
            logger: log
        ) { sandboxConfiguration in
            sandboxConfiguration.cpus = configuration.cpus
            sandboxConfiguration.memoryInBytes = configuration.memoryInBytes
            sandboxConfiguration.virtualization = configuration.nestedVirtualization
        }
        try self.init(
            sandbox: sandbox,
            runtimeFingerprint: runtimeFingerprint,
            connection: connection,
            log: log
        )
    }

    public func boot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootReceiptV1 {
        try validate(request)
        guard shutdownInFlight == nil, workloadStartInFlight.isEmpty else {
            throw conflictingOperation("sandbox boot")
        }
        if let inFlight = bootInFlight {
            guard inFlight.request == request else {
                throw conflictingOperation("sandbox boot")
            }
            return try await inFlight.task.value
        }

        let snapshot = await sandbox.snapshot()
        switch snapshot.state {
        case .running:
            guard let receipt = bootReceipt, receipt.matches(request) else {
                throw unattributedState("running sandbox has no matching boot receipt")
            }
            return receipt
        case .recoveryRequired:
            throw unattributedState("sandbox requires recovery before boot")
        case .absent:
            break
        }

        let receipt = EngineLinuxSandboxBootReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest,
            runtimeFingerprint: runtimeFingerprint
        )
        let sandbox = self.sandbox
        let task = Task<EngineLinuxSandboxBootReceiptV1, any Error> {
            try await sandbox.create()
            let observation = await sandbox.snapshot()
            guard observation.state == .running else {
                throw ContainerizationError(
                    .internalError,
                    message: "sandbox boot returned without a running observation"
                )
            }
            return receipt
        }
        bootInFlight = BootInFlight(request: request, task: task)
        do {
            let applied = try await task.value
            bootReceipt = applied
            shutdownReceipt = nil
            bootInFlight = nil
            return applied
        } catch {
            bootInFlight = nil
            log.error("Engine Linux sandbox boot failed", metadata: ["error": "\(error)"])
            throw error
        }
    }

    public func observeBoot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootObservationV1 {
        try validate(request)
        let snapshot = await sandbox.snapshot()
        switch snapshot.state {
        case .absent:
            return .absent
        case .running:
            guard let receipt = bootReceipt, receipt.matches(request) else {
                return .unknown
            }
            return .ready(receipt)
        case .recoveryRequired:
            return .unknown
        }
    }

    public func shutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownReceiptV1 {
        try validate(request)
        guard
            bootInFlight == nil,
            workloadStartInFlight.isEmpty,
            serviceDialsInFlight == 0
        else {
            throw conflictingOperation("sandbox shutdown")
        }
        if let inFlight = shutdownInFlight {
            guard inFlight.request == request else {
                throw conflictingOperation("sandbox shutdown")
            }
            return try await inFlight.task.value
        }

        let snapshot = await sandbox.snapshot()
        let receipt = EngineLinuxSandboxShutdownReceiptV1(
            sandboxID: request.sandboxID,
            generation: request.generation,
            effectID: request.effectID,
            requestDigest: request.requestDigest
        )
        switch snapshot.state {
        case .absent:
            shutdownReceipt = receipt
            bootReceipt = nil
            closeWorkloadCaptures()
            workloadRequests.removeAll()
            workloadReceipts.removeAll()
            return receipt
        case .recoveryRequired:
            throw unattributedState("sandbox requires recovery before shutdown")
        case .running:
            break
        }

        let sandbox = self.sandbox
        let task = Task<EngineLinuxSandboxShutdownReceiptV1, any Error> {
            try await sandbox.stop()
            let observation = await sandbox.snapshot()
            guard observation.state == .absent else {
                throw ContainerizationError(
                    .internalError,
                    message: "sandbox shutdown returned without an absent observation"
                )
            }
            return receipt
        }
        shutdownInFlight = ShutdownInFlight(request: request, task: task)
        do {
            let applied = try await task.value
            shutdownReceipt = applied
            bootReceipt = nil
            closeWorkloadCaptures()
            workloadRequests.removeAll()
            workloadReceipts.removeAll()
            shutdownInFlight = nil
            return applied
        } catch {
            shutdownInFlight = nil
            log.error("Engine Linux sandbox shutdown failed", metadata: ["error": "\(error)"])
            throw error
        }
    }

    public func observeShutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownObservationV1 {
        try validate(request)
        let snapshot = await sandbox.snapshot()
        switch snapshot.state {
        case .absent:
            let receipt =
                shutdownReceipt.flatMap { $0.matches(request) ? $0 : nil }
                ?? EngineLinuxSandboxShutdownReceiptV1(
                    sandboxID: request.sandboxID,
                    generation: request.generation,
                    effectID: request.effectID,
                    requestDigest: request.requestDigest
                )
            return .absent(receipt)
        case .running:
            return .running
        case .recoveryRequired:
            return .unknown
        }
    }

    public func startWorkload(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1,
        stdio: [FileHandle?]
    ) async throws -> WorkloadProcessReceiptV1 {
        try validate(request)
        let id = request.context.containerID
        guard bootInFlight == nil, shutdownInFlight == nil else {
            throw conflictingOperation("workload start for \(id)")
        }
        if let inFlight = workloadStartInFlight[id] {
            guard inFlight.request == request else {
                throw conflictingOperation("workload start for \(id)")
            }
            return try await inFlight.task.value
        }

        let snapshot = await sandbox.snapshot()
        guard snapshot.state == .running else {
            throw unattributedState("shared sandbox is not running for workload start")
        }
        guard
            let bootReceipt,
            bootReceipt.generation == request.context.sandboxGeneration
        else {
            throw unattributedState("workload start does not match the active sandbox generation")
        }

        let observed = snapshot.workloads.first { $0.id == id }
        switch observed?.state {
        case .running?, .paused?:
            guard
                workloadRequests[id] == request,
                let receipt = workloadReceipts[id],
                receipt.matches(request.context)
            else {
                throw unattributedState("running workload \(id) has no matching start receipt")
            }
            return receipt
        case .recoveryRequired?:
            throw unattributedState("workload \(id) requires recovery before start")
        case .registered?, .created?:
            guard
                workloadRequests[id] == request,
                workloadCaptures[id] != nil
            else {
                throw unattributedState("prepared workload \(id) has no matching materialization intent")
            }
        case .stopped?, nil:
            break
        }

        let isNewMaterialization = observed == nil || observed?.state == .stopped
        let capture: ContainerLogRuntimeCapture?
        let runtimeConfiguration: RuntimeConfiguration?
        let containerConfiguration: ContainerConfiguration?
        if isNewMaterialization {
            if observed?.state == .stopped {
                workloadCaptures.removeValue(forKey: id)?.close()
                workloadRequests[id] = nil
                workloadReceipts[id] = nil
            }
            let loadedBundle = ContainerResource.Bundle(path: request.workloadRoot)
            let loadedRuntimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(
                from: request.workloadRoot
            )
            let observedConfigurationDigest =
                try EngineLinuxSandboxWorkloadIntegrityV1
                .configurationDigest(loadedRuntimeConfiguration)
            guard
                observedConfigurationDigest == request.workloadConfigurationDigest,
                loadedRuntimeConfiguration.path.resolvingSymlinksInPath().standardizedFileURL.path
                    == request.workloadRoot.resolvingSymlinksInPath().standardizedFileURL.path,
                let loadedContainerConfiguration = loadedRuntimeConfiguration.containerConfiguration,
                loadedContainerConfiguration.id == id,
                loadedRuntimeConfiguration.containerRootFilesystem != nil
            else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "sealed workload bundle does not match start identity"
                )
            }
            let loggingPlan = try ContainerLogRuntimePlan(configuration: loadedContainerConfiguration)
            capture = try loggingPlan.activate(
                bundle: loadedBundle,
                terminal: loadedContainerConfiguration.initProcess.terminal
            )
            runtimeConfiguration = loadedRuntimeConfiguration
            containerConfiguration = loadedContainerConfiguration
        } else {
            capture = nil
            runtimeConfiguration = nil
            containerConfiguration = nil
        }

        let receipt = WorkloadProcessReceiptV1(
            containerID: id,
            operationGeneration: request.context.operationGeneration,
            processGeneration: request.context.candidateProcessGeneration,
            sandboxGeneration: request.context.sandboxGeneration,
            requestDigest: request.context.requestDigest
        )
        let sandbox = self.sandbox
        let log = self.log
        let task = Task<WorkloadProcessReceiptV1, any Error> {
            if observed?.state == .stopped {
                try await sandbox.removeContainer(id)
            }
            if let runtimeConfiguration,
                let containerConfiguration,
                let rootfs = runtimeConfiguration.containerRootFilesystem,
                let capture
            {
                try await sandbox.addContainer(
                    id,
                    rootfs: rootfs.asMount
                ) { workload in
                    try EngineLinuxSandboxWorkloadMapper.configure(
                        &workload,
                        from: containerConfiguration,
                        runtimeData: runtimeConfiguration.runtimeData,
                        dynamicEnvironment: request.dynamicEnvironment,
                        networkEndpoints: request.networkEndpoints,
                        stdio: stdio,
                        loggingCapture: capture,
                        log: log
                    )
                }
            }
            try await sandbox.startContainer(id)
            let observation = await sandbox.snapshot()
            guard
                let workload = observation.workloads.first(where: { $0.id == id }),
                workload.state == .running,
                workload.initProcessID != nil
            else {
                throw ContainerizationError(
                    .internalError,
                    message: "workload start returned without a running process observation"
                )
            }
            return receipt
        }
        workloadStartInFlight[id] = WorkloadStartInFlight(request: request, task: task)
        do {
            let applied = try await task.value
            workloadRequests[id] = request
            workloadReceipts[id] = applied
            if let capture {
                workloadCaptures[id]?.close()
                workloadCaptures[id] = capture
            }
            workloadStartInFlight[id] = nil
            return applied
        } catch {
            let failureSnapshot = await sandbox.snapshot()
            if let capture {
                if let workload = failureSnapshot.workloads.first(where: { $0.id == id }),
                    workload.state == .registered || workload.state == .created
                {
                    workloadRequests[id] = request
                    workloadCaptures[id]?.close()
                    workloadCaptures[id] = capture
                } else {
                    capture.close()
                }
            }
            workloadStartInFlight[id] = nil
            log.error(
                "Engine Linux sandbox workload start failed",
                metadata: ["containerID": "\(id)", "error": "\(error)"]
            )
            throw error
        }
    }

    public func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1 {
        try validate(request)
        let id = request.context.containerID
        let snapshot = await sandbox.snapshot()
        guard snapshot.state == .running else {
            return snapshot.state == .absent ? .absent : .unknown
        }
        guard
            let bootReceipt,
            bootReceipt.generation == request.context.sandboxGeneration
        else {
            return .unknown
        }
        guard let workload = snapshot.workloads.first(where: { $0.id == id }) else {
            return .absent
        }
        switch workload.state {
        case .registered, .created, .stopped:
            return .absent
        case .running, .paused:
            guard
                workloadRequests[id] == request,
                let receipt = workloadReceipts[id],
                receipt.matches(request.context)
            else {
                return .unknown
            }
            return .started(receipt)
        case .recoveryRequired:
            return .unknown
        }
    }

    public func dialService(
        _ request: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> FileHandle {
        try validate(request)
        guard bootInFlight == nil, shutdownInFlight == nil else {
            throw conflictingOperation("protected service dial")
        }
        let snapshot = await sandbox.snapshot()
        guard snapshot.state == .running else {
            throw unattributedState("shared sandbox is not running for protected service dial")
        }
        guard
            let bootReceipt,
            bootReceipt.sandboxID == request.sandboxID,
            bootReceipt.generation == request.sandboxGeneration
        else {
            throw unattributedState("protected service dial does not match the active sandbox generation")
        }
        serviceDialsInFlight += 1
        defer { serviceDialsInFlight -= 1 }
        return try await sandbox.dialVsock(port: request.port)
    }

    /// Return an endpoint from the helper's anonymous XPC connection.
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        guard let connection else {
            throw ContainerizationError(
                .invalidState,
                message: "Engine Linux sandbox XPC connection is not configured"
            )
        }
        let endpoint = xpc_endpoint_create(connection)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    @Sendable
    public func bootMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxBootRequestV1.self)
        let reply = message.reply()
        try reply.setEngineSandboxPayload(try await boot(request))
        return reply
    }

    @Sendable
    public func observeBootMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxBootRequestV1.self)
        let reply = message.reply()
        try reply.setEngineSandboxPayload(try await observeBoot(request))
        return reply
    }

    @Sendable
    public func shutdownMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxShutdownRequestV1.self)
        let reply = message.reply()
        try reply.setEngineSandboxPayload(try await shutdown(request))
        return reply
    }

    @Sendable
    public func observeShutdownMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxShutdownRequestV1.self)
        let reply = message.reply()
        try reply.setEngineSandboxPayload(try await observeShutdown(request))
        return reply
    }

    @Sendable
    public func startWorkloadMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStartRequestV1.self
        )
        let reply = message.reply()
        try reply.setEngineSandboxPayload(
            try await startWorkload(request, stdio: message.engineSandboxStdio())
        )
        return reply
    }

    @Sendable
    public func observeWorkloadStartMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStartRequestV1.self
        )
        let reply = message.reply()
        try reply.setEngineSandboxPayload(try await observeWorkloadStart(request))
        return reply
    }

    @Sendable
    public func dialServiceMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxServiceDialRequestV1.self
        )
        let reply = message.reply()
        reply.set(
            key: RuntimeKeys.fd.rawValue,
            value: try await dialService(request)
        )
        return reply
    }

    private func validate(_ request: EngineLinuxSandboxBootRequestV1) throws {
        try validateIdentity(
            sandboxID: request.sandboxID,
            generation: request.generation,
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            effectID: request.effectID
        )
    }

    private func validate(_ request: EngineLinuxSandboxShutdownRequestV1) throws {
        try validateIdentity(
            sandboxID: request.sandboxID,
            generation: request.generation,
            idempotencyKey: request.idempotencyKey,
            requestDigest: request.requestDigest,
            effectID: request.effectID
        )
    }

    private func validate(_ request: EngineLinuxSandboxWorkloadStartRequestV1) throws {
        let context = request.context
        let identifierLimit = EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes
        let digestLimit = EngineWorkloadLedgerLimitsV1.maximumDigestBytes
        guard
            !context.containerID.isEmpty,
            context.containerID.utf8.count <= identifierLimit,
            context.operationGeneration > 0,
            context.candidateProcessGeneration > 0,
            context.sandboxGeneration > 0,
            !context.requestDigest.isEmpty,
            context.requestDigest.utf8.count <= digestLimit,
            request.workloadRoot.isFileURL,
            request.workloadRoot.path.utf8.count <= 4096,
            !request.workloadConfigurationDigest.isEmpty,
            request.workloadConfigurationDigest.utf8.count <= digestLimit,
            request.dynamicEnvironment.count <= 1024
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox workload start request"
            )
        }
        try WorkloadNetworkPlan.validate(request.networkEndpoints)
    }

    private func validate(_ request: EngineLinuxSandboxServiceDialRequestV1) throws {
        guard
            request.sandboxID == sandbox.id,
            !request.sandboxID.isEmpty,
            request.sandboxID.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes,
            request.sandboxGeneration > 0,
            request.port > 0
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox protected service dial request"
            )
        }
    }

    private func validateIdentity(
        sandboxID: String,
        generation: UInt64,
        idempotencyKey: String,
        requestDigest: String,
        effectID: String
    ) throws {
        let identifierLimit = EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes
        let digestLimit = EngineWorkloadLedgerLimitsV1.maximumDigestBytes
        guard sandboxID == sandbox.id,
            generation > 0,
            !idempotencyKey.isEmpty,
            idempotencyKey.utf8.count <= identifierLimit,
            !effectID.isEmpty,
            effectID.utf8.count <= identifierLimit,
            !requestDigest.isEmpty,
            requestDigest.utf8.count <= digestLimit
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox operation identity"
            )
        }
    }

    private func conflictingOperation(_ operation: String) -> ContainerizationError {
        ContainerizationError(
            .invalidState,
            message: "a conflicting \(operation) is already in flight"
        )
    }

    private func unattributedState(_ message: String) -> ContainerizationError {
        ContainerizationError(.invalidState, message: message)
    }

    private func closeWorkloadCaptures() {
        for capture in workloadCaptures.values {
            capture.close()
        }
        workloadCaptures.removeAll()
    }
}

extension EngineLinuxSandboxBootReceiptV1 {
    fileprivate func matches(_ request: EngineLinuxSandboxBootRequestV1) -> Bool {
        sandboxID == request.sandboxID
            && generation == request.generation
            && effectID == request.effectID
            && requestDigest == request.requestDigest
    }
}

extension EngineLinuxSandboxShutdownReceiptV1 {
    fileprivate func matches(_ request: EngineLinuxSandboxShutdownRequestV1) -> Bool {
        sandboxID == request.sandboxID
            && generation == request.generation
            && effectID == request.effectID
            && requestDigest == request.requestDigest
    }
}

extension WorkloadProcessReceiptV1 {
    fileprivate func matches(_ context: WorkloadStartContextV1) -> Bool {
        containerID == context.containerID
            && operationGeneration == context.operationGeneration
            && processGeneration == context.candidateProcessGeneration
            && sandboxGeneration == context.sandboxGeneration
            && requestDigest == context.requestDigest
    }
}
