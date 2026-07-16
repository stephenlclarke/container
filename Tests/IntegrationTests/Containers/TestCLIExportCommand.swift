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

import ContainerAPIClient
import ContainerizationArchive
import Foundation
import Testing

@Suite
struct TestCLIExportCommand {
    private struct StatusJSON: Decodable {
        let appRoot: String
    }

    @Test func testExportCreatedContainer() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-created"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try f.doRemoveIfExists(name, ignoreFailure: true) }

            let exportPath = f.testDir.appending("created-export.tar")
            try f.doExport(name, to: exportPath)

            let reader = try ArchiveReader(file: URL(filePath: exportPath.string))
            let (release, releaseData) = try reader.extractFile(path: "/etc/alpine-release")
            #expect(release.fileType == .regular)
            #expect(!releaseData.isEmpty)
        }
    }

    @Test func testExportRejectsCorruptMaterializedRootfsMetadata() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-corrupt-rootfs"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try f.doRemoveIfExists(name, ignoreFailure: true) }

            let status = try f.run(["system", "status", "--format", "json"]).check()
            let appRoot = try JSONDecoder().decode(StatusJSON.self, from: status.outputData).appRoot
            let rootfsMetadata = URL(filePath: appRoot, directoryHint: .isDirectory)
                .appending(path: "containers", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
                .appending(path: "rootfs.json")
            try Data("{".utf8).write(to: rootfsMetadata)

            let exportPath = f.testDir.appending("corrupt-export.tar")
            let result = try f.run(["export", name, "-o", exportPath.string])

            #expect(result.status != 0)
            #expect(!FileManager.default.fileExists(atPath: exportPath.string))
        }
    }

    @Test func testExportCommand() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, autoRemove: false) { name in
                let mustBeInImage = "must-be-in-image"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo"])
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /parent/child"])
                let hardlinkMustRemain = "hardlink-must-remain"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(hardlinkMustRemain) > /parent/child/bar"])
                try f.doExec(name, cmd: ["sh", "-c", "ln /parent/child/bar /bar"])
                let symlinkMustRemain = "symlink-must-remain"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(symlinkMustRemain) > /parent/child/baz"])
                try f.doExec(name, cmd: ["sh", "-c", "ln /parent/child/baz /baz"])

                try f.doStop(name)

                let exportPath = f.testDir.appending("export.tar")
                try f.doExport(name, to: exportPath)

                let exportURL = URL(filePath: exportPath.string)
                let attrs = try FileManager.default.attributesOfItem(atPath: exportPath.string)
                let fileSize = attrs[.size] as! UInt64
                #expect(fileSize > 0)

                // TODO: verify foo bar baz are in tar file.
                let reader = try ArchiveReader(file: exportURL)
                let (foo, fooData) = try reader.extractFile(path: "/foo")
                #expect(foo.fileType == .regular)
                #expect(String(data: fooData, encoding: .utf8)?.starts(with: mustBeInImage) ?? false)
            }
        }
    }

    @Test func testExportCommandLive() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, autoRemove: false) { name in
                let mustBeInImage = "must-be-in-image-live"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo-live"])

                let exportPath = f.testDir.appending("export-live.tar")
                try f.run(["export", "--live", name, "-o", exportPath.string]).check()

                let exportURL = URL(filePath: exportPath.string)
                let attrs = try FileManager.default.attributesOfItem(atPath: exportPath.string)
                let fileSize = attrs[.size] as! UInt64
                #expect(fileSize > 0)

                let reader = try ArchiveReader(file: exportURL)
                let (fooLive, fooLiveData) = try reader.extractFile(path: "/foo-live")
                #expect(fooLive.fileType == .regular)
                #expect(String(data: fooLiveData, encoding: .utf8)?.starts(with: mustBeInImage) ?? false)

                let mustRemainWritable = "must-remain-writable-live"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustRemainWritable) > /foo-after-live-export"])
                let verify = try f.doExec(name, cmd: ["cat", "/foo-after-live-export"])
                #expect(verify.trimmingCharacters(in: .whitespacesAndNewlines) == mustRemainWritable)
            }
        }
    }

    @Test func testExportCommandLiveWithoutFreeze() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, autoRemove: false) { name in
                let mustBeInImage = "must-be-in-image-live-no-freeze"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo-live-no-freeze && sync"])

                let exportPath = f.testDir.appending("export-live-no-freeze.tar")
                try await ContainerClient().export(
                    id: name,
                    archive: URL(filePath: exportPath.string),
                    live: true,
                    noFreeze: true,
                )

                let reader = try ArchiveReader(file: URL(filePath: exportPath.string))
                let (exported, exportedData) = try reader.extractFile(path: "/foo-live-no-freeze")
                #expect(exported.fileType == .regular)
                #expect(String(data: exportedData, encoding: .utf8)?.starts(with: mustBeInImage) ?? false)

                let mustRemainWritable = "must-remain-writable-live-no-freeze"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustRemainWritable) > /foo-after-live-no-freeze-export"])
                let verify = try f.doExec(name, cmd: ["cat", "/foo-after-live-no-freeze-export"])
                #expect(verify.trimmingCharacters(in: .whitespacesAndNewlines) == mustRemainWritable)
            }
        }
    }
}
