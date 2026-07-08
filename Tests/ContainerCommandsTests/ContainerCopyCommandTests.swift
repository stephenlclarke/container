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
import SystemPackage
import Testing

@testable import ContainerCommands

struct ContainerCopyCommandTests {
    @Test func copyParsesShortArchiveFlag() throws {
        let command = try Application.ContainerCopy.parse([
            "-a",
            "example:/tmp/file",
            "./file",
        ])

        #expect(command.archive)
    }

    @Test func copyParsesLongArchiveFlag() throws {
        let command = try Application.ContainerCopy.parse([
            "--archive",
            "./file",
            "example:/tmp/file",
        ])

        #expect(command.archive)
    }

    @Test func copyDefaultsArchiveToFalse() throws {
        let command = try Application.ContainerCopy.parse([
            "example:/tmp/file",
            "./file",
        ])

        #expect(!command.archive)
    }

    @Test func copyParsesShortFollowLinkFlag() throws {
        let command = try Application.ContainerCopy.parse([
            "-L",
            "example:/tmp/link",
            "./link",
        ])

        #expect(command.followLink)
    }

    @Test func copyParsesLongFollowLinkFlag() throws {
        let command = try Application.ContainerCopy.parse([
            "--follow-link",
            "./link",
            "example:/tmp/link",
        ])

        #expect(command.followLink)
    }

    @Test func copyDefaultsFollowLinkToFalse() throws {
        let command = try Application.ContainerCopy.parse([
            "example:/tmp/link",
            "./link",
        ])

        #expect(!command.followLink)
    }

    @Test func localFilePathResolvesRelativePathsAgainstWorkingDirectory() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expected = cwd.appendingPathComponent("copy-output").standardizedFileURL.path

        #expect(Application.ContainerCopy.localFilePath("copy-output") == FilePath(expected))
    }

    @Test func localFilePathStandardizesParentComponents() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expected = cwd.appendingPathComponent("copy-output").standardizedFileURL.path

        #expect(Application.ContainerCopy.localFilePath("./scratch/../copy-output") == FilePath(expected))
    }

    @Test func localFilePathPreservesAbsolutePaths() {
        #expect(Application.ContainerCopy.localFilePath("/tmp/../tmp/copy-output") == FilePath("/tmp/copy-output"))
    }

    @Test func localFilePathExpandsTilde() {
        let expected = FilePath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("copy-output").path)

        #expect(Application.ContainerCopy.localFilePath("~/copy-output") == expected)
    }
}
