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

import ContainerAPIClient
import ContainerNetworkClient
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

/// A host VSOCK listener that yields reverse connections from one protected
/// workload. The listener is private to the runtime authority and is closed
/// whenever its associated workload generation becomes terminal.
public protocol EngineLinuxSandboxServiceListenerV1: AnyObject, Sendable {
    func nextConnection() async throws -> FileHandle
    func close() async
}

private actor ContainerizationEngineLinuxSandboxServiceListenerV1:
    EngineLinuxSandboxServiceListenerV1
{
    private let listener: VsockListener
    private var bufferedConnections = [FileHandle]()
    private var waiters = [CheckedContinuation<FileHandle?, Never>]()
    private var acceptTask: Task<Void, Never>?
    private var closed = false

    init(listener: VsockListener) {
        self.listener = listener
    }

    func startAccepting() {
        guard acceptTask == nil, !closed else {
            return
        }
        let listener = self.listener
        acceptTask = Task { [weak self, listener] in
            for await connection in listener {
                await self?.receive(connection)
            }
            await self?.finishAccepting()
        }
    }

    func nextConnection() async throws -> FileHandle {
        if !bufferedConnections.isEmpty {
            return bufferedConnections.removeFirst()
        }
        guard !closed else {
            throw ContainerizationError(
                .invalidState,
                message: "sealed reverse VSOCK listener is closed"
            )
        }
        guard
            let connection = await withCheckedContinuation({ continuation in
                waiters.append(continuation)
            })
        else {
            throw ContainerizationError(
                .invalidState,
                message: "sealed reverse VSOCK listener finished without a connection"
            )
        }
        return connection
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        acceptTask?.cancel()
        acceptTask = nil
        try? listener.finish()
        resumeWaiters()
        closeBufferedConnections()
    }

    private func receive(_ connection: FileHandle) {
        guard !closed else {
            try? connection.close()
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: connection)
        } else {
            bufferedConnections.append(connection)
        }
    }

    private func finishAccepting() {
        guard !closed else {
            return
        }
        closed = true
        acceptTask = nil
        resumeWaiters()
        closeBufferedConnections()
    }

    private func resumeWaiters() {
        let suspended = waiters
        waiters.removeAll()
        for waiter in suspended {
            waiter.resume(returning: nil)
        }
    }

    private func closeBufferedConnections() {
        let connections = bufferedConnections
        bufferedConnections.removeAll()
        for connection in connections {
            try? connection.close()
        }
    }
}

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
    func stopContainer(_ containerID: String) async throws
    func removeContainer(_ containerID: String) async throws
    func waitContainer(
        _ containerID: String,
        timeoutInSeconds: Int64?
    ) async throws -> ExitStatus
    func workloadStatus(_ containerID: String) async throws -> RuntimeStatus
    func pauseWorkload(_ containerID: String) async throws
    func resumeWorkload(_ containerID: String) async throws
    func signalWorkload(_ containerID: String, signal: String) async throws
    func resizeWorkload(
        _ containerID: String,
        width: UInt16,
        height: UInt16
    ) async throws
    func workloadStatistics(_ containerID: String) async throws -> ContainerStats
    func workloadProcesses(_ containerID: String) async throws -> ContainerProcesses
    func dialVsock(port: UInt32) async throws -> FileHandle
    func listenVsock(port: UInt32) async throws
        -> any EngineLinuxSandboxServiceListenerV1
}

extension LinuxPod: EngineLinuxSandboxInstanceV1 {
    public func workloadStatus(_ containerID: String) async throws -> RuntimeStatus {
        guard let workload = await snapshot().workloads.first(where: { $0.id == containerID }) else {
            throw ContainerizationError(
                .notFound,
                message: "workload \(containerID) not found in shared sandbox"
            )
        }
        return switch workload.state {
        case .registered, .created, .stopped:
            .stopped
        case .running:
            .running
        case .paused:
            .paused
        case .recoveryRequired:
            .unknown
        }
    }

    public func pauseWorkload(_ containerID: String) async throws {
        try await pauseContainer(containerID)
    }

    public func resumeWorkload(_ containerID: String) async throws {
        try await resumeContainer(containerID)
    }

    public func signalWorkload(_ containerID: String, signal: String) async throws {
        try await killContainer(containerID, signal: try Signal(signal))
    }

    public func resizeWorkload(
        _ containerID: String,
        width: UInt16,
        height: UInt16
    ) async throws {
        try await resizeContainer(
            containerID,
            to: .init(width: width, height: height)
        )
    }

    public func workloadStatistics(_ containerID: String) async throws -> ContainerStats {
        guard let stats = try await statistics(containerIDs: [containerID]).first else {
            throw ContainerizationError(
                .notFound,
                message: "statistics for workload \(containerID) were not returned"
            )
        }
        return ContainerStats(
            id: stats.id,
            memoryUsageBytes: stats.memory?.usageBytes,
            memoryLimitBytes: stats.memory?.limitBytes,
            cpuUsageUsec: stats.cpu?.usageUsec,
            networkRxBytes: stats.networks?.reduce(0) { $0 + $1.receivedBytes },
            networkTxBytes: stats.networks?.reduce(0) { $0 + $1.transmittedBytes },
            blockReadBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.readBytes },
            blockWriteBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.writeBytes },
            numProcesses: stats.process?.current,
            memoryOOMKillCount: stats.memoryEvents?.oomKill
        )
    }

    public func workloadProcesses(_ containerID: String) async throws -> ContainerProcesses {
        let identifiers = try await processIdentifiers(containerID)
        let rows = try await processes(containerID)
        return ContainerProcesses(
            id: containerID,
            processIdentifiers: identifiers,
            processes: rows.map {
                ContainerResource.ContainerProcessInfo(
                    uid: $0.uid,
                    pid: $0.pid,
                    ppid: $0.ppid,
                    cpu: $0.cpu,
                    startTime: $0.startTime,
                    tty: $0.tty,
                    time: $0.time,
                    command: $0.command
                )
            }
        )
    }

    public func listenVsock(port: UInt32) async throws
        -> any EngineLinuxSandboxServiceListenerV1
    {
        let listener = try await withVirtualMachineInstance { vm in
            try vm.listen(port)
        }
        let serviceListener = ContainerizationEngineLinuxSandboxServiceListenerV1(
            listener: listener
        )
        await serviceListener.startAccepting()
        return serviceListener
    }
}

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
        let task: Task<WorkloadStartResult, any Error>
    }

    private struct WorkloadStopInFlight: Sendable {
        let request: EngineLinuxSandboxWorkloadStopRequestV1
        let task: Task<EngineLinuxSandboxWorkloadStopReceiptV1, any Error>
    }

    private struct ServiceListenerSlot: Sendable {
        let sandboxGeneration: UInt64
        let workloadProcessGeneration: UInt64
        let port: UInt32
        let listener: any EngineLinuxSandboxServiceListenerV1

        func matches(_ request: EngineLinuxSandboxServiceDialRequestV1) -> Bool {
            sandboxGeneration == request.sandboxGeneration
                && workloadProcessGeneration == request.workloadProcessGeneration
                && port == request.port
        }
    }

    private struct WorkloadStartResult: Sendable {
        let receipt: WorkloadProcessReceiptV1
        let serviceListener: ServiceListenerSlot?
    }

    private struct ServiceListenerOpenInFlight: Sendable {
        let request: EngineLinuxSandboxServiceDialRequestV1
        let task: Task<ServiceListenerSlot, any Error>
    }

    /// Keeps the default VMNet allocation alive while the shared sandbox is
    /// available. The network helper releases the address when this XPC
    /// session closes, so the attachment must outlive individual VM boots.
    private struct SealedEgressNetworkBinding: Sendable {
        let client: ContainerNetworkClient.NetworkClient
        let session: XPCClientSession
    }

    private let connection: xpc_connection_t?
    private let sandbox: any EngineLinuxSandboxInstanceV1
    private let runtimeFingerprint: String
    private let log: Logger
    private let sealedEgressNetworkBinding: SealedEgressNetworkBinding?
    private var bootReceipt: EngineLinuxSandboxBootReceiptV1?
    private var shutdownReceipt: EngineLinuxSandboxShutdownReceiptV1?
    private var bootInFlight: BootInFlight?
    private var shutdownInFlight: ShutdownInFlight?
    private var workloadStartInFlight: [String: WorkloadStartInFlight] = [:]
    private var workloadStopInFlight: [String: WorkloadStopInFlight] = [:]
    private var workloadRequests: [String: EngineLinuxSandboxWorkloadStartRequestV1] = [:]
    private var workloadReceipts: [String: WorkloadProcessReceiptV1] = [:]
    private var workloadStopRequests: [String: EngineLinuxSandboxWorkloadStopRequestV1] = [:]
    private var workloadStopReceipts: [String: EngineLinuxSandboxWorkloadStopReceiptV1] = [:]
    private var workloadCaptures: [String: ContainerLogRuntimeCapture] = [:]
    private var workloadIO: [String: EngineLinuxSandboxWorkloadIO] = [:]
    private var workloadTerminalMonitors: [String: Task<Void, Never>] = [:]
    private var terminalWorkloadGenerations: [String: UInt64] = [:]
    private var serviceListeners: [String: ServiceListenerSlot] = [:]
    private var serviceListenerOpenInFlight: [String: ServiceListenerOpenInFlight] = [:]
    private var serviceDialsInFlight = 0
    private static let protectedServiceListenerAcceptTimeout = Duration.seconds(1)

    public init(
        sandbox: any EngineLinuxSandboxInstanceV1,
        runtimeFingerprint: String,
        connection: xpc_connection_t? = nil,
        log: Logger
    ) throws {
        try self.init(
            sandbox: sandbox,
            runtimeFingerprint: runtimeFingerprint,
            connection: connection,
            sealedEgressNetworkBinding: nil,
            log: log
        )
    }

    private init(
        sandbox: any EngineLinuxSandboxInstanceV1,
        runtimeFingerprint: String,
        connection: xpc_connection_t?,
        sealedEgressNetworkBinding: SealedEgressNetworkBinding?,
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
        self.sealedEgressNetworkBinding = sealedEgressNetworkBinding
    }

    public init(
        configuration: EngineLinuxSandboxRuntimeConfigurationV1,
        runtimeFingerprint: String,
        connection: xpc_connection_t,
        log: Logger
    ) async throws {
        try configuration.validate()
        let egressNetwork = try await Self.reserveSealedEgressNetwork(log: log)
        do {
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
                sandboxConfiguration.bootLog = .file(
                    path: configuration.path.appendingPathComponent("boot.log")
                )
                Self.configureSealedEgressNetwork(
                    &sandboxConfiguration,
                    interface: egressNetwork.interface
                )
            }
            try self.init(
                sandbox: sandbox,
                runtimeFingerprint: runtimeFingerprint,
                connection: connection,
                sealedEgressNetworkBinding: egressNetwork.binding,
                log: log
            )
        } catch {
            egressNetwork.binding?.session.close()
            throw error
        }
    }

    /// Installs the VMNet attachment used by host-network protected services.
    static func configureSealedEgressNetwork(
        _ configuration: inout LinuxPod.Configuration,
        interface: any Interface
    ) {
        configuration.interfaces = [interface]
        configuration.workloadNetworkBridge = WorkloadNetworkBridge(
            name: EngineLinuxSandboxNetworkingV1.workloadBridgeName
        )
    }

    private static func reserveSealedEgressNetwork(
        log: Logger
    ) async throws -> (interface: any Interface, binding: SealedEgressNetworkBinding?) {
        guard #available(macOS 26, *) else {
            return (
                interface: NATInterface(
                    ipv4Address: try CIDRv4("192.168.64.2/24"),
                    ipv4Gateway: try IPv4Address("192.168.64.1"),
                    mtu: 1280
                ),
                binding: nil
            )
        }

        let apiClient = ContainerAPIClient.NetworkClient()
        guard let defaultNetwork = try await apiClient.builtin else {
            throw ContainerizationError(
                .invalidState,
                message: "default VMNet network is not available for sealed service egress"
            )
        }
        let client = ContainerNetworkClient.NetworkClient(
            id: defaultNetwork.id,
            plugin: defaultNetwork.configuration.plugin
        )
        let session = client.connect()
        do {
            let (attachment, additionalData) = try await client.allocate(
                hostname: "engine-linux-sandbox-egress",
                on: session
            )
            let interface = try NonisolatedInterfaceStrategy(log: log).toInterface(
                attachment: attachment,
                interfaceIndex: 0,
                guestInterfaceName: nil,
                additionalData: additionalData
            )
            return (
                interface: interface,
                binding: SealedEgressNetworkBinding(client: client, session: session)
            )
        } catch {
            session.close()
            throw error
        }
    }

    public func boot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootReceiptV1 {
        try validate(request)
        guard shutdownInFlight == nil, workloadStartInFlight.isEmpty,
            workloadStopInFlight.isEmpty
        else {
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
            workloadStopInFlight.isEmpty,
            serviceListenerOpenInFlight.isEmpty,
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
            closeWorkloadIO()
            closeWorkloadCaptures()
            cancelWorkloadTerminalMonitors()
            await closeServiceListeners()
            workloadRequests.removeAll()
            workloadReceipts.removeAll()
            workloadStopRequests.removeAll()
            workloadStopReceipts.removeAll()
            terminalWorkloadGenerations.removeAll()
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
            closeWorkloadIO()
            closeWorkloadCaptures()
            cancelWorkloadTerminalMonitors()
            await closeServiceListeners()
            workloadRequests.removeAll()
            workloadReceipts.removeAll()
            workloadStopRequests.removeAll()
            workloadStopReceipts.removeAll()
            terminalWorkloadGenerations.removeAll()
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
        guard workloadStopInFlight[id] == nil else {
            throw conflictingOperation("workload stop for \(id)")
        }
        if let inFlight = workloadStartInFlight[id] {
            guard inFlight.request == request else {
                throw conflictingOperation("workload start for \(id)")
            }
            return try await inFlight.task.value.receipt
        }

        var snapshot = await sandbox.snapshot()
        guard snapshot.state == .running else {
            throw unattributedState("shared sandbox is not running for workload start")
        }
        guard
            let bootReceipt,
            bootReceipt.generation == request.context.sandboxGeneration
        else {
            throw unattributedState("workload start does not match the active sandbox generation")
        }

        var observed = snapshot.workloads.first { $0.id == id }
        if terminalWorkloadGenerations[id] != nil,
            observed?.state == .running || observed?.state == .paused
        {
            try await sandbox.stopContainer(id)
            snapshot = await sandbox.snapshot()
            observed = snapshot.workloads.first { $0.id == id }
        }
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
                workloadCaptures[id] != nil,
                workloadIO[id] != nil
            else {
                throw unattributedState("prepared workload \(id) has no matching materialization intent")
            }
        case .stopped?, nil:
            break
        }

        let isNewMaterialization = observed == nil || observed?.state == .stopped
        let capture: ContainerLogRuntimeCapture?
        let io: EngineLinuxSandboxWorkloadIO?
        let runtimeConfiguration: RuntimeConfiguration?
        let containerConfiguration: ContainerConfiguration?
        if isNewMaterialization {
            if observed?.state == .stopped {
                workloadIO.removeValue(forKey: id)?.close()
                workloadCaptures.removeValue(forKey: id)?.close()
                await closeServiceListener(for: id)
                workloadRequests[id] = nil
                workloadReceipts[id] = nil
                workloadStopRequests[id] = nil
                workloadStopReceipts[id] = nil
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
            let activatedCapture = try loggingPlan.activate(
                bundle: loadedBundle,
                terminal: loadedContainerConfiguration.initProcess.terminal
            )
            capture = activatedCapture
            io = EngineLinuxSandboxWorkloadIO(
                stdio: stdio,
                loggingCapture: activatedCapture,
                terminal: loadedContainerConfiguration.initProcess.terminal
            )
            runtimeConfiguration = loadedRuntimeConfiguration
            containerConfiguration = loadedContainerConfiguration
        } else {
            capture = nil
            io = nil
            runtimeConfiguration = nil
            containerConfiguration = nil
        }

        let sealedServicePort = containerConfiguration.flatMap {
            EngineLinuxSandboxServiceEndpointV1.reverseVsockPort(
                arguments: $0.initProcess.arguments,
                publishedSockets: $0.publishedSockets
            )
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
        let task = Task<WorkloadStartResult, any Error> {
            var serviceListener: ServiceListenerSlot?
            do {
                if let sealedServicePort {
                    let listener = try await sandbox.listenVsock(port: sealedServicePort)
                    serviceListener = ServiceListenerSlot(
                        sandboxGeneration: receipt.sandboxGeneration,
                        workloadProcessGeneration: receipt.processGeneration,
                        port: sealedServicePort,
                        listener: listener
                    )
                }
                if observed?.state == .stopped {
                    try await sandbox.removeContainer(id)
                }
                if let runtimeConfiguration,
                    let containerConfiguration,
                    let rootfs = runtimeConfiguration.containerRootFilesystem,
                    let io
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
                            io: io,
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
                return WorkloadStartResult(
                    receipt: receipt,
                    serviceListener: serviceListener
                )
            } catch {
                if let serviceListener {
                    await serviceListener.listener.close()
                }
                throw error
            }
        }
        workloadStartInFlight[id] = WorkloadStartInFlight(request: request, task: task)
        do {
            let applied = try await task.value
            workloadRequests[id] = request
            workloadReceipts[id] = applied.receipt
            terminalWorkloadGenerations[id] = nil
            if let serviceListener = applied.serviceListener,
                serviceListeners[id] == nil
            {
                serviceListeners[id] = serviceListener
            }
            if let capture {
                workloadCaptures[id]?.close()
                workloadCaptures[id] = capture
            }
            if let io {
                workloadIO[id]?.close()
                workloadIO[id] = io
            }
            if request.monitorTerminal {
                startWorkloadTerminalMonitor(id: id, receipt: applied.receipt)
            }
            workloadStartInFlight[id] = nil
            return applied.receipt
        } catch {
            let failureSnapshot = await sandbox.snapshot()
            if let capture {
                if let workload = failureSnapshot.workloads.first(where: { $0.id == id }),
                    workload.state == .registered || workload.state == .created
                {
                    workloadRequests[id] = request
                    workloadCaptures[id]?.close()
                    workloadCaptures[id] = capture
                    if let io {
                        workloadIO[id]?.close()
                        workloadIO[id] = io
                    }
                } else {
                    io?.close()
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
        if terminalWorkloadGenerations[id]
            == request.context.candidateProcessGeneration
        {
            return .absent
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

    public func stopWorkload(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopReceiptV1 {
        try validate(request)
        let id = request.workloadID
        guard bootInFlight == nil, shutdownInFlight == nil,
            workloadStartInFlight[id] == nil
        else {
            throw conflictingOperation("workload stop for \(id)")
        }
        if let inFlight = workloadStopInFlight[id] {
            guard inFlight.request == request else {
                throw conflictingOperation("workload stop for \(id)")
            }
            return try await inFlight.task.value
        }
        if let previous = workloadStopRequests[id] {
            guard
                previous == request,
                let receipt = workloadStopReceipts[id]
            else {
                throw conflictingOperation("workload stop for \(id)")
            }
            let snapshot = await sandbox.snapshot()
            guard
                snapshot.workloads.first(where: { $0.id == id })?.state
                    == .stopped
            else {
                throw unattributedState(
                    "completed workload stop no longer has a stopped observation"
                )
            }
            return receipt
        }

        let snapshot = await sandbox.snapshot()
        guard snapshot.state == .running,
            let bootReceipt,
            bootReceipt.sandboxID == request.sandboxID,
            bootReceipt.generation == request.sandboxGeneration,
            let startRequest = workloadRequests[id],
            let startReceipt = workloadReceipts[id],
            startRequest.context.sandboxGeneration
                == request.sandboxGeneration,
            startRequest.context.candidateProcessGeneration
                == request.workloadProcessGeneration,
            startReceipt.processGeneration
                == request.workloadProcessGeneration,
            startReceipt.sandboxGeneration == request.sandboxGeneration
        else {
            throw unattributedState(
                "workload stop does not match the active workload generation"
            )
        }
        let observed = snapshot.workloads.first { $0.id == id }
        let receipt = EngineLinuxSandboxWorkloadStopReceiptV1(
            request: request
        )
        if observed?.state == .stopped {
            workloadStopRequests[id] = request
            workloadStopReceipts[id] = receipt
            terminalWorkloadGenerations[id] = request.workloadProcessGeneration
            workloadIO.removeValue(forKey: id)?.close()
            workloadCaptures.removeValue(forKey: id)?.close()
            workloadTerminalMonitors.removeValue(forKey: id)?.cancel()
            await closeServiceListener(for: id)
            return receipt
        }
        guard observed?.state == .running || observed?.state == .paused else {
            throw unattributedState(
                "workload stop has no attributable active process"
            )
        }

        let sandbox = self.sandbox
        let task = Task<EngineLinuxSandboxWorkloadStopReceiptV1, any Error> {
            try await sandbox.stopContainer(id)
            let observation = await sandbox.snapshot()
            guard
                observation.workloads.first(where: { $0.id == id })?.state
                    == .stopped
            else {
                throw ContainerizationError(
                    .internalError,
                    message:
                        "workload stop returned without a stopped observation"
                )
            }
            return receipt
        }
        workloadStopInFlight[id] = WorkloadStopInFlight(
            request: request,
            task: task
        )
        do {
            let applied = try await task.value
            workloadStopRequests[id] = request
            workloadStopReceipts[id] = applied
            terminalWorkloadGenerations[id] = request.workloadProcessGeneration
            workloadIO.removeValue(forKey: id)?.close()
            workloadCaptures.removeValue(forKey: id)?.close()
            workloadTerminalMonitors.removeValue(forKey: id)?.cancel()
            await closeServiceListener(for: id)
            workloadStopInFlight[id] = nil
            return applied
        } catch {
            workloadStopInFlight[id] = nil
            log.error(
                "Engine Linux sandbox workload stop failed",
                metadata: ["containerID": "\(id)", "error": "\(error)"]
            )
            throw error
        }
    }

    public func observeWorkloadStop(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopObservationV1 {
        try validate(request)
        let snapshot = await sandbox.snapshot()
        guard snapshot.state == .running,
            let bootReceipt,
            bootReceipt.sandboxID == request.sandboxID,
            bootReceipt.generation == request.sandboxGeneration
        else {
            return .unknown
        }
        let observed = snapshot.workloads.first { $0.id == request.workloadID }
        if workloadStopRequests[request.workloadID] == request,
            let receipt = workloadStopReceipts[request.workloadID],
            observed?.state == .stopped
        {
            return .stopped(receipt)
        }
        if terminalWorkloadGenerations[request.workloadID]
            == request.workloadProcessGeneration,
            observed == nil || observed?.state == .stopped
        {
            return .absent
        }
        if observed?.state == .running || observed?.state == .paused,
            let start = workloadRequests[request.workloadID],
            let receipt = workloadReceipts[request.workloadID],
            start.context.candidateProcessGeneration
                == request.workloadProcessGeneration,
            start.context.sandboxGeneration == request.sandboxGeneration,
            receipt.processGeneration == request.workloadProcessGeneration,
            receipt.sandboxGeneration == request.sandboxGeneration
        {
            return .running
        }
        return .unknown
    }

    public func controlWorkload(
        _ request: EngineLinuxSandboxWorkloadControlRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadControlResponseV1 {
        try validate(request)
        switch request.action {
        case .state:
            return .state(try await sandbox.workloadStatus(request.workloadID))
        case .wait(let timeoutInSeconds):
            return .exit(
                EngineLinuxSandboxWorkloadExitStatusV1(
                    try await sandbox.waitContainer(
                        request.workloadID,
                        timeoutInSeconds: timeoutInSeconds
                    )
                )
            )
        case .pause:
            try await sandbox.pauseWorkload(request.workloadID)
            return .none
        case .resume:
            try await sandbox.resumeWorkload(request.workloadID)
            return .none
        case .signal(let signal):
            try await sandbox.signalWorkload(request.workloadID, signal: signal)
            return .none
        case .resize(let width, let height):
            try await sandbox.resizeWorkload(
                request.workloadID,
                width: width,
                height: height
            )
            return .none
        case .statistics:
            return .statistics(
                try await sandbox.workloadStatistics(request.workloadID)
            )
        case .processes:
            return .processes(
                try await sandbox.workloadProcesses(request.workloadID)
            )
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
        let terminalGeneration = terminalWorkloadGenerations[request.workloadID]
        let workload = snapshot.workloads.first(where: {
            $0.id == request.workloadID
        })
        let start = workloadRequests[request.workloadID]
        let receipt = workloadReceipts[request.workloadID]
        guard
            terminalGeneration != request.workloadProcessGeneration,
            let workload,
            workload.state == .running,
            let start,
            let receipt,
            start.context.containerID == request.workloadID,
            start.context.sandboxGeneration == request.sandboxGeneration,
            start.context.candidateProcessGeneration
                == request.workloadProcessGeneration,
            receipt.containerID == request.workloadID,
            receipt.operationGeneration
                == start.context.operationGeneration,
            receipt.processGeneration == request.workloadProcessGeneration,
            receipt.sandboxGeneration == request.sandboxGeneration,
            receipt.requestDigest == start.context.requestDigest
        else {
            log.error(
                "protected service workload generation fence rejected dial",
                metadata: [
                    "workloadID": "\(request.workloadID)",
                    "requestedProcessGeneration": "\(request.workloadProcessGeneration)",
                    "terminalProcessGeneration": "\(String(describing: terminalGeneration))",
                    "observedWorkloadState": "\(String(describing: workload?.state))",
                    "hasStartRequest": "\(start != nil)",
                    "hasStartReceipt": "\(receipt != nil)",
                ]
            )
            throw unattributedState(
                "protected service workload is not ready for the requested generation"
            )
        }
        let runtimeConfiguration =
            try RuntimeConfiguration
            .readRuntimeConfiguration(from: start.workloadRoot)
        let observedConfigurationDigest =
            try EngineLinuxSandboxWorkloadIntegrityV1
            .configurationDigest(runtimeConfiguration)
        let configurationDigestMatches =
            observedConfigurationDigest == start.workloadConfigurationDigest
        let configurationPathMatches =
            runtimeConfiguration.path.resolvingSymlinksInPath()
            .standardizedFileURL.path
            == start.workloadRoot.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let containerConfiguration = runtimeConfiguration.containerConfiguration
        let declaredReverseVsockPort = containerConfiguration.flatMap {
            EngineLinuxSandboxServiceEndpointV1.reverseVsockPort(
                arguments: $0.initProcess.arguments,
                publishedSockets: $0.publishedSockets
            )
        }
        let declaredGuestVsockPort = containerConfiguration.flatMap {
            EngineLinuxSandboxServiceEndpointV1.guestVsockPort(
                arguments: $0.initProcess.arguments,
                publishedSockets: $0.publishedSockets
            )
        }
        guard
            configurationDigestMatches,
            configurationPathMatches,
            containerConfiguration != nil,
            declaredReverseVsockPort == request.port
                || declaredGuestVsockPort == request.port
        else {
            log.error(
                "protected service endpoint validation rejected dial",
                metadata: [
                    "workloadID": "\(request.workloadID)",
                    "requestPort": "\(request.port)",
                    "declaredReverseVsockPort": "\(String(describing: declaredReverseVsockPort))",
                    "declaredGuestVsockPort": "\(String(describing: declaredGuestVsockPort))",
                    "configurationDigestMatches": "\(configurationDigestMatches)",
                    "configurationPathMatches": "\(configurationPathMatches)",
                    "hasContainerConfiguration": "\(containerConfiguration != nil)",
                    "publishedSocketCount": "\(containerConfiguration?.publishedSockets.count ?? 0)",
                ]
            )
            throw unattributedState(
                "protected service workload has no matching sealed VSOCK endpoint"
            )
        }
        serviceDialsInFlight += 1
        defer { serviceDialsInFlight -= 1 }
        if declaredReverseVsockPort == request.port {
            log.debug(
                "protected service transport selected",
                metadata: [
                    "transport": "reverse-host-vsock",
                    "workloadID": "\(request.workloadID)",
                    "port": "\(request.port)",
                ]
            )
            let listener = try await serviceListener(for: request)
            do {
                return try await acceptServiceConnection(from: listener.listener)
            } catch {
                await closeServiceListener(
                    for: request.workloadID,
                    matching: listener
                )
                throw error
            }
        }
        log.debug(
            "protected service transport selected",
            metadata: [
                "transport": "direct-guest-vsock",
                "workloadID": "\(request.workloadID)",
                "port": "\(request.port)",
            ]
        )
        return try await sandbox.dialVsock(port: request.port)
    }

    private func serviceListener(
        for request: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> ServiceListenerSlot {
        let id = request.workloadID
        if let existing = serviceListeners[id] {
            guard existing.matches(request) else {
                await closeServiceListener(for: id)
                throw unattributedState(
                    "protected service listener does not match the requested generation"
                )
            }
            return existing
        }
        if let inFlight = serviceListenerOpenInFlight[id] {
            guard inFlight.request == request else {
                throw conflictingOperation("protected service listener open for \(id)")
            }
            return try await inFlight.task.value
        }

        let sandbox = self.sandbox
        let task = Task<ServiceListenerSlot, any Error> {
            let listener = try await sandbox.listenVsock(port: request.port)
            if Task.isCancelled {
                await listener.close()
                throw CancellationError()
            }
            return ServiceListenerSlot(
                sandboxGeneration: request.sandboxGeneration,
                workloadProcessGeneration: request.workloadProcessGeneration,
                port: request.port,
                listener: listener
            )
        }
        serviceListenerOpenInFlight[id] = ServiceListenerOpenInFlight(
            request: request,
            task: task
        )
        do {
            let opened = try await task.value
            serviceListenerOpenInFlight[id] = nil
            if let existing = serviceListeners[id] {
                await opened.listener.close()
                guard existing.matches(request) else {
                    throw unattributedState(
                        "protected service listener changed while opening"
                    )
                }
                return existing
            }
            serviceListeners[id] = opened
            return opened
        } catch {
            serviceListenerOpenInFlight[id] = nil
            throw error
        }
    }

    private func acceptServiceConnection(
        from listener: any EngineLinuxSandboxServiceListenerV1
    ) async throws -> FileHandle {
        try await withThrowingTaskGroup(of: FileHandle?.self) { group in
            do {
                group.addTask {
                    try await listener.nextConnection()
                }
                group.addTask {
                    try await Task.sleep(
                        for: Self.protectedServiceListenerAcceptTimeout
                    )
                    return nil
                }
                guard let result = try await group.next(), let connection = result else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "sealed reverse VSOCK listener did not connect before timeout"
                    )
                }
                group.cancelAll()
                return connection
            } catch {
                group.cancelAll()
                await listener.close()
                throw error
            }
        }
    }

    private func closeServiceListener(for id: String) async {
        let listener = serviceListeners.removeValue(forKey: id)
        let opening = serviceListenerOpenInFlight.removeValue(forKey: id)
        opening?.task.cancel()
        if let listener {
            await listener.listener.close()
        }
    }

    private func closeServiceListener(
        for id: String,
        matching expected: ServiceListenerSlot
    ) async {
        guard let listener = serviceListeners[id],
            listener.listener === expected.listener
        else {
            return
        }
        serviceListeners[id] = nil
        await listener.listener.close()
    }

    private func closeServiceListeners() async {
        let identifiers = Array(serviceListeners.keys)
        for id in identifiers {
            await closeServiceListener(for: id)
        }
        let openings = serviceListenerOpenInFlight.values
        serviceListenerOpenInFlight.removeAll()
        for opening in openings {
            opening.task.cancel()
        }
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
        let receipt = try await boot(request)
        return try message.engineSandboxReply(receipt)
    }

    @Sendable
    public func observeBootMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxBootRequestV1.self)
        let observation = try await observeBoot(request)
        return try message.engineSandboxReply(observation)
    }

    @Sendable
    public func shutdownMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxShutdownRequestV1.self)
        let receipt = try await shutdown(request)
        return try message.engineSandboxReply(receipt)
    }

    @Sendable
    public func observeShutdownMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(EngineLinuxSandboxShutdownRequestV1.self)
        let observation = try await observeShutdown(request)
        return try message.engineSandboxReply(observation)
    }

    @Sendable
    public func startWorkloadMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStartRequestV1.self
        )
        let receipt = try await startWorkload(
            request,
            stdio: message.engineSandboxStdio()
        )
        return try message.engineSandboxReply(receipt)
    }

    @Sendable
    public func observeWorkloadStartMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStartRequestV1.self
        )
        let observation = try await observeWorkloadStart(request)
        return try message.engineSandboxReply(observation)
    }

    @Sendable
    public func stopWorkloadMessage(_ message: XPCMessage) async throws
        -> XPCMessage
    {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStopRequestV1.self
        )
        let receipt = try await stopWorkload(request)
        return try message.engineSandboxReply(receipt)
    }

    @Sendable
    public func observeWorkloadStopMessage(_ message: XPCMessage) async throws
        -> XPCMessage
    {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadStopRequestV1.self
        )
        let observation = try await observeWorkloadStop(request)
        return try message.engineSandboxReply(observation)
    }

    @Sendable
    public func controlWorkloadMessage(_ message: XPCMessage) async throws
        -> XPCMessage
    {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxWorkloadControlRequestV1.self
        )
        let response = try await controlWorkload(request)
        return try message.engineSandboxReply(response)
    }

    @Sendable
    public func dialServiceMessage(_ message: XPCMessage) async throws -> XPCMessage {
        let request = try message.engineSandboxPayload(
            EngineLinuxSandboxServiceDialRequestV1.self
        )
        let handle = try await dialService(request)
        let reply = message.reply()
        reply.set(
            key: RuntimeKeys.fd.rawValue,
            value: handle
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

    private func validate(
        _ request: EngineLinuxSandboxWorkloadControlRequestV1
    ) throws {
        guard
            request.sandboxID == sandbox.id,
            request.sandboxGeneration > 0,
            !request.workloadID.isEmpty,
            request.workloadID.utf8.count
                <= EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes,
            request.workloadProcessGeneration > 0,
            let bootReceipt,
            bootReceipt.sandboxID == request.sandboxID,
            bootReceipt.generation == request.sandboxGeneration,
            let receipt = workloadReceipts[request.workloadID],
            receipt.sandboxGeneration == request.sandboxGeneration,
            receipt.processGeneration == request.workloadProcessGeneration
        else {
            throw ContainerizationError(
                .invalidState,
                message: "shared sandbox control request does not match the active workload generation"
            )
        }
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

    private func validate(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) throws {
        let identifierLimit = EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes
        let digestLimit = EngineWorkloadLedgerLimitsV1.maximumDigestBytes
        guard
            request.sandboxID == sandbox.id,
            !request.sandboxID.isEmpty,
            request.sandboxID.utf8.count <= identifierLimit,
            request.sandboxGeneration > 0,
            !request.workloadID.isEmpty,
            request.workloadID.utf8.count <= identifierLimit,
            request.workloadProcessGeneration > 0,
            request.operationGeneration > 0,
            !request.idempotencyKey.isEmpty,
            request.idempotencyKey.utf8.count <= identifierLimit,
            !request.requestDigest.isEmpty,
            request.requestDigest.utf8.count <= digestLimit
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox workload stop request"
            )
        }
    }

    private func validate(_ request: EngineLinuxSandboxServiceDialRequestV1) throws {
        guard
            request.sandboxID == sandbox.id,
            !request.sandboxID.isEmpty,
            request.sandboxID.utf8.count <= EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes,
            request.sandboxGeneration > 0,
            !request.workloadID.isEmpty,
            request.workloadID.utf8.count
                <= EngineWorkloadLedgerLimitsV1.maximumIdentifierBytes,
            request.workloadProcessGeneration > 0,
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

    private func closeWorkloadIO() {
        for io in workloadIO.values {
            io.close()
        }
        workloadIO.removeAll()
    }

    private func startWorkloadTerminalMonitor(
        id: String,
        receipt: WorkloadProcessReceiptV1
    ) {
        workloadTerminalMonitors.removeValue(forKey: id)?.cancel()
        let sandbox = self.sandbox
        workloadTerminalMonitors[id] = Task { [weak self] in
            do {
                let status = try await sandbox.waitContainer(
                    id,
                    timeoutInSeconds: nil
                )
                try Task.checkCancellation()
                await self?.recordTerminalWorkload(
                    id: id,
                    receipt: receipt,
                    status: status
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.recordTerminalMonitorFailure(
                    id: id,
                    receipt: receipt,
                    error: error
                )
            }
        }
    }

    private func recordTerminalWorkload(
        id: String,
        receipt: WorkloadProcessReceiptV1,
        status: ExitStatus
    ) async {
        guard workloadReceipts[id] == receipt else {
            return
        }
        terminalWorkloadGenerations[id] = receipt.processGeneration
        log.error(
            "protected service workload exited",
            metadata: [
                "containerID": "\(id)",
                "processGeneration": "\(receipt.processGeneration)",
                "status": "\(status)",
            ]
        )
        workloadIO.removeValue(forKey: id)?.close()
        workloadCaptures.removeValue(forKey: id)?.close()
        await closeServiceListener(for: id)
        do {
            try await sandbox.stopContainer(id)
        } catch {
            log.error(
                "Engine Linux sandbox terminal workload cleanup failed",
                metadata: ["containerID": "\(id)", "error": "\(error)"]
            )
        }
        workloadTerminalMonitors[id] = nil
    }

    private func recordTerminalMonitorFailure(
        id: String,
        receipt: WorkloadProcessReceiptV1,
        error: any Error
    ) async {
        guard workloadReceipts[id] == receipt else {
            return
        }
        terminalWorkloadGenerations[id] = receipt.processGeneration
        workloadIO.removeValue(forKey: id)?.close()
        workloadCaptures.removeValue(forKey: id)?.close()
        await closeServiceListener(for: id)
        workloadTerminalMonitors[id] = nil
        log.error(
            "Engine Linux sandbox terminal workload observation failed",
            metadata: ["containerID": "\(id)", "error": "\(error)"]
        )
    }

    private func cancelWorkloadTerminalMonitors() {
        for monitor in workloadTerminalMonitors.values {
            monitor.cancel()
        }
        workloadTerminalMonitors.removeAll()
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
