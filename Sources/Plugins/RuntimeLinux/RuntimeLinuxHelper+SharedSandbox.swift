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
import ContainerLog
import ContainerPlugin
import ContainerRuntimeClient
import ContainerRuntimeLinuxServer
import ContainerXPC
import Foundation
import Logging

extension RuntimeLinuxHelper {
    struct SharedSandbox: AsyncParsableCommand {
        static let label = "com.apple.container.runtime.container-runtime-linux"

        static let configuration = CommandConfiguration(
            commandName: "shared-sandbox",
            abstract: "Start the Engine-owned shared Linux sandbox helper"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .shortAndLong, help: "Sandbox UUID")
        var uuid: String

        @Option(name: .shortAndLong, help: "Root directory for the shared sandbox")
        var root: String

        var logRoot = LogRoot.path

        var machServiceLabel: String {
            "\(Self.label).\(uuid)"
        }

        func run() async throws {
            let commandName = RuntimeLinuxHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName)-shared-\(uuid).log") }
            let log = ServiceLogger.bootstrap(
                category: "RuntimeLinuxSharedSandbox",
                metadata: ["uuid": "\(uuid)"],
                debug: debug,
                logPath: logPath
            )
            log.info("starting shared sandbox helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping shared sandbox helper", metadata: ["name": "\(commandName)"])
            }

            do {
                try adjustLimits()
                signal(SIGPIPE, SIG_IGN)

                let launchRoot = URL(fileURLWithPath: root)
                let configuration = try EngineLinuxSandboxRuntimeConfigurationV1.read(from: launchRoot)
                guard configuration.sandboxID == uuid else {
                    throw ValidationError("sandbox UUID does not match the persisted launch configuration")
                }

                nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)
                let runtimeFingerprint = "shared-v1:\(uuid):\(UUID().uuidString)"
                let service = try EngineLinuxSandboxRuntimeServiceV1(
                    configuration: configuration,
                    runtimeFingerprint: runtimeFingerprint,
                    connection: anonymousConnection,
                    log: log
                )
                let endpointServer = XPCServer(
                    identifier: machServiceLabel,
                    routes: [
                        RuntimeRoutes.createEndpoint.rawValue: XPCServer.route(service.createEndpoint)
                    ],
                    log: log
                )
                let mainServer = XPCServer(
                    connection: anonymousConnection,
                    routes: [
                        RuntimeRoutes.engineSandboxBoot.rawValue: XPCServer.route(service.bootMessage),
                        RuntimeRoutes.engineSandboxObserveBoot.rawValue: XPCServer.route(service.observeBootMessage),
                        RuntimeRoutes.engineSandboxShutdown.rawValue: XPCServer.route(service.shutdownMessage),
                        RuntimeRoutes.engineSandboxObserveShutdown.rawValue: XPCServer.route(service.observeShutdownMessage),
                        RuntimeRoutes.engineSandboxStartWorkload.rawValue: XPCServer.route(service.startWorkloadMessage),
                        RuntimeRoutes.engineSandboxObserveWorkloadStart.rawValue: XPCServer.route(
                            service.observeWorkloadStartMessage
                        ),
                        RuntimeRoutes.engineSandboxDialService.rawValue: XPCServer.route(
                            service.dialServiceMessage
                        ),
                    ],
                    log: log
                )

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await endpointServer.listen()
                    }
                    group.addTask {
                        try await mainServer.listen()
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch {
                log.error(
                    "shared sandbox helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ]
                )
                RuntimeLinuxHelper.SharedSandbox.exit(withError: error)
            }
        }

        private func adjustLimits() throws {
            var limits = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
            limits.rlim_cur = 65536
            limits.rlim_max = 65536
            guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
        }
    }
}
