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

import ContainerEngineRuntimeSPI
import CryptoKit
import Darwin
import Foundation

enum LoggingHandoffProtectedReceiptStoreError: Error, Equatable, Sendable {
    enum Component: Equatable, Sendable {
        case root
        case key
        case receipt
    }

    enum Operation: Equatable, Sendable {
        case createRoot
        case openRoot
        case openKey
        case readDirectory
        case createTemporaryFile
        case read
        case write
        case synchronizeFile
        case publishFile
        case synchronizeDirectory
        case delete
    }

    case invalidRoot
    case invalidMetadata(Component)
    case invalidDigest
    case invalidEncoding
    case boundsExceeded
    case integrityMismatch
    case receiptMismatch
    case notFound
    case identifierCollision
    case ioFailure(Operation, Int32)
}

struct LoggingHandoffSealedProtectedReceiptV1: Equatable, Sendable {
    let receipt: LoggingProtectedOptionStagingReceiptV1
    let privateStagingState: Data
}

/// Private, authenticated, crash-safe storage for logging import receipts.
///
/// The common handoff staging record stores only `receiptDigestSHA256`; the
/// destination references remain in this current-user-owned 0700 namespace.
actor LoggingHandoffProtectedReceiptStore {
    typealias RandomBytes = @Sendable (_ count: Int) throws -> Data

    static let keyFileName = ".logging-handoff-receipts.key"
    static let receiptFilePrefix = "logging-handoff-receipt-"
    static let receiptFileSuffix = ".bin"
    static let maximumCanonicalReceiptBytes = 4 * 1024 * 1024
    static let maximumPrivateStagingStateBytes = 8 * 1024 * 1024

    private static let fileMagic = Data("CLOGHRC2".utf8)
    private static let schemaVersion: UInt32 = 2
    private static let keyByteCount = 32
    private static let temporaryIdentifierByteCount = 16
    private static let maximumPublicationAttempts = 8
    private static let authenticationDomain = Data(
        "container.logging.handoff.protected-receipt.v1\u{0}".utf8
    )
    private static let envelopeFixedBytes =
        fileMagic.count
        + MemoryLayout<UInt32>.size
        + 2 * MemoryLayout<UInt64>.size
        + SHA256.byteCount

    private let rootDescriptor: Int32
    private let keyData: Data
    private let randomBytes: RandomBytes

    init(rootURL: URL) throws {
        try self.init(rootURL: rootURL, _testingRandomBytes: Self.secureRandomBytes)
    }

    init(rootURL: URL, retainingReceiptDigests: Set<String>) throws {
        try self.init(rootURL: rootURL, _testingRandomBytes: Self.secureRandomBytes)
        try Self.reconcile(
            rootDescriptor: rootDescriptor,
            retainingReceiptDigests: retainingReceiptDigests
        )
    }

    init(
        rootURL: URL,
        _testingRandomBytes randomBytes: @escaping RandomBytes
    ) throws {
        let rootDescriptor = try Self.openStoreRoot(at: rootURL)
        do {
            self.rootDescriptor = rootDescriptor
            self.keyData = try Self.loadOrCreateKey(
                rootDescriptor: rootDescriptor,
                randomBytes: randomBytes
            )
            self.randomBytes = randomBytes
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    func seal(
        _ receipt: LoggingProtectedOptionStagingReceiptV1
    ) throws -> LoggingProtectedOptionStagingReceiptV1 {
        try seal(receipt, privateStagingState: Data()).receipt
    }

    func seal(
        _ receipt: LoggingProtectedOptionStagingReceiptV1,
        privateStagingState: Data
    ) throws -> LoggingHandoffSealedProtectedReceiptV1 {
        try validateStoreBoundary()
        let digest = try Self.validatedDigest(receipt.receiptDigestSHA256)
        let canonical = try LoggingProtectedOptionStagingReceiptV1.canonicalBytes(
            receipt
        )
        guard
            canonical.count <= Self.maximumCanonicalReceiptBytes,
            privateStagingState.count <= Self.maximumPrivateStagingStateBytes
        else {
            throw LoggingHandoffProtectedReceiptStoreError.boundsExceeded
        }
        let encoded = Self.encodeEnvelope(
            canonical: canonical,
            privateStagingState: privateStagingState,
            receiptDigest: digest,
            keyData: keyData
        )
        do {
            let existing = try loadSealed(receipt.receiptDigestSHA256)
            guard
                existing.receipt == receipt,
                existing.privateStagingState == privateStagingState
            else {
                throw LoggingHandoffProtectedReceiptStoreError.receiptMismatch
            }
            return existing
        } catch LoggingHandoffProtectedReceiptStoreError.notFound {
            // Publish below.
        }

        let targetName = Self.receiptFileName(receipt.receiptDigestSHA256)
        for _ in 0..<Self.maximumPublicationAttempts {
            let temporaryName = try temporaryFileName()
            let descriptor: Int32
            do {
                descriptor = try Self.openNewFile(
                    rootDescriptor: rootDescriptor,
                    fileName: temporaryName,
                    component: .receipt
                )
            } catch LoggingHandoffProtectedReceiptStoreError.identifierCollision {
                continue
            }
            var descriptorNeedsClose = true
            var temporaryNeedsRemoval = true
            defer {
                if descriptorNeedsClose {
                    Darwin.close(descriptor)
                }
                if temporaryNeedsRemoval {
                    temporaryName.withCString {
                        _ = Darwin.unlinkat(rootDescriptor, $0, 0)
                    }
                }
            }
            try Self.writeAll(encoded, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                    .synchronizeFile,
                    errno
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorNeedsClose = false
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.write, errno)
            }
            descriptorNeedsClose = false

            let renameResult = temporaryName.withCString { temporaryPointer in
                targetName.withCString { targetPointer in
                    Darwin.renameatx_np(
                        rootDescriptor,
                        temporaryPointer,
                        rootDescriptor,
                        targetPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if renameResult == 0 {
                temporaryNeedsRemoval = false
                try Self.synchronizeDirectory(rootDescriptor)
                return LoggingHandoffSealedProtectedReceiptV1(
                    receipt: receipt,
                    privateStagingState: privateStagingState
                )
            }
            let code = errno
            if code == EEXIST {
                let existing = try loadSealed(receipt.receiptDigestSHA256)
                guard
                    existing.receipt == receipt,
                    existing.privateStagingState == privateStagingState
                else {
                    throw LoggingHandoffProtectedReceiptStoreError.receiptMismatch
                }
                return existing
            }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .publishFile,
                code
            )
        }
        throw LoggingHandoffProtectedReceiptStoreError.identifierCollision
    }

    func load(
        _ receiptDigestSHA256: String
    ) throws -> LoggingProtectedOptionStagingReceiptV1 {
        try loadSealed(receiptDigestSHA256).receipt
    }

    func loadSealed(
        _ receiptDigestSHA256: String
    ) throws -> LoggingHandoffSealedProtectedReceiptV1 {
        let digest = try Self.validatedDigest(receiptDigestSHA256)
        try validateStoreBoundary()
        let encoded = try Self.readManagedFile(
            rootDescriptor: rootDescriptor,
            fileName: Self.receiptFileName(receiptDigestSHA256),
            component: .receipt,
            minimumSize: Self.envelopeFixedBytes,
            maximumSize: Self.envelopeFixedBytes
                + Self.maximumCanonicalReceiptBytes
                + Self.maximumPrivateStagingStateBytes
        )
        let decoded = try Self.decodeEnvelope(
            encoded,
            expectedReceiptDigest: digest,
            keyData: keyData
        )
        let receipt = try LoggingProtectedOptionStagingReceiptV1.decodeCanonicalBytes(
            decoded.canonical
        )
        guard
            Self.timingSafeEqual(
                try Self.validatedDigest(receipt.receiptDigestSHA256),
                digest
            )
        else {
            throw LoggingHandoffProtectedReceiptStoreError.receiptMismatch
        }
        return LoggingHandoffSealedProtectedReceiptV1(
            receipt: receipt,
            privateStagingState: decoded.privateStagingState
        )
    }

    /// Idempotently destroys only the authenticated receipt named by digest.
    func delete(_ receiptDigestSHA256: String) throws {
        do {
            _ = try load(receiptDigestSHA256)
        } catch LoggingHandoffProtectedReceiptStoreError.notFound {
            return
        }
        let fileName = Self.receiptFileName(receiptDigestSHA256)
        let result = fileName.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT { return }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.delete, code)
        }
        try Self.synchronizeDirectory(rootDescriptor)
    }

    func reconcile(retainingReceiptDigests: Set<String>) throws {
        try Self.reconcile(
            rootDescriptor: rootDescriptor,
            retainingReceiptDigests: retainingReceiptDigests
        )
    }

    private func validateStoreBoundary() throws {
        try Self.validateDirectoryDescriptor(rootDescriptor)
        let current = try Self.loadExistingKey(rootDescriptor: rootDescriptor)
        guard Self.timingSafeEqual(current, keyData) else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(.key)
        }
    }

    private func temporaryFileName() throws -> String {
        let suffix = try randomBytes(Self.temporaryIdentifierByteCount)
        guard suffix.count == Self.temporaryIdentifierByteCount else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidEncoding
        }
        return ".logging-handoff-receipt.tmp.\(ProviderHandoffDigest.hex(suffix))"
    }

    private static func encodeEnvelope(
        canonical: Data,
        privateStagingState: Data,
        receiptDigest: Data,
        keyData: Data
    ) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: authenticatedData(
                canonical: canonical,
                privateStagingState: privateStagingState,
                receiptDigest: receiptDigest
            ),
            using: SymmetricKey(data: keyData)
        )
        var encoded = Data()
        encoded.reserveCapacity(
            envelopeFixedBytes + canonical.count + privateStagingState.count
        )
        encoded.append(fileMagic)
        appendBigEndian(schemaVersion, to: &encoded)
        appendBigEndian(UInt64(canonical.count), to: &encoded)
        appendBigEndian(UInt64(privateStagingState.count), to: &encoded)
        encoded.append(canonical)
        encoded.append(privateStagingState)
        encoded.append(contentsOf: authenticationCode)
        return encoded
    }

    private static func decodeEnvelope(
        _ encoded: Data,
        expectedReceiptDigest: Data,
        keyData: Data
    ) throws -> (canonical: Data, privateStagingState: Data) {
        var reader = ReceiptDataReader(data: encoded)
        guard
            try reader.read(count: fileMagic.count) == fileMagic,
            try reader.readUInt32() == schemaVersion,
            let canonicalSize = Int(exactly: try reader.readUInt64()),
            canonicalSize <= maximumCanonicalReceiptBytes,
            let privateStateSize = Int(exactly: try reader.readUInt64()),
            privateStateSize <= maximumPrivateStagingStateBytes
        else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidEncoding
        }
        let canonical = try reader.read(count: canonicalSize)
        let privateStagingState = try reader.read(count: privateStateSize)
        let encodedAuthenticationCode = try reader.read(count: SHA256.byteCount)
        guard reader.isAtEnd else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidEncoding
        }
        let key = SymmetricKey(data: keyData)
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                encodedAuthenticationCode,
                authenticating: authenticatedData(
                    canonical: canonical,
                    privateStagingState: privateStagingState,
                    receiptDigest: expectedReceiptDigest
                ),
                using: key
            )
        else {
            throw LoggingHandoffProtectedReceiptStoreError.integrityMismatch
        }
        return (canonical, privateStagingState)
    }

    private static func authenticatedData(
        canonical: Data,
        privateStagingState: Data,
        receiptDigest: Data
    ) -> Data {
        var value = Data()
        value.reserveCapacity(
            authenticationDomain.count
                + 32
                + 2 * MemoryLayout<UInt64>.size
                + canonical.count
                + privateStagingState.count
        )
        value.append(authenticationDomain)
        value.append(receiptDigest)
        appendBigEndian(UInt64(canonical.count), to: &value)
        value.append(canonical)
        appendBigEndian(UInt64(privateStagingState.count), to: &value)
        value.append(privateStagingState)
        return value
    }

    private static func openStoreRoot(at rootURL: URL) throws -> Int32 {
        guard
            rootURL.isFileURL,
            rootURL.path.hasPrefix("/"),
            !rootURL.path.utf8.contains(0)
        else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidRoot
        }
        let path = rootURL.path
        let result = path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        let created: Bool
        if result == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .createRoot,
                errno
            )
        }
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.openRoot, errno)
        }
        do {
            if created, Darwin.fchmod(descriptor, mode_t(0o700)) != 0 {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                    .createRoot,
                    errno
                )
            }
            try validateDirectoryDescriptor(descriptor)
            if created { try synchronizeDirectory(descriptor) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.openRoot, errno)
        }
        guard
            isDirectory(metadata),
            metadata.st_uid == Darwin.geteuid(),
            permissions(metadata) == mode_t(0o700)
        else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(.root)
        }
    }

    private static func loadOrCreateKey(
        rootDescriptor: Int32,
        randomBytes: RandomBytes
    ) throws -> Data {
        if let existing = try loadExistingKeyIfPresent(rootDescriptor: rootDescriptor) {
            return existing
        }
        let key = try randomBytes(keyByteCount)
        guard key.count == keyByteCount else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(.key)
        }
        for _ in 0..<maximumPublicationAttempts {
            let suffix = try randomBytes(temporaryIdentifierByteCount)
            guard suffix.count == temporaryIdentifierByteCount else {
                throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(.key)
            }
            let temporaryName =
                ".logging-handoff-receipts.key.tmp.\(ProviderHandoffDigest.hex(suffix))"
            let descriptor: Int32
            do {
                descriptor = try openNewFile(
                    rootDescriptor: rootDescriptor,
                    fileName: temporaryName,
                    component: .key
                )
            } catch LoggingHandoffProtectedReceiptStoreError.identifierCollision {
                continue
            }
            var descriptorNeedsClose = true
            var temporaryNeedsRemoval = true
            defer {
                if descriptorNeedsClose { Darwin.close(descriptor) }
                if temporaryNeedsRemoval {
                    temporaryName.withCString {
                        _ = Darwin.unlinkat(rootDescriptor, $0, 0)
                    }
                }
            }
            try writeAll(key, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                    .synchronizeFile,
                    errno
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorNeedsClose = false
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.write, errno)
            }
            descriptorNeedsClose = false
            let renameResult = temporaryName.withCString { temporaryPointer in
                keyFileName.withCString { keyPointer in
                    Darwin.renameatx_np(
                        rootDescriptor,
                        temporaryPointer,
                        rootDescriptor,
                        keyPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if renameResult == 0 {
                temporaryNeedsRemoval = false
                try synchronizeDirectory(rootDescriptor)
                return key
            }
            let code = errno
            if code == EEXIST {
                try synchronizeDirectory(rootDescriptor)
                return try loadExistingKey(rootDescriptor: rootDescriptor)
            }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .publishFile,
                code
            )
        }
        throw LoggingHandoffProtectedReceiptStoreError.identifierCollision
    }

    private static func loadExistingKey(rootDescriptor: Int32) throws -> Data {
        guard let key = try loadExistingKeyIfPresent(rootDescriptor: rootDescriptor) else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(.key)
        }
        return key
    }

    private static func loadExistingKeyIfPresent(
        rootDescriptor: Int32
    ) throws -> Data? {
        let descriptor = keyFileName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.openKey, code)
        }
        defer { Darwin.close(descriptor) }
        try validateRegularFileDescriptor(descriptor, component: .key)
        return try readExactFile(
            descriptor: descriptor,
            expectedSize: keyByteCount,
            component: .key
        )
    }

    private static func openNewFile(
        rootDescriptor: Int32,
        fileName: String,
        component: LoggingHandoffProtectedReceiptStoreError.Component
    ) throws -> Int32 {
        let descriptor = fileName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        if descriptor < 0 {
            let code = errno
            if code == EEXIST {
                throw LoggingHandoffProtectedReceiptStoreError.identifierCollision
            }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .createTemporaryFile,
                code
            )
        }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                    .createTemporaryFile,
                    errno
                )
            }
            try validateRegularFileDescriptor(descriptor, component: component)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            fileName.withCString {
                _ = Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            throw error
        }
    }

    private static func readManagedFile(
        rootDescriptor: Int32,
        fileName: String,
        component: LoggingHandoffProtectedReceiptStoreError.Component,
        minimumSize: Int,
        maximumSize: Int
    ) throws -> Data {
        let descriptor = fileName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                throw LoggingHandoffProtectedReceiptStoreError.notFound
            }
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.read, code)
        }
        defer { Darwin.close(descriptor) }
        try validateRegularFileDescriptor(descriptor, component: component)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.read, errno)
        }
        guard
            metadata.st_size >= off_t(minimumSize),
            metadata.st_size <= off_t(maximumSize)
        else {
            throw LoggingHandoffProtectedReceiptStoreError.boundsExceeded
        }
        return try readExactFile(
            descriptor: descriptor,
            expectedSize: Int(metadata.st_size),
            component: component
        )
    }

    private static func validateRegularFileDescriptor(
        _ descriptor: Int32,
        component: LoggingHandoffProtectedReceiptStoreError.Component
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.read, errno)
        }
        guard
            isRegularFile(metadata),
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            permissions(metadata) == mode_t(0o600)
        else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(component)
        }
    }

    private static func readExactFile(
        descriptor: Int32,
        expectedSize: Int,
        component: LoggingHandoffProtectedReceiptStoreError.Component
    ) throws -> Data {
        var data = Data(count: expectedSize)
        var offset = 0
        while offset < expectedSize {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedSize - offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.read, errno)
            }
            guard count > 0 else {
                throw LoggingHandoffProtectedReceiptStoreError.invalidMetadata(component)
            }
            offset += count
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.write, errno)
            }
            guard count > 0 else {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.write, EIO)
            }
            offset += count
        }
    }

    private static func reconcile(
        rootDescriptor: Int32,
        retainingReceiptDigests: Set<String>
    ) throws {
        try validateDirectoryDescriptor(rootDescriptor)
        for digest in retainingReceiptDigests {
            _ = try validatedDigest(digest)
        }
        let names = try directoryEntries(rootDescriptor: rootDescriptor)
        var removed = false
        for name in names {
            let remove: Bool
            if let digest = receiptDigest(fileName: name) {
                remove = !retainingReceiptDigests.contains(digest)
            } else {
                remove =
                    name.hasPrefix(".logging-handoff-receipt.tmp.")
                    || name.hasPrefix(".logging-handoff-receipts.key.tmp.")
            }
            guard remove else { continue }
            let result = name.withCString {
                Darwin.unlinkat(rootDescriptor, $0, 0)
            }
            if result != 0, errno != ENOENT {
                throw LoggingHandoffProtectedReceiptStoreError.ioFailure(.delete, errno)
            }
            removed = true
        }
        if removed { try synchronizeDirectory(rootDescriptor) }
    }

    private static func directoryEntries(rootDescriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(rootDescriptor)
        guard duplicate >= 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .readDirectory,
                errno
            )
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .readDirectory,
                code
            )
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .readDirectory,
                errno
            )
        }
        return names
    }

    private static func receiptFileName(_ digest: String) -> String {
        receiptFilePrefix + digest + receiptFileSuffix
    }

    private static func receiptDigest(fileName: String) -> String? {
        guard
            fileName.hasPrefix(receiptFilePrefix),
            fileName.hasSuffix(receiptFileSuffix)
        else {
            return nil
        }
        let start = fileName.index(
            fileName.startIndex,
            offsetBy: receiptFilePrefix.count
        )
        let end = fileName.index(
            fileName.endIndex,
            offsetBy: -receiptFileSuffix.count
        )
        let value = String(fileName[start..<end])
        return (try? validatedDigest(value)) == nil ? nil : value
    }

    private static func validatedDigest(_ value: String) throws -> Data {
        do {
            return try ProviderHandoffDigest.parseSHA256(value)
        } catch {
            throw LoggingHandoffProtectedReceiptStoreError.invalidDigest
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.ioFailure(
                .synchronizeDirectory,
                errno
            )
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func permissions(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(0o7777)
    }

    private static func isDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        ProviderHandoffDigest.constantTimeEqual(lhs, rhs)
    }

    private static func secureRandomBytes(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidEncoding
        }
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(
                in: UInt8.min...UInt8.max,
                using: &generator
            )
        }
        return Data(bytes)
    }
}

private struct ReceiptDataReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        let end = offset.addingReportingOverflow(count)
        guard
            count >= 0,
            !end.overflow,
            end.partialValue <= data.count
        else {
            throw LoggingHandoffProtectedReceiptStoreError.invalidEncoding
        }
        defer { offset = end.partialValue }
        return data.subdata(in: offset..<end.partialValue)
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    private mutating func readInteger<T: FixedWidthInteger>(
        _ type: T.Type
    ) throws -> T {
        try read(count: MemoryLayout<T>.size).reduce(T.zero) {
            ($0 << 8) | T($1)
        }
    }
}
