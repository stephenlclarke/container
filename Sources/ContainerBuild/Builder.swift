//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIO
import NIOPosix

public struct Builder: Sendable {
    public static let builderContainerId = "buildkit"
    public static let defaultBuilderName = "default"

    private final class ShutdownState: @unchecked Sendable {
        private let lock = NSLock()
        private var isShutdown = false

        func beginShutdown() -> Bool {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            guard !self.isShutdown else {
                return false
            }
            self.isShutdown = true
            return true
        }
    }

    public static func containerId(for builderName: String?) throws -> String {
        guard let name = builderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return builderContainerId
        }
        guard name != defaultBuilderName else {
            return builderContainerId
        }
        try ContainerAPIClient.Utility.validEntityName(name)
        let id = "\(builderContainerId)-\(name)"
        try ContainerAPIClient.Utility.validEntityName(id)
        return id
    }

    let client: Com_Apple_Container_Build_V1_Builder.Client<HTTP2ClientTransport.WrappedChannel>
    let grpcClient: GRPCClient<HTTP2ClientTransport.WrappedChannel>
    let group: EventLoopGroup
    let builderShimSocket: FileHandle
    let clientTask: Task<Void, any Swift.Error>
    let logger: Logger
    private let shutdownState: ShutdownState

    public init(socket: FileHandle, group: EventLoopGroup, logger: Logger) async throws {
        try socket.setSendBufSize(4 << 20)
        try socket.setRecvBufSize(2 << 20)

        let transport = try await HTTP2ClientTransport.WrappedChannel.wrapping(
            config: .defaults,
            serviceConfig: .init()
        ) { configure in
            try await withCheckedThrowingContinuation { continuation in
                ClientBootstrap(group: group)
                    .channelInitializer { channel in
                        configure(channel).map { configured in
                            continuation.resume(returning: configured)
                        }
                    }
                    .withConnectedSocket(socket.fileDescriptor)
                    .whenFailure { error in
                        continuation.resume(throwing: error)
                    }
            }
        }

        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        self.client = Com_Apple_Container_Build_V1_Builder.Client(wrapping: grpcClient)
        self.group = group
        self.builderShimSocket = socket
        self.logger = logger
        self.shutdownState = ShutdownState()

        // Start the client connection loop in a background task
        self.clientTask = Task {
            do {
                try await grpcClient.runConnections()
            } catch is CancellationError {
                // Expected during graceful shutdown - re-throw
                throw CancellationError()
            } catch let error as RPCError where error.code == .unavailable {
                // Connection closed - this is expected when the container stops
                logger.debug("gRPC connection closed: \(error)")
                throw error
            } catch {
                // Log unexpected connection errors
                logger.error("gRPC client connection error: \(error)")
                throw error
            }
        }
    }

    public func info() async throws -> InfoResponse {
        var opts = CallOptions.defaults
        opts.timeout = .seconds(30)
        return try await self.client.info(InfoRequest(), options: opts)
    }

    public func shutdown() async {
        guard self.shutdownState.beginShutdown() else {
            return
        }

        self.grpcClient.beginGracefulShutdown()
        self.clientTask.cancel()

        do {
            try await self.group.shutdownGracefully()
        } catch {
            self.logger.debug("builder event loop shutdown failed: \(error)")
        }

        try? self.builderShimSocket.close()
    }

    // TODO
    // - Symlinks in build context dir
    // - cache-to, cache-from
    // - output (other than the default OCI image output, e.g., local, tar, Docker)
    public func build(_ config: BuildConfig) async throws {
        var continuation: AsyncStream<ClientStream>.Continuation?
        let reqStream = AsyncStream<ClientStream> { (cont: AsyncStream<ClientStream>.Continuation) in
            continuation = cont
        }
        guard let continuation else {
            throw Error.invalidContinuation
        }

        defer {
            continuation.finish()
        }

        if let terminal = config.terminal {
            Task {
                let winchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])
                let setWinch = { (rows: UInt16, cols: UInt16) in
                    var winch = ClientStream()
                    winch.command = .init()
                    if let cmdString = try TerminalCommand(rows: rows, cols: cols).json() {
                        winch.command.command = cmdString
                        continuation.yield(winch)
                    }
                }
                let size = try terminal.size
                var width = size.width
                var height = size.height
                try setWinch(height, width)

                for await _ in winchHandler.signals {
                    let size = try terminal.size
                    let cols = size.width
                    let rows = size.height
                    if cols != width || rows != height {
                        width = cols
                        height = rows
                        try setWinch(height, width)
                    }
                }
            }
        }

        let pipeline = try await BuildPipeline(config)
        do {
            try await self.client.performBuild(
                metadata: try Self.buildMetadata(config),
                options: .defaults,
                requestProducer: { writer in
                    for await message in reqStream {
                        try await writer.write(message)
                    }
                },
                onResponse: { response in
                    try await pipeline.run(sender: continuation, receiver: response.messages)
                }
            )
        } catch Error.buildComplete {
            await self.shutdown()
            return
        } catch {
            await self.shutdown()
            throw error
        }

        await self.shutdown()
    }

    public struct BuildExport: Sendable {
        public let type: String
        public var destination: URL?
        public let additionalFields: [String: String]
        public let rawValue: String

        public init(type: String, destination: URL?, additionalFields: [String: String], rawValue: String) {
            self.type = type
            self.destination = destination
            self.additionalFields = additionalFields
            self.rawValue = rawValue
        }

        public init(from input: String) throws {
            var typeValue: String?
            var destinationValue: URL?
            var additionalFields: [String: String] = [:]

            let pairs = input.split(separator: ",", omittingEmptySubsequences: false)
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    throw Builder.Error.invalidExport(input, "invalid field format: \(pair)")
                }

                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    throw Builder.Error.invalidExport(input, "field key is required")
                }

                switch key {
                case "type":
                    typeValue = value
                case "dest":
                    destinationValue = try Self.resolveDestination(dest: value)
                default:
                    additionalFields[key] = value
                }
            }

            guard let type = typeValue else {
                throw Builder.Error.invalidExport(input, "type field is required")
            }

            switch type {
            case "oci":
                break
            case "tar":
                if destinationValue == nil {
                    throw Builder.Error.invalidExport(input, "dest field is required")
                }
            case "local":
                if destinationValue == nil {
                    throw Builder.Error.invalidExport(input, "dest field is required")
                }
            default:
                throw Builder.Error.invalidExport(input, "unsupported output type")
            }

            self.init(type: type, destination: destinationValue, additionalFields: additionalFields, rawValue: input)
        }

        public var stringValue: String {
            get throws {
                var components = ["type=\(type)"]

                switch type {
                case "oci", "tar", "local":
                    break  // ignore destination
                default:
                    throw Builder.Error.invalidExport(rawValue, "unsupported output type")
                }

                for (key, value) in additionalFields {
                    components.append("\(key)=\(value)")
                }

                return components.joined(separator: ",")
            }
        }

        static func resolveDestination(dest: String) throws -> URL {
            let destination = URL(fileURLWithPath: dest)
            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: destination.path) {
                let resourceValues = try destination.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = resourceValues.isDirectory
                if isDir != nil && isDir == false {
                    throw Builder.Error.invalidExport(dest, "dest path already exists")
                }

                var finalDestination = destination.appendingPathComponent("out.tar")
                var index = 1
                while fileManager.fileExists(atPath: finalDestination.path) {
                    let path = "out.tar.\(index)"
                    finalDestination = destination.appendingPathComponent(path)
                    index += 1
                }
                return finalDestination
            } else {
                let parentDirectory = destination.deletingLastPathComponent()
                try? fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            return destination
        }
    }

    public struct BuildConfig: Sendable {
        public let buildID: String
        public let contentStore: ContentStore
        public let buildArgs: [String]
        public let buildContexts: [String: String]
        public let localBuildContexts: [String: String]
        public let secrets: [String: Data]
        public let ssh: [String]
        public let entitlements: [String]
        public let attestations: [String: String]
        public let addHosts: [String]
        public let network: String?
        public let privileged: Bool
        public let shmSize: String?
        public let ulimits: [String]
        public let contextDir: String
        public let dockerfile: Data
        public let dockerignore: Data?
        public let labels: [String]
        public let noCache: Bool
        public let platforms: [Platform]
        public let terminal: Terminal?
        public let tags: [String]
        public let target: String
        public let quiet: Bool
        public let exports: [BuildExport]
        public let cacheIn: [String]
        public let cacheOut: [String]
        public let pull: Bool
        public let containerSystemConfig: ContainerSystemConfig
        public let check: Bool

        public init(
            buildID: String,
            contentStore: ContentStore,
            buildArgs: [String],
            buildContexts: [String: String] = [:],
            localBuildContexts: [String: String] = [:],
            secrets: [String: Data],
            ssh: [String] = [],
            entitlements: [String] = [],
            attestations: [String: String] = [:],
            addHosts: [String] = [],
            network: String? = nil,
            privileged: Bool = false,
            shmSize: String? = nil,
            ulimits: [String] = [],
            contextDir: String,
            dockerfile: Data,
            dockerignore: Data?,
            labels: [String],
            noCache: Bool,
            platforms: [Platform],
            terminal: Terminal?,
            tags: [String],
            target: String,
            quiet: Bool,
            exports: [BuildExport],
            cacheIn: [String],
            cacheOut: [String],
            pull: Bool,
            containerSystemConfig: ContainerSystemConfig,
            check: Bool = false
        ) {
            self.buildID = buildID
            self.contentStore = contentStore
            self.buildArgs = buildArgs
            self.buildContexts = buildContexts
            self.localBuildContexts = localBuildContexts
            self.secrets = secrets
            self.ssh = ssh
            self.entitlements = entitlements
            self.attestations = attestations
            self.addHosts = addHosts
            self.network = network
            self.privileged = privileged
            self.shmSize = shmSize
            self.ulimits = ulimits
            self.contextDir = contextDir
            self.dockerfile = dockerfile
            self.dockerignore = dockerignore
            self.labels = labels
            self.noCache = noCache
            self.platforms = platforms
            self.terminal = terminal
            self.tags = tags
            self.target = target
            self.quiet = quiet
            self.exports = exports
            self.cacheIn = cacheIn
            self.cacheOut = cacheOut
            self.pull = pull
            self.containerSystemConfig = containerSystemConfig
            self.check = check
        }
    }

    static func buildMetadata(_ config: BuildConfig) throws -> Metadata {
        var metadata = Metadata()
        metadata.addString(config.buildID, forKey: "build-id")
        metadata.addString(URL(filePath: config.contextDir).path(percentEncoded: false), forKey: "context")
        metadata.addString(config.dockerfile.base64EncodedString(), forKey: "dockerfile")
        metadata.addString(config.terminal != nil ? "tty" : "plain", forKey: "progress")
        metadata.addString(config.target, forKey: "target")

        if let dockerignore = config.dockerignore {
            metadata.addString(dockerignore.base64EncodedString(), forKey: "dockerignore")
        }
        for tag in config.tags {
            metadata.addString(tag, forKey: "tag")
        }
        for platform in config.platforms {
            metadata.addString(platform.description, forKey: "platforms")
        }
        if config.noCache {
            metadata.addString("", forKey: "no-cache")
        }
        if config.check {
            metadata.addString("", forKey: "check")
        }
        for label in config.labels {
            metadata.addString(label, forKey: "labels")
        }
        for buildArg in config.buildArgs {
            metadata.addString(buildArg, forKey: "build-args")
        }
        for (name, source) in config.buildContexts.sorted(by: { $0.key < $1.key }) {
            metadata.addString("\(name)=\(source)", forKey: "build-contexts")
        }
        for (id, data) in config.secrets {
            metadata.addString(id + "=" + data.base64EncodedString(), forKey: "secrets")
        }
        for ssh in config.ssh {
            metadata.addString(ssh, forKey: "ssh")
        }
        for entitlement in config.entitlements {
            metadata.addString(entitlement, forKey: "entitlements")
        }
        for addHost in config.addHosts {
            metadata.addString(addHost, forKey: "add-hosts")
        }
        if let network = config.network, !network.isEmpty {
            metadata.addString(network, forKey: "network")
        }
        if config.privileged {
            metadata.addString("", forKey: "privileged")
        }
        if let shmSize = config.shmSize, !shmSize.isEmpty {
            metadata.addString(shmSize, forKey: "shm-size")
        }
        for ulimit in config.ulimits {
            metadata.addString(ulimit, forKey: "ulimit")
        }
        for (key, value) in config.attestations.sorted(by: { $0.key < $1.key }) {
            metadata.addString(value, forKey: key)
        }
        for output in config.exports {
            metadata.addString(try output.stringValue, forKey: "outputs")
        }
        for cacheIn in config.cacheIn {
            metadata.addString(cacheIn, forKey: "cache-in")
        }
        for cacheOut in config.cacheOut {
            metadata.addString(cacheOut, forKey: "cache-out")
        }

        return metadata
    }
}

extension Builder {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidContinuation
        case buildComplete
        case invalidExport(String, String)

        var description: String {
            switch self {
            case .invalidContinuation:
                return "continuation could not created"
            case .buildComplete:
                return "build completed"
            case .invalidExport(let exp, let reason):
                return "export entry \(exp) is invalid: \(reason)"
            }
        }
    }
}

extension FileHandle {
    @discardableResult
    func setSendBufSize(_ bytes: Int) throws -> Int {
        try setSockOpt(
            level: SOL_SOCKET,
            name: SO_SNDBUF,
            value: bytes)
        return bytes
    }

    @discardableResult
    func setRecvBufSize(_ bytes: Int) throws -> Int {
        try setSockOpt(
            level: SOL_SOCKET,
            name: SO_RCVBUF,
            value: bytes)
        return bytes
    }

    private func setSockOpt(level: Int32, name: Int32, value: Int) throws {
        var v = Int32(value)
        let res = withUnsafePointer(to: &v) { ptr -> Int32 in
            ptr.withMemoryRebound(
                to: UInt8.self,
                capacity: MemoryLayout<Int32>.size
            ) { raw in
                #if canImport(Darwin)
                return setsockopt(
                    self.fileDescriptor,
                    level, name,
                    raw,
                    socklen_t(MemoryLayout<Int32>.size))
                #else
                fatalError("unsupported platform")
                #endif
            }
        }
        if res == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }
}
