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

enum ProtectedLoggingEffectStoreError: Error, Equatable, Sendable {
    enum Component: Equatable, Sendable {
        case root
        case lock
        case key
        case object
        case tombstone
    }

    enum Operation: Equatable, Sendable {
        case createRoot
        case openRoot
        case openAncestor
        case openLock
        case lock
        case openKey
        case readDirectory
        case createTemporaryFile
        case read
        case write
        case synchronizeFile
        case publishFile
        case synchronizeDirectory
        case delete
        case accessControl
    }

    case invalidRoot
    case invalidMetadata(Component)
    case invalidReference
    case invalidEncoding
    case boundsExceeded
    case integrityMismatch
    case materialConflict
    case removed
    case notFound
    case identifierCollision
    case ioFailure(Operation, Int32)
}

/// Authority-owned persistent storage for opaque provider effect material.
///
/// Each binding has a deterministic keyed object identity. Object and removal
/// records are immutable, self-authenticating, and published with an fsynced
/// temporary file, exclusive rename, and directory fsync. All post-init file
/// operations are relative to a held, non-symlink directory descriptor.
actor ProtectedLoggingEffectStore: ProtectedLoggingEffectStoreV1 {
    typealias RandomBytes = @Sendable (_ count: Int) throws -> Data
    typealias TestingObjectID = @Sendable (_ canonicalBinding: Data) throws -> String
    typealias TestingFailureInjector = @Sendable (TestingFailurePoint) throws -> Void

    enum TestingFailurePoint: Equatable, Sendable {
        case afterObjectPublication
        case afterTombstonePublication
        case beforeTemporaryCleanupUnlink
        case beforeDirectorySynchronization
    }

    static let maximumBindingBytes = 64 * 1_024
    static let maximumMaterialBytes = LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes
    static let maximumEncodedObjectBytes = 256 * 1_024
    static let maximumEncodedTombstoneBytes = 128 * 1_024

    static let keyFileName = ".logging-protected-effects.key"
    static let lockFileName = ".logging-protected-effects.lock"
    static let objectFilePrefix = "logging-effect-"
    static let objectFileSuffix = ".bin"
    static let tombstoneFileSuffix = ".removed"
    static let temporaryFilePrefix = ".logging-effects.tmp."
    static let temporaryKeyPrefix = ".logging-effects.key.tmp."

    private static let schemaVersion: UInt32 = 1
    private static let keyByteCount = 32
    private static let authenticationCodeByteCount = SHA256.byteCount
    private static let objectIDCharacterCount = SHA256.byteCount * 2
    private static let maximumPublicationAttempts = 8
    static let maximumDirectoryEntries = 4 * 1_024
    private static let maximumDirectoryEntryNameBytes = 4 * 1_024 * 1_024
    private static let bindingMagic = Data("CLBNDV1\u{0}".utf8)
    private static let objectMagic = Data("CLOGEFF1".utf8)
    private static let tombstoneMagic = Data("CLOGRMV1".utf8)
    private static let objectIDDomain = Data("container.logging.effect.object-id.v1\u{0}".utf8)
    private static let objectAuthenticationDomain = Data(
        "container.logging.effect.object.v1\u{0}".utf8
    )
    private static let tombstoneAuthenticationDomain = Data(
        "container.logging.effect.tombstone.v1\u{0}".utf8
    )

    private struct DecodedObject: Sendable {
        let binding: ProtectedLoggingEffectBindingV1
        let material: Data
        let authenticationCode: Data
    }

    private struct DecodedTombstone: Sendable {
        let binding: ProtectedLoggingEffectBindingV1
        let objectAuthenticationCode: Data
    }

    private struct ValidatedReference: Sendable {
        let objectID: String
        let authenticationCode: Data
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private struct StoreRoot {
        let parentDescriptor: Int32
        let descriptor: Int32
        let name: String
        let parentIdentity: FileIdentity
        let identity: FileIdentity
    }

    private static let processLock = NSRecursiveLock()

    private let rootParentDescriptor: Int32
    private let rootDescriptor: Int32
    private let rootName: String
    private let rootParentIdentity: FileIdentity
    private let rootIdentity: FileIdentity
    private let lockDescriptor: Int32
    private let lockIdentity: FileIdentity
    private let keyData: Data
    private let randomBytes: RandomBytes
    private let testingObjectID: TestingObjectID?
    private let testingFailureInjector: TestingFailureInjector

    init(rootURL: URL) throws {
        try self.init(
            rootURL: rootURL,
            _testingRandomBytes: Self.secureRandomBytes
        )
    }

    /// Test hooks never enter production wiring. They permit deterministic
    /// collision and crash-boundary coverage without weakening file checks.
    init(
        rootURL: URL,
        _testingRandomBytes randomBytes: @escaping RandomBytes,
        _testingObjectID testingObjectID: TestingObjectID? = nil,
        _testingFailureInjector testingFailureInjector: @escaping TestingFailureInjector = { _ in }
    ) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let root = try Self.openStoreRoot(at: rootURL)
        var lockDescriptor: Int32 = -1
        do {
            lockDescriptor = try Self.openLockFile(rootDescriptor: root.descriptor)
            try Self.acquireFileLock(lockDescriptor)
            defer { Self.releaseFileLock(lockDescriptor) }
            let keyData = try Self.loadOrCreateKey(
                rootDescriptor: root.descriptor,
                randomBytes: randomBytes
            )
            try Self.reconcileCrashRemnants(
                rootDescriptor: root.descriptor,
                keyData: keyData,
                retainingTombstoneObjectIDs: nil
            )
            self.rootParentDescriptor = root.parentDescriptor
            self.rootDescriptor = root.descriptor
            self.rootName = root.name
            self.rootParentIdentity = root.parentIdentity
            self.rootIdentity = root.identity
            self.lockDescriptor = lockDescriptor
            self.lockIdentity = try Self.fileIdentity(
                descriptor: lockDescriptor,
                operation: .openLock
            )
            self.keyData = keyData
            self.randomBytes = randomBytes
            self.testingObjectID = testingObjectID
            self.testingFailureInjector = testingFailureInjector
        } catch {
            if lockDescriptor >= 0 {
                Darwin.close(lockDescriptor)
            }
            Darwin.close(root.descriptor)
            Darwin.close(root.parentDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(lockDescriptor)
        Darwin.close(rootDescriptor)
        Darwin.close(rootParentDescriptor)
    }

    func seal(
        _ material: LogDriverOpaqueEffectTokenV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> ProtectedLoggingEffectReferenceV1 {
        try withExclusiveOperation {
            let bindingData = try Self.canonicalBindingData(binding)
            let materialData = material.withUnsafeBytes { Data($0) }
            guard materialData.count <= Self.maximumMaterialBytes else {
                throw ProtectedLoggingEffectStoreError.boundsExceeded
            }
            let objectID = try deriveObjectID(bindingData: bindingData)
            let encoded = try Self.encodeObject(
                objectID: objectID,
                bindingData: bindingData,
                material: materialData,
                keyData: keyData
            )
            let authenticationCode = Data(encoded.suffix(Self.authenticationCodeByteCount))
            let reference = try Self.reference(
                binding: binding,
                objectID: objectID,
                authenticationCode: authenticationCode
            )

            if let tombstone = try readTombstoneIfPresent(objectID: objectID) {
                try Self.authenticate(
                    tombstone: tombstone,
                    reference: reference,
                    binding: binding
                )
                throw ProtectedLoggingEffectStoreError.removed
            }

            do {
                try publishImmutable(
                    encoded,
                    targetName: Self.objectFileName(objectID: objectID),
                    temporaryPrefix: Self.temporaryFilePrefix,
                    component: .object
                )
            } catch ProtectedLoggingEffectStoreError.identifierCollision {
                let existing = try readObject(objectID: objectID)
                guard existing.binding == binding else {
                    throw ProtectedLoggingEffectStoreError.identifierCollision
                }
                guard Self.timingSafeEqual(existing.material, materialData) else {
                    throw ProtectedLoggingEffectStoreError.materialConflict
                }
                guard Self.timingSafeEqual(existing.authenticationCode, authenticationCode) else {
                    throw ProtectedLoggingEffectStoreError.integrityMismatch
                }
                return try Self.reference(
                    binding: existing.binding,
                    objectID: objectID,
                    authenticationCode: existing.authenticationCode
                )
            }
            try testingFailureInjector(.afterObjectPublication)
            return reference
        }
    }

    func resolve(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> LogDriverOpaqueEffectTokenV1 {
        try withExclusiveOperation {
            let validated = try validate(reference: reference, binding: binding)
            if let tombstone = try readTombstoneIfPresent(objectID: validated.objectID) {
                try Self.authenticate(
                    tombstone: tombstone,
                    reference: reference,
                    binding: binding
                )
                throw ProtectedLoggingEffectStoreError.removed
            }
            let object = try readObject(objectID: validated.objectID)
            try Self.authenticate(
                object: object,
                validatedReference: validated,
                binding: binding
            )
            return try LogDriverOpaqueEffectTokenV1(validating: object.material)
        }
    }

    func remove(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws {
        try withExclusiveOperation {
            let validated = try validate(reference: reference, binding: binding)

            if let tombstone = try readTombstoneIfPresent(objectID: validated.objectID) {
                try Self.authenticate(
                    tombstone: tombstone,
                    reference: reference,
                    binding: binding
                )
                if let object = try readObjectIfPresent(objectID: validated.objectID) {
                    try Self.authenticate(
                        object: object,
                        validatedReference: validated,
                        binding: binding
                    )
                    try deleteObject(objectID: validated.objectID)
                }
                return
            }

            guard let object = try readObjectIfPresent(objectID: validated.objectID) else {
                throw ProtectedLoggingEffectStoreError.notFound
            }
            try Self.authenticate(
                object: object,
                validatedReference: validated,
                binding: binding
            )
            let tombstone = try Self.encodeTombstone(
                objectID: validated.objectID,
                bindingData: Self.canonicalBindingData(binding),
                objectAuthenticationCode: validated.authenticationCode,
                keyData: keyData
            )
            do {
                try publishImmutable(
                    tombstone,
                    targetName: Self.tombstoneFileName(objectID: validated.objectID),
                    temporaryPrefix: Self.temporaryFilePrefix,
                    component: .tombstone
                )
            } catch ProtectedLoggingEffectStoreError.identifierCollision {
                guard
                    let existing = try readTombstoneIfPresent(objectID: validated.objectID)
                else {
                    throw ProtectedLoggingEffectStoreError.integrityMismatch
                }
                try Self.authenticate(
                    tombstone: existing,
                    reference: reference,
                    binding: binding
                )
            }
            try testingFailureInjector(.afterTombstonePublication)
            try deleteObject(objectID: validated.objectID)
        }
    }

    /// Reconciles crash remnants and compacts only tombstones no longer
    /// authorized by the caller's durable lifecycle ledger.
    func reconcile(
        retainingEffectReferences references: [ProtectedLoggingEffectReferenceV1]
    ) async throws {
        try withExclusiveOperation {
            guard references.count <= Self.maximumDirectoryEntries else {
                throw ProtectedLoggingEffectStoreError.boundsExceeded
            }
            var retainedObjectIDs = Set<String>()
            retainedObjectIDs.reserveCapacity(references.count)
            for reference in references {
                let validated = try validate(reference: reference, binding: reference.binding)
                if let tombstone = try readTombstoneIfPresent(objectID: validated.objectID) {
                    try Self.authenticate(
                        tombstone: tombstone,
                        reference: reference,
                        binding: reference.binding
                    )
                }
                _ = retainedObjectIDs.insert(validated.objectID)
            }
            try Self.reconcileCrashRemnants(
                rootDescriptor: rootDescriptor,
                keyData: keyData,
                retainingTombstoneObjectIDs: retainedObjectIDs
            )
        }
    }

    private func validate(
        reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) throws -> ValidatedReference {
        try reference.validateBinding(binding)
        guard Self.isValidObjectID(reference.protectedStoreObjectID) else {
            throw ProtectedLoggingEffectStoreError.invalidReference
        }
        let bindingData = try Self.canonicalBindingData(binding)
        let expectedObjectID = try deriveObjectID(bindingData: bindingData)
        guard
            Self.timingSafeEqual(
                Data(reference.protectedStoreObjectID.utf8),
                Data(expectedObjectID.utf8)
            )
        else {
            throw ProtectedLoggingEffectStoreError.invalidReference
        }
        let authenticationCode = try Self.authenticationCode(
            integrityDigest: reference.integrityDigest
        )
        return ValidatedReference(
            objectID: reference.protectedStoreObjectID,
            authenticationCode: authenticationCode
        )
    }

    private func validateStoreBoundary() throws {
        try Self.validateStoreBoundary(
            rootParentDescriptor: rootParentDescriptor,
            rootDescriptor: rootDescriptor,
            rootName: rootName,
            rootParentIdentity: rootParentIdentity,
            rootIdentity: rootIdentity,
            lockDescriptor: lockDescriptor,
            lockIdentity: lockIdentity,
            keyData: keyData
        )
    }

    private func withExclusiveOperation<T>(
        _ operation: () throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try Self.acquireFileLock(lockDescriptor)
        defer { Self.releaseFileLock(lockDescriptor) }
        try validateStoreBoundary()
        return try operation()
    }

    private func deriveObjectID(bindingData: Data) throws -> String {
        let objectID: String
        if let testingObjectID {
            objectID = try testingObjectID(bindingData)
        } else {
            var authenticated = Data()
            authenticated.reserveCapacity(
                Self.objectIDDomain.count + MemoryLayout<UInt32>.size + bindingData.count
            )
            authenticated.append(Self.objectIDDomain)
            authenticated.appendBigEndian(UInt32(bindingData.count))
            authenticated.append(bindingData)
            objectID = Self.hex(
                HMAC<SHA256>.authenticationCode(
                    for: authenticated,
                    using: SymmetricKey(data: keyData)
                )
            )
        }
        guard Self.isValidObjectID(objectID) else {
            throw ProtectedLoggingEffectStoreError.invalidReference
        }
        return objectID
    }

    private func readObject(objectID: String) throws -> DecodedObject {
        let encoded = try Self.readManagedFile(
            rootDescriptor: rootDescriptor,
            fileName: Self.objectFileName(objectID: objectID),
            component: .object,
            minimumSize: Self.minimumEncodedObjectBytes,
            maximumSize: Self.maximumEncodedObjectBytes
        )
        return try Self.decodeObject(
            encoded,
            expectedObjectID: objectID,
            keyData: keyData
        )
    }

    private func readObjectIfPresent(objectID: String) throws -> DecodedObject? {
        do {
            return try readObject(objectID: objectID)
        } catch ProtectedLoggingEffectStoreError.notFound {
            return nil
        }
    }

    private func readTombstoneIfPresent(objectID: String) throws -> DecodedTombstone? {
        do {
            let encoded = try Self.readManagedFile(
                rootDescriptor: rootDescriptor,
                fileName: Self.tombstoneFileName(objectID: objectID),
                component: .tombstone,
                minimumSize: Self.minimumEncodedTombstoneBytes,
                maximumSize: Self.maximumEncodedTombstoneBytes
            )
            return try Self.decodeTombstone(
                encoded,
                expectedObjectID: objectID,
                keyData: keyData
            )
        } catch ProtectedLoggingEffectStoreError.notFound {
            return nil
        }
    }

    private func publishImmutable(
        _ data: Data,
        targetName: String,
        temporaryPrefix: String,
        component: ProtectedLoggingEffectStoreError.Component
    ) throws {
        try Self.publishImmutable(
            data,
            rootDescriptor: rootDescriptor,
            targetName: targetName,
            temporaryPrefix: temporaryPrefix,
            component: component,
            randomBytes: randomBytes,
            failureInjector: testingFailureInjector
        )
    }

    private func deleteObject(objectID: String) throws {
        let name = Self.objectFileName(objectID: objectID)
        let result = name.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT {
                return
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.delete, code)
        }
        try Self.synchronizeDirectory(
            rootDescriptor,
            failureInjector: testingFailureInjector
        )
    }

    private static func reference(
        binding: ProtectedLoggingEffectBindingV1,
        objectID: String,
        authenticationCode: Data
    ) throws -> ProtectedLoggingEffectReferenceV1 {
        try ProtectedLoggingEffectReferenceV1(
            binding: binding,
            protectedStoreObjectID: objectID,
            integrityDigest: "hmac-sha256:\(hex(authenticationCode))"
        )
    }

    private static func authenticationCode(integrityDigest: String) throws -> Data {
        let prefix = "hmac-sha256:"
        guard integrityDigest.hasPrefix(prefix) else {
            throw ProtectedLoggingEffectStoreError.invalidReference
        }
        let encoded = integrityDigest.dropFirst(prefix.count)
        guard encoded.count == authenticationCodeByteCount * 2,
            let authenticationCode = dataFromLowercaseHex(encoded)
        else {
            throw ProtectedLoggingEffectStoreError.invalidReference
        }
        return authenticationCode
    }

    private static func authenticate(
        object: DecodedObject,
        validatedReference: ValidatedReference,
        binding: ProtectedLoggingEffectBindingV1
    ) throws {
        guard object.binding == binding else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }
        guard
            timingSafeEqual(
                object.authenticationCode,
                validatedReference.authenticationCode
            )
        else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }
    }

    private static func authenticate(
        tombstone: DecodedTombstone,
        reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) throws {
        guard tombstone.binding == binding else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }
        let referenceCode = try authenticationCode(
            integrityDigest: reference.integrityDigest
        )
        guard timingSafeEqual(tombstone.objectAuthenticationCode, referenceCode) else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }
    }

    static func canonicalBindingData(
        _ binding: ProtectedLoggingEffectBindingV1
    ) throws -> Data {
        var encoded = Data()
        encoded.reserveCapacity(
            bindingMagic.count
                + MemoryLayout<UInt32>.size * 4
                + MemoryLayout<UInt64>.size
                + binding.effectID.utf8.count
                + binding.owningControllerID.utf8.count
                + binding.providerID.utf8.count
        )
        encoded.append(bindingMagic)
        encoded.appendBigEndian(binding.schemaVersion)
        try encoded.appendLengthPrefixedUTF8(binding.effectID)
        try encoded.appendLengthPrefixedUTF8(binding.owningControllerID)
        try encoded.appendLengthPrefixedUTF8(binding.providerID)
        encoded.appendBigEndian(binding.providerGeneration)
        guard encoded.count <= maximumBindingBytes else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        return encoded
    }

    private static func decodeCanonicalBinding(
        _ encoded: Data
    ) throws -> ProtectedLoggingEffectBindingV1 {
        guard encoded.count <= maximumBindingBytes else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        var reader = ProtectedLoggingEffectDataReader(data: encoded)
        guard try reader.read(count: bindingMagic.count) == bindingMagic,
            try reader.readUInt32() == ProtectedLoggingEffectBindingV1.currentSchemaVersion
        else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let effectID = try reader.readLengthPrefixedUTF8()
        let owningControllerID = try reader.readLengthPrefixedUTF8()
        let providerID = try reader.readLengthPrefixedUTF8()
        let providerGeneration = try reader.readUInt64()
        guard reader.isAtEnd else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let binding: ProtectedLoggingEffectBindingV1
        do {
            binding = try ProtectedLoggingEffectBindingV1(
                effectID: effectID,
                owningControllerID: owningControllerID,
                providerID: providerID,
                providerGeneration: providerGeneration
            )
        } catch {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        guard try canonicalBindingData(binding) == encoded else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        return binding
    }

    private static func encodeObject(
        objectID: String,
        bindingData: Data,
        material: Data,
        keyData: Data
    ) throws -> Data {
        guard isValidObjectID(objectID),
            bindingData.count <= maximumBindingBytes,
            material.count <= maximumMaterialBytes,
            bindingData.count <= Int(UInt32.max),
            material.count <= Int(UInt32.max)
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        var encoded = Data()
        encoded.reserveCapacity(
            minimumEncodedObjectBytes + bindingData.count + material.count
        )
        encoded.append(objectMagic)
        encoded.appendBigEndian(schemaVersion)
        encoded.append(Data(objectID.utf8))
        encoded.appendBigEndian(UInt32(bindingData.count))
        encoded.appendBigEndian(UInt32(material.count))
        encoded.append(bindingData)
        encoded.append(material)
        encoded.append(
            authenticationCode(
                domain: objectAuthenticationDomain,
                payload: encoded,
                keyData: keyData
            )
        )
        guard encoded.count <= maximumEncodedObjectBytes else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        return encoded
    }

    private static func decodeObject(
        _ encoded: Data,
        expectedObjectID: String,
        keyData: Data
    ) throws -> DecodedObject {
        guard encoded.count >= minimumEncodedObjectBytes,
            encoded.count <= maximumEncodedObjectBytes
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        let payload = Data(encoded.dropLast(authenticationCodeByteCount))
        let authenticationCode = Data(encoded.suffix(authenticationCodeByteCount))
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                authenticationCode,
                authenticating: authenticatedData(
                    domain: objectAuthenticationDomain,
                    payload: payload
                ),
                using: SymmetricKey(data: keyData)
            )
        else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }

        var reader = ProtectedLoggingEffectDataReader(data: payload)
        guard try reader.read(count: objectMagic.count) == objectMagic,
            try reader.readUInt32() == schemaVersion
        else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let objectIDData = try reader.read(count: objectIDCharacterCount)
        guard let objectID = String(data: objectIDData, encoding: .utf8),
            isValidObjectID(objectID),
            objectID == expectedObjectID
        else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let bindingCount = Int(try reader.readUInt32())
        let materialCount = Int(try reader.readUInt32())
        guard bindingCount <= maximumBindingBytes,
            materialCount <= maximumMaterialBytes
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        let bindingData = try reader.read(count: bindingCount)
        let material = try reader.read(count: materialCount)
        guard reader.isAtEnd else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let binding = try decodeCanonicalBinding(bindingData)
        return DecodedObject(
            binding: binding,
            material: material,
            authenticationCode: authenticationCode
        )
    }

    private static func encodeTombstone(
        objectID: String,
        bindingData: Data,
        objectAuthenticationCode: Data,
        keyData: Data
    ) throws -> Data {
        guard isValidObjectID(objectID),
            bindingData.count <= maximumBindingBytes,
            bindingData.count <= Int(UInt32.max),
            objectAuthenticationCode.count == authenticationCodeByteCount
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        var encoded = Data()
        encoded.reserveCapacity(minimumEncodedTombstoneBytes + bindingData.count)
        encoded.append(tombstoneMagic)
        encoded.appendBigEndian(schemaVersion)
        encoded.append(Data(objectID.utf8))
        encoded.appendBigEndian(UInt32(bindingData.count))
        encoded.append(bindingData)
        encoded.append(objectAuthenticationCode)
        encoded.append(
            authenticationCode(
                domain: tombstoneAuthenticationDomain,
                payload: encoded,
                keyData: keyData
            )
        )
        guard encoded.count <= maximumEncodedTombstoneBytes else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        return encoded
    }

    private static func decodeTombstone(
        _ encoded: Data,
        expectedObjectID: String,
        keyData: Data
    ) throws -> DecodedTombstone {
        guard encoded.count >= minimumEncodedTombstoneBytes,
            encoded.count <= maximumEncodedTombstoneBytes
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        let payload = Data(encoded.dropLast(authenticationCodeByteCount))
        let tombstoneCode = Data(encoded.suffix(authenticationCodeByteCount))
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                tombstoneCode,
                authenticating: authenticatedData(
                    domain: tombstoneAuthenticationDomain,
                    payload: payload
                ),
                using: SymmetricKey(data: keyData)
            )
        else {
            throw ProtectedLoggingEffectStoreError.integrityMismatch
        }

        var reader = ProtectedLoggingEffectDataReader(data: payload)
        guard try reader.read(count: tombstoneMagic.count) == tombstoneMagic,
            try reader.readUInt32() == schemaVersion
        else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let objectIDData = try reader.read(count: objectIDCharacterCount)
        guard let objectID = String(data: objectIDData, encoding: .utf8),
            isValidObjectID(objectID),
            objectID == expectedObjectID
        else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let bindingCount = Int(try reader.readUInt32())
        guard bindingCount <= maximumBindingBytes else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        let bindingData = try reader.read(count: bindingCount)
        let objectCode = try reader.read(count: authenticationCodeByteCount)
        guard reader.isAtEnd else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let binding = try decodeCanonicalBinding(bindingData)
        return DecodedTombstone(
            binding: binding,
            objectAuthenticationCode: objectCode
        )
    }

    private static var minimumEncodedObjectBytes: Int {
        objectMagic.count
            + MemoryLayout<UInt32>.size
            + objectIDCharacterCount
            + 2 * MemoryLayout<UInt32>.size
            + authenticationCodeByteCount
    }

    private static var minimumEncodedTombstoneBytes: Int {
        tombstoneMagic.count
            + MemoryLayout<UInt32>.size
            + objectIDCharacterCount
            + MemoryLayout<UInt32>.size
            + 2 * authenticationCodeByteCount
    }

    private static func objectFileName(objectID: String) -> String {
        objectFilePrefix + objectID + objectFileSuffix
    }

    private static func tombstoneFileName(objectID: String) -> String {
        objectFilePrefix + objectID + tombstoneFileSuffix
    }

    private static func objectID(fileName: String, suffix: String) -> String? {
        guard
            fileName.hasPrefix(objectFilePrefix),
            fileName.hasSuffix(suffix)
        else {
            return nil
        }
        let start = fileName.index(
            fileName.startIndex,
            offsetBy: objectFilePrefix.count
        )
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start <= end else {
            return nil
        }
        let objectID = String(fileName[start..<end])
        return isValidObjectID(objectID) ? objectID : nil
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

    private static func authenticationCode(
        domain: Data,
        payload: Data,
        keyData: Data
    ) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: authenticatedData(domain: domain, payload: payload),
                using: SymmetricKey(data: keyData)
            )
        )
    }

    private static func authenticatedData(domain: Data, payload: Data) -> Data {
        var authenticated = Data()
        authenticated.reserveCapacity(domain.count + payload.count)
        authenticated.append(domain)
        authenticated.append(payload)
        return authenticated
    }

    private static func reconcileCrashRemnants(
        rootDescriptor: Int32,
        keyData: Data,
        retainingTombstoneObjectIDs: Set<String>?
    ) throws {
        let entries = try directoryEntries(rootDescriptor: rootDescriptor).sorted()
        var removedAny = false

        for name in entries
        where
            name.hasPrefix(temporaryFilePrefix)
            || name.hasPrefix(temporaryKeyPrefix)
        {
            removedAny =
                try unlinkIfPresent(
                    rootDescriptor: rootDescriptor,
                    fileName: name
                ) || removedAny
        }

        for name in entries {
            guard let objectID = objectID(fileName: name, suffix: tombstoneFileSuffix) else {
                continue
            }
            let tombstoneData = try readManagedFile(
                rootDescriptor: rootDescriptor,
                fileName: name,
                component: .tombstone,
                minimumSize: minimumEncodedTombstoneBytes,
                maximumSize: maximumEncodedTombstoneBytes
            )
            let tombstone = try decodeTombstone(
                tombstoneData,
                expectedObjectID: objectID,
                keyData: keyData
            )
            let objectName = objectFileName(objectID: objectID)
            let objectData: Data?
            do {
                objectData = try readManagedFile(
                    rootDescriptor: rootDescriptor,
                    fileName: objectName,
                    component: .object,
                    minimumSize: minimumEncodedObjectBytes,
                    maximumSize: maximumEncodedObjectBytes
                )
            } catch ProtectedLoggingEffectStoreError.notFound {
                objectData = nil
            }
            if let objectData {
                let object = try decodeObject(
                    objectData,
                    expectedObjectID: objectID,
                    keyData: keyData
                )
                guard object.binding == tombstone.binding,
                    timingSafeEqual(
                        object.authenticationCode,
                        tombstone.objectAuthenticationCode
                    )
                else {
                    throw ProtectedLoggingEffectStoreError.integrityMismatch
                }
                removedAny =
                    try unlinkIfPresent(
                        rootDescriptor: rootDescriptor,
                        fileName: objectName
                    ) || removedAny
            }
            if let retainingTombstoneObjectIDs,
                !retainingTombstoneObjectIDs.contains(objectID)
            {
                removedAny =
                    try unlinkIfPresent(
                        rootDescriptor: rootDescriptor,
                        fileName: name
                    ) || removedAny
            }
        }
        if removedAny {
            try synchronizeDirectory(rootDescriptor)
        }
    }

    private static func validateStoreBoundary(
        rootParentDescriptor: Int32,
        rootDescriptor: Int32,
        rootName: String,
        rootParentIdentity: FileIdentity,
        rootIdentity: FileIdentity,
        lockDescriptor: Int32,
        lockIdentity: FileIdentity,
        keyData: Data
    ) throws {
        guard
            try fileIdentity(
                descriptor: rootParentDescriptor,
                operation: .openAncestor
            ) == rootParentIdentity,
            try fileIdentity(
                descriptor: rootDescriptor,
                operation: .openRoot
            ) == rootIdentity,
            try fileIdentity(
                descriptor: lockDescriptor,
                operation: .openLock
            ) == lockIdentity
        else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.root)
        }
        try validateRootLink(
            parentDescriptor: rootParentDescriptor,
            rootName: rootName,
            expectedIdentity: rootIdentity
        )
        try validateDirectoryDescriptor(rootDescriptor)
        try validateLockFile(
            rootDescriptor: rootDescriptor,
            descriptor: lockDescriptor,
            expectedIdentity: lockIdentity
        )
        let onDiskKey = try loadExistingKey(rootDescriptor: rootDescriptor)
        guard timingSafeEqual(keyData, onDiskKey) else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.key)
        }
    }

    private static func openStoreRoot(at rootURL: URL) throws -> StoreRoot {
        guard rootURL.isFileURL else {
            throw ProtectedLoggingEffectStoreError.invalidRoot
        }
        let finalComponent = rootURL.lastPathComponent
        guard !finalComponent.isEmpty, finalComponent != ".", finalComponent != ".." else {
            throw ProtectedLoggingEffectStoreError.invalidRoot
        }
        let suppliedPath = rootURL.path
        let path: String
        if suppliedPath == "/var" || suppliedPath.hasPrefix("/var/") {
            path = "/private" + suppliedPath
        } else if suppliedPath == "/tmp" || suppliedPath.hasPrefix("/tmp/") {
            path = "/private" + suppliedPath
        } else if suppliedPath == "/etc" || suppliedPath.hasPrefix("/etc/") {
            path = "/private" + suppliedPath
        } else {
            path = suppliedPath
        }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ProtectedLoggingEffectStoreError.invalidRoot
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ProtectedLoggingEffectStoreError.invalidRoot
        }

        var parentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.openAncestor, errno)
        }
        do {
            for component in components.dropLast() {
                let next = component.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw ProtectedLoggingEffectStoreError.ioFailure(.openAncestor, errno)
                }
                Darwin.close(parentDescriptor)
                parentDescriptor = next
            }

            let rootName = components[components.count - 1]
            let creationResult = rootName.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            let created: Bool
            if creationResult == 0 {
                created = true
            } else if errno == EEXIST {
                created = false
            } else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.createRoot, errno)
            }

            let descriptor = rootName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.openRoot, errno)
            }
            do {
                if created {
                    guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                        throw ProtectedLoggingEffectStoreError.ioFailure(.createRoot, errno)
                    }
                    try clearExtendedACL(descriptor, component: .root)
                    try synchronizeDirectory(descriptor)
                    try synchronizeDirectory(parentDescriptor)
                }
                try validateDirectoryDescriptor(descriptor)
                let identity = try fileIdentity(descriptor: descriptor, operation: .openRoot)
                let parentIdentity = try fileIdentity(
                    descriptor: parentDescriptor,
                    operation: .openAncestor
                )
                try validateRootLink(
                    parentDescriptor: parentDescriptor,
                    rootName: rootName,
                    expectedIdentity: identity
                )
                return StoreRoot(
                    parentDescriptor: parentDescriptor,
                    descriptor: descriptor,
                    name: rootName,
                    parentIdentity: parentIdentity,
                    identity: identity
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    private static func validateRootLink(
        parentDescriptor: Int32,
        rootName: String,
        expectedIdentity: FileIdentity
    ) throws {
        var metadata = stat()
        let result = rootName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.openRoot, errno)
        }
        guard isDirectory(metadata), fileIdentity(metadata) == expectedIdentity else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.root)
        }
    }

    private static func openLockFile(rootDescriptor: Int32) throws -> Int32 {
        let createdDescriptor = lockFileName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        let descriptor: Int32
        let created: Bool
        if createdDescriptor >= 0 {
            descriptor = createdDescriptor
            created = true
        } else if errno == EEXIST {
            descriptor = lockFileName.withCString {
                Darwin.openat(rootDescriptor, $0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.openLock, errno)
            }
            created = false
        } else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.openLock, errno)
        }
        do {
            if created {
                guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw ProtectedLoggingEffectStoreError.ioFailure(.openLock, errno)
                }
                try clearExtendedACL(descriptor, component: .lock)
                guard Darwin.fsync(descriptor) == 0 else {
                    throw ProtectedLoggingEffectStoreError.ioFailure(.synchronizeFile, errno)
                }
                try synchronizeDirectory(rootDescriptor)
            }
            try validateLockFile(
                rootDescriptor: rootDescriptor,
                descriptor: descriptor,
                expectedIdentity: try fileIdentity(descriptor: descriptor, operation: .openLock)
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateLockFile(
        rootDescriptor: Int32,
        descriptor: Int32,
        expectedIdentity: FileIdentity
    ) throws {
        try validateRegularFileDescriptor(descriptor, component: .lock)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.openLock, errno)
        }
        guard metadata.st_size == 0 else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.lock)
        }
        var linkedMetadata = stat()
        let result = lockFileName.withCString {
            Darwin.fstatat(rootDescriptor, $0, &linkedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
            isRegularFile(linkedMetadata),
            fileIdentity(linkedMetadata) == expectedIdentity
        else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.lock)
        }
    }

    private static func acquireFileLock(_ descriptor: Int32) throws {
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR {
                continue
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.lock, errno)
        }
    }

    private static func releaseFileLock(_ descriptor: Int32) {
        while Darwin.lockf(descriptor, F_ULOCK, 0) != 0, errno == EINTR {}
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.openRoot, errno)
        }
        guard isDirectory(metadata),
            metadata.st_uid == Darwin.geteuid(),
            permissions(metadata) == mode_t(0o700)
        else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.root)
        }
        try validateNoExtendedACL(descriptor, component: .root)
    }

    private static func loadOrCreateKey(
        rootDescriptor: Int32,
        randomBytes: RandomBytes
    ) throws -> Data {
        if let existing = try loadExistingKeyIfPresent(
            rootDescriptor: rootDescriptor
        ) {
            return existing
        }
        let entries = try directoryEntries(rootDescriptor: rootDescriptor)
        let protectedStateExists = entries.contains { name in
            objectID(fileName: name, suffix: objectFileSuffix) != nil
                || objectID(fileName: name, suffix: tombstoneFileSuffix) != nil
        }
        guard !protectedStateExists else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.key)
        }

        let key = try randomBytes(keyByteCount)
        guard key.count == keyByteCount else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.key)
        }
        do {
            try publishImmutable(
                key,
                rootDescriptor: rootDescriptor,
                targetName: keyFileName,
                temporaryPrefix: temporaryKeyPrefix,
                component: .key,
                randomBytes: randomBytes
            )
            return key
        } catch ProtectedLoggingEffectStoreError.identifierCollision {
            return try loadExistingKey(rootDescriptor: rootDescriptor)
        }
    }

    private static func loadExistingKey(rootDescriptor: Int32) throws -> Data {
        guard
            let key = try loadExistingKeyIfPresent(rootDescriptor: rootDescriptor)
        else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(.key)
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
            if code == ENOENT {
                return nil
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.openKey, code)
        }
        defer { Darwin.close(descriptor) }
        try validateRegularFileDescriptor(descriptor, component: .key)
        return try readExactFile(
            descriptor: descriptor,
            expectedSize: keyByteCount,
            component: .key
        )
    }

    private static func publishImmutable(
        _ data: Data,
        rootDescriptor: Int32,
        targetName: String,
        temporaryPrefix: String,
        component: ProtectedLoggingEffectStoreError.Component,
        randomBytes: RandomBytes,
        failureInjector: TestingFailureInjector = { _ in }
    ) throws {
        let temporary = try createTemporaryFile(
            rootDescriptor: rootDescriptor,
            prefix: temporaryPrefix,
            component: component,
            randomBytes: randomBytes,
            failureInjector: failureInjector
        )
        let temporaryName = temporary.name
        let descriptor = temporary.descriptor
        var descriptorIsOpen = true
        var wasPublished = false
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(
                    .synchronizeFile,
                    errno
                )
            }
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.write, errno)
            }

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
                    throw ProtectedLoggingEffectStoreError.identifierCollision
                }
                throw ProtectedLoggingEffectStoreError.ioFailure(.publishFile, code)
            }
            wasPublished = true
            try synchronizeDirectory(
                rootDescriptor,
                failureInjector: failureInjector
            )
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            if !wasPublished {
                try cleanupTemporaryFile(
                    rootDescriptor: rootDescriptor,
                    fileName: temporaryName,
                    failureInjector: failureInjector
                )
            }
            throw error
        }
    }

    private static func createTemporaryFile(
        rootDescriptor: Int32,
        prefix: String,
        component: ProtectedLoggingEffectStoreError.Component,
        randomBytes: RandomBytes,
        failureInjector: TestingFailureInjector
    ) throws -> (name: String, descriptor: Int32) {
        for _ in 0..<maximumPublicationAttempts {
            let suffix = try randomBytes(16)
            guard suffix.count == 16 else {
                throw ProtectedLoggingEffectStoreError.invalidMetadata(component)
            }
            let name = prefix + hex(suffix)
            do {
                let descriptor = try openNewFile(
                    rootDescriptor: rootDescriptor,
                    fileName: name,
                    component: component,
                    failureInjector: failureInjector
                )
                return (name, descriptor)
            } catch ProtectedLoggingEffectStoreError.identifierCollision {
                continue
            }
        }
        throw ProtectedLoggingEffectStoreError.identifierCollision
    }

    private static func openNewFile(
        rootDescriptor: Int32,
        fileName: String,
        component: ProtectedLoggingEffectStoreError.Component,
        failureInjector: TestingFailureInjector
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
                throw ProtectedLoggingEffectStoreError.identifierCollision
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(
                .createTemporaryFile,
                code
            )
        }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(
                    .createTemporaryFile,
                    errno
                )
            }
            try clearExtendedACL(descriptor, component: component)
            try validateRegularFileDescriptor(descriptor, component: component)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            try cleanupTemporaryFile(
                rootDescriptor: rootDescriptor,
                fileName: fileName,
                failureInjector: failureInjector
            )
            throw error
        }
    }

    private static func cleanupTemporaryFile(
        rootDescriptor: Int32,
        fileName: String,
        failureInjector: TestingFailureInjector
    ) throws {
        try failureInjector(.beforeTemporaryCleanupUnlink)
        if try unlinkIfPresent(rootDescriptor: rootDescriptor, fileName: fileName) {
            try synchronizeDirectory(
                rootDescriptor,
                failureInjector: failureInjector
            )
        }
    }

    private static func readManagedFile(
        rootDescriptor: Int32,
        fileName: String,
        component: ProtectedLoggingEffectStoreError.Component,
        minimumSize: Int,
        maximumSize: Int
    ) throws -> Data {
        let descriptor = fileName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                throw ProtectedLoggingEffectStoreError.notFound
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.read, code)
        }
        defer { Darwin.close(descriptor) }
        try validateRegularFileDescriptor(descriptor, component: component)

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
        }
        guard metadata.st_size >= 0,
            metadata.st_size >= off_t(minimumSize),
            metadata.st_size <= off_t(maximumSize)
        else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        return try readExactFile(
            descriptor: descriptor,
            expectedSize: Int(metadata.st_size),
            component: component
        )
    }

    private static func validateRegularFileDescriptor(
        _ descriptor: Int32,
        component: ProtectedLoggingEffectStoreError.Component
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
        }
        guard isRegularFile(metadata),
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            permissions(metadata) == mode_t(0o600)
        else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(component)
        }
        try validateNoExtendedACL(descriptor, component: component)
    }

    private static func directoryEntries(rootDescriptor: Int32) throws -> [String] {
        let independent = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard independent >= 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.readDirectory, errno)
        }
        guard let directory = Darwin.fdopendir(independent) else {
            let code = errno
            Darwin.close(independent)
            throw ProtectedLoggingEffectStoreError.ioFailure(.readDirectory, code)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(256)
        var totalNameBytes = 0
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
            if name != ".", name != ".." {
                totalNameBytes += name.utf8.count
                guard names.count < maximumDirectoryEntries,
                    totalNameBytes <= maximumDirectoryEntryNameBytes
                else {
                    throw ProtectedLoggingEffectStoreError.boundsExceeded
                }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(
                .readDirectory,
                errno
            )
        }
        return names
    }

    private static func readExactFile(
        descriptor: Int32,
        expectedSize: Int,
        component: ProtectedLoggingEffectStoreError.Component
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
                throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
            }
            guard count > 0 else {
                throw ProtectedLoggingEffectStoreError.invalidMetadata(component)
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
                    throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
                }
                throw ProtectedLoggingEffectStoreError.boundsExceeded
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
                throw ProtectedLoggingEffectStoreError.ioFailure(.write, errno)
            }
            guard count > 0 else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.write, EIO)
            }
            offset += count
        }
    }

    private static func unlinkIfPresent(
        rootDescriptor: Int32,
        fileName: String
    ) throws -> Bool {
        let result = fileName.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        if result == 0 {
            return true
        }
        let code = errno
        if code == ENOENT {
            return false
        }
        throw ProtectedLoggingEffectStoreError.ioFailure(.delete, code)
    }

    private static func synchronizeDirectory(
        _ descriptor: Int32,
        failureInjector: TestingFailureInjector = { _ in }
    ) throws {
        try failureInjector(.beforeDirectorySynchronization)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(
                .synchronizeDirectory,
                errno
            )
        }
    }

    private static func clearExtendedACL(
        _ descriptor: Int32,
        component: ProtectedLoggingEffectStoreError.Component
    ) throws {
        guard let emptyACL = Darwin.acl_init(0) else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard Darwin.acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        try validateNoExtendedACL(descriptor, component: component)
    }

    private static func validateNoExtendedACL(
        _ descriptor: Int32,
        component: ProtectedLoggingEffectStoreError.Component
    ) throws {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = Darwin.acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if result == -1 {
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        guard result == 1 else {
            throw ProtectedLoggingEffectStoreError.invalidMetadata(component)
        }
    }

    private static func fileIdentity(
        descriptor: Int32,
        operation: ProtectedLoggingEffectStoreError.Operation
    ) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(operation, errno)
        }
        return fileIdentity(metadata)
    }

    private static func fileIdentity(_ metadata: stat) -> FileIdentity {
        FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
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
            throw ProtectedLoggingEffectStoreError.invalidReference
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

    private static func hex<Bytes: Sequence>(
        _ bytes: Bytes
    ) -> String where Bytes.Element == UInt8 {
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

private struct ProtectedLoggingEffectDataReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0 else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        let end = offset.addingReportingOverflow(count)
        guard !end.overflow, end.partialValue <= data.count else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
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

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try read(count: MemoryLayout<UInt64>.size)
        return bytes.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    mutating func readLengthPrefixedUTF8() throws -> String {
        let count = Int(try readUInt32())
        let encoded = try read(count: count)
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw ProtectedLoggingEffectStoreError.invalidEncoding
        }
        return value
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    fileprivate mutating func appendBigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    fileprivate mutating func appendLengthPrefixedUTF8(_ value: String) throws {
        let encoded = Data(value.utf8)
        guard encoded.count <= Int(UInt32.max) else {
            throw ProtectedLoggingEffectStoreError.boundsExceeded
        }
        appendBigEndian(UInt32(encoded.count))
        append(encoded)
    }
}
