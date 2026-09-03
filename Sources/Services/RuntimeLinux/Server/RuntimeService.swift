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

import ContainerNetworkClient
import ContainerOS
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import ContainerRuntimeLinuxClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import Logging
import NIO
import NIOFoundationCompat
import SocketForwarder
import Synchronization
import SystemPackage

import struct ContainerizationOCI.Mount
import struct ContainerizationOCI.Process

private final class StartedSocketForwarders: Sendable {
    private let storage = Mutex<[SocketForwarderResult]>([])

    func append(_ forwarder: SocketForwarderResult) {
        storage.withLock { $0.append(forwarder) }
    }

    func snapshot() -> [SocketForwarderResult] {
        storage.withLock { $0 }
    }
}

/// An XPC service that manages the lifecycle of a single VM-backed container.
public actor RuntimeService {
    private let connection: xpc_connection_t
    private let root: URL
    private let interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy]
    private var container: ContainerInfo?
    private let monitor: ExitMonitor
    private let eventLoopGroup: any EventLoopGroup
    private var waiters: [String: ExitWaiter] = [:]
    private let lock: AsyncLock = AsyncLock()
    private let log: Logging.Logger
    private var state: State = .created
    private var processes: [String: ProcessInfo] = [:]
    private var socketForwarders: [SocketForwarderResult] = []
    private var networkBindings: [NetworkBinding] = []
    private var dnsProxy: RuntimeDNSProxy?
    private var dnsProxyTask: Task<Void, Never>?

    static let sshAuthSocketGuestPath = "/var/host-services/ssh-auth.sock"
    static let sshAuthSocketEnvVar = "SSH_AUTH_SOCK"

    class ExitWaiter {
        public var exitStatus: ExitStatus? = nil
        public var continuations: [CheckedContinuation<ExitStatus, Never>] = []

        public func wait(_ cc: CheckedContinuation<ExitStatus, Never>) {
            if let exitStatus = exitStatus {
                // `doExit` has already been called for this waiter
                cc.resume(returning: exitStatus)
                return
            }
            continuations.append(cc)
        }

        public func doExit(exitStatus: ExitStatus) {
            // Exit fires exactly once. A second call (e.g. an onExit callback that
            // is retried after it threw) must not resume the same continuations
            // again — resuming a CheckedContinuation twice traps.
            guard self.exitStatus == nil else {
                return
            }
            self.exitStatus = exitStatus

            let pending = continuations
            continuations = []
            for cc in pending {
                cc.resume(returning: exitStatus)
            }
        }
    }

    static func sshAuthSocketHostUrl(
        config: ContainerConfiguration,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil
    ) -> URL? {
        guard config.ssh else {
            return nil
        }

        guard let sshSocket = dynamicEnv[Self.sshAuthSocketEnvVar] else {
            log?.warning("ssh forwarding requested but no \(Self.sshAuthSocketEnvVar) found")
            return nil
        }

        return URL(fileURLWithPath: sshSocket)
    }

    /// Returns the runtime log writer for the configured container log policy.
    static func containerLogWriter(bundle: ContainerResource.Bundle, logging: ContainerLogConfiguration) throws -> ContainerLogFileWriter? {
        switch logging.storage {
        case .local:
            return try ContainerLogFileWriter(
                rawLogURL: bundle.containerLog,
                recordLogURL: bundle.containerLogRecords,
                maxSizeInBytes: logging.maxSizeInBytes,
                maxFileCount: logging.maxFileCount
            )
        case .none:
            return nil
        }
    }

    /// Combines caller-attached stdio with optional persisted log capture.
    static func outputWriter(stdio: FileHandle?, logWriter: (any Writer)?) -> MultiWriter? {
        var writers: [any Writer] = []
        if let stdio {
            writers.append(stdio)
        }
        if let logWriter {
            writers.append(logWriter)
        }
        guard !writers.isEmpty else {
            return nil
        }
        return MultiWriter(writers: writers)
    }

    public init(
        root: URL,
        interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy],
        eventLoopGroup: any EventLoopGroup,
        connection: xpc_connection_t,
        log: Logger
    ) {
        self.root = root
        self.interfaceStrategies = interfaceStrategies
        self.log = log
        self.monitor = ExitMonitor(log: log)
        self.eventLoopGroup = eventLoopGroup
        self.connection = connection
    }

    /// Returns an endpoint from an anonymous xpc connection.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - endpoint: An XPC endpoint that can be used to communicate
    ///     with the runtime service.
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    /// Start the VM and the guest agent process for a container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        // Create the bundle if it doesn't exist yet
        if !self.bundleExists(at: self.root) {
            try self.createBundle()
        }

        return try await self.lock.withLock { [self] _ in
            guard await self.state == .created else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container expected to be in created state, got: \(await self.state)"
                )
            }

            let dynamicEnv = try message.dynamicEnv()
            let prewarming = message.bool(key: RuntimeKeys.prewarming.rawValue)

            let bundle = ContainerResource.Bundle(path: self.root)
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: self.root)
            var config = try bundle.configuration
            let loggingPlan = try ContainerLogRuntimePlan(configuration: config)
            let loggingCapture = try loggingPlan.activate(
                bundle: bundle,
                terminal: config.initProcess.terminal
            )
            var loggingCaptureNeedsClose = true
            defer {
                if loggingCaptureNeedsClose {
                    loggingCapture.close()
                }
            }

            var kernel = try bundle.kernel
            // Built-in defaults keyed by arg name. Each is applied only if the user did not already
            // supply the same key via --kernel-arg, letting custom kernels override them (e.g. lsm=...,bpf).
            let defaultKernelArgs: KeyValuePairs = [
                "oops": "panic",
                "lsm": "lockdown,capability,landlock,yama,apparmor",
            ]
            for (key, value) in defaultKernelArgs {
                guard !kernel.commandLine.kernelArgs.contains(where: { $0.hasPrefix("\(key)=") }) else {
                    continue
                }
                kernel.commandLine.kernelArgs.append("\(key)=\(value)")
            }
            let vmm = VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: bundle.initialFilesystem.asMount,
                rosetta: config.rosetta,
                group: self.eventLoopGroup,
                logger: self.log
            )

            let upstreamNameservers = config.dns?.nameservers ?? []
            try RuntimeDNSUpstream.validate(nameservers: upstreamNameservers)

            let networkConfigurations = Self.effectiveNetworkConfigurations(
                config: config
            )
            let networkBootstrapInfos = Self.effectiveNetworkBootstrapInfos(
                config: config,
                requested: try message.networkBootstrapInfos()
            )

            var bindings: [NetworkBinding] = []
            var attachments: [Attachment] = []
            var interfaces: [Interface] = []
            do {
                for (index, info) in networkBootstrapInfos.enumerated() {
                    let attachmentConfig = networkConfigurations[index]
                    let client = ContainerNetworkClient.NetworkClient(id: attachmentConfig.network, plugin: info.plugin)
                    let session = client.connect()
                    bindings.append(NetworkBinding(client: client, session: session))
                    var (attachment, additionalData) = try await client.allocate(
                        hostname: attachmentConfig.options.hostname,
                        aliases: attachmentConfig.options.aliases,
                        macAddress: attachmentConfig.options.macAddress,
                        requestedIPv4Address: attachmentConfig.options.requestedIPv4Address,
                        requestedIPv6Address: attachmentConfig.options.requestedIPv6Address,
                        retainOnDisconnect: true,
                        on: session
                    )
                    if let mtu = attachmentConfig.options.mtu {
                        attachment = Attachment(
                            network: attachment.network,
                            hostname: attachment.hostname,
                            aliases: attachment.aliases,
                            ipv4Address: attachment.ipv4Address,
                            ipv4Gateway: attachment.ipv4Gateway,
                            ipv6Address: attachment.ipv6Address,
                            ipv6Gateway: attachment.ipv6Gateway,
                            macAddress: attachment.macAddress,
                            mtu: mtu,
                            variant: attachment.variant
                        )
                    }
                    guard let iStrategy = self.interfaceStrategies[NetworkInterfaceKey(plugin: info.plugin, variant: attachment.variant)] else {
                        throw ContainerizationError(
                            .internalError,
                            message: "no available interface strategy for network \(attachment.network), plugin=\(info.plugin) variant=\(attachment.variant ?? "nil")")
                    }
                    let interface = try iStrategy.toInterface(
                        attachment: attachment,
                        interfaceIndex: index,
                        guestInterfaceName: attachmentConfig.options.guestInterfaceName,
                        additionalIPAddresses: attachmentConfig.options.additionalIPAddresses,
                        additionalData: additionalData
                    )
                    attachments.append(attachment)
                    interfaces.append(interface)
                }
            } catch {
                for binding in bindings { binding.session.close() }
                throw error
            }

            if let dns = config.dns {
                config.dns = ContainerConfiguration.DNSConfiguration(
                    nameservers: [DNSProxyProtocol.guestAddress],
                    domain: dns.domain,
                    searchDomains: dns.searchDomains,
                    options: dns.options
                )
            }

            let stdio = message.stdio()
            let stdin = Self.attachableInput(
                initial: stdio[0],
                prewarming: prewarming
            )
            let stdout = AttachableOutput(
                initial: stdio[1],
                persistent: loggingCapture.stdout
            )

            let stderr: AttachableOutput? =
                if !config.initProcess.terminal {
                    AttachableOutput(
                        initial: stdio[2],
                        persistent: loggingCapture.stderr
                    )
                } else {
                    nil
                }

            let id = config.id
            let rootfs = try bundle.containerRootfs.asMount
            let container = try LinuxContainer(id, rootfs: rootfs, vmm: vmm, logger: self.log) { czConfig in
                try Self.configureContainer(
                    czConfig: &czConfig,
                    config: config,
                    runtimeData: runtimeConfig.runtimeData,
                    dynamicEnv: dynamicEnv,
                    log: self.log
                )
                czConfig.interfaces = interfaces
                czConfig.process.stdout = stdout
                czConfig.process.stderr = stderr
                czConfig.process.stdin = stdin
                let hostsEntries = try Self.resolvedHosts(
                    hostname: czConfig.hostname ?? id,
                    primaryAddress: interfaces.first?.ipv4Address?.address.description,
                    gatewayAddress: interfaces.first?.ipv4Gateway?.description,
                    extraHosts: config.hosts
                )
                czConfig.hosts = Hosts(entries: hostsEntries)
                czConfig.bootLog = BootLog.file(path: bundle.bootlog, append: true)
            }

            let ctrInfo = ContainerInfo(
                container: container,
                config: config,
                attachments: attachments,
                bundle: bundle,
                io: ContainerStdio(input: stdin, stdout: stdout, stderr: stderr),
                logging: loggingCapture
            )
            await self.setContainer(ctrInfo)
            await self.setNetworkBindings(bindings)
            loggingCaptureNeedsClose = false

            do {
                try await container.create()
                if let memoryTargetInBytes = config.resources.memoryTargetInBytes {
                    try await container.setMemoryTarget(memoryTargetInBytes)
                }
                if config.dns != nil {
                    try await self.startDNSProxy(
                        container: container,
                        networkConfigurations: networkConfigurations,
                        upstreamNameservers: upstreamNameservers
                    )
                }

                try await self.initializeWaiters(for: id)
                try await self.monitor.registerProcess(id: config.id, onExit: self.onContainerExit)
                await self.setState(.booted)
            } catch {
                do {
                    try await self.cleanUpContainer(containerInfo: ctrInfo)
                    await self.setState(.stopped)
                } catch {
                    self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
                }
                throw error
            }
            return message.reply()
        }
    }

    /// Start the container workload inside the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let id = try message.id()
            let containerInfo = try await self.getContainer()
            let containerId = containerInfo.container.id
            if id == containerId {
                if !containerInfo.config.publishedPorts.isEmpty,
                    await self.socketForwarders.isEmpty,
                    Self.shouldStartSocketForwarders(
                        config: containerInfo.config,
                        hasInterfaces: !containerInfo.container.interfaces.isEmpty
                    )
                {
                    try await self.startSocketForwarders(
                        attachment: containerInfo.attachments[0],
                        publishedPorts: containerInfo.config.publishedPorts
                    )
                }
                try await self.startInitProcess(lock: lock)
                await self.setState(.running)
            } else {
                try await self.startExecProcess(processId: id, lock: lock)
            }
            return message.reply()
        }
    }

    /// Adds client-owned standard streams to the booted or running init process.
    /// The process itself keeps stable server-owned relays, so ending one
    /// client session does not close the process's standard input or output.
    @Sendable
    public func attach(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { [self] _ in
            let runtimeState = await self.state
            guard Self.acceptsAttach(in: runtimeState) else {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot attach: container is not booted, running, or paused"
                )
            }

            let stdio = message.stdio()
            let closeStdin = message.bool(
                key: RuntimeKeys.closeStdin.rawValue
            )
            guard stdio.contains(where: { $0 != nil }) || closeStdin else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "attach requires at least one standard stream"
                )
            }
            guard !closeStdin || stdio[0] == nil else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "attach cannot provide and close stdin together"
                )
            }

            let container = try await self.getContainer()
            if stdio[0] != nil, container.io.input == nil {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot attach stdin: container was not created with stdin open"
                )
            }
            if stdio[2] != nil, container.io.stderr == nil {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "cannot attach stderr: container has a terminal"
                )
            }

            if closeStdin {
                container.io.input?.close()
            } else if let stdin = stdio[0] {
                container.io.input?.add(stdin)
            }
            if let stdout = stdio[1] {
                container.io.stdout.add(stdout)
            }
            if let stderr = stdio[2] {
                container.io.stderr?.add(stderr)
            }
            return message.reply()
        }
    }

    static func attachableInput(
        initial: FileHandle?,
        prewarming: Bool
    ) -> AttachableInput? {
        if prewarming {
            return AttachableInput(initial: initial)
        }
        return initial.map(AttachableInput.init)
    }

    static func acceptsAttach(in state: State) -> Bool {
        state == .booted || state == .running || state == .paused
    }

    enum ShutdownDisposition: Equatable {
        case immediate
        case cleanBootedContainer
        case reject
    }

    private enum ContainerStopFailurePolicy {
        case logAndContinue
        case propagateAfterCleanup
    }

    static func shutdownDisposition(in state: State) -> ShutdownDisposition {
        switch state {
        case .created, .stopped, .shuttingDown:
            return .immediate
        case .booted, .stopping:
            return .cleanBootedContainer
        case .running, .paused:
            return .reject
        }
    }

    /// Opens a raw stream from the exact active logging generation.
    @Sendable
    public func followLogs(_ message: XPCMessage) async throws -> XPCMessage {
        try openLogStream(message, format: .raw)
    }

    /// Opens a newline-delimited structured stream from the exact active
    /// logging generation.
    @Sendable
    public func followLogRecords(_ message: XPCMessage) async throws -> XPCMessage {
        try openLogStream(message, format: .structuredRecords)
    }

    /// Opens a newline-delimited, lossless read-record stream from the exact
    /// active logging generation for authority-owned Engine presentation.
    @Sendable
    public func followLogReadRecordsV1(
        _ message: XPCMessage
    ) async throws -> XPCMessage {
        try openLogStream(message, format: .structuredReadRecordsV1)
    }

    private func openLogStream(
        _ message: XPCMessage,
        format: ContainerLogReaderStreamFormat
    ) throws -> XPCMessage {
        guard state == .running || state == .paused || state == .stopping else {
            throw ContainerizationError(
                .invalidState,
                message: "cannot follow logs: container is not running"
            )
        }
        let request = try message.logReadRequest()
        guard request.follow else {
            throw ContainerizationError(
                .invalidArgument,
                message: "active log stream requires follow=true"
            )
        }
        let container = try getContainer()
        let stream = try container.logging.makeStream(
            request: request,
            format: format
        )
        let reply = message.reply()
        reply.set(key: RuntimeKeys.fd.rawValue, value: stream)
        return reply
    }

    /// Get statistics for the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - statistics: JSON serialization of the `ContainerStats`.
    @Sendable
    public func statistics(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let containerInfo = try await self.getContainer()
            let stats = try await containerInfo.container.statistics()

            let containerStats = ContainerStats(
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

            let reply = message.reply()
            let data = try JSONEncoder().encode(containerStats)
            reply.set(key: RuntimeKeys.statistics.rawValue, value: data)
            return reply
        }
    }

    /// Get process information for the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - processes: JSON serialization of the `ContainerProcesses`.
    @Sendable
    public func processes(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            let containerInfo = try await self.getContainer()
            let processIdentifiers = try await containerInfo.container.processIdentifiers()
            let processInfo = try await containerInfo.container.processes()
            let processes = ContainerProcesses(
                id: containerInfo.container.id,
                processIdentifiers: processIdentifiers,
                processes: processInfo.map { process in
                    ContainerResource.ContainerProcessInfo(
                        uid: process.uid,
                        pid: process.pid,
                        ppid: process.ppid,
                        cpu: process.cpu,
                        startTime: process.startTime,
                        tty: process.tty,
                        time: process.time,
                        command: process.command
                    )
                }
            )

            let reply = message.reply()
            let data = try JSONEncoder().encode(processes)
            reply.set(key: RuntimeKeys.processes.rawValue, value: data)
            return reply
        }
    }

    /// Shutdown the RuntimeService.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { [self] _ in
            switch Self.shutdownDisposition(in: await self.state) {
            case .immediate:
                await self.setState(.shuttingDown)
            case .cleanBootedContainer:
                let containerInfo = try await self.getContainer()
                try await self.cleanUpContainer(
                    containerInfo: containerInfo,
                    stopFailurePolicy: .propagateAfterCleanup
                )
                await self.setState(.shuttingDown)
            case .reject:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot shutdown: container is not stopped"
                )
            }

            return message.reply()
        }
    }

    /// Create a process inside the virtual machine for the container.
    ///
    /// Use this procedure to run ad hoc processes in the virtual
    /// machine (`container exec`).
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - processConfig: JSON serialization of the `ProcessConfiguration`
    ///       containing the process attributes.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running, .booted:
                let id = try message.id()
                let config = try message.processConfig()
                let stdio = message.stdio()

                try await self.addNewProcess(id, config, stdio)

                try await self.initializeWaiters(for: id)
                do {
                    try await self.monitor.registerProcess(
                        id: id,
                        onExit: { id, exitStatus in
                            await self.releaseWaiters(for: id, status: exitStatus)

                            guard let process = await self.processes[id]?.process else {
                                throw ContainerizationError(
                                    .invalidState,
                                    message: "ProcessInfo missing for process \(id)"
                                )
                            }
                            try await process.delete()
                            try await self.setProcessState(id: id, state: .stopped)
                        }
                    )
                } catch {
                    await self.releaseWaiters(for: id, status: ExitStatus(exitCode: -1))
                    throw error
                }

                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot exec: container is not running"
                )
            }
        }
    }

    /// Return the state for the sandbox and its containers.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - snapshot: The JSON serialization of the `SandboxSnapshot`
    ///     that contains the state information.
    @Sendable
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        var status: RuntimeStatus = .unknown
        var networks: [Attachment] = []
        var cs: ContainerSnapshot?

        switch state {
        case .created, .stopped, .booted, .shuttingDown:
            status = .stopped
        case .stopping:
            status = .stopping
        case .paused:
            let ctr = try getContainer()

            status = .paused
            networks = ctr.attachments
            cs = ContainerSnapshot(
                configuration: ctr.config,
                status: RuntimeStatus.paused,
                networks: networks
            )
        case .running:
            let ctr = try getContainer()

            status = .running
            networks = ctr.attachments
            cs = ContainerSnapshot(
                configuration: ctr.config,
                status: RuntimeStatus.running,
                networks: networks
            )
        }

        let reply = message.reply()
        try reply.setState(
            .init(
                status: status,
                networks: networks,
                containers: cs != nil ? [cs!] : []
            )
        )
        return reply
    }

    /// Stop the container workload, any ad hoc processes, and the underlying
    /// virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - stopOptions: JSON serialization of `ContainerStopOptions`
    ///       that modify stop behavior.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let stopOptions = try message.stopOptions()
        let signal = try Signal(stopOptions.signal ?? "SIGTERM")
        let timeout: Duration = .seconds(stopOptions.timeoutInSeconds ?? 5)

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .running, .booted:
                await self.setState(.stopping)

                let ctr = try await self.getContainer()
                let exitStatus = try await self.gracefulStopContainer(
                    ctr.container,
                    signal: signal,
                    timeout: timeout
                )

                do {
                    if case .stopped = await self.state {
                        return message.reply()
                    }
                    try await self.cleanUpContainer(containerInfo: ctr, exitStatus: exitStatus)
                } catch {
                    self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
                }
                await self.setState(.stopped)
            case .paused:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot stop: container is paused; resume before stopping"
                )
            default:
                break
            }
            return message.reply()
        }
    }

    /// Pause the container workload without terminating its processes.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func pause(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        try await self.lock.withLock { _ in
            switch await self.state {
            case .running:
                let ctr = try await self.getContainer()
                try await ctr.container.pause()
                await self.setState(.paused)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot pause: container is not running"
                )
            }
        }

        return message.reply()
    }

    /// Resume a paused container workload.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func resume(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        try await self.lock.withLock { _ in
            switch await self.state {
            case .paused:
                let ctr = try await self.getContainer()
                try await ctr.container.resume()
                await self.setState(.running)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot resume: container is not paused"
                )
            }
        }

        return message.reply()
    }

    /// Request a live workload-memory target without restarting the sandbox.
    @Sendable
    public func setMemoryTarget(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let memoryInBytes = message.uint64(key: RuntimeKeys.memoryTargetInBytes.rawValue)
        guard memoryInBytes > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "memory target must be positive"
            )
        }

        try await self.lock.withLock { _ in
            switch await self.state {
            case .booted, .running, .paused:
                let ctr = try await self.getContainer()
                try await ctr.container.setMemoryTarget(memoryInBytes)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot set memory target: container is not booted, running, or paused"
                )
            }
        }

        return message.reply()
    }

    /// Signal a process running in the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - signal: The signal value.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let id = try message.id()
        let signal = try Signal(message.signal())

        try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running:
                let ctr = try await getContainer()
                if id != ctr.container.id {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "process \(id) not started")
                    }
                    try await proc.kill(signal)
                    return
                }

                try await ctr.container.kill(signal)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot kill: container is not running"
                )
            }
        }

        // SIGKILL is guaranteed by the kernel to terminate the target, so block
        // until we observe the exit.
        if signal == .kill {
            _ = await withCheckedContinuation { cc in
                self.waitForExit(id: id, cont: cc)
            }
        }

        return message.reply()
    }

    /// Resize the terminal for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - width: The terminal width.
    ///     - height: The terminal height.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.trace("enter", metadata: ["func": "\(#function)"])
        defer { self.log.trace("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running:
            let id = try message.id()
            let ctr = try getContainer()
            let width = message.uint64(key: RuntimeKeys.width.rawValue)
            let height = message.uint64(key: RuntimeKeys.height.rawValue)

            if id != ctr.container.id {
                guard let processInfo = self.processes[id] else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) does not exist"
                    )
                }

                guard let proc = processInfo.process else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) not started"
                    )
                }

                try await proc.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
            } else {
                try await ctr.container.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot resize: container is not running"
            )
        }
    }

    /// Wait for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - exitCode: The exit code for the process.
    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let id = message.string(key: RuntimeKeys.id.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing id in wait xpc message")
        }

        let exitStatus = await withCheckedContinuation { cc in
            self.waitForExit(id: id, cont: cc)
        }
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(exitStatus.exitCode))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: exitStatus.exitedAt)
        return reply
    }

    /// Copy a file or directory from the host into the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The host path to copy from.
    ///     - destinationPath: The container path to copy to.
    ///     - fileMode: The file permissions mode (UInt64).
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyIn` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for copyIn"
                )
            }
            let mode = UInt32(message.uint64(key: RuntimeKeys.fileMode.rawValue))
            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)
            let followSymlink = message.bool(key: RuntimeKeys.followSymlink.rawValue)
            let preserveOwnership = message.bool(key: RuntimeKeys.preserveOwnership.rawValue)

            let ctr = try getContainer()
            if let archive = message.fileHandle(key: RuntimeKeys.copyArchive.rawValue) {
                try await ctr.container.copyIn(
                    archive: archive,
                    to: URL(fileURLWithPath: destination),
                    createParents: createParents,
                    preserveOwnership: preserveOwnership
                )
            } else {
                guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "no source path supplied for copyIn"
                    )
                }
                try await ctr.container.copyIn(
                    from: URL(fileURLWithPath: source),
                    to: URL(fileURLWithPath: destination),
                    mode: mode,
                    createParents: createParents,
                    followSymlink: followSymlink,
                    preserveOwnership: preserveOwnership
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyIn: container is not running"
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The container path to copy from.
    ///     - destinationPath: The host path to copy to.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyOut` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no source path supplied for copyOut"
                )
            }
            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)
            let followSymlink = message.bool(key: RuntimeKeys.followSymlink.rawValue)
            let preserveOwnership = message.bool(key: RuntimeKeys.preserveOwnership.rawValue)
            let copyContents = message.bool(key: RuntimeKeys.copyContents.rawValue)

            let ctr = try getContainer()
            if let archive = message.fileHandle(key: RuntimeKeys.copyArchive.rawValue) {
                try await ctr.container.copyOut(
                    from: URL(fileURLWithPath: source),
                    to: archive,
                    followSymlink: followSymlink,
                    copyContents: copyContents
                )
            } else {
                guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "no destination path supplied for copyOut"
                    )
                }
                try await ctr.container.copyOut(
                    from: URL(fileURLWithPath: source),
                    to: URL(fileURLWithPath: destination),
                    createParents: createParents,
                    followSymlink: followSymlink,
                    preserveOwnership: preserveOwnership
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyOut: container is not running"
            )
        }
    }

    /// Snapshot the container's root filesystem.
    ///
    /// Running containers are frozen while their backing image is copied.
    /// `noFreeze` instead makes an APFS copy-on-write clone while the guest
    /// remains writable; this is deliberately best-effort, is not guaranteed
    /// to produce a filesystem-consistent image, and is used only for
    /// Docker-compatible `commit --pause=false` behavior.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - imagePath: The path to the source filesystem image.
    ///     - destinationPath: The path where the snapshot will be written.
    ///     - noFreeze: Whether to avoid freezing the guest filesystem.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func snapshotDisk(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`snapshotDisk` xpc handler")
        return try await self.lock.withLock { _ in
            let state = await self.state
            switch state {
            case .running, .booted:
                guard let imagePath = message.string(key: RuntimeKeys.imagePath.rawValue) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "no image path supplied for snapshotDisk"
                    )
                }
                guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "no destination path supplied for snapshotDisk"
                    )
                }

                if message.bool(key: RuntimeKeys.noFreeze.rawValue) {
                    try DiskSnapshot.clone(from: imagePath, to: destinationPath)
                    return message.reply()
                }

                let ctr = try await self.getContainer()
                let shouldFreeze = state == .running

                if shouldFreeze {
                    try await ctr.container.filesystemOperation(operation: .freeze, path: "/")
                }

                do {
                    try FileManager.default.copyItem(atPath: imagePath, toPath: destinationPath)
                } catch {
                    if shouldFreeze {
                        do {
                            try await ctr.container.filesystemOperation(operation: .thaw, path: "/")
                        } catch {
                            self.log.error(
                                "failed to thaw filesystem after snapshotDisk error",
                                metadata: [
                                    "error": "\(error)"
                                ])
                        }
                    }
                    throw error
                }

                if shouldFreeze {
                    try await ctr.container.filesystemOperation(operation: .thaw, path: "/")
                }

                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot snapshot disk: container is not running"
                )
            }
        }
    }

    /// Clean up unused space in the container filesystem.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The container ID.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func clean(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`clean` xpc handler")
        switch self.state {
        case .running:
            guard let id = message.string(key: RuntimeKeys.id.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no id supplied for clean"
                )
            }

            let ctr = try getContainer()

            var targets: [String] = []
            if !ctr.config.readOnly {
                targets.append("/")
            }
            for mount in ctr.config.mounts where mount.isBlock && !mount.options.readonly {
                targets.append(mount.destination)
            }

            var failed: [String] = []
            for path in targets {
                do {
                    try await ctr.container.filesystemOperation(operation: .trim, path: path)
                } catch {
                    self.log.error("failed to clean mount", metadata: ["path": "\(path)", "error": "\(error)"])
                    failed.append("\(path) (\(error))")
                }
            }

            guard failed.isEmpty else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to clean mounts in \(id): \(failed.joined(separator: ", "))"
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot clean: container is not running"
            )
        }
    }

    /// Dial a vsock port on the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - port: The port number.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - fd: The file descriptor for the vsock.
    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running, .booted:
            let port = message.uint64(key: RuntimeKeys.port.rawValue)
            guard port > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock port supplied for dial"
                )
            }

            let ctr = try getContainer()
            let fh = try await ctr.container.dialVsock(port: UInt32(port))

            let reply = message.reply()
            reply.set(key: RuntimeKeys.fd.rawValue, value: fh)
            return reply
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot dial: container is not running"
            )
        }
    }

    private func startInitProcess(lock: AsyncLock.Context) async throws {
        let info = try self.getContainer()
        let container = info.container
        let id = container.id

        guard self.state == .booted else {
            throw ContainerizationError(
                .invalidState,
                message: "container expected to be in booted state, got: \(self.state)"
            )
        }

        do {
            let io = info.io

            try await container.start()
            let waitFunc: ExitMonitor.WaitHandler = {
                let code = try await container.wait()
                try io.close()
                return code
            }
            try await self.monitor.track(id: id, waitingOn: waitFunc)
        } catch {
            try? await self.cleanUpContainer(containerInfo: info)
            self.setState(.stopped)
            throw error
        }
    }

    private func startExecProcess(processId id: String, lock: AsyncLock.Context) async throws {
        let container = try self.getContainer().container
        guard let processInfo = self.processes[id] else {
            throw ContainerizationError(.notFound, message: "process with id \(id)")
        }

        let containerInfo = try self.getContainer()
        let czConfig = try self.configureProcessConfig(
            config: processInfo.config,
            stdio: processInfo.io,
            containerConfig: containerInfo.config,
        )

        let process = try await container.exec(id, configuration: czConfig)
        try self.setUnderlyingProcess(id, process)

        try await process.start()

        let waitFunc: ExitMonitor.WaitHandler = {
            let code = try await process.wait()
            if let out = processInfo.io[1] {
                try self.closeHandle(out.fileDescriptor)
            }
            if let err = processInfo.io[2] {
                try self.closeHandle(err.fileDescriptor)
            }
            return code
        }
        try await self.monitor.track(id: id, waitingOn: waitFunc)
    }

    private func startSocketForwarders(attachment: Attachment, publishedPorts: [PublishPort]) async throws {
        guard !publishedPorts.isEmpty else {
            return
        }
        LocalNetworkPrivacy.triggerLocalNetworkPrivacyAlert()

        let startedForwarders = StartedSocketForwarders()
        guard !publishedPorts.hasOverlaps() else {
            throw ContainerizationError(.invalidArgument, message: "host ports for different publish port specs may not overlap")
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for publishedPort in publishedPorts {
                    for index in 0..<publishedPort.count {
                        let hostPort = publishedPort.hostPort + index
                        let hostBinding = try HostPortBinding.resolve(hostAddress: publishedPort.hostAddress, hostPort: hostPort)
                        let proxyAddress = hostBinding.proxyAddress
                        let containerIPAddress: String
                        switch publishedPort.hostAddress {
                        case .v4(_):
                            guard let ipv4Address = attachment.ipv4Address else {
                                throw ContainerizationError(
                                    .invalidArgument,
                                    message: "IPv4 published port requires an IPv4 network attachment"
                                )
                            }
                            containerIPAddress = ipv4Address.address.description
                        case .v6(_):
                            guard let ipv6Address = attachment.ipv6Address else {
                                throw ContainerizationError(.invalidState, message: "cannot configure IPv6 port forwarding for container with unknown IPv6 address")
                            }
                            containerIPAddress = ipv6Address.address.description
                        }
                        let serverAddress = try SocketAddress(ipAddress: containerIPAddress, port: Int(publishedPort.containerPort + index))
                        log.info(
                            "creating forwarder for",
                            metadata: [
                                "proxy": "\(proxyAddress)",
                                "server": "\(serverAddress)",
                                "protocol": "\(publishedPort.proto)",
                            ])
                        group.addTask {
                            let forwarder: SocketForwarder
                            switch publishedPort.proto {
                            case .tcp:
                                forwarder = try TCPForwarder(
                                    proxyAddress: proxyAddress,
                                    serverAddress: serverAddress,
                                    eventLoopGroup: self.eventLoopGroup,
                                    boundInterface: hostBinding.boundInterface,
                                    log: self.log
                                )
                            case .udp:
                                forwarder = try UDPForwarder(
                                    proxyAddress: proxyAddress,
                                    serverAddress: serverAddress,
                                    eventLoopGroup: self.eventLoopGroup,
                                    boundInterface: hostBinding.boundInterface,
                                    log: self.log
                                )
                            }
                            do {
                                let result = try await forwarder.run().get()
                                startedForwarders.append(result)
                            } catch let error as IOError where error.errnoCode == EACCES {
                                if let port = proxyAddress.port, port < 1024 {
                                    throw ContainerizationError(
                                        .invalidArgument,
                                        message: "Permission denied while binding to host port \(port). Binding to ports below 1024 requires root privileges."
                                    )
                                }
                                throw error
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            // A throwing task group does not guarantee that successful child
            // results are consumed before another child fails. Record each
            // bound listener at the point it starts so every partial success
            // can be closed before the init-start error reaches the API.
            for forwarder in startedForwarders.snapshot() {
                forwarder.close()
                try? await forwarder.wait()
            }
            throw error
        }

        self.socketForwarders = startedForwarders.snapshot()
    }

    private func startDNSProxy(
        container: LinuxContainer,
        networkConfigurations: [AttachmentConfiguration],
        upstreamNameservers: [String]
    ) async throws {
        guard networkBindings.count == networkConfigurations.count else {
            throw ContainerizationError(
                .invalidState,
                message: "network binding count does not match the configured attachments"
            )
        }

        var scopedAliases: [String: RuntimeDNSResolver.ScopedAlias] = [:]
        var lookups: [RuntimeDNSResolver.NetworkLookup] = []
        for (binding, configuration) in zip(networkBindings, networkConfigurations) {
            let lookup: RuntimeDNSResolver.NetworkLookup = { hostname in
                let attachments = try await binding.client.lookupAll(
                    hostname: hostname,
                    on: binding.session
                )
                return attachments.map { attachment in
                    RuntimeDNSAddress(
                        ipv4: attachment.ipv4Address?.address,
                        ipv6: attachment.ipv6Address?.address
                    )
                }
            }
            lookups.append(lookup)

            for (alias, target) in configuration.options.scopedDNSAliases {
                let canonicalAlias = RuntimeDNSResolver.canonicalHostname(alias)
                let canonicalTarget = RuntimeDNSResolver.canonicalHostname(target)
                guard !canonicalAlias.isEmpty, !canonicalTarget.isEmpty else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "network scoped DNS aliases require non-empty alias and target hostnames"
                    )
                }
                if let existing = scopedAliases[canonicalAlias] {
                    guard RuntimeDNSResolver.canonicalHostname(existing.target) == canonicalTarget else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "network scoped DNS alias '\(alias)' maps to multiple target hostnames"
                        )
                    }
                    scopedAliases[canonicalAlias] = RuntimeDNSResolver.ScopedAlias(
                        target: existing.target,
                        lookups: existing.lookups + [lookup]
                    )
                    continue
                }
                scopedAliases[canonicalAlias] = RuntimeDNSResolver.ScopedAlias(
                    target: target,
                    lookup: lookup
                )
            }
        }
        let resolver = RuntimeDNSResolver(
            scopedAliases: scopedAliases,
            networkLookups: lookups,
            upstreamNameservers: upstreamNameservers,
            log: log
        )
        let listener = try await container.withVirtualMachineInstance { vm in
            try vm.listen(DNSProxyProtocol.hostVsockPort)
        }
        let proxy = RuntimeDNSProxy(
            listener: listener,
            resolver: resolver,
            eventLoopGroup: eventLoopGroup,
            log: log
        )
        dnsProxy = proxy
        dnsProxyTask = Task {
            await proxy.run()
        }
    }

    private func stopDNSProxy() async {
        dnsProxy?.stop()
        dnsProxyTask?.cancel()
        await dnsProxyTask?.value
        dnsProxyTask = nil
        dnsProxy = nil
    }

    private func stopSocketForwarders() async {
        log.info("closing forwarders")
        for forwarder in self.socketForwarders {
            forwarder.close()
            try? await forwarder.wait()
        }
        log.info("closed forwarders")
    }

    private func onContainerExit(id: String, exitStatus: ExitStatus) async throws {
        self.log.info("init process exited", metadata: ["status": "\(exitStatus)"])

        try await self.lock.withLock { [self] _ in
            let ctrInfo = try await getContainer()

            switch await self.state {
            case .stopped, .stopping:
                return
            default:
                break
            }

            do {
                try await cleanUpContainer(containerInfo: ctrInfo, exitStatus: exitStatus)
            } catch {
                self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
            }
            await setState(.stopped)
        }
    }

    static func shouldStartSocketForwarders(config: ContainerConfiguration, hasInterfaces: Bool) -> Bool {
        hasInterfaces && !config.hostNetwork
    }

    /// Host-mode workloads join the sandbox VM's existing network namespace.
    /// They must not allocate or configure a private attachment, even if an
    /// older API service supplied the compatibility default-network request.
    static func effectiveNetworkBootstrapInfos(
        config: ContainerConfiguration,
        requested: [NetworkBootstrapInfo]
    ) -> [NetworkBootstrapInfo] {
        config.hostNetwork ? [] : requested
    }

    /// Host-mode workloads join the sandbox VM's existing network namespace.
    /// Compatibility attachments must therefore be suppressed consistently for
    /// allocation and DNS proxy startup, not only for the runtime bootstrap
    /// request.
    static func effectiveNetworkConfigurations(
        config: ContainerConfiguration
    ) -> [AttachmentConfiguration] {
        config.hostNetwork ? [] : config.networks
    }

    struct LinuxDeviceMetadata: Sendable {
        let type: String
        let major: Int64
        let minor: Int64
        let fileMode: UInt32
        let uid: UInt32
        let gid: UInt32
    }

    struct LinuxGPUResolution: Sendable {
        let enabled: Bool
        let guestDevices: [LinuxGuestDeviceRequest]
    }

    static let knownLinuxDevices: [String: LinuxDeviceMetadata] = [
        "/dev/null": LinuxDeviceMetadata(type: "c", major: 1, minor: 3, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/zero": LinuxDeviceMetadata(type: "c", major: 1, minor: 5, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/full": LinuxDeviceMetadata(type: "c", major: 1, minor: 7, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/random": LinuxDeviceMetadata(type: "c", major: 1, minor: 8, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/urandom": LinuxDeviceMetadata(type: "c", major: 1, minor: 9, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/tty": LinuxDeviceMetadata(type: "c", major: 5, minor: 0, fileMode: 0o666, uid: 0, gid: 0),
        "/dev/console": LinuxDeviceMetadata(type: "c", major: 5, minor: 1, fileMode: 0o600, uid: 0, gid: 0),
        "/dev/ptmx": LinuxDeviceMetadata(type: "c", major: 5, minor: 2, fileMode: 0o666, uid: 0, gid: 0),
    ]

    static func resolveDeviceMappings(_ mappings: [LinuxDeviceMapping]) throws -> (
        devices: [ContainerizationOCI.LinuxDevice],
        cgroupRules: [ContainerizationOCI.LinuxDeviceCgroup]
    ) {
        var devices: [ContainerizationOCI.LinuxDevice] = []
        var cgroupRules: [ContainerizationOCI.LinuxDeviceCgroup] = []
        devices.reserveCapacity(mappings.count)
        cgroupRules.reserveCapacity(mappings.count)

        for mapping in mappings {
            let metadata = try resolveLinuxDevice(source: mapping.source)

            devices.append(
                ContainerizationOCI.LinuxDevice(
                    path: mapping.target,
                    type: metadata.type,
                    major: metadata.major,
                    minor: metadata.minor,
                    fileMode: metadata.fileMode,
                    uid: metadata.uid,
                    gid: metadata.gid
                ))
            cgroupRules.append(
                ContainerizationOCI.LinuxDeviceCgroup(
                    allow: true,
                    type: metadata.type,
                    major: metadata.major,
                    minor: metadata.minor,
                    access: mapping.permissions
                ))
        }

        return (devices, cgroupRules)
    }

    static func resolveLinuxDevice(source: String) throws -> LinuxDeviceMetadata {
        if let metadata = knownLinuxDevices[source] {
            return metadata
        }
        let supportedDevices = knownLinuxDevices.keys.sorted().joined(separator: ", ")
        throw ContainerizationError(
            .unsupported,
            message: "device source '\(source)' cannot be resolved by the current runtime; supported VM device paths are: \(supportedDevices)"
        )
    }

    static func resolveGPURequests(_ requests: [LinuxGPURequest]) throws -> LinuxGPUResolution {
        guard !requests.isEmpty else {
            return LinuxGPUResolution(enabled: false, guestDevices: [])
        }
        guard requests.count == 1 else {
            throw ContainerizationError(.unsupported, message: "the Apple virtio-gpu backend exposes one GPU request")
        }

        let request = requests[0]
        guard request.driver.isEmpty || request.driver == "virtio" else {
            throw ContainerizationError(
                .unsupported,
                message: "GPU driver '\(request.driver)' is not supported; the Apple backend supports only virtio-gpu"
            )
        }
        guard request.options.isEmpty else {
            throw ContainerizationError(.unsupported, message: "GPU driver options are not supported by the Apple virtio-gpu backend")
        }
        guard request.capabilities.allSatisfy({ $0 == "gpu" }) else {
            throw ContainerizationError(
                .unsupported,
                message: "GPU capabilities other than 'gpu' are not supported by the Apple virtio-gpu backend"
            )
        }

        if request.deviceIDs.isEmpty {
            guard request.count == -1 || request.count == 1 else {
                throw ContainerizationError(.unsupported, message: "the Apple virtio-gpu backend exposes exactly one GPU")
            }
        } else {
            guard request.count == 0, request.deviceIDs == ["0"] else {
                throw ContainerizationError(.unsupported, message: "the Apple virtio-gpu backend supports only GPU device ID '0'")
            }
        }

        let guestDevices = [
            LinuxGuestDeviceRequest(path: "/dev/dri/card0", required: false),
            // A virtio modalias alone is not a usable GPU surface. The render
            // node is required so a requested GPU cannot silently run without
            // a DRM endpoint that a container process can open.
            LinuxGuestDeviceRequest(path: "/dev/dri/renderD128"),
        ]
        return LinuxGPUResolution(enabled: true, guestDevices: guestDevices)
    }

    static func configureContainer(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration,
        runtimeData: Data? = nil,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil,
    ) throws {
        czConfig.cpus = config.resources.cpus
        czConfig.cpuQuotaInMicroseconds = config.resources.cpuQuotaInMicroseconds
        czConfig.cpuPeriodInMicroseconds = config.resources.cpuPeriodInMicroseconds
        czConfig.cpuSet = config.resources.cpuSet
        czConfig.cpuOverhead = config.resources.cpuOverhead
        czConfig.memoryInBytes = config.resources.memoryInBytes
        if let runtimeData {
            let linuxData = try JSONDecoder().decode(LinuxRuntimeData.self, from: runtimeData)
            let deviceMapping = try resolveDeviceMappings(linuxData.devices)
            let gpu = try resolveGPURequests(linuxData.gpuRequests)
            czConfig.blockIO = linuxData.blockIO.map(Self.toContainerizationBlockIO)
            czConfig.pidsLimit = linuxData.pidsLimit
            czConfig.memoryReservationInBytes = linuxData.memoryReservationInBytes
            czConfig.memorySwapLimitInBytes = linuxData.memorySwapLimitInBytes
            czConfig.cpuShares = linuxData.cpuShares
            czConfig.cgroupParent = linuxData.cgroupParent
            czConfig.devices.append(contentsOf: deviceMapping.devices)
            czConfig.guestDevices.append(contentsOf: gpu.guestDevices)
            czConfig.deviceCgroupRules.append(contentsOf: linuxData.deviceCgroupRules + deviceMapping.cgroupRules)
            czConfig.graphics = gpu.enabled ? .virtioDevice : .disabled
        }
        // Overcommit memory and allow more memory mappings than the kernel default
        // so workloads inside swap-less guest VMs hit limits less easily.
        var sysctls = try Self.resolvedSysctls(config: config)
        sysctls["vm.overcommit_memory"] = "1"
        sysctls["vm.max_map_count"] = "262144"
        czConfig.sysctl = sysctls
        czConfig.annotations = config.annotations
        // If the host doesn't support this, we'll throw on container creation.
        czConfig.virtualization = config.virtualization
        czConfig.useInit = config.useInit
        czConfig.hostPIDNamespace = config.hostPIDNamespace
        czConfig.hostCgroupNamespace = config.hostCgroupNamespace
        czConfig.hostIPCNamespace = config.hostIPCNamespace
        czConfig.hostUTSNamespace = config.hostUTSNamespace
        czConfig.privateUserNamespace = config.privateUserNamespace

        // nil leaves LinuxContainer's own default set in place.
        if let maskedPaths = config.maskedPaths {
            czConfig.maskedPaths = maskedPaths
        }
        if let readonlyPaths = config.readonlyPaths {
            czConfig.readonlyPaths = readonlyPaths
        }

        if let shmSize = config.shmSize {
            for i in czConfig.mounts.indices {
                if czConfig.mounts[i].destination == "/dev/shm" {
                    czConfig.mounts[i].options.removeAll { $0.hasPrefix("size=") }
                    czConfig.mounts[i].options.append("size=\(shmSize)")
                }
            }
        }

        for mount in config.mounts {
            if try mount.isSocket() {
                let attrs = try? FileManager.default.attributesOfItem(atPath: mount.source)
                let permissions = (attrs?[.posixPermissions] as? NSNumber)
                    .map { FilePermissions(rawValue: mode_t($0.intValue)) }
                let socket = UnixSocketConfiguration(
                    source: URL(filePath: mount.source),
                    destination: URL(filePath: mount.destination),
                    permissions: permissions,
                    direction: .into,
                )
                czConfig.sockets.append(socket)
            } else {
                czConfig.mounts.append(mount.asMount)
            }
        }

        for inboundSocket in config.inboundSockets {
            czConfig.sockets.append(
                try EngineSocketGrantResolver.resolve(
                    inboundSocket,
                    containerID: config.id
                )
            )
        }

        for publishedSocket in config.publishedSockets {
            // UnixSocketConfiguration (Containerization) takes URL; convert from FilePath at the boundary.
            let socketConfig = UnixSocketConfiguration(
                source: URL(filePath: publishedSocket.containerPath.string),
                destination: URL(filePath: publishedSocket.hostPath.string),
                permissions: publishedSocket.permissions,
                direction: .outOf
            )
            czConfig.sockets.append(socketConfig)
        }

        if let socketUrl = Self.sshAuthSocketHostUrl(config: config, dynamicEnv: dynamicEnv, log: log) {
            let socketPath = socketUrl.path(percentEncoded: false)
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
            let permissions = (attrs?[.posixPermissions] as? NSNumber)
                .map { FilePermissions(rawValue: mode_t($0.intValue)) }
            let socketConfig = UnixSocketConfiguration(
                source: socketUrl,
                destination: URL(fileURLWithPath: Self.sshAuthSocketGuestPath),
                permissions: permissions,
                direction: .into,
            )
            czConfig.sockets.append(socketConfig)
        }

        czConfig.hostname = Self.resolvedHostname(config: config)

        if let dns = config.dns {
            czConfig.dns = DNS(
                nameservers: dns.nameservers, domain: dns.domain,
                searchDomains: dns.searchDomains, options: dns.options)
        }

        try Self.configureInitialProcess(czConfig: &czConfig, config: config)
    }

    static func configureInitialProcess(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration,
    ) throws {
        let process = config.initProcess

        czConfig.process.arguments = [process.executable] + process.arguments
        czConfig.process.environmentVariables = process.environment

        if config.ssh {
            if !czConfig.process.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                czConfig.process.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        czConfig.process.terminal = process.terminal
        czConfig.process.workingDirectory = process.workingDirectory
        czConfig.process.oomScoreAdj = process.oomScoreAdj
        czConfig.process.noNewPrivileges = process.noNewPrivileges
        try czConfig.process.rlimits = process.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        if process.privileged {
            // LinuxContainer applies OCI's restricted paths by default. A
            // privileged container retains the sandbox boundary, but restores
            // the Linux guest privilege surface that the runtime can expose.
            czConfig.process.capabilities = .allCapabilities
        } else {
            czConfig.process.capabilities = try Self.effectiveCapabilities(
                capAdd: config.capAdd,
                capDrop: config.capDrop
            )
        }
        if process.privileged || config.unconfinedSystemPaths {
            czConfig.maskedPaths = []
            czConfig.readonlyPaths = []
        }
        switch process.user {
        case .raw(let name):
            czConfig.process.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: process.supplementalGroups,
                additionalGroupNames: process.supplementalGroupNames,
                username: name
            )
        case .id(let uid, let gid):
            czConfig.process.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: process.supplementalGroups,
                additionalGroupNames: process.supplementalGroupNames,
                username: ""
            )
        }
    }

    private nonisolated func configureProcessConfig(config: ProcessConfiguration, stdio: [FileHandle?], containerConfig: ContainerConfiguration)
        throws -> LinuxProcessConfiguration
    {
        var proc = LinuxProcessConfiguration()
        proc.stdin = stdio[0]
        proc.stdout = stdio[1]
        proc.stderr = stdio[2]

        proc.arguments = [config.executable] + config.arguments
        proc.environmentVariables = config.environment

        if containerConfig.ssh {
            if !proc.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                proc.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        proc.terminal = config.terminal
        proc.workingDirectory = config.workingDirectory
        proc.oomScoreAdj = config.oomScoreAdj
        try proc.rlimits = config.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        proc.capabilities = try Self.execCapabilities(containerConfig: containerConfig, processConfig: config)
        switch config.user {
        case .raw(let name):
            proc.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: config.supplementalGroups,
                additionalGroupNames: config.supplementalGroupNames,
                username: name
            )
        case .id(let uid, let gid):
            proc.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: config.supplementalGroups,
                additionalGroupNames: config.supplementalGroupNames,
                username: ""
            )
        }

        return proc
    }

    /// Compute effective Linux capabilities from the OCI default set, capAdd, and capDrop.
    /// Steps are processed in order, so later steps override earlier ones:
    /// 1. If "ALL" in capDrop, start empty; otherwise start from OCI defaults.
    /// 2. If "ALL" in capAdd, replace with all caps (overriding step 1); otherwise add individual caps.
    /// 3. Remove individual capDrop entries (skipping "ALL" sentinel).
    static func effectiveCapabilities(capAdd: [String], capDrop: [String]) throws -> Containerization.LinuxCapabilities {
        // Step 1: Determine base set
        var caps: Set<CapabilityName>
        if capDrop.contains("ALL") {
            caps = []
        } else {
            caps = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.effective)
        }

        // Step 2: Process adds
        if capAdd.contains("ALL") {
            caps = Set(CapabilityName.allCases)
        } else {
            for name in capAdd {
                caps.insert(try CapabilityName(rawValue: name))
            }
        }

        // Step 3: Remove individual drops (skip "ALL" sentinel)
        for name in capDrop where name != "ALL" {
            caps.remove(try CapabilityName(rawValue: name))
        }

        return Containerization.LinuxCapabilities(capabilities: Array(caps))
    }

    static func execCapabilities(
        containerConfig: ContainerConfiguration,
        processConfig: ProcessConfiguration
    ) throws -> Containerization.LinuxCapabilities {
        if processConfig.privileged {
            return .allCapabilities
        }
        return try effectiveCapabilities(capAdd: containerConfig.capAdd, capDrop: containerConfig.capDrop)
    }

    /// Converts the OCI block I/O wire model carried in runtime data into the
    /// containerization API wrapper used by `LinuxContainer.Configuration`.
    static func toContainerizationBlockIO(_ oci: ContainerizationOCI.LinuxBlockIO) -> Containerization.LinuxBlockIO {
        Containerization.LinuxBlockIO(
            weight: oci.weight,
            leafWeight: oci.leafWeight,
            weightDevice: oci.weightDevice.map {
                Containerization.LinuxWeightDevice(major: $0.major, minor: $0.minor, weight: $0.weight, leafWeight: $0.leafWeight)
            },
            throttleReadBpsDevice: oci.throttleReadBpsDevice.map {
                Containerization.LinuxThrottleDevice(major: $0.major, minor: $0.minor, rate: $0.rate)
            },
            throttleWriteBpsDevice: oci.throttleWriteBpsDevice.map {
                Containerization.LinuxThrottleDevice(major: $0.major, minor: $0.minor, rate: $0.rate)
            },
            throttleReadIOPSDevice: oci.throttleReadIOPSDevice.map {
                Containerization.LinuxThrottleDevice(major: $0.major, minor: $0.minor, rate: $0.rate)
            },
            throttleWriteIOPSDevice: oci.throttleWriteIOPSDevice.map {
                Containerization.LinuxThrottleDevice(major: $0.major, minor: $0.minor, rate: $0.rate)
            }
        )
    }

    private nonisolated func closeHandle(_ handle: Int32) throws {
        guard close(handle) == 0 else {
            guard let errCode = POSIXErrorCode(rawValue: errno) else {
                fatalError("failed to convert errno to POSIXErrorCode")
            }
            throw POSIXError(errCode)
        }
    }

    private func getContainer() throws -> ContainerInfo {
        guard let container else {
            throw ContainerizationError(
                .invalidState,
                message: "no container found"
            )
        }
        return container
    }

    private func gracefulStopContainer(_ lc: LinuxContainer, signal: Signal, timeout: Duration) async throws -> ExitStatus {
        // Try and gracefully shut down the process. Even if this succeeds we need to power off
        // the vm, but we should try this first always.
        var code = ExitStatus(exitCode: 255)
        do {
            code = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    try await lc.wait()
                }
                group.addTask {
                    try await lc.kill(signal)
                    try await Task.sleep(for: timeout)
                    try await lc.kill(.kill)

                    return ExitStatus(exitCode: 137)
                }
                guard let code = try await group.next() else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to get exit code from gracefully stopping container"
                    )
                }
                group.cancelAll()

                return code
            }
        } catch {}

        // Now actually bring down the vm.
        try await lc.stop()

        return code
    }

    private func cleanUpContainer(
        containerInfo: ContainerInfo,
        exitStatus: ExitStatus? = nil,
        stopFailurePolicy: ContainerStopFailurePolicy = .logAndContinue
    ) async throws {
        let container = containerInfo.container
        let id = container.id

        try? containerInfo.io.close()
        await self.stopDNSProxy()

        var stopFailure: (any Error)?
        do {
            try await container.stop()
        } catch {
            self.log.error("failed to stop container during cleanup", metadata: ["error": "\(error)"])
            stopFailure = error
        }

        await self.stopSocketForwarders()

        for binding in networkBindings { binding.session.close() }
        networkBindings = []

        let status = exitStatus ?? ExitStatus(exitCode: 255)
        self.releaseWaiters(for: id, status: status)

        if case .propagateAfterCleanup = stopFailurePolicy,
            let stopFailure
        {
            throw stopFailure
        }
    }
}

extension XPCMessage {
    fileprivate func signal() throws -> String {
        guard let signal = self.string(key: RuntimeKeys.signal.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: RuntimeKeys.stopOptions.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: RuntimeKeys.snapshot.rawValue, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: RuntimeKeys.stdin.rawValue) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: RuntimeKeys.stdout.rawValue) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: RuntimeKeys.stderr.rawValue) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func setFileHandle(_ handle: FileHandle) {
        self.set(key: RuntimeKeys.fd.rawValue, value: handle)
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: RuntimeKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    fileprivate func dynamicEnv() throws -> [String: String] {
        let data = self.dataNoCopy(key: RuntimeKeys.dynamicEnv.rawValue)
        let dynamicEnv = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return dynamicEnv
    }

    fileprivate func logReadRequest() throws -> ContainerLogReadRequest {
        guard let data = self.dataNoCopy(key: RuntimeKeys.logReadRequest.rawValue) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "empty log read request"
            )
        }
        guard data.count <= ContainerLogReadRequest.maximumEncodedTransportBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "log read request exceeds the transport limit"
            )
        }
        do {
            return try JSONDecoder().decode(ContainerLogReadRequest.self, from: data)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid log read request",
                cause: error
            )
        }
    }

}

extension ContainerResource.Bundle {
    func createLegacyLogFiles() throws {
        try createLegacyLogFileIfAbsent(at: self.containerLog)
        try createLegacyLogFileIfAbsent(at: self.containerLogRecords)
    }

    private func createLegacyLogFileIfAbsent(at path: URL) throws {
        // Legacy containers retain their raw/sidecar history across restart.
        // The append-mode legacy writer owns all later mutation.
        let fd = Darwin.open(path.path, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension Filesystem {
    var asMount: Containerization.Mount {
        switch self.type {
        case .tmpfs:
            return .any(
                type: "tmpfs",
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .virtiofs:
            return .share(
                source: self.source,
                destination: self.destination,
                options: self.options,
                fileOwnership: self.fileOwnership.map {
                    .init(uid: $0.uid, gid: $0.gid)
                }
            )
        case .block(let format, let cacheMode, let syncMode):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
                subpath: self.sourceSubpath
            )
        case .volume(_, let format, let cacheMode, let syncMode):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
                subpath: self.sourceSubpath
            )
        }
    }

    func isSocket() throws -> Bool {
        if !self.isVirtiofs {
            return false
        }
        let info = try File.info(self.source)
        return info.isSocket
    }
}

extension Filesystem.CacheMode {
    static let vzRuntimeOptionKey = "vzDiskImageCachingMode"

    var asVZRuntimeOption: String {
        switch self {
        case .on: "cached"
        case .off: "uncached"
        case .auto: "automatic"
        }
    }
}

extension Filesystem.SyncMode {
    static let vzRuntimeOptionKey = "vzDiskImageSynchronizationMode"

    var asVZRuntimeOption: String {
        switch self {
        case .full: "full"
        case .fsync: "fsync"
        case .nosync: "none"
        }
    }
}

struct MultiWriter: Writer {
    let writers: [any Writer]

    init(handles: [FileHandle]) {
        self.writers = handles
    }

    init(writers: [any Writer]) {
        self.writers = writers
    }

    func close() throws {
        for writer in writers {
            try writer.close()
        }
    }

    func write(_ data: Data) throws {
        for writer in writers {
            try writer.write(data)
        }
    }
}

extension FileHandle: @retroactive ReaderStream, @retroactive Writer {
    public func write(_ data: Data) throws {
        try self.write(contentsOf: data)
    }

    public func stream() -> AsyncStream<Data> {
        .init { cont in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    self.readabilityHandler = nil
                    cont.finish()
                    return
                }
                cont.yield(data)
            }
        }
    }
}

// MARK: State handler and bundle creation helpers

extension RuntimeService {
    static let domainnameSysctl = "kernel.domainname"

    static func resolvedSysctls(config: ContainerConfiguration) throws -> [String: String] {
        var sysctls = config.sysctls.reduce(into: [String: String]()) {
            $0[$1.key] = $1.value
        }
        guard let domainname = config.domainname, !domainname.isEmpty else {
            return sysctls
        }
        if let existing = sysctls[domainnameSysctl], existing != domainname {
            throw ContainerizationError(
                .invalidArgument,
                message: "domainname conflicts with sysctl \(domainnameSysctl)"
            )
        }
        sysctls[domainnameSysctl] = domainname
        return sysctls
    }

    static func resolvedHostname(config: ContainerConfiguration) -> String {
        if let hostname = config.hostname, !hostname.isEmpty {
            return hostname
        }
        let hostnameSource = config.networks.first?.options.hostname ?? config.id
        return hostnameSource.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0) } ?? config.id
    }

    static func resolvedHosts(
        hostname: String,
        primaryAddress: String?,
        gatewayAddress: String? = nil,
        extraHosts: [ContainerConfiguration.HostEntry]
    ) throws -> [Hosts.Entry] {
        var hosts = [Hosts.Entry.localHostIPV4()]
        if let primaryAddress {
            hosts.append(Hosts.Entry(ipAddress: primaryAddress, hostnames: [hostname]))
        }
        for extraHost in extraHosts {
            let ipAddress = try Self.resolvedHostEntryAddress(extraHost, gatewayAddress: gatewayAddress)
            hosts.append(Hosts.Entry(ipAddress: ipAddress, hostnames: extraHost.hostnames))
        }
        return hosts
    }

    private static func resolvedHostEntryAddress(
        _ extraHost: ContainerConfiguration.HostEntry,
        gatewayAddress: String?
    ) throws -> String {
        guard extraHost.requiresHostGateway else {
            return extraHost.ipAddress
        }
        guard let gatewayAddress else {
            throw ContainerizationError(
                .invalidArgument,
                message: "host-gateway requires a container network with an IPv4 gateway"
            )
        }
        return gatewayAddress
    }

    private func initializeWaiters(for id: String) throws {
        guard waiters[id] == nil else {
            throw ContainerizationError(.invalidState, message: "waiter for \(id) already initialized")
        }
        waiters[id] = ExitWaiter()
    }

    private func waitForExit(id: String, cont: CheckedContinuation<ExitStatus, Never>) {
        guard let waiter = waiters[id] else {
            // No waiter was initialized at all, resume immediately
            cont.resume(returning: ExitStatus(exitCode: -1))
            return
        }

        waiter.wait(cont)
    }

    private func releaseWaiters(for id: String, status: ExitStatus) {
        waiters[id]?.doExit(exitStatus: status)
    }

    private func setUnderlyingProcess(_ id: String, _ process: LinuxProcess) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.process = process
        self.processes[id] = info
    }

    private func setProcessState(id: String, state: State) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.state = state
        self.processes[id] = info
    }

    private func setContainer(_ info: ContainerInfo) {
        self.container = info
    }

    private func setNetworkBindings(_ bindings: [NetworkBinding]) {
        self.networkBindings = bindings
    }

    private func addNewProcess(_ id: String, _ config: ProcessConfiguration, _ io: [FileHandle?]) throws {
        guard self.processes[id] == nil else {
            throw ContainerizationError(.invalidArgument, message: "process \(id) already exists")
        }
        self.processes[id] = ProcessInfo(config: config, process: nil, state: .created, io: io)
    }

    private struct ProcessInfo {
        let config: ProcessConfiguration
        var process: LinuxProcess?
        var state: State
        let io: [FileHandle?]
    }

    private struct NetworkBinding: Sendable {
        let client: ContainerNetworkClient.NetworkClient
        let session: XPCClientSession
    }

    private struct ContainerInfo {
        let container: LinuxContainer
        let config: ContainerConfiguration
        let attachments: [Attachment]
        let bundle: ContainerResource.Bundle
        let io: ContainerStdio
        let logging: ContainerLogRuntimeCapture
    }

    private struct ContainerStdio {
        let input: AttachableInput?
        let stdout: AttachableOutput
        let stderr: AttachableOutput?

        func close() throws {
            input?.close()
            try stdout.close()
            try stderr?.close()
        }
    }

    /// States the underlying sandbox can be in.
    public enum State: Sendable, Equatable {
        /// Sandbox is created. This should be what the service starts the sandbox in.
        case created
        /// Bootstrap will transition a .created state to .booted.
        case booted
        /// startProcess on the init process will transition .booted to .running.
        case running
        /// pause() will transition .running to .paused.
        case paused
        /// At the beginning of stop() .running will be transitioned to .stopping.
        case stopping
        /// Once a stop is successful, .stopping will transition to .stopped.
        case stopped
        /// .shuttingDown will be the last state the runtime service will ever be in. Shortly
        /// afterwards the process will exit.
        case shuttingDown
    }

    func setState(_ new: State) {
        self.state = new
    }

    /// Check if a bundle exists at the given path
    private func bundleExists(at path: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        let bundle = ContainerResource.Bundle(path: path)
        do {
            _ = try bundle.configuration
            return true
        } catch {
            return false
        }
    }

    /// Create bundle from RuntimeConfiguration
    private func createBundle() throws {
        do {
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: self.root)
            _ = try ContainerResource.Bundle.create(
                path: runtimeConfig.path,
                initialFilesystem: runtimeConfig.initialFilesystem,
                kernel: runtimeConfig.kernel,
                containerConfiguration: runtimeConfig.containerConfiguration,
                containerRootFilesystem: runtimeConfig.containerRootFilesystem,
                options: runtimeConfig.options
            )
            self.log.info("created bundle", metadata: ["configPath": "\(runtimeConfig.path)"])
        } catch {
            self.log.error("failed to create bundle", metadata: ["error": "\(error)"])
            throw error
        }
    }
}
