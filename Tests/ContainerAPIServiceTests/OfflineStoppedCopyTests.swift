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

import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import Darwin
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerAPIService

struct OfflineStoppedCopyTests {
    private let log = Logger(label: "offline-copy-test")

    @Test
    func runtimeAndMountOwnershipExcludeOfflineReading() throws {
        let image = ImageDescription(
            reference: "alpine", descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        let configuration = ContainerConfiguration(id: "offline", image: image, process: .init(executable: "/bin/true", arguments: [], environment: []))
        let state = ContainersService.ContainerState(snapshot: ContainerSnapshot(configuration: configuration, status: .stopped, networks: []))
        #expect(OfflineStoppedCopy.canReadRootfs(state))
        var excluded = state
        excluded.snapshot.status = .running
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.snapshot.status = .paused
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.snapshot.configuration.effectiveIsolation = .sharedVM
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.snapshot.configuration.runtimeHandler = "custom-runtime"
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.snapshot.configuration.mounts = [.tmpfs(destination: "/tmp", options: [])]
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.prewarmed = true
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.copyRuntime = true
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.prewarmCleanupRequired = true
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
        excluded = state
        excluded.prewarmCleanupRequiresLoggingClose = true
        #expect(!OfflineStoppedCopy.canReadRootfs(excluded))
    }

    @Test
    func rootfsMustBeAnOwnedPrivateBlockImage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = ContainerResource.Bundle(path: fixture.directory)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        let filesystem = Filesystem.block(format: "ext4", source: fixture.image.path, destination: "/", options: [])
        try bundle.setContainerRootFs(fs: filesystem)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == fixture.image)
        for mode in [0o620, 0o602, 0o666] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.image.path)
            #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.image.path)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == fixture.image)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .init(autoRemove: false, rootFsOverride: filesystem)) == nil)
        let other = fixture.directory.appendingPathComponent("other.ext4")
        try FileManager.default.copyItem(at: fixture.image, to: other)
        try bundle.setContainerRootFs(fs: .block(format: "ext4", source: other.path, destination: "/", options: []))
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        try bundle.setContainerRootFs(fs: .block(format: "xfs", source: fixture.image.path, destination: "/", options: []))
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        try bundle.setContainerRootFs(fs: .volume(name: "shared", format: "ext4", source: fixture.image.path, destination: "/", options: []))
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        try bundle.setContainerRootFs(fs: filesystem)
        let alias = fixture.directory.appendingPathComponent("alias.ext4")
        try FileManager.default.linkItem(at: fixture.image, to: alias)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.removeItem(at: fixture.image)
        try FileManager.default.createSymbolicLink(at: fixture.image, withDestinationURL: other)
        #expect(try OfflineStoppedCopy.rootfsURL(bundle: bundle, options: .default) == nil)
    }

    @Test
    func readonlyRootRejectsWritesWhileReadEligibilityIsUnchanged() throws {
        let image = ImageDescription(
            reference: "alpine",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        var configuration = ContainerConfiguration(id: "readonly", image: image, process: .init(executable: "/bin/true", arguments: [], environment: []))
        #expect(throws: Never.self) { try OfflineStoppedCopy.validateCopyInRootfs(configuration) }
        configuration.readOnly = true
        #expect(throws: ContainerizationError.self) { try OfflineStoppedCopy.validateCopyInRootfs(configuration) }
        let state = ContainersService.ContainerState(snapshot: ContainerSnapshot(configuration: configuration, status: .stopped, networks: []))
        #expect(OfflineStoppedCopy.canReadRootfs(state))
        configuration.mounts = [.tmpfs(destination: "/tmp", options: [])]
        #expect(throws: Never.self) { try OfflineStoppedCopy.validateCopyInRootfs(configuration) }
    }

    @Test
    func firstOfflineAccessMaterializesAndReusesPrivateFilesystem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = ContainerResource.Bundle(path: fixture.directory.appendingPathComponent("cold"))
        let kernel = Kernel(path: fixture.directory.appendingPathComponent("kernel"), platform: .linuxArm)
        try Data("kernel".utf8).write(to: kernel.path)
        let configuration = ContainerConfiguration(
            id: "cold",
            image: .init(
                reference: "alpine",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        let filesystem = Filesystem.block(format: "ext4", source: fixture.image.path, destination: "/", options: [])
        try RuntimeConfiguration(
            path: bundle.path, initialFilesystem: filesystem, kernel: kernel,
            containerConfiguration: configuration, containerRootFilesystem: filesystem,
            options: .default
        ).writeRuntimeConfiguration()
        let runtimeBefore = try Data(contentsOf: bundle.path.appendingPathComponent("runtime-configuration.json"))
        let sourceBefore = try Data(contentsOf: fixture.image)
        #expect(try !bundle.isPrepared)
        #expect(try OfflineStoppedCopy.prepareRootfs(bundle: bundle, options: .default) == bundle.containerRootfsBlock)
        #expect(try bundle.isPrepared)
        let output = fixture.directory.appendingPathComponent("cold-output")
        #expect(
            try OfflineStoppedCopy.copyOut(
                rootfs: bundle.containerRootfsBlock, source: "/real/target", destination: output.path,
                createParents: true, followSymlink: false, preserveOwnership: false, log: log))
        #expect(try Data(contentsOf: output) == fixture.payload)
        let handle = try FileHandle(forUpdating: bundle.containerRootfsBlock)
        defer { try? handle.close() }
        // A padding-byte edit detects accidental recloning on repeat access.
        try handle.seek(toOffset: 32)
        try handle.write(contentsOf: Data([0x7a]))
        #expect(try OfflineStoppedCopy.prepareRootfs(bundle: bundle, options: .default) == bundle.containerRootfsBlock)
        let reopened = try FileHandle(forReadingFrom: bundle.containerRootfsBlock)
        defer { try? reopened.close() }
        try reopened.seek(toOffset: 32)
        #expect(try reopened.read(upToCount: 1) == Data([0x7a]))
        #expect(try Data(contentsOf: fixture.image) == sourceBefore)
        #expect(try Data(contentsOf: bundle.path.appendingPathComponent("runtime-configuration.json")) == runtimeBefore)
        #expect(try OfflineStoppedCopy.prepareRootfs(bundle: bundle, options: .init(autoRemove: false, rootFsOverride: filesystem)) == nil)
    }

    @Test(arguments: [0o000, 0o640, 0o755])
    func regularFilePreservesBytesAndMode(mode: Int) throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.remove() }
        let imageBefore = try Data(contentsOf: fixture.image)
        let destination = fixture.directory.appendingPathComponent("out/target")
        #expect(try copy(fixture, source: "/parent/target", destination: destination, preserveOwnership: true))
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == mode)
        #expect((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        #expect((attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getgid())
        // Restore read permission only in the host output for the explicit-zero case.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #expect(try Data(contentsOf: destination) == fixture.payload)
        #expect(try Data(contentsOf: fixture.image) == imageBefore)
    }

    @Test(arguments: ["relative", "absolute", "dangling"])
    func symlinkCopyReplacesHostLinkWithoutFollowingIt(name: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sentinel = fixture.directory.appendingPathComponent("sentinel")
        let destination = fixture.directory.appendingPathComponent("link")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)
        #expect(try copy(fixture, source: "/\(name)", destination: destination, preserveOwnership: true))
        let targets = ["relative": "real/target", "absolute": "/real/target", "dangling": "missing/target"]
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == targets[name])
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
        var info = stat()
        #expect(lstat(destination.path, &info) == 0)
        #expect(info.st_uid == getuid() && info.st_gid == getgid())
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".container-copyout-") })
    }

    @Test
    func followedLinksAndHostDestinationLinksRetainFileSemantics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("host-target")
        let destination = fixture.directory.appendingPathComponent("host-link")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        #expect(try copy(fixture, source: "/relative", destination: destination, followSymlink: true))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == target.path)
        #expect(try Data(contentsOf: target) == fixture.payload)
        #expect(try copy(fixture, source: "/absolute", destination: target, followSymlink: true))
        let missing = fixture.directory.appendingPathComponent("must-not-exist")
        let error = #expect(throws: ContainerizationError.self) {
            try copy(fixture, source: "/dangling", destination: missing, followSymlink: true)
        }
        #expect(error?.code == .notFound)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test
    func archiveOutputPreservesMetadataAndCallerDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tar = fixture.directory.appendingPathComponent("result.tar")
        #expect(FileManager.default.createFile(atPath: tar.path, contents: nil))
        let output = try FileHandle(forWritingTo: tar)
        defer { try? output.close() }
        #expect(try OfflineStoppedCopy.copyOut(rootfs: fixture.image, source: "/relative", archive: output, followSymlink: true))
        let size = try output.offset()
        #expect(size > 0)
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tar)
        var iterator = reader.makeIterator()
        let next = iterator.next()
        let member = try #require(next)
        #expect(member.0.path == "relative")
        #expect(member.0.permissions & 0o777 == 0o640)
        #expect(member.1 == fixture.payload)
        #expect(iterator.next() == nil)
    }

    @Test
    func directoryFallbackDoesNotCreateOutputAndMissingParentFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("missing/output")
        #expect(try !copy(fixture, source: "/real", destination: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        #expect(throws: (any Error).self) {
            try OfflineStoppedCopy.copyOut(
                rootfs: fixture.image, source: "/real/target", destination: destination.path, createParents: false, followSymlink: false, preserveOwnership: false, log: log)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func journalRecoveryFallsBackBeforeCreatingOutput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try FileHandle(forUpdating: fixture.image)
        defer { try? image.close() }
        // ext4 s_feature_incompat is at byte 96 of the superblock at byte 1024.
        try image.seek(toOffset: 1024 + 96)
        let readFeatures = try image.read(upToCount: 4)
        var features = try #require(readFeatures)
        #expect(features.count == 4)
        features[0] |= 0x04
        try image.seek(toOffset: 1024 + 96)
        try image.write(contentsOf: features)
        let destination = fixture.directory.appendingPathComponent("must-not-exist")
        #expect(try !copy(fixture, source: "/real/target", destination: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func copy(_ fixture: Fixture, source: String, destination: URL, followSymlink: Bool = false, preserveOwnership: Bool = false) throws -> Bool {
        try OfflineStoppedCopy.copyOut(
            rootfs: fixture.image, source: source, destination: destination.path, createParents: true, followSymlink: followSymlink, preserveOwnership: preserveOwnership, log: log)
    }

    private struct Fixture {
        let directory: URL
        let image: URL
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })

        init(mode: Int = 0o640) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-copy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            image = directory.appendingPathComponent("rootfs.ext4")
            let formatter = try EXT4.Formatter(FilePath(image.path), minDiskSize: 4 * 1024 * 1024)
            try formatter.create(path: FilePath("/real"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            let stream = InputStream(data: payload)
            stream.open()
            defer { stream.close() }
            try formatter.create(path: FilePath("/real/target"), mode: EXT4.Inode.Mode(.S_IFREG, UInt16(mode)), buf: stream, uid: getuid(), gid: getgid())
            for (name, target) in [("relative", "real/target"), ("absolute", "/real/target"), ("dangling", "missing/target"), ("parent", "real")] {
                try formatter.create(path: FilePath("/\(name)"), link: FilePath(target), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777), uid: getuid(), gid: getgid())
            }
            try formatter.close()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
