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

extension Application {
    public struct ContainerResize: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "resize",
            abstract: "Change live resources for a running container"
        )

        @Option(name: .long, help: "Target workload memory (for example, 512M or 2G)")
        var memory: String

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public mutating func run() async throws {
            let memoryInBytes = try Self.memoryInBytes(memory)
            try await ContainerClient().setMemoryTarget(
                id: containerId,
                memoryInBytes: memoryInBytes
            )
            print(containerId)
        }

        static func memoryInBytes(_ value: String) throws -> UInt64 {
            try Parser.memoryStringAsBytes(value)
        }
    }
}
