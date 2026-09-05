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

import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

struct MultiWriterTests {
    private static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    @Test
    func writeContinuesToLogAfterClientEPIPE() throws {
        Self.ignoreSIGPIPE()

        let clientPipe = Pipe()
        try clientPipe.fileHandleForReading.close()

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiwriter-log-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let logHandle = try FileHandle(forWritingTo: logURL)

        let writer = MultiWriter(handles: [clientPipe.fileHandleForWriting, logHandle])
        try writer.write(Data("tick still logged\n".utf8))
        try writer.write(Data("second line\n".utf8))
        try writer.close()

        #expect(writer.liveWriterCount == 0)
        let logged = try Data(contentsOf: logURL)
        #expect(String(decoding: logged, as: UTF8.self) == "tick still logged\nsecond line\n")
    }

    @Test
    func writeThrowsWhenEveryConsumerFails() throws {
        Self.ignoreSIGPIPE()

        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let writer = MultiWriter(handles: [pipe.fileHandleForWriting])

        #expect(throws: (any Error).self) {
            try writer.write(Data("no consumers\n".utf8))
        }
        #expect(writer.liveWriterCount == 0)
    }
}
