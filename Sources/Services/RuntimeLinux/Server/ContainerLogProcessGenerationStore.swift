//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import CryptoKit
import Darwin
import Foundation

package enum ContainerLogProcessGenerationError: Error, Equatable, Sendable {
    package enum Operation: Equatable, Sendable {
        case close
        case createDirectory
        case enumerate
        case lock
        case metadata
        case open
        case openDirectory
        case openLockFile
        case openStateFile
        case createTemporaryFile
        case read
        case remove
        case rename
        case synchronize
        case unlock
        case write
    }

    case invalidRoot
    case unsafeStorage
    case invalidEncoding
    case exhausted
    case temporaryNameCollision
    case io(Operation, Int32)
}

/// Crash-safe allocator for a container's logging process generation.
///
/// The generation is durably advanced before it is returned. Callers may lose
/// a value when start later fails, but a generation returned to a session is
/// never reused after a helper or host crash. An atomically acquired `O_EXLOCK`
/// file descriptor serializes independent helpers while an in-process lock
/// serializes calls made through one store instance.
package final class ContainerLogProcessGenerationStore: @unchecked Sendable {
    private static let stateFileName = "process-generation-v1.bin"
    private static let lockFileName = ".process-generation-v1.lock"
    private static let temporaryPrefix = ".process-generation-v1.tmp."
    private static let magic = Data("CLOGGEN1".utf8)
    private static let encodedByteCount = magic.count + MemoryLayout<UInt64>.size + SHA256.byteCount
    private static let maximumDirectoryEntries = 1_024
    private static let maximumPublicationAttempts = 8
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)
    /// BSD advisory locks do not provide an intra-process ownership boundary
    /// between independently opened descriptors on every supported Darwin
    /// release. Serialize helpers in this process before taking the durable
    /// cross-process lock.
    private static let processLock = NSLock()

    package let directoryURL: URL

    private let directoryDescriptor: Int32

    package init(directoryURL: URL) throws {
        let directoryDescriptor = try Self.openDirectory(directoryURL)
        do {
            let allocationLockDescriptor = try Self.processLock.withLock {
                try Self.openLockFile(
                    directoryDescriptor: directoryDescriptor,
                    exclusive: false
                )
            }
            Darwin.close(allocationLockDescriptor)
            self.directoryURL = directoryURL
            self.directoryDescriptor = directoryDescriptor
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(directoryDescriptor)
    }

    /// Returns a newly durable generation. Gaps are valid; reuse is not.
    package func next() throws -> UInt64 {
        try Self.processLock.withLock {
            try Self.validateDirectoryDescriptor(directoryDescriptor)
            let allocationLockDescriptor = try acquireAllocationLock()
            do {
                try removeInterruptedTemporaryFiles()
                let current = try readCurrentGeneration()
                guard current < UInt64.max else {
                    throw ContainerLogProcessGenerationError.exhausted
                }
                let candidate = current + 1
                try publish(candidate)
                guard Darwin.close(allocationLockDescriptor) == 0 else {
                    throw ContainerLogProcessGenerationError.io(.unlock, errno)
                }
                return candidate
            } catch {
                Darwin.close(allocationLockDescriptor)
                throw error
            }
        }
    }

    private func acquireAllocationLock() throws -> Int32 {
        try Self.openLockFile(directoryDescriptor: directoryDescriptor, exclusive: true)
    }

    private func readCurrentGeneration() throws -> UInt64 {
        let descriptor = Self.stateFileName.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                return 0
            }
            throw ContainerLogProcessGenerationError.io(.openStateFile, code)
        }
        defer { Darwin.close(descriptor) }
        try Self.validateRegularFileDescriptor(descriptor)

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ContainerLogProcessGenerationError.io(.metadata, errno)
        }
        guard metadata.st_size == Self.encodedByteCount else {
            throw ContainerLogProcessGenerationError.invalidEncoding
        }
        let data = try Self.readExactly(descriptor: descriptor, count: Self.encodedByteCount)
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ContainerLogProcessGenerationError.io(.metadata, errno)
        }
        guard metadata.st_size == Self.encodedByteCount else {
            throw ContainerLogProcessGenerationError.invalidEncoding
        }
        return try Self.decode(data)
    }

    private func publish(_ generation: UInt64) throws {
        let encoded = Self.encode(generation)
        for _ in 0..<Self.maximumPublicationAttempts {
            let temporaryName = Self.temporaryPrefix + UUID().uuidString.lowercased()
            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    Self.fileMode
                )
            }
            if descriptor < 0 {
                let code = errno
                if code == EEXIST {
                    continue
                }
                throw ContainerLogProcessGenerationError.io(.createTemporaryFile, code)
            }

            var descriptorNeedsClose = true
            var temporaryNeedsRemoval = true
            defer {
                if descriptorNeedsClose {
                    Darwin.close(descriptor)
                }
                if temporaryNeedsRemoval {
                    temporaryName.withCString {
                        _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }
                }
            }

            do {
                try Self.validateRegularFileDescriptor(descriptor)
                try Self.writeAll(encoded, descriptor: descriptor)
                guard Darwin.fsync(descriptor) == 0 else {
                    throw ContainerLogProcessGenerationError.io(.synchronize, errno)
                }
                guard Darwin.close(descriptor) == 0 else {
                    descriptorNeedsClose = false
                    throw ContainerLogProcessGenerationError.io(.close, errno)
                }
                descriptorNeedsClose = false

                let result = temporaryName.withCString { temporaryPointer in
                    Self.stateFileName.withCString { statePointer in
                        Darwin.renameat(
                            directoryDescriptor,
                            temporaryPointer,
                            directoryDescriptor,
                            statePointer
                        )
                    }
                }
                guard result == 0 else {
                    throw ContainerLogProcessGenerationError.io(.rename, errno)
                }
                temporaryNeedsRemoval = false
                try synchronizeDirectory()
                return
            } catch {
                throw error
            }
        }
        throw ContainerLogProcessGenerationError.temporaryNameCollision
    }

    private func removeInterruptedTemporaryFiles() throws {
        let duplicate = Darwin.openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else {
            throw ContainerLogProcessGenerationError.io(.enumerate, errno)
        }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw ContainerLogProcessGenerationError.io(.enumerate, code)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw ContainerLogProcessGenerationError.io(.enumerate, errno)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            guard names.count < Self.maximumDirectoryEntries else {
                throw ContainerLogProcessGenerationError.unsafeStorage
            }
            names.append(name)
        }

        var removed = false
        for name in names where name.hasPrefix(Self.temporaryPrefix) {
            var metadata = stat()
            let metadataResult = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard metadataResult == 0 else {
                if errno == ENOENT {
                    continue
                }
                throw ContainerLogProcessGenerationError.io(.metadata, errno)
            }
            try Self.validateRegularMetadata(metadata)
            let removeResult = name.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            guard removeResult == 0 || errno == ENOENT else {
                throw ContainerLogProcessGenerationError.io(.remove, errno)
            }
            removed = removed || removeResult == 0
        }
        if removed {
            try synchronizeDirectory()
        }
    }

    private func synchronizeDirectory() throws {
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw ContainerLogProcessGenerationError.io(.synchronize, errno)
        }
    }

    static func encode(_ generation: UInt64) -> Data {
        var data = magic
        var bigEndian = generation.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    static func decode(_ data: Data) throws -> UInt64 {
        guard data.count == encodedByteCount, data.prefix(magic.count) == magic else {
            throw ContainerLogProcessGenerationError.invalidEncoding
        }
        let authenticated = data.prefix(magic.count + MemoryLayout<UInt64>.size)
        guard Data(SHA256.hash(data: authenticated)) == data.suffix(SHA256.byteCount) else {
            throw ContainerLogProcessGenerationError.invalidEncoding
        }
        let generationBytes = data[magic.count..<(magic.count + MemoryLayout<UInt64>.size)]
        var value: UInt64 = 0
        for byte in generationBytes {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw ContainerLogProcessGenerationError.invalidRoot
        }
        // Darwin exposes /var and /tmp as immutable system aliases into
        // /private. openat(O_NOFOLLOW) correctly rejects those aliases as
        // symlinks, so canonicalize only these fixed root spellings before
        // performing the descriptor-relative, no-follow traversal.
        let inputPath = url.path
        let canonicalPath: String
        if inputPath == "/var" || inputPath.hasPrefix("/var/")
            || inputPath == "/tmp" || inputPath.hasPrefix("/tmp/")
        {
            canonicalPath = "/private" + inputPath
        } else {
            canonicalPath = inputPath
        }
        let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({
                $0 != "." && $0 != ".." && !$0.utf8.contains(0) && $0.utf8.count <= 255
            })
        else {
            throw ContainerLogProcessGenerationError.invalidRoot
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            throw ContainerLogProcessGenerationError.io(.openDirectory, errno)
        }
        do {
            for (index, component) in components.enumerated() {
                let isFinal = index == components.count - 1
                var next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                var created = false
                if next < 0, errno == ENOENT, isFinal {
                    let createResult = component.withCString {
                        Darwin.mkdirat(current, $0, directoryMode)
                    }
                    guard createResult == 0 || errno == EEXIST else {
                        throw ContainerLogProcessGenerationError.io(.createDirectory, errno)
                    }
                    created = createResult == 0
                    if created, Darwin.fsync(current) != 0 {
                        throw ContainerLogProcessGenerationError.io(.synchronize, errno)
                    }
                    next = component.withCString {
                        Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                }
                guard next >= 0 else {
                    throw ContainerLogProcessGenerationError.io(.openDirectory, errno)
                }
                Darwin.close(current)
                current = next
                if isFinal {
                    if created, Darwin.fchmod(current, directoryMode) != 0 {
                        throw ContainerLogProcessGenerationError.io(.metadata, errno)
                    }
                    try validateDirectoryDescriptor(current)
                    if created, Darwin.fsync(current) != 0 {
                        throw ContainerLogProcessGenerationError.io(.synchronize, errno)
                    }
                }
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func openLockFile(
        directoryDescriptor: Int32,
        exclusive: Bool
    ) throws -> Int32 {
        let exclusiveFlag = exclusive ? O_EXLOCK : 0
        let baseFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | exclusiveFlag
        var lastError = ENOENT
        for _ in 0..<maximumPublicationAttempts {
            var created = false
            var descriptor = lockFileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    baseFlags | O_CREAT | O_EXCL,
                    fileMode
                )
            }
            if descriptor >= 0 {
                created = true
            } else if errno == EEXIST {
                descriptor = lockFileName.withCString {
                    Darwin.openat(directoryDescriptor, $0, baseFlags)
                }
            }
            if descriptor < 0 {
                lastError = errno
                if lastError == ENOENT || lastError == EINTR || lastError == EEXIST {
                    continue
                }
                throw ContainerLogProcessGenerationError.io(
                    exclusive ? .lock : .openLockFile,
                    lastError
                )
            }
            do {
                try validateRegularFileDescriptor(descriptor)
                if created, Darwin.fsync(directoryDescriptor) != 0 {
                    throw ContainerLogProcessGenerationError.io(.synchronize, errno)
                }
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        throw ContainerLogProcessGenerationError.io(
            exclusive ? .lock : .openLockFile,
            lastError
        )
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ContainerLogProcessGenerationError.io(.metadata, errno)
        }
        let permissions = metadata.st_mode & mode_t(0o777)
        guard
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            metadata.st_uid == Darwin.geteuid(),
            permissions == directoryMode
        else {
            throw ContainerLogProcessGenerationError.unsafeStorage
        }
    }

    private static func validateRegularFileDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ContainerLogProcessGenerationError.io(.metadata, errno)
        }
        try validateRegularMetadata(metadata)
    }

    private static func validateRegularMetadata(_ metadata: stat) throws {
        let permissions = metadata.st_mode & mode_t(0o777)
        guard
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            permissions & mode_t(0o077) == 0
        else {
            throw ContainerLogProcessGenerationError.unsafeStorage
        }
    }

    private static func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw ContainerLogProcessGenerationError.invalidEncoding
            }
            while offset < count {
                let result = Darwin.pread(descriptor, base.advanced(by: offset), count - offset, off_t(offset))
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                if result == 0 {
                    throw ContainerLogProcessGenerationError.invalidEncoding
                }
                throw ContainerLogProcessGenerationError.io(.read, errno)
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            while offset < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw ContainerLogProcessGenerationError.io(.write, result == 0 ? EIO : errno)
            }
        }
    }
}
