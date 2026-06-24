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
import Foundation

extension Application {
    public struct ContainerLogs: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Fetch container logs"
        )

        @Flag(name: .long, help: "Display the boot log for the container instead of stdio")
        var boot: Bool = false

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(name: [.short, .customLong("tail")], help: "Number of lines to show from the end of the logs. If not provided this will print all of the logs")
        var numLines: Int?

        @Option(name: .long, help: "Show logs after the specified RFC 3339 or Unix timestamp")
        var since: ContainerLogTimestamp?

        @Option(name: .long, help: "Show logs before the specified RFC 3339 or Unix timestamp")
        var until: ContainerLogTimestamp?

        @Flag(name: [.customShort("t"), .customLong("timestamps")], help: "Show timestamps")
        var timestamps: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func validate() throws {
            try Self.validateLogOptions(
                boot: boot,
                follow: follow,
                since: since,
                until: until,
                timestamps: timestamps
            )
        }

        public func run() async throws {
            let client = ContainerClient()
            let containerID = containerId
            if !boot && Self.usesStructuredRecords(follow: follow, since: since, until: until, timestamps: timestamps) {
                if follow {
                    let options = ContainerLogOptions(
                        tail: numLines,
                        since: since?.date,
                        until: until?.date
                    )
                    let recordFile = try await client.followLogRecords(id: containerID, options: options)
                    defer {
                        try? recordFile.close()
                    }
                    try await LogRecordOutput.write(
                        recordFile: recordFile,
                        n: nil,
                        follow: true,
                        since: nil,
                        until: nil,
                        timestamps: timestamps,
                    )
                } else {
                    let records = try await client.logRecords(
                        id: containerID,
                        replay: Self.staticReplayOptions()
                    )
                    try LogRecordOutput.write(
                        records: records,
                        n: numLines,
                        since: since?.date,
                        until: until?.date,
                        timestamps: timestamps
                    )
                }
                return
            }

            let options = Self.retrievalOptions(
                numLines: numLines,
                follow: follow,
                since: since,
                until: until
            )

            if follow && !boot {
                let followOptions = ContainerLogOptions(
                    tail: numLines,
                    since: since?.date,
                    until: until?.date
                )
                let fileHandle = try await client.followLogs(id: containerID, options: followOptions)
                defer {
                    try? fileHandle.close()
                }
                try await LogFileOutput.writeStream(fh: fileHandle)
                return
            }

            let fhs = try await client.logs(id: containerID, options: options, replay: Self.replayOptions(follow: follow))
            let fileHandle = boot ? fhs[1] : fhs[0]
            defer {
                for handle in fhs {
                    try? handle.close()
                }
            }

            try await LogFileOutput.write(
                fh: fileHandle,
                n: follow ? numLines : nil,
                follow: follow,
            )
        }

        static func validateLogOptions(
            boot: Bool,
            follow: Bool,
            since: ContainerLogTimestamp?,
            until: ContainerLogTimestamp?,
            timestamps: Bool
        ) throws {
            if boot && timestamps {
                throw ValidationError("--boot cannot be combined with --timestamps")
            }
            if boot && follow && (since != nil || until != nil) {
                throw ValidationError("--boot cannot be combined with followed time filters")
            }
        }

        static func retrievalOptions(
            numLines: Int?,
            follow: Bool,
            since: ContainerLogTimestamp?,
            until: ContainerLogTimestamp?
        ) -> ContainerLogOptions {
            ContainerLogOptions(
                tail: follow ? nil : numLines,
                since: since?.date,
                until: until?.date
            )
        }

        static func replayOptions(follow: Bool) -> ContainerLogReplayOptions {
            ContainerLogReplayOptions(includeRotated: !follow)
        }

        static func staticReplayOptions() -> ContainerLogReplayOptions {
            ContainerLogReplayOptions(includeRotated: true)
        }

        static func usesStructuredRecords(
            follow: Bool,
            since: ContainerLogTimestamp?,
            until: ContainerLogTimestamp?,
            timestamps: Bool
        ) -> Bool {
            timestamps || since != nil || until != nil
        }

    }
}

struct ContainerLogTimestamp: ExpressibleByArgument, Equatable {
    let date: Date

    init?(argument: String) {
        if let date = ContainerLogTimestampParser.parse(argument) {
            self.date = date
            return
        }
        return nil
    }
}
