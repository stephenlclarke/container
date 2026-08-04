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
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct SystemStatus: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the status of `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = "com.apple.container."

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        struct PrintableStatus: Codable {
            let status: String
            let appRoot: String
            let installRoot: String
            let logRoot: String?
            let apiServerVersion: String
            let apiServerCommit: String
            let apiServerBuild: String
            let apiServerAppName: String
            let apiServerBuilderShimRepository: String?
            let apiServerBuilderShimVersion: String?
            let apiServerBuilderShimDigest: String?
            let engineStatus: String
            let engineSocket: String

            init(
                status: String,
                appRoot: String = "",
                installRoot: String = "",
                logRoot: String? = nil,
                apiServerVersion: String = "",
                apiServerCommit: String = "",
                apiServerBuild: String = "",
                apiServerAppName: String = "",
                apiServerBuilderShimRepository: String? = nil,
                apiServerBuilderShimVersion: String? = nil,
                apiServerBuilderShimDigest: String? = nil,
                engineStatus: String = "unregistered",
                engineSocket: String = ContainerEngineServiceConfiguration(
                    appRoot: ApplicationRoot.defaultPath
                ).publicSocketPath.string
            ) {
                self.status = status
                self.appRoot = appRoot
                self.installRoot = installRoot
                self.logRoot = logRoot
                self.apiServerVersion = apiServerVersion
                self.apiServerCommit = apiServerCommit
                self.apiServerBuild = apiServerBuild
                self.apiServerAppName = apiServerAppName
                self.apiServerBuilderShimRepository = apiServerBuilderShimRepository
                self.apiServerBuilderShimVersion = apiServerBuilderShimVersion
                self.apiServerBuilderShimDigest = apiServerBuilderShimDigest
                self.engineStatus = engineStatus
                self.engineSocket = engineSocket
            }

            var apiServerBuilderShimImage: String? {
                guard let apiServerBuilderShimRepository else {
                    return nil
                }
                if let apiServerBuilderShimDigest, !apiServerBuilderShimDigest.isEmpty {
                    return "\(apiServerBuilderShimRepository)@\(apiServerBuilderShimDigest)"
                }
                guard let apiServerBuilderShimVersion else {
                    return nil
                }
                return "\(apiServerBuilderShimRepository):\(apiServerBuilderShimVersion)"
            }
        }

        public func run() async throws {
            let engineSocket = ContainerEngineServiceConfiguration(
                appRoot: ApplicationRoot.defaultPath
            ).publicSocketPath.string
            let engineRegistered = try ServiceManager.isRegistered(
                fullServiceLabel: ContainerEngineServiceConfiguration.launchdLabel
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
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(prefix)apiserver")
            if !isRegistered {
                try Output.render(
                    payload: PrintableStatus(
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
                let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
                let status = PrintableStatus(
                    status: engineRunning ? "running" : "degraded",
                    appRoot: systemHealth.appRoot.path(percentEncoded: false),
                    installRoot: systemHealth.installRoot.path(percentEncoded: false),
                    logRoot: systemHealth.logRoot?.string,
                    apiServerVersion: systemHealth.apiServerVersion,
                    apiServerCommit: systemHealth.apiServerCommit,
                    apiServerBuild: systemHealth.apiServerBuild,
                    apiServerAppName: systemHealth.apiServerAppName,
                    apiServerBuilderShimRepository: systemHealth.apiServerBuilderShimRepository,
                    apiServerBuilderShimVersion: systemHealth.apiServerBuilderShimVersion,
                    apiServerBuilderShimDigest: systemHealth.apiServerBuilderShimDigest,
                    engineStatus: engineStatus,
                    engineSocket: engineSocket
                )
                try Output.render(payload: status, format: format) {
                    Self.statusTable(status)
                }
                systemIsDegraded = !engineRunning
            } catch {
                try Output.render(
                    payload: PrintableStatus(
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

        private static func statusTable(_ status: PrintableStatus) -> String {
            let rows: [[String]] = [
                ["FIELD", "VALUE"],
                ["status", status.status],
                ["appRoot", status.appRoot],
                ["installRoot", status.installRoot],
                ["logRoot", status.logRoot ?? ""],
                ["apiserver.version", status.apiServerVersion],
                ["apiserver.commit", status.apiServerCommit],
                ["apiserver.build", status.apiServerBuild],
                ["apiserver.appName", status.apiServerAppName],
                ["apiserver.builderShim", status.apiServerBuilderShimImage ?? ""],
                ["engine.status", status.engineStatus],
                ["engine.socket", status.engineSocket],
            ]
            return TableOutput(rows: rows).format()
        }
    }
}
