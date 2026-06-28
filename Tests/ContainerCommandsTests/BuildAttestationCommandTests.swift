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

@testable import ContainerCommands

struct BuildAttestationCommandTests {
    @Test
    func buildParsesAttestationOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("FROM scratch\n".utf8).write(to: directory.appendingPathComponent("Dockerfile"))

        let command = try Application.BuildCommand.parse([
            "--provenance", "mode=max",
            "--sbom", "true",
            "--tag", "example/app:latest",
            directory.path,
        ])

        #expect(command.provenance == "mode=max")
        #expect(command.sbom == "true")
        #expect(command.contextDir == directory.path)
        #expect(command.targetImageNames == ["example/app:latest"])
    }
}
