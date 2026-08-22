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
import ContainerResource
import ContainerizationError
import Foundation

extension Application {
    public struct ContainerInspect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more containers")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs to inspect")
        var containerIds: [String]

        public func run() async throws {
            let client = ContainerClient()
            let views = try await client.lifecycleViews(filters: .all)
            let bundleKeys = try Self.resolveBundleKeys(
                identifiers: containerIds,
                lifecycles: views.map(\.lifecycle)
            )
            let containers = views.compactMap { view in
                bundleKeys.contains(view.lifecycle.immutableBundleKey)
                    ? view.container
                    : nil
            }

            try Output.emit(
                Output.renderJSON(
                    containers.map { ManagedContainer($0).routineInspection },
                    options: .pretty
                )
            )
        }

        /// Resolves native bundle keys from every stable lifecycle identity.
        static func resolveBundleKeys(
            identifiers: [String],
            lifecycles: [ContainerLifecycleRecordV2]
        ) throws -> Set<String> {
            var resolved = Set<String>()
            var missing = [String]()

            for identifier in Set(identifiers) {
                let matches = lifecycles.filter {
                    $0.containerID == identifier
                        || $0.canonicalName == identifier
                        || $0.immutableBundleKey == identifier
                }
                guard matches.count == 1, let match = matches.first else {
                    missing.append(identifier)
                    continue
                }
                resolved.insert(match.immutableBundleKey)
            }

            guard missing.isEmpty else {
                throw ContainerizationError(
                    .notFound,
                    message: "container not found: \(missing.sorted().joined(separator: ", "))"
                )
            }
            return resolved
        }
    }
}
