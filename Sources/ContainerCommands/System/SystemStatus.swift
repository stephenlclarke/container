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

import ArgumentParser
import ContainerAPIClient
import ContainerEngineService
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct SystemStatus: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the status of `container` services and system-wide information"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String?

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let serviceNamespace = try ContainerServiceNamespace.resolve()
            let servicePrefix = try serviceNamespace.servicePrefix(requestedPrefix: prefix)
            let engineConfiguration = ContainerEngineServiceConfiguration(
                appRoot: ApplicationRoot.path,
                serviceNamespace: serviceNamespace
            )
            let engineSocket = engineConfiguration.publicSocketPath.string
            let engineRegistered = try ServiceManager.isRegistered(
                fullServiceLabel: engineConfiguration.launchdLabel
            )
            let engineRunning: Bool
            do {
                try ContainerEngineHealthProbe.systemInfo(
                    socketPath: engineSocket
                )
                engineRunning = engineRegistered
            } catch {
                engineRunning = false
            }
            let engineStatus =
                engineRunning
                ? "running"
                : (engineRegistered ? "not running" : "unregistered")
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(servicePrefix)apiserver")
            if !isRegistered {
                try Output.render(
                    payload: StatusPayload(
                        status: "unregistered",
                        engineStatus: engineStatus,
                        engineSocket: engineSocket
                    ),
                    format: format
                ) {
                    "apiserver is not running and not registered with launchd"
                }
                Application.exit(withError: ExitCode(1))
            }

            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            var systemIsDegraded = false
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
                let status = await Self.gather(
                    health: health,
                    status: engineRunning ? "running" : "degraded",
                    engineStatus: engineStatus,
                    engineSocket: engineSocket
                )
                try Output.render(payload: status, format: format) {
                    Self.statusTable(status)
                }
                systemIsDegraded = !engineRunning
            } catch {
                try Output.render(
                    payload: StatusPayload(
                        status: "not running",
                        engineStatus: engineStatus,
                        engineSocket: engineSocket
                    ),
                    format: format
                ) {
                    "apiserver is not running"
                }
                Application.exit(withError: ExitCode(1))
            }
            if systemIsDegraded {
                Application.exit(withError: ExitCode(1))
            }
        }

        /// Collects system-wide status from the CLI and the running daemon.
        /// Resource counts are populated best-effort and omitted when their
        /// source is unavailable.
        static func gather(
            health: SystemHealth,
            status: String = "running",
            engineStatus: String = "unregistered",
            engineSocket: String = ContainerEngineServiceConfiguration(
                appRoot: ApplicationRoot.path
            ).publicSocketPath.string
        ) async -> StatusPayload {
            let client = ClientInfo(
                version: ReleaseVersion.version(),
                build: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container"
            )

            let host = HostInfo(
                architecture: Arch.hostArchitecture().rawValue,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                cpus: ProcessInfo.processInfo.processorCount
            )

            let server = ServerInfo(
                version: health.apiServerVersion,
                build: health.apiServerBuild,
                commit: health.apiServerCommit,
                appName: health.apiServerAppName,
                builderShimRepository: health.apiServerBuilderShimRepository,
                builderShimVersion: health.apiServerBuilderShimVersion,
                builderShimDigest: health.apiServerBuilderShimDigest
            )

            let paths = PathInfo(
                appRoot: health.appRoot.path(percentEncoded: false),
                installRoot: health.installRoot.path(percentEncoded: false),
                logRoot: health.logRoot?.string
            )

            var containersTotal: Int? = nil
            var containersRunning: Int? = nil
            let containerClient = ContainerClient()
            if let all = try? await containerClient.list(filters: ContainerListFilters.all.withoutMachines()) {
                containersTotal = all.count
                containersRunning = all.filter { $0.status == .running }.count
            }
            let imageCount = try? await ClientImage.list(responseTimeout: .seconds(10)).count
            let resources = Self.resourceCounts(
                containersTotal: containersTotal,
                containersRunning: containersRunning,
                imageCount: imageCount
            )

            return StatusPayload(
                status: status,
                client: client,
                server: server,
                host: host,
                paths: paths,
                resources: resources,
                engineStatus: engineStatus,
                engineSocket: engineSocket
            )
        }

        /// Builds resource counts from independently best-effort probes. A
        /// payload is omitted only when every probe is unavailable.
        static func resourceCounts(
            containersTotal: Int?,
            containersRunning: Int?,
            imageCount: Int?
        ) -> ResourceCounts? {
            guard containersTotal != nil || containersRunning != nil || imageCount != nil else {
                return nil
            }
            return ResourceCounts(
                containersTotal: containersTotal,
                containersRunning: containersRunning,
                images: imageCount
            )
        }

        static func statusTable(_ status: StatusPayload) -> String {
            var rows: [[String]] = [["FIELD", "VALUE"]]

            rows.append(["status", status.status])

            if let client = status.client {
                rows.append(["client.version", client.version])
                rows.append(["client.build", client.build])
                rows.append(["client.commit", client.commit])
            }

            if let host = status.host {
                rows.append(["host.os", host.operatingSystem])
                rows.append(["host.architecture", host.architecture])
                rows.append(["host.cpus", String(host.cpus)])
            }

            if let server = status.server {
                rows.append(["server.version", server.version])
                rows.append(["server.build", server.build])
                rows.append(["server.commit", server.commit])
                rows.append(["server.appName", server.appName])
                rows.append(["server.builderShim", server.builderShimImage ?? ""])
            }

            if let paths = status.paths {
                rows.append(["paths.appRoot", paths.appRoot])
                rows.append(["paths.installRoot", paths.installRoot])
                rows.append(["paths.logRoot", paths.logRoot ?? ""])
            }

            if let resources = status.resources {
                if let containersTotal = resources.containersTotal {
                    rows.append(["containers.total", String(containersTotal)])
                }
                if let containersRunning = resources.containersRunning {
                    rows.append(["containers.running", String(containersRunning)])
                }
                if let images = resources.images {
                    rows.append(["images.total", String(images)])
                }
            }

            rows.append(["engine.status", status.engineStatus])
            rows.append(["engine.socket", status.engineSocket])

            return TableOutput(rows: rows).format()
        }
    }

    struct StatusPayload: Codable {
        let status: String
        let client: ClientInfo?
        let server: ServerInfo?
        let host: HostInfo?
        let paths: PathInfo?
        let resources: ResourceCounts?
        let engineStatus: String
        let engineSocket: String

        init(
            status: String,
            client: ClientInfo? = nil,
            server: ServerInfo? = nil,
            host: HostInfo? = nil,
            paths: PathInfo? = nil,
            resources: ResourceCounts? = nil,
            engineStatus: String = "unregistered",
            engineSocket: String = ContainerEngineServiceConfiguration(
                appRoot: ApplicationRoot.path
            ).publicSocketPath.string
        ) {
            self.status = status
            self.client = client
            self.server = server
            self.host = host
            self.paths = paths
            self.resources = resources
            self.engineStatus = engineStatus
            self.engineSocket = engineSocket
        }
    }

    struct ClientInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
    }

    struct ServerInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
        let builderShimRepository: String?
        let builderShimVersion: String?
        let builderShimDigest: String?

        init(
            version: String,
            build: String,
            commit: String,
            appName: String,
            builderShimRepository: String? = nil,
            builderShimVersion: String? = nil,
            builderShimDigest: String? = nil
        ) {
            self.version = version
            self.build = build
            self.commit = commit
            self.appName = appName
            self.builderShimRepository = builderShimRepository
            self.builderShimVersion = builderShimVersion
            self.builderShimDigest = builderShimDigest
        }

        var builderShimImage: String? {
            guard let builderShimRepository else {
                return nil
            }
            if let builderShimDigest, !builderShimDigest.isEmpty {
                return "\(builderShimRepository)@\(builderShimDigest)"
            }
            guard let builderShimVersion else {
                return nil
            }
            return "\(builderShimRepository):\(builderShimVersion)"
        }
    }

    struct HostInfo: Codable {
        let architecture: String
        let operatingSystem: String
        let cpus: Int
    }

    struct PathInfo: Codable {
        let appRoot: String
        let installRoot: String
        let logRoot: String?
    }

    struct ResourceCounts: Codable {
        let containersTotal: Int?
        let containersRunning: Int?
        var images: Int?

        init(containersTotal: Int? = nil, containersRunning: Int? = nil, images: Int? = nil) {
            self.containersTotal = containersTotal
            self.containersRunning = containersRunning
            self.images = images
        }
    }
}
