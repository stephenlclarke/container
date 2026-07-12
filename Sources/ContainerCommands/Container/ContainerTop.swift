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

extension Application {
    public struct ContainerTop: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "top",
            abstract: "Display running processes for a container")

        @Argument(help: "Container ID")
        var container: String

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let processes = try await ContainerClient().processes(id: container)
            try Output.render(payload: processes, format: format) {
                Self.processTable(processes)
            }
        }

        static func processTable(_ processes: ContainerProcesses) -> String {
            if !processes.processes.isEmpty {
                let rows =
                    [["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"]]
                    + processes.processes.map { process in
                        [
                            process.uid,
                            String(process.pid),
                            String(process.ppid),
                            String(process.cpu),
                            process.startTime,
                            process.tty,
                            process.time,
                            process.command,
                        ]
                    }
                return TableOutput(rows: rows).format()
            }

            var rows = [["Container ID", "PID"]]
            for pid in processes.processIdentifiers {
                rows.append([processes.id, String(pid)])
            }
            return TableOutput(rows: rows).format()
        }
    }
}
