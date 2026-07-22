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

import ContainerLog
import Foundation
import Logging
import SystemPackage
import Testing

struct LogHandlerTests {
    @Test func fileLogHandlerWritesLegacyAndSwiftLogEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-handler-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let logURL = directory.appendingPathComponent("container.log", isDirectory: false)
        var handler = try FileLogHandler(label: "container-test", category: "unit", path: FilePath(logURL.path))
        handler.metadata["suite"] = "log-handler"

        handler.log(
            event: LogEvent(
                level: .info,
                message: "event-path",
                metadata: ["request": "abc123"],
                source: "ContainerLogTests",
                file: #fileID,
                function: #function,
                line: #line
            ))

        handler.log(
            level: .notice,
            message: "swift-log-path",
            metadata: ["request": "def456"],
            source: "ContainerLogTests",
            file: #fileID,
            function: #function,
            line: #line
        )

        let output = try String(contentsOf: logURL, encoding: .utf8)
        #expect(output.contains("[info] container-test unit"))
        #expect(output.contains("event-path"))
        #expect(output.contains("suite"))
        #expect(output.contains("request"))
        #expect(output.contains("swift-log-path"))
        #expect(output.contains("def456"))
    }
}
