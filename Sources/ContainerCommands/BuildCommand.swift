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

extension Application {
    /// Compatibility entry point for in-process callers; the CLI executes the build plugin.
    public struct BuildCommand: AsyncLoggableCommand {
        public init() {}

        public static var configuration: CommandConfiguration {
            CommandConfiguration(commandName: "build", abstract: "Build an image from a Dockerfile or Containerfile")
        }

        @OptionGroup
        public var options: BuildOptions

        public var logOptions: Flags.Logging {
            get { options.logOptions }
            set { options.logOptions = newValue }
        }

        public var dns: Flags.DNS {
            get { options.dns }
            set { options.dns = newValue }
        }

        public mutating func validate() throws {
            try options.validate()
        }

        public func run() async throws {
            let configuration = try await ClientHealthCheck.loadContainerSystemConfig()
            try await options.runLinuxBuild(containerSystemConfig: configuration)
        }
    }
}
