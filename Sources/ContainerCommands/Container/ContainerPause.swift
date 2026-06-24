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
import ContainerResource
import ContainerizationError

extension Application {
    public struct ContainerPause: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "pause",
            abstract: "Pause one or more running containers")

        @Flag(name: .shortAndLong, help: "Pause all running containers")
        var all = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        public func validate() throws {
            try Self.validateSelection(containerIds: containerIds, all: all)
        }

        public mutating func run() async throws {
            let client = ContainerClient()

            let containers: [String]
            if self.all {
                let filters = ContainerListFilters(status: .running).withoutMachines()
                containers = try await client.list(filters: filters).map { $0.id }
            } else {
                containers = containerIds
            }

            try await Self.pauseContainers(client: client, containers: containers)
        }

        static func validateSelection(containerIds: [String], all: Bool) throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        static func pauseContainers(client: ContainerClient, containers: [String]) async throws {
            var errors: [any Error] = []
            for container in containers {
                do {
                    try await client.pause(id: container)
                    print(container)
                } catch {
                    errors.append(error)
                }
            }
            if !errors.isEmpty {
                throw AggregateError(errors)
            }
        }
    }
}
