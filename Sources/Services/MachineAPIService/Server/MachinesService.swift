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
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import MachineAPIClient
import SystemPackage

// systemd poweroff signal (SIGRTMIN+4 on Linux, where SIGRTMIN=34 under glibc)
private let SIGRTMIN4: Int32 = 38

struct MachineCreationReservations: Sendable {
    private(set) var ids: Set<String> = []

    mutating func reserve(_ id: String, existing: Set<String>) throws {
        guard !ids.contains(id), !existing.contains(id) else {
            throw ContainerizationError(
                .exists,
                message: "container machine already exists: \(id)"
            )
        }
        ids.insert(id)
    }

    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        ids.remove(id) != nil
    }
}

enum ConcurrentMachineBootPreparation {
    @concurrent
    static func run<Discovery: Sendable, Configuration: Sendable, PreparedKernel: Sendable>(
        discovery: @Sendable @escaping () async throws -> Discovery,
        configuration: @Sendable @escaping () async throws -> Configuration,
        kernel: @Sendable @escaping () async throws -> PreparedKernel
    ) async throws -> (discovery: Discovery, configuration: Configuration, kernel: PreparedKernel) {
        async let discovered = discovery()
        async let configured = configuration()
        async let resolvedKernel = kernel()
        return try await (discovered, configured, resolvedKernel)
    }
}

enum ConcurrentMachineCreationPreparation {
    @concurrent
    static func run<Bundle: Sendable, Filesystem: Sendable>(
        bundle: @Sendable @escaping () async throws -> Bundle,
        filesystem: @Sendable @escaping () async throws -> Filesystem,
        finalize: @Sendable @escaping (Bundle, Filesystem) async throws -> Void
    ) async throws -> Bundle {
        async let preparedBundle = bundle()
        async let preparedFilesystem = filesystem()
        let values = try await (preparedBundle, preparedFilesystem)
        try await finalize(values.0, values.1)
        return values.0
    }
}

public actor MachinesService {
    private static let machinesDir = FilePath.Component("machines")
    private static let stateFile = FilePath.Component("state.json")

    struct MachineState {
        var snapshot: MachineSnapshot

        var id: String { snapshot.configuration.id }

        var logger: Task<Void, Never>?

        // Machine lifecycle locks are acquired before the service-wide lock.
        // The generation prevents delayed work from acting on a replacement with the same ID.
        let lifecycleLock = AsyncLock()
        let generation = UUID()
    }

    private var serviceState: ServiceState
    private let client: ContainerClient

    private let resourceRoot: FilePath
    private let machineRoot: FilePath
    private let lock = AsyncLock()
    private var machines: [String: MachineState]
    private var pendingCreations = MachineCreationReservations()
    private let exitMonitor: ExitMonitor
    private let log: Logger

    private var `default`: MachineState? {
        guard let id = serviceState.defaultMachine else {
            return nil
        }
        // If a default is set but doesn't exist, treat as if no default is set
        // This can happen if the default container machine was deleted
        return self.machines[id]
    }

    public init(appRoot: FilePath, resourceRoot: FilePath, log: Logger) throws {
        self.resourceRoot = resourceRoot

        let machineRoot = appRoot.appending(Self.machinesDir)
        try FileManager.default.createDirectory(atPath: machineRoot.string, withIntermediateDirectories: true)
        self.machineRoot = machineRoot
        self.serviceState = try ServiceState.from(appRoot.appending(Self.stateFile))

        self.log = log
        self.machines = try Self.loadAtBoot(root: machineRoot, resourceRoot: resourceRoot, log: log)
        self.client = ContainerClient()
        self.exitMonitor = ExitMonitor(log: log)
    }

    static private func loadAtBoot(root: FilePath, resourceRoot: FilePath, log: Logger) throws -> [String: MachineState] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.string)

        var results = [String: MachineState]()
        for entry in entries {
            guard let component = FilePath.Component(entry) else {
                continue
            }
            let dir = root.appending(component)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.string, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            do {
                try MachineBundle.sync(path: dir, resourceRoot: resourceRoot)
            } catch {
                log.error("failed to sync resources for machine bundle", metadata: ["path": "\(dir.string)", "error": "\(error)"])
                continue
            }

            do {
                let bundle = MachineBundle(path: dir)
                let config = try bundle.configuration
                let bootConfig = try bundle.bootConfig

                let state = MachineState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        bootConfig: bootConfig,
                        createdDate: try? bundle.createdDate,
                        containerId: nil,
                        initialized: bundle.initialized
                    )
                )

                results[config.id] = state
            } catch {
                log.warning("failed to load machine bundle", metadata: ["path": "\(dir.string)", "error": "\(error)"])
            }
        }

        return results
    }

    static private func pipeFile(from: FileHandle, to: FileHandle) async throws {
        try to.seekToEnd()

        let stream = AsyncStream<Data> { cont in
            from.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    from.readabilityHandler = nil
                    cont.finish()
                    return
                }

                cont.yield(data)
            }
        }

        for await data in stream {
            try to.write(contentsOf: data)
        }
    }

    public func list() async throws -> [MachineSnapshot] {
        self.log.debug("\(#function)")
        var snapshots: [MachineSnapshot] = []
        for state in self.machines.values {
            var snapshot = state.snapshot
            let path = try self.bundlePath(id: snapshot.id)
            let bundle = MachineBundle(path: path)
            snapshot.diskSize = bundle.diskSize
            snapshots.append(snapshot)
        }
        let runningIds = snapshots.compactMap { $0.status == .running ? $0.containerId : nil }
        if !runningIds.isEmpty {
            var containers: [ContainerSnapshot]?
            do {
                containers = try await self.client.list(filters: ContainerListFilters(ids: runningIds))
            } catch {
                self.log.warning("failed to fetch container addresses: \(error)")
            }
            let addressMap = (containers ?? []).reduce(into: [String: String]()) { result, c in
                if let addr = c.networks.first?.ipv4Address?.address.description {
                    result[c.id] = addr
                }
            }
            for i in snapshots.indices where snapshots[i].status == .running {
                if let cid = snapshots[i].containerId {
                    snapshots[i].ipAddress = addressMap[cid]
                }
            }
        }
        return snapshots
    }

    /// Ensure that a cloned machine root filesystem can boot as a container machine.
    ///
    /// The machine boot process hands off to the image's init system via
    /// `exec /sbin/init`, so an image without one (e.g. a standard application
    /// image such as `docker.io/library/ubuntu`) produces a machine that can
    /// never boot. Validating here surfaces an actionable error at create time.
    public static func validateMachineRootfs(blockDevice: FilePath, image: String) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: blockDevice)
        let initPath = FilePath("/sbin/init")
        let initMetadata = try? reader.stat(initPath)
        let isRegularFile = (try? reader.readFile(at: initPath, count: 0)) != nil
        let isExecutable = initMetadata.map { $0.inode.mode & 0o111 != 0 } ?? false
        guard isRegularFile, isExecutable else {
            throw ContainerizationError(
                .invalidArgument,
                message:
                    "image \(image) cannot be used as a container machine: it does not contain an executable /sbin/init file. "
                    + "Container machine images must include an init system such as systemd. "
                    + "See \"Bring your own container machine image\" in the container machine guide for a working Dockerfile."
            )
        }
    }

    public func create(configuration: MachineConfiguration, resources: MachineResources?, bootConfig: MachineConfig) async throws {
        self.log.debug("\(#function)")

        let path = try self.bundlePath(id: configuration.id)
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-reserve", "id": "\(configuration.id)"]) { context in
            try await self.reserveMachineCreation(configuration.id, context: context)
        }

        do {
            let resourceRoot = self.resourceRoot
            _ = try await ConcurrentMachineCreationPreparation.run(
                bundle: {
                    try MachineBundle.create(
                        path: path,
                        machineConfiguration: configuration,
                        resourceRoot: resourceRoot,
                        resources: resources,
                        bootConfig: bootConfig,
                    )
                },
                filesystem: {
                    let machineImage = ClientImage(description: configuration.image)
                    return try await machineImage.getCreateSnapshot(platform: configuration.platform)
                },
                finalize: { bundle, imageFs in
                    try bundle.setMachineRootFs(cloning: imageFs)
                    try Self.validateMachineRootfs(
                        blockDevice: FilePath(bundle.machineRootfs.source),
                        image: configuration.image.reference
                    )
                }
            )
            let snapshot = MachineSnapshot(
                configuration: configuration,
                status: .stopped,
                bootConfig: bootConfig,
                createdDate: Date(),
                containerId: nil
            )
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-commit", "id": "\(configuration.id)"]) { context in
                try await self.commitMachineCreation(snapshot, context: context)
            }
        } catch {
            if FileManager.default.fileExists(atPath: path.string) {
                do {
                    let bundle = MachineBundle(path: path)
                    try bundle.delete()
                } catch let cleanupError {
                    self.log.error(
                        "failed to delete bundle for container machine \(configuration.id)",
                        metadata: ["error": "\(cleanupError)"]
                    )
                }
            }
            await self.lock.withLock(logMetadata: ["acquirer": "\(#function)-rollback", "id": "\(configuration.id)"]) { context in
                await self.rollbackMachineCreation(configuration.id, context: context)
            }
            throw error
        }
    }

    public func delete(id: String) async throws {
        self.log.debug("\(#function)")

        let initialState = try self._getMachineState(id: id)
        try await initialState.lifecycleLock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            let state = try await self.lock.withLock { context in
                try await self.getMachineState(id: id, generation: initialState.generation, context: context)
            }

            switch state.snapshot.status {
            case .running:
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine \(id) is \(state.snapshot.status)")
            default:
                break
            }

            let path = try self.bundlePath(id: id)
            try MachineBundle(path: path).delete()

            try await self.lock.withLock { context in
                _ = try await self.getMachineState(id: id, generation: initialState.generation, context: context)
                if let defaultMachine = await self.default, defaultMachine.id == id {
                    try await self._setDefault(id: nil)
                }
                _ = await self.removeMachineState(
                    id: id,
                    generation: initialState.generation,
                    context: context
                )
            }
        }
    }

    public func getDefault() async throws -> String? {
        self.log.debug("\(#function)")

        return self.default?.id
    }

    public func setDefault(id: String) async throws {
        self.log.debug("\(#function)")

        try await self.lock.withLock { context in
            let state = try await self._getMachineState(id: id)
            try await self._setDefault(id: state.id)
        }
    }

    public func setConfig(id: String, bootConfig: MachineConfig) async throws {
        self.log.debug("\(#function)")
        let initialState = try self._getMachineState(id: id)
        try await initialState.lifecycleLock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            var state = try await self.lock.withLock { context in
                try await self.getMachineState(id: id, generation: initialState.generation, context: context)
            }
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)
            try bundle.set(bootConfig: bootConfig)

            state.snapshot.bootConfig = bootConfig
            let updatedState = state
            try await self.lock.withLock { context in
                _ = try await self.getMachineState(id: id, generation: initialState.generation, context: context)
                await self.setMachineState(id, updatedState, context: context)
            }
        }
    }

    private func _getMachineState(id: String) throws -> MachineState {
        let state = self.machines[id]
        guard let state else {
            throw ContainerizationError(
                .notFound,
                message: "container machine with ID \(id) not found")
        }
        return state
    }

    private func getMachineState(id: String, generation: UUID) throws -> MachineState {
        let state = try self._getMachineState(id: id)
        guard state.generation == generation else {
            throw ContainerizationError(
                .notFound,
                message: "container machine with ID \(id) was replaced"
            )
        }
        return state
    }

    private func getMachineState(
        id: String,
        generation: UUID,
        context _: AsyncLock.Context
    ) throws -> MachineState {
        try self.getMachineState(id: id, generation: generation)
    }

    private func setMachineState(_ id: String, _ state: MachineState, context: AsyncLock.Context) async {
        self.machines[id] = state
    }

    private func reserveMachineCreation(
        _ id: String,
        context _: AsyncLock.Context
    ) throws {
        try self.pendingCreations.reserve(id, existing: Set(self.machines.keys))
        do {
            try Task.checkCancellation()
        } catch {
            self.pendingCreations.remove(id)
            throw error
        }
    }

    private func commitMachineCreation(
        _ snapshot: MachineSnapshot,
        context _: AsyncLock.Context
    ) throws {
        try Task.checkCancellation()
        guard self.pendingCreations.ids.contains(snapshot.id) else {
            throw ContainerizationError(
                .internalError,
                message: "container machine creation reservation not found: \(snapshot.id)"
            )
        }
        if self.default == nil {
            try self._setDefault(id: snapshot.id)
        }
        self.pendingCreations.remove(snapshot.id)
        self.machines[snapshot.id] = MachineState(snapshot: snapshot)
    }

    private func rollbackMachineCreation(
        _ id: String,
        context _: AsyncLock.Context
    ) {
        self.pendingCreations.remove(id)
    }

    static func markMachineRunning(
        _ state: inout MachineState,
        containerID: String,
        startedDate: Date,
        initialized: Bool
    ) {
        state.snapshot.status = .running
        state.snapshot.startedDate = startedDate
        state.snapshot.containerId = containerID
        state.snapshot.initialized = initialized
    }

    static func markMachineStopped(_ state: inout MachineState) {
        state.snapshot.status = .stopped
        state.snapshot.startedDate = nil
        state.snapshot.containerId = nil
        state.snapshot.ipAddress = nil
    }

    @discardableResult
    static func removeMachineState(
        id: String,
        generation: UUID,
        from machines: inout [String: MachineState]
    ) -> Bool {
        guard machines[id]?.generation == generation else {
            return false
        }
        machines.removeValue(forKey: id)
        return true
    }

    @discardableResult
    private func removeMachineState(
        id: String,
        generation: UUID,
        context _: AsyncLock.Context
    ) -> Bool {
        Self.removeMachineState(id: id, generation: generation, from: &self.machines)
    }

    private nonisolated func bundlePath(id: String) throws -> FilePath {
        guard let component = FilePath.Component(id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container machine ID \(id) is not a valid path component"
            )
        }
        return self.machineRoot.appending(component)
    }

    private func _setDefault(id: String?) throws {
        try serviceState.setDefault(id: id)
    }

    nonisolated static func systemPlatform(from ociPlatform: ContainerizationOCI.Platform) -> SystemPlatform {
        ociPlatform.architecture == "amd64" ? .linuxAmd : .linuxArm
    }

    public func boot(id: String?, dynamicEnv: [String: String] = [:]) async throws -> MachineSnapshot {
        self.log.debug("\(#function)")

        guard let id = id ?? self.default?.id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no container machine specified and no default set"
            )
        }

        let initialState = try self._getMachineState(id: id)
        return try await initialState.lifecycleLock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            var state = try await self.lock.withLock { context in
                try await self.getMachineState(id: id, generation: initialState.generation, context: context)
            }

            switch state.snapshot.status {
            case .running:
                return state.snapshot
            case .stopped:
                break
            default:
                throw ContainerizationError(.invalidState, message: "container machine \(id) is \(state.snapshot.status)")
            }

            let cid = "\(id)-\(UUID().uuidString.prefix(MachineConfiguration.containerUUIDLength).lowercased())"
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)
            let rootfs = try bundle.machineRootfs

            let bootConfig = state.snapshot.bootConfig
            let machineConfiguration = state.snapshot.configuration
            let client = self.client
            let systemPlatform = Self.systemPlatform(from: machineConfiguration.platform)
            let preparation = try await ConcurrentMachineBootPreparation.run(
                discovery: {
                    try await client.list(filters: .init(ids: [cid]))
                },
                configuration: {
                    try await machineConfiguration.toContainerConfig(
                        cid: cid,
                        sbin: path.appending(MachineBundle.sbinDirectory),
                        initializedFile: path.appending(MachineBundle.initializedFile),
                        homeMountOption: bootConfig.homeMount,
                        virtualization: bootConfig.virtualization,
                    )
                },
                kernel: {
                    if let kernelPath = bootConfig.kernelPath {
                        let validated = try MachineConfig.validateKernelPath(kernelPath.string)
                        return Kernel(
                            path: URL(fileURLWithPath: validated.string),
                            platform: systemPlatform
                        )
                    }
                    return try await ClientKernel.getDefaultKernel(for: .current)
                }
            )
            guard preparation.discovery.isEmpty else {
                throw ContainerizationError(.internalError, message: "container \(cid) already exists")
            }

            var config = preparation.configuration
            config.resources.cpus = bootConfig.cpus
            config.resources.cpuOverhead = 0
            config.resources.memoryInBytes = bootConfig.memory.toUInt64(unit: .bytes)

            var fhs: [FileHandle] = []
            do {
                try await self.client.create(
                    configuration: config,
                    options: ContainerCreateOptions(autoRemove: true, rootFsOverride: rootfs),
                    kernel: preparation.kernel
                )

                let process = try await self.client.bootstrap(
                    id: cid, stdio: [nil, nil, nil], dynamicEnv: dynamicEnv)
                try await process.start()

                try fhs.append(contentsOf: await self.client.logs(id: cid))

                try bundle.createLogFiles()
                let stdioLog = try FileHandle(forWritingTo: URL(filePath: bundle.stdioLog.string))
                let bootLog = try FileHandle(forWritingTo: URL(filePath: bundle.bootLog.string))

                state.logger = Task<Void, Never> { [log = self.log, id = state.id, fhs] in
                    defer {
                        try? fhs[0].close()
                        try? fhs[1].close()

                        try? stdioLog.close()
                        try? bootLog.close()
                    }

                    await withTaskGroup(of: Result<Void, Error>.self) { group in
                        for (from, to) in zip(fhs, [stdioLog, bootLog]) {
                            group.addTask {
                                do {
                                    try await Self.pipeFile(from: from, to: to)
                                    return .success(())
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }

                        for await result in group {
                            switch result {
                            case .success():
                                continue
                            case .failure(let error):
                                log.error(
                                    "log pipe failed",
                                    metadata: [
                                        "id": "\(id)",
                                        "error": "\(error)",
                                    ])
                            }
                        }
                    }
                }

                let generation = state.generation
                try await self.exitMonitor.registerProcess(
                    id: id,
                    onExit: { [weak self] id, status in
                        guard let self else {
                            return
                        }
                        await self.handleMachineExit(
                            id: id,
                            code: status,
                            generation: generation
                        )
                    }
                )

                // Monitor container exit in the background so we can update container machine state
                // when the backing container stops (e.g., VM crash, kill, etc.)
                try await self.exitMonitor.track(id: id) {
                    self.log.info("registering container machine with exit monitor")
                    let code = try await process.wait()
                    self.log.info(
                        "container machine exited in exit monitor",
                        metadata: ["id": "\(id)", "rc": "\(code)"]
                    )

                    return ExitStatus(exitCode: code)
                }

                let startedDate = Date()
                let initialized = bundle.initialized
                let logger = state.logger
                return try await self.lock.withLock { context in
                    var currentState = try await self.getMachineState(
                        id: id,
                        generation: generation,
                        context: context
                    )
                    currentState.logger = logger
                    Self.markMachineRunning(
                        &currentState,
                        containerID: cid,
                        startedDate: startedDate,
                        initialized: initialized
                    )
                    await self.setMachineState(id, currentState, context: context)
                    return currentState.snapshot
                }
            } catch {
                await self.exitMonitor.stopTracking(id: id)

                state.logger?.cancel()
                await state.logger?.value
                state.logger = nil

                for fileHandle in fhs {
                    try? fileHandle.close()
                }
                try? await self.client.delete(id: cid, force: true)

                throw error
            }
        }
    }

    public func stop(id: String) async throws {
        self.log.debug("\(#function)")

        let initialState = try self._getMachineState(id: id)
        try await initialState.lifecycleLock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            let state = try await self.lock.withLock { context in
                try await self.getMachineState(id: id, generation: initialState.generation, context: context)
            }

            switch state.snapshot.status {
            case .stopped:
                return
            case .running:
                break
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine \(id) is \(state.snapshot.status)"
                )
            }

            guard let cid = state.snapshot.containerId else {
                throw ContainerizationError(
                    .internalError,
                    message: "no container ID for running container machine"
                )
            }

            try await self.client.stop(id: cid, opts: ContainerStopOptions(timeoutInSeconds: 10, signal: nil))
            await self.finishMachineExit(id: id, code: nil, generation: initialState.generation)
        }
    }

    private func handleMachineExit(id: String, code: ExitStatus?, generation: UUID) async {
        guard let initialState = self.machines[id], initialState.generation == generation else {
            return
        }
        await initialState.lifecycleLock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            await self.finishMachineExit(id: id, code: code, generation: generation)
        }
    }

    private func finishMachineExit(id: String, code: ExitStatus?, generation: UUID) async {
        self.log.info(
            "container exited for container machine \(id)",
            metadata: ["status": "\(String(describing: code))"]
        )
        let result: (matched: Bool, logger: Task<Void, Never>?) = await self.lock.withLock { context in
            guard var state = try? await self.getMachineState(id: id, generation: generation, context: context) else {
                return (false, nil)
            }
            let logger = state.logger
            state.logger = nil
            Self.markMachineStopped(&state)
            await self.setMachineState(id, state, context: context)
            return (true, logger)
        }
        guard result.matched else {
            return
        }

        result.logger?.cancel()
        await result.logger?.value
        await self.exitMonitor.stopTracking(id: id)
    }

    public func inspect(id: String) async throws -> MachineSnapshot {
        self.log.debug("\(#function)")
        var snapshot = try self._getMachineState(id: id).snapshot
        let path = try self.bundlePath(id: id)
        let bundle = MachineBundle(path: path)
        snapshot.initialized = bundle.initialized
        snapshot.diskSize = bundle.diskSize
        if snapshot.status == .running, let cid = snapshot.containerId {
            do {
                let container = try await self.client.get(id: cid)
                snapshot.ipAddress = container.networks.first?.ipv4Address?.address.description
            } catch {
                self.log.warning("failed to fetch container address for \(cid): \(error)")
            }
        }
        return snapshot
    }

    // Get the logs for the container machine
    public func logs(id: String) async throws -> [FileHandle] {
        self.log.debug("\(#function)")

        do {
            _ = try _getMachineState(id: id)
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)
            return [
                try FileHandle(forReadingFrom: URL(filePath: bundle.stdioLog.string)),
                try FileHandle(forReadingFrom: URL(filePath: bundle.bootLog.string)),
            ]
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container machine logs: \(error)")
        }
    }
}

extension MachinesService {
    fileprivate struct ServiceState: Codable, Sendable {
        private var path: FilePath?

        public var defaultMachine: String?

        enum CodingKeys: String, CodingKey {
            case defaultMachine
        }

        public static func from(_ path: FilePath) throws -> ServiceState {
            var state: ServiceState

            let url = URL(filePath: path.string)
            do {
                let data = try Data(contentsOf: url)
                state = try JSONDecoder().decode(Self.self, from: data)
            } catch {
                state = ServiceState(defaultMachine: nil)
                try JSONEncoder().encode(state).write(to: url)
            }

            state.path = path
            return state
        }

        public mutating func setDefault(id: String?) throws {
            guard let path else {
                throw ContainerizationError(
                    .internalError,
                    message: "service state path is not set"
                )
            }

            self.defaultMachine = id
            let data = try JSONEncoder().encode(self)
            try data.write(to: URL(filePath: path.string), options: .atomic)
        }
    }
}

extension MachineBundle {
    func createLogFiles() throws {
        let bootLogFd = Darwin.open(self.bootLog.string, O_CREAT | O_RDONLY, 0o644)
        guard bootLogFd > 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        close(bootLogFd)

        let stdioLogFd = Darwin.open(self.stdioLog.string, O_CREAT | O_RDONLY, 0o644)
        guard stdioLogFd > 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        close(stdioLogFd)
    }
}

extension MachineConfiguration {
    fileprivate func toContainerConfig(
        cid: String,
        sbin: FilePath,
        initializedFile: FilePath,
        homeMountOption: MachineConfig.HomeMountOption,
        virtualization: Bool,
    ) async throws -> ContainerConfiguration {
        var config = ContainerConfiguration(
            id: cid,
            image: image,
            process: ProcessConfiguration(
                executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
                arguments: [],
                environment: processEnvironment,
                workingDirectory: "/",
                terminal: true,
                user: .id(uid: 0, gid: 0)
            )
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        config.mounts = [
            .virtiofs(
                source: sbin.string,
                destination: "/\(MachineBundle.sbinDirectory)",
                options: ["ro"]),
            .virtiofs(
                source: initializedFile.string,
                destination: "/etc/.\(MachineBundle.initializedFile)",
                options: ["rw"]),
        ]
        if homeMountOption != .none {
            config.mounts.append(
                .virtiofs(
                    source: home,
                    destination: home,
                    options: [homeMountOption.rawValue]
                )
            )
        }

        config.platform = platform
        config.labels = [
            ResourceLabelKeys.plugin: "machine"
        ]
        let domain = Self.defaultDNSDomain
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: [],
            domain: domain,
            searchDomains: [domain],
        )
        guard let defaultNetwork = try await NetworkClient().builtin else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        config.networks = [
            AttachmentConfiguration(
                network: defaultNetwork.id,
                options: AttachmentOptions(hostname: dnsHostname)
            )
        ]

        config.capAdd = ["ALL"]
        config.ssh = true
        config.virtualization = virtualization
        config.readonlyPaths = []
        config.maskedPaths = []

        config.rosetta = platform.architecture == "amd64" && Arch.hostArchitecture() == .arm64

        // Default to nil if image is not found, which defaults to send SIGTERM on stop
        let imageConfig = try? await ClientImage(description: image).config(for: platform).config
        config.stopSignal = imageConfig?.stopSignal

        return config
    }
}
