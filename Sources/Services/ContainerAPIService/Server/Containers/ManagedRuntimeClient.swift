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
import ContainerizationOS
import CryptoKit
import Foundation

enum ManagedRuntimeClient: Sendable {
    case dedicated(RuntimeClient)
    case shared(SharedSandboxRuntimeClient)

    var isDedicated: Bool {
        if case .dedicated = self { return true }
        return false
    }

    func bootstrap(
        stdio: [FileHandle?],
        networkBootstrapInfos: [NetworkBootstrapInfo],
        dynamicEnv: [String: String] = [:],
        prewarming: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.bootstrap(
                stdio: stdio,
                networkBootstrapInfos: networkBootstrapInfos,
                dynamicEnv: dynamicEnv,
                prewarming: prewarming
            )
        case .shared(let client):
            guard !prewarming else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "shared-vm workloads cannot use dedicated runtime prewarming"
                )
            }
            try await client.bootstrap(
                stdio: stdio,
                networkBootstrapInfos: networkBootstrapInfos,
                dynamicEnv: dynamicEnv
            )
        }
    }

    func state() async throws -> SandboxSnapshot {
        switch self {
        case .dedicated(let client): return try await client.state()
        case .shared(let client): return try await client.state()
        }
    }

    func createProcess(
        _ id: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.createProcess(id, config: config, stdio: stdio)
        case .shared(let client):
            try await client.createProcess(id, config: config, stdio: stdio)
        }
    }

    func attach(
        stdio: [FileHandle?],
        closeStdin: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.attach(
                stdio: stdio,
                closeStdin: closeStdin
            )
        case .shared(let client):
            guard !closeStdin else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "shared-vm workloads do not have deferred dedicated stdin"
                )
            }
            try await client.attach(stdio: stdio)
        }
    }

    func followLogs(request: ContainerLogReadRequest) async throws -> FileHandle {
        switch self {
        case .dedicated(let client): return try await client.followLogs(request: request)
        case .shared(let client): return try await client.followLogs(request: request)
        }
    }

    func followLogRecords(request: ContainerLogReadRequest) async throws -> FileHandle {
        switch self {
        case .dedicated(let client): return try await client.followLogRecords(request: request)
        case .shared(let client): return try await client.followLogRecords(request: request)
        }
    }

    func followLogReadRecordsV1(request: ContainerLogReadRequest) async throws -> FileHandle {
        switch self {
        case .dedicated(let client): return try await client.followLogReadRecordsV1(request: request)
        case .shared(let client): return try await client.followLogReadRecordsV1(request: request)
        }
    }

    func startProcess(_ id: String) async throws {
        switch self {
        case .dedicated(let client): try await client.startProcess(id)
        case .shared(let client): try await client.startProcess(id)
        }
    }

    func stop(options: ContainerStopOptions) async throws {
        switch self {
        case .dedicated(let client): try await client.stop(options: options)
        case .shared(let client): try await client.stop(options: options)
        }
    }

    func pause() async throws {
        switch self {
        case .dedicated(let client): try await client.pause()
        case .shared(let client): try await client.pause()
        }
    }

    func resume() async throws {
        switch self {
        case .dedicated(let client): try await client.resume()
        case .shared(let client): try await client.resume()
        }
    }

    func setMemoryTarget(_ memoryInBytes: UInt64) async throws {
        switch self {
        case .dedicated(let client):
            try await client.setMemoryTarget(memoryInBytes)
        case .shared:
            throw ContainerizationError(
                .unsupported,
                message: "live memory targeting is unavailable for shared-vm isolation"
            )
        }
    }

    func kill(_ id: String, signal: String) async throws {
        switch self {
        case .dedicated(let client): try await client.kill(id, signal: signal)
        case .shared(let client): try await client.kill(id, signal: signal)
        }
    }

    func resize(_ id: String, size: Terminal.Size) async throws {
        switch self {
        case .dedicated(let client): try await client.resize(id, size: size)
        case .shared(let client): try await client.resize(id, size: size)
        }
    }

    func wait(_ id: String, deliversToClient: Bool = true) async throws -> ExitStatus {
        switch self {
        case .dedicated(let client):
            if deliversToClient {
                return try await client.wait(id)
            }
            return try await client.observeExit(id)
        case .shared(let client): return try await client.wait(id)
        }
    }

    func dial(_ port: UInt32) async throws -> FileHandle {
        switch self {
        case .dedicated(let client): return try await client.dial(port)
        case .shared(let client): return try await client.dial(port)
        }
    }

    func shutdown() async throws {
        switch self {
        case .dedicated(let client): try await client.shutdown()
        case .shared(let client): try await client.shutdown()
        }
    }

    func clean(id: String) async throws {
        switch self {
        case .dedicated(let client):
            try await client.clean(id: id)
        case .shared:
            throw ContainerizationError(
                .unsupported,
                message: "clean is unavailable for shared-vm isolation"
            )
        }
    }

    func copyIn(
        source: String,
        destination: String,
        mode: UInt32,
        createParents: Bool = true,
        followSymlink: Bool = false,
        preserveOwnership: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.copyIn(
                source: source,
                destination: destination,
                mode: mode,
                createParents: createParents,
                followSymlink: followSymlink,
                preserveOwnership: preserveOwnership
            )
        case .shared(let client):
            try await client.copyIn(
                source: source,
                destination: destination,
                mode: mode,
                createParents: createParents,
                followSymlink: followSymlink,
                preserveOwnership: preserveOwnership
            )
        }
    }

    func copyIn(
        archive: FileHandle,
        destination: String,
        createParents: Bool = true,
        preserveOwnership: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.copyIn(
                archive: archive,
                destination: destination,
                createParents: createParents,
                preserveOwnership: preserveOwnership
            )
        case .shared(let client):
            try await client.copyIn(
                archive: archive,
                destination: destination,
                createParents: createParents,
                preserveOwnership: preserveOwnership
            )
        }
    }

    func copyOut(
        source: String,
        destination: String,
        createParents: Bool = true,
        followSymlink: Bool = false,
        preserveOwnership: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.copyOut(
                source: source,
                destination: destination,
                createParents: createParents,
                followSymlink: followSymlink,
                preserveOwnership: preserveOwnership
            )
        case .shared(let client):
            try await client.copyOut(
                source: source,
                destination: destination,
                createParents: createParents,
                followSymlink: followSymlink,
                preserveOwnership: preserveOwnership
            )
        }
    }

    func copyOut(
        source: String,
        archive: FileHandle,
        followSymlink: Bool = false,
        copyContents: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.copyOut(
                source: source,
                archive: archive,
                followSymlink: followSymlink,
                copyContents: copyContents
            )
        case .shared(let client):
            try await client.copyOut(
                source: source,
                archive: archive,
                followSymlink: followSymlink,
                copyContents: copyContents
            )
        }
    }

    func snapshotDisk(
        imagePath: String,
        destinationPath: String,
        noFreeze: Bool = false
    ) async throws {
        switch self {
        case .dedicated(let client):
            try await client.snapshotDisk(
                imagePath: imagePath,
                destinationPath: destinationPath,
                noFreeze: noFreeze
            )
        case .shared(let client):
            try await client.snapshotDisk(
                imagePath: imagePath,
                destinationPath: destinationPath,
                noFreeze: noFreeze
            )
        }
    }

    func statistics() async throws -> ContainerStats {
        switch self {
        case .dedicated(let client): return try await client.statistics()
        case .shared(let client): return try await client.statistics()
        }
    }

    func processes() async throws -> ContainerProcesses {
        switch self {
        case .dedicated(let client): return try await client.processes()
        case .shared(let client): return try await client.processes()
        }
    }
}

protocol SharedSandboxNetworkAllocating: Sendable {
    func allocate(
        configurations: [AttachmentConfiguration],
        bootstrapInfos: [NetworkBootstrapInfo]
    ) async throws -> [Attachment]
}

private actor DefaultSharedSandboxNetworkAllocator:
    SharedSandboxNetworkAllocating
{
    private struct Binding: Sendable {
        let client: ContainerNetworkClient.NetworkClient
        let session: XPCClientSession
    }

    private var bindings: [Binding] = []

    func allocate(
        configurations: [AttachmentConfiguration],
        bootstrapInfos: [NetworkBootstrapInfo]
    ) async throws -> [Attachment] {
        guard configurations.count == bootstrapInfos.count else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm network configuration and plugin counts do not match"
            )
        }

        var pendingBindings: [Binding] = []
        var attachments: [Attachment] = []
        do {
            for (configuration, info) in zip(
                configurations,
                bootstrapInfos
            ) {
                let client = ContainerNetworkClient.NetworkClient(
                    id: configuration.network,
                    plugin: info.plugin
                )
                let session = client.connect()
                pendingBindings.append(
                    Binding(client: client, session: session)
                )
                let (attachment, _) = try await client.allocate(
                    hostname: configuration.options.hostname,
                    aliases: configuration.options.aliases,
                    macAddress: configuration.options.macAddress,
                    requestedIPv4Address:
                        configuration.options.requestedIPv4Address,
                    requestedIPv6Address:
                        configuration.options.requestedIPv6Address,
                    retainOnDisconnect: true,
                    on: session
                )
                attachments.append(attachment)
            }
        } catch {
            for binding in pendingBindings {
                binding.session.close()
            }
            throw error
        }

        bindings.append(contentsOf: pendingBindings)
        return attachments
    }
}

actor SharedSandboxRuntimeClient {
    private static let initProcessPlan = "sha256:container-shared-vm-v1"

    private let id: String
    private let workloadRoot: URL
    private let containerConfiguration: ContainerConfiguration
    private let authority: any EngineLinuxSandboxWorkloadAuthorityV1
    private let configurationProvider: any EngineLinuxSandboxConfigurationProvidingV1
    private let networkAllocator: any SharedSandboxNetworkAllocating
    private var sandboxConfiguration: EngineLinuxSandboxRuntimeConfigurationV1?
    private var workload: EngineWorkloadRecordV1?
    private var networkAttachments: [Attachment] = []

    init(
        id: String,
        workloadRoot: URL,
        containerConfiguration: ContainerConfiguration,
        authority: any EngineLinuxSandboxWorkloadAuthorityV1,
        configurationProvider:
            any EngineLinuxSandboxConfigurationProvidingV1,
        networkAllocator: any SharedSandboxNetworkAllocating =
            DefaultSharedSandboxNetworkAllocator()
    ) {
        self.id = id
        self.workloadRoot = workloadRoot
        self.containerConfiguration = containerConfiguration
        self.authority = authority
        self.configurationProvider = configurationProvider
        self.networkAllocator = networkAllocator
    }

    func bootstrap(
        stdio: [FileHandle?],
        networkBootstrapInfos: [NetworkBootstrapInfo],
        dynamicEnv: [String: String]
    ) async throws {
        guard workload == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm workload is already bootstrapped"
            )
        }
        let configuration = try await configurationProvider.sandboxConfiguration()
        guard containerConfiguration.effectiveIsolation == .sharedVM,
            containerConfiguration.sandboxID == configuration.sandboxID
        else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm workload does not match its durable sandbox identity"
            )
        }
        let networkConfigurations = try Self.networkConfigurations(
            for: containerConfiguration
        )
        let attachments = try await networkAllocator.allocate(
            configurations: networkConfigurations,
            bootstrapInfos: networkBootstrapInfos
        )
        guard attachments.count == networkConfigurations.count else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm network allocator returned an unexpected attachment count"
            )
        }
        let networkEndpoints = try zip(networkConfigurations, attachments)
            .enumerated()
            .map { index, pair in
                try Self.networkEndpoint(
                    containerID: id,
                    interfaceIndex: index,
                    configuration: pair.0,
                    attachment: pair.1
                )
            }
        let running = try await authority.startWorkload(
            planDigest: Self.initProcessPlan,
            configuration: configuration,
            workloadRoot: workloadRoot,
            dynamicEnvironment: dynamicEnv,
            networkEndpoints: networkEndpoints,
            stdio: stdio,
            controllers: [],
            monitorTerminal: false
        )
        guard running.containerID == id,
            running.state == .running,
            running.activeProcessGeneration != nil
        else {
            throw ContainerizationError(
                .internalError,
                message: "shared-vm authority returned an invalid workload receipt"
            )
        }
        sandboxConfiguration = configuration
        workload = running
        networkAttachments = attachments
    }

    func state() async throws -> SandboxSnapshot {
        guard case .state(let status) = try await control(.state) else {
            throw invalidResponse("state")
        }
        return SandboxSnapshot(
            status: status,
            networks: networkAttachments,
            containers: []
        )
    }

    static func networkConfigurations(
        for configuration: ContainerConfiguration
    ) throws -> [AttachmentConfiguration] {
        guard !configuration.hostNetwork else {
            return []
        }
        guard configuration.networks.count <= 1,
            configuration.networks.allSatisfy({
                $0.network == ContainerAPIClient.NetworkClient.defaultNetworkName
            })
        else {
            throw ContainerizationError(
                .unsupported,
                message: "shared-vm isolation currently supports only the built-in default network"
            )
        }
        return configuration.networks
    }

    static func networkEndpoint(
        containerID: String,
        interfaceIndex: Int,
        configuration: AttachmentConfiguration,
        attachment: Attachment
    ) throws -> WorkloadNetworkEndpoint {
        guard let macAddress = attachment.macAddress else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm network attachment has no MAC address"
            )
        }

        var addresses = configuration.options.additionalIPAddresses.map {
            InterfaceIPAssignment(address: $0)
        }
        if let address = attachment.ipv4Address {
            addresses.insert(
                InterfaceIPAssignment(
                    address: .v4(address.address, address.prefix)
                ),
                at: 0
            )
        }
        if let address = attachment.ipv6Address {
            addresses.append(
                InterfaceIPAssignment(
                    address: .v6(address.address, address.prefix)
                )
            )
        }

        var routes: [InterfaceRoute] = []
        if interfaceIndex == 0 {
            if attachment.ipv4Address != nil,
                let gateway = attachment.ipv4Gateway
            {
                routes.append(InterfaceRoute(nextHop: .v4(gateway)))
            }
            if attachment.ipv6Address != nil,
                let gateway = attachment.ipv6Gateway
            {
                routes.append(InterfaceRoute(nextHop: .v6(gateway)))
            }
        }

        return WorkloadNetworkEndpoint(
            hostInterfaceName: hostInterfaceName(
                containerID: containerID,
                interfaceIndex: interfaceIndex
            ),
            bridgeInterfaceName:
                EngineLinuxSandboxNetworkingV1.workloadBridgeName,
            interface: InterfaceConfiguration(
                name: configuration.options.guestInterfaceName
                    ?? "eth\(interfaceIndex)",
                hardwareAddress: macAddress,
                addresses: addresses,
                routes: routes,
                mtu: configuration.options.mtu ?? attachment.mtu ?? 1280
            )
        )
    }

    static func hostInterfaceName(
        containerID: String,
        interfaceIndex: Int
    ) -> String {
        let material = Data("\(containerID)\u{0}\(interfaceIndex)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "cw" + digest.prefix(13)
    }

    func createProcess(
        _ processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        _ = processID
        _ = config
        _ = stdio
        throw unsupported("exec process creation")
    }

    func attach(stdio: [FileHandle?]) async throws {
        _ = stdio
        throw unsupported("attaching after start")
    }

    func followLogs(request: ContainerLogReadRequest) async throws -> FileHandle {
        _ = request
        throw unsupported("runtime log following")
    }

    func followLogRecords(request: ContainerLogReadRequest) async throws -> FileHandle {
        _ = request
        throw unsupported("structured runtime log following")
    }

    func followLogReadRecordsV1(request: ContainerLogReadRequest) async throws -> FileHandle {
        _ = request
        throw unsupported("lossless runtime log following")
    }

    func startProcess(_ processID: String) throws {
        guard processID == id else {
            throw unsupported("exec process start")
        }
        _ = try activeWorkload()
    }

    func stop(options: ContainerStopOptions) async throws {
        let signal = options.signal ?? containerConfiguration.stopSignal ?? "SIGTERM"
        try await signalAndWait(
            signal: signal,
            timeoutInSeconds:
                options.timeoutInSeconds
                ?? containerConfiguration.stopTimeoutInSeconds
                ?? 10
        )
        let (configuration, processGeneration) = try activeTuple()
        workload = try await authority.stopWorkload(
            configuration: configuration,
            workloadID: id,
            workloadProcessGeneration: processGeneration
        )
    }

    func pause() async throws {
        let (configuration, processGeneration) = try activeTuple()
        workload = try await authority.pauseWorkload(
            configuration: configuration,
            workloadID: id,
            workloadProcessGeneration: processGeneration
        )
    }

    func resume() async throws {
        let (configuration, processGeneration) = try activeTuple()
        workload = try await authority.resumeWorkload(
            configuration: configuration,
            workloadID: id,
            workloadProcessGeneration: processGeneration
        )
    }

    func kill(_ processID: String, signal: String) async throws {
        guard processID == id else {
            throw unsupported("exec process signal")
        }
        guard case .none = try await control(.signal(signal)) else {
            throw invalidResponse("signal")
        }
    }

    func resize(_ processID: String, size: Terminal.Size) async throws {
        guard processID == id else {
            throw unsupported("exec terminal resize")
        }
        guard
            case .none = try await control(
                .resize(width: size.width, height: size.height)
            )
        else {
            throw invalidResponse("resize")
        }
    }

    func wait(_ processID: String) async throws -> ExitStatus {
        guard processID == id else {
            throw unsupported("exec process wait")
        }
        guard
            case .exit(let status) = try await control(
                .wait(timeoutInSeconds: nil)
            )
        else {
            throw invalidResponse("wait")
        }
        return status.exitStatus
    }

    func dial(_ port: UInt32) async throws -> FileHandle {
        let (configuration, processGeneration) = try activeTuple()
        return try await authority.dialService(
            configuration: configuration,
            workloadID: id,
            workloadProcessGeneration: processGeneration,
            port: port
        )
    }

    func shutdown() async throws {
        guard let workload else {
            return
        }
        switch workload.state {
        case .stopped:
            return
        case .running, .paused:
            let (configuration, processGeneration) = try activeTuple()
            self.workload = try await authority.stopWorkload(
                configuration: configuration,
                workloadID: id,
                workloadProcessGeneration: processGeneration
            )
        default:
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm workload cannot be reclaimed from state \(workload.state)"
            )
        }
    }

    func copyIn(
        source: String,
        destination: String,
        mode: UInt32,
        createParents: Bool,
        followSymlink: Bool,
        preserveOwnership: Bool
    ) throws {
        _ = source
        _ = destination
        _ = mode
        _ = createParents
        _ = followSymlink
        _ = preserveOwnership
        throw unsupported("copying files into a running workload")
    }

    func copyIn(
        archive: FileHandle,
        destination: String,
        createParents: Bool,
        preserveOwnership: Bool
    ) throws {
        _ = archive
        _ = destination
        _ = createParents
        _ = preserveOwnership
        throw unsupported("streaming files into a running workload")
    }

    func copyOut(
        source: String,
        destination: String,
        createParents: Bool,
        followSymlink: Bool,
        preserveOwnership: Bool
    ) throws {
        _ = source
        _ = destination
        _ = createParents
        _ = followSymlink
        _ = preserveOwnership
        throw unsupported("copying files from a running workload")
    }

    func copyOut(
        source: String,
        archive: FileHandle,
        followSymlink: Bool,
        copyContents: Bool
    ) throws {
        _ = source
        _ = archive
        _ = followSymlink
        _ = copyContents
        throw unsupported("streaming files from a running workload")
    }

    func snapshotDisk(
        imagePath: String,
        destinationPath: String,
        noFreeze: Bool
    ) throws {
        _ = imagePath
        _ = destinationPath
        _ = noFreeze
        throw unsupported("live disk snapshots")
    }

    func statistics() async throws -> ContainerStats {
        guard case .statistics(let statistics) = try await control(.statistics)
        else {
            throw invalidResponse("statistics")
        }
        return statistics
    }

    func processes() async throws -> ContainerProcesses {
        guard case .processes(let processes) = try await control(.processes)
        else {
            throw invalidResponse("processes")
        }
        return processes
    }

    private func signalAndWait(
        signal: String,
        timeoutInSeconds: Int32
    ) async throws {
        guard case .none = try await control(.signal(signal)) else {
            throw invalidResponse("stop signal")
        }
        let timeout = max(0, Int64(timeoutInSeconds))
        do {
            guard
                case .exit = try await control(
                    .wait(timeoutInSeconds: timeout)
                )
            else {
                throw invalidResponse("stop wait")
            }
            return
        } catch let error as ContainerizationError where error.code == .timeout {
            // The guest-side RPC deadline is authoritative. Continue with the
            // forced signal without relying on cancellation of an XPC wait.
        }
        guard case .none = try await control(.signal("SIGKILL")) else {
            throw invalidResponse("forced stop signal")
        }
        guard
            case .exit = try await control(
                .wait(timeoutInSeconds: nil)
            )
        else {
            throw invalidResponse("forced stop wait")
        }
    }

    private func control(
        _ action: EngineLinuxSandboxWorkloadControlRequestV1.Action
    ) async throws -> EngineLinuxSandboxWorkloadControlResponseV1 {
        let (configuration, processGeneration) = try activeTuple()
        return try await authority.controlWorkload(
            configuration: configuration,
            workloadID: id,
            workloadProcessGeneration: processGeneration,
            action: action
        )
    }

    private func activeTuple() throws
        -> (EngineLinuxSandboxRuntimeConfigurationV1, UInt64)
    {
        let running = try activeWorkload()
        guard let sandboxConfiguration,
            let processGeneration = running.activeProcessGeneration
        else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm workload has no active generation"
            )
        }
        return (sandboxConfiguration, processGeneration)
    }

    private func activeWorkload() throws -> EngineWorkloadRecordV1 {
        guard let workload,
            workload.state == .running || workload.state == .paused
        else {
            throw ContainerizationError(
                .invalidState,
                message: "shared-vm workload is not active"
            )
        }
        return workload
    }

    nonisolated private func unsupported(
        _ operation: String
    ) -> ContainerizationError {
        ContainerizationError(
            .unsupported,
            message: "shared-vm isolation does not yet support \(operation)"
        )
    }

    nonisolated private func invalidResponse(
        _ operation: String
    ) -> ContainerizationError {
        ContainerizationError(
            .internalError,
            message: "shared-vm runtime returned an invalid \(operation) response"
        )
    }
}
