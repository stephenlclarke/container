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
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

/// A client for interacting with the container API server.
///
/// This client holds a reusable XPC connection and provides methods for
/// container lifecycle operations. All methods that operate on a specific
/// container take an `id` parameter.
public struct ContainerClient: Sendable {
    private static var serviceIdentifier: String {
        ContainerServiceNamespace.current.apiServerIdentifier
    }

    private let xpcClient: XPCClient

    /// Creates a new container client with a connection to the API server.
    public init() {
        self.xpcClient = XPCClient(service: Self.serviceIdentifier)
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = XPCClient.xpcRegistrationTimeout
    ) async throws -> XPCMessage {
        try await xpcClient.send(message, responseTimeout: timeout)
    }

    /// Create a new container with the given configuration.
    public func create(
        configuration: ContainerConfiguration,
        loggingRequest: ContainerLogRequest? = nil,
        options: ContainerCreateOptions = .default,
        kernel: Kernel,
        initImage: String? = nil,
        runtimeData: Data? = nil
    ) async throws {
        do {
            let request = XPCMessage(route: .containerCreate)

            let data = try JSONEncoder().encode(configuration)
            let kdata = try JSONEncoder().encode(kernel)
            let odata = try JSONEncoder().encode(options)
            request.set(key: .containerConfig, value: data)
            request.set(key: .kernel, value: kdata)
            request.set(key: .containerOptions, value: odata)

            if let loggingData = try Self.encodedLoggingRequest(loggingRequest) {
                request.set(key: .containerLogRequest, value: loggingData)
            }

            if let initImage {
                request.set(key: .initImage, value: initImage)
            }

            if let runtimeData {
                request.set(key: .runtimeData, value: runtimeData)
            }

            try await xpcSend(message: request)
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container",
                cause: error
            )
        }
    }

    /// Encodes the optional authority request independently from the legacy
    /// configuration field. Keeping this boundary narrow makes omission and
    /// transport-size behavior directly testable without opening an XPC
    /// connection.
    static func encodedLoggingRequest(_ loggingRequest: ContainerLogRequest?) throws -> Data? {
        guard let loggingRequest else {
            return nil
        }
        let loggingData = try JSONEncoder().encode(loggingRequest)
        guard loggingData.count <= ContainerLogRequest.maximumEncodedTransportBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "logging request exceeds the encoded byte limit"
            )
        }
        return loggingData
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        do {
            let request = XPCMessage(route: .containerList)
            let filterData = try JSONEncoder().encode(filters)
            request.set(key: .listFilters, value: filterData)

            let response = try await xpcSend(
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: .containers)
            guard let data else {
                return []
            }
            return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list containers",
                cause: error
            )
        }
    }

    /// Get the container for the provided id.
    public func get(id: String) async throws -> ContainerSnapshot {
        let containers = try await list(filters: ContainerListFilters(ids: [id]))
        guard let container = containers.first else {
            throw ContainerizationError(
                .notFound,
                message: "get failed: container \(id) not found"
            )
        }
        return container
    }

    /// Bootstrap the container's init process.
    public func bootstrap(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String] = [:]
    ) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerBootstrap)

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        do {
            let dynamicEnv = try JSONEncoder().encode(dynamicEnv)
            request.set(key: .dynamicEnv, value: dynamicEnv)

            request.set(key: .id, value: id)
            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: id, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container",
                cause: error
            )
        }
    }

    /// Attach standard streams to the init process of a running container.
    ///
    /// The provided descriptors belong to this client session. Closing them
    /// detaches the client without closing the container process's stdio.
    public func attach(id: String, stdio: [FileHandle?]) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerAttach)
        request.set(key: .id, value: id)

        for (i, handle) in stdio.enumerated() {
            let key: XPCKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()
            if let handle {
                request.set(key: key, value: handle)
            }
        }

        do {
            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: id, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to attach to container \(id)",
                cause: error
            )
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, signal: String) async throws {
        do {
            let request = XPCMessage(route: .containerKill)
            request.set(key: .id, value: id)
            request.set(key: .processIdentifier, value: id)
            request.set(key: .signal, value: signal)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container",
                cause: error
            )
        }
    }

    /// Stop the container and all processes currently executing inside.
    public func stop(id: String, opts: ContainerStopOptions = ContainerStopOptions.default) async throws {
        do {
            let request = XPCMessage(route: .containerStop)
            let data = try JSONEncoder().encode(opts)
            request.set(key: .id, value: id)
            request.set(key: .stopOptions, value: data)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Atomically restarts the container through its selected authority.
    public func restart(
        id: String,
        opts: ContainerStopOptions = ContainerStopOptions.default
    ) async throws {
        do {
            let request = XPCMessage(route: .containerRestart)
            request.set(key: .id, value: id)
            request.set(key: .stopOptions, value: try JSONEncoder().encode(opts))
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to restart container",
                cause: error
            )
        }
    }

    /// Pause a running container.
    public func pause(id: String) async throws {
        do {
            let request = XPCMessage(route: .containerPause)
            request.set(key: .id, value: id)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to pause container",
                cause: error
            )
        }
    }

    /// Resume a paused container.
    public func unpause(id: String) async throws {
        do {
            let request = XPCMessage(route: .containerUnpause)
            request.set(key: .id, value: id)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to unpause container",
                cause: error
            )
        }
    }

    /// Request a live workload-memory target without restarting the container.
    public func setMemoryTarget(id: String, memoryInBytes: UInt64) async throws {
        do {
            let request = XPCMessage(route: .containerSetMemoryTarget)
            request.set(key: .id, value: id)
            request.set(key: .memoryTargetInBytes, value: memoryInBytes)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to set memory target for container \(id)",
                cause: error
            )
        }
    }

    /// Returns the authoritative lifecycle v2 record.
    public func lifecycle(id: String) async throws -> ContainerLifecycleRecordV2 {
        let request = XPCMessage(route: .containerLifecycle)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)
        guard let data = reply.dataNoCopy(key: .lifecycleRecord) else {
            throw ContainerizationError(
                .internalError,
                message: "lifecycle response is missing its record"
            )
        }
        return try JSONDecoder().decode(ContainerLifecycleRecordV2.self, from: data)
    }

    /// Returns one coherent snapshot of every authoritative lifecycle v2 record.
    public func lifecycleRecords() async throws -> [ContainerLifecycleRecordV2] {
        let request = XPCMessage(route: .containerLifecycleList)
        let reply = try await xpcClient.send(request)
        guard let data = reply.dataNoCopy(key: .lifecycleRecords) else {
            throw ContainerizationError(
                .internalError,
                message: "lifecycle list response is missing its records"
            )
        }
        return try JSONDecoder().decode([ContainerLifecycleRecordV2].self, from: data)
    }

    /// Returns one atomic resource-and-lifecycle view for every matching container.
    public func lifecycleViews(
        filters: ContainerListFilters = .all
    ) async throws -> [ContainerLifecycleViewV2] {
        let request = XPCMessage(route: .containerLifecycleViewList)
        request.set(key: .listFilters, value: try JSONEncoder().encode(filters))
        let reply = try await xpcClient.send(request)
        guard let data = reply.dataNoCopy(key: .lifecycleViews) else {
            throw ContainerizationError(
                .internalError,
                message: "lifecycle view list response is missing its records"
            )
        }
        return try JSONDecoder().decode([ContainerLifecycleViewV2].self, from: data)
    }

    /// Delete the container along with any resources.
    public func delete(id: String, force: Bool = false) async throws {
        do {
            let request = XPCMessage(route: .containerDelete)
            request.set(key: .id, value: id)
            request.set(key: .forceDelete, value: force)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }

    /// Get the disk usage for a container.
    public func diskUsage(id: String) async throws -> UInt64 {
        let request = XPCMessage(route: .containerDiskUsage)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)

        let size = reply.uint64(key: .containerSize)
        return size
    }

    /// Create a new process inside a running container.
    /// The process is in a created state and must still be started.
    public func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        do {
            let request = XPCMessage(route: .containerCreateProcess)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: processId)

            let data = try JSONEncoder().encode(configuration)
            request.set(key: .processConfig, value: data)

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: containerId, processId: processId, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process in container",
                cause: error
            )
        }
    }

    /// Get the raw log file handles for a container.
    public func logs(id: String) async throws -> [FileHandle] {
        try await logs(id: id, options: .default, replay: .default)
    }

    /// Get the raw log file handles for a container.
    ///
    /// The returned handles contain bytes as stored. Options such as `tail`,
    /// `since`, and `until` are applied to timestamp-prefixed raw lines where
    /// possible; timestamp rendering is available through `logRecords(id:options:replay:)`.
    public func logs(
        id: String,
        options: ContainerLogOptions,
        replay: ContainerLogReplayOptions = .default
    ) async throws -> [FileHandle] {
        do {
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: id)
            if let tail = options.tail {
                request.set(key: .logTail, value: Int64(tail))
            }
            if let since = options.since {
                request.set(key: .logSince, value: since)
            }
            if let until = options.until {
                request.set(key: .logUntil, value: until)
            }
            request.set(key: .logIncludeRotated, value: replay.includeRotated)

            let response = try await xpcClient.send(request)
            let fds = response.fileHandles(key: .logs)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fds returned"
                )
            }
            return fds
        } catch let error as ContainerizationError where error.code == .unsupported {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get logs for container \(id)",
                cause: error
            )
        }
    }

    /// Follow the raw stdio log stream for a container.
    ///
    /// The returned handle starts with the requested replay window and then
    /// streams future bytes from local log storage, including bytes written
    /// after the active log file rotates. Use structured log record APIs for
    /// timestamp filters.
    public func followLogs(
        id: String,
        options: ContainerLogOptions = .default
    ) async throws -> FileHandle {
        do {
            let request = XPCMessage(route: .containerFollowLogs)
            request.set(key: .id, value: id)
            if let tail = options.tail {
                request.set(key: .logTail, value: Int64(tail))
            }
            if let since = options.since {
                request.set(key: .logSince, value: since)
            }
            if let until = options.until {
                request.set(key: .logUntil, value: until)
            }

            let response = try await xpcClient.send(request)
            guard let fd = response.fileHandles(key: .logs)?.first else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fd returned"
                )
            }
            return fd
        } catch let error as ContainerizationError where error.code == .unsupported {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to follow logs for container \(id)",
                cause: error
            )
        }
    }

    /// Get timestamped runtime log records for a container.
    ///
    /// Retrieval options are applied after runtime chunks are rebuilt into
    /// logical log lines. Returned records can therefore be split differently
    /// from the stored record boundaries when a filter selects a subset of a
    /// stored chunk.
    public func logRecords(
        id: String,
        options: ContainerLogOptions = .default,
        replay: ContainerLogReplayOptions = .default
    ) async throws -> [ContainerLogRecord] {
        do {
            let request = XPCMessage(route: .containerLogRecords)
            request.set(key: .id, value: id)
            if let tail = options.tail {
                request.set(key: .logTail, value: Int64(tail))
            }
            if let since = options.since {
                request.set(key: .logSince, value: since)
            }
            if let until = options.until {
                request.set(key: .logUntil, value: until)
            }
            request.set(key: .logIncludeRotated, value: replay.includeRotated)

            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .logRecords) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log records returned"
                )
            }
            return try JSONDecoder().decode([ContainerLogRecord].self, from: data)
        } catch let error as ContainerizationError where error.code == .unsupported {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get log records for container \(id)",
                cause: error
            )
        }
    }

    /// Follow timestamped runtime log records for a container.
    ///
    /// The returned stream contains newline-delimited `ContainerLogRecord`
    /// values after stored chunks are rebuilt into logical log lines. Retrieval
    /// options are therefore applied to Docker-style line output while the
    /// runtime still preserves the original stream and timestamp metadata.
    public func followLogRecords(
        id: String,
        options: ContainerLogOptions = .default
    ) async throws -> FileHandle {
        do {
            let request = XPCMessage(route: .containerFollowLogRecords)
            request.set(key: .id, value: id)
            if let tail = options.tail {
                request.set(key: .logTail, value: Int64(tail))
            }
            if let since = options.since {
                request.set(key: .logSince, value: since)
            }
            if let until = options.until {
                request.set(key: .logUntil, value: until)
            }

            let response = try await xpcClient.send(request)
            guard let fd = response.fileHandle(key: .logRecordFile) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log record file returned"
                )
            }
            return fd
        } catch let error as ContainerizationError where error.code == .unsupported {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to follow log records for container \(id)",
                cause: error
            )
        }
    }

    /// Get the timestamped log record file for a container.
    public func logRecordFile(id: String) async throws -> FileHandle {
        try await logRecordFile(id: id, replay: .default)
    }

    /// Stream a finite newline-delimited record file for a container.
    ///
    /// Rotated records are emitted oldest-first before the active file when
    /// requested, without collecting the complete history in one response.
    public func logRecordFile(
        id: String,
        replay: ContainerLogReplayOptions
    ) async throws -> FileHandle {
        do {
            let request = XPCMessage(route: .containerLogRecordFile)
            request.set(key: .id, value: id)
            request.set(key: .logIncludeRotated, value: replay.includeRotated)

            let response = try await xpcClient.send(request)
            guard let fd = response.fileHandle(key: .logRecordFile) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log record file returned"
                )
            }
            return fd
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get log record file for container \(id)",
                cause: error
            )
        }
    }

    /// Incrementally decode a finite timestamped log-record stream.
    ///
    /// The underlying file descriptor is consumed in bounded chunks and each
    /// newline-delimited record is decoded only when requested by the caller.
    public func logRecordStream(
        id: String,
        replay: ContainerLogReplayOptions = .default
    ) async throws -> AsyncThrowingStream<ContainerLogRecord, any Error> {
        let file = try await logRecordFile(id: id, replay: replay)
        return Self.logRecordStream(file: file)
    }

    static func logRecordStream(
        file: FileHandle
    ) -> AsyncThrowingStream<ContainerLogRecord, any Error> {
        let reader = ContainerLogRecordFileReader(file: file)
        return AsyncThrowingStream(
            unfolding: {
                try await reader.next()
            }
        )
    }

    /// Stream lifecycle events emitted by the API server.
    ///
    /// The returned handle contains newline-delimited `ContainerEvent` JSON
    /// values. The stream remains open until the caller closes the handle or
    /// the API server stops.
    public func events(options: ContainerEventOptions = .default) async throws -> FileHandle {
        do {
            let request = XPCMessage(route: .containerEvent)
            if let since = options.since {
                request.set(key: .eventSince, value: since)
            }
            if let until = options.until {
                request.set(key: .eventUntil, value: until)
            }
            let response = try await xpcClient.send(request)
            guard let fd = response.fileHandle(key: .containerEvent) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no event file returned"
                )
            }
            return fd
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stream container events",
                cause: error
            )
        }
    }

    /// Dial a port on the container via vsock.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: .containerDial)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))

        let response: XPCMessage
        do {
            response = try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial port \(port) on container",
                cause: error
            )
        }
        guard let fh = response.fileHandle(key: .fd) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    /// Copy a file or directory from the host into the container.
    public func copyIn(
        id: String, source: String, destination: String, mode: UInt32 = 0o644, createParents: Bool = true, followSymlink: Bool = false, preserveOwnership: Bool = false
    ) async throws {
        let request = XPCMessage(route: .containerCopyIn)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .fileMode, value: UInt64(mode))
        request.set(key: .createParents, value: createParents)
        request.set(key: .followSymlink, value: followSymlink)
        request.set(key: .preserveOwnership, value: preserveOwnership)

        do {
            try await xpcSend(message: request, timeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy into container \(id)",
                cause: error
            )
        }
    }

    /// Stream a tar archive from the host into a container directory.
    public func copyIn(
        id: String,
        archive: FileHandle,
        destination: String,
        createParents: Bool = true,
        preserveOwnership: Bool = false
    ) async throws {
        let request = XPCMessage(route: .containerCopyIn)
        request.set(key: .id, value: id)
        request.set(key: .copyArchive, value: archive)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .createParents, value: createParents)
        request.set(key: .preserveOwnership, value: preserveOwnership)

        do {
            try await xpcSend(message: request, timeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stream archive into container \(id)",
                cause: error
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    public func copyOut(id: String, source: String, destination: String, createParents: Bool = true, followSymlink: Bool = false, preserveOwnership: Bool = false) async throws {
        let request = XPCMessage(route: .containerCopyOut)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .createParents, value: createParents)
        request.set(key: .followSymlink, value: followSymlink)
        request.set(key: .preserveOwnership, value: preserveOwnership)

        do {
            try await xpcSend(message: request, timeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy from container \(id)",
                cause: error
            )
        }
    }

    /// Stream a container path to the host as an uncompressed tar archive.
    public func copyOut(
        id: String,
        source: String,
        archive: FileHandle,
        followSymlink: Bool = false,
        copyContents: Bool = false
    ) async throws {
        let request = XPCMessage(route: .containerCopyOut)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .copyArchive, value: archive)
        request.set(key: .followSymlink, value: followSymlink)
        request.set(key: .copyContents, value: copyContents)

        do {
            try await xpcSend(message: request, timeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stream archive from container \(id)",
                cause: error
            )
        }
    }

    /// Get resource usage statistics for a container.
    public func stats(id: String) async throws -> ContainerStats {
        let request = XPCMessage(route: .containerStats)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .statistics) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no statistics data returned"
                )
            }
            return try JSONDecoder().decode(ContainerStats.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get statistics for container \(id)",
                cause: error
            )
        }
    }

    /// Get process information currently associated with a container.
    public func processes(id: String) async throws -> ContainerProcesses {
        let request = XPCMessage(route: .containerProcesses)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .processes) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no process data returned"
                )
            }
            return try JSONDecoder().decode(ContainerProcesses.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get processes for container \(id)",
                cause: error
            )
        }
    }

    /// Exports a container filesystem, optionally from a running container.
    ///
    /// A live export freezes the guest filesystem by default. `noFreeze` is
    /// intentionally best-effort: it creates an APFS copy-on-write clone while
    /// the guest keeps writing, so the resulting image is not guaranteed to be
    /// filesystem or application consistent. This matches Docker's documented
    /// `commit --pause=false` trade-off.
    public func export(id: String, archive: URL, live: Bool = false, noFreeze: Bool = false) async throws {
        let request = XPCMessage(route: .containerExport)
        request.set(key: .id, value: id)
        request.set(key: .archive, value: archive.absolutePath())
        request.set(key: .live, value: live)
        request.set(key: .noFreeze, value: noFreeze)

        do {
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to export container",
                cause: error
            )
        }
    }
}

private actor ContainerLogRecordFileReader {
    private static let readChunkBytes = 64 * 1_024

    private let file: FileHandle
    private var buffer = Data()
    private var ended = false

    init(file: FileHandle) {
        self.file = file
    }

    deinit {
        try? file.close()
    }

    func next() async throws -> ContainerLogRecord? {
        guard !ended else {
            return nil
        }
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard
                    newline
                        <= ContainerLogReadRecordWireV1
                        .maximumEncodedRecordBytes
                else {
                    throw invalidRecordStream("record exceeds the transport limit")
                }
                let encoded = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !encoded.isEmpty else {
                    continue
                }
                do {
                    return try JSONDecoder().decode(
                        ContainerLogRecord.self,
                        from: encoded
                    )
                } catch {
                    throw invalidRecordStream("record is not valid JSON")
                }
            }
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
            else {
                throw invalidRecordStream("record exceeds the transport limit")
            }
            let file = self.file
            let chunk = try await Task.detached(priority: .utility) {
                try file.read(upToCount: Self.readChunkBytes) ?? Data()
            }.value
            if chunk.isEmpty {
                guard buffer.isEmpty else {
                    throw invalidRecordStream("stream ended with a partial record")
                }
                ended = true
                try? file.close()
                return nil
            }
            buffer.append(chunk)
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
                    + Self.readChunkBytes
            else {
                throw invalidRecordStream("record exceeds the transport limit")
            }
        }
    }

    private func invalidRecordStream(_ reason: String) -> ContainerizationError {
        ended = true
        try? file.close()
        return ContainerizationError(
            .internalError,
            message: "invalid container log record stream: \(reason)"
        )
    }
}
