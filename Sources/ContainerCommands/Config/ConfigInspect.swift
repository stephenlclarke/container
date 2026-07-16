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
import Foundation

extension Application.ConfigCommand {
    public struct ConfigInspect: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display metadata for one or more configurations"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Configurations to inspect")
        var names: [String]

        public init() {}

        public func run() async throws {
            let requested = Set(names)
            let configs = try await ClientConfig.list().filter { requested.contains($0.name) }
            if configs.count != requested.count {
                let found = Set(configs.map(\.name))
                let missing = requested.subtracting(found).sorted().joined(separator: ", ")
                throw ContainerizationError(.notFound, message: "config not found: \(missing)")
            }
            let resources = configs.map { ConfigResource(configuration: $0) }
            try Output.emit(Output.renderJSON(resources, options: .pretty))
        }
    }
}
