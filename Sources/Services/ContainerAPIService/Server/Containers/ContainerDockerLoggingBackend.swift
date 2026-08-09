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
import ContainerEngineLogging
import ContainerEngineWire
import ContainerLoggingProviders
import ContainerLoggingStorage
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation

actor ContainerDockerImageResourceCache {
    typealias ImageProvider = @Sendable () async throws -> [ClientImage]
    typealias VisibilityProvider = @Sendable (ClientImage) throws -> Bool
    typealias ResourceProvider = @Sendable (ClientImage) async throws -> ImageResource

    private struct InventoryEntry: Equatable {
        let reference: String
        let digest: String
    }

    private let imageProvider: ImageProvider
    private let isVisible: VisibilityProvider
    private let resourceProvider: ResourceProvider
    private var inventory = [InventoryEntry]()
    private var resources = [ImageResource]()

    init(containerSystemConfig: ContainerSystemConfig) {
        imageProvider = { try await ClientImage.list() }
        isVisible = {
            try !Utility.isInfraImage(
                name: $0.description.reference,
                containerSystemConfig: containerSystemConfig
            )
        }
        resourceProvider = {
            try await $0.toImageResource(
                containerSystemConfig: containerSystemConfig,
                for: .current
            )
        }
    }

    init(
        imageProvider: @escaping ImageProvider,
        isVisible: @escaping VisibilityProvider,
        resourceProvider: @escaping ResourceProvider
    ) {
        self.imageProvider = imageProvider
        self.isVisible = isVisible
        self.resourceProvider = resourceProvider
    }

    func currentResources() async throws -> [ImageResource] {
        let images = try await imageProvider().filter(isVisible)
        let currentInventory = images.map {
            InventoryEntry(
                reference: $0.description.reference,
                digest: $0.description.descriptor.digest
            )
        }.sorted {
            if $0.reference != $1.reference {
                return $0.reference.utf8.lexicographicallyPrecedes($1.reference.utf8)
            }
            return $0.digest.utf8.lexicographicallyPrecedes($1.digest.utf8)
        }
        if currentInventory == inventory {
            return resources
        }

        var refreshed = [ImageResource]()
        for image in images {
            refreshed.append(try await resourceProvider(image))
        }
        inventory = currentInventory
        resources = refreshed
        return refreshed
    }
}

struct ContainerEngineLoggingInspection: Sendable {
    let driver: String
    let options: [String: String]
    let publicLogPath: String?
    let terminal: Bool
}

struct ContainerEngineAttachmentInspection: Sendable {
    let snapshot: ContainerSnapshot
    let terminal: Bool
    let restarting: Bool
}

struct ContainerEngineInspectBase: Sendable {
    let snapshot: ContainerSnapshot
    let options: ContainerCreateOptions
    let runtimeData: Data?
    let stateError: String
}

enum ContainerEngineLogReadSource: Sendable {
    case direct(reader: any ContainerLogReader, terminal: Bool)
    case activeWire(file: FileHandle, terminal: Bool)
}

/// Projects the authority-owned Container logging controller onto the neutral
/// Docker Engine logging backend. It never opens a second catalog, store, or
/// provider session and therefore cannot diverge from native clients.
public struct ContainerDockerLoggingBackend:
    DockerContainerLifecycleBackend,
    DockerContainerWaitBackend,
    DockerLoggingBackend,
    DockerTerminalResizeBackend,
    Sendable
{
    let containers: ContainersService
    let engineIdentity: String
    let serverVersion: String
    let imageCountProvider: @Sendable () async throws -> Int
    let imageResourceProvider: @Sendable () async throws -> [ImageResource]
    let imagePullProvider: @Sendable (DockerImagePullRequest) async throws -> DockerImagePullResult
    let imageTagProvider: @Sendable (String, DockerImageTagRequest) async throws -> Void
    let imageDeleteProvider: @Sendable (String, DockerImageDeleteRequest) async throws -> [DockerImageDeleteResult]

    public init(
        containers: ContainersService,
        engineIdentity: String = "container",
        serverVersion: String = "unknown",
        containerSystemConfig: ContainerSystemConfig = .init(),
        imageCountProvider: (@Sendable () async throws -> Int)? = nil,
        imageResourceProvider: (@Sendable () async throws -> [ImageResource])? = nil,
        imagePullProvider: (
            @Sendable (DockerImagePullRequest) async throws -> DockerImagePullResult
        )? = nil,
        imageTagProvider: (
            @Sendable (String, DockerImageTagRequest) async throws -> Void
        )? = nil,
        imageDeleteProvider: (
            @Sendable (String, DockerImageDeleteRequest) async throws -> [DockerImageDeleteResult]
        )? = nil
    ) {
        let imageResourceCache = ContainerDockerImageResourceCache(
            containerSystemConfig: containerSystemConfig
        )
        let authoritativeImageResources =
            imageResourceProvider ?? {
                try await imageResourceCache.currentResources()
            }
        self.containers = containers
        self.engineIdentity = engineIdentity
        self.serverVersion = serverVersion
        self.imageResourceProvider = authoritativeImageResources
        self.imagePullProvider =
            imagePullProvider ?? {
                try await Self.pullImage(
                    request: $0,
                    containerSystemConfig: containerSystemConfig
                )
            }
        self.imageTagProvider =
            imageTagProvider ?? {
                try await Self.tagImage(
                    name: $0,
                    request: $1,
                    containerSystemConfig: containerSystemConfig
                )
            }
        self.imageDeleteProvider =
            imageDeleteProvider ?? {
                try await Self.deleteImage(
                    name: $0,
                    request: $1,
                    containerSystemConfig: containerSystemConfig
                )
            }
        self.imageCountProvider =
            imageCountProvider ?? {
                var count = 0
                for image in try await ClientImage.list() {
                    if try !Utility.isInfraImage(
                        name: image.description.reference,
                        containerSystemConfig: containerSystemConfig
                    ) {
                        count += 1
                    }
                }
                return count
            }
    }

    public func loggingSystemInfo() async throws -> DockerLoggingSystemInfo {
        do {
            let info = try await containers.engineLoggingSystemInfo()
            return DockerLoggingSystemInfo(
                defaultDriver: info.defaultDriver,
                registeredDrivers: info.registeredDrivers
            )
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

    private func resolveDockerContainerID(_ identifier: String) async throws -> String {
        do {
            return try await containers.resolveDockerContainerIdentifier(identifier)
        } catch {
            throw Self.map(error, containerID: identifier)
        }
    }

    public func createContainer(
        request: DockerContainerCreateRequest,
        requestedName: String?
    ) async throws -> DockerContainerCreateResult {
        do {
            try Self.validateDockerSyslogUnixSocket(request)
            let containerID = try await containers.createDockerContainer(
                request: request,
                requestedName: requestedName
            )
            return DockerContainerCreateResult(containerID: containerID)
        } catch {
            throw Self.map(error, containerID: requestedName)
        }
    }

    /// Docker stats Unix Syslog endpoints during `POST /containers/create`.
    /// Keep this validation in the Docker boundary so a rejected create never
    /// reaches the native authority or leaves a partially persisted container.
    static func validateDockerSyslogUnixSocket(
        _ request: DockerContainerCreateRequest,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) throws {
        guard
            let logging = request.hostConfiguration?.logConfiguration,
            logging.type == "syslog",
            let address = logging.options?["syslog-address"],
            let components = URLComponents(string: address),
            components.scheme == "unix" || components.scheme == "unixgram",
            !components.percentEncodedPath.isEmpty,
            let path = components.percentEncodedPath.removingPercentEncoding,
            !fileExists(path)
        else {
            return
        }
        throw DockerLoggingBackendError.server(
            "failed to create task for container: failed to initialize logging driver: stat \(path): no such file or directory"
        )
    }

    public func startContainer(containerID: String) async throws {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            try await containers.bootstrap(
                id: resolvedID,
                stdio: [nil, nil, nil],
                dynamicEnv: [:]
            )
            try await containers.startProcess(
                id: resolvedID,
                processID: resolvedID
            )
        } catch {
            let mapped = Self.map(error, containerID: containerID)
            await containers.recordDockerStartError(
                containerID: resolvedID,
                error: mapped.message
            )
            throw mapped
        }
    }

    public func stopContainer(
        containerID: String,
        timeoutSeconds: Int64?
    ) async throws {
        let resolvedID = try await resolveDockerContainerID(containerID)
        let timeout = timeoutSeconds.flatMap { Int32(exactly: $0) }
        if timeoutSeconds != nil, timeout == nil {
            throw DockerLoggingBackendError.invalidParameter(
                "stop timeout exceeds the runtime range"
            )
        }
        do {
            try await containers.stop(
                id: resolvedID,
                options: ContainerStopOptions(
                    timeoutInSeconds: timeout,
                    signal: nil
                )
            )
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func deleteContainer(
        containerID: String,
        force: Bool,
        removeVolumes _: Bool
    ) async throws {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            try await containers.delete(id: resolvedID, force: force)
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func waitForContainer(
        containerID: String,
        condition: DockerContainerWaitCondition
    ) async throws -> DockerContainerWaitResult {
        try await waitForContainer(
            containerID: containerID,
            condition: condition,
            onRegistered: {}
        )
    }

    public func waitForContainer(
        containerID: String,
        condition: DockerContainerWaitCondition,
        onRegistered: @escaping @Sendable () -> Void
    ) async throws -> DockerContainerWaitResult {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            return try await containers.waitForDockerContainer(
                id: resolvedID,
                condition: condition,
                onRegistered: onRegistered
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            let inspection = try await containers.engineLoggingInspection(
                containerID: resolvedID
            )
            return DockerContainerLoggingInspection(
                configuration: DockerResolvedLogConfiguration(
                    driver: inspection.driver,
                    options: inspection.options
                ),
                publicLogPath: inspection.publicLogPath,
                terminal: inspection.terminal
            )
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func openContainerLogs(
        containerID: String,
        request: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            let source = try await containers.engineLogReadSource(
                containerID: resolvedID,
                request: try Self.containerRequest(request)
            )
            switch source {
            case .direct(let reader, let terminal):
                return DirectDockerLogReadSession(
                    reader: reader,
                    terminal: terminal
                )
            case .activeWire(let file, let terminal):
                return WireDockerLogReadSession(
                    file: file,
                    terminal: terminal
                )
            }
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func attachContainer(
        containerID: String,
        request: DockerAttachRequest
    ) async throws -> DockerAttachConnection {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            let inspection = try await containers.engineAttachmentInspection(
                containerID: resolvedID
            )
            try Self.validateAttachState(
                containerID: containerID,
                status: inspection.snapshot.status,
                restarting: inspection.restarting
            )
            let outputRequested = request.stdout || request.stderr
            let detachKeys =
                request.stdin
                ? try DetachKeySequence(request.detachKeys ?? "ctrl-p,ctrl-q")
                : nil

            let logReader: (any DockerLogReadSession)?
            if request.includeLogs, outputRequested {
                do {
                    logReader = try await openContainerLogs(
                        containerID: resolvedID,
                        request: DockerLogReadRequest(
                            stdout: request.stdout,
                            stderr: request.stderr,
                            follow: request.stream,
                            tail: nil,
                            since: nil,
                            until: nil,
                            timestamps: false,
                            details: false
                        )
                    )
                } catch DockerLoggingBackendError.unsupportedLogReader {
                    // Docker keeps attach usable for `none` and other
                    // unreadable drivers. There is no history in that case,
                    // but the exact process output remains attachable.
                    logReader = nil
                }
            } else {
                logReader = nil
            }

            let runtimePlan = ContainerDockerRuntimeAttachPlan(
                request: request,
                terminal: inspection.terminal,
                hasLogReader: logReader != nil
            )
            let pipes: ContainerDockerRuntimeAttachPipes
            do {
                pipes = try await attachRuntime(
                    containerID: resolvedID,
                    terminal: inspection.terminal,
                    input: runtimePlan.input,
                    stdout: runtimePlan.stdout,
                    stderr: runtimePlan.stderr
                )
            } catch {
                if let logReader {
                    await logReader.cancel()
                }
                throw error
            }

            let session = ContainerDockerAttachSession(
                input: pipes.input,
                runtimeOutputs: pipes.outputs,
                logReader: logReader,
                detachKeySequence: detachKeys?.bytes,
                waitForProcess: runtimePlan.input && pipes.outputs.isEmpty,
                processWait: { [containers] in
                    try await containers.wait(
                        id: resolvedID,
                        processID: resolvedID
                    ).exitCode
                },
                onDetach: { [containers, snapshot = inspection.snapshot] in
                    await containers.publishEngineDetachEvent(snapshot: snapshot)
                }
            )
            await containers.publishEngineAttachEvent(
                snapshot: inspection.snapshot
            )
            await session.start()
            return DockerAttachConnection(
                terminal: inspection.terminal,
                session: session
            )
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func resizeContainerTerminal(
        containerID: String,
        height: UInt32,
        width: UInt32
    ) async throws {
        let resolvedID = try await resolveDockerContainerID(containerID)
        do {
            let inspection = try await containers.engineAttachmentInspection(
                containerID: resolvedID
            )
            try await containers.resize(
                id: resolvedID,
                processID: resolvedID,
                size: Self.terminalSize(height: height, width: width)
            )
            await containers.publishEngineResizeEvent(
                snapshot: inspection.snapshot,
                height: height,
                width: width
            )
        } catch let error as ContainerizationError
            where error.code == .invalidState
        {
            throw DockerLoggingBackendError.conflict(
                "container \(containerID) is not running"
            )
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    static func terminalSize(height: UInt32, width: UInt32) -> Terminal.Size {
        Terminal.Size(
            width: UInt16(truncatingIfNeeded: width),
            height: UInt16(truncatingIfNeeded: height)
        )
    }

    static func validateAttachState(
        containerID: String,
        status: RuntimeStatus,
        restarting: Bool
    ) throws {
        // Moby rejects restarting and paused containers before opening a log
        // reader or runtime pipe. It permits stopped and stopping containers
        // so their retained output can still be replayed.
        if restarting {
            throw DockerLoggingBackendError.conflict(
                "container \(containerID) is restarting, wait until the container is running"
            )
        }
        guard status != .paused else {
            throw DockerLoggingBackendError.conflict(
                "container \(containerID) is paused, unpause the container before attach"
            )
        }
    }

    private func attachRuntime(
        containerID: String,
        terminal: Bool,
        input: Bool,
        stdout: Bool,
        stderr: Bool
    ) async throws -> ContainerDockerRuntimeAttachPipes {
        guard input || stdout || stderr else {
            return ContainerDockerRuntimeAttachPipes()
        }
        let inputPipe = input ? Pipe() : nil
        let stdoutPipe = stdout ? Pipe() : nil
        let stderrPipe = stderr && !terminal ? Pipe() : nil
        let serviceHandles = [
            inputPipe?.fileHandleForReading,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForWriting,
        ]
        do {
            let bootstrapped = try await containers.bootstrapForAttach(
                id: containerID,
                stdio: serviceHandles,
                dynamicEnv: [:]
            )
            if !bootstrapped {
                try await containers.attach(
                    id: containerID,
                    stdio: serviceHandles
                )
            }
        } catch {
            for handle in serviceHandles.compactMap({ $0 }) {
                try? handle.close()
            }
            try? inputPipe?.fileHandleForWriting.close()
            try? stdoutPipe?.fileHandleForReading.close()
            try? stderrPipe?.fileHandleForReading.close()
            throw error
        }
        // Runtime XPC owns duplicates after attach returns. Closing the local
        // service ends makes EOF and detach depend only on the live runtime.
        for handle in serviceHandles.compactMap({ $0 }) {
            try? handle.close()
        }
        var outputs = [(DockerStreamChannel, FileHandle)]()
        if let stdoutPipe {
            outputs.append((.standardOutput, stdoutPipe.fileHandleForReading))
        }
        if let stderrPipe {
            outputs.append((.standardError, stderrPipe.fileHandleForReading))
        }
        return ContainerDockerRuntimeAttachPipes(
            input: inputPipe?.fileHandleForWriting,
            outputs: outputs
        )
    }

    private static func containerRequest(
        _ request: DockerLogReadRequest
    ) throws -> ContainerLogReadRequest {
        try ContainerLogReadRequest(
            stdout: request.stdout,
            stderr: request.stderr,
            follow: request.follow,
            tail: request.tail,
            since: request.since.map(Self.date),
            until: request.until.map(Self.date),
            timestamps: request.timestamps,
            details: request.details
        )
    }

    private static func date(_ timestamp: DockerLogTimestamp) -> Date {
        Date(
            timeIntervalSince1970:
                Double(timestamp.secondsSinceUnixEpoch)
                + Double(timestamp.nanoseconds) / 1_000_000_000
        )
    }

    static func map(
        _ error: any Error,
        containerID: String?
    ) -> DockerLoggingBackendError {
        if let error = error as? DockerLoggingBackendError {
            return error
        }
        if case .connectionFailed(let endpoint, let reason) = error as? GELFProviderError {
            return .server(
                "failed to create task for container: failed to initialize logging driver: gelf: cannot connect to GELF endpoint: \(endpoint.host):\(endpoint.port) \(reason)"
            )
        }
        if (error as? FluentdProviderError) == .tlsTrustVerificationFailed
            || (error as? SyslogProviderError) == .tlsTrustVerificationFailed
        {
            return .server(
                "failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority"
            )
        }
        if let error = error as? ContainerizationError {
            switch error.code {
            case .notFound:
                return .containerNotFound(containerID ?? "")
            case .exists:
                return .conflict(error.message)
            case .invalidArgument:
                return .invalidParameter(error.message)
            case .invalidState:
                return .conflict(error.message)
            default:
                return .server("container logging operation failed")
            }
        }
        if let error = error as? ContainerLogReaderError {
            switch error {
            case .configuredDriverDoesNotSupportReading:
                return .unsupportedLogReader
            case .activeReaderRequired:
                return .conflict("active container logging reader is required")
            default:
                return .server("container logging reader failed")
            }
        }
        if let error = error as? ContainerLogNativeReaderFactoryError {
            switch error {
            case .providerReaderRequired:
                return .unsupportedLogReader
            default:
                return .server("container logging reader failed")
            }
        }
        if error is LogDriverLifecycleContractError {
            return .invalidParameter("invalid logging request")
        }
        return .server("container logging operation failed")
    }
}

struct ContainerDockerRuntimeAttachPlan: Equatable, Sendable {
    let input: Bool
    let stdout: Bool
    let stderr: Bool

    init(
        request: DockerAttachRequest,
        terminal: Bool,
        hasLogReader: Bool
    ) {
        input = request.stdin && request.stream
        let runtimeOutput =
            request.stream && !hasLogReader
            && (request.stdout || request.stderr)
        stdout = runtimeOutput && request.stdout
        stderr = runtimeOutput && request.stderr && !terminal
    }
}

private struct ContainerDockerRuntimeAttachPipes {
    var input: FileHandle?
    var outputs: [(DockerStreamChannel, FileHandle)]

    init(
        input: FileHandle? = nil,
        outputs: [(DockerStreamChannel, FileHandle)] = []
    ) {
        self.input = input
        self.outputs = outputs
    }
}

private struct DockerDetachInputFilter {
    let sequence: [UInt8]
    private var pending = [UInt8]()

    init?(sequence: [UInt8]?) {
        guard let sequence, !sequence.isEmpty else {
            return nil
        }
        self.sequence = sequence
    }

    mutating func consume(_ data: Data) -> (forwarded: Data, detached: Bool) {
        var forwarded = [UInt8]()
        for byte in data {
            pending.append(byte)
            while !sequence.starts(with: pending) {
                forwarded.append(pending.removeFirst())
            }
            if pending == sequence {
                pending.removeAll(keepingCapacity: false)
                return (Data(forwarded), true)
            }
        }
        return (Data(forwarded), false)
    }

    mutating func finish() -> Data {
        defer { pending.removeAll(keepingCapacity: false) }
        return Data(pending)
    }
}

private enum ContainerDockerAttachSessionError: Error {
    case inputUnavailable
    case outputBufferTerminated
}

/// Bridges one Engine hijack to exact-process runtime pipes or the canonical
/// replay/follow reader. Its bounded frame stream retries a full buffer instead
/// of dropping output, so a slow Engine client applies backpressure without an
/// unbounded host allocation.
actor ContainerDockerAttachSession: DockerHijackSession {
    nonisolated let frames: AsyncThrowingStream<DockerStreamFrame, any Error>

    private static let maximumBufferedFrames = 256

    private let continuation:
        AsyncThrowingStream<
            DockerStreamFrame,
            any Error
        >.Continuation
    private let input: FileHandle?
    private let runtimeOutputs: [(DockerStreamChannel, FileHandle)]
    private let logReader: (any DockerLogReadSession)?
    private let waitForProcess: Bool
    private let processWait: @Sendable () async throws -> Int32
    private let onDetach: @Sendable () async -> Void

    private var detachFilter: DockerDetachInputFilter?
    private var tasks = [Task<Void, Never>]()
    private var remainingSources = 0
    private var started = false
    private var finished = false
    private var logReaderFinished = false
    private var terminalExitCode: Int32?
    private var terminalError: (any Error)?
    private var waiters = [CheckedContinuation<Int32, any Error>]()

    init(
        input: FileHandle?,
        runtimeOutputs: [(DockerStreamChannel, FileHandle)],
        logReader: (any DockerLogReadSession)?,
        detachKeySequence: [UInt8]?,
        waitForProcess: Bool,
        processWait: @escaping @Sendable () async throws -> Int32,
        onDetach: @escaping @Sendable () async -> Void
    ) {
        var streamContinuation:
            AsyncThrowingStream<
                DockerStreamFrame,
                any Error
            >.Continuation?
        frames = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedFrames)
        ) { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!
        self.input = input
        self.runtimeOutputs = runtimeOutputs
        self.logReader = logReader
        detachFilter = DockerDetachInputFilter(
            sequence: detachKeySequence
        )
        self.waitForProcess = waitForProcess
        self.processWait = processWait
        self.onDetach = onDetach
    }

    func start() async {
        guard !started, !finished else {
            return
        }
        started = true
        remainingSources = runtimeOutputs.count + (logReader == nil ? 0 : 1)
        for (channel, handle) in runtimeOutputs {
            startRuntimePump(channel: channel, handle: handle)
        }
        if let logReader {
            startLogPump(reader: logReader)
        }
        if remainingSources == 0 {
            if waitForProcess {
                startProcessWait()
            } else {
                await finish(exitCode: 0)
            }
        }
    }

    func write(_ data: Data) async throws {
        guard !finished else {
            throw ContainerDockerAttachSessionError.outputBufferTerminated
        }
        guard let input else {
            throw ContainerDockerAttachSessionError.inputUnavailable
        }
        let filtered: (forwarded: Data, detached: Bool)
        if var detachFilter {
            filtered = detachFilter.consume(data)
            self.detachFilter = detachFilter
        } else {
            filtered = (data, false)
        }
        if !filtered.forwarded.isEmpty {
            try await Self.write(filtered.forwarded, to: input)
        }
        if filtered.detached {
            await finish(exitCode: 0)
        }
    }

    func closeStandardInput() async throws {
        guard !finished else {
            return
        }
        if var detachFilter {
            let pending = detachFilter.finish()
            self.detachFilter = detachFilter
            if !pending.isEmpty, let input {
                try await Self.write(pending, to: input)
            }
        }
        try? input?.close()
    }

    func wait() async throws -> Int32 {
        if let terminalError {
            throw terminalError
        }
        if let terminalExitCode {
            return terminalExitCode
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func cancel() async {
        await finish(exitCode: 0)
    }

    private func startRuntimePump(
        channel: DockerStreamChannel,
        handle: FileHandle
    ) {
        guard !finished else {
            try? handle.close()
            return
        }
        handle.readabilityHandler = { [weak self] readable in
            readable.readabilityHandler = nil
            let data = readable.availableData
            Task { [weak self] in
                await self?.receiveRuntimeData(
                    data,
                    channel: channel,
                    handle: readable
                )
            }
        }
    }

    private func receiveRuntimeData(
        _ data: Data,
        channel: DockerStreamChannel,
        handle: FileHandle
    ) async {
        guard !finished else {
            try? handle.close()
            return
        }
        guard !data.isEmpty else {
            await sourceEnded()
            return
        }
        do {
            guard
                try await emit(
                    DockerStreamFrame(channel: channel, data: data)
                )
            else {
                return
            }
            startRuntimePump(channel: channel, handle: handle)
        } catch {
            await sourceFailed(error)
        }
    }

    private func startLogPump(reader: any DockerLogReadSession) {
        let task = Task { [weak self] in
            do {
                while !Task.isCancelled, let record = try await reader.nextRecord() {
                    let channel: DockerStreamChannel =
                        record.source
                            == .standardOutput ? .standardOutput : .standardError
                    guard
                        try await self?.emit(
                            DockerStreamFrame(
                                channel: channel,
                                data: record.line
                            )
                        ) == true
                    else {
                        return
                    }
                }
                await reader.close()
                await self?.logSourceEnded()
            } catch {
                await reader.cancel()
                await self?.logSourceFailed(error)
            }
        }
        tasks.append(task)
    }

    private func startProcessWait() {
        let task = Task { [weak self, processWait] in
            do {
                await self?.finish(exitCode: try await processWait())
            } catch {
                await self?.sourceFailed(error)
            }
        }
        tasks.append(task)
    }

    private func emit(_ frame: DockerStreamFrame) async throws -> Bool {
        while !finished, !Task.isCancelled {
            switch continuation.yield(frame) {
            case .enqueued:
                return true
            case .dropped:
                try await Task.sleep(for: .milliseconds(1))
            case .terminated:
                throw ContainerDockerAttachSessionError.outputBufferTerminated
            @unknown default:
                throw ContainerDockerAttachSessionError.outputBufferTerminated
            }
        }
        return false
    }

    private func sourceEnded() async {
        guard !finished else {
            return
        }
        remainingSources -= 1
        if remainingSources == 0 {
            await finish(exitCode: 0)
        }
    }

    private func sourceFailed(_ error: any Error) async {
        guard !finished else {
            return
        }
        await finish(error: error)
    }

    private func logSourceEnded() async {
        logReaderFinished = true
        await sourceEnded()
    }

    private func logSourceFailed(_ error: any Error) async {
        logReaderFinished = true
        await sourceFailed(error)
    }

    private func finish(exitCode: Int32) async {
        await finish(exitCode: exitCode, error: nil)
    }

    private func finish(error: any Error) async {
        await finish(exitCode: nil, error: error)
    }

    private func finish(
        exitCode: Int32?,
        error: (any Error)?
    ) async {
        guard !finished else {
            return
        }
        finished = true
        terminalExitCode = exitCode
        terminalError = error
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll(keepingCapacity: false)
        try? input?.close()
        for (_, handle) in runtimeOutputs {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        if let logReader, !logReaderFinished {
            logReaderFinished = true
            await logReader.cancel()
        }
        if let error {
            continuation.finish(throwing: error)
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
        } else {
            let exitCode = exitCode ?? 0
            continuation.finish()
            for waiter in waiters {
                waiter.resume(returning: exitCode)
            }
        }
        waiters.removeAll(keepingCapacity: false)
        await onDetach()
    }

    private nonisolated static func write(
        _ data: Data,
        to handle: FileHandle
    ) async throws {
        try await Task.detached(priority: .utility) {
            try handle.write(contentsOf: data)
        }.value
    }
}

private actor DirectDockerLogReadSession: DockerLogReadSession {
    nonisolated let terminal: Bool

    private let reader: any ContainerLogReader
    private var ended = false

    init(reader: any ContainerLogReader, terminal: Bool) {
        self.reader = reader
        self.terminal = terminal
    }

    func nextRecord() async throws -> DockerLogRecord? {
        guard !ended else {
            return nil
        }
        do {
            switch try await reader.next() {
            case .record(let record):
                return try Self.dockerRecord(record)
            case .endOfStream:
                ended = true
                return nil
            }
        } catch {
            throw ContainerDockerLoggingBackend.map(
                error,
                containerID: nil
            )
        }
    }

    func close() async {
        guard !ended else {
            return
        }
        ended = true
        await reader.cancel()
    }

    func cancel() async {
        await close()
    }

    private static func dockerRecord(
        _ record: ContainerLogReadRecordV1
    ) throws -> DockerLogRecord {
        try DockerLogRecord(
            source: record.stream == .stdout
                ? .standardOutput
                : .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: record.timestamp.secondsSinceUnixEpoch,
                nanoseconds: record.timestamp.nanoseconds
            ),
            line: record.data,
            attributes: record.attributes
        )
    }
}

actor WireDockerLogReadSession: DockerLogReadSession {
    nonisolated let terminal: Bool

    private static let readChunkBytes = 64 * 1_024

    private let file: FileHandle
    private var buffer = Data()
    private var ended = false

    init(file: FileHandle, terminal: Bool) {
        self.file = file
        self.terminal = terminal
    }

    deinit {
        try? file.close()
    }

    func nextRecord() async throws -> DockerLogRecord? {
        guard !ended else {
            return nil
        }
        guard let encoded = try await nextEncodedRecord() else {
            ended = true
            try? file.close()
            return nil
        }
        do {
            let wire = try JSONDecoder().decode(
                ContainerLogReadRecordWireV1.self,
                from: encoded
            )
            return try Self.dockerRecord(wire.record())
        } catch {
            throw ContainerDockerLoggingBackend.map(
                error,
                containerID: nil
            )
        }
    }

    func close() async {
        guard !ended else {
            return
        }
        ended = true
        try? file.close()
    }

    func cancel() async {
        await close()
    }

    private func nextEncodedRecord() async throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard
                    newline
                        <= ContainerLogReadRecordWireV1
                        .maximumEncodedRecordBytes
                else {
                    throw DockerLoggingBackendError.server(
                        "container logging record exceeds the transport limit"
                    )
                }
                let record = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !record.isEmpty else {
                    continue
                }
                return record
            }
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
            else {
                throw DockerLoggingBackendError.server(
                    "container logging record exceeds the transport limit"
                )
            }
            let file = self.file
            let chunk = try await Task.detached(priority: .utility) {
                try file.read(upToCount: Self.readChunkBytes) ?? Data()
            }.value
            if chunk.isEmpty {
                guard buffer.isEmpty else {
                    throw DockerLoggingBackendError.server(
                        "container logging stream ended with a partial record"
                    )
                }
                return nil
            }
            buffer.append(chunk)
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
                    + Self.readChunkBytes
            else {
                throw DockerLoggingBackendError.server(
                    "container logging record exceeds the transport limit"
                )
            }
        }
    }

    private static func dockerRecord(
        _ record: ContainerLogReadRecordV1
    ) throws -> DockerLogRecord {
        try DockerLogRecord(
            source: record.stream == .stdout
                ? .standardOutput
                : .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: record.timestamp.secondsSinceUnixEpoch,
                nanoseconds: record.timestamp.nanoseconds
            ),
            line: record.data,
            attributes: record.attributes
        )
    }
}
