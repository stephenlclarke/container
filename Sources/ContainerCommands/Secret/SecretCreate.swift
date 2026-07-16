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
import Foundation

extension Application.SecretCommand {
    public struct SecretCreate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create an immutable secret from a file or standard input"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Secret name")
        var name: String

        @Argument(help: "Source file path, or '-' for standard input")
        var source: String

        public init() {}

        public func run() async throws {
            let contents: Data
            if source == "-" {
                contents = try FileHandle.standardInput.readToEnd() ?? Data()
            } else {
                contents = try Data(contentsOf: URL(fileURLWithPath: source))
            }

            let secret = try ClientSecret.create(name: name, contents: contents)
            print(secret.name)
        }
    }
}
