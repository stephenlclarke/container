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
import CryptoKit
import Darwin
import Foundation

enum LoggingProtectedOptionsStoreError: Error, Equatable, Sendable {
    enum Component: Equatable, Sendable {
        case root
        case key
        case object
    }

    enum Operation: Equatable, Sendable {
        case createRoot
        case openRoot
        case openKey
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
    case invalidReference
    case invalidEncoding
    case boundsExceeded
    case integrityMismatch
    case objectIdentityMismatch
    case notFound
    case identifierCollision
    case ioFailure(Operation, Int32)
}

/// Authority-owned storage for protected logging option values.
///
/// Objects are immutable and published through an fsynced temporary file,
/// exclusive atomic rename, and directory fsync. All file operations after
/// initialization are relative to a held, non-symlink directory descriptor.
actor LoggingProtectedOptionsStore {
    typealias RandomBytes = @Sendable (_ count: Int) throws -> Data

    static let maximumOptionCount = 1_024
    static let maximumOptionNameBytes = 16 * 1_024
    static let maximumOptionValueBytes = 1 * 1_024 * 1_024
    static let maximumEncodedBytes = 4 * 1_024 * 1_024

    static let keyFileName = ".logging-protected-options.key"
    static let objectFilePrefix = "logging-options-"
    static let objectFileSuffix = ".bin"

    private static let schemaVersion: UInt32 = 1
    private static let keyByteCount = 32
    private static let objectIDByteCount = 16
    private static let objectIDCharacterCount = objectIDByteCount * 2
    private static let maximumPublicationAttempts = 8
    private static let fileMagic = Data("CLOGOPT1".utf8)
    private static let authenticationDomain = Data("container.logging.protected-options.v1\u{0}".utf8)

    private let rootDescriptor: Int32
    private let keyData: Data
    private let randomBytes: RandomBytes

    init(rootURL: URL) throws {
        try self.init(rootURL: rootURL, _testingRandomBytes: Self.secureRandomBytes)
    }

    /// Randomness injection remains module-internal and exists only so tests
    /// can make object identifiers, temporary names, and store keys repeatable.
    init(rootURL: URL, _testingRandomBytes randomBytes: @escaping RandomBytes) throws {
        let rootDescriptor = try Self.openStoreRoot(at: rootURL)
        do {
            let keyData = try Self.loadOrCreateKey(
                rootDescriptor: rootDescriptor,
                randomBytes: randomBytes
            )
            self.rootDescriptor = rootDescriptor
            self.keyData = keyData
            self.randomBytes = randomBytes
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    func store(_ options: [String: String]) throws -> LoggingProtectedOptionsReference {
        try validateStoreBoundary()

        for _ in 0..<Self.maximumPublicationAttempts {
            let objectID = try generateObjectID()
            let encoded = try Self.encode(options: options, objectID: objectID)
            do {
                try publish(encoded, objectID: objectID)
                return LoggingProtectedOptionsReference(
                    objectID: objectID,
                    integrityDigest: Self.integrityDigest(
                        encoded: encoded,
                        objectID: objectID,
                        keyData: keyData
                    )
                )
            } catch LoggingProtectedOptionsStoreError.identifierCollision {
                continue
            }
        }
        throw LoggingProtectedOptionsStoreError.identifierCollision
    }

    func load(_ reference: LoggingProtectedOptionsReference) throws -> [String: String] {
        let validatedReference = try Self.validate(reference: reference)
        try validateStoreBoundary()
        let encoded = try readObject(objectID: validatedReference.objectID)
        let authenticatedData = Self.authenticatedData(
            encoded: encoded,
            objectID: validatedReference.objectID
        )
        let key = SymmetricKey(data: keyData)
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                validatedReference.authenticationCode,
                authenticating: authenticatedData,
                using: key
            )
        else {
            throw LoggingProtectedOptionsStoreError.integrityMismatch
        }
        return try Self.decode(encoded: encoded, expectedObjectID: validatedReference.objectID)
    }

    /// Removes only the validated object named by `reference`. Repeating the
    /// exact deletion after the object is gone succeeds without side effects.
    func delete(_ reference: LoggingProtectedOptionsReference) throws {
        let validatedReference = try Self.validate(reference: reference)
        do {
            _ = try load(reference)
        } catch LoggingProtectedOptionsStoreError.notFound {
            return
        }

        let fileName = Self.objectFileName(objectID: validatedReference.objectID)
        let result = fileName.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT {
                return
            }
            throw LoggingProtectedOptionsStoreError.ioFailure(.delete, code)
        }
        try Self.synchronizeDirectory(rootDescriptor)
    }

    private func validateStoreBoundary() throws {
        try Self.validateDirectoryDescriptor(rootDescriptor)
        let onDiskKey = try Self.loadExistingKey(rootDescriptor: rootDescriptor)
        guard Self.timingSafeEqual(keyData, onDiskKey) else {
            throw LoggingProtectedOptionsStoreError.invalidMetadata(.key)
        }
    }

    private func generateObjectID() throws -> String {
        let bytes = try randomBytes(Self.objectIDByteCount)
        guard bytes.count == Self.objectIDByteCount else {
            throw LoggingProtectedOptionsStoreError.invalidReference
        }
        return Self.hex(bytes)
    }

    private func publish(_ encoded: Data, objectID: String) throws {
        let targetName = Self.objectFileName(objectID: objectID)
        let temporary = try createTemporaryFile()
        let temporaryName = temporary.name
        let descriptor = temporary.descriptor
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
            throw LoggingProtectedOptionsStoreError.ioFailure(.synchronizeFile, errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorNeedsClose = false
            throw LoggingProtectedOptionsStoreError.ioFailure(.write, errno)
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
        guard renameResult == 0 else {
            let code = errno
            if code == EEXIST {
                throw LoggingProtectedOptionsStoreError.identifierCollision
            }
            throw LoggingProtectedOptionsStoreError.ioFailure(.publishFile, code)
        }
        temporaryNeedsRemoval = false
        try Self.synchronizeDirectory(rootDescriptor)
    }

    private func createTemporaryFile() throws -> (name: String, descriptor: Int32) {
        for _ in 0..<Self.maximumPublicationAttempts {
            let suffix = try randomBytes(Self.objectIDByteCount)
            guard suffix.count == Self.objectIDByteCount else {
                throw LoggingProtectedOptionsStoreError.invalidReference
            }
            let name = ".logging-options.tmp.\(Self.hex(suffix))"
            do {
                let descriptor = try Self.openNewFile(
                    rootDescriptor: rootDescriptor,
                    fileName: name,
                    component: .object
                )
                return (name, descriptor)
            } catch LoggingProtectedOptionsStoreError.identifierCollision {
                continue
            }
        }
        throw LoggingProtectedOptionsStoreError.identifierCollision
    }

    private func readObject(objectID: String) throws -> Data {
        let fileName = Self.objectFileName(objectID: objectID)
        return try Self.readManagedFile(
            rootDescriptor: rootDescriptor,
            fileName: fileName,
            component: .object,
            minimumSize: Self.minimumEncodedByteCount,
            maximumSize: Self.maximumEncodedBytes
        )
    }

    private static var minimumEncodedByteCount: Int {
        fileMagic.count + MemoryLayout<UInt32>.size + objectIDCharacterCount + MemoryLayout<UInt32>.size
    }

    private static func objectFileName(objectID: String) -> String {
        objectFilePrefix + objectID + objectFileSuffix
    }

    private static func validate(
        reference: LoggingProtectedOptionsReference
    ) throws -> (objectID: String, authenticationCode: Data) {
        guard isValidObjectID(reference.objectID) else {
            throw LoggingProtectedOptionsStoreError.invalidReference
        }
        let prefix = "hmac-sha256:"
        guard reference.integrityDigest.hasPrefix(prefix) else {
            throw LoggingProtectedOptionsStoreError.invalidReference
        }
        let encodedCode = reference.integrityDigest.dropFirst(prefix.count)
        guard encodedCode.count == SHA256.byteCount * 2,
            let authenticationCode = dataFromLowercaseHex(encodedCode)
        else {
            throw LoggingProtectedOptionsStoreError.invalidReference
        }
        return (reference.objectID, authenticationCode)
    }

    private static func isValidObjectID(_ value: String) -> Bool {
        guard value.utf8.count == objectIDCharacterCount else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func encode(options: [String: String], objectID: String) throws -> Data {
        guard isValidObjectID(objectID), options.count <= maximumOptionCount else {
            throw LoggingProtectedOptionsStoreError.boundsExceeded
        }

        let entries = try options.map { name, value -> (name: Data, value: Data) in
            let nameData = Data(name.utf8)
            let valueData = Data(value.utf8)
            guard nameData.count <= maximumOptionNameBytes,
                valueData.count <= maximumOptionValueBytes,
                nameData.count <= Int(UInt32.max),
                valueData.count <= Int(UInt32.max)
            else {
                throw LoggingProtectedOptionsStoreError.boundsExceeded
            }
            return (nameData, valueData)
        }.sorted { lhs, rhs in
            lhs.name.lexicographicallyPrecedes(rhs.name)
        }

        var expectedSize = minimumEncodedByteCount
        for entry in entries {
            let entrySize = 2 * MemoryLayout<UInt32>.size + entry.name.count + entry.value.count
            let addition = expectedSize.addingReportingOverflow(entrySize)
            guard !addition.overflow, addition.partialValue <= maximumEncodedBytes else {
                throw LoggingProtectedOptionsStoreError.boundsExceeded
            }
            expectedSize = addition.partialValue
        }

        var encoded = Data()
        encoded.reserveCapacity(expectedSize)
        encoded.append(fileMagic)
        encoded.appendBigEndian(schemaVersion)
        encoded.append(Data(objectID.utf8))
        encoded.appendBigEndian(UInt32(entries.count))
        for entry in entries {
            encoded.appendBigEndian(UInt32(entry.name.count))
            encoded.appendBigEndian(UInt32(entry.value.count))
            encoded.append(entry.name)
            encoded.append(entry.value)
        }
        guard encoded.count == expectedSize else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        return encoded
    }

    private static func decode(encoded: Data, expectedObjectID: String) throws -> [String: String] {
        guard encoded.count >= minimumEncodedByteCount, encoded.count <= maximumEncodedBytes else {
            throw LoggingProtectedOptionsStoreError.boundsExceeded
        }
        var reader = BoundedDataReader(data: encoded)
        guard try reader.read(count: fileMagic.count) == fileMagic,
            try reader.readUInt32() == schemaVersion
        else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        let encodedObjectIDData = try reader.read(count: objectIDCharacterCount)
        guard let encodedObjectID = String(data: encodedObjectIDData, encoding: .utf8),
            isValidObjectID(encodedObjectID)
        else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        guard encodedObjectID == expectedObjectID else {
            throw LoggingProtectedOptionsStoreError.objectIdentityMismatch
        }

        let count = Int(try reader.readUInt32())
        guard count <= maximumOptionCount else {
            throw LoggingProtectedOptionsStoreError.boundsExceeded
        }
        var options: [String: String] = [:]
        options.reserveCapacity(count)
        var previousNameData: Data?
        for _ in 0..<count {
            let nameCount = Int(try reader.readUInt32())
            let valueCount = Int(try reader.readUInt32())
            guard nameCount <= maximumOptionNameBytes, valueCount <= maximumOptionValueBytes else {
                throw LoggingProtectedOptionsStoreError.boundsExceeded
            }
            let nameData = try reader.read(count: nameCount)
            let valueData = try reader.read(count: valueCount)
            guard let name = String(data: nameData, encoding: .utf8),
                let value = String(data: valueData, encoding: .utf8),
                previousNameData.map({ $0.lexicographicallyPrecedes(nameData) }) ?? true,
                options[name] == nil
            else {
                throw LoggingProtectedOptionsStoreError.invalidEncoding
            }
            options[name] = value
            previousNameData = nameData
        }
        guard reader.isAtEnd else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        return options
    }

    private static func integrityDigest(encoded: Data, objectID: String, keyData: Data) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: authenticatedData(encoded: encoded, objectID: objectID),
            using: SymmetricKey(data: keyData)
        )
        return "hmac-sha256:\(hex(authenticationCode))"
    }

    private static func authenticatedData(encoded: Data, objectID: String) -> Data {
        var authenticated = Data()
        authenticated.reserveCapacity(authenticationDomain.count + objectIDCharacterCount + encoded.count)
        authenticated.append(authenticationDomain)
        authenticated.append(Data(objectID.utf8))
        authenticated.append(encoded)
        return authenticated
    }

    private static func openStoreRoot(at rootURL: URL) throws -> Int32 {
        guard rootURL.isFileURL else {
            throw LoggingProtectedOptionsStoreError.invalidRoot
        }
        let path = rootURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw LoggingProtectedOptionsStoreError.invalidRoot
        }

        let creationResult = path.withCString {
            Darwin.mkdir($0, mode_t(0o700))
        }
        let created: Bool
        if creationResult == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.createRoot, errno)
        }

        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.openRoot, errno)
        }
        do {
            if created, Darwin.fchmod(descriptor, mode_t(0o700)) != 0 {
                throw LoggingProtectedOptionsStoreError.ioFailure(.createRoot, errno)
            }
            try validateDirectoryDescriptor(descriptor)
            if created {
                try synchronizeDirectory(descriptor)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.openRoot, errno)
        }
        guard isDirectory(metadata),
            metadata.st_uid == Darwin.geteuid(),
            permissions(metadata) == mode_t(0o700)
        else {
            throw LoggingProtectedOptionsStoreError.invalidMetadata(.root)
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
            throw LoggingProtectedOptionsStoreError.invalidMetadata(.key)
        }
        for _ in 0..<maximumPublicationAttempts {
            let suffix = try randomBytes(objectIDByteCount)
            guard suffix.count == objectIDByteCount else {
                throw LoggingProtectedOptionsStoreError.invalidMetadata(.key)
            }
            let temporaryName = ".logging-options.key.tmp.\(hex(suffix))"
            let descriptor: Int32
            do {
                descriptor = try openNewFile(
                    rootDescriptor: rootDescriptor,
                    fileName: temporaryName,
                    component: .key
                )
            } catch LoggingProtectedOptionsStoreError.identifierCollision {
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

            try writeAll(key, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw LoggingProtectedOptionsStoreError.ioFailure(.synchronizeFile, errno)
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorNeedsClose = false
                throw LoggingProtectedOptionsStoreError.ioFailure(.write, errno)
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
            throw LoggingProtectedOptionsStoreError.ioFailure(.publishFile, code)
        }
        throw LoggingProtectedOptionsStoreError.identifierCollision
    }

    private static func loadExistingKey(rootDescriptor: Int32) throws -> Data {
        guard let key = try loadExistingKeyIfPresent(rootDescriptor: rootDescriptor) else {
            throw LoggingProtectedOptionsStoreError.invalidMetadata(.key)
        }
        return key
    }

    private static func loadExistingKeyIfPresent(rootDescriptor: Int32) throws -> Data? {
        let descriptor = keyFileName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw LoggingProtectedOptionsStoreError.ioFailure(.openKey, code)
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
        component: LoggingProtectedOptionsStoreError.Component
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
                throw LoggingProtectedOptionsStoreError.identifierCollision
            }
            throw LoggingProtectedOptionsStoreError.ioFailure(.createTemporaryFile, code)
        }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw LoggingProtectedOptionsStoreError.ioFailure(.createTemporaryFile, errno)
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
        component: LoggingProtectedOptionsStoreError.Component,
        minimumSize: Int,
        maximumSize: Int
    ) throws -> Data {
        let descriptor = fileName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                throw LoggingProtectedOptionsStoreError.notFound
            }
            throw LoggingProtectedOptionsStoreError.ioFailure(.read, code)
        }
        defer { Darwin.close(descriptor) }
        try validateRegularFileDescriptor(descriptor, component: component)

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.read, errno)
        }
        guard metadata.st_size >= 0,
            metadata.st_size >= off_t(minimumSize),
            metadata.st_size <= off_t(maximumSize)
        else {
            throw LoggingProtectedOptionsStoreError.boundsExceeded
        }
        return try readExactFile(
            descriptor: descriptor,
            expectedSize: Int(metadata.st_size),
            component: component
        )
    }

    private static func validateRegularFileDescriptor(
        _ descriptor: Int32,
        component: LoggingProtectedOptionsStoreError.Component
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.read, errno)
        }
        guard isRegularFile(metadata),
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            permissions(metadata) == mode_t(0o600)
        else {
            throw LoggingProtectedOptionsStoreError.invalidMetadata(component)
        }
    }

    private static func readExactFile(
        descriptor: Int32,
        expectedSize: Int,
        component: LoggingProtectedOptionsStoreError.Component
    ) throws -> Data {
        var data = Data(count: expectedSize)
        var offset = 0
        while offset < expectedSize {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedSize - offset
                )
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw LoggingProtectedOptionsStoreError.ioFailure(.read, errno)
            }
            guard count > 0 else {
                throw LoggingProtectedOptionsStoreError.invalidMetadata(component)
            }
            offset += count
        }

        var extraByte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &extraByte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 0 else {
                if count < 0 {
                    throw LoggingProtectedOptionsStoreError.ioFailure(.read, errno)
                }
                throw LoggingProtectedOptionsStoreError.boundsExceeded
            }
            break
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw LoggingProtectedOptionsStoreError.ioFailure(.write, errno)
            }
            guard count > 0 else {
                throw LoggingProtectedOptionsStoreError.ioFailure(.write, EIO)
            }
            offset += count
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.synchronizeDirectory, errno)
        }
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
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw LoggingProtectedOptionsStoreError.invalidReference
        }
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func dataFromLowercaseHex(_ value: Substring) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            return nil
        }
        var decoded = [UInt8]()
        decoded.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = lowercaseHexNibble(bytes[index]),
                let low = lowercaseHexNibble(bytes[index + 1])
            else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        return Data(decoded)
    }

    private static func lowercaseHexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }
}

private struct BoundedDataReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0 else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        let end = offset.addingReportingOverflow(count)
        guard !end.overflow, end.partialValue <= data.count else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        defer { offset = end.partialValue }
        return data.subdata(in: offset..<end.partialValue)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: MemoryLayout<UInt32>.size)
        return bytes.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
