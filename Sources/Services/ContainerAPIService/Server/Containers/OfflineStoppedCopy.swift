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
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import Darwin
import Foundation
import Logging
import SystemPackage

/// Read-only copies from an exclusively owned, unmounted root filesystem.
/// The caller holds the container's lifecycle mutation slot throughout the operation.
enum OfflineStoppedCopy {
    static func canReadRootfs(_ state: ContainersService.ContainerState) -> Bool {
        state.snapshot.status == .stopped
            && state.snapshot.configuration.effectiveIsolation == .dedicatedVM
            && state.snapshot.configuration.runtimeHandler == "container-runtime-linux"
            && state.snapshot.configuration.mounts.isEmpty
            && state.client == nil
            && !state.prewarmed && !state.copyRuntime && !state.prewarmCleanupRequired
            && !state.prewarmCleanupRequiresLoggingClose
    }

    /// Called before the first offline access while holding the lifecycle slot.
    /// RuntimeLinux observes the same final readiness marker on a later boot.
    static func prepareRootfs(bundle: ContainerResource.Bundle, options: ContainerCreateOptions) throws -> URL? {
        guard options.rootFsOverride == nil else { return nil }
        if try !bundle.isPrepared {
            let runtime = try RuntimeConfiguration.readRuntimeConfiguration(from: bundle.path)
            guard runtime.path.standardizedFileURL == bundle.path.standardizedFileURL,
                let configuration = runtime.containerConfiguration,
                configuration.effectiveIsolation == .dedicatedVM,
                configuration.runtimeHandler == "container-runtime-linux", configuration.mounts.isEmpty,
                runtime.options?.rootFsOverride == nil,
                let filesystem = runtime.containerRootFilesystem,
                case .block(let format, _, _) = filesystem.type,
                format == "ext4", filesystem.destination == "/", filesystem.sourceSubpath == nil
            else { return nil }
            _ = try ContainerResource.Bundle.create(
                path: runtime.path, initialFilesystem: runtime.initialFilesystem,
                kernel: runtime.kernel, containerConfiguration: configuration,
                containerRootFilesystem: filesystem, options: runtime.options
            )
        }
        return try rootfsURL(bundle: bundle, options: options)
    }

    static func rootfsURL(bundle: ContainerResource.Bundle, options: ContainerCreateOptions) throws -> URL? {
        guard options.rootFsOverride == nil else { return nil }
        let filesystem: Filesystem
        do {
            filesystem = try bundle.containerRootfs
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A never-prepared container has no private materialized rootfs yet.
            return nil
        }
        guard case .block(let format, _, _) = filesystem.type,
            format == "ext4", filesystem.destination == "/", filesystem.sourceSubpath == nil,
            URL(fileURLWithPath: filesystem.source).standardizedFileURL == bundle.containerRootfsBlock.standardizedFileURL
        else { return nil }

        var info = stat()
        guard lstat(bundle.containerRootfsBlock.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Shared write access, symlinks and hard links do not establish private ownership.
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
            info.st_uid == getuid(), info.st_mode & 0o022 == 0
        else { return nil }
        return bundle.containerRootfsBlock
    }

    /// False selects the existing guest transfer for unsupported offline cases.
    static func copyOut(
        rootfs: URL, source: String, destination: String, createParents: Bool,
        followSymlink: Bool, preserveOwnership: Bool, log: Logger
    ) throws -> Bool {
        guard let reader = try open(rootfs: rootfs) else { return false }
        let path = FilePath(source)
        let inode = try sourceInode(reader: reader, path: path, followSymlink: followSymlink)
        let kind = mode_t(inode.mode) & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { return false }
        let size = UInt64(inode.sizeHigh) << 32 | UInt64(inode.sizeLow)
        guard Int64(exactly: size) != nil else { throw EXT4.Error.invalidExtents }

        let output = URL(fileURLWithPath: destination)
        if createParents {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if kind == mode_t(S_IFLNK) {
            try installSymlink(reader: reader, source: path, destination: output, inode: inode, preserveOwnership: preserveOwnership, log: log)
        } else {
            let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while offset < size {
                let data = try reader.readFile(at: path, offset: offset, count: Int(min(64 * 1024, size - offset)), followSymlinks: followSymlink)
                guard !data.isEmpty else { throw EXT4.Error.invalidExtents }
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            }
            let uid = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
            let gid = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
            if preserveOwnership, fchown(fd, uid, gid) != 0 {
                log.debug("copyOut: unable to preserve ownership", metadata: ["error": "\(String(cString: strerror(errno)))"])
            }
            if fchmod(fd, mode_t(inode.mode) & 0o777) != 0 {
                log.debug("copyOut: unable to preserve mode", metadata: ["error": "\(String(cString: strerror(errno)))"])
            }
        }
        return true
    }

    static func copyOut(rootfs: URL, source: String, archive: FileHandle, followSymlink: Bool) throws -> Bool {
        guard let reader = try open(rootfs: rootfs) else { return false }
        let path = FilePath(source)
        let inode = try sourceInode(reader: reader, path: path, followSymlink: followSymlink)
        let kind = mode_t(inode.mode) & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { return false }
        let staging = try makeStaging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tar = staging.appendingPathComponent("copy.tar")
        try reader.export(archive: FilePath(tar.path), selectedPath: path, followSymlink: followSymlink)
        let input = try FileHandle(forReadingFrom: tar)
        defer { try? input.close() }
        // Keep ownership and lifetime of the caller's descriptor unchanged.
        let fd = dup(archive.fileDescriptor)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try output.write(contentsOf: data)
        }
        return true
    }

    private static func open(rootfs: URL) throws -> EXT4.EXT4Reader? {
        do {
            return try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path), requireCleanJournal: true)
        } catch EXT4.Error.journalRecoveryRequired {
            // Guest mounting replays the journal; never read stale offline metadata.
            return nil
        }
    }

    private static func sourceInode(reader: EXT4.EXT4Reader, path: FilePath, followSymlink: Bool) throws -> EXT4.Inode {
        do {
            return try reader.stat(path, followSymlinks: followSymlink).inode
        } catch EXT4.PathIOError.notFound {
            throw ContainerizationError(.notFound, message: "copy: path not found '\(path)'")
        } catch let error as EXT4.PathIOError {
            throw ContainerizationError(.internalError, message: "copy: failed to open '\(path)': \(error)")
        }
    }

    private static func makeStaging(in parent: URL) throws -> URL {
        let staging = parent.appendingPathComponent(".container-copyout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return staging
    }

    private static func installSymlink(
        reader: EXT4.EXT4Reader, source: FilePath, destination: URL, inode: EXT4.Inode, preserveOwnership: Bool, log: Logger
    ) throws {
        guard let name = source.lastComponent, case .regular = name.kind else {
            throw ContainerizationError(.invalidArgument, message: "copyOut requires a regular final path component")
        }
        let staging = try makeStaging(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: staging) }
        let tar = staging.appendingPathComponent("link.tar")
        let contents = staging.appendingPathComponent("contents", isDirectory: true)
        try reader.export(archive: FilePath(tar.path), selectedPath: source, followSymlink: false)
        let archive = try ArchiveReader(format: .pax, filter: .none, file: tar)
        let rejected = try archive.extractContents(to: contents, preserveOwnership: false)
        let inventory = try FileManager.default.contentsOfDirectory(atPath: contents.path)
        let link = contents.appendingPathComponent(name.string)
        var info = stat()
        guard rejected.isEmpty, inventory == [name.string], lstat(link.path, &info) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        else {
            throw ContainerizationError(.invalidArgument, message: "copyOut expected exactly one symbolic link archive member")
        }
        if preserveOwnership {
            let uid = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
            let gid = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
            if lchown(link.path, uid, gid) != 0 {
                log.debug("copyOut: unable to preserve symbolic link ownership", metadata: ["error": "\(String(cString: strerror(errno)))"])
            }
        }
        guard rename(link.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
