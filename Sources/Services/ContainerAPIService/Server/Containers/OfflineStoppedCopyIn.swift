// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.

import COfflineCopyProcess
import ContainerizationEXT4
import CryptoKit
import Darwin
import Foundation
import Logging
import Security
import SystemPackage

/// The lifecycle owner calls this synchronously off the actor, and awaits its
/// completion before releasing its mutation slot. Only the staged clone is writable.
enum OfflineStoppedCopyIn {
    static let helperName = "container-ext4-copy"

    static func discoverHelper() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/container/helpers/\(helperName)")
        return FileManager.default.isExecutableFile(atPath: installed.path) ? installed : nil
    }

    /// Overlap first executable/sandbox initialization with API startup. This
    /// never opens a container image and never replaces per-copy authentication.
    static func prepareHelper(helper: URL?, log: Logger) -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        guard let helper, verifyHelper(helper, log: log) else { return false }
        var status: Int32 = -1
        let launch = helper.path.withCString { cec_probe($0, 5, &status) }
        log.debug("copyIn: helper preparation", metadata: ["launch": "\(launch)", "status": "\(status)", "duration": "\(started.duration(to: clock.now))"])
        return launch == 0 && status == 0
    }

    static func copy(
        rootfs: URL, source: String, destination: String, mode: UInt32,
        createParents: Bool, followSymlink: Bool, preserveOwnership: Bool,
        helper: URL, log: Logger
    ) throws -> Bool {
        let clock = ContinuousClock()
        var started = clock.now
        func phase(_ name: String) {
            let now = clock.now
            log.debug("copyIn: writer phase", metadata: ["phase": "\(name)", "duration": "\(started.duration(to: now))"])
            started = now
        }
        guard !source.utf8.contains(0), !destination.utf8.contains(0),
            verifyHelper(helper, log: log)
        else { return false }
        phase("authenticateHelper")
        let originalSource = URL(fileURLWithPath: source)
        let resolvedSource = followSymlink ? originalSource.resolvingSymlinksInPath() : originalSource
        let sourceFD = Darwin.open(resolvedSource.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { return false }
        defer { Darwin.close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0,
            sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), sourceInfo.st_size >= 0
        else { return false }
        let parent = rootfs.deletingLastPathComponent()
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { return false }
        defer { Darwin.close(parentFD) }
        let originalFD = openat(parentFD, rootfs.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard originalFD >= 0 else { return false }
        defer { Darwin.close(originalFD) }
        var originalInfo = stat()
        guard fstat(originalFD, &originalInfo) == 0,
            originalInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            originalInfo.st_uid == getuid(), originalInfo.st_nlink == 1,
            originalInfo.st_mode & 0o022 == 0,
            !(originalInfo.st_dev == sourceInfo.st_dev && originalInfo.st_ino == sourceInfo.st_ino)
        else { return false }

        let stagingName = ".container-copyin-\(UUID().uuidString)"
        guard mkdirat(parentFD, stagingName, 0o700) == 0 else { return false }
        let staging = parent.appendingPathComponent(stagingName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagingFD = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { return false }
        defer { Darwin.close(stagingFD) }
        guard clonefileat(parentFD, rootfs.lastPathComponent, stagingFD, "rootfs", UInt32(CLONE_NOFOLLOW)) == 0 else { return false }
        let staged = staging.appendingPathComponent("rootfs")
        let imageFD = openat(stagingFD, "rootfs", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard imageFD >= 0 else { return false }
        defer { Darwin.close(imageFD) }
        guard fchmod(imageFD, 0o600) == 0 else { return false }

        phase("clonePrivateImage")
        let permissions = mode & 0o777
        let arguments = [
            helper.path, "--protocol=1", destination, originalSource.lastPathComponent,
            String(permissions), String(sourceInfo.st_uid), String(sourceInfo.st_gid),
            createParents ? "1" : "0", preserveOwnership ? "1" : "0",
        ]
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { $0.map { UnsafePointer($0) } } + [nil]
        var status: Int32 = -1
        let launch = helper.path.withCString { path in
            pointers.withUnsafeMutableBufferPointer {
                cec_run(path, $0.baseAddress, imageFD, sourceFD, 30, &status)
            }
        }
        phase("helperTransfer")
        guard launch == 0, status == 0 else {
            log.debug("copyIn: offline helper selected guest transfer", metadata: ["launch": "\(launch)", "status": "\(status)"])
            return false
        }
        // Independent SDK readback catches unsupported layouts and verifies the
        // exact transferred bytes and requested metadata before any live change.
        do {
            try verifyCopy(
                staged: staged, sourceFD: sourceFD, sourceInfo: sourceInfo,
                destination: destination, basename: originalSource.lastPathComponent,
                mode: permissions, preserveOwnership: preserveOwnership)
        } catch {
            log.debug("copyIn: offline readback selected guest transfer", metadata: ["error": "\(error)"])
            return false
        }
        phase("independentReadback")
        var current = stat()
        var sourceAfter = stat()
        var stagedInfo = stat()
        guard fstatat(parentFD, rootfs.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
            sameFile(originalInfo, current), fstat(originalFD, &current) == 0,
            sameFile(originalInfo, current), fstat(sourceFD, &sourceAfter) == 0,
            sameFile(sourceInfo, sourceAfter), fstat(imageFD, &stagedInfo) == 0,
            stagedInfo.st_uid == getuid(), stagedInfo.st_nlink == 1
        else { return false }
        guard fchmod(imageFD, originalInfo.st_mode & 0o777) == 0, fsync(imageFD) == 0 else { return false }
        guard renameat(stagingFD, "rootfs", parentFD, rootfs.lastPathComponent) == 0 else { return false }
        // The rename already committed. A sync failure must be reported rather
        // than falling back and accidentally performing the copy a second time.
        guard fsync(parentFD) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        phase("commit")
        return true
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func verifyCopy(
        staged: URL, sourceFD: Int32, sourceInfo: stat, destination: String,
        basename: String, mode: UInt32, preserveOwnership: Bool
    ) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(staged.path), requireCleanJournal: true)
        var path = FilePath(destination)
        var inode = try reader.stat(path).inode
        if mode_t(inode.mode) & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            path.append(basename)
            inode = try reader.stat(path).inode
        }
        let size = UInt64(inode.sizeHigh) << 32 | UInt64(inode.sizeLow)
        guard mode_t(inode.mode) & mode_t(S_IFMT) == mode_t(S_IFREG),
            size == UInt64(sourceInfo.st_size), UInt32(inode.mode) & 0o777 == mode
        else { throw CocoaError(.fileReadCorruptFile) }
        if preserveOwnership {
            guard (UInt32(inode.uidHigh) << 16 | UInt32(inode.uid)) == sourceInfo.st_uid,
                (UInt32(inode.gidHigh) << 16 | UInt32(inode.gid)) == sourceInfo.st_gid
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < size {
            let wanted = Int(min(UInt64(buffer.count), size - offset))
            let actual = buffer.withUnsafeMutableBytes { pread(sourceFD, $0.baseAddress, wanted, off_t(offset)) }
            if actual < 0 && errno == EINTR { continue }
            guard actual > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = try reader.readFile(at: path, offset: offset, count: actual)
            guard bytes == Data(buffer.prefix(actual)) else { throw CocoaError(.fileReadCorruptFile) }
            offset += UInt64(actual)
        }
    }

    private static func verifyHelper(_ helper: URL, log: Logger) -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        let manifest = helper.deletingLastPathComponent().appendingPathComponent(helperName + ".manifest.json")
        guard let bytes = try? Data(contentsOf: manifest), bytes.count <= 1024 * 1024,
            let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            fields["protocol"] as? Int == 1,
            let executable = try? Data(contentsOf: helper, options: .mappedIfSafe),
            fields["binarySHA256"] as? String == SHA256.hash(data: executable).map({ String(format: "%02x", $0) }).joined()
        else { return false }
        log.debug("copyIn: writer phase", metadata: ["phase": "helperDigest", "duration": "\(started.duration(to: clock.now))"])
        let signatureStarted = clock.now
        defer { log.debug("copyIn: writer phase", metadata: ["phase": "helperSignature", "duration": "\(signatureStarted.duration(to: clock.now))"]) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }
}
