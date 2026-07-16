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
import ContainerizationError
import Foundation

extension Application {
    /// Attach the terminal to the init process of a running container.
    public struct ContainerAttach: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Attach to a running container"
        )

        @Flag(
            name: .customLong("no-stdin"),
            help: "Do not attach standard input"
        )
        var noStdin = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func run() async throws {
            let client = ContainerClient()
            let container = try await client.get(id: containerId)
            guard container.status == .running || container.status == .paused else {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot attach: container is not running"
                )
            }

            let io = try ProcessIO.create(
                tty: container.configuration.initProcess.terminal,
                interactive: !noStdin,
                detach: false
            )
            defer {
                try? io.close()
            }

            let process = try await client.attach(id: container.id, stdio: io.stdio)
            let exitCode = try await io.handleAttachedProcess(process: process, log: log)
            throw ArgumentParser.ExitCode(exitCode)
        }
    }
}
