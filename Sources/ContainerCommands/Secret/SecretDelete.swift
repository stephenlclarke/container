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

extension Application.SecretCommand {
    public struct SecretDelete: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more secrets",
            aliases: ["rm"]
        )

        @Flag(name: .shortAndLong, help: "Delete all secrets")
        var all = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Secret names")
        var names: [String] = []

        public init() {}

        public func validate() throws {
            if names.isEmpty && !all {
                throw ContainerizationError(.invalidArgument, message: "no secrets specified and --all not supplied")
            }
            if !names.isEmpty && all {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "explicitly supplied secret names conflict with the --all flag"
                )
            }
        }

        public func run() async throws {
            let requested = Set(names)
            let available = try ClientSecret.list()
            let secrets = all ? available : available.filter { requested.contains($0.name) }

            if !all, secrets.count != requested.count {
                let found = Set(secrets.map(\.name))
                let missing = requested.subtracting(found).sorted().joined(separator: ", ")
                throw ContainerizationError(.notFound, message: "secret not found: \(missing)")
            }

            for secret in secrets {
                try ClientSecret.delete(name: secret.name)
                print(secret.name)
            }
        }
    }
}
