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

import ContainerTestSupport
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ContainerTestSupportTests {

    @Test
    func assertionsReportCommandFailuresWithoutTestingRuntime() async throws {
        try await withFakeContainerCLI {
            try await ContainerFixture.with { fixture in
                try fixture.assertContainerHasFile("fixture", at: "present")
                try fixture.assertContainerMissingFile("fixture", at: "missing")
                try fixture.assertImageBuilt("expected")

                #expect {
                    try fixture.assertContainerHasFile("fixture", at: "missing")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "missing should exist in container"
                }

                #expect {
                    try fixture.assertContainerMissingFile("fixture", at: "present")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "present should NOT exist in container"
                }

                #expect {
                    try fixture.assertImageBuilt("mismatched")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "expected image mismatched to be present"
                }
            }
        }
    }

    private func withFakeContainerCLI<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-test-support-\(UUID().uuidString)", isDirectory: true)
        let executable = directory.appendingPathComponent("container", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
            #!/bin/sh
            if [ "$1" = "exec" ]; then
              case "$5" in
                present) exit 0 ;;
                *) exit 1 ;;
              esac
            fi
            if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
              case "$3" in
                expected) printf '%s\\n' '[{"configuration":{"name":"expected"},"variants":[]}]' ;;
                mismatched) printf '%s\\n' '[{"configuration":{"name":"other"},"variants":[]}]' ;;
                *) exit 1 ;;
              esac
              exit 0
            fi
            exit 1
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        guard chmod(executable.path, 0o755) == 0 else {
            throw CommandError.executionFailed("could not mark fake container executable")
        }

        let originalPath = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"]
        setenv("CONTAINER_CLI_PATH", executable.path, 1)
        defer {
            if let originalPath {
                setenv("CONTAINER_CLI_PATH", originalPath, 1)
            } else {
                unsetenv("CONTAINER_CLI_PATH")
            }
        }
        return try await body()
    }
}
