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

import ContainerizationEXT4
import ContainerizationError
import Foundation
import MachineAPIService
import SystemPackage
import Testing

@Suite
struct MachineRootfsValidationTests {
    private static let testImage = "docker.io/library/ubuntu:latest"

    private struct RootfsFixture {
        let directory: URL
        let blockDevice: FilePath

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Create an ext4 block file in a temporary directory, populated by `populate`.
    private func makeRootfs(populate: (EXT4.Formatter) throws -> Void) throws -> RootfsFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineRootfsValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blockDevice = FilePath(dir.appendingPathComponent("rootfs.ext4").path)
        let formatter = try EXT4.Formatter(blockDevice, minDiskSize: 2.mib())
        do {
            try populate(formatter)
            try formatter.close()
        } catch {
            try? formatter.close()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return RootfsFixture(directory: dir, blockDevice: blockDevice)
    }

    @Test func passesWhenInitIsRegularFile() throws {
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/sbin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/sbin/init"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755))
        }
        defer { fixture.remove() }
        try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
    }

    @Test func passesWhenInitIsSymlinkToExistingFile() throws {
        // Mirrors a systemd image: /sbin/init -> /lib/systemd/systemd
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/sbin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/lib"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/lib/systemd"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/lib/systemd/systemd"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755))
            try formatter.create(path: FilePath("/sbin/init"), link: FilePath("/lib/systemd/systemd"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }
        defer { fixture.remove() }
        try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
    }

    @Test func throwsWhenInitIsMissing() throws {
        // Mirrors a standard application image such as ubuntu:latest or alpine.
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/bin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/bin/sh"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755))
        }
        defer { fixture.remove() }
        let error = #expect(throws: ContainerizationError.self) {
            try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
        }
        let message = try #require(error).message
        #expect(message.contains("/sbin/init"))
        #expect(message.contains(Self.testImage))
    }

    @Test func throwsWhenInitIsDanglingSymlink() throws {
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/sbin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/sbin/init"), link: FilePath("/lib/systemd/systemd"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }
        defer { fixture.remove() }
        #expect(throws: ContainerizationError.self) {
            try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
        }
    }

    @Test func throwsWhenInitIsDirectory() throws {
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/sbin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/sbin/init"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        }
        defer { fixture.remove() }
        #expect(throws: ContainerizationError.self) {
            try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
        }
    }

    @Test func throwsWhenInitIsNotExecutable() throws {
        let fixture = try makeRootfs { formatter in
            try formatter.create(path: FilePath("/sbin"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/sbin/init"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644))
        }
        defer { fixture.remove() }
        #expect(throws: ContainerizationError.self) {
            try MachinesService.validateMachineRootfs(blockDevice: fixture.blockDevice, image: Self.testImage)
        }
    }
}
