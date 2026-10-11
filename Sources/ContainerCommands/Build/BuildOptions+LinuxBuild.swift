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

import ArgumentParser
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerLog
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIO
import TerminalProgress

extension BuildOptions {
    /// Resolves the set of target platforms from `--platform`, the
    /// `CONTAINER_DEFAULT_PLATFORM` environment variable, and `--os`/`--arch`.
    public func resolvePlatforms() throws -> Set<Platform> {
        var results: Set<Platform> = []
        for platform in (self.platform.flatMap { $0 }) {
            guard let p = try? Platform(from: platform) else {
                throw ValidationError("invalid platform specified \(platform)")
            }
            results.insert(p)
        }

        if !results.isEmpty {
            return results
        }

        if let envPlatform = try DefaultPlatform.fromEnvironment(log: log) {
            return [envPlatform]
        }

        for o in (self.os.flatMap { $0 }) {
            for a in (self.arch.flatMap { $0 }) {
                guard let platform = try? Platform(from: "\(o)/\(a)") else {
                    throw ValidationError("invalid os/architecture combination \(o)/\(a)")
                }
                results.insert(platform)
            }
        }
        return results
    }

    /// Returns the path of the Dockerfile to build, or "-" to read it from stdin.
    /// Lookup in the context directory is deferred until here so that callers
    /// that don't build a Dockerfile (e.g. non-Linux builds) don't require one.
    func resolveDockerfile() throws -> String {
        switch file {
        case "-":
            return "-"
        case .some(let filepath):
            return URL(fileURLWithPath: filepath, relativeTo: .currentDirectory()).path
        case .none:
            guard let defaultDockerfile = try BuildFile.resolvePath(contextDir: contextDir) else {
                guard (try? FileManager.default.contentsOfDirectory(atPath: contextDir)) != nil else {
                    throw ValidationError("cannot read context dir \(contextDir): permission denied")
                }
                throw ValidationError("dockerfile not found in context dir")
            }

            guard FileManager.default.fileExists(atPath: defaultDockerfile) else {
                throw ValidationError("dockerfile does not exist \(defaultDockerfile)")
            }
            return defaultDockerfile
        }
    }

    public func runLinuxBuild(containerSystemConfig: ContainerSystemConfig) async throws {
        let dockerfile = try resolveDockerfile()
        var activeBuilder: Builder?
        do {
            let timeout: Duration = .seconds(300)
            let progressConfig = try ProgressConfig(
                showTasks: true,
                showItems: true
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            progress.set(description: "Dialing builder")

            let builderContainerId = try Builder.containerId(for: builder)
            let sshForwarding = try BuildSSHForwarding.resolve(values: ssh)
            let enableSSHForwarding = sshForwarding.isEnabled
            let attestations = buildAttestations()
            let dnsNameservers = self.dns.nameservers
            let dnsDomain = self.dns.domain
            let dnsSearchDomains = self.dns.searchDomains
            let dnsOptions = self.dns.options
            progress.set(tasks: 0)
            progress.set(totalTasks: 3)
            try await Builder.start(
                cpus: cpus,
                memory: memory,
                log: log,
                dnsNameservers: dnsNameservers,
                dnsDomain: dnsDomain,
                dnsSearchDomains: dnsSearchDomains,
                dnsOptions: dnsOptions,
                enableSSHForwarding: enableSSHForwarding,
                sshAuthSocketPath: sshForwarding.environmentSocketGuestPath,
                sshSocketMounts: sshForwarding.socketMounts,
                builderContainerId: builderContainerId,
                progressUpdate: progress.handler,
                containerSystemConfig: containerSystemConfig,
            )
            progress.set(description: "Dialing builder")

            let builder: Builder? = try await withThrowingTaskGroup(of: Builder.self) {
                [builderContainerId, vsockPort, cpus, memory, dnsNameservers, enableSSHForwarding, sshForwarding] group in
                defer {
                    group.cancelAll()
                }

                group.addTask { [builderContainerId, vsockPort, cpus, memory, log, dnsNameservers, sshForwarding] in
                    let client = ContainerClient()
                    var retryBackoff = BuilderReadinessBackoff()
                    while true {
                        do {
                            let fh = try await client.dial(id: builderContainerId, port: vsockPort)

                            // The builder client owns one gRPC connection, so one event loop is sufficient.
                            let threadGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                            let b: Builder
                            do {
                                b = try await Builder(socket: fh, group: threadGroup, logger: log)
                            } catch {
                                let connectionError = error
                                do {
                                    try await threadGroup.shutdownGracefully()
                                } catch {
                                    log.warning("failed to shut down builder event loop: \(error)")
                                }
                                throw connectionError
                            }

                            // If this call succeeds, then BuildKit is running.
                            do {
                                let _ = try await b.info()
                                return b
                            } catch {
                                let readinessError = error
                                await b.shutdown()
                                throw readinessError
                            }
                        } catch {
                            try Task.checkCancellation()

                            let builderStatus: RuntimeStatus?
                            let builderStatusError: Error?
                            do {
                                builderStatus = try await client.get(id: builderContainerId).status
                                builderStatusError = nil
                            } catch {
                                try Task.checkCancellation()
                                builderStatus = nil
                                builderStatusError = error
                            }
                            if Self.builderExitedBeforeDial(status: builderStatus) {
                                throw ContainerizationError(
                                    .invalidState,
                                    message: "builder '\(builderContainerId)' exited before accepting connections; inspect its logs with 'container logs \(builderContainerId)'"
                                )
                            }

                            // If we get here, "Dialing builder" is shown for such a short period
                            // of time that it's invisible to the user.
                            progress.set(tasks: 0)
                            progress.set(totalTasks: 3)

                            if BuilderReadinessRecovery.shouldRestart(
                                after: error,
                                builderStatusError: builderStatusError
                            ) {
                                try await Builder.start(
                                    cpus: cpus,
                                    memory: memory,
                                    log: log,
                                    dnsNameservers: dnsNameservers,
                                    dnsDomain: dnsDomain,
                                    dnsSearchDomains: dnsSearchDomains,
                                    dnsOptions: dnsOptions,
                                    enableSSHForwarding: enableSSHForwarding,
                                    sshAuthSocketPath: sshForwarding.environmentSocketGuestPath,
                                    sshSocketMounts: sshForwarding.socketMounts,
                                    builderContainerId: builderContainerId,
                                    progressUpdate: progress.handler,
                                    containerSystemConfig: containerSystemConfig,
                                )
                            }

                            try await Task.sleep(for: retryBackoff.nextDelay())
                            continue
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ValidationError(
                        """
                            Timeout waiting for connection to builder
                        """
                    )
                }

                return try await group.next()
            }

            guard let builder else {
                throw ValidationError("builder is not running")
            }
            activeBuilder = builder

            let buildFileData: Data
            // Dockerfile should be read from stdin
            if dockerfile == "-" {
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("Dockerfile-\(UUID().uuidString)")
                defer {
                    try? FileManager.default.removeItem(at: tempFile)
                }

                guard FileManager.default.createFile(atPath: tempFile.path(), contents: nil) else {
                    throw ContainerizationError(.internalError, message: "unable to create temporary file")
                }

                guard let fileHandle = try? FileHandle(forWritingTo: tempFile) else {
                    throw ContainerizationError(.internalError, message: "unable to open temporary file for writing")
                }

                let bufferSize = 4096
                while true {
                    let chunk = FileHandle.standardInput.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    fileHandle.write(chunk)
                }
                try fileHandle.close()
                buildFileData = try Data(contentsOf: URL(filePath: tempFile.path()))
            } else {
                buildFileData = try Data(contentsOf: URL(filePath: dockerfile))
            }
            let ignoreFileData = try Self.dockerignoreData(dockerfile: dockerfile, contextDir: contextDir)

            // BUG: See https://github.com/apple/container/issues/735.
            // Reject dockerfiles larger than 16kb before attempting to build.
            // TODO: Remove when #735 was been resolved.
            let maxDockerfileSize = 16 * 1024  // 16 KiB
            guard buildFileData.count < maxDockerfileSize else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: """
                        Dockerfile size (\(buildFileData.count) bytes) exceeds the maximum allowed size of \(maxDockerfileSize) bytes. \
                        See https://github.com/apple/container/issues/735.
                        """
                )
            }

            let secretsData: [String: Data] = try self.secrets.mapValues { secret in
                switch secret {
                case .data(let data):
                    return data
                case .file(let path):
                    return try Data(contentsOf: URL(fileURLWithPath: path))
                }
            }

            let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
            let exportPath = systemHealth.appRoot
                .appendingPathComponent(Builder.builderResourceDir)
            let buildID = UUID().uuidString
            let tempURL = exportPath.appendingPathComponent(buildID)
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let imageNames: [String] = try targetImageNames.map { name in
                let parsedReference = try Reference.parse(name)
                parsedReference.normalize()
                return parsedReference.description
            }

            var terminal: Terminal?
            switch self.progress {
            case .tty:
                terminal = try Terminal(descriptor: STDERR_FILENO)
            case .auto:
                terminal = try? Terminal(descriptor: STDERR_FILENO)
            case .plain:
                terminal = nil
            }

            defer { terminal?.tryReset() }

            let exports: [Builder.BuildExport] = try output.map { output in
                var exp = try Builder.BuildExport(from: output)
                if exp.destination == nil {
                    exp.destination = tempURL.appendingPathComponent("out.tar")
                }
                return exp
            }
            let buildContexts = try parsedBuildContexts()

            try await withThrowingTaskGroup(of: Void.self) { [terminal] group in
                defer {
                    group.cancelAll()
                }
                group.addTask {
                    let handler = AsyncSignalHandler.create(notify: [SIGTERM, SIGINT, SIGUSR1, SIGUSR2])
                    for await sig in handler.signals {
                        throw ContainerizationError(.interrupted, message: "exiting on signal \(sig)")
                    }
                }
                let platforms = try resolvePlatforms()
                group.addTask {
                    [
                        terminal, buildArg, secretsData, sshForwarding, contextDir, ignoreFileData, label,
                        noCache, noCacheFilter, target, quiet, cacheIn, cacheOut, pull, check, exports, imageNames, tempURL, log, attestations,
                        buildContexts, allow, addHost, network, privileged, shmSize, ulimit,
                    ] in
                    let config = Builder.BuildConfig(
                        buildID: buildID,
                        contentStore: RemoteContentStoreClient(),
                        buildArgs: buildArg,
                        buildContexts: buildContexts.sources,
                        localBuildContexts: buildContexts.localPaths,
                        secrets: secretsData,
                        ssh: sshForwarding.metadataValues,
                        entitlements: allow,
                        attestations: attestations,
                        addHosts: addHost,
                        network: network,
                        privileged: privileged,
                        shmSize: shmSize,
                        ulimits: ulimit,
                        contextDir: contextDir,
                        dockerfile: buildFileData,
                        dockerignore: ignoreFileData,
                        labels: label,
                        noCache: noCache,
                        noCacheFilter: noCacheFilter,
                        platforms: [Platform](platforms),
                        terminal: terminal,
                        tags: imageNames,
                        target: target,
                        quiet: quiet,
                        exports: exports,
                        cacheIn: cacheIn,
                        cacheOut: cacheOut,
                        pull: pull,
                        containerSystemConfig: containerSystemConfig,
                        check: check,
                    )
                    progress.finish()

                    try await builder.build(config)
                    if check {
                        return
                    }

                    let unpackProgressConfig = try ProgressConfig(
                        description: "Unpacking built image",
                        itemsName: "entries",
                        showTasks: exports.count > 1,
                        totalTasks: exports.count
                    )
                    let unpackProgress = ProgressBar(config: unpackProgressConfig)
                    defer {
                        unpackProgress.finish()
                    }
                    unpackProgress.start()

                    var finalMessage = imageNames.joined(separator: "\n")
                    let taskManager = ProgressTaskCoordinator()
                    // Currently, only a single export can be specified.
                    for exp in exports {
                        unpackProgress.add(tasks: 1)
                        let unpackTask = await taskManager.startTask()
                        switch exp.type {
                        case "oci":
                            try Task.checkCancellation()
                            guard let dest = exp.destination else {
                                throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                            }
                            let result = try await ClientImage.load(from: dest.absolutePath(), force: false)
                            guard result.rejectedMembers.isEmpty else {
                                log.error("archive contains invalid members", metadata: ["paths": "\(result.rejectedMembers)"])
                                throw ContainerizationError(.internalError, message: "failed to load archive")
                            }
                            for image in result.images {
                                try Task.checkCancellation()
                                try await image.unpack(platform: nil, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: unpackProgress.handler))

                                // Tag the unpacked image with all requested tags
                                for tagName in imageNames {
                                    try Task.checkCancellation()
                                    _ = try await image.tag(new: tagName)
                                }
                            }
                        case "tar":
                            guard let dest = exp.destination else {
                                throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                            }
                            let tarURL = tempURL.appendingPathComponent("out.tar")
                            try FileManager.default.moveItem(at: tarURL, to: dest)
                            finalMessage = dest.absolutePath()
                        case "local":
                            guard let dest = exp.destination else {
                                throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                            }
                            let localDir = tempURL.appendingPathComponent("local")

                            guard FileManager.default.fileExists(atPath: localDir.path) else {
                                throw ContainerizationError(.invalidArgument, message: "expected local output not found")
                            }
                            try FileManager.default.copyItem(at: localDir, to: dest)
                            finalMessage = dest.absolutePath()
                        default:
                            throw ContainerizationError(.invalidArgument, message: "invalid exporter \(exp.rawValue)")
                        }
                    }
                    await taskManager.finish()
                    unpackProgress.finish()
                    print(finalMessage)
                }

                try await group.next()
            }
            await builder.shutdown()
            activeBuilder = nil
        } catch {
            if let activeBuilder {
                await activeBuilder.shutdown()
            }
            throw NSError(domain: "Build", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
    }

    static func builderExitedBeforeDial(status: RuntimeStatus?) -> Bool {
        status == .stopped
    }

    static func dockerignoreData(dockerfile: String, contextDir: String) throws -> Data? {
        if dockerfile != "-" {
            let dockerfileIgnoreURL = URL(filePath: dockerfile + ".dockerignore")
            if FileManager.default.fileExists(atPath: dockerfileIgnoreURL.path) {
                return try Data(contentsOf: dockerfileIgnoreURL)
            }
        }

        let contextIgnoreURL = URL(filePath: contextDir).appending(path: ".dockerignore")
        if FileManager.default.fileExists(atPath: contextIgnoreURL.path) {
            return try Data(contentsOf: contextIgnoreURL)
        }
        return nil
    }
}

struct BuilderReadinessBackoff: Sendable {
    private static let initialDelay: Duration = .milliseconds(50)
    private static let maximumDelay: Duration = .seconds(1)

    private var delay = Self.initialDelay

    mutating func nextDelay() -> Duration {
        let current = delay
        delay = min(delay * 2, Self.maximumDelay)
        return current
    }
}

struct BuilderReadinessRecovery {
    static func shouldRestart(
        after readinessError: Error,
        builderStatusError: Error?
    ) -> Bool {
        if let containerError = readinessError as? ContainerizationError,
            containerError.code == .invalidState || containerError.code == .notFound
        {
            return true
        }

        if let containerError = builderStatusError as? ContainerizationError,
            containerError.code == .notFound
        {
            return true
        }

        return false
    }
}
