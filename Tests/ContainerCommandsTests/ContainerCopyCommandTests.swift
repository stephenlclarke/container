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
    @Test(arguments: [0o000, 0o640, 0o664, 0o755])
    func copyReadsSourcePermissionsWithoutArchiveMode(mode: UInt32) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("payload".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: source.path)

        #expect(try Application.ContainerCopy.sourceFileMode(FilePath(source.path)) == mode)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(try Application.ContainerCopy.sourceFileMode(FilePath(link.path)) == mode)
    }

    @Test func copySourcePermissionsRejectMissingSource() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: Error.self) {
            try Application.ContainerCopy.sourceFileMode(FilePath(source.path))
        }
    }

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

    @Test func copyPathReferencePreservesColonsInContainerPaths() throws {
        let ref = try Application.ContainerCopy.parsePathRef("example:/var/log/app-2026-07-20T10:30:00.log")

        guard case .container(let id, let path) = ref else {
            Issue.record("expected a container path reference")
            return
        }
        #expect(id == "example")
        #expect(path == "/var/log/app-2026-07-20T10:30:00.log")
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
