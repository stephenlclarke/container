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
import ContainerVersion
import Foundation

extension Application {
    public struct SystemVersion: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Show version information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let cliInfo = VersionInfo(
                version: ReleaseVersion.version(),
                buildType: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container",
                distribution: ReleaseVersion.distribution(),
                source: ReleaseVersion.containerSource(),
                containerization: "\(ReleaseVersion.containerizationSource())@\(ReleaseVersion.containerizationRef())",
                builderShimRepository: ReleaseVersion.builderShimRepository(),
                builderShimVersion: ReleaseVersion.builderShimVersion()
            )

            // Try to get API server version info
            let serverInfo: VersionInfo?
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                serverInfo = VersionInfo(
                    version: health.apiServerVersion,
                    buildType: health.apiServerBuild,
                    commit: health.apiServerCommit,
                    appName: health.apiServerAppName,
                    builderShimRepository: health.apiServerBuilderShimRepository,
                    builderShimVersion: health.apiServerBuilderShimVersion
                )
            } catch {
                serverInfo = nil
            }

            let versions = [cliInfo, serverInfo].compactMap { $0 }

            try Output.render(payload: versions, format: format) {
                Self.versionTable(versions)
            }
        }

        private static func versionTable(_ versions: [VersionInfo]) -> String {
            let header = ["COMPONENT", "VERSION", "BUILD", "COMMIT", "DISTRIBUTION", "SOURCE", "CONTAINERIZATION", "BUILDER-SHIM"]
            let rows =
                [header]
                + versions.map {
                    [
                        $0.appName,
                        $0.version,
                        $0.buildType,
                        $0.commit,
                        $0.distribution ?? "-",
                        $0.source ?? "-",
                        $0.containerization ?? "-",
                        $0.builderShimImage ?? "-",
                    ]
                }
            return TableOutput(rows: rows).format()
        }
    }

    public struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String

        let distribution: String?
        let source: String?
        let containerization: String?
        let builderShimRepository: String?
        let builderShimVersion: String?

        var builderShimImage: String? {
            guard let builderShimRepository, let builderShimVersion else {
                return nil
            }
            return "\(builderShimRepository):\(builderShimVersion)"
        }

        init(
            version: String,
            buildType: String,
            commit: String,
            appName: String,
            distribution: String? = nil,
            source: String? = nil,
            containerization: String? = nil,
            builderShimRepository: String? = nil,
            builderShimVersion: String? = nil
        ) {
            self.version = version
            self.buildType = buildType
            self.commit = commit
            self.appName = appName
            self.distribution = distribution
            self.source = source
            self.containerization = containerization
            self.builderShimRepository = builderShimRepository
            self.builderShimVersion = builderShimVersion
        }
    }
}
