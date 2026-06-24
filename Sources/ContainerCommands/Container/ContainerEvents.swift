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
import Foundation

extension Application {
    public struct ContainerEvents: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "Stream container lifecycle events as JSON lines")

        @Option(name: .long, help: "Show events after the specified RFC 3339, Unix timestamp, or relative duration")
        var since: ContainerEventTimestamp?

        @Option(name: .long, help: "Stream events until the specified RFC 3339, Unix timestamp, or relative duration")
        var until: ContainerEventTimestamp?

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let client = ContainerClient()
            defer {
                _ = client
            }
            let eventStream = try await client.events(options: Self.eventOptions(since: since, until: until))
            defer {
                try? eventStream.close()
            }
            try await LogFileOutput.writeStream(fh: eventStream)
        }

        static func eventOptions(
            since: ContainerEventTimestamp?,
            until: ContainerEventTimestamp?
        ) -> ContainerEventOptions {
            ContainerEventOptions(
                since: since?.date,
                until: until?.date
            )
        }
    }
}

struct ContainerEventTimestamp: ExpressibleByArgument, Equatable {
    let date: Date

    init?(argument: String) {
        if let date = ContainerLogTimestampParser.parse(argument) {
            self.date = date
            return
        }
        return nil
    }
}
